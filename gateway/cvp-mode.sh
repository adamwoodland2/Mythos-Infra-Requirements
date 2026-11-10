#!/usr/bin/env bash
# /usr/local/sbin/cvp-mode  -  switch the Squid allow-list between modes
#
#   sudo cvp-mode run     -> api.anthropic.com + platform.claude.com only  (default)
#   sudo cvp-mode login   -> adds claude.ai and claude.com (exact) for re-authenticating
#   sudo cvp-mode update  -> adds downloads.claude.ai and github.com for `claude update`
#                            and `git pull` of this repo on Kali
#   sudo cvp-mode status  -> show which list is active and tail recent denials
#
# Every switch is written to /var/log/cvp-mode.log so the audit trail shows
# when a wider list was in use. Switching back to run restarts Squid, so no
# tunnel opened under a wider list outlives it. login and update switch back to
# run by themselves after $REVERT (a transient systemd timer), in case it's forgotten.

set -euo pipefail

SQUID_DIR=/etc/squid
ACTIVE="$SQUID_DIR/allowlist.txt"
LOG=/var/log/cvp-mode.log
REVERT=30min
TIMER=cvp-mode-revert

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
    # cancel any pending switch back (when the timer itself runs this, only its timer stops)
    systemctl stop "$TIMER.timer" 2>/dev/null || true
    if [[ "$mode" == run ]]; then
      systemctl restart squid     # drops any tunnel opened under a wider list
    else
      squid -k reconfigure
      systemctl stop "$TIMER.service" 2>/dev/null || true
      systemctl reset-failed "$TIMER.service" 2>/dev/null || true
      systemd-run --quiet --unit="$TIMER" --on-active="$REVERT" /usr/local/sbin/cvp-mode run ||
        echo "WARNING: couldn't schedule the switch back to run - do it by hand" >&2
    fi
    echo "$(date -Is) mode=$mode by=${SUDO_USER:-${USER:-$TIMER}}" >> "$LOG"
    echo "Squid allow-list now: $mode"
    if [[ "$mode" != run ]]; then
      echo "It switches back to run by itself in $REVERT; run 'sudo cvp-mode run' as soon as you're done."
    fi
    ;;
  status)
    echo "Active allow-list -> $(readlink -f "$ACTIVE")"
    if systemctl -q is-active "$TIMER.timer" 2>/dev/null; then
      echo "Switches back to run automatically (pending: $TIMER.timer)"
    fi
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
