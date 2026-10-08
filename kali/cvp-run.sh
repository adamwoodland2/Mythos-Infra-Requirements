#!/usr/bin/env bash
# /usr/local/bin/cvp-run  -  pre-flight checks, then Claude Code with a hard time limit
#
#   cd ~/engagements/<name> && cvp-run <hours>
#
# Run it from the engagement directory; its CLAUDE.md names the in-scope
# targets. If any check fails it does not start Claude Code, so a
# misconfigured lab fails closed instead of running. <hours> (1-12) is
# required - choose it for the engagement; there is deliberately no default.
# When the limit is reached Claude Code is stopped, and anything it left
# running (e.g. a long scan) is killed with it.

set -uo pipefail
CONF=/etc/cvp-lab.conf
MANAGED=/etc/claude-code/managed-settings.json
# shellcheck source=/dev/null
[[ -r "$CONF" ]] && . "$CONF"

hours="${1:-}"
if ! [[ "$hours" =~ ^([1-9]|1[0-2])$ ]]; then
  echo "usage: cvp-run <hours 1-12>   (a hard time limit for this run; there is no default)" >&2
  exit 2
fi

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
warn() { printf '  warn  %s\n' "$*"; }

echo "Workspace"
if [[ -f CLAUDE.md ]]; then ok "CLAUDE.md present"; else bad "no CLAUDE.md here - copy kali/CLAUDE.md.template and fill it in"; fi
if grep -qE '<(ENGAGEMENT NAME|DATE|YOUR NAME|TICKET)' CLAUDE.md 2>/dev/null; then bad "CLAUDE.md still has template placeholders"; fi
if git remote -v 2>/dev/null | grep -qi 'Mythos-Infra-Requirements'; then
  bad "this is inside the public lab repo - use a directory outside it, e.g. ~/engagements/<name>"
else
  ok "not inside the public lab repo"
fi

echo "Network"
mapfile -t ifs < <(ip -o link show up | awk -F': ' '{sub(/@.*/, "", $2); if ($2 != "lo") print $2}')
if [[ ${#ifs[@]} -eq 1 ]]; then ok "one interface up (${ifs[0]})"; else bad "interfaces up: ${ifs[*]:-none} - expected exactly one"; fi
if ip -4 -o addr show | grep -q ' 10\.0\.3\.11/24 '; then ok "address 10.0.3.11/24"; else bad "10.0.3.11/24 not configured"; fi
if [[ -n "$(ip -4 -o addr show scope global | grep -v ' 10\.0\.3\.11/24 ')" ]]; then bad "extra IPv4 addresses present"; fi
if [[ -z "$(ip route show default; ip -6 route show default)" ]]; then ok "no default route"; else bad "a default route exists"; fi

echo "Scope"
mapfile -t want < <(awk '/^## In scope/{f=1; next} /^## /{f=0} f && /^\|/' CLAUDE.md 2>/dev/null |
                    grep -oE '10\.0\.3\.[0-9]+' | sort -u)
mapfile -t have < <(sort -u /run/cvp-scope.targets 2>/dev/null)
if [[ ! -e /run/cvp-scope.targets ]]; then
  bad "cvp-scope firewall not loaded (sudo systemctl start cvp-scope)"
elif [[ "${want[*]}" == "${have[*]}" ]]; then
  ok "firewall scope matches CLAUDE.md: ${have[*]:-no targets}"
else
  bad "firewall scope (${have[*]:-none}) != CLAUDE.md in-scope table (${want[*]:-none}) - run: sudo cvp-scope set ${want[*]:-...}"
fi

echo "Credentials and model"
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_PROFILE \
         CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS \
         CLAUDE_CODE_USE_MANTLE AWS_BEARER_TOKEN_BEDROCK; do
  if [[ -n "${!v:-}" ]]; then bad "$v is set - it would take precedence over the OAuth login"; fi
done
for f in "$HOME/.claude/settings.json" .claude/settings.json .claude/settings.local.json; do
  [[ -f "$f" ]] || continue
  if python3 - "$f" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
bad = {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"}
sys.exit(0 if "apiKeyHelper" in s or bad & set(s.get("env", {})) else 1)
PY
  then bad "$f sets apiKeyHelper or a credential/endpoint variable"; fi
done
if [[ "$(stat -c %U "$MANAGED" 2>/dev/null)" == root && ! -w "$MANAGED" ]]; then
  ok "managed settings in place (root-owned)"
else
  bad "$MANAGED missing or writable by you - re-run setup-kali.sh build"
fi
auth="$(claude auth status 2>/dev/null)"
python3 - "$auth" "${CVP_ACCOUNT_EMAIL:-}" <<'PY'
import json, sys
try:
    a = json.loads(sys.argv[1])
except ValueError:
    print("  FAIL  claude auth status gave no JSON - signed in?"); sys.exit(1)
want, rc = sys.argv[2].lower(), 0
if a.get("authMethod") == "claude.ai":
    print("  ok    signed in with claude.ai OAuth")
else:
    print(f"  FAIL  auth method is {a.get('authMethod')!r}, not 'claude.ai'"); rc = 1
email = (a.get("email") or (a.get("account") or {}).get("email") or "").lower()
if not want:
    print("  warn  no CVP_ACCOUNT_EMAIL in /etc/cvp-lab.conf - check the account in /status")
elif not email:
    print("  warn  auth status shows no email - check the account in /status")
elif email == want:
    print(f"  ok    account {email}")
else:
    print(f"  FAIL  signed in as {email}, expected {want}"); rc = 1
sys.exit(rc)
PY
[[ $? -eq 0 ]] || fail=1
if [[ -n "${CVP_MODEL:-}" ]]; then
  if python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s.get("model")==sys.argv[2] and s.get("availableModels")==[sys.argv[2]] else 1)' "$MANAGED" "$CVP_MODEL" 2>/dev/null; then
    ok "model pinned to $CVP_MODEL"
  else
    bad "managed settings don't pin $CVP_MODEL"
  fi
else
  warn "no model pinned (CVP_MODEL unset) - confirm the model in /status before starting"
fi

echo "Egress (through the gateway proxy)"
code() { curl -s -o /dev/null -m 15 -x http://10.0.3.1:3128 -w '%{http_connect}' "$1"; }
if [[ "$(code https://api.anthropic.com/)" == 200 ]]; then ok "api.anthropic.com reachable via proxy"; else bad "api.anthropic.com not reachable via proxy"; fi
if [[ "$(code https://example.com/)" == 403 ]]; then ok "example.com refused by proxy"; else bad "example.com was NOT refused by the proxy"; fi

echo "Host"
sudo -k
if sudo -n true 2>/dev/null; then bad "passwordless sudo works - the agent could undo the scope and read anything"; else ok "no passwordless sudo"; fi
if grep -qE 'vmhgfs|hgfs' /proc/mounts; then bad "a VMware shared folder is mounted"; else ok "no VMware shared folders mounted"; fi
if pkill -u "$USER" -f 'vmtoolsd -n vmusr'; then
  warn "stopped the VMware user agent (copy/paste, drag and drop) for this login"
fi
if systemctl is-active --quiet cvp-sync.timer; then ok "transcript sync timer running"; else bad "cvp-sync.timer not running"; fi

if [[ $fail -ne 0 ]]; then
  echo
  echo "Not starting Claude Code: fix the FAIL lines above."
  exit 1
fi

runlog="$HOME/.claude/cvp-runs.log"
echo "$(date -Is) start dir=$PWD hours=$hours scope=${have[*]:-none} model=${CVP_MODEL:-unpinned}" >> "$runlog"
echo
echo "All checks passed. Starting Claude Code with a ${hours}h limit."
unit="cvp-run-$(date +%Y%m%d%H%M%S)"
systemd-run --user --scope --quiet --unit="$unit" -- \
  timeout --foreground --kill-after=30 "${hours}h" claude
rc=$?
# kill anything the run left behind (a timeout only stops claude itself)
systemctl --user stop "$unit.scope" 2>/dev/null || true
echo "$(date -Is) end rc=$rc" >> "$runlog"
[[ $rc -eq 124 ]] && echo "Time limit reached - Claude Code was stopped."
/usr/local/bin/sync-transcripts || echo "transcript sync failed - the timer will retry" >&2
