#!/usr/bin/env bash
set -euo pipefail

#
# Create a secret on Vault via REST API (KV2)
#
# Usage:
#   ./test/create-secret.sh                                    # interactive prompts
#   ./test/create-secret.sh -p myapp/config -k db_password -v s3cret
#   ./test/create-secret.sh -p myapp/config -d '{"user":"admin","pass":"s3cret"}'
#
# Options:
#   -a VAULT_ADDR       Vault address (default: http://10.0.10.11:8200)
#   -m MOUNT            KV2 mount path (default: secret)
#   -p PATH             Secret path (required)
#   -k KEY              Single key name
#   -v VALUE            Single value (requires -k)
#   -d DATA             Full JSON data payload (alternative to -k/-v)
#   -c CREDENTIALS      Path to credentials file (default: ../.vault-credentials.json)
#   -t TOKEN            Vault token (overrides credentials file)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VAULT_ADDR="http://127.0.0.1:8200"
MOUNT="secret"
SECRET_PATH=""
KEY=""
VALUE=""
DATA=""
CREDENTIALS_FILE="$ROOT_DIR/.vault-credentials.json"
TOKEN=""

while getopts "a:m:p:k:v:d:c:t:" opt; do
  case "$opt" in
    a) VAULT_ADDR="$OPTARG" ;;
    m) MOUNT="$OPTARG" ;;
    p) SECRET_PATH="$OPTARG" ;;
    k) KEY="$OPTARG" ;;
    v) VALUE="$OPTARG" ;;
    d) DATA="$OPTARG" ;;
    c) CREDENTIALS_FILE="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    *) echo "Usage: $0 -p <path> [-k key -v value | -d json_data] [options]" >&2; exit 1 ;;
  esac
done

if [[ -z "$SECRET_PATH" ]]; then
  echo "ERROR: Secret path is required (-p <path>)" >&2
  echo "Example: $0 -p myapp/config -k password -v s3cret" >&2
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "ERROR: No token provided and credentials file not found: $CREDENTIALS_FILE" >&2
    exit 1
  fi
  TOKEN=$(jq -r '.root_token' "$CREDENTIALS_FILE")
fi

if [[ -n "$DATA" ]]; then
  PAYLOAD="$DATA"
elif [[ -n "$KEY" && -n "$VALUE" ]]; then
  PAYLOAD=$(jq -n --arg k "$KEY" --arg v "$VALUE" '{($k): $v}')
elif [[ -n "$KEY" ]]; then
  echo "ERROR: -k requires -v (value)" >&2
  exit 1
else
  echo "ERROR: Provide either -d (json data) or -k/-v (key/value pair)" >&2
  exit 1
fi

API_URL="$VAULT_ADDR/v1/$MOUNT/data/$SECRET_PATH"
BODY=$(jq -n --argjson data "$PAYLOAD" '{"data": $data}')

echo "Writing secret to: $MOUNT/$SECRET_PATH"
echo "  Vault: $VAULT_ADDR"
echo ""

HTTP_CODE=$(curl -sf -o /tmp/vault-create-secret-response.json -w "%{http_code}" \
  -X POST "$API_URL" \
  -H "X-Vault-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY") || HTTP_CODE=$?

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
  echo "Secret written successfully."
  if [[ -f /tmp/vault-create-secret-response.json ]]; then
    VERSION=$(jq -r '.data.version // empty' /tmp/vault-create-secret-response.json 2>/dev/null || true)
    if [[ -n "$VERSION" ]]; then
      echo "  Version: $VERSION"
    fi
  fi
else
  echo "ERROR: Failed to write secret (HTTP $HTTP_CODE)" >&2
  if [[ -f /tmp/vault-create-secret-response.json ]]; then
    jq . /tmp/vault-create-secret-response.json 2>/dev/null || cat /tmp/vault-create-secret-response.json
  fi
  exit 1
fi

echo ""
echo "Verify with:"
echo "  curl -s -H \"X-Vault-Token: \$TOKEN\" $VAULT_ADDR/v1/$MOUNT/data/$SECRET_PATH | jq .data.data"
