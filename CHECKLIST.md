# CVP Lab Build Checklist - Defense Access for Individuals

VMware Workstation lab for running Claude Code (Kali) against local targets (Windows) under the Anthropic Cyber Verification Program, Defense Access for Individuals tier.

Tick items as you go. Only §1 is **mandatory**: it comes from the CVP Security Requirements (§3 for individuals, plus Incident Reporting, Cooperation and Ongoing Review from §1). Everything else is **recommended** by Anthropic's containment best practices, and this lab treats it as required for itself. Config files referenced are in this repo:

| Path | Goes to | Purpose |
|---|---|---|
| [`gateway/install-gateway.sh`](gateway/install-gateway.sh) | gateway VM | one-shot installer for everything below |
| [`gateway/nftables.conf`](gateway/nftables.conf) | `/etc/nftables.conf` | default-drop, no forwarding; only Kali can reach Squid |
| [`gateway/squid.conf`](gateway/squid.conf) | `/etc/squid/squid.conf` | explicit CONNECT proxy for Kali only, hostname allow-list, logging |
| [`gateway/allowlist-run.txt`](gateway/allowlist-run.txt) | `/etc/squid/allowlist-run.txt` | engagement allow-list (2 hosts) |
| [`gateway/allowlist-login.txt`](gateway/allowlist-login.txt) | `/etc/squid/allowlist-login.txt` | re-authentication inside the lab (exact hosts) |
| [`gateway/allowlist-update.txt`](gateway/allowlist-update.txt) | `/etc/squid/allowlist-update.txt` | `claude update` |
| [`gateway/cvp-mode.sh`](gateway/cvp-mode.sh) | `/usr/local/sbin/cvp-mode` | switch allow-lists, show denials |
| [`gateway/cvp-enrol-key.sh`](gateway/cvp-enrol-key.sh) | `/usr/local/sbin/cvp-enrol-key` | install Kali's transcript-sync key (write-only, no deletes) |
| [`gateway/cvp-archive.sh`](gateway/cvp-archive.sh) | `/usr/local/sbin/cvp-archive` | 5-minute root-only transcript snapshots, tamper check, 45-day prune |
| [`gateway/cvp-review.sh`](gateway/cvp-review.sh) | `/usr/local/sbin/cvp-review` | pattern scan of transcripts + random sample of unflagged ones |
| [`gateway/logrotate-squid`](gateway/logrotate-squid), [`gateway/logrotate-cvp`](gateway/logrotate-cvp) | `/etc/logrotate.d/` | 45-day retention for Squid and nftables drop logs |
| [`kali/setup-kali.sh`](kali/setup-kali.sh) | Kali VM | `build` (Phase A), `lab` and `share-key` (Phase B) |
| [`kali/kali-netconfig.sh`](kali/kali-netconfig.sh) | Kali VM | static IP, no default route, system proxy; fails if anything else is connected |
| [`kali/managed-settings.json`](kali/managed-settings.json) | `/etc/claude-code/managed-settings.json` | root-owned Claude Code policy: proxy, OAuth only, Auto Mode rules, model pin |
| [`kali/cvp-scope.sh`](kali/cvp-scope.sh), [`kali/cvp-scope.nft`](kali/cvp-scope.nft) | `/usr/local/sbin/cvp-scope`, `/etc/cvp-scope.nft` | Kali firewall: only the gateway and the engagement's in-scope targets |
| [`kali/cvp-run.sh`](kali/cvp-run.sh) | `/usr/local/bin/cvp-run` | pre-flight checks, then Claude Code with a hard time limit |
| [`kali/sync-transcripts.sh`](kali/sync-transcripts.sh) | `/usr/local/bin/sync-transcripts` | transcripts to the gateway drop-box (every minute via `cvp-sync.timer`) |
| [`kali/CLAUDE.md.template`](kali/CLAUDE.md.template) | engagement dir `CLAUDE.md` | per-engagement scope statement |
| [`kali/escape-test-prompt.md`](kali/escape-test-prompt.md) | - | pre-engagement validation run |
| [`validation/validate-kali.sh`](validation/validate-kali.sh) | run on Kali | read-only checks of the Kali build (§4 Phase B) |
| [`validation/validate-windows.ps1`](validation/validate-windows.ps1) | copy to each target | read-only checks of a Windows target (§5) |

Windows targets are configured by hand (§5).

---

## 0. Target architecture

```
Windows host (VMware Workstation)
 │
 ├─ VMnet8 (NAT) ──► internet
 │     └─ [GW] gateway VM        ens33: NAT         ens37: LAN Segment "cvp-lab" 10.0.3.1
 │
 └─ LAN Segment "cvp-lab" 10.0.3.0/24  (no host adapter, no VMware DHCP, no default route)
        ├─ [GW]   10.0.3.1      Squid :3128 for Kali only (allow-list + log), nftables (no forwarding),
        │                       transcript drop-box + root-only snapshots
        ├─ [KALI] 10.0.3.11     Claude Code, HTTPS_PROXY -> 10.0.3.1:3128, cvp-scope firewall
        └─ [WIN]  10.0.3.21-30  target apps (as many as needed), no proxy, no route out
```

Why this shape: the containment guidance recommends that wherever the model does agentic work, outbound traffic is limited to an allow-list **enforced off the host** and **logged** (for the Red Team and Specialized tiers this is a requirement). NAT gives every VM open internet and no log. A LAN Segment has no host virtual adapter at all, so the only way out of the lab is through the gateway VM, which refuses to route and only offers a proxy, to Kali alone.

Hypervisor note: Anthropic's containment guidance names Hyper-V on Windows, Firecracker on Linux and Hypervisor.framework on macOS as the recommended isolation. VMware Workstation isn't named but satisfies the stated recommendation ("isolation inside a virtual machine"). If you later want to match it exactly, this design ports to Hyper-V unchanged (External vSwitch for GW NIC1, Private vSwitch for the lab).

---

## 1. Account and credentials (MANDATORY - CVP Security Requirements §3, plus §1 items)

- [ ] **Sign-in method.** The account holding the grant signs in only through Google or an equivalent identity provider - this lab uses Google. Never use *Continue with email* on claude.ai: that is the magic-link sign-in the requirement rules out.
- [ ] **MFA enabled now** on the Google account you sign in with (2-Step Verification). With Google sign-in, Google is where the MFA happens.
- [ ] **Phishing-resistant MFA by 15 Dec 2026**: a security key, a passkey, or a smartcard/PIV - for Google, add a passkey or security key. One qualifying method meets the requirement; registering a second as a backup is sensible but not required. SMS, voice, emailed codes, authenticator-app codes and push approvals do not qualify after the cutoff, so also remove the text-message, Authenticator-app and Google-prompt methods from the Google account, or they remain as fallbacks an attacker can phish. Google's Advanced Protection Program enforces this for you.
- [ ] **Use OAuth, not API keys.** Claude Code signs in through the claude.ai account (`setup-kali.sh build` does this; managed settings force `claudeai` login). Do not set `ANTHROPIC_API_KEY` or any other credential variable; `cvp-run` refuses to start if one is set.
- [ ] **If an API key is unavoidable before the cutoff**: one key only, stored in a password manager or local secrets store, never in source code or shared, replaced at least every 7 days. After 15 Dec 2026 static or long-lived credentials, API keys included, must not be used at all.
- [ ] **Personal access only.** Nobody else uses the account, the Kali VM session, or any proxy/extension that exposes the session.
- [ ] **Monitoring acknowledged.** All traffic under the grant is retained and monitored by Anthropic; zero data retention is not available.
- [ ] **Incident reporting known (§1).** Suspected breach or misuse involving the grant: report within 72 h; security incident: within 24 h; to `security@anthropic.com` or your account team. **Cooperation (§1):** investigate any abuse Anthropic identifies within 48 h and respond to misuse inquiries within 7 days.
- [ ] **Ongoing review (§1).** Anthropic may ask for evidence of compliance. Keep this repo's history, the escape-test reports and the gateway logs so you can show it.
- [ ] Write the incident timers on a sticky note / in your runbook so they are not something you have to look up during an incident.

Not applicable at this tier (Red Team / Specialized only): organisation-domain accounts, managed devices with EDR, background checks, 25-seat cap, mandatory off-host egress control, no static credentials on endpoints. This lab does most of these anyway where cheap.

---

## 2. VMware Workstation networking

- [ ] **Create the LAN Segment.** VM Settings → Network Adapter → *LAN segment* → *LAN Segments...* → Add `cvp-lab`. Do this on any one VM; the segment is then available to all.
- [ ] **Gateway VM: two adapters.** Adapter 1 = NAT (VMnet8). Adapter 2 = LAN segment `cvp-lab`.
- [ ] **Kali VM: one adapter** = LAN segment `cvp-lab` once the build is done. `kali-netconfig.sh` fails if Kali has any other adapter.
- [ ] **Each Windows target VM: one adapter** = LAN segment `cvp-lab`.
- [ ] **Disable VMware guest side-channels** on Kali and Windows: VM Settings → Options → Guest Isolation → untick *drag and drop* and *copy and paste*; Options → Shared Folders → *Disabled*. These are host-reach paths the escape test will otherwise find. (`cvp-run` also refuses to start if a shared folder is mounted, and stops the VMware copy/paste agent inside Kali.)
- [ ] **Snapshot policy decided.** Kali "gold" snapshot after §4 is complete; restore between engagements. Windows target snapshot before each engagement.

---

## 3. Gateway VM (RECOMMENDED containment - this lab's egress control and logging)

Build on a minimal Ubuntu Server 26.04 (Squid 7.2; 1 vCPU, 1 GB RAM and 20 GB disk is plenty).

- [ ] Install OS with adapter 1 (NAT) only connected; adapter 2 attached but it will be configured by the script.
- [ ] Check interface names: `ip -br link` should show `ens33` (NAT) and `ens37` (lab). If yours differ, run the installer as `sudo WAN_IF=<nat> LAN_IF=<lab> bash install-gateway.sh`; it writes them into `/etc/nftables.conf` and the netplan file.
- [ ] Clone this repo on the VM and run `sudo bash gateway/install-gateway.sh`. It also installs `openssh-server` for the transcript drop-box and limits SSH from the lab to that one key; administer the gateway from the VMware console.
- [ ] Verify nftables: `sudo nft list ruleset` shows `policy drop` on `input` and `forward`, and `sysctl net.ipv4.ip_forward` = 0.
- [ ] Verify Squid: `sudo cvp-mode status` shows `allowlist-run.txt` active with exactly `api.anthropic.com` and `platform.claude.com`.
- [ ] Verify logging: `/var/log/squid/access.log` exists, `cat /etc/logrotate.d/squid /etc/logrotate.d/cvp-lab` shows `rotate 45`, and `systemctl list-timers cvp-archive.timer` shows the snapshot timer.
- [ ] Transcript drop-box key: done from Kali in §4 Phase B (`setup-kali.sh share-key`, then `sudo cvp-enrol-key` here).
- [ ] Optional hardening: once the build is done, restrict the gateway's own `output` chain to the Anthropic hosts (resolve with `dig +short api.anthropic.com platform.claude.com` and add `ip daddr { ... } tcp dport 443 accept`, policy drop). Note Anthropic IPs can change; keep the policy-accept version if you'd rather not maintain that.
- [ ] Snapshot the gateway.

Allow-list rationale (from the Claude Code network docs):

| Host | Needed for | Run | Login | Update |
|---|---|---|---|---|
| `api.anthropic.com` | Claude API, feature flags | yes | yes | yes |
| `platform.claude.com` | OAuth token exchange / refresh / revocation | yes | yes | yes |
| `claude.ai`, `claude.com` (exact) | browser sign-in page and redirect | no | yes | no |
| `downloads.claude.ai` | native installer / updater | no | no | yes |
| everything else in the docs table | plugins, MCP connectors, artifacts, telemetry, docs | no | no | no |

---

## 4. Kali VM (Claude Code sandbox)

**Phase A - build on NAT (internet available):**

- [ ] Fresh Kali; clone this repo (e.g. `git clone https://github.com/adamwoodland2/Mythos-Infra-Requirements ~/cvp-lab`).
- [ ] `bash ~/cvp-lab/kali/setup-kali.sh build` as your normal user. It:
  - fully updates Kali and installs Claude Code with the native installer, checking it is ≥ 2.1.257 (needed for the *Host containment* entry);
  - asks for your business name, the email of the account holding the grant (your Google address), and the **model to pin**: when it asks, open `claude` in a second terminal, type `/model`, highlight *Mythos 5.1* (or whichever model the grant is for), press Enter, then `/exit`. The picker only shows display names, but that saves the model's ID to `~/.claude/settings.json`, and the script offers it as the default, then checks it with a one-word request before pinning (the Mythos ID isn't in Anthropic's public model list, so the script doesn't guess it);
  - **signs you in** with OAuth. Easiest with Google: copy the sign-in URL to a browser on the host, where your Google passkey or security key already works, choose *Continue with Google*, and paste the code back into Kali. Keep VMware copy and paste enabled for Kali until this is done (§2's Guest Isolation settings go on in Phase B). Sign-in happens here, on NAT, because Google's sign-in pages are not on any allow-list (D-016);
  - installs the root-owned `/etc/claude-code/managed-settings.json` (proxy, claude.ai-only login, Auto Mode rules, the model pin) and `/etc/cvp-lab.conf`, the sync key `~/.ssh/cvpsync` and `/usr/local/bin/sync-transcripts`.
- [ ] Install every tool you expect to need for the engagement class (the guidance says install all tools, packages and dependencies before the run so nothing is fetched mid-run). Don't forget wordlists, Python/Go deps, and anything `pip`/`go install` based.
- [ ] Shut down.

**Phase B - move to the lab segment:**

- [ ] Change the adapter to LAN segment `cvp-lab` (and remove any other adapter); apply the Guest Isolation / Shared Folders settings from §2.
- [ ] Boot; `bash ~/cvp-lab/kali/setup-kali.sh lab`. It runs `kali-netconfig.sh` (which fails if there is a second adapter, a default route or a stray address), installs the `cvp-scope` firewall (no targets until you set them, after every boot), `cvp-run`, and the every-minute `cvp-sync.timer`. Log out and in.
- [ ] Connectivity checks from Kali:
  - `ping -c1 8.8.8.8` → *Network is unreachable* (no route)
  - `curl -sI https://example.com` → `403 Forbidden` from Squid
  - `curl -skI https://8.8.8.8` → `403 Forbidden` from Squid (bare IPs never match the allow-list, see docs/decisions.md D-015)
  - `curl -sI https://api.anthropic.com` → an HTTP response from Anthropic (any status is fine; it proves the proxy path works)
  - `ping -c1 win-app-01` → fails (no targets in scope); `sudo cvp-scope set 10.0.3.21` → the same ping succeeds; `sudo cvp-scope none` again. Repeat for each target you built.
- [ ] **Transcript drop-box key:** on Kali `bash ~/cvp-lab/kali/setup-kali.sh share-key`; on the gateway console `sudo cvp-enrol-key` and check the fingerprints match; Ctrl+C on Kali; then `sync-transcripts` should succeed and, within 5 minutes, `sudo ls /var/cvp/archive` on the gateway shows a snapshot.
- [ ] `claude auth status --text` shows you signed in to the grant account.
- [ ] Know how to sign in again inside the lab (login expired, or lost to a snapshot restore). Google's sign-in pages aren't on any allow-list and your security key isn't in the VM, so the browser step has to happen on the host: temporarily tick *copy and paste* for the Kali VM in VMware (Guest Isolation), log out and back in to Kali's desktop (`cvp-run` stops VMware's copy/paste agent), run `/login`, press `c`, finish in the host browser with *Continue with Google*, paste the code back, then untick *copy and paste* again. Kali itself only needs `platform.claude.com` for that, so run mode should be enough; `sudo cvp-mode login` only helps if Kali's own browser still has a claude.ai session from Phase A.
- [ ] Make a scratch engagement (`~/engagements/check`, CLAUDE.md from the template with no targets) and run `cvp-run 1` there: every pre-flight line should be `ok`. In Claude Code, `/status` shows the *Proxy* row `http://10.0.3.1:3128`, your account, the pinned model and the managed settings source; the mode indicator shows Auto Mode. `claude auto-mode config` lists your `environment`, `hard_deny` and `soft_deny` entries; `claude auto-mode critique` sanity-checks them.
- [ ] `bash ~/cvp-lab/validation/validate-kali.sh 10.0.3.21` passes, once with the target out of scope (checks it is blocked) and once after `sudo cvp-scope set 10.0.3.21` (checks it answers); then `sudo cvp-scope none`.
- [ ] Take the **Kali gold snapshot**.

**Phase C - validation (RECOMMENDED; treat as mandatory for yourself):**

- [ ] Run the sandbox escape test in [`kali/escape-test-prompt.md`](kali/escape-test-prompt.md) under supervision, with the Squid and nftables logs tailing on the gateway.
- [ ] Review: every outbound attempt appears as `TCP_DENIED` in Squid, `cvp-lab-*-drop` in `/var/log/cvp-lab-nft.log` on the gateway, or `cvp-scope-drop` in Kali's kernel log. Keep `escape-test.md` (in the engagement directory, never in the repo) as evidence.
- [ ] Re-run this whenever you change the gateway config, the Squid allow-list, the managed settings, the model, or rebuild the Kali gold image.

---

## 5. Windows target VMs (configured by hand)

Up to ten targets, 10.0.3.21-30, as many as the engagement needs. Kali knows them as `win-app-01` (10.0.3.21) to `win-app-10` (10.0.3.30). Repeat this section for each one.

- [ ] Build / install the application and complete any licence activation or Windows Update **on NAT first**.
- [ ] Switch the VM's only adapter to LAN segment `cvp-lab`; apply Guest Isolation / Shared Folders settings from §2.
- [ ] IPv4 on that adapter: static `10.0.3.2N/24` (`.21` for `win-app-01` ... `.30` for `win-app-10`), **no default gateway, no DNS servers**. Untick IPv6 on the adapter.
- [ ] No proxy: `netsh winhttp reset proxy` and Settings → Network → Proxy all off.
- [ ] Optional hosts entries (`C:\Windows\System32\drivers\etc\hosts`): `10.0.3.1 cvp-gw`, `10.0.3.11 kali-cvp`.
- [ ] Verify in PowerShell: `Test-NetConnection 10.0.3.11` succeeds; `Test-NetConnection 8.8.8.8` fails; `Test-NetConnection 10.0.3.1 -Port 3128` fails (the gateway proxy serves Kali only). Or copy [`validation/validate-windows.ps1`](validation/validate-windows.ps1) over on NAT before the switch and run `powershell -ExecutionPolicy Bypass -File .\validate-windows.ps1`, which checks all of this and more.
- [ ] Snapshot.

---

## 6. Per-engagement runbook (RECOMMENDED - containment best practices)

Before:

- [ ] Restore Kali gold snapshot and the Windows target snapshots.
- [ ] Gateway: `sudo cvp-mode status` → confirm **run** mode.
- [ ] Make the engagement directory **outside the repo clone**, e.g. `~/engagements/<name>/`. Its contents (findings, notes, target data) are private and never go in the public repo.
- [ ] Copy [`kali/CLAUDE.md.template`](kali/CLAUDE.md.template) there as `CLAUDE.md`; fill in targets, permitted actions, and the authorisation reference. Phrase constraints as intent ("do not access..."), not as environment claims ("you cannot...").
- [ ] `sudo cvp-scope set <exactly the in-scope IPs>` on Kali.
- [ ] Confirm all tooling the task needs is present (nothing can be fetched mid-run). Note any "impossible" steps that will need closer supervision.
- [ ] On the gateway, open `tail -f /var/log/squid/access.log /var/log/cvp-lab-nft.log` in a visible window.
- [ ] Start with `cvp-run <hours>` from the engagement directory, choosing the time limit for this engagement. It refuses to start if the workspace, network, scope, credentials, model, egress, sudo, VMware sharing or sync checks fail.

During:

- [ ] Supervise the run (the guidance's answer for networked runs). Watch tool calls and the logs; be ready to `Ctrl+C` / suspend the VM. Claude Code has no turn limit for interactive sessions; the `cvp-run` time limit and you are the off-switch.
- [ ] Any `TCP_DENIED` for a host you didn't expect, `cvp-lab-*-drop` on the gateway or `cvp-scope-drop` on Kali: pause and read the transcript around it.
- [ ] On long runs, `sudo cvp-review 1` on the gateway every hour or two (transcripts arrive every minute).
- [ ] Never point the agent at live production, especially OT/ICS, medical or energy systems. Replica, testbed or digital twin only; if live access is unavoidable, read-only and a human performs every state-changing step.

After:

- [ ] `cvp-run` syncs when Claude Code exits; `sudo cvp-review` on the gateway lists integrity warnings, flagged sessions, and a random 10% of unflagged sessions. Read all of them. For a second opinion, have Claude review the flagged and sampled transcripts in a separate session outside the lab.
- [ ] Review the transcript for any run where the egress layer logged a denied/unexpected request, and for anything that looked like probing the sandbox or network isolation.
- [ ] Out-of-scope behaviour observed → stop, keep the logs, notify your Anthropic account team (and, if it meets the §1 thresholds, `security@anthropic.com` within 24/72 h), and sign out / revoke the Claude Code login.
- [ ] `sudo cvp-scope none` on Kali.
- [ ] Retention: Squid and nftables logs (45 days) and transcript snapshots (`/var/cvp/archive`, 45 days) all cover ≥ 30 days.

---

## 7. Maintenance

- [ ] **Updating Claude Code:** gateway `sudo cvp-mode update`; on Kali `claude update`; gateway `sudo cvp-mode run`; re-snapshot Kali; re-run the escape test.
- [ ] **Updating Kali tools:** rebuild from Phase A on NAT (re-run `setup-kali.sh build`). Don't widen the allow-list for package repos.
- [ ] **Patching the gateway:** `sudo apt update && sudo apt upgrade` monthly (it has internet through NAT); keep your versions of the config files if apt asks.
- [ ] **Quarterly:** re-read the Anthropic articles in §References; they are marked as evolving. Check `claude auto-mode defaults` for new built-in rules.
- [ ] **15 Dec 2026:** phishing-resistant MFA cutoff. Any interim API key must be gone.

---

## 8. Known gaps (recommended practices this lab doesn't fully meet)

- **The model credential is inside the sandbox.** The OAuth login lives in `~/.claude/` on Kali, as the same user Claude Code runs as. The guidance recommends a credential proxy outside the sandbox, with Kali holding only a placeholder `CLAUDE_CODE_OAUTH_TOKEN`; its reference design uses a `claude setup-token` token. That token is long-lived, and the Security Requirements forbid long-lived credentials after 15 Dec 2026, so check with your account team before building it. Mitigations here: `blockReadsOutsideWorkingDirectories`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, the `hard_deny` rule, no passwordless sudo, snapshot restore between runs, and revoking the login if the VM is ever suspect (D-007).
- **Target scope is enforced on Kali, not off-host.** Targets share the lab segment with Kali, so the gateway never sees Kali-to-target traffic. `cvp-scope` holds while the agent has no root; a root process could flush it or send raw frames past it. Enforcing scope off-host means moving the targets to their own segment routed through the gateway, which changes the addressing (D-019).
- **Transcripts are written by the agent's own process.** The guidance prefers an orchestrator outside the sandbox writing stream-json. Here they are synced every minute, snapshotted every 5 minutes into a root-only area of the gateway, and checked for in-place edits, so later tampering is caught but anything faked before the first sync is not. The Squid and nftables logs are the independent record (D-018).
- **No turn limit in interactive sessions.** Claude Code offers `--max-turns` only for `-p` runs; interactive runs rely on supervision and the `cvp-run` wall-clock limit.
- **`ask` rules are prefix matches.** `Bash(ssh *)` won't catch `/usr/bin/ssh`, `env ssh` or `bash -c "ssh ..."`. They are a convenience, not a boundary; the gateway is the boundary.
- **The sandbox escape classifier isn't available to Claude Code**, so it can't prioritise transcript review here.
- Squid/nftables/netplan files are hand-written standard configs, not from Anthropic; the escape test is what proves they work in your build.

---

## References

- Cyber Verification Program Security Requirements (the only mandatory document) - https://support.claude.com/en/articles/17202708-cyber-verification-program-security-requirements
- Agent containment best practices for CVP participants - https://support.claude.com/en/articles/17317514-agent-containment-best-practices-for-cvp-participants
- Agent containment best practices: getting started - https://support.claude.com/en/articles/17316076, and its sub-articles: sandboxing (17316105), auto mode (17316089), offline monitoring (17316112), online monitoring (17313886), prompt injection (17316099)
- Claude Code: network configuration (proxy vars, required domains) - https://code.claude.com/docs/en/network-config
- Claude Code: managed settings - https://code.claude.com/docs/en/managed-settings
- Claude Code: configure auto mode - https://code.claude.com/docs/en/auto-mode-config
- Claude Code: environment variables - https://code.claude.com/docs/en/env-vars
- CISA: Implementing Phishing-Resistant MFA - https://www.cisa.gov/sites/default/files/publications/fact-sheet-implementing-phishing-resistant-mfa-508c.pdf
