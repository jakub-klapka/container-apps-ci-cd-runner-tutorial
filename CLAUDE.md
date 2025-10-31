# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a tutorial repository for deploying self-hosted GitHub Actions runners on Azure Container Apps jobs. The repository demonstrates a two-container pattern:

1. **Init Container** (`Dockerfile.init`) - Handles authentication and generates JIT (Just-In-Time) runner configurations or registration tokens
2. **Runner Container** (`Dockerfile.github`) - Executes the actual GitHub Actions workflows

See the [official tutorial](https://learn.microsoft.com/azure/container-apps/tutorial-ci-cd-runners-jobs) for deployment context.

## Key Files

### Dockerfiles

- **`Dockerfile.init`** - Init container that runs `init.sh` to generate runner credentials
  - Base: `ghcr.io/actions/actions-runner:2.329.0`
  - Installs: curl, openssl, python3, ca-certificates
  - Entrypoint: `/init.sh`
  - Runs as `runner` user

- **`Dockerfile.github`** - Main runner container that executes workflows
  - Base: `ghcr.io/actions/actions-runner:2.329.0`
  - Installs: curl, jq, Azure CLI
  - Entrypoint: `entrypoint.sh`
  - Runs as `runner` user

### Scripts (`github-actions-runner/`)

- **`init.sh`** - Authentication and JIT config generation script
  - **Organization-level runners only**
  - Supports both GitHub PAT and GitHub App authentication
  - Generates JIT config exclusively (no classic registration tokens)
  - Writes JIT config to `/handoff` directory (default) for the runner container
  - Environment variables:
    - Required: `GITHUB_ORG` (organization login)
    - Auth mode: `GITHUB_PAT` (Personal Access Token) or `GITHUB_APP_ID` + `GITHUB_INSTALLATION_ID` + `GITHUB_APP_PRIVATE_KEY_PEM`
    - Optional: `RUNNER_GROUP_ID` (defaults to 1), `RUNNER_GROUP_NAME`, `RUNNER_NAME`, `RUNNER_LABELS_JSON`, `HANDOFF_DIR`
  - Default label: `["rbcz-azure"]` (hardcoded)

- **`entrypoint.sh`** - Runner startup script
  - Reads JIT config from `/mnt/reg-token-store/jit` (mount path in Azure Container Apps)
  - Starts runner with: `./run.sh --jitconfig "$JIT"`

## Architecture

### Two-Container Init Pattern

1. **Init container** runs first:
   - Authenticates with GitHub API (PAT or App)
   - Calls GitHub API to generate JIT config or registration token
   - Writes credential file to shared volume at `$HANDOFF_DIR`

2. **Runner container** starts after init succeeds:
   - Reads credential from shared volume (mounted at `/mnt/reg-token-store/`)
   - Registers with GitHub and runs workflows
   - Self-destructs after job completion (Azure Container Apps job behavior)

### Authentication Flow

The `init.sh` script supports two authentication modes:

1. **PAT Mode** (when `GITHUB_PAT` is set): Uses Personal Access Token directly
2. **GitHub App Mode**: Uses App credentials (`GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY_PEM`) to generate installation access token

Both modes generate JIT config exclusively - no fallback to classic registration tokens.

### Runner Scope

- **Organization-level only**: Runners appear in org settings and can service any repository in the organization
- Can use custom runner groups via `RUNNER_GROUP_ID` or `RUNNER_GROUP_NAME` (defaults to group 1)

### Configuration for Azure Container Apps

When deploying with Azure Container Apps and KEDA's GitHub Runner scaler:

1. **Set `GITHUB_ORG`** (required) - Your GitHub organization login
2. **Set `RUNNER_GROUP_ID`** (optional) - Organize runners by group (defaults to 1)
3. **Set `GITHUB_PAT`** - Personal Access Token with appropriate permissions

**Why organization-level?**
- KEDA scalers determine *when* to scale based on workflow queue depth
- Repository information from triggering workflows is not available to init containers
- Org-level runners can service any repository in your organization automatically

See `ARCHITECTURE.md` for detailed technical explanation of KEDA scaler design.

## Building Images on Azure Container Registry

**Current version: 21.0** (increment by 1 for each build)

**⚠️ Important Build Workflow:**

1. **Commit and push changes to GitHub first** - ACR build pulls from the remote repository
2. **Then run the ACR build command** - Uses the latest code from GitHub
3. **Update version tracking in CLAUDE.md** - Document the new version

```bash
# Set your registry name
CONTAINER_REGISTRY_NAME="your-acr-name"

# 1. First: Commit and push your changes
git add .
git commit -m "Your commit message"
git push origin main

# 2. Then: Build init container (increment version number for each build)
az acr build \
    --registry "$CONTAINER_REGISTRY_NAME" \
    --image "github-actions-init:22.0" \
    --file "Dockerfile.init" \
    "https://github.com/jakub-klapka/container-apps-ci-cd-runner-tutorial.git"

# Build runner container
az acr build \
    --registry "$CONTAINER_REGISTRY_NAME" \
    --image "github-actions-runner:22.0" \
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

To test the init script locally:

```bash
# With default runner group (ID: 1)
docker run --rm \
  -e GITHUB_ORG=myorg \
  -e GITHUB_PAT=ghp_xxx \
  -v /tmp/handoff:/handoff \
  <registry>/runner-init:latest

# With custom runner group
docker run --rm \
  -e GITHUB_ORG=myorg \
  -e GITHUB_PAT=ghp_xxx \
  -e RUNNER_GROUP_ID=7 \
  -v /tmp/handoff:/handoff \
  <registry>/runner-init:latest

# Check generated JIT config
cat /tmp/handoff/jit
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
- The default runner label `rbcz-azure` is hardcoded in `init.sh` - modify as needed for your use case
- Azure Container Apps mounts the shared volume from `$HANDOFF_DIR` to `/mnt/reg-token-store` in the runner container
- Runners register at organization level and can service any repository in your organization
- Use `RUNNER_GROUP_ID` to organize runners (defaults to 1 if not specified)
- dont change the permissions on handoff dir, since its mouned by aca