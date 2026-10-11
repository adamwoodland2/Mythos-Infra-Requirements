#!/usr/bin/env bash
# /usr/local/bin/cvp-engagement  -  set up, re-scope and close engagements on Kali
#
#   cvp-engagement new <name> <IP> [<IP> ...]   make ~/engagements/<name> with a filled-in
#                                              CLAUDE.md and findings/, and set cvp-scope
#   cvp-engagement scope <name>                 set cvp-scope from that CLAUDE.md again
#                                              (after a reboot, or after editing the table)
#   cvp-engagement close <name>                 sync everything to the gateway, clear the scope
#   cvp-engagement list                         list engagements and their in-scope IPs
#
# <name>: lower-case letters, digits and hyphens, e.g. acme-web-2026-10.
# Targets are 10.0.3.21-30 (win-app-01 ... win-app-10). See GUIDE.md.

set -euo pipefail
ROOT="$HOME/engagements"
TEMPLATE=/usr/local/share/cvp-lab/CLAUDE.md.template

die() { echo "$*" >&2; exit 1; }

check_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] ||
    die "name must be lower-case letters, digits and hyphens (up to 48), e.g. acme-web-2026-10"
}

scope_ips() {   # the IPs in a CLAUDE.md's In scope table (the same rule cvp-run uses)
  awk '/^## In scope/{f=1; next} /^## /{f=0} f && /^\|/' "$1" | grep -oE '10\.0\.3\.[0-9]+' | sort -u || true
}

new() {
  local name="${1:-}"
  check_name "$name"
  shift
  [[ $# -gt 0 ]] || die "usage: cvp-engagement new <name> <IP> [<IP> ...]"
  local ip re='^10\.0\.3\.(2[1-9]|30)$'
  for ip in "$@"; do
    [[ "$ip" =~ $re ]] || die "refusing $ip: targets are 10.0.3.21-30"
  done
  local dir="$ROOT/$name"
  [[ ! -e "$dir" ]] || die "$dir already exists"
  [[ -r "$TEMPLATE" ]] || die "missing $TEMPLATE - re-run setup-kali.sh lab"

  local who auth
  read -rp "Your name (for the authorisation line): " who
  read -rp "Authorisation reference (ticket or engagement ID): " auth
  [[ -n "$who" && -n "$auth" ]] || die "both are required"

  mkdir -p "$dir/findings"
  python3 - "$TEMPLATE" "$name" "$(date +%Y-%m-%d)" "$who" "$auth" "$@" > "$dir/CLAUDE.md" <<'PY'
import re, sys
tpl, name, date, who, auth, *ips = sys.argv[1:]
t = open(tpl).read()
for old, new in (("<ENGAGEMENT NAME>", name), ("<DATE>", date),
                 ("<YOUR NAME>", who), ("<TICKET / ENGAGEMENT ID>", auth)):
    t = t.replace(old, new)
# the template's how-to-use text and operator notes are for people, not for Claude
t = re.sub(r"^(# [^\n]*\n).*?(?=^## Authorisation)", r"\1\n", t, count=1, flags=re.S | re.M)
rows = "".join(
    f"| win-app-{int(ip.rsplit('.', 1)[1]) - 20:02d} | {ip} | Windows app server (replica, not production) "
    "| recon, vuln discovery, exploitation, post-exploitation on this host only |\n"
    for ip in ips)
t = re.sub(r"^\| win-app-01 \|.*\n", lambda m: rows, t, flags=re.M)
t = t.replace(" (Add a row per target in use,\n  from win-app-01 = 10.0.3.21 to win-app-10 = 10.0.3.30.)", "")
sys.stdout.write(t)
PY
  sudo cvp-scope set "$@"
  cat <<EOF

Created $dir
  CLAUDE.md   in scope: $* - check the Role and Permitted actions columns
  findings/   where Claude writes its findings
Next:
  cd $dir
  cvp-run <hours>
EOF
}

scope() {
  local name="${1:-}"
  check_name "$name"
  local f="$ROOT/$name/CLAUDE.md"
  [[ -f "$f" ]] || die "no $f"
  local -a ips
  mapfile -t ips < <(scope_ips "$f")
  if [[ ${#ips[@]} -gt 0 ]]; then
    sudo cvp-scope set "${ips[@]}"
  else
    sudo cvp-scope none
  fi
}

close() {
  local name="${1:-}"
  check_name "$name"
  [[ -d "$ROOT/$name" ]] || die "no $ROOT/$name"
  sync-transcripts
  sudo cvp-scope none
  echo "Closed $name. On the gateway: sudo cvp-review, then sudo cvp-export $name"
}

list() {
  local d
  shopt -s nullglob
  for d in "$ROOT"/*/; do
    d="${d%/}"
    printf '%-32s %s\n' "${d##*/}" "$(scope_ips "$d/CLAUDE.md" 2>/dev/null | paste -sd' ')"
  done
}

case "${1:-}" in
  new)   shift; new "$@" ;;
  scope) scope "${2:-}" ;;
  close) close "${2:-}" ;;
  list)  list ;;
  *)     echo "usage: cvp-engagement {new <name> <IP>...|scope <name>|close <name>|list}" >&2; exit 2 ;;
esac
