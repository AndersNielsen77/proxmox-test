#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p 2222"

echo -e "${GREEN}====== KFT Infrastructure Deployment ======${NC}"
echo ""

# Step 1: Clean start
echo -e "${YELLOW}[1/9] Preparing clean VM environment...${NC}"
./stop-vm.sh >/dev/null 2>&1 || true
qemu-img snapshot -a clean-with-template proxmox-test.qcow2
./start-vm.sh
echo "Waiting for VM to boot..."
sleep 45

# Step 2: Verify connectivity
echo -e "${YELLOW}[2/9] Verifying VM connectivity...${NC}"
for i in {1..5}; do
  if ssh $SSHOPTS root@localhost 'echo OK' >/dev/null 2>&1; then
    echo -e "${GREEN}✓ SSH connected${NC}"
    break
  fi
  echo "  Attempt $i/5..."
  sleep 5
done

# Step 3: Configure repositories and install tools
echo -e "${YELLOW}[3/9] Installing Terraform and Ansible...${NC}"
ssh $SSHOPTS root@localhost <<'EOFINSTALL'
# Disable enterprise repos
mv -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.bak 2>/dev/null || true
mv -f /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.bak 2>/dev/null || true
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Update and install prerequisites
apt update -qq
apt install -y -qq wget gpg curl

# Install Terraform
wget -q -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com trixie main" > /etc/apt/sources.list.d/hashicorp.list
apt update -qq
apt install -y -qq terraform ansible

echo "Terraform $(terraform version | head -1)"
echo "Ansible $(ansible --version | head -1)"
EOFINSTALL
echo -e "${GREEN}✓ Tools installed${NC}"

# Step 4: Copy infrastructure code
echo -e "${YELLOW}[4/9] Copying KFT-Infra code...${NC}"
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q -r /home/smd/Documents/KFT-Infra root@localhost:/root/kft-infra
echo -e "${GREEN}✓ Code copied${NC}"

# Step 5: Deploy containers with Terraform
echo -e "${YELLOW}[5/9] Deploying containers with Terraform...${NC}"
ssh $SSHOPTS root@localhost <<'EOFTERRAFORM'
cd /root/kft-infra/terraform

# Backup production configs
mv containers.tf containers.tf.prod 2>/dev/null || true
mv vms.tf vms.tf.prod 2>/dev/null || true
mv outputs.tf outputs.tf.prod 2>/dev/null || true

# Use test config (already copied)
cp containers-test-all.tf containers.tf

# Initialize and apply
terraform init -no-color >/dev/null 2>&1
echo "Deploying 5 containers (this may take 2-3 minutes)..."
terraform apply -var-file=terraform-dev.tfvars -auto-approve -no-color
EOFTERRAFORM

if [ $? -ne 0 ]; then
  echo -e "${RED}✗ Terraform deployment may have issues, checking status...${NC}"
  sleep 10
fi

# Step 6: Wait for containers and get IPs
echo -e "${YELLOW}[6/9] Waiting for containers to stabilize...${NC}"
sleep 20

echo "Checking container status..."
ssh $SSHOPTS root@localhost 'pct list' || echo "Checking containers..."

# Get container IPs
echo -e "${YELLOW}[7/9] Discovering container IPs...${NC}"
ssh $SSHOPTS root@localhost <<'EOFIPS'
echo "Container IPs:"
for id in 100 106 107 109 115; do
  name=$(pct config $id 2>/dev/null | grep "^hostname:" | awk '{print $2}')
  ip=$(pct exec $id -- hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$ip" ] && [ -n "$name" ]; then
    echo "  $id ($name): $ip"
  fi
done
EOFIPS

# Step 8: Create test inventory and configure with Ansible
echo -e "${YELLOW}[8/9] Configuring services with Ansible...${NC}"
ssh $SSHOPTS root@localhost <<'EOFANSIBLE'
cd /root/kft-infra/ansible

# Create test inventory with actual IPs
cat > inventory/test-hosts.yml <<'EOFINV'
---
all:
  vars:
    ansible_user: root
    ansible_python_interpreter: /usr/bin/python3
    ansible_connection: community.general.lxc
    ansible_lxc_host: localhost

  children:
    containers:
      children:
        monitoring:
          hosts:
            grafana:
              ansible_lxc_name: grafana
            prometheus:
              ansible_lxc_name: prometheus

        network_services:
          hosts:
            adguard:
              ansible_lxc_name: adguard

        smarthome:
          hosts:
            homeassistant:
              ansible_lxc_name: homeassistant

        dashboard:
          hosts:
            homarr:
              ansible_lxc_name: homarr
EOFINV

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
