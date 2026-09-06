#!/usr/bin/env bash
# Mint a short-lived Tailscale auth key for Finamp Embedded Tailscale re-enroll.
#
# Requires OAuth client credentials with devices + auth keys write access.
# Never commit secrets — load from env or a local untracked file.
#
# Dev MacBook:
#   export TS_OAUTH_CLIENT_ID='…'
#   export TS_OAUTH_CLIENT_SECRET='…'
#   # optional:
#   export TS_AUTHKEY_EXPIRY_SECONDS=259200   # 3 days (default)
#   export TS_AUTHKEY_TAGS='tag:finamp'
#   ./scripts/mint-tailscale-authkey.sh
#   ./scripts/mint-tailscale-authkey.sh --cleanup-stale --dry-run
#   ./scripts/mint-tailscale-authkey.sh --cleanup-stale   # deletes matching offline devices
#
set -euo pipefail

EXPIRY_SECONDS="${TS_AUTHKEY_EXPIRY_SECONDS:-259200}"
TAGS_CSV="${TS_AUTHKEY_TAGS:-tag:finamp}"
STALE_NAME_REGEX="${TS_STALE_DEVICE_REGEX:-^(finamp|finamp-)}"
CLEANUP_STALE=0
DRY_RUN=1
API_BASE="https://api.tailscale.com/api/v2"

usage() {
  cat <<'EOF'
Usage: mint-tailscale-authkey.sh [--cleanup-stale] [--execute] [--dry-run]

  Mint a reusable, preauthorized auth key (prints tskey-auth-…).

Env:
  TS_OAUTH_CLIENT_ID       required
  TS_OAUTH_CLIENT_SECRET   required
  TS_AUTHKEY_EXPIRY_SECONDS  default 259200 (3 days)
  TS_AUTHKEY_TAGS            comma-separated, default tag:finamp
  TS_STALE_DEVICE_REGEX      default ^(finamp|finamp-)
  TS_TAILNET                 default "-" (default tailnet for the OAuth client)

Flags:
  --cleanup-stale   also list (and with --execute, delete) offline devices
                    whose name matches TS_STALE_DEVICE_REGEX
  --dry-run         cleanup lists only (default when --cleanup-stale)
  --execute         actually delete stale devices (implies --cleanup-stale)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup-stale) CLEANUP_STALE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --execute) CLEANUP_STALE=1; DRY_RUN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}
need curl
need python3

: "${TS_OAUTH_CLIENT_ID:?Set TS_OAUTH_CLIENT_ID}"
: "${TS_OAUTH_CLIENT_SECRET:?Set TS_OAUTH_CLIENT_SECRET}"
TAILNET="${TS_TAILNET:--}"

echo "Requesting OAuth access token…" >&2
TOKEN_JSON="$(
  curl -fsS -u "${TS_OAUTH_CLIENT_ID}:${TS_OAUTH_CLIENT_SECRET}" \
    "https://api.tailscale.com/api/v2/oauth/token" \
    -d "grant_type=client_credentials"
)"
ACCESS_TOKEN="$(
  python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <<<"$TOKEN_JSON"
)"

TAG_JSON="$(
  python3 -c '
import json, os
tags = [t.strip() for t in os.environ["TAGS_CSV"].split(",") if t.strip()]
print(json.dumps(tags))
' 
)"
TAGS_CSV="$TAGS_CSV" TAG_JSON="$TAG_JSON" EXPIRY_SECONDS="$EXPIRY_SECONDS" \
python3 - <<'PY' >/dev/null
import json, os
assert json.loads(os.environ["TAG_JSON"])
PY

BODY="$(
  TAGS_CSV="$TAGS_CSV" EXPIRY_SECONDS="$EXPIRY_SECONDS" python3 - <<'PY'
import json, os
tags = [t.strip() for t in os.environ["TAGS_CSV"].split(",") if t.strip()]
print(json.dumps({
  "capabilities": {
    "devices": {
      "create": {
        "reusable": True,
        "ephemeral": False,
        "preauthorized": True,
        "tags": tags,
      }
    }
  },
  "expirySeconds": int(os.environ["EXPIRY_SECONDS"]),
  "description": "finamp-embedded-tsnet",
}))
PY
)"

echo "Minting auth key (expirySeconds=${EXPIRY_SECONDS}, tags=${TAGS_CSV})…" >&2
KEY_JSON="$(
  curl -fsS -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API_BASE}/tailnet/${TAILNET}/keys" \
    -d "${BODY}"
)"
KEY="$(
  python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])' <<<"$KEY_JSON"
)"
echo
echo "${KEY}"
echo
echo "Paste into Finamp → Settings → Embedded Tailscale → Auth key, then Connect." >&2

if [[ "$CLEANUP_STALE" -eq 1 ]]; then
  echo "Listing devices for stale cleanup (regex=${STALE_NAME_REGEX})…" >&2
  DEVICES_JSON="$(
    curl -fsS -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${API_BASE}/tailnet/${TAILNET}/devices"
  )"
  STALE_NAME_REGEX="$STALE_NAME_REGEX" DRY_RUN="$DRY_RUN" ACCESS_TOKEN="$ACCESS_TOKEN" \
  API_BASE="$API_BASE" python3 - <<'PY' <<<"$DEVICES_JSON"
import json, os, re, sys, urllib.request

data = json.load(sys.stdin)
pat = re.compile(os.environ["STALE_NAME_REGEX"])
dry = os.environ["DRY_RUN"] == "1"
token = os.environ["ACCESS_TOKEN"]
api = os.environ["API_BASE"]
stale = []
for d in data.get("devices", []):
    name = (d.get("hostname") or d.get("name") or "").strip()
    online = bool(d.get("online"))
    if online:
        continue
    if not pat.search(name):
        continue
    stale.append((name, d.get("id") or d.get("nodeId") or ""))

if not stale:
    print("No offline devices matched.", file=sys.stderr)
    raise SystemExit(0)

for name, did in stale:
    print(f"{'Would delete' if dry else 'Deleting'}: {name} ({did})", file=sys.stderr)
    if dry or not did:
        continue
    req = urllib.request.Request(
        f"{api}/device/{did}",
        method="DELETE",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req) as resp:
        resp.read()
if dry:
    print("Dry-run only. Re-run with --execute to delete.", file=sys.stderr)
PY
fi
