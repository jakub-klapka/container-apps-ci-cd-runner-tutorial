#!/usr/bin/env bash
# Mint JIT runner config (preferred) or classic registration token for an org runner
# Deps: bash, curl, openssl. Optional: python3 (only for resolving runner group by NAME).
set -euo pipefail
set -x

# -------- Inputs --------
: "${GITHUB_APP_ID:?missing GITHUB_APP_ID (App ID integer)}"
: "${GITHUB_INSTALLATION_ID:?missing GITHUB_INSTALLATION_ID}"
: "${GITHUB_ORG:?missing GITHUB_ORG (org login)}"
: "${GITHUB_APP_PRIVATE_KEY_PEM:?missing GITHUB_APP_PRIVATE_KEY_PEM (path OR inline PEM)}"

RUNNER_GROUP_NAME="${RUNNER_GROUP_NAME:-}"     # optional if RUNNER_GROUP_ID provided
RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-}"         # recommended to set explicitly
RUNNER_NAME="${RUNNER_NAME:-jit-$(hostname)-$RANDOM}"
RUNNER_LABELS_JSON='["rbcz-azure"]'            # your requested label
HANDOFF_DIR="${HANDOFF_DIR:-/handoff}"

API="https://api.github.com"
API_VERSION="2022-11-28"

# -------- Helpers --------
have_python() { command -v python3 >/dev/null 2>&1; }

json_get() {
  local key="$1"
  if have_python; then
    python3 -c 'import sys,json; k=sys.argv[1]; d=json.load(sys.stdin); v=d.get(k,""); print(v if not isinstance(v,(dict,list)) else json.dumps(v,separators=(",",":")))' "$key"
  else
    echo "ERROR: python3 not found; cannot parse JSON. Install python3." >&2
    exit 2
  fi
}

find_group_id_by_name() {
  local name="$1"
  if ! have_python; then
    echo "ERROR: python3 required to resolve runner group by name; set RUNNER_GROUP_ID instead." >&2
    exit 2
  fi
  python3 -c 'import sys,json; name=sys.argv[1]; data=json.load(sys.stdin)
for g in data.get("runner_groups",[]):
  if g.get("name")==name:
    print(g.get("id")); sys.exit(0)
sys.exit(3)' "$name"
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Accept GITHUB_APP_PRIVATE_KEY_PEM as a path or inline PEM
KEY_TMP=""
cleanup_key() {
  if [ -n "$KEY_TMP" ]; then
    if command -v shred >/dev/null 2>&1; then shred -u "$KEY_TMP" || rm -f "$KEY_TMP"; else rm -f "$KEY_TMP"; fi
  fi
}
trap cleanup_key EXIT

resolve_key_path() {
  local val="$1"
  # If it's a readable file path, use it directly
  if [ -f "$val" ]; then
    printf '%s\n' "$val"
    return
  fi

  # Otherwise treat it as inline PEM; normalize \r and '\n' sequences
  # Replace literal backslash-n with real newline; strip \r
  local pem
  pem="$(printf '%s' "$val" | sed 's/\\r//g; s/\\n/\n/g')"

  # Quick sanity check: header must look like BEGIN ... PRIVATE KEY
  if ! printf '%s' "$pem" | grep -q '^-----BEGIN .*PRIVATE KEY-----'; then
    echo "ERROR: GITHUB_APP_PRIVATE_KEY_PEM is neither a readable file nor valid PEM content." >&2
    exit 1
  fi

  KEY_TMP="$(mktemp)"
  chmod 600 "$KEY_TMP"
  # Ensure trailing newline so OpenSSL is happy
  printf '%s\n' "$pem" > "$KEY_TMP"
  printf '%s\n' "$KEY_TMP"
}


KEY_PATH="$(resolve_key_path "$GITHUB_APP_PRIVATE_KEY_PEM")"

make_jwt() {
  local now iat exp header payload unsigned sig passin
  now=$(date +%s); iat=$((now-60)); exp=$((now+540))
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$iat" "$exp" "$GITHUB_APP_ID")
  unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  passin="pass:"  # no prompt; empty passphrase by default
  if [ -n "${GITHUB_APP_KEY_PASSPHRASE:-}" ]; then passin="pass:${GITHUB_APP_KEY_PASSPHRASE}"; fi
  sig="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$KEY_PATH" -passin "$passin" -binary | b64url)"
  printf '%s.%s\n' "$unsigned" "$sig"
}

mkdir -p "$HANDOFF_DIR"; chmod 700 "$HANDOFF_DIR"

# 1) App JWT
JWT="$(make_jwt)"

# 2) Installation access token
INSTALL_TOKEN="$(
  curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $JWT" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API/app/installations/$GITHUB_INSTALLATION_ID/access_tokens" \
  | json_get token
)"
[ -n "$INSTALL_TOKEN" ] || { echo "Failed to get installation access token"; exit 1; }

auth_hdr=(-H "Accept: application/vnd.github+json" -H "Authorization: Bearer $INSTALL_TOKEN" -H "X-GitHub-Api-Version: $API_VERSION")

# 3) If you want org-level Default group with classic token, leave RUNNER_GROUP_ID empty and skip JIT.
if [ -z "${RUNNER_GROUP_ID:-}" ] && [ -z "${RUNNER_GROUP_NAME:-}" ]; then
  REG_TOKEN="$(
    curl -fsSL -X POST "${auth_hdr[@]}" \
      "$API/orgs/$GITHUB_ORG/actions/runners/registration-token" \
    | json_get token
  )"
  [ -n "$REG_TOKEN" ]
  umask 077
  printf '%s' "$REG_TOKEN" > "$HANDOFF_DIR/regtoken"
  echo "OK: wrote org reg token to $HANDOFF_DIR/regtoken (runner will join Default group)."
  exit 0
fi

# 4) Otherwise resolve runner group (by ID or NAME) and generate JIT config
if [ -z "${RUNNER_GROUP_ID:-}" ] && [ -n "${RUNNER_GROUP_NAME:-}" ]; then
  RUNNER_GROUP_ID="$(
    curl -fsSL "${auth_hdr[@]}" "$API/orgs/$GITHUB_ORG/actions/runner-groups" \
    | find_group_id_by_name "$RUNNER_GROUP_NAME" || true
  )"
fi
if [ -z "${RUNNER_GROUP_ID:-}" ]; then
  echo "ERROR: Provide RUNNER_GROUP_ID or a valid RUNNER_GROUP_NAME (requires python3), or leave both empty to use classic org token." >&2
  exit 1
fi

JIT_BODY=$(printf '{"name":"%s","runner_group_id":%s,"labels":%s,"work_folder":"_work"}' \
                  "$RUNNER_NAME" "$RUNNER_GROUP_ID" "$RUNNER_LABELS_JSON")

set +e
JIT_RESP="$(
  curl -fsS -X POST "${auth_hdr[@]}" -d "$JIT_BODY" \
    "$API/orgs/$GITHUB_ORG/actions/runners/generate-jitconfig"
)"
rc=$?
set -e

if [ $rc -eq 0 ]; then
  ENCODED_JIT="$(printf '%s' "$JIT_RESP" | json_get encoded_jit_config)"
  [ -n "$ENCODED_JIT" ]
  umask 077
  printf '%s' "$ENCODED_JIT" > "$HANDOFF_DIR/jit"
  echo "OK: wrote JIT config to $HANDOFF_DIR/jit for runner '$RUNNER_NAME' (labels: $RUNNER_LABELS_JSON)."
  exit 0
fi

echo "WARN: JIT config failed; falling back to classic registration token…" >&2
REG_TOKEN="$(
  curl -fsSL -X POST "${auth_hdr[@]}" \
    "$API/orgs/$GITHUB_ORG/actions/runners/registration-token" \
  | json_get token
)"
[ -n "$REG_TOKEN" ]
umask 077
printf '%s' "$REG_TOKEN" > "$HANDOFF_DIR/regtoken"
echo "OK: wrote registration token to $HANDOFF_DIR/regtoken for runner '$RUNNER_NAME'."


