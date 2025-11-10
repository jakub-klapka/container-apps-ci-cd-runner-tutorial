# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a tutorial repository for deploying self-hosted GitHub Actions runners on Azure Container Apps jobs. The repository demonstrates a two-container pattern:

1. **Init Container** (`Dockerfile.init`) - Handles authentication and generates JIT (Just-In-Time) runner configurations
2. **Runner Container** (`Dockerfile.github`) - Executes the actual GitHub Actions workflows

See the [official tutorial](https://learn.microsoft.com/azure/container-apps/tutorial-ci-cd-runners-jobs) for deployment context.

## Key Files

### Dockerfiles

- **`Dockerfile.init`** - Init container that runs `init.sh` to generate runner credentials
  - Base: `ghcr.io/actions/actions-runner:2.329.0`
  - Installs: curl, openssl, jq, ca-certificates
  - Entrypoint: `/init.sh`
  - Runs as `runner` user

- **`Dockerfile.github`** - Main runner container that executes workflows
  - Base: `ghcr.io/actions/actions-runner:2.329.0`
  - Installs: curl, jq, Azure CLI, Terraform
  - Entrypoint: `entrypoint.sh`
  - Runs as `runner` user

### Scripts (`github-actions-runner/`)

- **`init.sh`** - Authentication and JIT config generation script
  - **Supports both organization-level and repository-level runners**
  - Uses PAT (Personal Access Token) authentication only
  - Generates JIT config exclusively (no classic registration tokens)
  - Writes JIT config to `/handoff` directory (default) for the runner container
  - Uses jq for JSON parsing (clean and efficient)
  - Structured logging with clear progress indicators
  - **Repository discovery**: For repo scope, automatically queries GitHub API to find repositories with queued workflows matching the label
  - Environment variables:
    - **Common (all modes):**
      - Required: `GITHUB_PAT` (Personal Access Token), `RUNNER_LABEL` (single label string, e.g., "rbcz-azure")
      - Optional: `RUNNER_SCOPE` (defaults to "org"), `RUNNER_NAME`, `HANDOFF_DIR`, `API`
    - **Organization mode (`RUNNER_SCOPE=org`):**
      - Required: `GITHUB_ORG` (organization login), `RUNNER_GROUP_ID` (runner group ID)
    - **Repository mode (`RUNNER_SCOPE=repo`):**
      - Required: `GITHUB_OWNER` (owner/org name)
      - Optional: `GITHUB_REPOS` (comma-separated repo names to check, e.g., "repo1,repo2")

- **`entrypoint.sh`** - Runner startup script
  - Reads JIT config from `/mnt/reg-token-store/jit` (mount path in Azure Container Apps)
  - Starts runner with: `./run.sh --jitconfig "$JIT"`

## Architecture

### Two-Container Init Pattern

1. **Init container** runs first:
   - Authenticates with GitHub API (PAT or App)
   - Calls GitHub API to generate JIT config
   - Writes JIT config file to shared volume at `$HANDOFF_DIR`

2. **Runner container** starts after init succeeds:
   - Reads credential from shared volume (mounted at `/mnt/reg-token-store/`)
   - Registers with GitHub and runs workflows
   - Self-destructs after job completion (Azure Container Apps job behavior)

### Authentication Flow

The `init.sh` script uses PAT (Personal Access Token) authentication exclusively:
- **PAT Mode**: Uses Personal Access Token directly with GitHub API
- **Required PAT scopes**:
  - Organization runners: `admin:org` scope
  - Repository runners: `repo` scope
- Generates JIT config exclusively - no fallback to classic registration tokens

### Runner Scope

The init script supports two runner scopes:

1. **Organization-level (`RUNNER_SCOPE=org`)**:
   - Runners appear in org settings and can service any repository in the organization
   - Must specify runner group via `RUNNER_GROUP_ID`
   - Single API call to generate JIT config

2. **Repository-level (`RUNNER_SCOPE=repo`)**:
   - Runners are dedicated to a single specific repository
   - Automatically discovers which repository has queued workflows
   - Queries GitHub API to find repos with matching label
   - Always uses runner_group_id: 1 (hardcoded for repo runners)

### Configuration for Azure Container Apps

When deploying with Azure Container Apps and KEDA's GitHub Runner scaler:

**Organization-level runners:**
1. **Set `RUNNER_SCOPE=org`** (or omit, it's the default)
2. **Set `GITHUB_ORG`** (required) - Your GitHub organization login
3. **Set `RUNNER_GROUP_ID`** (required) - Runner group ID
4. **Set `GITHUB_PAT`** (required) - PAT with `admin:org` scope
5. **Set `RUNNER_LABEL`** (required) - Single label string (e.g., "rbcz-azure")

**Repository-level runners:**
1. **Set `RUNNER_SCOPE=repo`**
2. **Set `GITHUB_OWNER`** (required) - Owner/org name
3. **Set `GITHUB_PAT`** (required) - PAT with `repo` scope
4. **Set `RUNNER_LABEL`** (required) - Single label string (e.g., "rbcz-azure")
5. **Set `GITHUB_REPOS`** (optional) - Comma-separated repo names to check (if omitted, checks all accessible repos)

**Why organization-level?**
- KEDA scalers determine *when* to scale based on workflow queue depth
- Repository information from triggering workflows is not available to init containers
- Org-level runners can service any repository in your organization automatically

See `ARCHITECTURE.md` for detailed technical explanation of KEDA scaler design.

## Building Images on Azure Container Registry

**Azure Container Registry:** `jklrbacaacr.azurecr.io`

**Current versions:**
- Init container: **23.0**
- Runner container: **10.0**

(Increment by 1 for each build)

**⚠️ Important Build Workflow:**

1. **Commit and push changes to GitHub first** - ACR build pulls from the remote repository
2. **Then run the ACR build command** - Uses the latest code from GitHub
3. **Update version tracking in CLAUDE.md** - Document the new version

```bash
# 1. First: Commit and push your changes
git add .
git commit -m "Your commit message"
git push origin main

# 2. Then: Build init container (increment version number for each build)
az acr build \
    --registry "jklrbacaacr" \
    --image "github-actions-init:24.0" \
    --file "Dockerfile.init" \
    "https://github.com/jakub-klapka/container-apps-ci-cd-runner-tutorial.git"

# Build runner container
az acr build \
    --registry "jklrbacaacr" \
    --image "github-actions-runner:10.0" \
    --file "Dockerfile.github" \
    "https://github.com/jakub-klapka/container-apps-ci-cd-runner-tutorial.git"

# 3. Finally: Update version tracking and commit
# Edit this file to update "Current version" above
```

### Local Docker builds (for testing)

```bash
# Build init container
docker build -f Dockerfile.init -t <registry>/runner-init:latest .

# Build runner container
docker build -f Dockerfile.github -t <registry>/github-runner:latest .
```

## Testing Locally

### Organization-Level Runners

```bash
# Direct script test
RUNNER_SCOPE="org" \
GITHUB_ORG="myorg" \
GITHUB_PAT="ghp_xxx" \
RUNNER_LABEL="rbcz-azure" \
RUNNER_GROUP_ID=7 \
HANDOFF_DIR="./handoff" \
./github-actions-runner/init.sh

# Docker test
docker run --rm \
  -e RUNNER_SCOPE=org \
  -e GITHUB_ORG=myorg \
  -e GITHUB_PAT=ghp_xxx \
  -e RUNNER_LABEL=rbcz-azure \
  -e RUNNER_GROUP_ID=7 \
  -v /tmp/handoff:/handoff \
  <registry>/runner-init:latest

# Check generated JIT config
cat /tmp/handoff/jit
```

### Repository-Level Runners

```bash
# Auto-discovery (checks all accessible repos)
RUNNER_SCOPE="repo" \
GITHUB_OWNER="myorg" \
GITHUB_PAT="ghp_xxx" \
RUNNER_LABEL="rbcz-azure" \
HANDOFF_DIR="./handoff" \
./github-actions-runner/init.sh

# With specific repos filter (faster)
RUNNER_SCOPE="repo" \
GITHUB_OWNER="myorg" \
GITHUB_REPOS="repo1,repo2" \
GITHUB_PAT="ghp_xxx" \
RUNNER_LABEL="rbcz-azure" \
HANDOFF_DIR="./handoff" \
./github-actions-runner/init.sh

# Docker test
docker run --rm \
  -e RUNNER_SCOPE=repo \
  -e GITHUB_OWNER=myorg \
  -e GITHUB_REPOS=repo1,repo2 \
  -e GITHUB_PAT=ghp_xxx \
  -e RUNNER_LABEL=rbcz-azure \
  -v /tmp/handoff:/handoff \
  <registry>/runner-init:latest
```

To test the runner container (after init generates JIT config):

```bash
docker run --rm \
  -v /tmp/handoff:/mnt/reg-token-store:ro \
  <registry>/github-runner:latest
```

## Important Notes

- Both containers must use the same base image version to ensure `runner` user/group IDs match
- The handoff directory must be readable by the `runner` user (UID/GID from base image)
- JIT configs are single-use and ephemeral - each runner gets a unique config
- Azure Container Apps mounts the shared volume from `$HANDOFF_DIR` to `/mnt/reg-token-store` in the runner container
- **Runner label**: Set via `RUNNER_LABEL` environment variable (single string, not JSON)
- **PAT-only authentication**: GitHub App authentication has been removed for simplicity
- **Organization runners**: Require `admin:org` PAT scope and explicit `RUNNER_GROUP_ID`
- **Repository runners**: Require `repo` PAT scope, always use runner_group_id: 1
- **Repository discovery**: For repo scope, the init script queries GitHub API to find repositories with matching queued workflows
- **Rate limiting**: Repository discovery can consume API rate limit - use `GITHUB_REPOS` filter to minimize API calls
- **KEDA configuration**: KEDA determines *when* to scale but doesn't pass repository context to init containers in standard setup

## Troubleshooting

### Line Ending Issues

**Problem:** `/bin/sh: 0: Illegal option -` or similar shell parsing errors

**Solution:** All shell scripts must use Unix (LF) line endings, not Windows (CRLF). Fix with:
```bash
sed -i 's/\r$//' github-actions-runner/init.sh
sed -i 's/\r$//' github-actions-runner/entrypoint.sh
```

### Permission Issues

**Problem:** Cannot modify permissions on `/mnt/reg-token-store` or `HANDOFF_DIR`

**Solution:** These directories are mounted by Azure Container Apps and should NOT have permissions modified by the init script. The `umask` setting in init.sh is sufficient for file permissions. Do not use `chmod` on the mounted directory.