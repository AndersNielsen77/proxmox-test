# Verified KFT integration — 2026-10-03

A real local QEMU/KVM lab was created from the checksum-verified Debian 13 cloud
image. It ran Proxmox 9.2.21, kernel 7.0.14-20-pve. Bootstrap needed manual GRUB and
ifupdown fixes during development; those fixes are included in the current bootstrap
script, but the final script has not been replayed on a second completely fresh disk.

KFT-Infra's dedicated `terraform/test/` root provisioned five Debian 13 unprivileged
LXC containers, IDs 901–905, on 10.73.0.11–15. Actual Ansible roles installed the stack.
The root-token restriction on `keyctl` was found and corrected; nesting alone worked
for the tested Docker services.

| Service | Verification |
|---|---|
| Home Assistant 2026.9.4 | Docker application and HTTP 302 |
| AdGuard 0.107.79 | HTTP 302, generated credential status API 200, DNS resolution |
| Homarr v2.0.0 | Docker application and HTTP 307 |
| Grafana | Generated credential API 200, datasource health 200, provisioned Node Exporter dashboard API 200 with corrected datasource UID |
| Prometheus | Ready HTTP 200, all six scrape targets up |

Fresh installation succeeded. After corrections, two final configuration runs each
reported five hosts with `changed=0`, `unreachable=0`, `failed=0`. The integration
runner fails on failed native probes or a non-idempotent second run. Four process/disk/
loopback guard unit tests and shell syntax checks passed.

The lab was gracefully stopped using QMP ACPI shutdown; an offline snapshot named
`kft-full-stack` was created. Snapshot restore has not been tested. Runtime state,
credentials and logs remain private and ignored under `.runtime/`.

Production guests were not deployed/restarted by these tests. No production USB,
TrueNAS pool/disk/restore, fresh UniFi installation, GUI dashboard rendering, HA
onboarding, Homarr user workflow or complete fleet recovery was verified. See KFT's
[production coverage report](https://github.com/AndersNielsen77/KFT-Infra/blob/maintenance/home-ovh-refresh/docs/guest-coverage-and-integration-2026-10-03.md)
for all 22 running production guests and remaining issues.
