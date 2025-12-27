# =============================================================================
# Proxmox + OpenTofu — Shared Outputs
# =============================================================================
# Outputs are used to generate Ansible inventory and for operator reference.
# =============================================================================

# --- Per-Environment VM Info ---

# Testing
output "testing_vm_ip" {
  description = "Testing VM IPv4 address"
  value       = module.testing_vm.ipv4_address
}

output "testing_vm_id" {
  description = "Testing VM Proxmox ID"
  value       = module.testing_vm.vm_id
}

# Staging
output "staging_vm_ip" {
  description = "Staging VM IPv4 address"
  value       = module.staging_vm.ipv4_address
}

output "staging_vm_id" {
  description = "Staging VM Proxmox ID"
  value       = module.staging_vm.vm_id
}

# Production
output "prod_vm_ip" {
  description = "Production agent VM IPv4 address"
  value       = module.prod_vm.ipv4_address
}

output "prod_vm_id" {
  description = "Production agent VM Proxmox ID"
  value       = module.prod_vm.vm_id
}

# --- Ansible Inventory ---

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.tmpl", {
    testing_vm_ip = module.testing_vm.ipv4_address
    staging_vm_ip = module.staging_vm.ipv4_address
    prod_vm_ip    = module.prod_vm.ipv4_address
  })
  filename = "${path.module}/../ansible/inventory.ini"
}
