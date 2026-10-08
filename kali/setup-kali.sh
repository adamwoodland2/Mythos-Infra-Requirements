#!/usr/bin/env bash
# setup-kali.sh  -  Kali VM setup for the CVP lab. Run as your normal user
# (not root) from a clone of this repo; it uses sudo where it needs root.
#
#   bash kali/setup-kali.sh build       Phase A, on NAT: update Kali, install Claude Code, sign in,
#                                       managed settings, sync key
#   bash kali/setup-kali.sh lab         Phase B, on the lab segment: network, scope firewall,
#                                       cvp-run, transcript sync timer
#   bash kali/setup-kali.sh share-key   Phase B: serve the sync PUBLIC key for `sudo cvp-enrol-key`
#                                       on the gateway
#
# build's questions can be answered in advance:
#   CVP_ORG="Business name" CVP_ACCOUNT_EMAIL=you@example.com CVP_MODEL=<model ID or ''>

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KALI_IP=10.0.3.11
MIN_CLAUDE=2.1.257          # needed for the Host containment entry in managed-settings.json
KEY="$HOME/.ssh/cvpsync"

die() { echo "$*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (Claude Code installs per user)"

build() {
  echo "[1/6] update Kali and install prerequisites"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install curl rsync openssh-client python3 nftables

  echo "[2/6] Claude Code (native installer)"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    grep -qs '\.local/bin' "$rc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
  done
  ver="$(claude --version | awk '{print $1}')"
  if [[ "$(printf '%s\n' "$MIN_CLAUDE" "$ver" | sort -V | head -n1)" != "$MIN_CLAUDE" ]]; then
    die "Claude Code $ver is older than $MIN_CLAUDE - run 'claude update' and re-run"
  fi
  echo "Claude Code $ver"

  org="${CVP_ORG:-}"
  [[ -n "$org" ]] || read -rp "Business name for the auto mode context: " org
  [[ -n "$org" ]] || die "business name is required"
  email="${CVP_ACCOUNT_EMAIL:-}"
  [[ -n "$email" ]] || read -rp "Email of the claude.ai account that holds the CVP grant: " email
  [[ "$email" == ?*@?* ]] || die "that doesn't look like an email address"

  echo "[3/6] sign in (OAuth) while Kali still has direct internet"
  # Must happen before the managed settings go in: their proxy (10.0.3.1) is unreachable on NAT.
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

  echo "[4/6] model to pin"
  if [[ -z "${CVP_MODEL+set}" ]]; then
    echo "To see the exact ID: run 'claude' in another terminal, type /model, note the model"
    echo "your grant is for (e.g. the Mythos model), then /exit."
    read -rp "Model ID or alias to pin (blank = don't pin): " CVP_MODEL
  fi
  model="$CVP_MODEL"
  [[ "$model" =~ ^[A-Za-z0-9._:@/\[\]-]*$ ]] || die "unexpected characters in the model ID"

  echo "[5/6] managed settings and lab config (root-owned, so Claude can't change them)"
  tmp="$(mktemp)"
  python3 - "$HERE/managed-settings.json" "$org" "$model" > "$tmp" <<'PY'
import json, sys
path, org, model = sys.argv[1:]
s = json.load(open(path))
s["autoMode"]["environment"] = [e.replace("<YOUR BUSINESS NAME>", org) for e in s["autoMode"]["environment"]]
if model:
    s["model"] = model
    s["availableModels"] = [model]
    s["enforceAvailableModels"] = True
print(json.dumps(s, indent=2))
PY
  sudo install -d -m 0755 /etc/claude-code
  sudo install -m 0644 -o root -g root "$tmp" /etc/claude-code/managed-settings.json
  printf 'CVP_USER=%q\nCVP_ACCOUNT_EMAIL=%q\nCVP_MODEL=%q\n' "$USER" "$email" "$model" > "$tmp"
  sudo install -m 0644 -o root -g root "$tmp" /etc/cvp-lab.conf
  rm -f "$tmp"

  echo "[6/6] transcript sync key and script"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -f "$KEY" -N '' -C "cvpsync@$(hostname)"
  sudo install -m 0755 -o root -g root "$HERE/sync-transcripts.sh" /usr/local/bin/sync-transcripts
  echo "Sync key: $(ssh-keygen -lf "$KEY.pub")"

  cat <<EOF

Done. Still on NAT:
  1. Install all the tooling the engagements need now - nothing can be fetched
     once Kali is in the lab. (Don't start claude again until Phase B: it now
     expects the lab proxy.)
  2. Shut down, move the adapter to LAN segment cvp-lab, boot, then:
       bash $HERE/setup-kali.sh lab
EOF
}

lab() {
  [[ -f /etc/cvp-lab.conf ]] || die "run '$0 build' first (on NAT)"

  echo "[1/4] network"
  sudo bash "$HERE/kali-netconfig.sh"

  echo "[2/4] scope firewall (no targets until 'sudo cvp-scope set ...')"
  sudo install -m 0644 -o root -g root "$HERE/cvp-scope.nft" /etc/cvp-scope.nft
  sudo install -m 0755 -o root -g root "$HERE/cvp-scope.sh" /usr/local/sbin/cvp-scope
  sudo tee /etc/systemd/system/cvp-scope.service >/dev/null <<'EOF'
[Unit]
Description=CVP lab outbound scope firewall (no targets until cvp-scope set)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cvp-scope boot

[Install]
WantedBy=multi-user.target
EOF

  echo "[3/4] cvp-run (pre-flight checks + time-limited Claude Code)"
  sudo install -m 0755 -o root -g root "$HERE/cvp-run.sh" /usr/local/bin/cvp-run

  echo "[4/4] transcript sync every minute (root-owned timer, runs as $USER)"
  sudo tee /etc/systemd/system/cvp-sync.service >/dev/null <<EOF
[Unit]
Description=Sync Claude Code transcripts to the gateway drop-box

[Service]
Type=oneshot
User=$USER
ExecStart=/usr/local/bin/sync-transcripts
EOF
  sudo tee /etc/systemd/system/cvp-sync.timer >/dev/null <<'EOF'
[Unit]
Description=Sync Claude Code transcripts to the gateway every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now cvp-scope.service cvp-sync.timer

  cat <<EOF

Done. Log out and back in (for the proxy environment), then hand the sync key
to the gateway:   bash $HERE/setup-kali.sh share-key
(The sync timer logs failures until the key is enrolled; that's expected.)
EOF
}

share_key() {
  [[ -f "$KEY.pub" ]] || die "no $KEY.pub - run '$0 build' first"
  ip -4 -o addr show | grep -q " $KALI_IP/" || die "$KALI_IP is not configured - run '$0 lab' first"
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  cp "$KEY.pub" "$dir/cvpsync.pub"     # serve a copy, never ~/.ssh itself
  cat <<EOF
Serving the PUBLIC key at http://$KALI_IP:8000/cvpsync.pub for up to 5 minutes.
On the gateway console run:   sudo cvp-enrol-key
Its fingerprint must match:   $(ssh-keygen -lf "$KEY.pub")
Press Ctrl+C here once it is installed, then test with:  sync-transcripts
EOF
  timeout 300 python3 -m http.server 8000 --bind "$KALI_IP" --directory "$dir" || true
}

case "${1:-}" in
  build)     build ;;
  lab)       lab ;;
  share-key) share_key ;;
  *)         echo "usage: $0 {build|lab|share-key}" >&2; exit 2 ;;
esac
