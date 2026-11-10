# Lab reference

Background for [CHECKLIST.md](../CHECKLIST.md), which is the step-by-step build.
Why each choice was made is in [decisions.md](decisions.md).

## Addresses

| Host | Address | Notes |
|---|---|---|
| Gateway | 10.0.3.1 | Ubuntu Server 26.04; `ens33` = NAT, `ens37` = lab |
| Kali | 10.0.3.11 | Claude Code |
| Windows targets | 10.0.3.21-30 | `win-app-01` = .21 ... `win-app-10` = .30 on Kali |

## Architecture

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

The containment guidance recommends that wherever the model does agentic work,
outbound traffic is limited to an allow-list enforced off the host and logged
(for the Red Team and Specialized tiers it is a requirement). A LAN segment has
no host adapter, so the only way out is the gateway, which doesn't route and
only offers a proxy, to Kali alone.

The gateway's own outbound traffic is not filtered (nftables `output` is
`policy accept`): Squid needs DNS and HTTPS upstream, and apt needs the
internet. So `curl https://example.com` works when run on the gateway itself;
that is expected, because nothing in the lab can use that route. Test the proxy
from Kali. Optional hardening once the build is done: restrict the gateway's
`output` chain to the Anthropic hosts (`ip daddr { ... } tcp dport 443 accept`
plus DNS, policy drop). Anthropic's IPs change, so that list needs maintaining
and apt updates need it relaxed.

## Required versus recommended

Only the CVP Security Requirements are mandatory. For an individual that is §3
(Google or equivalent sign-in, MFA, phishing-resistant MFA by 15 Dec 2026, no
static or long-lived credentials after that date, personal access, Anthropic
monitoring) plus Incident Reporting, Cooperation and Ongoing Review from §1.
CHECKLIST §1 covers them. Everything else in the lab follows the containment
best-practice articles, which are recommendations.

Not applicable at this tier (Red Team / Specialized only): organisation-domain
accounts, managed devices with EDR, background checks, a 25-seat cap, mandatory
off-host egress control, no static credentials on endpoints.

## Files

| Path | Installed to | Purpose |
|---|---|---|
| [`gateway/install-gateway.sh`](../gateway/install-gateway.sh) | run on the gateway | one-shot installer for everything below |
| [`gateway/nftables.conf`](../gateway/nftables.conf) | `/etc/nftables.conf` | default-drop, no forwarding; only Kali can reach Squid |
| [`gateway/squid.conf`](../gateway/squid.conf) | `/etc/squid/squid.conf` | explicit CONNECT proxy for Kali only, hostname allow-list, logging |
| [`gateway/allowlist-run.txt`](../gateway/allowlist-run.txt) | `/etc/squid/` | engagement allow-list (2 hosts) |
| [`gateway/allowlist-login.txt`](../gateway/allowlist-login.txt) | `/etc/squid/` | re-authentication inside the lab (exact hosts) |
| [`gateway/allowlist-update.txt`](../gateway/allowlist-update.txt) | `/etc/squid/` | `claude update` and `git pull` of this repo on Kali |
| [`gateway/cvp-mode.sh`](../gateway/cvp-mode.sh) | `/usr/local/sbin/cvp-mode` | switch allow-lists, show denials |
| [`gateway/cvp-enrol-key.sh`](../gateway/cvp-enrol-key.sh) | `/usr/local/sbin/cvp-enrol-key` | install Kali's transcript-sync key (write-only, no deletes) |
| [`gateway/cvp-archive.sh`](../gateway/cvp-archive.sh) | `/usr/local/sbin/cvp-archive` | 5-minute root-only transcript snapshots, tamper check, 45-day prune |
| [`gateway/cvp-review.sh`](../gateway/cvp-review.sh) | `/usr/local/sbin/cvp-review` | pattern scan of transcripts + random sample of unflagged ones |
| [`gateway/cvp-export.sh`](../gateway/cvp-export.sh) | `/usr/local/sbin/cvp-export` | package an engagement (folder, transcripts, gateway logs) for the host's shared folder |
| [`gateway/logrotate-squid`](../gateway/logrotate-squid), [`gateway/logrotate-cvp`](../gateway/logrotate-cvp) | `/etc/logrotate.d/` | 45-day retention for Squid and nftables drop logs |
| [`kali/setup-kali.sh`](../kali/setup-kali.sh) | run on Kali | `build` (on NAT), `lab` and `share-key` (in the lab) |
| [`kali/kali-netconfig.sh`](../kali/kali-netconfig.sh) | run by `setup-kali.sh lab` | static IP, no default route, system proxy; fails if anything else is connected |
| [`kali/managed-settings.json`](../kali/managed-settings.json) | `/etc/claude-code/managed-settings.json` | root-owned Claude Code policy: proxy, claude.ai-only login, Auto Mode rules, model pin |
| [`kali/cvp-scope.sh`](../kali/cvp-scope.sh), [`kali/cvp-scope.nft`](../kali/cvp-scope.nft) | `/usr/local/bin/cvp-scope`, `/etc/cvp-scope.nft` | Kali firewall: only the gateway and the engagement's in-scope targets |
| [`kali/cvp-run.sh`](../kali/cvp-run.sh) | `/usr/local/bin/cvp-run` | pre-flight checks, then Claude Code with a hard time limit |
| [`kali/cvp-engagement.sh`](../kali/cvp-engagement.sh) | `/usr/local/bin/cvp-engagement` | create, re-scope, list and close engagements under `~/engagements/` |
| [`kali/sync-transcripts.sh`](../kali/sync-transcripts.sh) | `/usr/local/bin/sync-transcripts` | transcripts and `~/engagements/` to the gateway (every minute via `cvp-sync.timer`) |
| [`kali/CLAUDE.md.template`](../kali/CLAUDE.md.template) | `/usr/local/share/cvp-lab/` | per-engagement scope statement (`cvp-engagement new` fills it in) |
| [`kali/CLAUDE.md.no-targets`](../kali/CLAUDE.md.no-targets) | `/usr/local/share/cvp-lab/` | nothing in scope, for the self-check and escape test |
| [`kali/escape-test-prompt.md`](../kali/escape-test-prompt.md) | - | the sandbox escape test prompt |
| [`validation/validate-kali.sh`](../validation/validate-kali.sh) | run on Kali | read-only checks of the Kali build |
| [`validation/validate-windows.ps1`](../validation/validate-windows.ps1) | copy to each target | read-only checks of a Windows target |

## Squid allow-lists

| Host | Needed for | Run | Login | Update |
|---|---|---|---|---|
| `api.anthropic.com` | Claude API, feature flags | yes | yes | yes |
| `platform.claude.com` | OAuth token exchange / refresh / revocation | yes | yes | yes |
| `claude.ai`, `claude.com` (exact) | browser sign-in page and redirect | no | yes | no |
| `downloads.claude.ai` | native installer / updater | no | no | yes |
| `github.com` | `git pull` of this public repo on Kali | no | no | yes |
| everything else in the network-config docs | plugins, MCP connectors, artifacts, telemetry, docs | no | no | no |

Google's sign-in pages are on no list, so a Google sign-in is always finished
in a browser on the host (D-016).

## Logs and where to look

| What | Where | Kept |
|---|---|---|
| Proxy requests (allowed and `TCP_DENIED`) | gateway `/var/log/squid/access.log` | 45 days |
| Gateway firewall drops (`cvp-lab-*-drop`) | gateway `/var/log/cvp-lab-nft.log` | 45 days |
| Transcript snapshots | gateway `/var/cvp/archive/` (`latest` = newest) | 45 days; the newest until the gateway is rebuilt |
| Snapshot integrity and disk warnings | gateway `/var/log/cvp-transcripts.log` | 12 months |
| Allow-list mode switches | gateway `/var/log/cvp-mode.log` | 12 months |
| Kali scope drops (`cvp-scope-drop`) | Kali `journalctl -k` | journald |
| Scope changes | Kali `/var/log/cvp-scope.log` | - |
| Claude Code run starts/stops | Kali `~/.claude/cvp-runs.log` (also synced) | synced |
| Engagement folders (synced copy) | gateway `/var/cvp/archive/<time>/kali/engagements/` | 45 days; the newest until the gateway is rebuilt |
| Engagement exports | gateway `/var/cvp/exports/`, then host `C:\CVP\exports\` | until you delete them |

## Weaknesses accepted as risk

Known weaknesses, accepted for a supervised lab that tests replica systems
rather than hostile code. Each says what limits it. Those from the November
2026 review are recorded in D-025.

- **The model credential is inside the sandbox.** The OAuth login lives in `~/.claude/` on Kali, as the same user Claude Code runs as. The guidance recommends a credential proxy outside the sandbox; its reference design uses a `claude setup-token` token, which is long-lived, and the Security Requirements forbid long-lived credentials after 15 Dec 2026. Check with your account team before building it. Mitigations here: `blockReadsOutsideWorkingDirectories`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, the `hard_deny` rule, no passwordless sudo, snapshot restore between runs, and revoking the login if the VM is ever suspect (D-007).
- **Programs Claude runs share its identity.** Everything the agent executes runs as the operator's Kali user, so it could read the OAuth login, change user-owned files (including the Claude Code binary under `~/.local`, which is what enforces the managed settings), edit transcripts before they sync, or start processes that outlive the session. Claude Code's Bash sandbox isn't used: it sends network traffic through its own allow-list proxy, so tools that talk to the targets wouldn't run inside it. Limits: no passwordless sudo, root-owned managed settings and firewall, the tampering `soft_deny` rule, and snapshot restore between engagements. Optional, untested: install the Claude Code binary root-owned (D-025).
- **Targets share Kali's network segment.** The gateway never sees Kali-to-target traffic, and `cvp-scope` holds only while the agent has no root (D-019). A compromised target can reach every other running target directly, so targets that aren't in scope stay powered off (GUIDE §1 step 1). A target that takes over Kali's address can use the proxy, but only to reach api.anthropic.com and platform.claude.com, which the agent on Kali can reach anyway, and it disrupts Kali's own traffic while it does. Off-host enforcement would mean re-addressing the targets onto their own segment, routed through the gateway (D-025).
- **The time limit covers only what runs inside the `cvp-run` scope.** A process started outside it (e.g. with `systemd-run --user`) outlives the limit, and anything already running on a target carries on. The backstop is the hypervisor: suspend Kali and every running target (GUIDE §3 step 1) (D-025).
- **Transcripts are written by the agent's own process.** They are synced every minute and snapshotted every 5 minutes into a root-only area of the gateway, with in-place edits flagged, so later tampering is caught but anything faked before the first sync is not. The Squid and nftables logs are the independent record (D-018).
- **The gateway disk has no hard quota.** Kali can upload without limit. `cvp-archive` stops snapshotting at 80% used and logs `LOW-SPACE` (shown by `cvp-review`), but uploads still land in `/var/cvp/incoming`, and a full disk would stop Squid's and nftables' logging. A second virtual disk for `/var/cvp` would cap it. Engagement material stays on the gateway (in `incoming` and the newest snapshot) until the gateway is rebuilt or it is deleted by hand (D-025).
- **Checks without root see less than their names suggest.** `cvp-run` and `validate-kali.sh` read cvp-scope's service and state file, not the live ruleset. A target that doesn't answer ping may be blocked or down, which is why CHECKLIST §7 runs the check both in and out of scope. The escape test also exercises the permission rules, so its report marks each attempt *blocked*, *refused* or *not tried*; only *blocked* is evidence of containment (D-025).
- **Kernel code can still reach the hypervisor.** `restrict_backdoor` stops ordinary programs using the VMware backdoor and the VMCI device is removed, but code in a guest's kernel may still use the backdoor. On Kali the agent has no root; on a target it can become administrator by design. The gateway keeps both for `cvp-export` (D-024).
- **The lab shares the Windows host.** An escape through VMware itself would land on the host, so the host holds no production credentials and joins no client networks, and it and VMware Workstation are patched monthly (CHECKLIST §9 step 4). A dedicated host isn't planned (D-025).
- **No turn limit in interactive sessions.** Claude Code offers `--max-turns` only for `-p` runs; interactive runs rely on supervision and the `cvp-run` time limit.
- **`ask` rules are prefix matches.** `Bash(ssh *)` won't catch `/usr/bin/ssh`, `env ssh` or `bash -c "ssh ..."`. They are a convenience, not a boundary.
- **The sandbox escape classifier isn't available to Claude Code.**
- Squid/nftables/netplan files are hand-written standard configs, not from Anthropic; the escape test is what proves they work in your build.

## References

- Cyber Verification Program Security Requirements (the only mandatory document) - https://support.claude.com/en/articles/17202708-cyber-verification-program-security-requirements
- Agent containment best practices for CVP participants - https://support.claude.com/en/articles/17317514-agent-containment-best-practices-for-cvp-participants
- Agent containment best practices: getting started - https://support.claude.com/en/articles/17316076, and its sub-articles: sandboxing (17316105), auto mode (17316089), offline monitoring (17316112), online monitoring (17313886), prompt injection (17316099)
- Claude Code: network configuration - https://code.claude.com/docs/en/network-config
- Claude Code: managed settings - https://code.claude.com/docs/en/managed-settings
- Claude Code: configure auto mode - https://code.claude.com/docs/en/auto-mode-config
- Claude Code: environment variables - https://code.claude.com/docs/en/env-vars
- CISA: Implementing Phishing-Resistant MFA - https://www.cisa.gov/sites/default/files/publications/fact-sheet-implementing-phishing-resistant-mfa-508c.pdf
