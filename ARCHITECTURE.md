# Architecture Documentation

This document explains key architectural decisions and technical limitations for the Azure Container Apps GitHub Actions runner implementation.

## Table of Contents

- [KEDA Scaler Limitations](#keda-scaler-limitations)
- [Why Organization-Level Runners are Recommended](#why-organization-level-runners-are-recommended)
- [Available Workarounds](#available-workarounds)
- [Design Decisions](#design-decisions)

---

## KEDA Scaler Limitations

### Background

Azure Container Apps uses KEDA (Kubernetes Event-Driven Autoscaling) to scale GitHub Actions runners based on workflow queue depth. The GitHub Runner scaler monitors queued workflows and scales up/down accordingly.

### The Core Limitation: No Metadata Injection

**KEDA scalers do not pass metadata about triggering events to scaled containers.**

#### What KEDA Does

1. **Monitors external event sources** - Polls GitHub API for queued workflows
2. **Calculates scaling metrics** - Determines how many runners are needed
3. **Makes scaling decisions** - Instructs Kubernetes to scale pods from 0→1→N

#### What KEDA Does NOT Do

- **Does not mutate pod templates** - Cannot inject environment variables dynamically
- **Does not pass workflow context** - Repository name, branch, workflow ID, etc. are not available
- **Does not customize per-job** - All scaled pods use the same template configuration

### Technical Deep Dive

The KEDA GitHub Runner scaler (`github_runner_scaler.go`) processes detailed workflow information internally:
- Repository names
- Branch information
- Workflow labels
- Job requirements

However, this data is used exclusively for:
- Filtering jobs by labels
- Counting queue length
- Matching job requirements to runner capabilities

**None of this metadata is passed to the scaled containers.**

### Source Code Evidence

From the KEDA codebase analysis:
```go
// The scaler collects metrics but does not inject environment variables
func (s *githubRunnerScaler) GetWorkflowQueueLength() int64 {
    // Processes workflow runs and jobs
    // Calculates queue depth
    // Returns a number for scaling decisions
    // NO environment variable injection logic exists
}
```

### Why This Design?

KEDA is intentionally designed as a **metrics provider** for Kubernetes' Horizontal Pod Autoscaler (HPA), not as a configuration management system. This separation of concerns means:

- Scalers remain simple and focused on metrics
- Pod configuration stays in Deployment/StatefulSet manifests
- No risk of scalers modifying application workloads

---

## Why Organization-Level Runners are Recommended

### The Problem with Repository-Level Registration

When using KEDA with Azure Container Apps:

1. **Scaler Configuration** - You configure the scaler to watch specific repositories
2. **Scaling Trigger** - A workflow queues in any watched repository
3. **Pod Creation** - ACA creates a pod using your configured template
4. **Missing Information** - The pod has no way to know which repository triggered the scale event

### The Solution: Organization-Level Runners

**Organization-level runners solve this by design:**

```bash
# Set in Container App environment variables
GITHUB_ORG="myorg"
RUNNER_GROUP_ID=7  # Optional, defaults to 1
```

Benefits:
- ✅ Works with any repository in the organization
- ✅ No need to know the triggering repository
- ✅ Centralized runner management
- ✅ Supports runner groups for organization

### How It Works

1. **Init container** registers runner with organization using `GITHUB_ORG`
2. **GitHub Actions** sees the runner as available for any org repository
3. **Workflow execution** assigns the runner to any matching job
4. **Runner lifecycle** completes job and terminates (ephemeral)

---

## Available Workarounds

If you must use repository-specific runners with ACA, here are your options:

### Option 1: Static Repository Configuration (Recommended)

**Use case:** Single repository or known set of repositories

```bash
# Hardcode in Container App job definition
GITHUB_REPOSITORY="owner/repo"
```

**Pros:**
- Simple to configure
- Explicit and predictable
- Works with current init.sh

**Cons:**
- Must create separate jobs for multiple repos
- Cannot dynamically route to specific repositories

### Option 2: Multiple Container App Jobs

**Use case:** Multiple repositories with isolated runners

Create separate Container App jobs, each configured for a specific repository:

```bash
# Job 1 - Repo A
GITHUB_REPOSITORY="org/repo-a"
# Scaler watches: repos=org/repo-a

# Job 2 - Repo B
GITHUB_REPOSITORY="org/repo-b"
# Scaler watches: repos=org/repo-b
```

**Pros:**
- True repository isolation
- Each repo has dedicated runners
- Different runner configurations per repo

**Cons:**
- Operational overhead
- More complex infrastructure
- Duplicate configuration

### Option 3: Parse Repository from Organization URL

**Use case:** Want org-level flexibility with repo awareness

Modify `init.sh` to extract owner from `GITHUB_REPOSITORY`:

```bash
if [ -n "$GITHUB_REPOSITORY" ]; then
  GITHUB_ORG="${GITHUB_REPOSITORY%%/*}"  # Extract owner
  # Use org-level registration
fi
```

**Pros:**
- Maintains flexibility
- Single registration point
- Simpler than multiple jobs

**Cons:**
- Still uses org-level registration (not truly repo-specific)
- Runner appears at org level, not repo level

### Option 4: Custom External Scaler (Advanced)

**Use case:** Need true dynamic repository routing

Build a KEDA external scaler that:
- Monitors GitHub API
- Passes repository metadata to containers
- Implements custom scaling logic

**Pros:**
- Full control over metadata passing
- Can implement custom routing logic
- Solves the limitation completely

**Cons:**
- Significant development effort
- Must maintain custom scaler
- Increased complexity
- See: https://keda.sh/docs/2.14/concepts/external-scalers/

---

## Design Decisions

### Why Keep Repository-Level Support?

The current implementation supports both org-level and repo-level registration:

```bash
# Priority order:
1. GITHUB_ORG → Organization-level (recommended)
2. GITHUB_REPOSITORY → Repository-level (manual config only)
```

**Rationale:**
- Flexibility for different deployment scenarios
- Supports manual/testing environments
- Backward compatibility
- Clear fallback behavior

### Why Not Remove Repository-Level?

Repository-level registration is valid for:
- Local development and testing
- Manual Docker deployments
- Single-repo dedicated runners
- Non-ACA deployments

The code supports both, with clear documentation on when to use each.

### JIT Configuration Only

The implementation uses JIT (Just-In-Time) configuration exclusively:

**Why?**
- ✅ More secure (single-use tokens)
- ✅ Simpler logic (no fallback complexity)
- ✅ GitHub's recommended approach
- ✅ Works for both org and repo levels

**Trade-off:**
- Requires runner_group_id even for repos (uses default ID: 1)

---

## References

### Research Sources

- [KEDA GitHub Runner Scaler Documentation](https://keda.sh/docs/2.10/scalers/github-runner/)
- [KEDA Scaler Source Code](https://github.com/kedacore/keda/blob/main/pkg/scalers/github_runner_scaler.go)
- [Azure Container Apps Scaling](https://learn.microsoft.com/en-us/azure/container-apps/scale-app)
- [Tutorial: Run GitHub Actions runners with ACA](https://learn.microsoft.com/en-us/azure/container-apps/tutorial-ci-cd-runners-jobs)

### Related Documentation

- See `CLAUDE.md` for quick reference and build commands
- See `README.md` for the official Microsoft tutorial link
- See `init.sh` comments for implementation details

---

## Future Considerations

### Potential Improvements

1. **GitHub Actions Workflow Context**
   - Once the workflow starts running, `GITHUB_REPOSITORY` is available in the runner container
   - Could log this for observability/debugging
   - Not useful for init container (already registered)

2. **Runner Labels Strategy**
   - Use labels for routing (e.g., `repo-specific`, `team-frontend`)
   - Workflows can target specific runner pools
   - Provides soft routing without hard repository binding

3. **Metrics and Monitoring**
   - Track which workflows are using runners
   - Monitor runner utilization by repository
   - Alert on misconfigured runners

### Known Limitations

- Cannot dynamically route init containers to specific repos with KEDA
- Must choose between org-wide flexibility or repo-specific static config
- KEDA scaler metadata is not extensible for this use case
