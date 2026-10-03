#!/usr/bin/env bash
# Runs only inside the disposable pve-test VM created by lab.py.
set -euo pipefail
[[ "$(hostname -s)" == pve-test ]]
export DEBIAN_FRONTEND=noninteractive
exec >>/var/log/kft-bootstrap.log 2>&1
if [[ ! -e /var/lib/kft-kernel-installed ]]; then
  echo "grub-pc grub-pc/install_devices multiselect /dev/vda" | debconf-set-selections
  dpkg --configure -a
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -o /usr/share/keyrings/proxmox-archive-keyring.gpg
  echo '136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg' | sha256sum -c -
  cat > /etc/apt/sources.list.d/pve-test.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  apt-get update
  echo "grub-pc grub-pc/install_devices multiselect /dev/vda" | debconf-set-selections
  dpkg --configure -a
  apt-get install -y proxmox-default-kernel
  touch /var/lib/kft-kernel-installed
  systemctl reboot
  exit 0
fi
if [[ ! -e /var/lib/kft-lab-ready ]]; then
  [[ "$(uname -r)" == *-pve ]]
  apt-get install -y proxmox-ve postfix open-iscsi chrony nftables
  mkdir -p /etc/network/interfaces.d
  cat > /etc/network/interfaces.d/kft-test <<'EOF'
auto vmbr1
iface vmbr1 inet static
    address 10.73.0.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
  grep -q 'source /etc/network/interfaces.d/' /etc/network/interfaces || echo 'source /etc/network/interfaces.d/*' >> /etc/network/interfaces
  mkdir -p /run/network
  ifup vmbr1
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/90-kft-lab.conf
  sysctl -p /etc/sysctl.d/90-kft-lab.conf
  upstream="$(ip route show default | awk '{print $5; exit}')"
  cat > /etc/kft-test-network.nft <<EOF
table ip kft_test {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 10.73.0.0/24 oifname "$upstream" masquerade
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    ip daddr {192.168.0.0/16, 172.16.0.0/12, 100.64.0.0/10} reject
    ip daddr 10.0.0.0/8 ip daddr != 10.73.0.0/24 ip daddr != 10.0.2.0/24 reject
  }
  chain output {
    type filter hook output priority -10; policy accept;
    ip daddr {192.168.0.0/16, 172.16.0.0/12, 100.64.0.0/10} reject
    ip daddr 10.0.0.0/8 ip daddr != 10.73.0.0/24 ip daddr != 10.0.2.0/24 reject
  }
}
EOF
  cat > /etc/systemd/system/kft-test-network.service <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/kft-test-network.nft
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now kft-test-network.service
  # API token stays root-only in this test VM. Never use production credentials.
  if [[ ! -s /root/kft-test-token.json ]]; then
    pveum user token add root@pam kft-test --privsep 0 --output-format json > /root/kft-test-token.json.tmp
    chmod 600 /root/kft-test-token.json.tmp
    mv /root/kft-test-token.json.tmp /root/kft-test-token.json
  fi
  pveam update
  template="$(pveam available --section system | awk '/debian-13-standard.*amd64/ {print $2; exit}')"
  [[ -n "$template" ]]
  pveam download local "$template"
  echo "local:vztmpl/$template" > /root/kft-test-template
  touch /var/lib/kft-lab-ready
fi
