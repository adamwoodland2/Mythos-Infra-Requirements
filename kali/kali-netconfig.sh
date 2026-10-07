#!/usr/bin/env bash
# kali-netconfig.sh  -  run once on the Kali VM AFTER it has been moved from NAT
# to the "cvp-lab" LAN segment. Sets a static IP with NO default gateway and
# points the system-wide proxy at the gateway VM so the OAuth browser login and
# curl/apt (when allowed) also go through Squid.
#
#   sudo bash kali-netconfig.sh [interface]      (default: eth0)

set -euo pipefail
IF="${1:-eth0}"
LAB_IP=10.0.3.10/24
GW_PROXY=http://10.0.3.1:3128

echo "[1/3] NetworkManager static profile on $IF (no gateway, no DNS)"
nmcli connection delete cvp-lab >/dev/null 2>&1 || true
nmcli connection add type ethernet ifname "$IF" con-name cvp-lab \
  ipv4.method manual ipv4.addresses "$LAB_IP" \
  ipv4.never-default yes ipv4.dns "" ipv6.method disabled \
  connection.autoconnect yes
nmcli connection up cvp-lab

echo "[2/3] system-wide proxy environment (browser + CLI tools)"
cat > /etc/environment.d/90-cvp-proxy.conf <<EOF
HTTPS_PROXY=$GW_PROXY
HTTP_PROXY=$GW_PROXY
NO_PROXY=localhost,127.0.0.1,::1,10.0.3.0/24
https_proxy=$GW_PROXY
http_proxy=$GW_PROXY
no_proxy=localhost,127.0.0.1,::1,10.0.3.0/24
EOF
# apt (only useful while cvp-mode login + extra domains are active)
cat > /etc/apt/apt.conf.d/90cvp-proxy <<EOF
Acquire::http::Proxy "$GW_PROXY";
Acquire::https::Proxy "$GW_PROXY";
EOF

echo "[3/3] hosts entries so nothing needs DNS inside the lab"
grep -q 'cvp-gw' /etc/hosts || cat >> /etc/hosts <<'EOF'
10.0.3.1   cvp-gw
10.0.3.20  win-app-01
EOF

echo
echo "Done. Log out and back in (or reboot) for the proxy env to apply."
echo "Test:  curl -sI https://api.anthropic.com   -> expect an HTTP response from Anthropic"
echo "       curl -sI https://example.com         -> expect 403 from squid"
echo "       ping -c1 8.8.8.8                     -> expect 'Network is unreachable'"
