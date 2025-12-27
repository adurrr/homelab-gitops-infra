# Proxmox + OpenTofu Troubleshooting Runbook

All issues encountered during Phase 0-2 implementation, with root causes and fixes.

> **Security:** Real IPs, hostnames, and port numbers are replaced with placeholders.
> `$PROXMOX_IP` = Proxmox host IP, `$VLAN_SUBNET` = VLAN subnet prefix, `$SSH_PORT` = non-standard SSH port.

---

## 1. Proxmox API Token Permissions

### `VM.Monitor`, Invalid privilege in PVE 9.x

**Error:** `400 Parameter verification failed. privs: invalid format - invalid privilege 'VM.Monitor'`

**Root cause:** `VM.Monitor` was removed in Proxmox VE 9.0 and replaced by `VM.GuestAgent.*` + `Sys.Audit`.

**Fix:** Use `VM.GuestAgent.Audit`, `VM.GuestAgent.FileRead`, `VM.GuestAgent.FileWrite`, `VM.GuestAgent.FileSystemMgmt`, `VM.GuestAgent.Unrestricted` instead of `VM.Monitor`.

```bash
pveum role add TerraformRole -privs "\
VM.Allocate,VM.Clone,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.CDROM,VM.Config.Disk,\
VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Audit,VM.Backup,VM.Console,VM.PowerMgmt,VM.Migrate,VM.Snapshot,\
VM.Snapshot.Rollback,VM.GuestAgent.Audit,VM.GuestAgent.FileRead,\
VM.GuestAgent.FileWrite,VM.GuestAgent.FileSystemMgmt,VM.GuestAgent.Unrestricted,\
Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,\
Datastore.Audit,Pool.Allocate,Pool.Audit,Sys.Audit,Sys.Modify"
```

### `SDN.Use`, Missing SDN permission

**Error:** `received an HTTP 403 response - Reason: Permission check failed (/sdn/zones/localnetwork/vmbr0, SDN.Use)`

**Root cause:** VLAN-tagged VMs need SDN permissions on the specific bridge path. With `--privsep 1` (privilege separation), both the user AND the token need SDN permissions.

**Fix:**
```bash
# Grant to BOTH user and token
pveum acl modify /sdn/zones/localnetwork/vmbr0 -user terraform@pve -role PVESDNUser
pveum acl modify /sdn/zones/localnetwork/vmbr0 -token 'terraform@pve!terraform' -role PVESDNUser
```

### `VM.Config.CDROM`, Missing CDROM permission

**Error:** `received an HTTP 403 response - Permission check failed (/vms/<VMID>, VM.Config.CDROM)`

**Root cause:** Cloud-init drive configuration during clone requires `VM.Config.CDROM` privilege, even when using SCSI for cloud-init.

**Fix:** Add `VM.Config.CDROM` to the TerraformRole privileges list (included above).

### `SDN.Allocate` / `Datastore.AllocateTemplate`, Not in minimal role

**Error:** Various 403 responses during VM creation.

**Fix:** These are in the full privilege list above. The `TerraformRole` should include `Datastore.AllocateTemplate` (for snippet/cloud-init uploads) and SDN privileges (for VLAN-tagged networks).

---

## 2. SSH Connectivity (bpg/proxmox Provider)

### Custom cloud-init snippets require SSH/SFTP (PAM)

**Context:** `proxmox_virtual_environment_file` with `content_type = "snippets"` requires SSH/SFTP upload to the Proxmox host. This uses the provider's SSH configuration and requires a PAM account (root) with key-based auth.

**Workaround:** If SSH agent issues persist, skip custom cloud-init snippets entirely. Use the `initialization {}` block with Proxmox's native cloud-init (no SSH needed), and handle OS configuration via Ansible post-provisioning.

```hcl
# Rely on native cloud-init (no snippet upload)
initialization {
  datastore_id = "local-zfs"
  ip_config {
    ipv4 { address = "$VM_IP/24", gateway = "$VM_GATEWAY" }
  }
  user_account {
    username = "ubuntu"
    keys     = [file(pathexpand(var.ssh_public_key_path))]
  }
}
# Do NOT set cloud_init_user_data_file, skip custom snippets
```

---

## 3. Storage Configuration

### `local-lvm` doesn't exist on ZFS-only Proxmox

**Error:** `storage 'local-lvm' does not exist`

**Root cause:** Proxmox 9.x with only ZFS storage (`local-zfs`) has no `local-lvm`. The bpg provider defaults `initialization.datastore_id` to `local-lvm` for cloud-init drives.

**Fix:** Explicitly set `datastore_id` on the `initialization` block:
```hcl
initialization {
  datastore_id = "local-zfs"   # Must match your actual storage
}
```

### Cloud-init on IDE + ZFS causes QEMU boot failure

**Error:** `start failed: QEMU exited with code 1`

**Root cause:** Proxmox 9.x has a regression where cloud-init drives on IDE (`ide2`) + ZFS storage cause QEMU to crash at boot. No clear error message in logs.

**Fix:** Use SCSI for cloud-init drives instead of IDE:
```bash
# Template creation, use SCSI for cloud-init
qm set <template-id> --scsi1 local-zfs:cloudinit    # NOT --ide2
```

### ZFS dataset conflicts (stale VM leftovers)

**Error:** `zfs error: cannot create 'rpool/data/vm-<vmid>-cloudinit': dataset already exists`

**Root cause:** Destroying a VM via `qm destroy` sometimes leaves ZFS datasets behind. When OpenTofu tries to recreate the VM, it finds the existing dataset.

**Fix:**
```bash
# Check for stale datasets
zfs list -r rpool/data | grep vm-<vmid>
zfs list -r tank/vmdata | grep vm-<vmid>

# If datasets are busy (zvols with kernel references):
zfs rename rpool/data/vm-<vmid>-cloudinit rpool/data/vm-<vmid>-cloudinit-old
# Then recreate VM, the original name is freed

# For non-busy datasets:
zfs destroy -f rpool/data/vm-<vmid>-cloudinit
```

### `ssd=1` on HDD storage

**Context:** If the VM storage pool is on HDD (not SSD), setting `ssd=1` causes unnecessary TRIM operations.

**Fix:** Use `ssd=0` for disks on HDD storage:
```bash
qm set <template-id> --scsi0 <hdd-storage>:vm-<template-id>-disk-0,discard=on,ssd=0
```

### `cloudinit` content type not valid for ZFS pools

**Error:** `400 Parameter verification failed. content: invalid format - invalid content type 'cloudinit'`

**Root cause:** `pvesm add zfspool` doesn't accept `cloudinit` as a content type in Proxmox 9.x. Cloud-init ISOs must be on `dir` type storage.

**Fix:** Register ZFS storage without cloudinit, and use the SSD-backed ZFS pool for cloud-init:
```bash
pvesm add zfspool vm-storage --pool tank/vmdata --content images,rootdir
# Cloud-init stays on the SSD ZFS pool (fast, supports cloudinit)
```

### `snippets` content type missing on `local` storage

**Error:** `the datastore "local" does not support content type "snippets"`

**Root cause:** Proxmox 9.x `local` storage (dir type) doesn't include `snippets` by default.

**Fix:**
```bash
pvesm set local --content iso,vztmpl,backup,snippets
```

---

## 4. VM Configuration

### `x86-64-v2-AES` CPU type compatibility with `--cpu host` template

**Context:** The OpenTofu module sets `cpu.type = "x86-64-v2-AES"` which is a generic CPU model. If the template uses `--cpu host`, the cloned VM inherits the host CPU but OpenTofu overrides it to `x86-64-v2-AES`. This is safe for cloning and live migration but may cause minor performance loss.

**Status:** This combination works without errors in Proxmox 9.x. No action needed.

### Proxmox 9.x tag format, no colons

**Error:** `Parameter verification failed. (tags: invalid format - invalid characters in tag)`

**Root cause:** Proxmox 9.x restricts tag characters. Colons (`:`) are not allowed.

**Fix:** Use hyphens instead of colons:
```hcl
tags = ["k8s", "env-testing", "role-server"]   # NOT ["k8s", "env:testing", "role:server"]
```

### `iothread` incompatible with `virtio-scsi-pci`

**Warning:** `WARN: iothread is only valid with virtio disk or virtio-scsi-single controller, ignoring`

**Root cause:** The `iothread = true` setting in the disk block only works with `virtio-scsi-single`, not `virtio-scsi-pci`. With `virtio-scsi-pci`, it's silently ignored.

**Fix:** Remove `iothread = true` from disk blocks when using `virtio-scsi-pci`:
```hcl
disk {
  datastore_id = "vm-storage"
  interface    = "scsi0"
  size         = 30
  discard      = "on"
  ssd          = false
  # iothread = true   # Remove, not compatible with virtio-scsi-pci
}
```

### QEMU guest agent not installed in cloud image

**Symptom:** `qm agent <vmid> network-get-interfaces` returns "QEMU guest agent is not running"

**Root cause:** Ubuntu 24.04 cloud images don't include `qemu-guest-agent` by default. Without it, OpenTofu can't detect the VM's IP address, causing `tofu apply` to hang waiting for networking info.

**Fix:** Boot the template once before converting to template, so cloud-init installs packages:
```bash
qm start 9000 && sleep 300 && qm stop 9000 && qm template 9000
```

The cloud-init `base.yaml` includes `qemu-guest-agent` in the `packages:` list and `systemctl enable qemu-guest-agent` in `runcmd:`.

---

## 5. Networking

### VLAN-tagged VM can't reach gateway, bridge not VLAN-aware

**Error:** `no physical interface on bridge 'vmbr0'` / `kvm: -netdev ... network script failed with status 6400`

**Root cause:** The Proxmox bridge `vmbr0` was not configured as VLAN-aware. Tagged traffic had nowhere to go.

**Fix:** Make the bridge VLAN-aware permanently in `/etc/network/interfaces`:
```
auto vmbr0
iface vmbr0 inet static
    address $PROXMOX_IP/24
    gateway $LAN_GATEWAY
    bridge-ports <physical-nic>
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

Reload: `ifreload -a`

### VM can't reach internet, bridge bypasses iptables

**Symptom:** VM can ping VLAN gateway but can't ping public IPs. `tcpdump` shows packets going OUT on the physical NIC but no replies.

**Root cause:** Linux bridges skip netfilter/iptables by default (`net.bridge.bridge-nf-call-iptables=0`). NAT rules (MASQUERADE) are invisible to bridged traffic.

**Fix:**
```bash
# Enable bridge iptables processing
sysctl -w net.bridge.bridge-nf-call-iptables=1
echo 'net.bridge.bridge-nf-call-iptables=1' > /etc/sysctl.d/99-bridge-nf.conf

# Use SNAT (more explicit than MASQUERADE for bridged traffic)
iptables -t nat -A POSTROUTING -s <VLAN20_SUBNET> -j SNAT --to-source $PROXMOX_IP
iptables -t nat -A POSTROUTING -s <VLAN30_SUBNET> -j SNAT --to-source $PROXMOX_IP

# Forward rules (both directions)
iptables -A FORWARD -i vmbr0.20 -o <physical-nic> -j ACCEPT
iptables -A FORWARD -i vmbr0.30 -o <physical-nic> -j ACCEPT
iptables -A FORWARD -i <physical-nic> -o vmbr0.20 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i <physical-nic> -o vmbr0.30 -m state --state ESTABLISHED,RELATED -j ACCEPT

# Save
iptables-save > /etc/iptables/rules.v4
```

### VLAN interfaces don't persist across reboots

**Symptom:** After reboot, `ip link show vmbr0.<vlan-id>` returns nothing.

**Root cause:** `ip link add link vmbr0 name vmbr0.30 type vlan id 30` is temporary. It's lost on reboot.

**Fix:** Add to `/etc/network/interfaces`:
```
auto vmbr0.30
iface vmbr0.30 inet static
    address <VLAN30_GATEWAY>/24

auto vmbr0.20
iface vmbr0.20 inet static
    address <VLAN20_GATEWAY>/24
```

### Proxmox SSH non-standard port

**Context:** The SSH config on the admin machine uses a non-standard port for `ssh proxmox`, but the bpg provider doesn't read `~/.ssh/config`. The port must be explicitly set in the provider's `ssh.node.port`.

**Fix:** Already in the provider config, see §2 above.

---

## 6. OpenTofu / Provider Issues

### State lock conflicts after interrupted apply

**Symptom:** `Error acquiring the state lock: resource temporarily unavailable`

**Root cause:** A previous `tofu apply` was interrupted (Ctrl+C) or timed out, leaving the state lock file behind.

**Fix:**
```bash
# For local state:
rm -f proxmox/opentofu/terraform.tfstate.tflock

# If another process still holds it:
pkill tofu
rm -f proxmox/opentofu/terraform.tfstate.tflock
```

### Config file already exists after failed destroy

**Error:** `unable to create VM <vmid>: config file already exists`

**Root cause:** VM was destroyed from Proxmox but the config file or ZFS datasets weren't fully cleaned. Tofu can't recreate it.

**Fix:**
```bash
# On Proxmox host, remove config file
rm -f /etc/pve/qemu-server/<vmid>.conf

# And clean ZFS datasets (see §3)
zfs rename rpool/data/vm-<vmid>-cloudinit rpool/data/vm-<vmid>-cloudinit-old
```

### `tofu apply` hangs waiting for guest agent

**Symptom:** `tofu apply` shows "Still creating..." for 5+ minutes then times out.

**Root cause:** The bpg provider waits for QEMU guest agent to report the VM's IP. If the guest agent isn't running (see §4), the provider waits until timeout.

**Workaround:**
1. Boot template once before converting (install guest agent)
2. Kill the stuck tofu process (`Ctrl+C`)
3. The VM is actually created, check `qm status <vmid>`
4. Remove state lock and re-apply with `-refresh-only`

### Module providers must be declared in module

**Error:** `Could not retrieve the list of available versions for provider hashicorp/proxmox`

**Root cause:** The VM module uses `proxmox_virtual_environment_vm` but doesn't declare `required_providers`. OpenTofu tries to use `hashicorp/proxmox` (doesn't exist) instead of `bpg/proxmox`.

**Fix:** Add to `modules/vm/main.tf`:
```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78.0"
    }
  }
}
```

### `file()` function can't expand `~` tilde

**Error:** `no file exists at "~/.ssh/id_ed25519.pub"`

**Root cause:** OpenTofu's `file()` function doesn't expand `~` to the home directory.

**Fix:** Use `pathexpand()`:
```hcl
ssh_keys = [file(pathexpand(var.ssh_public_key_path))]
```

### Environment directory approach doesn't work for tofu validate

**Context:** Per-environment directories (`environments/testing/main.tf`) were tried initially. They don't work because each environment needs its own provider config, creating duplication.

**Fix:** Single root `main.tf` with all module blocks in one file. Use `-target=module.testing_vm` to apply single environments. See `proxmox/opentofu/main.tf`.

---

## 7. Template & Cloud-Init

### Template never booted, guest agent not installed

**Symptom:** VMs clone fine but `qm agent <vmid>` fails and tofu times out.

**Fix:** Boot the template once for 5 minutes before templating:
```bash
qm start 9000 && sleep 300 && qm stop 9000 && qm template 9000
```

### Ubuntu cloud image downloaded but not bootable

**Context:** Downloaded `noble-server-cloudimg-amd64.img` to `/var/lib/vz/template/iso/`. Must be imported via `qm importdisk`, not just placed there.

```bash
qm importdisk 9000 /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img vm-storage
```

### Cloud-init SSH key path on Proxmox

**Context:** The `--sshkey` flag in `qm set` must point to a PUBLIC key file on the Proxmox host:
```bash
qm set 9000 --sshkey /root/.ssh/id_ed25519.pub
```

The key injected into the template is later **overridden** by OpenTofu's `initialization.user_account.keys` when the VM is cloned. The template key is just a placeholder.

---

## 8. SSH Access to VMs

### SSH key mismatch between admin and Proxmox

**Symptom:** VMs accept SSH only from Proxmox host, not from admin machine.

**Root cause:** The VM's cloud-init SSH key was set to Proxmox's key, but the admin machine has a different key. OpenTofu's `initialization` block injects whatever key is at `var.ssh_public_key_path`.

**Fix:** Either:
1. Copy Proxmox's public key to the admin machine: `echo '<key-content>' > ~/.ssh/proxmox_vm_key.pub`
2. Or use SSH ProxyJump through Proxmox: `ssh -J root@$PROXMOX_IP:$SSH_PORT ubuntu@<vm-ip>`

### VM on isolated VLAN unreachable from admin machine

**Symptom:** Admin machine can't reach VMs on isolated VLANs.

**Root cause:** VLANs are isolated L2 domains. The admin machine doesn't have an interface on those VLANs.

**Fix:** Access VMs via Proxmox host (which has VLAN interfaces). Use SSH ProxyJump as shown above.

---

## Quick Reference: Common Fixes

| Problem | Quick check | Fix command |
|---------|------------|-------------|
| API 403 | `pveum user token permissions terraform@pve terraform` | Add privileges via `pveum acl modify` |
| SSH auth | `ssh-add -l` | `ssh-add ~/.ssh/id_ed25519` |
| VM won't boot | `qm config <vmid> \| grep ide2` | Use `scsi1` for cloud-init |
| No internet | `sysctl net.bridge.bridge-nf-call-iptables` | Set to 1 + add SNAT rule |
| VLAN not working | `ip link show vmbr0.30` | Add to /etc/network/interfaces |
| State locked | `ls terraform.tfstate.tflock` | `rm -f terraform.tfstate.tflock` |
| Stale ZFS dataset | `zfs list -r rpool/data \| grep vm-` | `zfs rename ...-old; zfs destroy -f ...-old` |
| Guest agent missing | `qm agent <vmid> ping` | Boot template once before templating |
