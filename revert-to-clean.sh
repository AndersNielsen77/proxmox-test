#!/bin/bash
# Revert Proxmox Test VM to Clean State

echo "========================================="
echo "Reverting to Clean Proxmox Installation"
echo "========================================="
echo ""
echo "This will:"
echo "  1. Stop the VM"
echo "  2. Restore snapshot 'clean-with-template'"
echo "  3. Restart the VM"
echo ""
echo "All containers and VMs will be deleted!"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 1
fi

# Stop VM
echo "Stopping VM..."
./stop-vm.sh

# Restore snapshot
echo "Restoring snapshot..."
qemu-img snapshot -a clean-with-template $HOME/proxmox-test/proxmox-test.qcow2

if [ $? -eq 0 ]; then
    echo "Snapshot restored successfully"
else
    echo "Error restoring snapshot!"
    exit 1
fi

# Restart VM
echo "Starting VM..."
./start-vm.sh

echo ""
echo "========================================="
echo "Revert complete!"
echo "========================================="
echo "Access: https://localhost:8006"
echo "Login: root / test1234"
