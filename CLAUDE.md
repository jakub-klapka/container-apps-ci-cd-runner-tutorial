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
  - Supports both GitHub PAT and GitHub App authentication
  - Generates JIT config exclusively (no fallback to classic tokens)
  - Supports both org-level and repo-level runner registration
  - Writes JIT config to `/handoff` directory (default) for the runner container
  - Environment variables:
    - Scope selection (priority order):
      - `GITHUB_ORG` - Use org-level registration (takes precedence)
      - `GITHUB_REPOSITORY` - Use repo-level registration (format: owner/repo, auto-set by ACA scaler)
    - Auth mode: `GITHUB_PAT` (Personal Access Token) or `GITHUB_APP_ID` + `GITHUB_INSTALLATION_ID` + `GITHUB_APP_PRIVATE_KEY_PEM`
    - Optional: `RUNNER_GROUP_ID` (org-level only, defaults to 1), `RUNNER_GROUP_NAME` (org-level only), `RUNNER_NAME`, `RUNNER_LABELS_JSON`, `HANDOFF_DIR`
  - Default label: `["rbcz-azure"]` (hardcoded)
  - Repo-level runners always use runner_group_id: 1 (default)

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

- **Organization-level** (when `GITHUB_ORG` is set): Runners appear in org settings, can use custom runner groups
- **Repository-level** (when `GITHUB_REPOSITORY` is set): Runners appear in repo settings, use default group (ID: 1)
- Priority: `GITHUB_ORG` takes precedence if both are set

## Building Images on Azure Container Registry

**Current version: 16.0** (increment by 1 for each build)

```bash
# Set your registry name
CONTAINER_REGISTRY_NAME="your-acr-name"

# Build init container (increment version number for each build)
az acr build \
    --registry "$CONTAINER_REGISTRY_NAME" \
    --image "github-actions-init:17.0" \
    --file "Dockerfile.init" \
    "https://github.com/jakub-klapka/container-apps-ci-cd-runner-tutorial.git"

# Build runner container
az acr build \
    --registry "$CONTAINER_REGISTRY_NAME" \
    --image "github-actions-runner:17.0" \
    --file "Dockerfile.github" \
    "https://github.com/jakub-klapka/container-apps-ci-cd-runner-tutorial.git"
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
# Org-level with custom runner group
docker run --rm \
  -e GITHUB_ORG=myorg \
  -e GITHUB_PAT=ghp_xxx \
  -e RUNNER_GROUP_ID=7 \
  -v /tmp/handoff:/handoff \
  <registry>/runner-init:latest

# Repo-level (uses default group ID: 1)
docker run --rm \
  -e GITHUB_REPOSITORY=owner/repo \
  -e GITHUB_PAT=ghp_xxx \
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
- When ACA scaler sets `GITHUB_REPOSITORY`, runners automatically register at repo-level
- For org-level runners with custom groups, explicitly set `GITHUB_ORG` and `RUNNER_GROUP_ID`
