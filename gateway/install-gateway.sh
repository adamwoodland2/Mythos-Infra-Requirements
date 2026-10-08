#!/usr/bin/env bash
# install-gateway.sh  -  run once on a fresh Ubuntu Server 26.04 gateway VM
# while its NAT interface still has internet. Copies the files from this
# directory into place and enables the services.
#
#   sudo bash install-gateway.sh
#
# Interface names default to this lab's gateway VM (ens33 = NAT, ens37 = lab).
# Check with `ip -br link`; if yours differ, override both:
#   sudo WAN_IF=ens33 LAN_IF=ens37 bash install-gateway.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WAN_IF="${WAN_IF:-ens33}"
LAN_IF="${LAN_IF:-ens37}"

for i in "$WAN_IF" "$LAN_IF"; do
  [[ -e "/sys/class/net/$i" ]] || { echo "no interface '$i' - check 'ip -br link' and set WAN_IF / LAN_IF" >&2; exit 1; }
done
[[ "$WAN_IF" != "$LAN_IF" ]] || { echo "WAN_IF and LAN_IF must be different interfaces" >&2; exit 1; }
echo "WAN (NAT) = $WAN_IF, LAN (cvp-lab) = $LAN_IF"

echo "[1/7] packages"
apt-get update
apt-get install -y squid nftables rsync logrotate openssh-server

echo "[2/7] static IP on the lab interface ($LAN_IF = 10.0.3.1/24, no gateway)"
# accept-ra off: nothing on the lab segment gets to hand the gateway an IPv6 route
cat > /etc/netplan/60-cvp-lab.yaml <<EOF
network:
  version: 2
  ethernets:
    $LAN_IF:
      addresses: [10.0.3.1/24]
      dhcp4: false
      dhcp6: false
      accept-ra: false
EOF
chmod 600 /etc/netplan/60-cvp-lab.yaml
netplan apply

echo "[3/7] squid"
install -m 0644 "$HERE/squid.conf"          /etc/squid/squid.conf
install -m 0644 "$HERE/allowlist-run.txt"   /etc/squid/allowlist-run.txt
install -m 0644 "$HERE/allowlist-login.txt" /etc/squid/allowlist-login.txt
ln -sfn /etc/squid/allowlist-run.txt /etc/squid/allowlist.txt
install -m 0755 "$HERE/cvp-mode.sh"         /usr/local/sbin/cvp-mode
install -m 0755 "$HERE/cvp-enrol-key.sh"    /usr/local/sbin/cvp-enrol-key
touch /var/log/cvp-mode.log
# Squid binds 10.0.3.1, so it has to start after the lab interface is up. The
# packaged unit is ordered After=network-online.target but never pulls it in.
mkdir -p /etc/systemd/system/squid.service.d
cat > /etc/systemd/system/squid.service.d/cvp-lab.conf <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=on-failure
RestartSec=5
EOF
systemctl daemon-reload
squid -k parse
systemctl enable squid
systemctl restart squid

echo "[4/7] logrotate (45-day retention)"
install -m 0644 "$HERE/logrotate-squid" /etc/logrotate.d/squid

echo "[5/7] transcript drop-box for Kali rsync"
# Shell must be a real one: sshd runs the forced rrsync command through it.
id cvpsync >/dev/null 2>&1 || useradd -r -M -d /var/cvp -s /bin/sh cvpsync
mkdir -p /var/cvp/transcripts /var/cvp/.ssh
chown -R cvpsync:cvpsync /var/cvp
chmod 700 /var/cvp/.ssh
# The key is added later with `sudo cvp-enrol-key` (CHECKLIST §4B). It is forced
# into `rrsync -wo -no-del`, so Kali can add transcripts but never read or delete them.

echo "[6/7] sshd: from the lab, only the cvpsync key may log in"
cat > /etc/ssh/sshd_config.d/60-cvp-lab.conf <<'EOF'
# Written by install-gateway.sh. Administer the gateway from the VMware console;
# the only SSH login accepted from the lab segment is the transcript drop-box.
Match Address 10.0.3.0/24
    AllowUsers cvpsync
    PasswordAuthentication no
    KbdInteractiveAuthentication no
EOF
sshd -t
# Ubuntu starts sshd on demand from ssh.socket; restart it only if it is running
systemctl try-restart ssh.service

echo "[7/7] nftables (default-drop, no forwarding)"
sed -e "s/^define WAN_IF .*/define WAN_IF   = \"$WAN_IF\"/" \
    -e "s/^define LAN_IF .*/define LAN_IF   = \"$LAN_IF\"/" \
    "$HERE/nftables.conf" > /etc/nftables.conf
chmod 0644 /etc/nftables.conf
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables
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
echo "  curl -sI https://api.anthropic.com   (from Kali -> expect an HTTP response from Anthropic, NOT 403 from squid)"
echo "  curl -sI https://example.com         (from Kali -> expect 403 from squid)"
