# =============================================================================
# Proxmox + OpenTofu — VM Module
# =============================================================================
# Reusable module for provisioning Proxmox VMs from a cloud-init template.
# Used by all three environments (testing, staging, production).
# =============================================================================

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "vm_name" {
  description = "VM display name in Proxmox"
  type        = string
}

variable "vm_id" {
  description = "Unique VM ID (101=testing, 201=staging, 301=prod)"
  type        = number
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
}

variable "template_id" {
  description = "Template VM ID to clone from"
  type        = number
  default     = 9000
}

variable "cpu_cores" {
  description = "Number of vCPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in MB"
  type        = number
  default     = 4096
}

variable "disk_size_gb" {
  description = "Disk size in GB"
  type        = number
  default     = 30
}

variable "disk_datastore" {
  description = "Proxmox datastore ID for VM disk"
  type        = string
  default     = "vm-storage"
}

variable "network_bridge" {
  description = "Proxmox bridge name"
  type        = string
  default     = "vmbr0"
}

variable "network_vlan" {
  description = "VLAN tag (null = untagged)"
  type        = number
  default     = null
}

variable "network_model" {
  description = "Network device model"
  type        = string
  default     = "virtio"
}

variable "ip_address" {
  description = "Static IPv4 in CIDR notation (e.g., 10.0.20.11/24)"
  type        = string
}

variable "gateway" {
  description = "Default gateway IP"
  type        = string
}

variable "dns_servers" {
  description = "DNS server IPs"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_user" {
  description = "Cloud-init default user"
  type        = string
  default     = "ubuntu"
}

variable "ssh_keys" {
  description = "List of public SSH keys for cloud-init"
  type        = list(string)
}

variable "cloud_init_user_data_file" {
  description = "Path to cloud-init user-data YAML file"
  type        = string
  default     = null
}

variable "tags" {
  description = "Proxmox tags for the VM"
  type        = list(string)
  default     = []
}

variable "on_boot" {
  description = "Start VM on Proxmox host boot"
  type        = bool
  default     = true
}

variable "agent_enabled" {
  description = "Enable QEMU guest agent"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# VM Resource
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.vm_name
  node_name = var.node_name
  vm_id     = var.vm_id
  tags      = var.tags
  on_boot   = var.on_boot

  agent {
    enabled = var.agent_enabled
  }

  clone {
    vm_id = var.template_id
    full  = true
  }

  cpu {
    cores   = var.cpu_cores
    sockets = 1
    type    = "x86-64-v2-AES"
    numa    = false
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.disk_datastore
    interface    = "scsi0"
    size         = var.disk_size_gb
      discard           = "on"
      ssd               = true
    }

  network_device {
    bridge  = var.network_bridge
    model   = var.network_model
    vlan_id = var.network_vlan
  }

  initialization {
    datastore_id = "local-zfs"

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.ssh_user
      keys     = var.ssh_keys
    }

    user_data_file_id = var.cloud_init_user_data_file != null ? proxmox_virtual_environment_file.user_data[0].id : null
  }

  stop_on_destroy     = true
  reboot_after_update = true

  lifecycle {
    ignore_changes = [
      network_device[0].mac_address,
    ]
  }
}

# ---------------------------------------------------------------------------
# Cloud-Init User Data (uploaded as Proxmox snippet)
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_file" "user_data" {
  count = var.cloud_init_user_data_file != null ? 1 : 0

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name

  source_raw {
    data      = file(var.cloud_init_user_data_file)
    file_name = "cloud-init-${var.vm_name}.yaml"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.vm.id
}

output "vm_name" {
  description = "VM display name"
  value       = proxmox_virtual_environment_vm.vm.name
}

output "ipv4_address" {
  description = "VM IPv4 address (without CIDR)"
  value       = element(split("/", var.ip_address), 0)
}

output "ipv4_cidr" {
  description = "VM IPv4 address with CIDR"
  value       = var.ip_address
}
