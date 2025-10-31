# Architecture Documentation

This document explains key architectural decisions and technical limitations for the Azure Container Apps GitHub Actions runner implementation.

## Table of Contents

- [KEDA Scaler Limitations](#keda-scaler-limitations)
- [Why Organization-Level Runners](#why-organization-level-runners)
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

## Why Organization-Level Runners

### The Challenge with KEDA and Repository Context

When using KEDA with Azure Container Apps:

1. **Scaler Configuration** - You configure the scaler to watch specific repositories
2. **Scaling Trigger** - A workflow queues in any watched repository
3. **Pod Creation** - ACA creates a pod using your configured template
4. **Missing Information** - The pod has no way to know which repository triggered the scale event

### Organization-Level Runners: The Solution

**This implementation uses organization-level runners exclusively:**

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

## Design Decisions

### Organization-Level Only

The implementation uses organization-level runners exclusively:

**Rationale:**
- Simplifies configuration and reduces complexity
- Works seamlessly with KEDA scaler design
- Runners automatically available to all repositories in the organization
- Avoids the need for repository-specific configuration that KEDA cannot provide
- Easier to manage and maintain

### JIT Configuration Only

The implementation uses JIT (Just-In-Time) configuration exclusively:

**Why?**
- ✅ More secure (single-use tokens)
- ✅ Simpler logic (no fallback complexity)
- ✅ GitHub's recommended approach
- ✅ Ephemeral runners by design

**Benefits:**
- Each runner gets a unique, single-use configuration
- No need to manage long-lived registration tokens
- Automatic cleanup after job completion

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
