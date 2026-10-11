# Engagement guide

How to run an engagement once the lab is built ([CHECKLIST.md](CHECKLIST.md)). Do the steps in order. Each says what to do and what you should see; if you don't see it, stop and sort it out first.

`<name>` is the engagement name you choose: lower-case letters, digits and hyphens, e.g. `acme-web-2026-10`. Targets are `10.0.3.21-30` (`win-app-01` ... `win-app-10`). The repo is at `~/Mythos-Infra-Requirements` on the gateway and on Kali.

---

## 1. Start an engagement

1. **Restore the Kali gold snapshot** and the snapshots of the targets you'll use (VMware → VM → Snapshot → Snapshot Manager → gold → *Go To*).
   Expect: Kali boots to the desktop, and `cvp-scope status` shows `In-scope targets:` with nothing after it.
2. **Check the gateway is in run mode** (gateway console).
   ```
   sudo cvp-mode status
   ```
   Expect: `Active allow-list -> /etc/squid/allowlist-run.txt`.
3. **Create the engagement** on Kali, listing the target IPs.
   ```
   cvp-engagement new <name> 10.0.3.21 [10.0.3.22 ...]
   ```
   It asks for your name and the authorisation reference (ticket or engagement ID).
   Expect: `In-scope targets: 10.0.3.21 ...`, then `Created /home/<you>/engagements/<name>`.
4. **Check the scope file.**
   ```
   nano ~/engagements/<name>/CLAUDE.md
   ```
   Change each target's *Role* and *Permitted actions* if the defaults don't fit, and add anything Claude needs (test accounts, functions that are off limits). Don't add or remove rows by hand without step 5.
   Expect: the *In scope* table lists exactly the targets you mean.
5. **Only if you changed the table: re-apply the scope.**
   ```
   cvp-engagement scope <name>
   ```
   Expect: `In-scope targets:` followed by exactly the IPs in the table.
6. **Watch the gateway logs** in a window you can see (gateway console).
   ```
   sudo tail -f /var/log/squid/access.log /var/log/cvp-lab-nft.log
   ```
   Expect: the window stays open, showing new lines as they arrive.
7. **Start Claude Code** with a time limit you choose for this session (1-12 hours).
   ```
   cd ~/engagements/<name>
   cvp-run <hours>
   ```
   Expect: every line `ok` (a `warn` about the VMware user agent is fine), then `All checks passed. Starting Claude Code with a <hours>h limit.`
   If not: each `FAIL` line says what to fix.
8. **Give Claude the task** as the first message, for example:
   ```
   Test the hosts in the In scope table of CLAUDE.md, within the permitted actions listed
   there. Start with read-only enumeration. Write each confirmed finding to
   findings/<host>-<short-title>.md with the exact commands used, keep NOTES.md up to
   date, and ask me before anything destructive.
   ```
   Expect: Claude starts enumerating the in-scope host(s) only.

---

## 2. While it runs

1. **Watch the tool calls and the gateway window.**
   Expect: the Squid log shows only `TCP_TUNNEL/200 ... CONNECT api.anthropic.com:443` (and the occasional `platform.claude.com`); no `TCP_DENIED` and no `cvp-lab-...-drop` lines.
   If not: press Esc to interrupt Claude, read what it was doing, and decide whether to continue.
2. **Answer the permission prompts.** Commands using `ssh`, `scp`, `rsync`, `nc`, `ncat`, `socat`, `chisel` or `ligolo` always ask you.
   Expect: a prompt naming the command. Approve only if it targets an in-scope host.
3. **Check for blocked lab traffic** on Kali if anything looks odd.
   ```
   journalctl -k | grep cvp-scope-drop
   ```
   Expect: nothing. A line means something tried to reach a lab host that isn't in scope.
4. **On long runs, every hour or two,** triage the transcripts so far (gateway).
   ```
   sudo cvp-review 1
   ```
   Expect: `(none)` under integrity warnings. Read any `FLAGGED` session.
5. **Never point it at production,** especially OT/ICS, medical or energy systems. Replicas and test systems only.

---

## 3. Pause and resume

1. **To stop at once:** press Ctrl+C twice in Claude Code (or suspend the Kali VM in VMware).
   Expect: back at the shell; `cvp-run` syncs and prints `... synced to cvpsync@10.0.3.1:kali/`. If the time limit ran out instead, it first prints `Time limit reached - Claude Code was stopped.`
2. **To carry on later:**
   ```
   cd ~/engagements/<name>
   cvp-run <hours>
   ```
   then type `/resume` in Claude Code and pick the previous session.
   Expect: the earlier conversation is back.
   If `cvp-run` reports the scope doesn't match (Kali was rebooted): `cvp-engagement scope <name>`, then run `cvp-run` again.
3. **Don't restore the Kali snapshot mid-engagement.** It deletes `~/engagements/<name>` on Kali. Shut down or suspend instead. (The gateway keeps the copy synced so far, which §5 can still export.)

---

## 4. Finish the engagement

1. **Exit Claude Code:** type `/exit`.
   Expect: `... synced to cvpsync@10.0.3.1:kali/`.
2. **Close the engagement** on Kali.
   ```
   cvp-engagement close <name>
   ```
   Expect: `... transcripts and engagements synced to cvpsync@10.0.3.1:kali/`, then `In-scope targets:` with nothing after it, then `Closed <name>.`
3. **Review the transcripts** (gateway).
   ```
   sudo cvp-review
   ```
   Expect: `(none)` under integrity warnings. Read every `FLAGGED` session and every one in the random sample. For a second opinion, paste them into a Claude session outside the lab after §5.
4. **If anything was out of scope:** keep the logs, tell your Anthropic account team (and `security@anthropic.com` within 24/72 h if it meets CHECKLIST §1 step 7), and sign Claude Code out on Kali.

---

## 5. Get the engagement off the lab

Kali has no route, shared folder or clipboard to the host, so its files leave through the gateway: Kali syncs `~/engagements/` and the transcripts to the gateway every minute, and `cvp-export` packages them for a shared folder that only the gateway can see.

Once:

1. **Make a private folder on the Windows host,** e.g. `C:\CVP\exports`. Not in OneDrive and not inside a git repo.
   Expect: the folder exists.

Each time:

2. **Share the folder with the gateway VM only:** VMware → gateway VM → Settings → Options → Shared Folders → *Enabled until next power off* → Add → host path `C:\CVP\exports`, name `cvp-exports`, *Read-only* unticked. Never enable shared folders on Kali or the targets.
   Expect: on the gateway, `vmware-hgfsclient` prints `cvp-exports`.
3. **Export the engagement** (gateway).
   ```
   sudo cvp-export <name>
   ```
   Expect: `Copied to the host folder shared as 'cvp-exports'.`, then `Archive: /var/cvp/exports/<name>-<time>.tar.gz` and `SHA256:  <hash>`.
   If it says `Not copied to the host`: do step 2, then run step 3 again.
4. **Check the file arrived intact** (PowerShell on the host).
   ```
   Get-FileHash C:\CVP\exports\<name>-<time>.tar.gz
   ```
   Expect: the same hash as the `SHA256:` line.
5. **Unpack it.**
   ```
   tar -xzf C:\CVP\exports\<name>-<time>.tar.gz -C C:\CVP\exports
   ```
   Expect: a folder `<name>-<time>` containing `engagement`, `transcripts`, `gateway-logs`, `cvp-runs.log` and `SHA256SUMS`.
6. **Turn the share off:** gateway VM → Settings → Options → Shared Folders → *Disabled* (or leave it to lapse at the next power-off).
7. **Delete the gateway's copy of the archive** once it's safely stored.
   ```
   sudo rm /var/cvp/exports/<name>-<time>.tar.gz
   ```
   Expect: no output. The synced snapshots stay in `/var/cvp/archive` for 45 days.

What the archive holds:

| Folder / file | Contents |
|---|---|
| `engagement/` | Kali's `~/engagements/<name>`: `CLAUDE.md`, `findings/`, `NOTES.md`, anything else Claude wrote there |
| `transcripts/` | Claude Code transcripts (JSONL) of every session run in that folder |
| `cvp-runs.log` | when `cvp-run` started and stopped Claude Code, with the scope and time limit |
| `gateway-logs/` | Squid access log, gateway firewall drops, transcript integrity log, allow-list mode switches |
| `SHA256SUMS` | a hash of every file above |

---

## 6. Reset for the next engagement

1. **Restore the Kali gold snapshot** and the target snapshots.
   Expect: `cvp-engagement list` no longer shows `<name>`.
2. **Start again at §1.**

---

## Where things live

| Where | Path | What |
|---|---|---|
| Kali | `~/engagements/<name>/` | the engagement: `CLAUDE.md`, `findings/`, `NOTES.md` |
| Kali | `~/.claude/projects/-home-<you>-engagements-<name>/` | Claude Code transcripts for that engagement |
| Kali | `~/.claude/cvp-runs.log` | `cvp-run` start/stop record |
| Gateway | `/var/cvp/incoming/kali/` | latest copy from Kali (Kali can add and update, never read or delete) |
| Gateway | `/var/cvp/archive/<time>/kali/`, `latest` | root-only snapshots every 5 minutes, kept 45 days |
| Gateway | `/var/cvp/exports/` | archives made by `cvp-export` |
| Host | `C:\CVP\exports\` | exported archives |

## Commands

| Where | Command | Does |
|---|---|---|
| Kali | `cvp-engagement new <name> <IP>...` | make the engagement folder and `CLAUDE.md`, set the scope |
| Kali | `cvp-engagement scope <name>` | set the scope from that `CLAUDE.md` again |
| Kali | `cvp-engagement close <name>` | sync everything to the gateway, clear the scope |
| Kali | `cvp-engagement list` | engagements on this Kali and their in-scope IPs |
| Kali | `cvp-run <hours>` | pre-flight checks, then Claude Code with that time limit |
| Kali | `cvp-scope status` | the IPs Kali may connect to right now |
| Kali | `sync-transcripts` | sync now (it also runs every minute) |
| Gateway | `sudo cvp-mode status` | which allow-list is active, recent denials |
| Gateway | `sudo cvp-review [days]` | integrity warnings, flagged sessions, random sample |
| Gateway | `sudo cvp-export <name>` | package an engagement for the host |
