#!/usr/bin/env bash
# setup-kali.sh  -  Kali VM setup for the CVP lab. Run as your normal user
# (not root) from a clone of this repo; it uses sudo where it needs root.
#
#   bash kali/setup-kali.sh build       Phase A, on NAT: update Kali, install Claude Code,
#                                       settings.json, transcript sync key and script
#   bash kali/setup-kali.sh share-key   Phase B, on the lab segment: serve the sync PUBLIC
#                                       key for `sudo cvp-enrol-key` on the gateway
#
# The Phase B network change is separate:  sudo bash kali/kali-netconfig.sh
#
# Set CVP_ORG="Business name" to skip the prompt for the auto mode context.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KALI_IP=10.0.3.11
MIN_CLAUDE=2.1.257          # needed for the Host containment entry in settings.json
KEY="$HOME/.ssh/cvpsync"

[[ $EUID -ne 0 ]] || { echo "run as your normal user, not root (Claude Code installs per user)" >&2; exit 1; }

build() {
  echo "[1/5] update Kali and install sync prerequisites"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install curl rsync openssh-client python3

  echo "[2/5] Claude Code (native installer)"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    grep -qs '\.local/bin' "$rc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
  done
  ver="$(claude --version | awk '{print $1}')"
  if [[ "$(printf '%s\n' "$MIN_CLAUDE" "$ver" | sort -V | head -n1)" != "$MIN_CLAUDE" ]]; then
    echo "Claude Code $ver is older than $MIN_CLAUDE - run 'claude update' and re-run" >&2
    exit 1
  fi
  echo "Claude Code $ver"

  org="${CVP_ORG:-}"
  [[ -n "$org" ]] || read -rp "Business name for the auto mode context: " org
  [[ -n "$org" && "$org" != *[\"\\/\&]* ]] || { echo "business name must be non-empty, without \" \\ / &" >&2; exit 1; }

  echo "[3/5] sign in (OAuth) while Kali still has direct internet"
  # Must happen before settings.json goes in: its proxy (10.0.3.1) is unreachable on NAT.
  mkdir -p "$HOME/.claude" && chmod 700 "$HOME/.claude"
  if [[ -f "$HOME/.claude/settings.json" ]]; then
    mv "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak.$(date +%Y%m%d%H%M%S)"
  fi
  if ! claude auth status >/dev/null 2>&1; then
    echo "Finish the browser step in Kali's browser, or open the URL in a browser on the host"
    echo "(where your Google account and security keys work) and paste the code back here."
    claude auth login
  fi
  claude auth status --text

  echo "[4/5] ~/.claude/settings.json"
  sed "s/<YOUR BUSINESS NAME>/$org/" "$HERE/settings.json" > "$HOME/.claude/settings.json"
  python3 -m json.tool "$HOME/.claude/settings.json" >/dev/null

  echo "[5/5] transcript sync key and script"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -f "$KEY" -N '' -C "cvpsync@$(hostname)"
  install -D -m 0755 "$HERE/sync-transcripts.sh" "$HOME/bin/sync-transcripts.sh"
  echo "Sync key: $(ssh-keygen -lf "$KEY.pub")"

  cat <<EOF

Done. Still on NAT:
  1. Install all the tooling the engagements need now - nothing can be fetched
     once Kali is in the lab. (Don't start claude again until Phase B: it now
     expects the lab proxy.)
  2. Shut down and continue at CHECKLIST §4 Phase B:
       sudo bash $HERE/kali-netconfig.sh
       bash $HERE/setup-kali.sh share-key
EOF
}

share_key() {
  [[ -f "$KEY.pub" ]] || { echo "no $KEY.pub - run '$0 build' first" >&2; exit 1; }
  ip -4 -o addr show | grep -q " $KALI_IP/" || { echo "$KALI_IP is not configured - run kali-netconfig.sh first" >&2; exit 1; }
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  cp "$KEY.pub" "$dir/cvpsync.pub"     # serve a copy, never ~/.ssh itself
  cat <<EOF
Serving the PUBLIC key at http://$KALI_IP:8000/cvpsync.pub for up to 5 minutes.
On the gateway console run:   sudo cvp-enrol-key
Its fingerprint must match:   $(ssh-keygen -lf "$KEY.pub")
Press Ctrl+C here once it is installed, then test with:  ~/bin/sync-transcripts.sh
EOF
  timeout 300 python3 -m http.server 8000 --bind "$KALI_IP" --directory "$dir" || true
}

case "${1:-}" in
  build)     build ;;
  share-key) share_key ;;
  *)         echo "usage: $0 {build|share-key}" >&2; exit 2 ;;
esac
