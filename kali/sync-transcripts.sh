#!/usr/bin/env bash
# /usr/local/bin/sync-transcripts  -  copy Claude Code session transcripts off
# the Kali VM to the gateway drop-box so they survive crashes and snapshot
# restores. cvp-sync.timer runs it every minute (as your user, from a root-owned
# unit), cvp-run runs it when a session ends, and you can run it by hand.
#
# One-time setup (done by kali/setup-kali.sh):
#   build      creates ~/.ssh/cvpsync and installs this script
#   lab        installs cvp-sync.timer
#   share-key  lets the gateway fetch the public key with `sudo cvp-enrol-key`
#
# Synced: ~/.claude/projects/ (session transcripts, JSONL), ~/.claude/debug/,
# history.jsonl and cvp-runs.log (cvp-run's start/stop record). Credentials
# (~/.claude/.credentials.json) are deliberately NOT synced.
#
# No --delete: after a snapshot restore Kali no longer has earlier engagements'
# transcripts, and deleting them on the gateway would defeat the point. The
# gateway refuses deletes anyway (rrsync -no-del), and snapshots what arrives
# into read-only copies (cvp-archive).

set -euo pipefail
SRC="$HOME/.claude"
# Path is relative to the rrsync root (/var/cvp/incoming) on the gateway
DEST="cvpsync@10.0.3.1:$(hostname)/"
KEY="$HOME/.ssh/cvpsync"

rsync -az \
  --include='projects/***' \
  --include='debug/***' \
  --include='history.jsonl' \
  --include='cvp-runs.log' \
  --exclude='*' \
  -e "ssh -i $KEY -o StrictHostKeyChecking=accept-new" \
  "$SRC/" "$DEST"

echo "$(date -Is) transcripts synced to $DEST"
