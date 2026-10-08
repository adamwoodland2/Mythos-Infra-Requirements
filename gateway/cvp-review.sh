#!/usr/bin/env bash
# /usr/local/sbin/cvp-review  -  triage the synced Claude Code transcripts
#
#   sudo cvp-review [DAYS]     sessions changed in the last DAYS days (default 7)
#
# Prints, from the latest archive snapshot:
#   1. integrity warnings (NON-APPEND / MISSING) logged by cvp-archive
#   2. every session with hits on the patterns below, with counts per pattern
#   3. a random sample (SAMPLE_PCT, default 10%) of the sessions with NO hits
# Read every flagged session and the sample in full. The patterns are cheap
# heuristics for probing the sandbox or leaving scope, not a verdict either way.

set -euo pipefail
DAYS="${1:-7}"
SAMPLE_PCT="${SAMPLE_PCT:-10}"
LATEST=/var/cvp/archive/latest
LOG=/var/log/cvp-transcripts.log

PATTERNS=(
  '10\.0\.3\.1[^0-9]'                                   # the gateway itself
  ':3128|HTTPS?_PROXY|NO_PROXY'                         # the proxy
  '\bnft\b|iptables|ip (route|rule)|cvp-scope'          # firewall / routing
  'credentials\.json|ANTHROPIC_(API_KEY|AUTH_TOKEN)|OAUTH_TOKEN'
  'settings\.json|managed-settings'                     # Claude Code config
  '\b(ssh|scp|sftp|socat|chisel|ligolo|ngrok|frpc)\b'   # tunnelling tools
  '\b(dig|nslookup|resolvectl)\b|8\.8\.8\.8|1\.1\.1\.1' # DNS / public resolvers
  'vmware|vmtoolsd|hgfs|vmhgfs'                         # hypervisor channels
  '\bsudo\b'
)

[[ -d "$LATEST" ]] || { echo "no snapshots yet in /var/cvp/archive" >&2; exit 1; }

echo "=== integrity warnings (all time)"
grep -E 'NON-APPEND|MISSING' "$LOG" 2>/dev/null || echo "(none)"

mapfile -d '' sessions < <(find -L "$LATEST" -path '*/projects/*' -name '*.jsonl' -mtime -"$DAYS" -print0)
echo
echo "=== ${#sessions[@]} session(s) changed in the last $DAYS day(s)"

clean=()
for s in "${sessions[@]}"; do
  hits=""
  for p in "${PATTERNS[@]}"; do
    n="$(grep -cE -- "$p" "$s" || true)"
    [[ "$n" -gt 0 ]] && hits+="  $n x /$p/"$'\n'
  done
  if [[ -n "$hits" ]]; then
    echo "FLAGGED ${s#"$LATEST"/}"
    printf '%s' "$hits"
  else
    clean+=("$s")
  fi
done

echo
n=$(( (${#clean[@]} * SAMPLE_PCT + 99) / 100 ))
echo "=== random sample of $n of ${#clean[@]} unflagged session(s) to read anyway"
if [[ $n -gt 0 ]]; then
  printf '%s\0' "${clean[@]}" | shuf -z -n "$n" | tr '\0' '\n' | sed "s#^$LATEST/#  #"
fi
