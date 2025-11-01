#!/usr/bin/env bash
# Generate JIT runner config for GitHub Actions runners (org or repo level)
# Deps: bash, curl, jq
set -euo pipefail

# -------- Inputs --------
RUNNER_SCOPE="${RUNNER_SCOPE:-org}"
: "${GITHUB_PAT:?missing GITHUB_PAT}"
: "${RUNNER_LABEL:?missing RUNNER_LABEL (custom label string)}"
RUNNER_NAME="${RUNNER_NAME:-jit-$(hostname)-$RANDOM}"
HANDOFF_DIR="${HANDOFF_DIR:-/handoff}"
API="${API:-https://api.github.com}"
API_VERSION="2022-11-28"

# Validate scope
if [ "$RUNNER_SCOPE" != "org" ] && [ "$RUNNER_SCOPE" != "repo" ]; then
  echo "ERROR: RUNNER_SCOPE must be 'org' or 'repo'" >&2
  exit 1
fi

# Mode-specific validation
if [ "$RUNNER_SCOPE" = "org" ]; then
  : "${GITHUB_ORG:?missing GITHUB_ORG (organization name)}"
  : "${RUNNER_GROUP_ID:?missing RUNNER_GROUP_ID (runner group ID)}"
else
  : "${GITHUB_OWNER:?missing GITHUB_OWNER (owner/org name)}"
  RUNNER_GROUP_ID=1  # Always 1 for repo runners
fi

# -------- Helpers --------
json_get() {
  local key="$1"
  local input
  input="$(cat)"

  # Check for empty input
  if [ -z "$input" ] || [ -z "$(printf '%s' "$input" | tr -d '[:space:]')" ]; then
    echo "ERROR: Empty response from API call. Check your credentials and API endpoint." >&2
    return 2
  fi

  # Extract value with jq (raw output, empty if key doesn't exist)
  printf '%s' "$input" | jq -r ".$key // empty" 2>/dev/null || {
    echo "ERROR: Invalid JSON response or jq error." >&2
    echo "Received: ${input:0:200}" >&2
    return 2
  }
}

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

list_repositories() {
  local page=1
  local all_repos=""

  while true; do
    local response
    response=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_PAT" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API/user/repos?visibility=all&per_page=100&page=$page")

    # Check if we got any results
    local count
    count=$(echo "$response" | jq '. | length')
    [ "$count" -eq 0 ] && break

    # Extract repos for the target owner
    local page_repos
    page_repos=$(echo "$response" | jq -r ".[] | select(.owner.login == \"$GITHUB_OWNER\") | .name")

    # Add matching repos if any (page might have no matches)
    if [ -n "$page_repos" ]; then
      all_repos="$all_repos$page_repos"$'\n'
    fi

    # Continue if we got full page (means more might exist)
    [ "$count" -lt 100 ] && break

    page=$((page + 1))
  done

  # Filter by GITHUB_REPOS if specified
  if [ -n "${GITHUB_REPOS:-}" ]; then
    # Convert comma-separated list to newline-separated and trim spaces
    local filter_list
    filter_list=$(echo "$GITHUB_REPOS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$all_repos" | grep -Fx -f <(echo "$filter_list")
  else
    echo "$all_repos"
  fi
}

get_queued_runs() {
  local repo="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_PAT" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API/repos/$GITHUB_OWNER/$repo/actions/runs?status=queued&per_page=100" \
    | jq -r '.workflow_runs[]?.id // empty'
}

get_job_labels() {
  local repo="$1"
  local run_id="$2"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_PAT" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API/repos/$GITHUB_OWNER/$repo/actions/runs/$run_id/jobs?per_page=100" \
    | jq -r '.jobs[]? | select(.status == "queued") | .labels[]? // empty'
}

find_matching_repo() {
  echo "==> Discovering repository with matching queued jobs" >&2

  local repos
  repos=$(list_repositories)

  if [ -z "$repos" ]; then
    echo "ERROR: No repositories found for owner '$GITHUB_OWNER'" >&2
    return 1
  fi

  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    echo "    Checking $GITHUB_OWNER/$repo..." >&2

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

if [ "$RUNNER_SCOPE" = "org" ]; then
  echo "    Organization: $GITHUB_ORG"
  echo "    Runner Group ID: $RUNNER_GROUP_ID"
else
  echo "    Owner: $GITHUB_OWNER"
  if [ -n "${GITHUB_REPOS:-}" ]; then
    echo "    Target Repos: $GITHUB_REPOS"
  else
    echo "    Target Repos: all accessible repos"
  fi
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

  echo "==> Selected repository: $GITHUB_OWNER/$GITHUB_REPO"
fi

# -------- Generate JIT config --------
echo "==> Generating JIT runner configuration"

if [ "$RUNNER_SCOPE" = "org" ]; then
  JIT_ENDPOINT="$API/orgs/$GITHUB_ORG/actions/runners/generate-jitconfig"
else
  JIT_ENDPOINT="$API/repos/$GITHUB_OWNER/$GITHUB_REPO/actions/runners/generate-jitconfig"
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
printf '%s' "$ENCODED_JIT" > "$HANDOFF_DIR/jit"

echo "==> Successfully created JIT configuration"
echo "    Written to: $HANDOFF_DIR/jit"
if [ "$RUNNER_SCOPE" = "org" ]; then
  echo "    Organization: $GITHUB_ORG"
  echo "    Group ID: $RUNNER_GROUP_ID"
else
  echo "    Repository: $GITHUB_OWNER/$GITHUB_REPO"
fi
echo "    Runner: $RUNNER_NAME"
echo "    Label: $RUNNER_LABEL"
