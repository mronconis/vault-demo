# Vault HA Cluster (Vagrant + Ansible)

Local 3-node [HashiCorp Vault](https://www.vaultproject.io/) cluster with integrated Raft storage, provisioned by Ansible on QEMU virtual machines. Secrets management uses the Red Hat certified [`hashicorp.vault`](https://github.com/ansible-collections/hashicorp.vault) Ansible collection.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  macOS host (Apple Silicon)                          │
│                                                      │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐      │
│  │  vault-1   │  │  vault-2   │  │  vault-3   │      │
│  │ 10.0.10.11 │  │ 10.0.10.12 │  │ 10.0.10.13 │      │
│  │ :8200 API  │  │ :8200 API  │  │ :8200 API  │      │
│  │ :8201 Raft │  │ :8201 Raft │  │ :8201 Raft │      │
│  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘      │
│        │               │               │             │
│        └───────────────┼───────────────┘             │
│                   VDE switch                         │
│              (L2 virtual network)                    │
└──────────────────────────────────────────────────────┘
```

| Node | Cluster IP | SSH |
|------|------------|-----|
| `vault-1` | `10.0.10.11` | `vagrant ssh vault-1` |
| `vault-2` | `10.0.10.12` | `vagrant ssh vault-2` |
| `vault-3` | `10.0.10.13` | `vagrant ssh vault-3` |

### Raft Consensus and Fault Tolerance

Vault uses the [Raft consensus algorithm](https://developer.hashicorp.com/vault/docs/internals/integrated-storage) for leader election and log replication. The cluster tolerates up to **f** node failures as long as a quorum (strict majority) is maintained:

$$N = 2f + 1$$

where **N** is the total number of nodes and **f** is the maximum number of simultaneous failures the cluster can survive.

| Nodes (N) | Failure tolerance (f) | Quorum required |
|-----------|----------------------|-----------------|
| 3         | 1                    | 2               |
| 5         | 2                    | 3               |
| 7         | 3                    | 4               |

This cluster uses **3 nodes**, so it can tolerate **1 node failure** while remaining operational. Adding nodes increases fault tolerance but also increases write latency, since every committed entry must be replicated to a majority of peers before being acknowledged.

## Prerequisites

| Tool | Tested version | Install |
|------|----------------|---------|
| [Vagrant](https://www.vagrantup.com/) | 2.4.x | `brew install vagrant` |
| [QEMU](https://www.qemu.org/) | 9.x | `brew install qemu` |
| [vagrant-qemu](https://github.com/ppggff/vagrant-qemu) | 0.3.x | `vagrant plugin install vagrant-qemu` |
| [VDE](https://github.com/virtualsquare/vde-2) | 2.3.x | `brew install vde` |
| Python | 3.10+ | ships with macOS / `brew install python` |
| GNU Make | any | ships with Xcode CLI tools |

> **Note:** This setup uses the QEMU provider with HVF acceleration and is designed for **Apple Silicon** (aarch64) Macs. For Intel Macs or Linux hosts, adjust `qe.arch`, `qe.machine`, `qe.cpu`, and the Vagrant box accordingly.

## Quick Start

```bash
# Clone and enter the project
git clone <repo-url> && cd vault

# Bring up the cluster (creates venv, starts VDE, boots VMs, runs Ansible)
make up

# Initialise, unseal, and enable KV2 secrets engine
make init
```

The init playbook will:

1. Run `vault operator init` on the leader node
2. Save unseal keys and root token to `.vault-credentials.json`
3. Unseal the leader, wait for followers to join via Raft `retry_join`
4. Unseal all follower nodes (with retry for Raft sync)
5. Enable the KV2 secrets engine

Credentials are printed to stdout and persisted locally:

```bash
cat .vault-credentials.json
```

> **Re-running is safe:** the playbooks are idempotent — they skip init if already done and only unseal sealed nodes.

### Verify cluster health

Check which node is the leader (`200`) and which are followers (`429`):

```bash
for node in vault-1 vault-2 vault-3; do
  echo "=== $node ===";
  vagrant ssh $node -c "curl -so /dev/null -w '%{http_code}' http://127.0.0.1:8200/v1/sys/health" 2>/dev/null;
  echo;
done
```

| HTTP code | Meaning |
|-----------|---------|
| `200` | Active (leader), unsealed |
| `429` | Standby (follower), unsealed |
| `503` | Sealed |
| `501` | Not initialized |

## Web UI

The Vault UI is enabled on all nodes. Since the QEMU provider does not expose VM ports directly on the host, open an SSH tunnel:

```bash
# Quick tunnel via Makefile
make ssh-tunnel

# Or manually
vagrant ssh vault-1 -- -L 8200:127.0.0.1:8200 -N &
```

Then open **http://127.0.0.1:8200** in your browser and sign in with the **Token** method using the root token from `.vault-credentials.json`.

## Makefile Targets

The project uses a `Makefile` to orchestrate the entire workflow, keeping the Vagrantfile clean and eliminating trigger-related warnings.

| Target | Description |
|--------|-------------|
| `make up` | Prepare venv + VDE, then `vagrant up` |
| `make destroy` | Destroy all VMs and stop VDE switch |
| `make provision` | Re-run Ansible setup on existing VMs |
| `make init` | Initialise and unseal the Vault cluster |
| `make configure` | Configure Vault (policies, secrets, k8s auth) via collection |
| `make secrets` | Reconcile secrets on Vault (write defined, remove orphans) |
| `make ssh-tunnel` | Open SSH tunnel to Vault API (port 8200) |
| `make clean` | Full cleanup (VMs + venv + credentials + collections) |
| `make status` | Show VM status |
| `make help` | List available targets |

## What `make up` Does

1. **Creates a Python virtual environment** (`.venv/`), installs Ansible and the `hashicorp.vault` collection.
2. **Starts a VDE switch** (`/tmp/vault-cluster.sock`) — a virtual L2 network shared by all VMs.
3. **Boots 3 Ubuntu 22.04 aarch64 VMs** in parallel via QEMU with HVF acceleration.
4. **Runs the Ansible playbook** (`setup.yml`) against all nodes:
   - Detects and configures the cluster network interface via netplan.
   - Adds the HashiCorp APT repository and installs Vault.
   - Deploys `vault.hcl` with Raft integrated storage and `retry_join`.
   - Enables and starts the `vault` systemd service.

## Project Structure

```
.
├── .vault-pass                          # Ansible Vault password (git-ignored)
├── Makefile                             # Orchestrates setup, VDE, and playbook execution
├── Vagrantfile                          # Reads inventory.yml, defines VMs
├── ansible.cfg                          # Ansible settings (pipelining, no host key check)
├── requirements.txt                     # Python dependencies (ansible, requests)
├── README.md
├── ansible/
│   ├── inventory.yml                    # Single source of truth: node IPs, ports, MACs, SSH
│   ├── setup.yml                       # Provisioning: install + configure Vault
│   ├── initialize.yml                  # Day-2: init, unseal, enable KV2
│   ├── configure.yml                  # VSO resources (ACL policies, k8s auth)
│   ├── secrets.yml                    # Write secrets from Ansible Vault to HashiCorp Vault
│   ├── collections/
│   │   └── requirements.yml           # Ansible collection dependencies (hashicorp.vault)
│   ├── group_vars/
│   │   ├── all.yml                     # Cluster-wide variables (ports, paths)
│   │   └── vault/
│   │       ├── secrets.yml             # Secret definitions (paths, engine, key mapping)
│   │       └── sensitive.yml           # Sensitive values (ansible-vault encrypted)
│   └── templates/
│       ├── 60-cluster.yaml.j2          # Netplan template
│       └── vault.hcl.j2               # Vault config template
├── kind/
│   ├── cluster.yml                     # Kind cluster definition
│   ├── test-vso.sh                    # Integration test script (VSO ↔ Vault)
│   ├── README.md                      # CR documentation and VSO flow
│   └── manifests/
│       ├── namespace.yml              # vso-test namespace
│       ├── rbac.yml                   # vault-auth SA + ClusterRoleBinding
│       ├── vault-connection.yml       # VaultConnection CR
│       ├── vault-auth.yml            # VaultAuth CR
│       └── vault-static-secret.yml   # VaultStaticSecret CR
└── test/
    ├── README.md                      # Test scripts documentation
    ├── create-secret.sh               # Write a secret to Vault via REST API
    └── read-secret.sh                 # Read a secret from Vault via REST API
```

## REST API Test Scripts

The `test/` directory contains shell scripts to interact with Vault directly via its HTTP API. They require an SSH tunnel to the Vault API on `127.0.0.1:8200`.

```bash
# Open SSH tunnel
make ssh-tunnel &

# Write a secret
./test/create-secret.sh -p myapp/config -k password -v s3cret

# Read it back
./test/read-secret.sh -p myapp/config
```

See [`test/README.md`](test/README.md) for full usage details.

## VSO Integration Test

The `kind/` directory contains everything needed to test the integration between the Vault cluster (on VMs) and the [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) on Kubernetes.

Ansible manages **all** Vault configuration (including the Kubernetes auth method). The test script handles the Kind cluster infrastructure, invokes `make configure`, and verifies the result.

### Prerequisites

- Vault cluster running and unsealed (`make up` + `make init`)
- `kind`, `helm`, `kubectl`, `jq` installed
- Podman machine running (`podman machine start`)

### Run the test

```bash
./kind/test-vso.sh
```

The test script will:

1. Open an SSH tunnel to the Vault API on the VM
2. Write a test secret to Vault via the HTTP API
3. Create a Kind cluster and install VSO via Helm
4. Apply Kubernetes manifests (`kind/manifests/`)
5. Run `make configure` (configures policies + Kubernetes auth on Vault)
6. Verify the secret is synced from Vault into a Kubernetes Secret

### Cleanup

```bash
./kind/test-vso.sh cleanup
```

### Kubernetes Manifests

| Manifest | Purpose |
|----------|---------|
| `namespace.yml` | Creates the `vso-test` namespace |
| `rbac.yml` | ServiceAccount + ClusterRoleBinding for token review |
| `vault-connection.yml` | `VaultConnection` CR pointing to Vault via `host.containers.internal` |
| `vault-auth.yml` | `VaultAuth` CR using Kubernetes auth method |
| `vault-static-secret.yml` | `VaultStaticSecret` CR syncing `secret/test/vso-integration` |

## Ansible Collection

This project uses the Red Hat certified [`hashicorp.vault`](https://github.com/ansible-collections/hashicorp.vault) Ansible collection for managing Vault configuration (secrets, ACL policies). Kubernetes auth method and roles are configured via `ansible.builtin.uri` in the same playbook.

The collection is installed automatically by `make up`. For manual installation:

```bash
.venv/bin/ansible-galaxy collection install -r ansible/collections/requirements.yml -p ansible/collections
```

Collection modules used in `configure.yml`:

| Module | Purpose |
|--------|---------|
| `hashicorp.vault.acl_policy` | Create/manage ACL policies |
| `hashicorp.vault.kv2_secret` | Write KV2 secrets |
| `hashicorp.vault.kv2_secret_info` | Read KV2 secrets |

Additionally, `configure.yml` uses `ansible.builtin.uri` to manage the Kubernetes auth method (enable, configure backend, create roles) when a Kind cluster is detected.

> **Note:** init, unseal, and secrets engine enablement are not covered by the collection and remain CLI-based.

## Secrets Management

The `secrets.yml` playbook **reconciles** secrets on HashiCorp Vault with the definitions in Ansible (single source of truth). Each secret declares a `state` field (`present` or `absent`) that controls whether it is created/updated or deleted. Sensitive values are encrypted with [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html).

### How it works

| File | Encrypted | Content |
|------|-----------|---------|
| `ansible/group_vars/vault/sensitive.yml` | Yes | Flat dictionary of sensitive values (`vault_sensitive_data`) |
| `ansible/group_vars/vault/secrets.yml` | No | Secret definitions: KV2 path, engine mount, and key mapping referencing `vault_sensitive_data` |

Ansible auto-loads all files under `group_vars/vault/` for hosts in the `vault` inventory group. The playbook writes entries with `state: present` (default) and deletes entries with `state: absent`. To remove a secret from Vault, set its state to `absent` and run `make secrets`; once confirmed, the entry can be removed from the file.

### Vault password

The Ansible Vault password is stored in `.vault-pass` (git-ignored, `chmod 600`). The `Makefile` exports the `ANSIBLE_VAULT_PASSWORD_FILE` environment variable pointing to this file, so all `make` targets that need to decrypt `sensitive.yml` work automatically without interactive prompts.

```bash
# Create the password file (one-time)
echo -n "changeme" > .vault-pass
chmod 600 .vault-pass
```

### Initial setup

```bash
# Edit the sensitive values (before encryption)
vim ansible/group_vars/vault/sensitive.yml

# Encrypt the file (one-time)
ansible-vault encrypt ansible/group_vars/vault/sensitive.yml

# Define secret paths and key mapping (plaintext, safe to commit)
vim ansible/group_vars/vault/secrets.yml
```

### Writing secrets

```bash
make secrets
```

### Editing encrypted values

```bash
ansible-vault edit ansible/group_vars/vault/sensitive.yml
```

### Adding a new secret

1. Add the sensitive value to `ansible/group_vars/vault/sensitive.yml` (via `ansible-vault edit`)
2. Add a new entry to `vault_secret_definitions` in `ansible/group_vars/vault/secrets.yml`
3. Run `make secrets`

## Configuration

### Node inventory (`ansible/inventory.yml`)

This is the **single source of truth** for the cluster topology. Both the Vagrantfile and Ansible playbooks read from it. SSH connection parameters are included so playbooks can run standalone via `make`.

```yaml
all:
  children:
    vault:
      vars:
        ansible_user: vagrant
        ansible_host: 127.0.0.1
        ansible_ssh_private_key_file: "{{ playbook_dir }}/../.vagrant/machines/{{ inventory_hostname }}/qemu/private_key"
      hosts:
        vault-1:
          vault_node_ip: 10.0.10.11
          vault_ssh_port: 50022
          ansible_port: 50022
          vault_mac: "52:54:00:aa:00:01"
```

To add or remove nodes, edit only this file. The Vagrantfile parses it at load time.

### Cluster variables (`ansible/group_vars/all.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `vault_api_port` | `8200` | Vault HTTP API port |
| `vault_cluster_port` | `8201` | Raft replication port |
| `vault_data_dir` | `/opt/vault/data` | Raft storage path |
| `vault_config_dir` | `/etc/vault.d` | Vault config directory |

## Common Operations

```bash
# Bring up the full cluster
make up

# Initialise + unseal the cluster (first time, or after data wipe)
make init

# Configure Vault (policies, secrets)
make configure

# Write secrets to Vault from encrypted Ansible Vault values
make secrets

# Re-run provisioning without recreating VMs
make provision

# Open SSH tunnel to Vault API
make ssh-tunnel

# SSH into a specific node
vagrant ssh vault-2

# Show VM status
make status

# Destroy everything (VMs + VDE switch)
make destroy

# Full cleanup (VMs + venv + credentials)
make clean
```

## Networking

Inter-VM communication uses [VDE](https://github.com/virtualsquare/vde-2) (Virtual Distributed Ethernet) — a userspace virtual switch that connects all QEMU instances at Layer 2 without requiring root privileges or macOS entitlements.

Each VM has two network interfaces:

| Interface | Network | Purpose |
|-----------|---------|---------|
| `eth0` | `10.0.2.0/24` (QEMU user-mode) | SSH access from host, internet |
| `enp0s2` | `10.0.10.0/24` (VDE) | Cluster traffic (Raft, API) |

## Security Notes

This setup is intended for **local development and testing only**:

- TLS is disabled (`tls_disable = 1`)
- `disable_mlock = true` (required for non-root operation)
- The UI is enabled on all nodes
- Default `key-shares=3 / key-threshold=2` (configurable in `initialize.yml`)
- `.vault-credentials.json` stores unseal keys and root token in plaintext — **do not commit this file**
- `.vault-pass` contains the Ansible Vault password in plaintext — **do not commit this file**

For production deployments, refer to the [Vault Production Hardening Guide](https://developer.hashicorp.com/vault/tutorials/operations/production-hardening).

## License

MIT
