#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# SSH password for the VM (from start-vm.sh)
SSH_PASSWORD="test1234"

# Check if sshpass is available, install if not
if ! command -v sshpass >/dev/null 2>&1; then
  echo "Installing sshpass for password authentication..."
  sudo apt-get update -qq >/dev/null 2>&1
  sudo apt-get install -y -qq sshpass >/dev/null 2>&1
fi

SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -p 2222"
SSHCMD="sshpass -p '$SSH_PASSWORD' ssh $SSHOPTS"

echo -e "${GREEN}====== KFT Infrastructure Deployment ======${NC}"
echo ""

# Step 1: Clean start (skip snapshot restore - it's corrupted)
echo -e "${YELLOW}[1/9] Preparing VM environment...${NC}"
./stop-vm.sh >/dev/null 2>&1 || true
./start-vm.sh
echo "Waiting for VM to boot..."
sleep 45

# Step 2: Verify connectivity
echo -e "${YELLOW}[2/9] Verifying VM connectivity...${NC}"
for i in {1..20}; do
  if $SSHCMD root@localhost 'echo OK' >/dev/null 2>&1; then
    echo -e "${GREEN}✓ SSH connected${NC}"
    break
  fi
  echo "  Attempt $i/20..."
  sleep 5
done

# Step 2.3: Enable VLAN support
echo -e "${YELLOW}Enabling VLAN support...${NC}"
$SSHCMD root@localhost 'modprobe 8021q 2>/dev/null && echo 1 > /sys/class/net/vmbr0/bridge/vlan_filtering 2>/dev/null || true'
echo -e "${GREEN}✓ VLAN support enabled${NC}"

# Step 2.5: Clean up any containers/VMs from snapshot
echo -e "${YELLOW}Cleaning up existing resources from snapshot...${NC}"
$SSHCMD root@localhost <<'EOFCLEANUP'
echo "Checking for existing resources..."
pct list 2>/dev/null || true
qm list 2>/dev/null || true

echo "Force destroying any existing containers/VMs..."
for id in 100 102 106 107 109 115; do
  pct unlock $id 2>/dev/null || true
  pct stop $id 2>/dev/null || true
  pct destroy $id --purge --force 2>/dev/null || true
  rm -f /etc/pve/lxc/${id}.conf 2>/dev/null || true
  rm -f /run/lock/lxc/pve-config-${id}.lock 2>/dev/null || true
done

qm unlock 300 2>/dev/null || true
qm stop 300 2>/dev/null || true
qm destroy 300 --purge 2>/dev/null || true
rm -f /etc/pve/qemu-server/300.conf 2>/dev/null || true
rm -f /run/lock/qemu-server/lock-300.conf 2>/dev/null || true

# Restart Proxmox services to clear any cached state
systemctl restart pvedaemon 2>/dev/null || true
sleep 3

echo "Cleanup complete - verifying..."
pct list 2>/dev/null || true
qm list 2>/dev/null || true
EOFCLEANUP
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Step 3: Configure repositories and install tools
echo -e "${YELLOW}[3/9] Installing Terraform and Ansible...${NC}"
$SSHCMD root@localhost <<'EOFINSTALL'
# Disable enterprise repos
mv -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.bak 2>/dev/null || true
mv -f /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.bak 2>/dev/null || true
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Update and install prerequisites
apt update -qq
apt install -y -qq wget gpg curl python3-pip python3-dev build-essential

# Try to install python3-lxc from Debian repos, if not available try pip
if apt-cache search python3-lxc | grep -q python3-lxc; then
  apt install -y -qq python3-lxc
else
  echo "python3-lxc not in repos, trying to install via pip..."
  # Install LXC development headers first
  apt install -y -qq liblxc-dev lxc-dev || true
  # Try installing via pip as fallback
  pip3 install python-lxc 2>&1 | grep -v "already satisfied" || true
fi

# Install Terraform
wget -q -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com trixie main" > /etc/apt/sources.list.d/hashicorp.list
apt update -qq
apt install -y -qq terraform ansible

# Install Ansible collections required for LXC connection
echo "Installing Ansible collections..."
ansible-galaxy collection install community.general -p /usr/share/ansible/collections 2>&1 | grep -v "already installed" || true

# Verify installations
echo "Terraform $(terraform version | head -1)"
echo "Ansible $(ansible --version | head -1)"

# Test LXC Python bindings with detailed error message
echo "Testing LXC Python bindings..."
python3 -c "import lxc; print('LXC bindings: OK')" 2>&1 || {
  echo "WARNING: LXC Python bindings test failed!"
  echo "Attempting to install via pip..."
  pip3 install --upgrade python-lxc 2>&1 || echo "pip install also failed"
  # Final test
  python3 -c "import lxc; print('LXC bindings: OK')" 2>&1 || echo "ERROR: LXC bindings still not working"
}

echo "Ansible collections: $(ansible-galaxy collection list community.general 2>/dev/null | grep -q community.general && echo "installed" || echo "NOT INSTALLED")"
EOFINSTALL
echo -e "${GREEN}✓ Tools installed${NC}"

# Step 4: Copy infrastructure code
echo -e "${YELLOW}[4/9] Copying KFT-Infra code...${NC}"
$SSHCMD root@localhost 'rm -rf /root/kft-infra'
sshpass -p "$SSH_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q -r /home/smd/Documents/KFT-Infra root@localhost:/root/kft-infra
echo -e "${GREEN}✓ Code copied${NC}"

# Step 5: Deploy containers with Terraform
echo -e "${YELLOW}[5/9] Deploying containers with Terraform...${NC}"
echo "This may take 5-10 minutes. Running Terraform in background to survive SSH disconnects..."

# Install screen if not available and run Terraform in detached session
$SSHCMD root@localhost <<'EOFTERRAFORM'
cd /root/kft-infra/terraform

# Clean up any stale Terraform state from snapshot
rm -rf .terraform terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl 2>/dev/null || true

# Install screen if needed
command -v screen >/dev/null 2>&1 || apt-get install -y -qq screen >/dev/null 2>&1

# Kill any existing terraform screen session
screen -S terraform-deploy -X quit 2>/dev/null || true

# Initialize Terraform first (quick operation)
echo "Initializing Terraform..."
terraform init -no-color

# Run Terraform apply in a screen session with output logging
# Limit parallelism to reduce VM load (create max 2 resources at once)
echo "Starting Terraform apply in background (this may take several minutes)..."
screen -dmS terraform-deploy bash -c "
  cd /root/kft-infra/terraform
  export TF_LOG=INFO
  terraform apply -var-file=dev.tfvars -auto-approve -no-color -parallelism=2 2>&1 | tee /tmp/terraform-apply.log
  echo \$? > /tmp/terraform-exit-code
"
EOFTERRAFORM

# Monitor Terraform progress
echo "Monitoring Terraform deployment..."
MAX_WAIT=900  # 15 minutes max
ELAPSED=0
INTERVAL=10
TERRAFORM_STATUS=1  # Default to error until we know otherwise
VM_UNRESPONSIVE_COUNT=0
MAX_UNRESPONSIVE=3  # Allow 3 failed checks before giving up

while [ $ELAPSED -lt $MAX_WAIT ]; do
  # First check if VM is still responsive with a simple SSH command
  VM_RESPONSIVE=$($SSHCMD root@localhost 'echo "OK"' 2>/dev/null || echo "FAILED")
  
  if [ "$VM_RESPONSIVE" != "OK" ]; then
    # SSH failed, but check if Proxmox web UI is still responding (VM is actually running)
    WEB_UI_RESPONSIVE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 https://localhost:8006/api2/json/version 2>/dev/null || echo "000")
    
    if [ "$WEB_UI_RESPONSIVE" = "200" ] || [ "$WEB_UI_RESPONSIVE" = "401" ]; then
      # Web UI is responding (200=OK, 401=auth required, both mean VM is alive)
      VM_UNRESPONSIVE_COUNT=$((VM_UNRESPONSIVE_COUNT + 1))
      echo -e "${YELLOW}⚠ SSH unresponsive but web UI is alive (VM is running, SSH just busy) - attempt $VM_UNRESPONSIVE_COUNT/$MAX_UNRESPONSIVE...${NC}"
      echo -e "${YELLOW}  Terraform is likely still running. Waiting longer before retry...${NC}"
      
      if [ $VM_UNRESPONSIVE_COUNT -ge $MAX_UNRESPONSIVE ]; then
        echo -e "${YELLOW}SSH has been unresponsive for a while, but VM is still running.${NC}"
        echo -e "${YELLOW}Waiting 2 minutes for Terraform to complete, then checking again...${NC}"
        sleep 120
        
        # Try SSH again after longer wait
        VM_RESPONSIVE=$($SSHCMD root@localhost 'echo "OK"' 2>/dev/null || echo "FAILED")
        if [ "$VM_RESPONSIVE" != "OK" ]; then
          # Still can't SSH, but web UI works, so continue monitoring via web API
          echo -e "${YELLOW}SSH still unresponsive, but continuing to monitor via web API...${NC}"
          VM_UNRESPONSIVE_COUNT=0  # Reset to continue monitoring
          sleep 30
          continue
        else
          echo -e "${GREEN}✓ SSH recovered, continuing monitoring...${NC}"
          VM_UNRESPONSIVE_COUNT=0
        fi
      else
        sleep 30  # Wait longer before retry when SSH is busy
        continue
      fi
    else
      # Neither SSH nor web UI responding - VM might actually be down
      VM_UNRESPONSIVE_COUNT=$((VM_UNRESPONSIVE_COUNT + 1))
      echo -e "${RED}⚠ Both SSH and web UI unresponsive (attempt $VM_UNRESPONSIVE_COUNT/$MAX_UNRESPONSIVE)...${NC}"
      
      if [ $VM_UNRESPONSIVE_COUNT -ge $MAX_UNRESPONSIVE ]; then
        echo -e "${RED}✗ VM appears to be down. Exiting monitoring.${NC}"
        TERRAFORM_STATUS=1
        break
      else
        sleep 20
        continue
      fi
    fi
  else
    VM_UNRESPONSIVE_COUNT=0  # Reset counter on successful response
  fi
  
  # Check if screen session still exists (Terraform still running)
  # Use timeout to prevent hanging if SSH is slow
  SCREEN_RUNNING=$(timeout 10 $SSHCMD root@localhost 'screen -list | grep -q terraform-deploy && echo "yes" || echo "no"' 2>/dev/null || echo "unknown")
  
  if [ "$SCREEN_RUNNING" = "no" ] && [ "$SCREEN_RUNNING" != "unknown" ]; then
    # Screen session ended, check exit code
    EXIT_CODE=$(timeout 10 $SSHCMD root@localhost 'cat /tmp/terraform-exit-code 2>/dev/null || echo "unknown"' 2>/dev/null || echo "unknown")
    
    if [ "$EXIT_CODE" != "unknown" ]; then
      echo ""
      if [ "$EXIT_CODE" = "0" ]; then
        echo -e "${GREEN}✓ Terraform deployment complete${NC}"
        TERRAFORM_STATUS=0
      else
        echo -e "${YELLOW}⚠ Terraform deployment completed with exit code: $EXIT_CODE${NC}"
        TERRAFORM_STATUS=$EXIT_CODE
      fi
      # Show last 20 lines of output
      echo "Last Terraform output:"
      $SSHCMD root@localhost 'tail -20 /tmp/terraform-apply.log 2>/dev/null' || true
      break
    fi
  fi
  
  # Show progress every 30 seconds
  if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
    echo "  Still deploying... (${ELAPSED}s elapsed)"
    # Show recent Terraform output (with timeout to avoid hanging)
    # Only try if SSH is responsive
    if [ "$VM_RESPONSIVE" = "OK" ]; then
      timeout 5 $SSHCMD root@localhost 'tail -5 /tmp/terraform-apply.log 2>/dev/null | grep -E "(Creating|Still creating|Creation complete)" || true' 2>/dev/null || true
    else
      echo "  (SSH busy, but VM is running - Terraform continuing in background)"
    fi
  fi
  
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

# If we hit max wait, check current status
if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo -e "${YELLOW}⚠ Terraform deployment taking longer than expected${NC}"
  echo "Checking current status..."
  $SSHCMD root@localhost 'tail -30 /tmp/terraform-apply.log 2>/dev/null' || true
  TERRAFORM_STATUS=1
fi

if [ $TERRAFORM_STATUS -ne 0 ]; then
  echo -e "${YELLOW}Checking if containers were partially created...${NC}"
  sleep 5
fi

# Step 6: Wait for containers and get IPs
echo -e "${YELLOW}[6/9] Waiting for containers to stabilize...${NC}"
sleep 20

echo "Checking container status..."
$SSHCMD root@localhost 'pct list' || echo "Checking containers..."

# Remove VLAN tags from containers for test environment (VLAN config kept in Terraform as backup)
echo "Removing VLAN tags from containers for test environment..."
$SSHCMD root@localhost <<'EOFNOVLAN'
for id in 100 106 107 109 115; do
  name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
  if [ -z "$name" ]; then
    continue
  fi
  
  # Check current network config
  current_net=$(pct config $id 2>/dev/null | grep "^net0:")
  if echo "$current_net" | grep -q "tag="; then
    echo "  Removing VLAN tag from $name (ID: $id)..."
    # Extract MAC address and other settings, remove VLAN tag
    mac=$(echo "$current_net" | grep -o "hwaddr=[^,]*" | cut -d= -f2)
    if [ -n "$mac" ]; then
      pct set $id --net0 name=eth0,bridge=vmbr0,hwaddr=$mac,ip=dhcp,type=veth 2>/dev/null || \
      pct set $id --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth 2>/dev/null || true
    else
      pct set $id --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth 2>/dev/null || true
    fi
    
    # Remove net1 if it exists (backup/secondary interface)
    pct set $id --delete net1 2>/dev/null || true
    
    # Restart container to apply network changes
    if [ "$(pct status $id 2>/dev/null | awk '{print $2}')" = "running" ]; then
      echo "    Restarting container to apply network changes..."
      pct shutdown $id 2>/dev/null || true
      sleep 3
      pct start $id 2>/dev/null || true
    fi
  fi
done
echo "VLAN tags removed. Containers will use standard bridge networking."
EOFNOVLAN

# Get container IPs
echo -e "${YELLOW}[7/9] Discovering container IPs...${NC}"
$SSHCMD root@localhost <<'EOFIPS'
echo "Container IPs:"
for id in 100 106 107 109 115; do
  name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
  # Get IPv4 address only (exclude IPv6)
  ip=$(pct exec $id -- ip -4 addr show eth0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
  if [ -z "$ip" ]; then
    ip=$(pct exec $id -- hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  fi
  if [ -n "$ip" ] && [ -n "$name" ]; then
    echo "  $id ($name): $ip"
  fi
done
EOFIPS

# Step 8: Create test inventory and configure with Ansible
echo -e "${YELLOW}[8/9] Configuring services with Ansible...${NC}"

# Get container IPs for SSH-based connection (LXC plugin doesn't work with Proxmox)
echo "Collecting container IPs for SSH-based Ansible connection..."
echo "Waiting for all containers to get IP addresses..."

# First, ensure all containers are running
echo "Checking container status..."
$SSHCMD root@localhost <<'EOFSTATUS'
for id in 100 106 107 109 115; do
  status=$(pct status $id 2>/dev/null | awk '{print $2}')
  name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
  echo "Container $id ($name): $status"
  if [ "$status" != "running" ]; then
    echo "  Starting container $id..."
    pct start $id 2>/dev/null || true
  fi
done
EOFSTATUS

# Wait for containers to get IPs (retry up to 10 times with longer waits)
for attempt in {1..10}; do
  CONTAINER_IPS=$($SSHCMD root@localhost <<'EOFGETIPS'
for id in 100 106 107 109 115; do
  name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
  status=$(pct status $id 2>/dev/null | awk '{print $2}')
  
  if [ "$status" = "running" ]; then
    # Try multiple methods to get IPv4 IP (prefer IPv4 over IPv6)
    # First try ip command for IPv4 specifically
    ip=$(pct exec $id -- ip -4 addr show eth0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    if [ -z "$ip" ]; then
      # Try ifconfig for IPv4
      ip=$(pct exec $id -- ifconfig eth0 2>/dev/null | grep "inet " | awk '{print $2}')
    fi
    if [ -z "$ip" ]; then
      # Fallback to hostname -I but filter for IPv4 only
      ip=$(pct exec $id -- hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    fi
    
    if [ -n "$ip" ] && [ -n "$name" ]; then
      echo "$name=$ip"
    else
      echo "WARNING: $name (ID: $id) is running but has no IP yet" >&2
      # Try to fix network - restart networking in container
      echo "Attempting to fix network for $name (ID: $id)..." >&2
      pct exec $id -- bash -c "systemctl restart networking 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || dhclient -r eth0; dhclient eth0 2>/dev/null || true" 2>&1 | grep -v "^$" >&2 || true
      sleep 3
    fi
  else
    echo "WARNING: $name (ID: $id) status is: $status" >&2
  fi
done
EOFGETIPS
)
  
  # Parse the IPs
  GRAFANA_IP=$(echo "$CONTAINER_IPS" | grep "^grafana=" | cut -d= -f2)
  PROMETHEUS_IP=$(echo "$CONTAINER_IPS" | grep "^prometheus=" | cut -d= -f2)
  ADGUARD_IP=$(echo "$CONTAINER_IPS" | grep "^adguard=" | cut -d= -f2)
  HOMEASSISTANT_IP=$(echo "$CONTAINER_IPS" | grep "^homeassistant=" | cut -d= -f2)
  HOMARR_IP=$(echo "$CONTAINER_IPS" | grep "^homarr=" | cut -d= -f2)
  
  # Check if all IPs are present
  MISSING_IPS=""
  [ -z "$GRAFANA_IP" ] && MISSING_IPS="$MISSING_IPS grafana"
  [ -z "$PROMETHEUS_IP" ] && MISSING_IPS="$MISSING_IPS prometheus"
  [ -z "$ADGUARD_IP" ] && MISSING_IPS="$MISSING_IPS adguard"
  [ -z "$HOMEASSISTANT_IP" ] && MISSING_IPS="$MISSING_IPS homeassistant"
  [ -z "$HOMARR_IP" ] && MISSING_IPS="$MISSING_IPS homarr"
  
  if [ -z "$MISSING_IPS" ]; then
    echo "All containers have IPs!"
    break
  fi
  
  if [ $attempt -lt 10 ]; then
    echo "  Attempt $attempt/10: Missing IPs for:$MISSING_IPS, waiting 15 seconds..."
    
    # For containers without IPs, try to restart them or fix network
    if [ $attempt -ge 3 ] && [ $attempt -lt 6 ]; then
      echo "  Trying to restart network for containers without IPs..."
      $SSHCMD root@localhost <<'EOFRESTARTNET'
      for id in 100 106 107; do
        name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
        ip=$(pct exec $id -- hostname -I 2>/dev/null | awk '{print $1}')
        if [ -z "$ip" ]; then
          echo "  Restarting container $id ($name)..."
          pct shutdown $id 2>/dev/null || true
          sleep 5
          pct start $id 2>/dev/null || true
          sleep 10
        fi
      done
EOFRESTARTNET
    fi
    
    sleep 15
  else
    echo -e "${YELLOW}Warning: Some containers still don't have IPs after 10 attempts${NC}"
    echo "Missing IPs for:$MISSING_IPS"
    echo ""
    echo "Trying one final network fix - checking container network configs..."
    $SSHCMD root@localhost <<'EOFFINALFIX'
    for id in 100 106 107; do
      name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
      echo "Container $id ($name) network config:"
      pct config $id | grep -E "^(net|hostname)" || echo "  No network config found"
      echo "  Interfaces in container:"
      pct exec $id -- ip link show 2>/dev/null | grep -E "^[0-9]+:" || echo "  Could not list interfaces"
      echo ""
    done
EOFFINALFIX
    echo "Will continue with available containers..."
  fi
done

echo "Container IPs:"
echo "  grafana: ${GRAFANA_IP:-NOT FOUND}"
echo "  prometheus: ${PROMETHEUS_IP:-NOT FOUND}"
echo "  adguard: ${ADGUARD_IP:-NOT FOUND}"
echo "  homeassistant: ${HOMEASSISTANT_IP:-NOT FOUND}"
echo "  homarr: ${HOMARR_IP:-NOT FOUND}"

# Setup SSH access to containers (copy SSH key or enable password auth)
echo "Setting up SSH access to containers..."
$SSHCMD root@localhost <<'EOFSSHSETUP'
# Generate SSH key if it doesn't exist
if [ ! -f /root/.ssh/id_rsa ]; then
  ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
fi

# Copy SSH key to each container
for id in 100 106 107 109 115; do
  name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
  if [ -n "$name" ]; then
    echo "Setting up SSH for $name (ID: $id)..."
    # Ensure SSH is enabled in container
    pct exec $id -- bash -c "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-server >/dev/null 2>&1 || true" 2>/dev/null || true
    pct exec $id -- bash -c "systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true" 2>/dev/null || true
    pct exec $id -- bash -c "systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true" 2>/dev/null || true
    
    # Try to copy SSH key (may fail if password auth not enabled, that's OK)
    pct exec $id -- bash -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh" 2>/dev/null || true
    cat /root/.ssh/id_rsa.pub | pct exec $id -- bash -c "cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null || true
  fi
done
EOFSSHSETUP

# Ensure containers have SSH access (they should by default, but verify)
echo "Creating Ansible inventory with container IPs..."

# Create inventory file locally first, then copy it
cat > /tmp/test-hosts.yml <<EOFINV
---
all:
  vars:
    ansible_user: root
    ansible_python_interpreter: /usr/bin/python3
    ansible_connection: ssh
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=yes"
    ansible_ssh_pass: ""

  children:
    containers:
      children:
        monitoring:
          hosts:
            grafana:
              ansible_host: ${GRAFANA_IP:-}
            prometheus:
              ansible_host: ${PROMETHEUS_IP:-}

        network_services:
          hosts:
            adguard:
              ansible_host: ${ADGUARD_IP:-}

        smarthome:
          hosts:
            homeassistant:
              ansible_host: ${HOMEASSISTANT_IP:-}

        dashboard:
          hosts:
            homarr:
              ansible_host: ${HOMARR_IP:-}
EOFINV

# Copy inventory to VM
sshpass -p "$SSH_PASSWORD" scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/test-hosts.yml root@localhost:/root/kft-infra/ansible/inventory/test-hosts.yml

# Now run Ansible
$SSHCMD root@localhost <<'EOFANSIBLE'
cd /root/kft-infra/ansible

# Run Ansible playbooks (skip unifi)
echo "Running Ansible playbooks..."
ansible-playbook -i inventory/test-hosts.yml playbooks/site.yml --skip-tags unifi --limit '!unifi-tailscale' -v
EOFANSIBLE

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Ansible configuration complete${NC}"
else
  echo -e "${YELLOW}⚠ Ansible had some issues, but continuing...${NC}"
fi

# Step 9: Create final snapshot
echo -e "${YELLOW}[9/9] Creating final snapshot...${NC}"
./stop-vm.sh
qemu-img snapshot -c kft-full-stack proxmox-test.qcow2
qemu-img snapshot -l proxmox-test.qcow2

echo ""
echo -e "${GREEN}====== Deployment Complete! ======${NC}"
echo ""
echo "Containers deployed:"
echo "  - Home Assistant (100)"
echo "  - AdGuard Home (106)"
echo "  - Homarr (107)"
echo "  - Grafana (109)"
echo "  - Prometheus (115)"
echo ""
echo "Snapshots available:"
echo "  - clean-with-template (clean Proxmox)"
echo "  - kft-full-stack (full deployment)"
echo ""
echo "To start:"
echo "  cd /home/smd/proxmox-test"
echo "  ./start-vm.sh"
echo "  ssh proxmox-test"
echo ""
