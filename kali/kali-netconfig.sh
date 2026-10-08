#!/usr/bin/env bash
# kali-netconfig.sh  -  run once on the Kali VM AFTER it has been moved from NAT
# to the "cvp-lab" LAN segment. Sets a static IP with NO default gateway and
# points the system-wide proxy at the gateway VM so curl and apt (when allowed)
# also go through Squid. Claude Code gets its proxy from ~/.claude/settings.json.
#
#   sudo bash kali-netconfig.sh [interface]      (default: eth0)

set -euo pipefail
IF="${1:-eth0}"
LAB_IP=10.0.3.11/24
GW_PROXY=http://10.0.3.1:3128

echo "[1/3] NetworkManager static profile on $IF (no gateway, no DNS)"
nmcli connection delete cvp-lab >/dev/null 2>&1 || true
# autoconnect-priority so the old NAT/DHCP profile never wins after a reboot
nmcli connection add type ethernet ifname "$IF" con-name cvp-lab \
  ipv4.method manual ipv4.addresses "$LAB_IP" \
  ipv4.never-default yes ipv4.dns "" ipv6.method disabled \
  connection.autoconnect yes connection.autoconnect-priority 100
nmcli connection up cvp-lab

echo "[2/3] system-wide proxy environment (CLI tools, every login)"
# /etc/environment is read by pam_env for console, SSH and LightDM/Xfce logins.
# (/etc/environment.d only reaches systemd user services, not Xfce terminals.)
sed -i -E '/^(HTTPS?_PROXY|NO_PROXY|https?_proxy|no_proxy)=/d' /etc/environment
cat >> /etc/environment <<EOF
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
# Windows targets are 10.0.3.21-30: win-app-01 is .21 ... win-app-10 is .30
sed -i '/^# cvp-lab hosts begin/,/^# cvp-lab hosts end/d' /etc/hosts
{
  echo "# cvp-lab hosts begin"
  echo "10.0.3.1   cvp-gw"
  for i in $(seq 21 30); do printf '10.0.3.%d  win-app-%02d\n' "$i" $((i - 20)); done
  echo "# cvp-lab hosts end"
} >> /etc/hosts

echo
echo "Done. Log out and back in (or reboot) for the proxy env to apply."
echo "Test:  curl -sI https://api.anthropic.com   -> expect an HTTP response from Anthropic"
echo "       curl -sI https://example.com         -> expect 403 from squid"
echo "       ping -c1 8.8.8.8                     -> expect 'Network is unreachable'"
