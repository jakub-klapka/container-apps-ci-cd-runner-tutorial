#!/bin/bash
#
# Generates JIT (Just-In-Time) configuration for GitHub Actions self-hosted runners.
# Supports org-level or repo-level runners. In repo mode, discovers target repository
# by scanning for queued workflow jobs matching the specified RUNNER_LABEL.
# Authenticates via GitHub PAT and writes encoded JIT config to handoff directory.
#
# Generate JIT runner config for GitHub Actions runners (org or repo level)
# Deps: bash, curl, jq
set -euo pipefail

# -------- Inputs --------
# Runner scope: 'org' for organization-level or 'repo' for repository-level runner
RUNNER_SCOPE="${RUNNER_SCOPE:-org}"
# GitHub organization name (required for both org and repo modes)
# GITHUB_ORG=your-org-name
# GitHub Personal Access Token with repo permissions (Actions: read, Administration: read/write)
: "${GITHUB_PAT:?missing GITHUB_PAT}"
# Custom label to identify and match queued workflow jobs (e.g., 'azure')
: "${RUNNER_LABEL:?missing RUNNER_LABEL (custom label string)}"
# Name for the runner instance (auto-generated if not specified)
RUNNER_NAME="${RUNNER_NAME:-jit-$( { command -v hostname >/dev/null && hostname || cat /etc/hostname 2>/dev/null || uname -n; } )-$RANDOM}"
# Full path to write the JIT config file (including filename)
JIT_TOKEN_PATH="${JIT_TOKEN_PATH:-/mnt/jit-token-store/jit}"
# GitHub API endpoint URL
API="${API:-https://api.github.com}"
# GitHub API version for request headers
API_VERSION="2022-11-28"
# Required: comma-separated list of repository names to check for queued jobs
# GITHUB_REPOS=repo1,repo2,repo3
# Optional: runner group ID for org mode (required for org-level runners)
# RUNNER_GROUP_ID=123

# Validate scope
if [ "$RUNNER_SCOPE" != "org" ] && [ "$RUNNER_SCOPE" != "repo" ]; then
  echo "ERROR: RUNNER_SCOPE must be 'org' or 'repo'" >&2
  exit 1
fi

# Mode-specific validation
# Organization name (required for both org and repo modes)
: "${GITHUB_ORG:?missing GITHUB_ORG (organization name)}"
# Repository list (required for both org and repo modes)
: "${GITHUB_REPOS:?missing GITHUB_REPOS (comma-separated list of repository names)}"

if [ "$RUNNER_SCOPE" = "org" ]; then
  # Runner group ID from GitHub org settings (required for org-level runners)
  : "${RUNNER_GROUP_ID:?missing RUNNER_GROUP_ID (runner group ID)}"
else
  # For repo runners, always use group ID 1 (default group)
  RUNNER_GROUP_ID=1
fi

# -------- Helpers --------
check_rate_limit() {
  local response
  response=$(curl -fsSL \
    -H "Authorization: Bearer $GITHUB_PAT" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API/rate_limit")

  local remaining
  remaining=$(echo "$response" | jq -r '.rate.remaining')

  if [ "$remaining" -lt 50 ]; then
    echo "ERROR: GitHub API rate limit nearly exhausted (remaining: $remaining)" >&2
    local reset_time
    reset_time=$(echo "$response" | jq -r '.rate.reset')
    echo "Rate limit resets at: $(date -d @"$reset_time" 2>/dev/null || date -r "$reset_time" 2>/dev/null)" >&2
    exit 1
  fi
}

get_queued_runs() {
  local repo="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_PAT" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API/repos/$GITHUB_ORG/$repo/actions/runs?status=queued&per_page=100" \
    | jq -r '.workflow_runs[]?.id // empty'
}

get_job_labels() {
  local repo="$1"
  local run_id="$2"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_PAT" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API/repos/$GITHUB_ORG/$repo/actions/runs/$run_id/jobs?per_page=100" \
    | jq -r '.jobs[]? | select(.status == "queued") | .labels[]? // empty'
}

find_matching_repo() {
  echo "==> Discovering repository with matching queued jobs" >&2

  # Parse GITHUB_REPOS: convert comma-separated to newline-separated and trim spaces
  local repos
  repos=$(echo "$GITHUB_REPOS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [ -z "$repos" ]; then
    echo "ERROR: GITHUB_REPOS is empty after parsing" >&2
    return 1
  fi

  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    echo "    Checking $GITHUB_ORG/$repo..." >&2

    local runs
    runs=$(get_queued_runs "$repo")

    if [ -z "$runs" ]; then
      echo "      No queued runs" >&2
      continue
    fi

    local run_count
    run_count=$(echo "$runs" | wc -l)
    echo "      Found $run_count queued run(s)" >&2

    while IFS= read -r run_id; do
      [ -z "$run_id" ] && continue
      echo "      Run $run_id: checking jobs..." >&2

      local labels
      labels=$(get_job_labels "$repo" "$run_id")

      if echo "$labels" | grep -qx "$RUNNER_LABEL"; then
        echo "      ✓ MATCH found on label '$RUNNER_LABEL'!" >&2
        echo "$repo"
        return 0
      fi
    done <<< "$runs"
  done <<< "$repos"

  return 1
}

# -------- Initialization --------
echo "==> Initializing GitHub Actions runner"
echo "    Scope: $RUNNER_SCOPE"
echo "    Label: $RUNNER_LABEL"
echo "    Runner Name: $RUNNER_NAME"

echo "    Organization: $GITHUB_ORG"
echo "    Target Repos: $GITHUB_REPOS"

if [ "$RUNNER_SCOPE" = "org" ]; then
  echo "    Runner Group ID: $RUNNER_GROUP_ID"
fi

echo "==> Using Personal Access Token (PAT) authentication"
INSTALL_TOKEN="$GITHUB_PAT"

# -------- Repository Discovery (repo mode only) --------
if [ "$RUNNER_SCOPE" = "repo" ]; then
  check_rate_limit

  GITHUB_REPO=$(find_matching_repo)

  if [ -z "$GITHUB_REPO" ]; then
    echo "ERROR: No repository found with queued jobs matching label '$RUNNER_LABEL'" >&2
    exit 1
  fi

  echo "==> Selected repository: $GITHUB_ORG/$GITHUB_REPO"
fi

# -------- Generate JIT config --------
echo "==> Generating JIT runner configuration"

if [ "$RUNNER_SCOPE" = "org" ]; then
  check_rate_limit
  JIT_ENDPOINT="$API/orgs/$GITHUB_ORG/actions/runners/generate-jitconfig"
else
  JIT_ENDPOINT="$API/repos/$GITHUB_ORG/$GITHUB_REPO/actions/runners/generate-jitconfig"
fi

JIT_BODY=$(printf '{"name":"%s","runner_group_id":%s,"labels":["%s"],"work_folder":"_work"}' \
                  "$RUNNER_NAME" "$RUNNER_GROUP_ID" "$RUNNER_LABEL")

JIT_RESP=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $INSTALL_TOKEN" \
  -H "X-GitHub-Api-Version: $API_VERSION" \
  -d "$JIT_BODY" \
  "$JIT_ENDPOINT")

ENCODED_JIT=$(echo "$JIT_RESP" | jq -r '.encoded_jit_config // empty')
[ -n "$ENCODED_JIT" ] || {
  echo "ERROR: Failed to generate JIT config" >&2
  echo "Response: ${JIT_RESP:0:500}" >&2
  exit 1
}

umask 077
printf '%s' "$ENCODED_JIT" > "$JIT_TOKEN_PATH"

echo "==> Successfully created JIT configuration"
echo "    Written to: $JIT_TOKEN_PATH"
if [ "$RUNNER_SCOPE" = "org" ]; then
  echo "    Organization: $GITHUB_ORG"
  echo "    Group ID: $RUNNER_GROUP_ID"
else
  echo "    Repository: $GITHUB_ORG/$GITHUB_REPO"
fi
echo "    Runner: $RUNNER_NAME"
echo "    Label: $RUNNER_LABEL"
