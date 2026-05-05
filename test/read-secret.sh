#!/usr/bin/env bash
set -euo pipefail

#
# Read a secret from Vault via REST API (KV2)
#
# Usage:
#   ./test/read-secret.sh -p myapp/config
#   ./test/read-secret.sh -p myapp/config -k db_password
#   ./test/read-secret.sh -p myapp/config -a http://10.0.10.11:8200
#
# Options:
#   -a VAULT_ADDR       Vault address (default: http://127.0.0.1:8200)
#   -m MOUNT            KV2 mount path (default: secret)
#   -p PATH             Secret path (required)
#   -k KEY              Extract a single key from the secret data
#   -c CREDENTIALS      Path to credentials file (default: ../.vault-credentials.json)
#   -t TOKEN            Vault token (overrides credentials file)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VAULT_ADDR="http://127.0.0.1:8200"
MOUNT="secret"
SECRET_PATH=""
KEY=""
CREDENTIALS_FILE="$ROOT_DIR/.vault-credentials.json"
TOKEN=""

while getopts "a:m:p:k:c:t:" opt; do
  case "$opt" in
    a) VAULT_ADDR="$OPTARG" ;;
    m) MOUNT="$OPTARG" ;;
    p) SECRET_PATH="$OPTARG" ;;
    k) KEY="$OPTARG" ;;
    c) CREDENTIALS_FILE="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    *) echo "Usage: $0 -p <path> [-k key] [options]" >&2; exit 1 ;;
  esac
done

if [[ -z "$SECRET_PATH" ]]; then
  echo "ERROR: Secret path is required (-p <path>)" >&2
  echo "Example: $0 -p myapp/config" >&2
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "ERROR: No token provided and credentials file not found: $CREDENTIALS_FILE" >&2
    exit 1
  fi
  TOKEN=$(jq -r '.root_token' "$CREDENTIALS_FILE")
fi

API_URL="$VAULT_ADDR/v1/$MOUNT/data/$SECRET_PATH"

echo "Reading secret from: $MOUNT/$SECRET_PATH"
echo "  Vault: $VAULT_ADDR"
echo ""

HTTP_CODE=$(curl -sf -o /tmp/vault-read-secret-response.json -w "%{http_code}" \
  -X GET "$API_URL" \
  -H "X-Vault-Token: $TOKEN") || HTTP_CODE=$?

if [[ "$HTTP_CODE" == "200" ]]; then
  if [[ -n "$KEY" ]]; then
    VALUE=$(jq -r --arg k "$KEY" '.data.data[$k] // empty' /tmp/vault-read-secret-response.json)
    if [[ -n "$VALUE" ]]; then
      echo "  $KEY = $VALUE"
    else
      echo "ERROR: Key '$KEY' not found in secret" >&2
      echo "Available keys:" >&2
      jq -r '.data.data | keys[]' /tmp/vault-read-secret-response.json >&2
      exit 1
    fi
  else
    echo "Secret data:"
    jq '.data.data' /tmp/vault-read-secret-response.json
  fi
  echo ""
  VERSION=$(jq -r '.data.metadata.version // empty' /tmp/vault-read-secret-response.json 2>/dev/null || true)
  if [[ -n "$VERSION" ]]; then
    echo "  Version: $VERSION"
  fi
elif [[ "$HTTP_CODE" == "404" ]]; then
  echo "ERROR: Secret not found at $MOUNT/$SECRET_PATH" >&2
  exit 1
else
  echo "ERROR: Failed to read secret (HTTP $HTTP_CODE)" >&2
  if [[ -f /tmp/vault-read-secret-response.json ]]; then
    jq . /tmp/vault-read-secret-response.json 2>/dev/null || cat /tmp/vault-read-secret-response.json
  fi
  exit 1
fi
