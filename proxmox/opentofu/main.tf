# =============================================================================
# Proxmox + OpenTofu — Root Module
# =============================================================================
# Single root that manages all 3 VMs in one state file.
# All OpenTofu commands run from this directory.
#
# Target a single environment:
#   tofu plan -target=module.testing_vm
#   tofu apply -target=module.staging_vm
#
# Override variables per environment:
#   tofu plan -var-file=environments/testing.tfvars
# =============================================================================

terraform {
  required_version = ">= 1.10"

  # NOTE: Backend starts as local during bootstrap (gitignored).
  # After Phase 2 provisions the production agent VM and MinIO is deployed,
  # uncomment the S3 backend block below and run: tofu init -migrate-state
  #
  # backend "s3" {
  #   endpoint                    = var.s3_endpoint
  #   bucket                      = var.s3_bucket
  #   key                         = "proxmox-terraform/terraform.tfstate"
  #   region                      = "us-east-1"
  #   encrypt                     = true
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  # }

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Provider Configuration
# ---------------------------------------------------------------------------

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_tls_insecure

  ssh {
    agent       = true
    username    = var.proxmox_ssh_user

    node {
      name    = var.proxmox_node_name
      address = var.proxmox_node_ip
      port    = var.proxmox_ssh_port
    }
  }
}

# =============================================================================
# Testing Environment — Ephemeral K3s Cluster
# =============================================================================
# Minimal single-node K3s server for experimental changes.
# VLAN 30, 2 vCPU, 4GB RAM, 30GB disk.
# No ArgoCD, no observability — just K3s + essential components.
# =============================================================================

module "testing_vm" {
  source = "./modules/vm"

  vm_name        = "k8s-testing"
  vm_id          = 101
  node_name      = var.proxmox_node_name
  cpu_cores      = 2
  memory_mb      = 4096
  disk_size_gb   = 30
  network_bridge = "vmbr0"
  network_vlan   = 30
  ip_address     = "10.0.30.11/24"
  gateway        = "10.0.30.1"
  ssh_keys       = [file(pathexpand(var.ssh_public_key_path))]
  tags           = ["k8s", "env-testing", "role-server"]
}

# =============================================================================
# Staging Environment — Production Mirror
# =============================================================================
# Full GitOps stack mirroring production: ArgoCD, monitoring, AIOps v1.
# VLAN 20, 4 vCPU, 8GB RAM, 50GB disk.
# =============================================================================

module "staging_vm" {
  source = "./modules/vm"

  vm_name        = "k8s-staging"
  vm_id          = 201
  node_name      = var.proxmox_node_name
  cpu_cores      = 4
  memory_mb      = 8192
  disk_size_gb   = 50
  network_bridge = "vmbr0"
  network_vlan   = 20
  ip_address     = "10.0.20.11/24"
  gateway        = "10.0.20.1"
  ssh_keys       = [file(pathexpand(var.ssh_public_key_path))]
  tags           = ["k8s", "env-staging", "role-server"]
}

# =============================================================================
# Production Environment — K3s Agent Node
# =============================================================================
# Joins the existing production K3s cluster as an additional worker node.
# Untagged vmbr0 (existing LAN), 4 vCPU, 8GB RAM, 100GB disk.
# =============================================================================

module "prod_vm" {
  source = "./modules/vm"

  vm_name        = "k8s-prod-agent"
  vm_id          = 301
  node_name      = var.proxmox_node_name
  cpu_cores      = 4
  cpu_type       = "host"
  memory_mb      = 8192
  disk_size_gb   = 100
  network_bridge = "vmbr0"
  network_vlan   = null                        # Untagged — same LAN as existing cluster
  ip_address     = "192.168.50.65/24"          # Same subnet as existing master (192.168.50.60)
  gateway        = "192.168.50.1"
  ssh_keys       = [file(pathexpand(var.ssh_public_key_path))]
  tags           = ["k8s", "env-prod", "role-agent"]
}
