# VSO Integration Test

Integration test between the Vault cluster (on VMs) and the [Vault Secrets Operator (VSO)](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) on a local Kind cluster.

## Custom Resources

VSO uses three Custom Resources (CRs) to manage the lifecycle of secrets synced from Vault to Kubernetes.

### VaultConnection

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
```

Defines the connection to the Vault server.

| Field | Value | Description |
|-------|-------|-------------|
| `spec.address` | `http://host.containers.internal:8200` | Vault server address reachable from pods. In this setup, `host.containers.internal` is the hostname that Podman resolves to the macOS host, where an SSH tunnel exposes port 8200 of the VM. |
| `spec.skipTLSVerify` | `true` | Disables TLS verification (the test cluster does not use TLS). |

**Relations:** referenced by `VaultAuth` via `spec.vaultConnectionRef`.

---

### VaultAuth

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
```

Configures the authentication method that VSO uses to obtain a Vault token.

| Field | Value | Description |
|-------|-------|-------------|
| `spec.vaultConnectionRef` | `vault-connection` | Reference to the `VaultConnection` CR to use. |
| `spec.method` | `kubernetes` | Vault auth method. Uses the Kubernetes ServiceAccount JWT to authenticate. |
| `spec.mount` | `kubernetes` | Mount path of the auth method on Vault (corresponds to `vault auth enable -path=kubernetes`). |
| `spec.kubernetes.role` | `vso-test` | Vault role assigned to the ServiceAccount. Determines the policies (and thus the readable secret paths). |
| `spec.kubernetes.serviceAccount` | `default` | Kubernetes ServiceAccount whose JWT token is sent to Vault for login. |

**Authentication flow:**

1. VSO reads the JWT token of the `default` ServiceAccount in the `vso-test` namespace
2. Sends the JWT to `POST /v1/auth/kubernetes/login` with the role `vso-test`
3. Vault validates the token by calling the Kubernetes TokenReview API (using the `token_reviewer_jwt` configured on the Vault side)
4. If valid, Vault returns a client token with the policies associated with the role

**Relations:** referenced by `VaultStaticSecret` via `spec.vaultAuthRef`.

---

### VaultStaticSecret

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
```

Syncs a static secret from Vault into a Kubernetes Secret, keeping it up-to-date with periodic polling.

| Field | Value | Description |
|-------|-------|-------------|
| `spec.vaultAuthRef` | `vault-auth` | Reference to the `VaultAuth` CR for authentication. |
| `spec.mount` | `secret` | Mount point of the secrets engine on Vault. |
| `spec.type` | `kv-v2` | Secrets engine type (KV version 2). |
| `spec.path` | `test/vso-integration` | Path of the secret within the mount (the full path on Vault is `secret/data/test/vso-integration`). |
| `spec.refreshAfter` | `10s` | Polling interval to check for secret updates on Vault. |
| `spec.destination.name` | `vso-synced-secret` | Name of the destination Kubernetes Secret that is created/updated. |
| `spec.destination.create` | `true` | If `true`, VSO creates the Secret if it does not exist. |

**Result:** a Kubernetes Secret `vso-synced-secret` in the `vso-test` namespace containing the keys from the Vault secret (e.g. `username`, `password`).

---

## Supporting Resources

### Namespace (`namespace.yml`)

Creates the `vso-test` namespace where all test resources reside.

### RBAC (`rbac.yml`)

| Resource | Name | Purpose |
|----------|------|---------|
| `ServiceAccount` | `vault-auth` | Account used by Vault to validate JWT tokens via the TokenReview API. |
| `ClusterRoleBinding` | `vault-auth-delegator` | Binds the `vault-auth` SA to the `system:auth-delegator` ClusterRole, which grants permission to call the TokenReview API. |

---

## Vault-side Configuration

The Vault-side configuration (auth backend, role) is managed by the Ansible playbook `ansible/configure.yml`. When a Kind cluster is running, the playbook automatically:

| Component | Description |
|-----------|-------------|
| Auth method `kubernetes` | Enabled on path `/auth/kubernetes`, configured with the cluster CA cert and a `token_reviewer_jwt` from the `vault-auth` SA. |
| Role `vso-test` | Binds the `default` ServiceAccount in the `vso-test` namespace to the `read-secret` policy with a 1-hour TTL. |

The `read-secret` policy (also created by `configure.yml`) grants read/list on `secret/data/*` and `secret/metadata/*`.

---

## Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  Kind Cluster (Podman)                                              │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Namespace: vso-test                                        │    │
│  │                                                             │    │
│  │  VaultConnection ──→ http://host.containers.internal:8200   │    │
│  │       ↑                                                     │    │
│  │  VaultAuth (method: kubernetes, role: vso-test)             │    │
│  │       ↑                                                     │    │
│  │  VaultStaticSecret ──→ secret/test/vso-integration          │    │
│  │       │                                                     │    │
│  │       ↓                                                     │    │
│  │  Secret: vso-synced-secret                                  │    │
│  │    username: vso-test-user                                  │    │
│  │    password: s3cr3t-from-vault                              │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Namespace: vault-secrets-operator-system                   │    │
│  │  VSO Controller (reconciles the CRs above)                  │    │
│  └─────────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────┬─────────────────────────────┘
                                        │
                        host.containers.internal:8200
                                        │
                              SSH tunnel (host)
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Vault VM (vault-1, 10.0.10.11)                                     │
│                                                                     │
│  Auth: /auth/kubernetes                                             │
│    └─ role: vso-test (SA=default, NS=vso-test, policy=read-secret) │
│                                                                     │
│  Secrets: /secret/data/test/vso-integration                         │
│    └─ {username: "vso-test-user", password: "s3cr3t-from-vault"}    │
│                                                                     │
│  Policy: read-secret → read/list secret/data/*, secret/metadata/*   │
└─────────────────────────────────────────────────────────────────────┘
```

## Usage

```bash
# Run the full test (single command)
./kind/test-vso.sh

# Clean up resources (Kind cluster + SSH tunnels)
./kind/test-vso.sh cleanup
```

The test script will:

1. Open an SSH tunnel to the Vault API
2. Write a test secret to Vault via REST API
3. Create the Kind cluster and install VSO via Helm
4. Apply Kubernetes manifests (namespace, RBAC, CRs)
5. Start a reverse SSH tunnel for the K8s API
6. Run `make configure` (configures Vault policies + Kubernetes auth)
7. Verify the secret is synced into a Kubernetes Secret

> **Note:** The script invokes `make configure` automatically, which detects the Kind cluster and configures Vault's Kubernetes auth backend.
