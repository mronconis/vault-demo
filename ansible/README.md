# Ansible — Vault HA Cluster Provisioning

This directory contains all Ansible playbooks, templates, and configuration for deploying and managing the HashiCorp Vault HA cluster on VMs.

## Playbooks

### `setup.yml`

Provisions the Vault cluster on all VMs. Run automatically by `make up` (via Vagrant provisioner).

| Stage | What it does |
|-------|--------------|
| Network | Detects the cluster interface, deploys netplan config with static IPs |
| Install | Adds HashiCorp APT repository and installs the `vault` package |
| Configure | Deploys `vault.hcl` (Raft storage, retry_join, API listener), creates data directory |
| Service | Enables and starts the `vault` systemd unit |

```bash
# Re-run provisioning manually
make provision
```

### `initialize.yml`

Day-2 operations: initialises the cluster, unseals all nodes, enables KV2.

| Play | Description |
|------|-------------|
| 1 — Init + unseal leader | Runs `vault operator init`, saves credentials, unseals the leader |
| 2 — Unseal followers | Waits for Raft join, unseals remaining nodes with retry |
| 3 — Enable KV2 | Enables the KV version 2 secrets engine at `secret/` |

```bash
make init
```

> Idempotent: skips init if already done, skips unseal on unsealed nodes, skips KV2 if already enabled.

### `configure.yml`

Configures Vault resources required by the Vault Secrets Operator (VSO). Secrets are managed separately by `secrets.yml`.

**Play 1 — ACL policies:**

| Task | Module | Description |
|------|--------|-------------|
| Create ACL policy | `hashicorp.vault.acl_policy` | Creates `read-secret` policy (read/list on `secret/data/*` and `secret/metadata/*`) |

**Play 2 — Kubernetes auth for VSO (conditional):**

Automatically configures the Vault Kubernetes auth backend when a Kind cluster is running. Skipped if no cluster is detected.

| Task | Description |
|------|-------------|
| Enable `kubernetes` auth method | Enables the auth backend on Vault (idempotent) |
| Configure auth backend | Sets K8s API host, CA cert, and reviewer JWT |
| Create `vso-test` role | Binds SA `default` in namespace `vso-test` to `read-secret` policy |

```bash
make configure
```

### `secrets.yml`

Reconciles secrets on HashiCorp Vault with Ansible definitions (single source of truth). Each secret entry declares its desired state.

| Field | Description |
|-------|-------------|
| `path` | KV2 secret path (relative to engine mount) |
| `engine_mount_point` | Secrets engine mount (default: `secret`) |
| `state` | `present` (default) or `absent` |
| `purge` | `true` to permanently destroy metadata + all versions (default: `false`) |
| `data` | Key/value pairs (required when `state: present`) |

| Action | Behaviour |
|--------|-----------|
| `state: present` | Creates or updates the secret |
| `state: absent` | Soft-deletes the latest version |
| `state: absent` + `purge: true` | Hard-deletes metadata and all versions |

```bash
make secrets
```

Sensitive values are stored in `group_vars/vault/sensitive.yml` (Ansible Vault encrypted). Secret definitions live in `group_vars/vault/secrets.yml` (plaintext, safe to commit).

## Directory Structure

```
ansible/
├── setup.yml                  # VM provisioning playbook
├── initialize.yml             # Init, unseal, enable KV2
├── configure.yml              # VSO resources (ACL policies, k8s auth)
├── secrets.yml                # Reconcile secrets (write, soft-delete, purge)
├── inventory.yml              # Cluster topology (IPs, SSH ports, MACs, connection vars)
├── collections/
│   └── requirements.yml       # Ansible collection dependencies
├── group_vars/
│   ├── all.yml                # Cluster-wide variables
│   └── vault/
│       ├── secrets.yml        # Secret definitions (paths, engine, key mapping)
│       └── sensitive.yml      # Sensitive values (ansible-vault encrypted)
└── templates/
    ├── 60-cluster.yaml.j2     # Netplan template (static IP on cluster interface)
    └── vault.hcl.j2           # Vault server configuration template
```

## Inventory

`inventory.yml` is the single source of truth for the cluster. Both the Vagrantfile and playbooks read from it. SSH connection parameters (`ansible_host`, `ansible_port`, `ansible_user`, `ansible_ssh_private_key_file`) are included so that playbooks can run standalone via `make` targets.

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

## Variables

### `group_vars/all.yml`

| Variable | Default | Description |
|----------|---------|-------------|
| `vault_cluster_name` | `vault-cluster` | Raft cluster identifier |
| `vault_cluster_iface_candidates` | `[enp0s2, ..., eth1]` | Interface names to probe for cluster network |
| `vault_data_dir` | `/opt/vault/data` | Raft storage directory |
| `vault_config_dir` | `/etc/vault.d` | Vault configuration directory |
| `vault_api_port` | `8200` | HTTP API port |
| `vault_cluster_port` | `8201` | Raft replication port |

### `group_vars/vault/`

| File | Encrypted | Content |
|------|-----------|---------|
| `sensitive.yml` | Yes | Flat dictionary of sensitive values (`vault_sensitive_data`) |
| `secrets.yml` | No | Secret definitions: KV2 path, engine mount, state, and key mapping |

Ansible auto-loads all files under `group_vars/vault/` for hosts in the `vault` inventory group.

## Ansible Collection

The [`hashicorp.vault`](https://github.com/ansible-collections/hashicorp.vault) Red Hat certified collection is used in:

- **`configure.yml`** — `hashicorp.vault.acl_policy` to create ACL policies
- **`secrets.yml`** — `hashicorp.vault.kv2_secret` to write and soft-delete KV2 secrets

### Install the collection manually

```bash
.venv/bin/ansible-galaxy collection install -r ansible/collections/requirements.yml -p ansible/collections
```

The collection is installed automatically by `make up`.

### Python dependency

The collection requires the `requests` library, included in `requirements.txt`.

## Templates

### `vault.hcl.j2`

Generates the Vault server configuration for each node:

- Raft integrated storage with `retry_join` to all other nodes
- HTTP API listener on the cluster IP (`0.0.0.0:8200`)
- Cluster address on port 8201
- TLS disabled (development setup)
- UI enabled

### `60-cluster.yaml.j2`

Netplan configuration that assigns a static IP to the cluster network interface (VDE on macOS, libvirt isolated on Linux).

## Credentials

After running `make init`, credentials are saved to `../.vault-credentials.json`:

```json
{
  "root_token": "hvs.xxxxx",
  "unseal_keys": ["key1", "key2", "key3"]
}
```

This file is used by:
- `initialize.yml`, `configure.yml`, and `secrets.yml`
- `test/create-secret.sh` and `test/read-secret.sh`
- `kind/test-vso.sh`
