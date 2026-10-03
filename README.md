# Proxmox test environment

A dedicated local QEMU/KVM Proxmox lab for [KFT-Infra](https://github.com/AndersNielsen77/KFT-Infra).
The lab uses a verified Debian 13 cloud image and the official signed Proxmox packages,
with a Proxmox kernel. No ISO installation or old VM disk/snapshot is required.

The previous scripts used shared passwords, broad process kills, production guest IDs,
manual network rewrites and unconditional cleanup. These entry points now operate only
on the new dedicated `.runtime/` lab; legacy disks are never selected automatically.

## Requirements

Linux x86_64, writable `/dev/kvm` with nested virtualization, Python 3.11+, QEMU,
`qemu-img`, `xorriso`, OpenSSH, internet access, 8 GiB spare RAM and about 20 GiB
actual disk space (60 GiB sparse guest disk). No host administrator settings are changed.
The five test service containers share the lab VM's resources. KFT's Python/Ansible/
Terraform dependencies and this repo's `requirements.txt` must be installed in the
controller environment. Keep both repositories side by side or pass `--repo PATH`.

## Create and start

```bash
python3 lab.py prepare
./start-vm.sh
python3 lab.py status
```

First bootstrap installs Proxmox and reboots **only the dedicated lab VM**. It can take
several minutes; `lab.py status` shows progress, then the installed Proxmox version.
The SSH key and API token are generated for this lab. There is no shared/default password.
`.runtime/` is private (0700) and ignored, including images, keys, known hosts,
generated credentials/inventory and logs. Never commit or reuse those credentials.

| Interface | Address |
|---|---|
| Proxmox API | https://127.0.0.1:18006 |
| SSH | 127.0.0.1:12222, via `python3 lab.py ssh COMMAND` |
| Internal service network | 10.73.0.0/24, NAT through the lab VM |

Port forwards bind only loopback. Lab firewall rules block access to the home,
Tailscale and other private production networks, retaining the lab subnet and QEMU
DNS/NAT subnet. The API uses its local self-signed certificate. The lab uses SSH keys
and an API token; interactive root password login is not configured by default.

The bootstrap follows [Proxmox's Debian 13 installation workflow](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie),
using its signed no-subscription repository. Cloud-image download checksums are verified
against [Debian's published SHA512 manifest](https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS).

## Real integration test

With KFT-Infra's validated controller environment active:

```bash
pip install -r requirements.txt
./deploy-full-stack.sh --repo ../KFT-Infra
```

The runner verifies `pve-test` and its bootstrap marker, then uses KFT's separate
`terraform/test/` root, fixed loopback API endpoint, dedicated guest IDs **901–905**
and **10.73.0.11–15**. It never invokes the home or OVH Terraform roots. It provisions
Home Assistant, AdGuard, Homarr, Grafana and Prometheus, installs guest SSH access
using only the lab public key, runs the actual KFT service roles twice, and probes them.
Errors fail the run; partial failures are not reported as successful deployments.

Evidence is in `.runtime/integration.log`, `ansible-first.log`, `ansible-second.log`
and `integration-results.json`. Review second-run changed/failed counts for idempotence.
The runner does not reproduce real hardware/USB passthrough, TrueNAS pools, UniFi
fresh installation, production backups, OVH websites or a full production restore.
Those require separate ownership and validation. See [actual results and limits](docs/integration-2026-10-03.md).

## Stop and snapshots

```bash
./stop-vm.sh
python3 lab.py snapshot kft-full-stack
python3 lab.py start
# Explicitly restore a snapshot on this dedicated disk only:
./revert-to-clean.sh kft-full-stack
```

Stop sends ACPI powerdown over the dedicated QMP socket and waits for graceful shutdown.
It verifies the recorded PID belongs to this exact QEMU VM; there is no `pkill` or force
kill fallback. Snapshot operations require the VM to be stopped. Restore changes only
the dedicated lab disk and must name a snapshot explicitly. Test containers have boot
startup disabled; re-run the integration workflow when restarting a stopped lab.

## Script checks

```bash
python3 -m unittest discover -s tests -v
bash -n *.sh scripts/bootstrap-proxmox.sh
```

These test process ownership, refusal to overwrite existing disks, reuse of a running
lab without killing it, and loopback-only forwards. They do not replace the real
Terraform/Ansible installation test.
