# -*- mode: ruby -*-
# vi: set ft=ruby :
require "yaml"

VENV_DIR  = File.join(__dir__, ".venv")
PLAYBOOK  = "ansible/setup.yml"
INVENTORY = File.join(__dir__, "ansible/inventory.yml")
VDE_SOCK  = "/tmp/vault-cluster.sock"

# ── Build NODES from ansible/inventory.yml ──────────────────────
inv   = YAML.load_file(INVENTORY)
hosts = inv.dig("all", "children", "vault", "hosts") || {}

NODES = hosts.map do |name, vars|
  {
    name:     name,
    ip:       vars["vault_node_ip"],
    ssh_port: vars["vault_ssh_port"],
    mac:      vars["vault_mac"],
  }
end

Vagrant.configure("2") do |config|
  config.vm.box = "perk/ubuntu-2204-arm64"

  NODES.each_with_index do |opts, idx|
    config.vm.define opts[:name] do |node|
      node.vm.hostname = opts[:name]

      node.vm.provider "qemu" do |qe|
        qe.memory   = 1024
        qe.smp      = 1
        qe.arch     = "aarch64"
        qe.machine  = "virt,accel=hvf,highmem=on"
        qe.cpu      = "host"
        qe.ssh_port = opts[:ssh_port]
        qe.net_device = "virtio-net-pci"
        qe.extra_qemu_args = %W[
          -netdev vde,id=cluster,sock=#{VDE_SOCK}
          -device virtio-net-pci,netdev=cluster,mac=#{opts[:mac]}
        ]
      end

      # Ansible runs only after the last VM boots, targeting all nodes
      if idx == NODES.length - 1
        node.vm.provision "ansible" do |ansible|
          ansible.playbook       = PLAYBOOK
          ansible.config_file    = "ansible.cfg"
          ansible.playbook_command = "#{VENV_DIR}/bin/ansible-playbook"
          ansible.limit          = "all"
          ansible.compatibility_mode = "2.0"

          ansible.groups = {
            "vault" => NODES.map { |n| n[:name] }
          }

          ansible.host_vars = NODES.each_with_object({}) do |n, vars|
            vars[n[:name]] = { "vault_node_ip" => n[:ip] }
          end
        end
      end
    end
  end
end
