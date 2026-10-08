#!/usr/bin/env bash
# sync-transcripts.sh  -  copy Claude Code session transcripts off the Kali VM
# to the gateway drop-box so they survive snapshot restores and satisfy the
# 30-day retention expectation. Run after every engagement (or from cron hourly).
#
# One-time setup (both done by kali/setup-kali.sh):
#   build      creates ~/.ssh/cvpsync and installs this script as ~/bin/sync-transcripts.sh
#   share-key  lets the gateway fetch the public key with `sudo cvp-enrol-key`
#
# Transcripts live under ~/.claude/projects/ as JSONL; ~/.claude/debug/ holds
# --debug logs. Both are synced. Credentials (~/.claude/.credentials.json) are
# deliberately NOT synced.
#
# No --delete: after a snapshot restore Kali no longer has earlier engagements'
# transcripts, and deleting them on the gateway would defeat the point. The
# gateway enforces this anyway (rrsync -no-del).

set -euo pipefail
SRC="$HOME/.claude"
# Path is relative to the rrsync root (/var/cvp/transcripts) on the gateway
DEST="cvpsync@10.0.3.1:$(hostname)/"
KEY="$HOME/.ssh/cvpsync"

rsync -az \
  --include='projects/***' \
  --include='debug/***' \
  --include='history.jsonl' \
  --exclude='*' \
  -e "ssh -i $KEY -o StrictHostKeyChecking=accept-new" \
  "$SRC/" "$DEST"

echo "$(date -Is) transcripts synced to $DEST"
