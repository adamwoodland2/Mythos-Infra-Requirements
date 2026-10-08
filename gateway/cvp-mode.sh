#!/usr/bin/env bash
# /usr/local/sbin/cvp-mode  -  switch the Squid allow-list between modes
#
#   sudo cvp-mode run     -> api.anthropic.com + platform.claude.com only  (default)
#   sudo cvp-mode login   -> adds claude.ai and claude.com (exact) for re-authenticating
#   sudo cvp-mode update  -> adds downloads.claude.ai for `claude update`
#   sudo cvp-mode status  -> show which list is active and tail recent denials
#
# Every switch is written to /var/log/cvp-mode.log so the audit trail shows
# when a wider list was in use. Switching back to run restarts Squid, so no
# tunnel opened under a wider list outlives it.

set -euo pipefail

SQUID_DIR=/etc/squid
ACTIVE="$SQUID_DIR/allowlist.txt"
LOG=/var/log/cvp-mode.log

mode="${1:-status}"

case "$mode" in
  run|login|update)
    src="$SQUID_DIR/allowlist-$mode.txt"
    [[ -f "$src" ]] || { echo "missing $src" >&2; exit 1; }
    prev="$(readlink -f "$ACTIVE")"
    ln -sfn "$src" "$ACTIVE"
    if ! squid -k parse >/dev/null; then
      ln -sfn "$prev" "$ACTIVE"
      echo "squid rejected $src; allow-list left as $prev" >&2
      exit 1
    fi
    if [[ "$mode" == run ]]; then
      systemctl restart squid     # drops any tunnel opened under a wider list
    else
      squid -k reconfigure
    fi
    echo "$(date -Is) mode=$mode by=${SUDO_USER:-$USER}" >> "$LOG"
    echo "Squid allow-list now: $mode"
    if [[ "$mode" != run ]]; then
      echo "REMEMBER: run 'sudo cvp-mode run' before starting any engagement."
    fi
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
    echo "usage: cvp-mode {run|login|update|status}" >&2
    exit 2
    ;;
esac
