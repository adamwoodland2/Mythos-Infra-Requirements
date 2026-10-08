#!/usr/bin/env bash
# /usr/local/sbin/cvp-scope  -  set which lab targets Kali may connect to
#
#   sudo cvp-scope set 10.0.3.21 [10.0.3.22 ...]   replace the in-scope set (targets are .21-.30)
#   sudo cvp-scope none                             no targets (also the state after every boot)
#   cvp-scope status                                show the current set
#
# Use exactly the IPs listed as in scope in the engagement's CLAUDE.md; cvp-run
# refuses to start Claude Code if the two differ. Every change is logged to
# /var/log/cvp-scope.log. The current set is mirrored to /run/cvp-scope.targets
# so cvp-run can check it without root.

set -euo pipefail
LOG=/var/log/cvp-scope.log
STATE=/run/cvp-scope.targets
re='^10\.0\.3\.(2[1-9]|30)$'

need_root() { [[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }; }

apply() {   # apply [IP...] - replace the set, mirror it, log it
  local cmds="flush set inet cvp_scope targets"
  if [[ $# -gt 0 ]]; then cmds+=$'\n'"add element inet cvp_scope targets { $(IFS=,; echo "$*") }"; fi
  nft -f - <<<"$cmds"
  printf '%s\n' "$@" > "$STATE"
  chmod 644 "$STATE"
  echo "$(date -Is) scope=${*:-none} by=${SUDO_USER:-root}" >> "$LOG"
}

case "${1:-status}" in
  boot)     # cvp-scope.service: load the ruleset with an empty set
    need_root
    nft -f /etc/cvp-scope.nft
    : > "$STATE"; chmod 644 "$STATE"
    echo "$(date -Is) scope=none (boot)" >> "$LOG"
    ;;
  set)
    need_root
    shift
    [[ $# -gt 0 ]] || { echo "usage: cvp-scope set <IP>..." >&2; exit 2; }
    for ip in "$@"; do
      [[ "$ip" =~ $re ]] || { echo "refusing $ip: targets are 10.0.3.21-30" >&2; exit 1; }
    done
    apply "$@"
    ;;
  none)
    need_root
    apply
    ;;
  status) ;;
  *)
    echo "usage: cvp-scope {set <IP>...|none|status}" >&2
    exit 2
    ;;
esac

echo "In-scope targets: $(paste -sd' ' "$STATE" 2>/dev/null || true)"
