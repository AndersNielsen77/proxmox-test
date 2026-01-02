# Proxmox Test Environment

Local nested Proxmox VE installation for testing infrastructure code before deploying to production.

This repository contains scripts to manage a QEMU/KVM-based Proxmox VE 9.1 test environment. Perfect for testing [KFT-Infra](https://github.com/AndersNielsen77/KFT-Infra) deployments safely before production.

## Prerequisites

**Required Software:**
- QEMU/KVM with virtualization support
- SSH client
- VNC viewer (optional, for console access)

**Required Downloads (not in Git):**
- [Proxmox VE 9.1 ISO](https://www.proxmox.com/en/downloads) (~1.8GB) - Place in this directory
- VM disk image: Either create new or use existing `proxmox-test.qcow2`

## Quick Start

```bash
# Clone this repository
git clone https://github.com/AndersNielsen77/proxmox-test.git
cd proxmox-test

# Download Proxmox VE ISO (if needed)
wget https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso

# Start the VM
./start-vm.sh

# Access Proxmox
# Web UI: https://localhost:8006 (root@pam / test1234)
# SSH: ssh -p 2222 root@localhost
```

## Quick Reference

| Item | Value |
|------|-------|
| **Web UI** | https://localhost:8006 |
| **SSH** | `ssh -p 2222 root@localhost` |
| **VNC** | `localhost:5901` |
| **Credentials** | `root@pam` / `test1234` |
| **Node Name** | `pve` |

## Files

```
proxmox-test/
├── start-vm.sh              # Start the Proxmox VM
├── stop-vm.sh               # Stop the VM gracefully
├── revert-to-clean.sh       # Restore to clean snapshot
├── deploy-full-stack.sh     # Full KFT-Infra deployment
├── .gitignore               # Excludes large VM files
└── README.md                # This file

Not in Git (large files):
├── proxmox-ve_9.1-1.iso     # Proxmox installer (~1.8GB)
└── proxmox-test.qcow2       # VM disk image (~20GB)
```

## Usage

### Starting the VM

```bash
./start-vm.sh
```

Wait ~30 seconds for boot, then access via web UI or SSH.

### Stopping the VM

```bash
./stop-vm.sh
```

Gracefully shuts down Proxmox and stops the VM.

### Reverting to Clean State

After testing, restore to a clean Proxmox installation:

```bash
./revert-to-clean.sh
```

This will:
1. Stop the VM
2. Restore the `clean-with-template` snapshot
3. Restart the VM

**Clean state includes:**
- Fresh Proxmox 9.1 installation
- Debian 12 template pre-downloaded
- No containers or VMs deployed

### Full Stack Deployment

Deploy complete KFT-Infra with one command:

```bash
./deploy-full-stack.sh
```

This will:
1. Revert to clean snapshot
2. Install Terraform and Ansible in the VM
3. Deploy all 5 containers (Home Assistant, AdGuard, Homarr, Grafana, Prometheus)
4. Configure services with Ansible
5. Create final snapshot

See [KFT-Infra](https://github.com/AndersNielsen77/KFT-Infra) for manual deployment steps.

## Snapshots

The VM uses QEMU snapshots for instant rollback:

| Snapshot Name | Description |
|---------------|-------------|
| `clean-with-template` | Fresh Proxmox + Debian 12 template |
| `kft-full-stack` | Full KFT-Infra deployment (optional) |

### Managing Snapshots

```bash
# List all snapshots
qemu-img snapshot -l proxmox-test.qcow2

# Create new snapshot
./stop-vm.sh
qemu-img snapshot -c my-snapshot proxmox-test.qcow2
./start-vm.sh

# Restore snapshot
./stop-vm.sh
qemu-img snapshot -a snapshot-name proxmox-test.qcow2
./start-vm.sh
```

## Network Configuration

- **Type:** User-mode networking (NAT)
- **Port Forwards:**
  - Host `8006` → VM `8006` (Proxmox Web UI)
  - Host `2222` → VM `22` (SSH)
- **Container Network:** Containers get DHCP addresses on `vmbr0`

## Integration with KFT-Infra

This test environment is designed to work with [KFT-Infra](https://github.com/AndersNielsen77/KFT-Infra).

**Test environment configuration:**
```hcl
# terraform/terraform-dev.tfvars
proxmox_endpoint = "https://localhost:8006"
proxmox_username = "root@pam"
proxmox_password = "test1234"
node_name        = "pve"
```

## Troubleshooting

### VM won't start

```bash
# Kill any existing QEMU instances
pkill qemu-system-x86_64

# Try starting again
./start-vm.sh
```

### Can't connect to web UI

```bash
# Verify SSH works first
ssh -p 2222 root@localhost "pveversion"

# Check Proxmox web service
ssh -p 2222 root@localhost "systemctl status pveproxy"
```

### SSH host key changed errors

The VM regenerates SSH keys on snapshot restore. Add to `~/.ssh/config`:

```
Host proxmox-test
    HostName localhost
    Port 2222
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
```

Then use: `ssh proxmox-test`

## Development Workflow

1. **Make changes** to KFT-Infra Terraform/Ansible code
2. **Start test VM**: `./start-vm.sh`
3. **Deploy to test**: Use KFT-Infra with `terraform-dev.tfvars`
4. **Verify functionality** in test environment
5. **Revert to clean**: `./revert-to-clean.sh`
6. **Repeat** until confident
7. **Deploy to production** with production credentials

## Why This Exists

- **Safe Testing**: Break things without affecting production
- **Fast Iteration**: Snapshot rollback in seconds
- **Isolated Environment**: Completely separate from production
- **Reproducible**: Consistent test environment every time

## License

MIT License - See LICENSE file for details

## Related Projects

- [KFT-Infra](https://github.com/AndersNielsen77/KFT-Infra) - Infrastructure as Code for home lab deployment
