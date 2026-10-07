#!/usr/bin/env bash
# /usr/local/sbin/cvp-mode  -  switch the Squid allow-list between modes
#
#   sudo cvp-mode run     -> api.anthropic.com + platform.claude.com only  (default)
#   sudo cvp-mode login   -> adds claude.ai / claude.com for OAuth sign-in
#   sudo cvp-mode status  -> show which list is active and tail recent denials
#
# Every switch is written to /var/log/cvp-mode.log so the audit trail shows
# when the wider list was in use.

set -euo pipefail

SQUID_DIR=/etc/squid
ACTIVE="$SQUID_DIR/allowlist.txt"
LOG=/var/log/cvp-mode.log

mode="${1:-status}"

case "$mode" in
  run|login)
    src="$SQUID_DIR/allowlist-$mode.txt"
    [[ -f "$src" ]] || { echo "missing $src" >&2; exit 1; }
    ln -sfn "$src" "$ACTIVE"
    squid -k parse >/dev/null
    squid -k reconfigure
    echo "$(date -Is) mode=$mode by=${SUDO_USER:-$USER}" >> "$LOG"
    echo "Squid allow-list now: $mode"
    [[ "$mode" == "login" ]] && echo "REMEMBER: run 'sudo cvp-mode run' before starting any engagement."
    ;;
  status)
    echo "Active allow-list -> $(readlink -f "$ACTIVE")"
    echo "--- entries ---"
    grep -vE '^\s*(#|$)' "$ACTIVE" || true
    echo "--- last 10 mode switches ---"
    tail -n 10 "$LOG" 2>/dev/null || echo "(none yet)"
    echo "--- last 20 denied requests ---"
    grep TCP_DENIED /var/log/squid/access.log 2>/dev/null | tail -n 20 || echo "(none)"
    ;;
  *)
    echo "usage: cvp-mode {run|login|status}" >&2
    exit 2
    ;;
esac
