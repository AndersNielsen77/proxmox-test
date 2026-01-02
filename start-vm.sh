#!/bin/bash
# Start Proxmox Test VM

# Kill any existing instances
pkill -f "qemu-system-x86_64.*proxmox-test" 2>/dev/null

echo "Starting Proxmox test VM..."
echo "Access:"
echo "  Web UI: https://localhost:8006"
echo "  SSH:    ssh -p 2222 root@localhost"
echo "  VNC:    gvncviewer localhost:5901"
echo ""
echo "Root password: test1234"
echo ""

qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -name proxmox-test \
  -drive file=$HOME/proxmox-test/proxmox-test.qcow2,format=qcow2,if=virtio \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::8006-:8006,hostfwd=tcp::2222-:22 \
  -vnc 127.0.0.1:1 \
  -daemonize

echo "VM started in background"
echo "Waiting for boot (30 seconds)..."
sleep 30
echo "VM should be ready now!"
