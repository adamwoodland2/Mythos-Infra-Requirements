#!/usr/bin/env bash
# install-gateway.sh  -  run once on a fresh Debian 12 / Ubuntu 24.04 gateway VM
# while its NAT interface (eth0) still has internet. Copies the files from this
# directory into place and enables the services.
#
#   sudo bash install-gateway.sh
#
# Before running, confirm interface names with `ip -br link` and edit
# nftables.conf (LAN_IF / WAN_IF) if they are not eth0 / eth1.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "[1/6] packages"
apt-get update
apt-get install -y squid nftables rsync logrotate

echo "[2/6] static IP on the lab interface (eth1 = 10.0.3.1/24, no gateway)"
if command -v netplan >/dev/null 2>&1; then
  # Ubuntu
  cat > /etc/netplan/60-cvp-lab.yaml <<'EOF'
network:
  version: 2
  ethernets:
    eth1:
      addresses: [10.0.3.1/24]
      dhcp4: false
EOF
  chmod 600 /etc/netplan/60-cvp-lab.yaml
  netplan apply
else
  # Debian (ifupdown)
  cat > /etc/network/interfaces.d/cvp-lab <<'EOF'
auto eth1
iface eth1 inet static
    address 10.0.3.1/24
EOF
  ifup eth1 2>/dev/null || true
fi

echo "[3/6] squid"
install -m 0644 "$HERE/squid.conf"          /etc/squid/squid.conf
install -m 0644 "$HERE/allowlist-run.txt"   /etc/squid/allowlist-run.txt
install -m 0644 "$HERE/allowlist-login.txt" /etc/squid/allowlist-login.txt
ln -sfn /etc/squid/allowlist-run.txt /etc/squid/allowlist.txt
install -m 0755 "$HERE/cvp-mode.sh"         /usr/local/sbin/cvp-mode
touch /var/log/cvp-mode.log
squid -k parse
systemctl enable --now squid
systemctl restart squid

echo "[4/6] logrotate (45-day retention)"
install -m 0644 "$HERE/logrotate-squid" /etc/logrotate.d/squid

echo "[5/6] transcript drop-box for Kali rsync"
mkdir -p /var/cvp/transcripts
id cvpsync >/dev/null 2>&1 || useradd -r -m -d /var/cvp -s /usr/sbin/nologin cvpsync
chown -R cvpsync:cvpsync /var/cvp
# Allow rsync-over-ssh for cvpsync only:
#   - put Kali's public key in /var/cvp/.ssh/authorized_keys
#   - restrict the key (rrsync ships with the rsync package):
#       command="/usr/bin/rrsync -wo /var/cvp/transcripts",restrict  ssh-ed25519 AAAA... kali-cvpsync
mkdir -p /var/cvp/.ssh && chmod 700 /var/cvp/.ssh && chown cvpsync:cvpsync /var/cvp/.ssh
# nologin shell blocks ssh; use a restricted shell instead for the sync user
usermod -s /bin/sh cvpsync

echo "[6/6] nftables (default-drop, no forwarding)"
install -m 0644 "$HERE/nftables.conf" /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable --now nftables
# belt and braces: make sure the kernel is not forwarding anyway
cat > /etc/sysctl.d/99-cvp-noforward.conf <<'EOF'
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
EOF
sysctl --system >/dev/null

echo
echo "Done. Verify:"
echo "  sudo nft list ruleset"
echo "  sudo cvp-mode status"
echo "  curl -x http://10.0.3.1:3128 -sI https://api.anthropic.com   (from Kali -> expect HTTP 4xx from Anthropic, NOT 403 from squid)"
echo "  curl -x http://10.0.3.1:3128 -sI https://example.com         (from Kali -> expect 403 from squid)"
