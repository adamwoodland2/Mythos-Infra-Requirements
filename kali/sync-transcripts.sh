#!/usr/bin/env bash
# sync-transcripts.sh  -  copy Claude Code session transcripts off the Kali VM
# to the gateway drop-box so they survive snapshot restores and satisfy the
# 30-day retention expectation. Run after every engagement (or from cron hourly).
#
# One-time setup:
#   ssh-keygen -t ed25519 -f ~/.ssh/cvpsync -N ''
#   -> paste ~/.ssh/cvpsync.pub into /var/cvp/.ssh/authorized_keys on the gateway
#      with the restricted command= prefix shown in install-gateway.sh
#
# Transcripts live under ~/.claude/projects/ as JSONL; ~/.claude/debug/ holds
# --debug logs. Both are synced. Credentials (~/.claude/.credentials.json) are
# deliberately NOT synced.

set -euo pipefail
SRC="$HOME/.claude"
# Path is relative to the rrsync root (/var/cvp/transcripts) on the gateway
DEST="cvpsync@10.0.3.1:$(hostname)/"
KEY="$HOME/.ssh/cvpsync"

rsync -az --delete-excluded \
  --include='projects/***' \
  --include='debug/***' \
  --include='history.jsonl' \
  --exclude='*' \
  -e "ssh -i $KEY -o StrictHostKeyChecking=accept-new" \
  "$SRC/" "$DEST"

echo "$(date -Is) transcripts synced to $DEST"
