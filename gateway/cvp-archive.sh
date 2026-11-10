#!/usr/bin/env bash
# /usr/local/sbin/cvp-archive  -  snapshot the transcript drop-box (run every
# 5 minutes by cvp-archive.timer, or by hand)
#
# Kali syncs into /var/cvp/incoming through `rrsync -wo -no-del`: it can add and
# overwrite files there, but not delete them or read anything back. Whenever
# incoming has changed, this copies it into a new snapshot under
# /var/cvp/archive (mode 700, root only; unchanged files are hard links to the
# previous snapshot), so nothing on Kali can alter a version once snapshotted.
# Snapshots hold regular files and folders only: symlinks, devices and FIFOs
# that Kali uploads are left out, so nothing run here as root (this script,
# cvp-review, cvp-export) can be led outside the archive (D-025).
#
# Below 20% free disk it logs LOW-SPACE and skips the snapshot, leaving room
# for Squid's and nftables' logs on the same disk.
#
# Transcripts are JSONL and only ever grow. A transcript that no longer starts
# with its previous contents is logged as NON-APPEND, and any file that
# disappears as MISSING - treat either as possible tampering (cvp-review).
# Engagement folders (findings, notes) are snapshotted too but are expected to
# change, so they aren't append-checked.
# Snapshots older than 45 days are pruned; the newest one always stays, and it
# holds every file ever synced because incoming never loses files.

set -euo pipefail
IN=/var/cvp/incoming
AR=/var/cvp/archive
LOG=/var/log/cvp-transcripts.log
KEEP_DAYS=45
MAX_USED_PCT=80

log() { echo "$(date -Is) $*" >> "$LOG"; logger -t cvp-archive -- "$*" || true; }

mkdir -p "$AR"
chmod 700 "$AR"
[[ -n "$(ls -A "$IN" 2>/dev/null)" ]] || exit 0

prev=""
if [[ -L "$AR/latest" ]]; then prev="$(readlink -f "$AR/latest")"; fi
# Nothing changed since the last snapshot? (ctime, because rsync keeps Kali's mtimes)
if [[ -n "$prev" && -e "$prev/.snapshot" ]] &&
   [[ -z "$(find "$IN" -cnewer "$prev/.snapshot" -print -quit)" ]]; then
  exit 0
fi

used="$(df --output=pcent "$AR" | tail -n 1 | tr -dc 0-9)"
if (( ${used:-0} > MAX_USED_PCT )); then
  log "LOW-SPACE $AR's disk is ${used}% full - snapshot skipped; free space on the gateway"
  exit 0
fi

ts="$(date -u +%Y%m%dT%H%M%SZ)"
new="$AR/$ts"
started="$(mktemp)"     # anything changed after this is caught by the next run
trap 'rm -f "$started"' EXIT
# .name.XXXXXX are rsync's in-flight temp files from a sync still running;
# /.snapshot is this script's marker, so Kali can't supply it
rsync -a --no-links --no-D --exclude='.*.??????' --exclude='/.snapshot' \
  ${prev:+--link-dest="$prev"} "$IN/" "$new/"

if [[ -n "$prev" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$new"/}"
    case "$rel" in              # only transcripts must only grow; findings and notes get edited
      */projects/*.jsonl|*/history.jsonl|*/cvp-runs.log) ;;
      *) continue ;;
    esac
    old="$prev/$rel"
    [[ -f "$old" ]] || continue
    [[ "$f" -ef "$old" ]] && continue                     # unchanged, hard-linked
    if ! cmp -s -n "$(stat -c %s "$old")" "$old" "$f"; then
      log "NON-APPEND $rel changed in place in snapshot $ts (possible tampering)"
    fi
  done < <(find "$new" -type f -print0)
  while IFS= read -r -d '' f; do
    rel="${f#"$prev"/}"
    [[ "$rel" == .snapshot ]] || [[ -e "$new/$rel" ]] || log "MISSING $rel absent from snapshot $ts"
  done < <(find "$prev" -type f -print0)
fi

touch -r "$started" "$new/.snapshot"
ln -sfn "$new" "$AR/latest"
log "snapshot $ts"

find "$AR" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -mtime +"$KEEP_DAYS" \
  ! -path "$new" -exec rm -rf {} +
