#!/usr/bin/env bash
# kali-netconfig.sh  -  run once on the Kali VM AFTER it has been moved from NAT
# to the "cvp-lab" LAN segment (setup-kali.sh lab runs it). Sets a static IP
# with NO default gateway and points the system-wide proxy at the gateway VM so
# curl and apt (when allowed) also go through Squid. Claude Code gets its proxy
# from /etc/claude-code/managed-settings.json. Fails if the result is not
# exactly one lab interface with no route out.
#
#   sudo bash kali-netconfig.sh [interface]      (default: eth0)

set -euo pipefail
IF="${1:-eth0}"
LAB_IP=10.0.3.11/24
GW_PROXY=http://10.0.3.1:3128

die() { echo "FAIL: $*" >&2; exit 1; }

mapfile -t eths < <(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="ethernet"{print $1}')
[[ ${#eths[@]} -eq 1 && "${eths[0]}" == "$IF" ]] ||
  die "expected exactly one ethernet adapter ($IF), found: ${eths[*]:-none}. Remove the others in VMware."

# NetworkManager ignores an interface that /etc/network/interfaces configures
# (e.g. a static address typed into the Kali installer), and then can't apply
# the lab profile. Stop before changing anything.
state="$(nmcli -g GENERAL.STATE device show "$IF" 2>/dev/null || true)"
if [[ "$state" == *unmanaged* ]]; then
  echo "NetworkManager doesn't manage $IF ($state), so it can't apply the lab profile." >&2
  if grep -sEn "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]].*\\b$IF\\b" \
       /etc/network/interfaces /etc/network/interfaces.d/* >&2; then
    die "$IF is configured in the file above (ifupdown). Comment out its lines there
      (keep the 'lo' ones), run 'sudo nmcli device set $IF managed yes', then re-run."
  fi
  die "check 'nmcli device status' and /etc/NetworkManager/conf.d/ for an unmanaged-devices
      setting, then re-run."
fi

echo "  network 1/4: NetworkManager: one static lab profile on $IF, nothing else autoconnects"
nmcli connection delete cvp-lab >/dev/null 2>&1 || true
while IFS=: read -r uuid type; do
  [[ "$type" == loopback ]] && continue
  nmcli connection modify "$uuid" connection.autoconnect no
  nmcli connection down "$uuid" >/dev/null 2>&1 || true
done < <(nmcli -t -f UUID,TYPE connection show)
nmcli connection add type ethernet ifname "$IF" con-name cvp-lab \
  ipv4.method manual ipv4.addresses "$LAB_IP" \
  ipv4.never-default yes ipv4.dns "" ipv6.method disabled \
  connection.autoconnect yes connection.autoconnect-priority 100
nmcli connection up cvp-lab

echo "  network 2/4: system-wide proxy environment (CLI tools, every login)"
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
# apt (only useful while cvp-mode login/update + extra domains are active)
cat > /etc/apt/apt.conf.d/90cvp-proxy <<EOF
Acquire::http::Proxy "$GW_PROXY";
Acquire::https::Proxy "$GW_PROXY";
EOF

echo "  network 3/4: hosts entries so nothing needs DNS inside the lab"
# Windows targets are 10.0.3.21-30: win-app-01 is .21 ... win-app-10 is .30
sed -i '/^# cvp-lab hosts begin/,/^# cvp-lab hosts end/d' /etc/hosts
{
  echo "# cvp-lab hosts begin"
  echo "10.0.3.1   cvp-gw"
  for i in $(seq 21 30); do printf '10.0.3.%d  win-app-%02d\n' "$i" $((i - 20)); done
  echo "# cvp-lab hosts end"
} >> /etc/hosts

echo "  network 4/4: checks"
[[ -z "$(ip route show default; ip -6 route show default)" ]] || die "a default route exists"
ip -4 -o addr show dev "$IF" | grep -q " ${LAB_IP} " || die "$LAB_IP is not on $IF"
[[ -z "$(ip -4 -o addr show scope global | grep -v " ${LAB_IP} ")" ]] || die "extra IPv4 addresses present"
echo "ok: $IF = $LAB_IP, no default route, no other addresses"

