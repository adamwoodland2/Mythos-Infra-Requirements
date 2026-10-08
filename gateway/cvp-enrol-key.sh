#!/usr/bin/env bash
# /usr/local/sbin/cvp-enrol-key  -  install Kali's transcript-sync public key
#
#   on Kali:      bash kali/setup-kali.sh share-key
#   on gateway:   sudo cvp-enrol-key [URL]   (default http://10.0.3.11:8000/cvpsync.pub)
#
# The key is forced into rrsync write-only with deletes disabled, so Kali can
# add and update transcripts under /var/cvp/transcripts but never read or
# delete them. Re-running replaces the previous key.

set -euo pipefail
URL="${1:-http://10.0.3.11:8000/cvpsync.pub}"
AK=/var/cvp/.ssh/authorized_keys

key="$(curl -fsS --noproxy '*' -m 10 "$URL")"
# Exactly one ed25519 key on one line; anything else could smuggle in an
# unrestricted second authorized_keys line.
re='^ssh-ed25519 [A-Za-z0-9+/]+=* ?[A-Za-z0-9@._-]*$'
if ! [[ "$key" =~ $re ]] || ! ssh-keygen -lf - <<<"$key" >/dev/null 2>&1; then
  echo "refusing: $URL did not return a single ssh-ed25519 public key" >&2
  exit 1
fi

printf 'command="/usr/bin/rrsync -wo -no-del /var/cvp/transcripts",restrict %s\n' "$key" > "$AK"
chown cvpsync:cvpsync "$AK"
chmod 600 "$AK"
echo "Installed for cvpsync: $(ssh-keygen -lf "$AK")"
echo "Check this fingerprint matches the one setup-kali.sh printed on Kali."
