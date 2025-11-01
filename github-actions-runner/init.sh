#!/usr/bin/env bash
# Generate JIT runner config for an organization-level GitHub Actions runner
# Deps: bash, curl, openssl, jq
set -euo pipefail

# -------- Inputs --------
: "${GITHUB_ORG:?missing GITHUB_ORG (org login)}"
: "${RUNNER_GROUP_ID:?missing RUNNER_GROUP_ID (runner group ID)}"

GITHUB_PAT="${GITHUB_PAT:-}"                         # optional; if set we use PAT mode
RUNNER_NAME="${RUNNER_NAME:-jit-$(hostname)-$RANDOM}"
RUNNER_LABELS_JSON='["rbcz-azure"]'
HANDOFF_DIR="${HANDOFF_DIR:-/handoff}"
API="${API:-https://api.github.com}"
API_VERSION="2022-11-28"

echo "==> Initializing GitHub Actions runner configuration"
echo "    Organization: $GITHUB_ORG"
echo "    Runner Group ID: $RUNNER_GROUP_ID"
echo "    Runner Name: $RUNNER_NAME"
echo "    Labels: $RUNNER_LABELS_JSON"

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

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

make_jwt_with_key() {
  local now iat exp header payload unsigned sig passin key_tmp
  now=$(date +%s); iat=$((now-60)); exp=$((now+540))
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$iat" "$exp" "$GITHUB_APP_ID")
  unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  passin="pass:"  # no prompt; empty passphrase by default
  if [ -n "${GITHUB_APP_KEY_PASSPHRASE:-}" ]; then passin="pass:${GITHUB_APP_KEY_PASSPHRASE}"; fi

  # Write PEM to temp file for signing
  key_tmp="$(mktemp)"
  chmod 600 "$key_tmp"
  printf '%s\n' "$GITHUB_APP_PRIVATE_KEY_PEM" | sed 's/\\r//g; s/\\n/\n/g' > "$key_tmp"

  sig="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key_tmp" -passin "$passin" -binary | b64url)"

  # Cleanup temp key file
  if command -v shred >/dev/null 2>&1; then shred -u "$key_tmp" || rm -f "$key_tmp"; else rm -f "$key_tmp"; fi

  printf '%s.%s\n' "$unsigned" "$sig"
}

# ---------- Auth mode: PAT or GitHub App ----------
USE_PAT=false
if [ -n "${GITHUB_PAT}" ]; then
  USE_PAT=true
fi

if $USE_PAT; then
  echo "==> Using Personal Access Token (PAT) authentication"
  INSTALL_TOKEN="${GITHUB_PAT}"
  # Ensure nothing later tries to touch App credentials
  unset GITHUB_APP_ID GITHUB_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PEM GITHUB_APP_KEY_PASSPHRASE || true
else
  echo "==> Using GitHub App authentication"
  # App mode requires these:
  : "${GITHUB_APP_ID:?missing GITHUB_APP_ID (App ID integer)}"
  : "${GITHUB_INSTALLATION_ID:?missing GITHUB_INSTALLATION_ID}"
  : "${GITHUB_APP_PRIVATE_KEY_PEM:?missing GITHUB_APP_PRIVATE_KEY_PEM (inline PEM)}"
  echo "    App ID: $GITHUB_APP_ID"
  echo "    Installation ID: $GITHUB_INSTALLATION_ID"
  echo "==> Generating JWT for GitHub App authentication"
  JWT="$(make_jwt_with_key)"
  echo "==> Obtaining installation access token"
  INSTALL_TOKEN="$(
    curl -fsSL -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $JWT" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API/app/installations/$GITHUB_INSTALLATION_ID/access_tokens" \
    | json_get token
  )"
fi

if [ -z "$INSTALL_TOKEN" ]; then
  echo "ERROR: Failed to obtain auth token" >&2
  echo "Check your GITHUB_PAT or GitHub App credentials (GITHUB_APP_ID, GITHUB_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_PEM)" >&2
  exit 1
fi
auth_hdr=(-H "Accept: application/vnd.github+json" -H "Authorization: Bearer $INSTALL_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION")

# ---------- Generate JIT config ----------
echo "==> Generating JIT runner configuration"
JIT_BODY=$(printf '{"name":"%s","runner_group_id":%s,"labels":%s,"work_folder":"_work"}' \
                  "$RUNNER_NAME" "$RUNNER_GROUP_ID" "$RUNNER_LABELS_JSON")

JIT_RESP="$(
  curl -fsSL -X POST "${auth_hdr[@]}" -d "$JIT_BODY" \
    "$API/orgs/$GITHUB_ORG/actions/runners/generate-jitconfig"
)"

ENCODED_JIT="$(printf '%s' "$JIT_RESP" | json_get encoded_jit_config)"
[ -n "$ENCODED_JIT" ] || { echo "ERROR: Failed to generate JIT config" >&2; exit 1; }

umask 077
printf '%s' "$ENCODED_JIT" > "$HANDOFF_DIR/jit"
echo "==> Successfully created JIT configuration"
echo "    Written to: $HANDOFF_DIR/jit"
echo "    Runner: $RUNNER_NAME"
echo "    Group ID: $RUNNER_GROUP_ID"
echo "    Labels: $RUNNER_LABELS_JSON"
