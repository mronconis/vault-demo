#!/usr/bin/env bash
set -euo pipefail

#
# Integration test: Vault (on VM) ↔ Vault Secrets Operator (on Kind)
#
# This script creates a Kind cluster, installs VSO, writes a test secret,
# runs `make configure` to set up Kubernetes auth on Vault, then verifies
# that VSO syncs the secret into a Kubernetes Secret.
#
# Prerequisites:
#   - Vault cluster running and unsealed (make up + make init)
#   - kind, helm, kubectl, jq available on the host
#   - Podman machine running
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KIND_CONFIG="$SCRIPT_DIR/cluster.yml"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
CREDENTIALS_FILE="$ROOT_DIR/.vault-credentials.json"
SSH_KEY="$ROOT_DIR/.vagrant/machines/vault-1/qemu/private_key"

CLUSTER_NAME="vault-vso-test"
VSO_NAMESPACE="vault-secrets-operator-system"
TEST_NAMESPACE="vso-test"
VAULT_NODE_IP="10.0.10.11"
VAULT_SSH_PORT=50022
VAULT_ADDR="http://127.0.0.1:8200"

# ── Helpers ───────────────────────────────────────────────────────

info()  { printf "\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()    { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
fail()  { printf "\033[1;31m✗ %s\033[0m\n" "$*"; exit 1; }

check_deps() {
  for cmd in kind helm kubectl jq ssh; do
    command -v "$cmd" >/dev/null || fail "Missing dependency: $cmd"
  done
  [ -f "$CREDENTIALS_FILE" ] || fail "Vault credentials not found: $CREDENTIALS_FILE"
  [ -f "$SSH_KEY" ] || fail "SSH key not found: $SSH_KEY"
}

vault_token() {
  jq -r '.root_token' "$CREDENTIALS_FILE"
}

# ── SSH Tunnels ───────────────────────────────────────────────────

start_vault_tunnel() {
  if ! pgrep -f "ssh.*-L 8200:${VAULT_NODE_IP}:8200" >/dev/null 2>&1; then
    info "Starting SSH tunnel to Vault API (localhost:8200 → VM)"
    ssh -f -N -L "8200:${VAULT_NODE_IP}:8200" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$SSH_KEY" -p "$VAULT_SSH_PORT" vagrant@127.0.0.1
  fi

  info "Waiting for Vault API..."
  for i in $(seq 1 10); do
    if curl -sf "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
      ok "Vault API reachable"
      return
    fi
    sleep 1
  done
  fail "Vault API not reachable at $VAULT_ADDR"
}

start_k8s_reverse_tunnel() {
  local k8s_port="$1"
  if ! pgrep -f "ssh.*-R 6443:127.0.0.1:${k8s_port}" >/dev/null 2>&1; then
    info "Starting reverse SSH tunnel for K8s API (VM:6443 → host:${k8s_port})"
    ssh -f -N -R "6443:127.0.0.1:${k8s_port}" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$SSH_KEY" -p "$VAULT_SSH_PORT" vagrant@127.0.0.1
  fi
}

# ── Kind Cluster ──────────────────────────────────────────────────

create_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Kind cluster '$CLUSTER_NAME' already exists"
  else
    info "Creating Kind cluster '$CLUSTER_NAME'"
    kind create cluster --config "$KIND_CONFIG"
  fi
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
  ok "Kind cluster ready"
}

get_k8s_api_port() {
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null \
    | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 | cut -d: -f2
}

# ── VSO Install ───────────────────────────────────────────────────

install_vso() {
  helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
  helm repo update >/dev/null

  if helm list -n "$VSO_NAMESPACE" -o json | jq -e 'length > 0' >/dev/null 2>&1; then
    info "VSO already installed"
  else
    info "Installing Vault Secrets Operator via Helm"
    helm install vault-secrets-operator hashicorp/vault-secrets-operator \
      -n "$VSO_NAMESPACE" --create-namespace --wait --timeout 120s
  fi

  kubectl wait --for=condition=Available \
    deployment/vault-secrets-operator-controller-manager \
    -n "$VSO_NAMESPACE" --timeout=90s >/dev/null
  ok "VSO controller ready"
}

# ── Write test secret ─────────────────────────────────────────────

write_test_secret() {
  local token
  token="$(vault_token)"

  info "Writing test secret to Vault (secret/test/vso-integration)"
  curl -sf -o /dev/null \
    --header "X-Vault-Token: $token" \
    --request POST \
    --data '{"data":{"username":"vso-test-user","password":"s3cr3t-from-vault"}}' \
    "$VAULT_ADDR/v1/secret/data/test/vso-integration"

  ok "Test secret written"
}

# ── Apply manifests ───────────────────────────────────────────────

apply_manifests() {
  info "Applying Kubernetes manifests"
  kubectl apply -f "$MANIFESTS_DIR/"
  ok "Manifests applied"
}

# ── Configure Vault (via Makefile) ────────────────────────────────

configure_vault() {
  info "Running 'make configure' (Vault policies + Kubernetes auth)"
  make -C "$ROOT_DIR" configure
  ok "Vault configured"
}

# ── Verify ────────────────────────────────────────────────────────

verify_sync() {
  info "Waiting for secret sync (up to 60s)..."
  local password=""
  for i in $(seq 1 12); do
    password="$(kubectl get secret vso-synced-secret -n "$TEST_NAMESPACE" \
      -o jsonpath='{.data.password}' 2>/dev/null || true)"
    if [ -n "$password" ]; then
      password="$(echo "$password" | base64 -d)"
      break
    fi
    sleep 5
  done

  if [ -z "$password" ]; then
    echo
    info "VaultStaticSecret status:"
    kubectl get vaultstaticsecret -n "$TEST_NAMESPACE" -o jsonpath='{.items[0].status.conditions[0].message}' 2>/dev/null || true
    echo
    fail "Secret was not synced within 60s"
  fi

  if [ "$password" = "s3cr3t-from-vault" ]; then
    echo
    ok "═══════════════════════════════════════════════════════"
    ok " VSO Integration Test PASSED"
    ok ""
    ok " Vault (VM):    $VAULT_ADDR"
    ok " Kind cluster:  $CLUSTER_NAME"
    ok " Secret path:   secret/test/vso-integration"
    ok " K8s secret:    $TEST_NAMESPACE/vso-synced-secret"
    ok " Synced value:  password=$password"
    ok "═══════════════════════════════════════════════════════"
  else
    fail "Secret mismatch: got '$password', expected 's3cr3t-from-vault'"
  fi
}

# ── Cleanup ───────────────────────────────────────────────────────

cleanup() {
  info "Cleaning up Kind cluster and SSH tunnels"
  kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
  pkill -f "ssh.*-L 8200:${VAULT_NODE_IP}:8200" 2>/dev/null || true
  pkill -f "ssh.*-R 6443:" 2>/dev/null || true
  ok "Cleanup done"
}

# ── Main ──────────────────────────────────────────────────────────

main() {
  local cmd="${1:-run}"

  case "$cmd" in
    run)
      check_deps
      start_vault_tunnel
      write_test_secret
      create_cluster
      start_k8s_reverse_tunnel "$(get_k8s_api_port)"
      install_vso
      apply_manifests
      configure_vault
      verify_sync
      ;;
    cleanup)
      cleanup
      ;;
    *)
      echo "Usage: $0 [run|cleanup]"
      exit 1
      ;;
  esac
}

main "$@"
