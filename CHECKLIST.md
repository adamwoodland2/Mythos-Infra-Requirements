# CVP Lab Build Checklist - Defense Access for Individuals

VMware Workstation lab for running Claude Code (Kali) against local targets (Windows) under the Anthropic Cyber Verification Program, Defense Access for Individuals tier.

Tick items as you go. Each section says whether it is **mandatory** (from the CVP Security Requirements) or **recommended** (from the Agent Containment Best Practices). Config files referenced are in this repo:

| Path | Goes to | Purpose |
|---|---|---|
| [`gateway/install-gateway.sh`](gateway/install-gateway.sh) | gateway VM | one-shot installer for everything below |
| [`gateway/nftables.conf`](gateway/nftables.conf) | `/etc/nftables.conf` | default-drop, no forwarding; lab can only reach Squid |
| [`gateway/squid.conf`](gateway/squid.conf) | `/etc/squid/squid.conf` | explicit CONNECT proxy, hostname allow-list, logging |
| [`gateway/allowlist-run.txt`](gateway/allowlist-run.txt) | `/etc/squid/allowlist-run.txt` | engagement allow-list (2 hosts) |
| [`gateway/allowlist-login.txt`](gateway/allowlist-login.txt) | `/etc/squid/allowlist-login.txt` | OAuth sign-in / update allow-list |
| [`gateway/cvp-mode.sh`](gateway/cvp-mode.sh) | `/usr/local/sbin/cvp-mode` | switch allow-lists, show denials |
| [`gateway/cvp-enrol-key.sh`](gateway/cvp-enrol-key.sh) | `/usr/local/sbin/cvp-enrol-key` | install Kali's transcript-sync key, append-only |
| [`gateway/logrotate-squid`](gateway/logrotate-squid) | `/etc/logrotate.d/squid` | 45-day log retention |
| [`kali/setup-kali.sh`](kali/setup-kali.sh) | Kali VM | Phase A build (Claude Code, sign-in, settings, sync key) and key hand-over |
| [`kali/kali-netconfig.sh`](kali/kali-netconfig.sh) | Kali VM | static IP, no default route, system proxy |
| [`kali/settings.json`](kali/settings.json) | `~/.claude/settings.json` | proxy env, Auto Mode, deny/ask rules |
| [`kali/CLAUDE.md.template`](kali/CLAUDE.md.template) | engagement dir `CLAUDE.md` | per-engagement scope statement |
| [`kali/sync-transcripts.sh`](kali/sync-transcripts.sh) | Kali VM | copy transcripts to gateway drop-box |
| [`kali/escape-test-prompt.md`](kali/escape-test-prompt.md) | - | pre-engagement validation run |
| [`windows/netconfig.ps1`](windows/netconfig.ps1) | Windows target VM | static IP, no gateway, no proxy |

---

## 0. Target architecture

```
Windows host (VMware Workstation)
 │
 ├─ VMnet8 (NAT) ──► internet
 │     └─ [GW] gateway VM        ens33: NAT         ens37: LAN Segment "cvp-lab" 10.0.3.1
 │
 └─ LAN Segment "cvp-lab" 10.0.3.0/24  (no host adapter, no VMware DHCP, no default route)
        ├─ [GW]   10.0.3.1      Squid :3128 (allow-list + log) + nftables (no forwarding)
        ├─ [KALI] 10.0.3.11     Claude Code, HTTPS_PROXY -> 10.0.3.1:3128
        └─ [WIN]  10.0.3.21-30  target apps (as many as needed), no proxy, no route out
```

Why this shape: the requirement is that wherever the model does agentic work, outbound traffic is limited to an allow-list **enforced off the host** and **logged**. NAT gives every VM open internet and no log. A LAN Segment has no host virtual adapter at all, so the only way out of the lab is through the gateway VM, which refuses to route and only offers a proxy.

Hypervisor note: Anthropic's containment guidance names Hyper-V on Windows, Firecracker on Linux and Hypervisor.framework on macOS as the recommended isolation. VMware Workstation isn't named but satisfies the stated requirement ("isolation inside a virtual machine"). If you later want to match the recommendation exactly, this design ports to Hyper-V unchanged (External vSwitch for GW NIC1, Private vSwitch for the lab).

---

## 1. Account and credentials (MANDATORY - CVP Security Requirements §3)

- [ ] **Sign-in method.** The account holding the grant signs in only through Google or an equivalent identity provider. No email/password, no magic-link.
- [ ] **MFA enabled now** on that Google/IdP account.
- [ ] **Phishing-resistant MFA by 15 Dec 2026**: register at least two FIDO2 security keys or passkeys on the account (one as backup). SMS, voice, emailed codes, authenticator-app TOTP and push approvals do not qualify after the cutoff. Disable email magic-link sign-in.
- [ ] **Use OAuth, not API keys.** Sign Claude Code in with `claude` then `/login` (claude.ai account). Do not set `ANTHROPIC_API_KEY` anywhere.
- [ ] **If an API key is unavoidable before the cutoff**: one key only, stored in a password manager or local secrets store, never in source code or shared, rotated at least every 7 days. Put a 7-day rotation reminder in your calendar. After 15 Dec 2026 API keys are not permitted at all.
- [ ] **Personal access only.** Nobody else uses the account, the Kali VM session, or any proxy/extension that exposes the session.
- [ ] **Monitoring acknowledged.** All traffic under the grant is retained and monitored by Anthropic; zero-data-retention is not available at this tier.
- [ ] **Incident reporting known.** Suspected breach or misuse involving the grant: report within 72 h; security incident: within 24 h; to `security@anthropic.com` or your account team. Investigate any abuse Anthropic flags within 48 h; respond to misuse inquiries within 7 days.
- [ ] Write the above two bullets on a sticky note / in your runbook so the timers are not something you have to look up during an incident.

Not applicable at this tier (Red Team / Specialized only): organisation-domain accounts, managed devices with EDR, background checks, 25-seat cap, formal gateway rules, documented incident procedure. Worth doing anyway where cheap, but not required.

---

## 2. VMware Workstation networking

- [ ] **Create the LAN Segment.** VM Settings → Network Adapter → *LAN segment* → *LAN Segments...* → Add `cvp-lab`. Do this on any one VM; the segment is then available to all.
- [ ] **Gateway VM: two adapters.** Adapter 1 = NAT (VMnet8). Adapter 2 = LAN segment `cvp-lab`.
- [ ] **Kali VM: one adapter** = LAN segment `cvp-lab`. Remove or disconnect any NAT/bridged adapter once the build is done.
- [ ] **Each Windows target VM: one adapter** = LAN segment `cvp-lab`.
- [ ] **Disable VMware guest side-channels** on Kali and Windows: VM Settings → Options → Guest Isolation → untick *drag and drop* and *copy and paste*; Options → Shared Folders → *Disabled*. These are host-reach paths the escape test will otherwise find.
- [ ] **Snapshot policy decided.** Kali "gold" snapshot after §4 is complete; restore between engagements. Windows target snapshot before each engagement.

---

## 3. Gateway VM (MANDATORY egress control + logging)

Build on a minimal Ubuntu Server 26.04 (Squid 7.2; 1 vCPU, 1 GB RAM is plenty).

- [ ] Install OS with adapter 1 (NAT) only connected; adapter 2 attached but it will be configured by the script.
- [ ] Check interface names: `ip -br link` should show `ens33` (NAT) and `ens37` (lab). If yours differ, run the installer as `sudo WAN_IF=<nat> LAN_IF=<lab> bash install-gateway.sh`; it writes them into `/etc/nftables.conf` and the netplan file.
- [ ] Clone this repo on the VM and run `sudo bash gateway/install-gateway.sh`. It also installs `openssh-server` for the transcript drop-box and limits SSH from the lab to that one key; administer the gateway from the VMware console.
- [ ] Verify nftables: `sudo nft list ruleset` shows `policy drop` on `input` and `forward`, and `sysctl net.ipv4.ip_forward` = 0.
- [ ] Verify Squid: `sudo cvp-mode status` shows `allowlist-run.txt` active with exactly `api.anthropic.com` and `platform.claude.com`.
- [ ] Verify logging: `sudo tail /var/log/squid/access.log` exists and `cat /etc/logrotate.d/squid` shows `rotate 45`.
- [ ] Transcript drop-box key: done from Kali in §4 Phase B (`setup-kali.sh share-key`, then `sudo cvp-enrol-key` here).
- [ ] Optional hardening: once the build is done, restrict the gateway's own `output` chain to the Anthropic hosts (resolve with `dig +short api.anthropic.com platform.claude.com` and add `ip daddr { ... } tcp dport 443 accept`, policy drop). Note Anthropic IPs can change; keep the policy-accept version if you'd rather not maintain that.
- [ ] Snapshot the gateway.

Allow-list rationale (from the Claude Code network docs):

| Host | Needed for | Run mode | Login mode |
|---|---|---|---|
| `api.anthropic.com` | Claude API, feature flags | yes | yes |
| `platform.claude.com` | OAuth token exchange / refresh / revocation | yes | yes |
| `claude.ai`, `claude.com` | browser sign-in page and redirect | no | yes |
| `downloads.claude.ai` | native installer / updater | no | only while updating |
| everything else in the docs table | plugins, MCP connectors, artifacts, telemetry, docs | no | no |

---

## 4. Kali VM (Claude Code sandbox)

**Phase A - build on NAT (internet available):**

- [ ] Fresh Kali; clone this repo (e.g. `git clone https://github.com/adamwoodland2/Mythos-Infra-Requirements ~/cvp-lab`).
- [ ] `bash ~/cvp-lab/kali/setup-kali.sh build` as your normal user. It fully updates Kali, installs Claude Code with the native installer and checks it is ≥ 2.1.257 (needed for the *Host containment* entry), **signs you in** (OAuth - finish the browser step in Kali's browser or on the host and paste the code back), then installs `~/.claude/settings.json` with your business name, the sync key `~/.ssh/cvpsync` and `~/bin/sync-transcripts.sh`. Sign-in happens here, on NAT, because the Google sign-in pages are not on any allow-list (D-016).
- [ ] Install every tool you expect to need for the engagement class (the guidance says install all tools, packages and dependencies before the run so nothing is fetched mid-run). Don't forget wordlists, Python/Go deps, and anything `pip`/`go install` based.
- [ ] Shut down.

**Phase B - move to the lab segment:**

- [ ] Change the adapter to LAN segment `cvp-lab`; apply the Guest Isolation / Shared Folders settings from §2.
- [ ] Boot; `sudo bash ~/cvp-lab/kali/kali-netconfig.sh`; log out and in.
- [ ] Connectivity checks from Kali:
  - `ping -c1 8.8.8.8` → *Network is unreachable* (no route)
  - `curl -sI https://example.com` → `403 Forbidden` from Squid
  - `curl -skI https://8.8.8.8` → `403 Forbidden` from Squid (bare IPs never match the allow-list, see docs/decisions.md D-015)
  - `curl -sI https://api.anthropic.com` → an HTTP response from Anthropic (any status is fine; it proves the proxy path works)
  - `ping -c1 win-app-01` (10.0.3.21) → Windows target reachable; same for each further target up to `win-app-10` (10.0.3.30)
- [ ] **Transcript drop-box key:** on Kali `bash ~/cvp-lab/kali/setup-kali.sh share-key`; on the gateway console `sudo cvp-enrol-key` and check the fingerprints match; Ctrl+C on Kali; then `~/bin/sync-transcripts.sh` should succeed.
- [ ] `claude auth status --text` shows you signed in. If a login is ever needed inside the lab (expired, or lost to a snapshot restore), try `/login` in run mode with the browser step on the host first; only if that fails use `sudo cvp-mode login` on the gateway, then `sudo cvp-mode run` straight after.
- [ ] In Claude Code run `/status` and confirm the *Proxy* row shows `http://10.0.3.1:3128`. Then `claude auto-mode config` and confirm your `environment` and `hard_deny` entries appear. `claude auto-mode critique` to sanity-check the custom rules.
- [ ] Confirm Auto Mode is actually active: start `claude` and check the mode indicator; if it reports auto mode unavailable, see the permission-modes docs (model/plan requirements).
- [ ] Take the **Kali gold snapshot**.

**Phase C - validation (RECOMMENDED but treat as mandatory for yourself):**

- [ ] Run the sandbox escape test in [`kali/escape-test-prompt.md`](kali/escape-test-prompt.md) under supervision, with Squid and journal logs tailing on the gateway.
- [ ] Review: every outbound attempt appears as `TCP_DENIED` in Squid or `cvp-lab-*-drop` in the gateway journal. Keep `escape-test.md` as evidence.
- [ ] Re-run this whenever you change the gateway config, the Squid allow-list, `settings.json`, or rebuild the Kali gold image.

---

## 5. Windows target VMs

Up to ten targets, 10.0.3.21-30, as many as the engagement needs. Kali knows them as `win-app-01` (10.0.3.21) to `win-app-10` (10.0.3.30). Repeat this section for each one.

- [ ] Build / install the application and complete any licence activation or Windows Update **on NAT first**.
- [ ] Switch adapter to LAN segment `cvp-lab`; apply Guest Isolation / Shared Folders settings from §2.
- [ ] Run [`windows/netconfig.ps1`](windows/netconfig.ps1) as Administrator: no argument for the first target (10.0.3.21), then `-IP 10.0.3.22` and so on up to `-IP 10.0.3.30`. Anything outside that range is refused.
- [ ] Verify: `Test-NetConnection 10.0.3.11` succeeds; `Test-NetConnection 8.8.8.8` fails.
- [ ] Snapshot.

---

## 6. Per-engagement runbook (RECOMMENDED - containment best practices)

Before:

- [ ] Restore Kali gold snapshot and Windows target snapshot.
- [ ] Gateway: `sudo cvp-mode status` → confirm **run** mode.
- [ ] Copy [`kali/CLAUDE.md.template`](kali/CLAUDE.md.template) to the engagement directory as `CLAUDE.md`; fill in targets, permitted actions, and the authorisation reference. Phrase constraints as intent ("do not access..."), not as environment claims ("you cannot...").
- [ ] Confirm all tooling the task needs is present (nothing can be fetched mid-run). Note any "impossible" steps that will need closer supervision.
- [ ] Open `tail -f /var/log/squid/access.log` on the gateway in a visible window.

During:

- [ ] Supervise the run. Watch tool calls and the Squid log; be ready to `Ctrl+C` / suspend the VM.
- [ ] Any `TCP_DENIED` for a host you didn't expect, or any `cvp-lab-*-drop` in the gateway journal, pause and read the transcript around it.
- [ ] Never point the agent at live production, especially OT/ICS, medical or energy systems. Replica, testbed or digital twin only; if live access is unavoidable, read-only and a human performs every state-changing step.

After:

- [ ] `~/bin/sync-transcripts.sh` on Kali.
- [ ] Review the transcript for any run where the egress layer logged a denied/unexpected request, and for anything that looked like probing the sandbox or network isolation.
- [ ] Out-of-scope behaviour observed → notify your Anthropic account team (and, if it meets the §1 thresholds, `security@anthropic.com` within 24/72 h).
- [ ] Confirm retention: Squid logs (45 days on gateway) and transcripts (`/var/cvp/transcripts`) both cover ≥ 30 days.

---

## 7. Maintenance

- [ ] **Updating Claude Code:** gateway `sudo cvp-mode login`, uncomment `downloads.claude.ai` in `allowlist-login.txt` and `sudo cvp-mode login` again to reload, run `claude update` on Kali, re-comment the line, `sudo cvp-mode run`, re-snapshot Kali, re-run the escape test.
- [ ] **Updating Kali tools:** either rebuild from Phase A on NAT, or temporarily add the repo hosts to the login list. Prefer rebuilding; it keeps the allow-list history clean.
- [ ] **Quarterly:** re-read the two Anthropic articles; both are marked as evolving. Check `claude auto-mode defaults` for new built-in rules.
- [ ] **15 Dec 2026:** phishing-resistant MFA cutoff. Any interim API key must be gone.

---

## 8. Known gaps / things to verify yourself

- `cleanupPeriodDays` (local transcript expiry in Claude Code) was not verified against the current settings reference. The sync script makes it moot, but check it if you rely on local copies.
- The containment article asks for the credential to be injected from outside the sandbox. With OAuth, the refresh token lives on Kali under `~/.claude/`. Mitigations here: `hard_deny` rule against touching `~/.claude/`, snapshot restore between runs, and revocation from the account if the VM is ever suspect. A stricter option is running a gateway on the GW VM holding the credential (`ANTHROPIC_BASE_URL`); the Claude Code gateway docs cover this but it wasn't set up or tested here.
- The "sandbox escape classifier" Anthropic mentions is documented in a separate getting-started article not reviewed for this checklist.
- Squid/nftables/netplan/PowerShell files are hand-written standard configs, not from Anthropic; the escape test is what proves they work in your build.

---

## References

- Agent containment best practices for CVP participants - https://support.claude.com/en/articles/17317514-agent-containment-best-practices-for-cvp-participants
- Cyber Verification Program Security Requirements - https://support.claude.com/en/articles/17202708-cyber-verification-program-security-requirements
- Agent containment best practices: getting started (classifier) - https://support.claude.com/en/articles/17316076 (not reviewed)
- Claude Code: Enterprise network configuration (proxy vars, required domains) - https://code.claude.com/docs/en/network-config
- Claude Code: Configure auto mode - https://code.claude.com/docs/en/auto-mode-config
- Claude Code: Run through a gateway - https://code.claude.com/docs/en/gateways
- CISA: Implementing Phishing-Resistant MFA - https://www.cisa.gov/sites/default/files/publications/fact-sheet-implementing-phishing-resistant-mfa-508c.pdf
