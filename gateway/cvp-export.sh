#!/usr/bin/env bash
# /usr/local/sbin/cvp-export  -  package one engagement for the Windows host
#
#   sudo cvp-export <name>
#
# Takes a fresh snapshot (cvp-archive), then packs from it:
#   engagement/     Kali's ~/engagements/<name> (CLAUDE.md, findings/, notes, reports)
#   transcripts/    Claude Code transcripts of the sessions run in that directory
#   cvp-runs.log    cvp-run's start/stop record
#   gateway-logs/   Squid access log, nftables drop log, transcript and mode logs
#   SHA256SUMS
# into /var/cvp/exports/<name>-<UTC time>.tar.gz, and copies it to the Windows
# host if this VM has a VMware shared folder named cvp-exports (GUIDE.md §4).
# The archive is engagement material: keep it private and out of the repo.

set -euo pipefail
SHARE=cvp-exports
MNT=/mnt/cvp-exports
OUT=/var/cvp/exports

die() { echo "$*" >&2; exit 1; }

name="${1:-}"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || die "usage: sudo cvp-export <engagement name>"
[[ $EUID -eq 0 ]] || die "run with sudo"

/usr/local/sbin/cvp-archive
[[ -L /var/cvp/archive/latest ]] || die "no snapshots yet - has Kali synced? (sync-transcripts on Kali)"
latest="$(readlink -f /var/cvp/archive/latest)"

eng="$(find "$latest" -mindepth 3 -maxdepth 3 -type d -path "*/engagements/$name" -print -quit)"
[[ -n "$eng" ]] || die "no engagement '$name' in the latest snapshot - run 'cvp-engagement close $name' on Kali first"
host_dir="${eng%/engagements/*}"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
pkg="$name-$ts"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$pkg/transcripts" "$work/$pkg/gateway-logs"

cp -a "$eng" "$work/$pkg/engagement"
# Claude Code names a project's transcript folder after its path, '/' -> '-'
shopt -s nullglob
for d in "$host_dir"/projects/*-engagements-"$name"; do
  cp -a "$d/." "$work/$pkg/transcripts/"
done
if [[ -f "$host_dir/cvp-runs.log" ]]; then cp -a "$host_dir/cvp-runs.log" "$work/$pkg/"; fi
for f in /var/log/squid/access.log /var/log/cvp-lab-nft.log /var/log/cvp-transcripts.log /var/log/cvp-mode.log; do
  if [[ -f "$f" ]]; then cp -a "$f" "$work/$pkg/gateway-logs/"; fi
done
(cd "$work/$pkg" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS)

mkdir -p "$OUT"
chmod 700 "$OUT"
tar -C "$work" -czf "$OUT/$pkg.tar.gz" "$pkg"
sum="$(sha256sum "$OUT/$pkg.tar.gz" | cut -d' ' -f1)"

if command -v vmware-hgfsclient >/dev/null 2>&1 && vmware-hgfsclient 2>/dev/null | grep -qx "$SHARE"; then
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || vmhgfs-fuse ".host:/$SHARE" "$MNT"
  cp "$OUT/$pkg.tar.gz" "$MNT/"
  sync
  umount "$MNT"
  echo "Copied to the host folder shared as '$SHARE'."
else
  echo "Not copied to the host: this VM has no VMware shared folder named '$SHARE' (GUIDE.md §4)."
  echo "Share the folder, then run 'sudo cvp-export $name' again."
fi
echo "Archive: $OUT/$pkg.tar.gz"
echo "SHA256:  $sum"
