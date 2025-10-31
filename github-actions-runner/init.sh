#!/usr/bin/env bash
# Generate JIT runner configuration for GitHub Actions organization-level runners
# Deps: bash, curl, openssl. Optional: python3 (for JSON parsing / group name lookup).
set -euo pipefail
set -x

# -------- Inputs --------
: "${GITHUB_ORG:?missing GITHUB_ORG (org login)}"
GITHUB_PAT="${GITHUB_PAT:-}"                         # optional; if set we use PAT mode

RUNNER_GROUP_NAME="${RUNNER_GROUP_NAME:-}"           # optional if RUNNER_GROUP_ID provided
RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-}"               # recommended to set explicitly for JIT
RUNNER_NAME="${RUNNER_NAME:-jit-$(hostname)-$RANDOM}"
RUNNER_LABELS_JSON='["rbcz-azure"]'                  # your requested label
HANDOFF_DIR="${HANDOFF_DIR:-/handoff}"

API="https://api.github.com"
API_VERSION="2022-11-28"

# -------- Helpers --------
have_python() { command -v python3 >/dev/null 2>&1; }

# Trim helper (so spaces-only PAT is treated as empty)
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

json_get() {
  local key="$1"
  local json_data
  # Read stdin into variable before heredoc takes over stdin
  json_data="$(cat)"
  if have_python; then
    python3 - "$key" "$json_data" <<'PY'
import sys, json
k = sys.argv[1]
input_data = sys.argv[2] if len(sys.argv) > 2 else ""
if not input_data or not input_data.strip():
    print(f'ERROR: Empty response from API call. Check your credentials and API endpoint.', file=sys.stderr)
    sys.exit(2)
try:
    d = json.loads(input_data)
except json.JSONDecodeError as e:
    print(f'ERROR: Invalid JSON response: {e}', file=sys.stderr)
    print(f'Received: {input_data[:200]}', file=sys.stderr)
    sys.exit(2)
v = d.get(k, '')
print(v if not isinstance(v, (dict, list)) else json.dumps(v, separators=(',',':')))
PY
  else
    echo "ERROR: python3 not found; cannot parse JSON." >&2
    exit 2
  fi
}

find_group_id_by_name() {
  local name="$1"
  if ! have_python; then
    echo "ERROR: python3 required to resolve runner group by name; set RUNNER_GROUP_ID instead." >&2
    exit 2
  fi
  python3 - "$name" <<'PY'
import sys, json
name = sys.argv[1]
data = json.load(sys.stdin)
for g in data.get("runner_groups", []):
    if g.get("name") == name:
        print(g.get("id"))
        sys.exit(0)
sys.exit(3)
PY
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Accept GITHUB_APP_PRIVATE_KEY_PEM as a path or inline PEM (App mode only)
KEY_TMP=""
cleanup_key() {
  if [ -n "$KEY_TMP" ]; then
    if command -v shred >/dev/null 2>&1; then shred -u "$KEY_TMP" || rm -f "$KEY_TMP"; else rm -f "$KEY_TMP"; fi
  fi
}
trap cleanup_key EXIT

resolve_key_path() {
  local val="$1"
  # File path
  if [ -f "$val" ]; then
    printf '%s\n' "$val"
    return
  fi
  # Inline PEM: normalize \r and literal \n
  local pem
  pem="$(printf '%s' "$val" | sed 's/\\r//g; s/\\n/\n/g')"
  if ! printf '%s' "$pem" | grep -q '^-----BEGIN .*PRIVATE KEY-----'; then
    echo "ERROR: GITHUB_APP_PRIVATE_KEY_PEM is neither a readable file nor valid PEM content." >&2
    exit 1
  fi
  KEY_TMP="$(mktemp)"
  chmod 600 "$KEY_TMP"
  printf '%s\n' "$pem" > "$KEY_TMP"
  printf '%s\n' "$KEY_TMP"
}

make_jwt_with_key() {
  local key_path="$1"
  local now iat exp header payload unsigned sig passin
  now=$(date +%s); iat=$((now-60)); exp=$((now+540))
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$iat" "$exp" "$GITHUB_APP_ID")
  unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  passin="pass:"  # no prompt; empty passphrase by default
  if [ -n "${GITHUB_APP_KEY_PASSPHRASE:-}" ]; then passin="pass:${GITHUB_APP_KEY_PASSPHRASE}"; fi
  sig="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key_path" -passin "$passin" -binary | b64url)"
  printf '%s.%s\n' "$unsigned" "$sig"
}

# ---------- Auth mode: PAT or GitHub App ----------
USE_PAT=false
if [ -n "$(trim "${GITHUB_PAT}")" ]; then
  USE_PAT=true
fi

if $USE_PAT; then
  INSTALL_TOKEN="$(trim "${GITHUB_PAT}")"
  # Ensure nothing later tries to touch App credentials
  unset GITHUB_APP_ID GITHUB_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PEM GITHUB_APP_KEY_PASSPHRASE || true
else
  # App mode requires these:
  : "${GITHUB_APP_ID:?missing GITHUB_APP_ID (App ID integer)}"
  : "${GITHUB_INSTALLATION_ID:?missing GITHUB_INSTALLATION_ID}"
  : "${GITHUB_APP_PRIVATE_KEY_PEM:?missing GITHUB_APP_PRIVATE_KEY_PEM (path OR inline PEM)}"
  KEY_PATH="$(resolve_key_path "$GITHUB_APP_PRIVATE_KEY_PEM")"
  JWT="$(make_jwt_with_key "$KEY_PATH")"
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

echo "INFO: Using organization-level runner registration for $GITHUB_ORG"

# ---------- Determine runner group ID ----------
if [ -z "${RUNNER_GROUP_ID:-}" ] && [ -z "${RUNNER_GROUP_NAME:-}" ]; then
  # Default to group 1 if not specified
  RUNNER_GROUP_ID=1
  echo "INFO: Using default runner group (ID: 1)"
elif [ -z "${RUNNER_GROUP_ID:-}" ] && [ -n "${RUNNER_GROUP_NAME:-}" ]; then
  # Resolve by name
  RUNNER_GROUP_ID="$(
    curl -fsSL "${auth_hdr[@]}" "$API/orgs/$GITHUB_ORG/actions/runner-groups" \
    | find_group_id_by_name "$RUNNER_GROUP_NAME"
  )"
  if [ -z "${RUNNER_GROUP_ID:-}" ]; then
    echo "ERROR: Could not find runner group named '$RUNNER_GROUP_NAME'" >&2
    exit 1
  fi
  echo "INFO: Resolved runner group '$RUNNER_GROUP_NAME' to ID: $RUNNER_GROUP_ID"
else
  echo "INFO: Using runner group ID: $RUNNER_GROUP_ID"
fi

# ---------- Generate JIT config ----------
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
chmod 755 "$HANDOFF_DIR" || true
chmod 644 "$HANDOFF_DIR/jit" || true
echo "OK: wrote JIT config to $HANDOFF_DIR/jit for runner '$RUNNER_NAME' in group $RUNNER_GROUP_ID (labels: $RUNNER_LABELS_JSON)."
