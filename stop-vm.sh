#!/bin/bash
# Stop Proxmox Test VM

echo "Stopping Proxmox test VM..."

# Try graceful shutdown first
ssh -p 2222 root@localhost "shutdown -h now" 2>/dev/null && {
    echo "Graceful shutdown initiated..."
    sleep 10
}

# Kill if still running
pkill -f "qemu-system-x86_64.*proxmox-test" && {
    echo "VM stopped"
} || {
    echo "VM was not running"
}
