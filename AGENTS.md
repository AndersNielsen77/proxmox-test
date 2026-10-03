# proxmox-test

- This repo controls only `.runtime/proxmox-test.qcow2` and QEMU name `proxmox-test-kft`.
- Never select legacy disks, production hosts/IDs or unrelated QEMU processes automatically.
- Use `lab.py` for lifecycle; no broad process kills or password defaults.
- Test keys/tokens, generated inventory and raw logs stay in ignored `.runtime/` (0700).
- KFT integration must use the fixed loopback `terraform/test/` root and IDs 901–905.
- Run the stdlib unit tests and shell syntax checks for script changes.
- Distinguish script validation, actual lab deployment and production verification in results.
