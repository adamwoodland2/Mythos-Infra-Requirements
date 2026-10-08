#!/usr/bin/env bash
# Read-only validation for the Kali / Claude Code VM.
#
# Run after the gateway and at least one Windows target are online:
#   bash validation/validate-kali.sh [target-ip]
#
# The target defaults to 10.0.3.21. If it is in the cvp-scope set
# (`sudo cvp-scope set <ip>`) the script checks it is reachable; if not, it
# checks the scope firewall blocks it. No configuration is changed. The script
# exits 0 only when every check passes, otherwise it exits 1.

set -uo pipefail

EXPECTED_IP="10.0.3.11/24"
GATEWAY_IP="10.0.3.1"
PROXY="http://${GATEWAY_IP}:3128"
TARGET_IP="${1:-10.0.3.21}"
MIN_CLAUDE="2.1.257"
SETTINGS="/etc/claude-code/managed-settings.json"
SCOPE_STATE="/run/cvp-scope.targets"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  printf 'PASS  %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'FAIL  %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

check() {
  local description="$1"
  shift
  if "$@"; then
    pass "$description"
  else
    fail "$description"
  fi
}

have_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || return 1
  done
}

has_expected_address_only() {
  local -a addresses=()
  mapfile -t addresses < <(ip -o -4 address show scope global | awk '{print $4}')
  [[ ${#addresses[@]} -eq 1 && "${addresses[0]}" == "$EXPECTED_IP" ]]
}

no_ipv4_default_route() {
  [[ -z "$(ip -4 route show default 2>/dev/null)" ]]
}

no_ipv6_connectivity() {
  [[ -z "$(ip -6 route show default 2>/dev/null)" ]] &&
    [[ -z "$(ip -o -6 address show scope global 2>/dev/null)" ]]
}

proxy_environment_ok() {
  [[ "${HTTPS_PROXY:-}" == "$PROXY" ]] &&
    [[ "${HTTP_PROXY:-}" == "$PROXY" ]] &&
    [[ "${https_proxy:-}" == "$PROXY" ]] &&
    [[ "${http_proxy:-}" == "$PROXY" ]] &&
    [[ ",${NO_PROXY:-}," == *",10.0.3.0/24,"* ]] &&
    [[ ",${no_proxy:-}," == *",10.0.3.0/24,"* ]]
}

no_static_api_credentials_in_environment() {
  local variable_name
  for variable_name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    [[ -z "${!variable_name:-}" ]] || return 1
  done
}

settings_ok() {
  [[ -f "$SETTINGS" ]] || return 1
  # root-owned and not writable by this user, so Claude can't change its own policy
  [[ "$(stat -c '%U' "$SETTINGS")" == "root" && ! -w "$SETTINGS" ]] || return 1
  python3 - "$SETTINGS" "$PROXY" 2>/dev/null <<'PY'
import json
import sys

path, proxy = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

env = data.get("env", {})
permissions = data.get("permissions", {})
auto_mode = data.get("autoMode", {})

assert env.get("HTTPS_PROXY") == proxy
assert env.get("HTTP_PROXY") == proxy
assert env.get("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") == "1"
assert env.get("ENABLE_CLAUDEAI_MCP_SERVERS") == "false"
assert env.get("CLAUDE_CODE_DISABLE_ARTIFACT") == "1"
assert not env.get("ANTHROPIC_API_KEY")
assert not env.get("ANTHROPIC_AUTH_TOKEN")
assert data.get("forceLoginMethod") == "claudeai"
assert permissions.get("defaultMode") == "auto"
assert permissions.get("disableBypassPermissionsMode") == "disable"
assert {"WebFetch", "WebSearch"}.issubset(set(permissions.get("deny", [])))
assert "$defaults" in auto_mode.get("environment", [])
assert "$defaults" in auto_mode.get("hard_deny", [])
assert "$defaults" in auto_mode.get("soft_deny", [])
PY
}

claude_version_ok() {
  local version
  version="$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')"
  [[ -n "$version" ]] || return 1
  [[ "$(printf '%s\n' "$MIN_CLAUDE" "$version" | sort -V | head -n 1)" == "$MIN_CLAUDE" ]]
}

claude_auth_ok() {
  claude auth status --text >/dev/null 2>&1
}

claude_auto_mode_ok() {
  claude auto-mode config >/dev/null 2>&1
}

ping_reachable() {
  ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

scope_firewall_loaded() {
  [[ -e "$SCOPE_STATE" ]]
}

target_in_scope() {
  grep -Fxq "$TARGET_IP" "$SCOPE_STATE" 2>/dev/null
}

target_blocked_by_scope() {
  ! ping_reachable "$TARGET_IP"
}

tcp_reachable() {
  local address="$1"
  local port="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/${address}/${port}" >/dev/null 2>&1
}

direct_external_tcp_blocked() {
  ! tcp_reachable 1.1.1.1 443
}

public_dns_blocked() {
  ! timeout 5 getent ahosts example.com >/dev/null 2>&1
}

proxy_allows_destination() {
  local destination="$1"
  local status
  status="$(curl --proxy "$PROXY" --connect-timeout 5 --max-time 15 \
    --silent --show-error --output /dev/null --write-out '%{http_code}' \
    "$destination" 2>/dev/null)" || return 1
  [[ "$status" =~ ^[1-5][0-9][0-9]$ && "$status" != "000" ]]
}

proxy_blocks_destination() {
  local destination="$1"
  local connect_status
  connect_status="$(curl --proxy "$PROXY" --insecure --connect-timeout 5 --max-time 10 \
    --silent --output /dev/null --write-out '%{http_connect}' \
    "$destination" 2>/dev/null || true)"
  [[ "$connect_status" == "403" ]]
}

hosts_entry_matches() {
  local name="$1"
  local expected="$2"
  getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | grep -Fxq "$expected"
}

no_vmware_shared_folder_mount() {
  ! findmnt --raw --noheadings --types fuse.vmhgfs,vmhgfs >/dev/null 2>&1
}

local_files_secure() {
  local claude_mode key_mode
  [[ -d "${HOME}/.claude" ]] || return 1
  claude_mode="$(stat -c '%a' "${HOME}/.claude")"
  [[ "$claude_mode" == "700" ]] || return 1

  [[ -f "${HOME}/.ssh/cvpsync" && -f "${HOME}/.ssh/cvpsync.pub" ]] || return 1
  key_mode="$(stat -c '%a' "${HOME}/.ssh/cvpsync")"
  [[ "$key_mode" == "600" ]] || return 1
  [[ -x /usr/local/bin/sync-transcripts ]] || return 1
  systemctl is-active --quiet cvp-sync.timer
}

if [[ ! "$TARGET_IP" =~ ^10\.0\.3\.(2[1-9]|30)$ ]]; then
  printf 'ERROR target IP must be in 10.0.3.21-30\n' >&2
  exit 2
fi

TARGET_LAST_OCTET="${TARGET_IP##*.}"
TARGET_NAME="$(printf 'win-app-%02d' "$((10#$TARGET_LAST_OCTET - 20))")"

printf 'CVP Kali validation (read-only)\n'
printf 'Target: %s (%s)\n\n' "$TARGET_NAME" "$TARGET_IP"
printf 'Scope: automated host and network checks only. Account MFA, personal use,\n'
printf 'VMware UI settings and gateway log retention still require manual review.\n\n'

check "running as the normal user, not root" test "$EUID" -ne 0
check "required validation commands are installed" have_commands \
  ip awk grep getent ping timeout curl findmnt stat python3 sort head claude
check "only ${EXPECTED_IP} is configured as a global IPv4 address" has_expected_address_only
check "no IPv4 default route exists" no_ipv4_default_route
check "no IPv6 default route or global IPv6 address exists" no_ipv6_connectivity
check "HTTP(S) proxy environment points to ${PROXY}" proxy_environment_ok
check "no static Anthropic API credential is exported" no_static_api_credentials_in_environment
check "Claude Code managed settings are root-owned and contain the required containment controls" settings_ok
check "Claude Code is at least version ${MIN_CLAUDE}" claude_version_ok
check "Claude Code reports a valid signed-in session" claude_auth_ok
check "Claude Code accepts the effective Auto Mode configuration" claude_auto_mode_ok
check "gateway responds on the lab segment" ping_reachable "$GATEWAY_IP"
check "cvp-scope firewall is loaded" scope_firewall_loaded
if target_in_scope; then
  check "Windows target ${TARGET_IP} (in scope) responds on the lab segment" ping_reachable "$TARGET_IP"
else
  check "Windows target ${TARGET_IP} (not in scope) is blocked by cvp-scope" target_blocked_by_scope
fi
check "${TARGET_NAME} resolves to ${TARGET_IP} through /etc/hosts" hosts_entry_matches "$TARGET_NAME" "$TARGET_IP"
check "Squid is reachable at ${GATEWAY_IP}:3128" tcp_reachable "$GATEWAY_IP" 3128
check "transcript drop-box SSH is reachable at ${GATEWAY_IP}:22" tcp_reachable "$GATEWAY_IP" 22
check "direct external TCP access is blocked" direct_external_tcp_blocked
check "public DNS resolution is blocked" public_dns_blocked
check "proxy permits api.anthropic.com over HTTPS" proxy_allows_destination "https://api.anthropic.com/"
check "proxy permits platform.claude.com over HTTPS" proxy_allows_destination "https://platform.claude.com/"
check "proxy blocks a non-allow-listed hostname" proxy_blocks_destination "https://example.com/"
check "proxy blocks a bare external IP address" proxy_blocks_destination "https://1.1.1.1/"
check "no VMware shared-folder filesystem is mounted" no_vmware_shared_folder_mount
check "Claude directory, transcript key, sync script and sync timer are in place" local_files_secure

printf '\nSummary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if ((FAIL_COUNT == 0)); then
  printf 'ALL AUTOMATED CHECKS PASSED\n'
  exit 0
fi

printf 'VALIDATION FAILED\n'
exit 1
