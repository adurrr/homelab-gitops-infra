# Ansible: IT Automation

> **Official site:** [ansible.com](https://www.ansible.com/) · **Docs:** [docs.ansible.com](https://docs.ansible.com/)
> **GitHub:** [ansible/ansible](https://github.com/ansible/ansible) · **License:** GPL-3.0

## Overview

Ansible is an **open-source IT automation tool** that automates configuration
management, application deployment, and orchestration. It uses a simple,
human-readable YAML syntax and connects to nodes via SSH: no agents required.

In this project, Ansible bootstraps the homelab nodes before K3s installation:
installing tools, configuring kernel parameters, and ensuring prerequisites.

## How It Works

```
 ┌──────────────────────────────────────────────────────────────┐
 │                     Admin Machine                             │
 │                                                               │
 │  ┌────────────────────────────────────────────────────────┐  │
 │  │                 Ansible Control Node                     │  │
 │  │                                                          │  │
 │  │  ┌──────────┐    ┌──────────┐    ┌──────────────────┐  │  │
 │  │  │Inventory │    │ Playbook │    │    Roles         │  │  │
 │  │  │ (hosts)  │    │ (tasks)  │    │  bootstrap-node  │  │  │
 │  │  │          │    │          │    │  install-kubectl │  │  │
 │  │  │ server    │    │ - import │    │  install-helm    │  │  │
 │  │  │ agent   │    │   roles  │    └──────────────────┘  │  │
 │  │  └──────────┘    └────┬─────┘                          │  │
 │  └───────────────────────┼────────────────────────────────┘  │
 │                          │ SSH                                │
 └──────────────────────────┼───────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
 ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
 │    server     │  │   agent     │  │   (add more) │
 │              │  │              │  │              │
 │ • kubectl    │  │ • kubectl    │  │              │
 │ • helm       │  │ • helm       │  │              │
 │ • kernel mods│  │ • kernel mods│  │              │
 │ • sysctl     │  │ • sysctl     │  │              │
 └──────────────┘  └──────────────┘  └──────────────┘
```

## Core Concepts

| Concept | Description |
|---------|-------------|
| **Inventory** | List of managed nodes (hosts, groups, variables) |
| **Playbook** | YAML file defining a sequence of tasks to execute |
| **Task** | Single action (install package, copy file, run command) |
| **Role** | Reusable collection of tasks, variables, and handlers |
| **Module** | Unit of work: Ansible ships with 1000+ built-in modules |
| **Fact** | System information gathered from nodes (OS, arch, IPs) |
| **Handler** | Task triggered by notifications (e.g., restart service) |
| **Idempotent** | Running the same playbook twice produces no changes |

## Architecture-Aware Bootstrapping

Ansible gathers **facts** about each node and adapts behavior:

```yaml
# vars/main.yml: architecture detection
kubectl_arch_map:
  aarch64: arm64    # K3s on ARM64 SBC
  x86_64: amd64     # Standard x86 servers
```

```yaml
# tasks/main.yml: use facts to download correct binary
- name: Download kubectl
  get_url:
    url: "https://dl.k8s.io/release/v{{ kubectl_version }}/bin/linux/{{ arch_map[ansible_architecture] }}/kubectl"
    dest: /usr/local/bin/kubectl
    mode: '0755'
```

## Best Practices

### Project Structure

```
ansible/
├── ansible.cfg        # Global Ansible configuration
├── inventory.yml       # Node inventory (gitignored)
├── inventory.example.yml  # Template (committed)
├── playbook.yml        # Main playbook
├── group_vars/         # Variables per group
├── host_vars/          # Variables per host
├── roles/
│   ├── bootstrap-node/
│   │   ├── tasks/main.yml
│   │   ├── vars/main.yml
│   │   └── defaults/main.yml
│   ├── install-kubectl/
│   └── install-helm/
└── vars/
    └── main.yml
```

### Idempotency

```yaml
# Bad: runs every time
- name: Install kubectl
  command: curl -LO https://...

# Good: idempotent
- name: Check if kubectl is installed
  command: kubectl version --client --short
  register: kubectl_check
  failed_when: false
  changed_when: false

- name: Install kubectl
  get_url:
    url: "https://..."
    dest: /usr/local/bin/kubectl
    mode: '0755'
  when: kubectl_check.rc != 0 or kubectl_version not in kubectl_check.stdout
```

### Variables

```yaml
# defaults/main.yml: lowest precedence (overridable)
kubectl_version: "1.36.0"

# vars/main.yml: higher precedence (role-specific)
helm_version: "4.1.4"

# group_vars/all.yml: even higher
ansible_user: root

# inventory.yml: highest precedence
node-server:
  ansible_host: <CONTROL_PLANE_IP>
  ansible_user: root
```

### Secrets Management

```bash
# NEVER commit real values
ansible/inventory.yml    → .gitignore
infra/.env               → .gitignore

# Commit templates instead
ansible/inventory.example.yml  → committed
infra/env.example              → committed
```

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **SSH keys** | Use key-based auth; rotate keys regularly |
| **Sudo access** | Limit sudo to specific commands via sudoers |
| **Playbook secrets** | Never hardcode; use `ansible-vault` or env vars |
| **Inventory exposure** | `inventory.yml` is gitignored; contains IPs |
| **Become password** | Set `become_ask_pass = True` for interactive prompt |
| **Ansible Galaxy** | Pin role versions; review third-party roles |

## Configuration in This Project

### Roles

| Role | Purpose |
|------|---------|
| **bootstrap-node** | Install prerequisites (curl, socat, conntrack), load kernel modules, set sysctl, disable swap |
| **install-kubectl** | Download and install kubectl (version-pinned, arch-aware, idempotent) |
| **install-helm** | Download and install helm (version-pinned, arch-aware, idempotent) |

### Playbook Flow

```
 Playbook (playbook.yml)
    │
    ├── hosts: all
    │   └── roles:
    │       ├── bootstrap-node       # Kernel modules, sysctl, swap
    │       ├── install-kubectl      # kubectl binary
    │       └── install-helm         # helm binary
    │
    └── gather_facts: yes   # Auto-detect OS, architecture
```

### Makefile Integration

```makefile
ansible-ping:
	ansible all -m ping --ask-become-pass

ansible-check:
	ansible-playbook ansible/playbook.yml --check --ask-become-pass

ansible-bootstrap:
	ansible-playbook ansible/playbook.yml --ask-become-pass

ansible-lint:
	ansible-lint ansible/playbook.yml --profile production
```

## Use Cases

| Use Case | Why Ansible |
|----------|-------------|
| **Node bootstrapping** | Agentless; runs over SSH; no pre-installed agents |
| **Configuration drift** | Ensure all nodes have identical configuration |
| **K3s prerequisites** | Install tools + kernel config before K3s |
| **Repeatable setup** | Idempotent: safe to re-run on new or existing nodes |
| **Documentation as code** | Playbook documents exactly what's installed |

## Official References

- [Ansible Documentation](https://docs.ansible.com/)
- [Getting Started](https://docs.ansible.com/ansible/latest/getting_started/)
- [Playbook Guide](https://docs.ansible.com/ansible/latest/playbook_guide/)
- [Inventory Guide](https://docs.ansible.com/ansible/latest/inventory_guide/)
- [Module Index](https://docs.ansible.com/ansible/latest/collections/index_module.html)
- [Best Practices](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html)
- [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/)
