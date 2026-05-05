VENV_DIR  := $(CURDIR)/.venv
VDE_SOCK  := /tmp/vault-cluster.sock
ANSIBLE   := $(VENV_DIR)/bin/ansible-playbook

.PHONY: up destroy provision init configure clean status ssh-tunnel

## ── Main targets ────────────────────────────────────────────────

up: _venv _vde _kill_stale  ## Bring up the cluster
	vagrant up

destroy:  ## Destroy all VMs and stop VDE
	vagrant destroy -f
	@rm -rf $(VDE_SOCK) 2>/dev/null; true
	@pkill -f "vde_switch.*$(VDE_SOCK)" 2>/dev/null; true
	@echo "VDE switch stopped"

provision:  ## Re-run Ansible setup on existing VMs
	vagrant provision

init:  ## Initialize and unseal Vault cluster
	$(ANSIBLE) -i ansible/inventory.yml ansible/initialize.yml

configure:  ## Configure Vault (policies, secrets, k8s auth) via collection
	$(ANSIBLE) -i ansible/inventory.yml ansible/configure.yml

status:  ## Show VM status
	vagrant status

ssh-tunnel:  ## Open SSH tunnel to Vault API (port 8200)
	@echo "Opening SSH tunnel to vault-1:8200 on localhost:8200 …"
	@echo "Press Ctrl+C to close."
	vagrant ssh vault-1 -- -N -L 8200:127.0.0.1:8200

clean: destroy  ## Full cleanup (VMs + venv + credentials)
	rm -rf .vagrant .vault-credentials.json $(VENV_DIR)
	rm -rf ansible/collections/ansible_collections

## ── Internal targets ────────────────────────────────────────────

_venv:
	@if [ ! -f "$(VENV_DIR)/bin/ansible-playbook" ]; then \
		echo "Creating Python venv …"; \
		python3 -m venv "$(VENV_DIR)"; \
		"$(VENV_DIR)/bin/pip" install --upgrade pip -q; \
		"$(VENV_DIR)/bin/pip" install -r requirements.txt -q; \
		echo "Ansible installed: $$($(VENV_DIR)/bin/ansible --version | head -1)"; \
	else \
		echo "Python venv already present"; \
	fi
	@echo "Installing Ansible collections…"
	@"$(VENV_DIR)/bin/ansible-galaxy" collection install \
		-r ansible/collections/requirements.yml \
		-p ansible/collections --force

_vde:
	@if ! test -S "$(VDE_SOCK)"; then \
		vde_switch -s "$(VDE_SOCK)" -daemon; \
		echo "VDE switch started"; \
	else \
		echo "VDE switch already running"; \
	fi

_kill_stale:
	@for pair in vault-1:50022 vault-2:50023 vault-3:50024; do \
		name=$${pair%%:*}; port=$${pair##*:}; \
		if [ ! -d ".vagrant/machines/$$name/qemu" ]; then \
			pid=$$(lsof -ti :$$port -sTCP:LISTEN 2>/dev/null | head -1); \
			if [ -n "$$pid" ]; then \
				kill $$pid 2>/dev/null && echo "Killed orphan QEMU on port $$port (PID $$pid)" && sleep 1; \
			fi; \
		fi; \
	done; true

## ── Help ────────────────────────────────────────────────────────

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
