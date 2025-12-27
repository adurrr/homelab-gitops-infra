# =============================================================================
# Proxmox + OpenTofu — Shared Input Variables
# =============================================================================
# All values are sourced from environment variables (TF_VAR_*) or .tfvars files.
# DO NOT commit real values — use proxmox/.env (gitignored).
# =============================================================================

# --- Proxmox Connection ---

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint (e.g., https://pve.local:8006/)"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID (format: user@pve!token-name)"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification (true for self-signed certs)"
  type        = bool
  default     = true
}

variable "proxmox_node_name" {
  description = "Proxmox node name (e.g., 'pve')"
  type        = string
  default     = "pve"
}

variable "proxmox_node_ip" {
  description = "Proxmox node IP for SSH/SFTP snippet uploads"
  type        = string
  default     = "192.168.1.2"
}

variable "proxmox_ssh_user" {
  description = "SSH user for file/snippet uploads to Proxmox"
  type        = string
  default     = "root"
}

variable "proxmox_ssh_private_key_path" {
  description = "Path to SSH private key for Proxmox SFTP"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "proxmox_ssh_port" {
  description = "SSH port on Proxmox host"
  type        = number
  default     = 22
}

# --- S3 Backend (deferred — see main.tf) ---

variable "s3_endpoint" {
  description = "MinIO/S3 endpoint for state storage"
  type        = string
  default     = ""
}

variable "s3_bucket" {
  description = "S3 bucket name for state storage"
  type        = string
  default     = ""
}

# --- VM Template ---

variable "template_id" {
  description = "Proxmox VM template ID to clone from (created manually in Phase 1)"
  type        = number
  default     = 9000
}

# --- SSH ---

variable "ssh_public_key_path" {
  description = "Path to SSH public key for cloud-init injection"
  type        = string
  default     = "~/.ssh/proxmox_vm_key.pub"
}

# --- K3s ---

variable "k3s_token_testing" {
  description = "K3s cluster token for testing environment"
  type        = string
  sensitive   = true
}

variable "k3s_token_staging" {
  description = "K3s cluster token for staging environment"
  type        = string
  sensitive   = true
}

variable "k3s_token_prod" {
  description = "K3s cluster token for production (must match existing cluster)"
  type        = string
  sensitive   = true
}

variable "existing_k3s_server_ip" {
  description = "IP of the existing production K3s server (for agent join)"
  type        = string
}

variable "existing_k3s_server_port" {
  description = "Port of the existing production K3s server"
  type        = number
  default     = 6443
}
