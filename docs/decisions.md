# Design decisions

Why the lab is built the way it is. Each entry records the requirement or
guidance it answers, the options considered, and what was chosen. Dates are
when the decision was made; "Status" flips to *superseded* if a later entry
replaces it.

Requirements are from:

- CVP Security Requirements (SR) - https://support.claude.com/en/articles/17202708-cyber-verification-program-security-requirements
- Agent containment best practices (CB) - https://support.claude.com/en/articles/17317514-agent-containment-best-practices-for-cvp-participants
- Claude Code network config (NC) - https://code.claude.com/docs/en/network-config
- Claude Code auto mode config (AM) - https://code.claude.com/docs/en/auto-mode-config

---

## D-001 Access tier assumed: Defense Access for Individuals

**Date:** 2026-10-07 · **Status:** active

The grant is held by an individual, so SR §3 applies plus Incident Reporting,
Cooperation and Ongoing Review from §1. SR §2 (org Defense), §4 (Red Team) and
§5 (Specialized) do not apply. This matters because the stricter tiers add
managed devices with EDR, org-domain accounts, background checks, a formal
gateway rule and a 25-seat cap - none of which are built here. If the grant is
ever upgraded, CHECKLIST §1 is the first thing to revisit.

## D-002 Egress enforced on a separate gateway VM, not on the Kali host

**Date:** 2026-10-07 · **Status:** active

SR §4.9/§5.9 (and the spirit of CB 1.a) require outbound traffic from wherever
the model does agentic work to be limited to an allow-list *enforced off the
host* and logged. Although those sections are Red Team/Specialized text, CB 1.a
applies to everyone and says the same thing in softer words.

Options considered:

1. Windows host firewall rules on the VMware NAT adapter. Rejected: `vmnat.exe`
   does the translation and Windows Firewall sees the traffic as the host's own,
   so per-VM rules are unreliable, and there is no per-request log.
2. `iptables` / proxy on the Kali VM itself. Rejected: on-host; the agent could
   in principle modify it, which is exactly what the requirement forbids.
3. A dedicated gateway VM with no forwarding and an explicit proxy. **Chosen.**
   The enforcement point is outside the sandbox, every request is logged, and
   it is cheap (1 vCPU / 1 GB).

## D-003 VMware LAN Segment rather than Host-only or NAT for the lab network

**Date:** 2026-10-07 · **Status:** active

- NAT (VMnet8): every VM gets the internet. Not usable for the sandbox.
- Host-only (VMnet1 or custom): still creates a host virtual adapter, so the
  Kali VM can reach the Windows host's network stack. That is a host-escape
  path and would also need host firewall work.
- LAN Segment: a pure virtual switch with no host adapter and no VMware DHCP.
  The only thing on it with a second NIC is the gateway VM. **Chosen.**

Consequence: all lab hosts need static IPs and `/etc/hosts` entries (no DNS).
This is deliberate - DNS is an exfiltration channel and the lab doesn't need it.

## D-004 VMware Workstation retained despite Hyper-V being the named recommendation

**Date:** 2026-10-07 · **Status:** active - revisit if evidence of compliance is requested

CB 1.a recommends Firecracker (Linux), Hyper-V (Windows), Hypervisor.framework
(macOS). The *requirement* wording is "isolation inside a virtual machine or
dedicated bare-metal host", which Workstation meets. Workstation on modern
Windows with Hyper-V enabled already runs on the Windows Hypervisor Platform.
The design ports to Hyper-V unchanged: External vSwitch for GW NIC1, Private
vSwitch for the lab. Not done now because Workstation is the existing tooling
and nothing in the requirements forbids it.

## D-005 Squid explicit CONNECT proxy, no TLS interception

**Date:** 2026-10-07 · **Status:** active

Alternatives: `nftables` IP allow-list only (Anthropic's IPs change; no
hostname-level log), transparent proxy with TLS bump (needs a CA on Kali, and
`NODE_EXTRA_CA_CERTS` plumbing, plus decrypts API traffic for no benefit).

Explicit CONNECT proxy matches the hostname in the CONNECT request, which is
enough for an allow-list, logs every request including `TCP_DENIED`, and needs
no certificate work on Kali. Claude Code reads `HTTPS_PROXY` natively (NC).
Squid does not support SOCKS and neither does Claude Code, which rules that out.

Minor detail: `logformat squid` is a built-in name and can't be redefined, so
the custom format is called `cvp`.

## D-006 Two allow-lists (run / login) switched by a logged script

**Date:** 2026-10-07 · **Status:** superseded in part by D-021 (three lists, exact login hosts)

NC lists ~18 hosts Claude Code may contact. Only `api.anthropic.com` and
`platform.claude.com` are needed during a run with an OAuth login (`claude.ai`
and `claude.com` are only touched by the browser sign-in page). Everything else
is updates, plugins, MCP connectors, artifacts, telemetry and docs.

Keeping the run list to two hosts means any other hostname in the Squid log is
by definition unexpected, which makes the CB 1.c review ("review transcripts
where the egress layer logged a denied or unexpected request") trivial. The
login list exists so OAuth can be done without hand-editing the config, and
`cvp-mode` writes every switch to `/var/log/cvp-mode.log` so the audit trail
shows when the wider list was active.

## D-007 OAuth credential stays on Kali (gap accepted for now)

**Date:** 2026-10-07, revised 2026-10-09 · **Status:** active - known gap, see CHECKLIST §8

CB 1.a wants "the API key injected from outside the sandbox". SR §3.2 requires
OAuth rather than keys for individuals, and Claude Code's OAuth refresh token
lives in `~/.claude/.credentials.json` on the VM.

*Revised 2026-10-09 after re-reading the guidance:* keeping the credential out
of the sandbox is a recommendation, not a requirement, for every tier. The
getting-started sandboxing article's reference design is a credential proxy
holding a `claude setup-token` token, with the agent given only a placeholder
`CLAUDE_CODE_OAUTH_TOKEN`. That token is long-lived, and SR §3 forbids static
or long-lived credentials after 15 Dec 2026, so the two documents pull in
different directions for an individual; ask the account team before building
it. Added mitigations (D-020): `blockReadsOutsideWorkingDirectories`,
`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, a tampering `soft_deny`, and `cvp-run`
refusing to start when passwordless sudo is available.

Options:

1. Accept it, mitigate with a `hard_deny` against touching `~/.claude/`,
   snapshot-restore between runs, and account-level revocation. **Chosen for
   now** - simplest and still compliant with SR §3.
2. Run a credential-holding gateway on the GW VM and point Kali at it with
   `ANTHROPIC_BASE_URL`. Closer to CB, but the Claude Code gateway docs were
   not fully worked through and `--teleport`/cloud features don't work behind
   a gateway. Deferred.

## D-008 `iifname` instead of `iif` in nftables

**Date:** 2026-10-07 · **Status:** active

`nft -c` failed with "Interface does not exist" because `iif` resolves the
interface to an index at load time. On a VM where nftables may start before
the NIC is up, that would leave the ruleset unloaded - i.e. the lab would
silently be *un*-filtered. `iifname` matches by string and loads regardless.

## D-009 Forwarding disabled at three layers

**Date:** 2026-10-07 · **Status:** active

`forward` chain policy drop, no masquerade rule at all, and
`net.ipv4.ip_forward=0` via sysctl. Any one is sufficient; three means a
mistake in one (e.g. someone adds a NAT rule "just to apt-get") doesn't open
the lab. The escape test (CHECKLIST §4C) is what proves it.

## D-010 Auto Mode on, with environment + hard_deny entries, not `bypassPermissions`

**Date:** 2026-10-07 · **Status:** active

CB 1.d and 2.f recommend Auto Mode because its classifier blocks
containment-escape actions (metadata credentials, tunnels, reverse shells,
reading host credentials, scanning neighbours) and says to describe in-scope
exceptions in `autoMode.environment` rather than disabling it.

`settings.json` therefore:

- keeps `"$defaults"` in every list so built-in rules are inherited (AM warns
  that omitting it discards them);
- adds a *Host containment* environment entry (requires Claude Code
  ≥ 2.1.257 per AM) naming the proxy, the allowed hosts, and that no metadata
  endpoint exists;
- adds `hard_deny` entries for leaving the segment and for touching the
  operator's credentials;
- lives in `~/.claude/settings.json`, because AM says the classifier does not
  read `autoMode` from project-level settings files. *Superseded by D-020:
  it is now root-owned managed settings.*

`permissions.deny` on WebFetch/WebSearch is belt-and-braces (the proxy already
blocks them) and stops wasted turns. `permissions.ask` on ssh/scp/nc/socat/
chisel/ligolo forces a human prompt even in Auto Mode, since those are the
tools most likely to be used to tunnel out.

## D-011 Scope statements phrased as intent, in CLAUDE.md

**Date:** 2026-10-07 · **Status:** active

CB 2.b: constraints should be written as intent ("do not access hosts outside
10.0.3.0/24") rather than environment claims ("you cannot reach the
internet"), so they hold if the environment is misconfigured. AM notes the
classifier reads the same CLAUDE.md Claude does, so one file steers both.
Hence `kali/CLAUDE.md.template` and the matching wording in `settings.json`.

## D-012 Transcripts synced to the gateway rather than relying on local retention

**Date:** 2026-10-07 · **Status:** superseded by D-018

CB 1.c / 2.e: retain transcripts and egress logs ≥ 30 days. Kali is
snapshot-restored between engagements (D-002, D-009), which would wipe
`~/.claude/projects/`. `sync-transcripts.sh` rsyncs them to `/var/cvp/transcripts`
on the gateway over a key restricted with `rrsync -wo`, and excludes
`.credentials.json`. Squid logs rotate at 45 days. `cleanupPeriodDays` (local
Claude Code transcript expiry) was *not* verified; the sync makes it moot.

## D-013 Windows target has no gateway, no DNS, no proxy

**Date:** 2026-10-07 · **Status:** active

The target is a replica (CB 2.g: never a live production / OT / ICS system).
It has no reason to leave the lab, and giving it none removes a second egress
path the agent could pivot through. Licence activation and updates are done on
NAT before the adapter is moved. Targets are configured by hand (no script),
and since 2026-10-09 the gateway's proxy refuses them outright (D-019).

## D-014 Markdown checklist in git, not a Word document

**Date:** 2026-10-07 · **Status:** active (superseded the original docx plan)

The files are the deliverable; a document that embeds them goes stale the
moment one is edited. Markdown with relative links keeps one source of truth,
diffs in git, and is readable by Claude Code when the repo is opened there.

## D-015 Squid matches allow-list hostnames only (`dstdomain -n`)

**Date:** 2026-10-07 · **Status:** active

Found the first time squid.conf was actually run (Squid 6.14, Ubuntu 24.04
build). Without `-n`, a CONNECT to a bare IP is reverse-resolved and allowed if
the PTR record names a listed host. PTR records are set by whoever owns the IP,
so any server could pass itself off as `api.anthropic.com`. In testing,
`CONNECT 8.8.8.8:443` was tunnelled once `dns.google` was on the list; with
`-n` the same request is `TCP_DENIED`. Claude Code always CONNECTs by hostname,
so nothing legitimate needs the reverse lookup.

`via off` is kept even though Squid 6 warns about it: without it, every 403
sends `Via: 1.1 <gateway hostname> (squid/6.14)` back to the sandbox.

## D-016 Claude Code signs in on NAT during the Kali build, not through the lab proxy

**Date:** 2026-10-09 · **Status:** active

SR §3 requires the account to sign in through Google (or another IdP) with
phishing-resistant MFA. Doing `/login` in Kali's browser inside the lab would
need Google's sign-in pages on the Squid allow-list, plus USB passthrough for a
security key. `setup-kali.sh build` instead runs `claude auth login` in Phase A
while Kali still has direct internet, with the browser step optionally on the
host, and only then installs `settings.json` (whose proxy is unreachable on
NAT). No agentic work happens before Kali moves to the lab. Login mode stays as
a fallback for re-authenticating inside the lab.

*2026-10-09:* the grant account signs in with Google, so login mode can't
complete a fresh sign-in in Kali's browser (Google's pages aren't listed, and
the security key isn't in the VM). Re-authenticating inside the lab means the
browser step on the host, with VMware copy and paste turned on just for that.
Adding Google's sign-in hosts to login mode was rejected: it would open a broad
set of Google domains to the sandbox for a rare task.

## D-017 Gateway SSH is for the transcript drop-box only, and the drop-box refuses deletes

**Date:** 2026-10-09 · **Status:** active; corrected by D-018

*Correction:* this entry first called the drop-box "append-only". It isn't:
`-no-del` stops deletes, but rrsync still lets Kali overwrite or truncate a
file (only `-no-overwrite` stops that, and growing transcripts need
overwriting). D-018 adds the gateway-side snapshots that make overwrites
detectable instead.

Ubuntu's sshd allows password logins by default, and the original ruleset let
the whole lab reach port 22 on the gateway - the egress enforcement point. Now
nftables accepts SSH only from Kali (10.0.3.11), an sshd `Match Address
10.0.3.0/24` block allows only `cvpsync` with keys, and the gateway is
administered from the VMware console.

The `cvpsync` key is forced into `rrsync -wo -no-del`, and `sync-transcripts.sh`
no longer passes `--delete-excluded`. Previously the first sync after a snapshot
restore would have deleted earlier engagements' transcripts on the gateway
(D-012), and a compromised Kali could have wiped its own audit trail. The key
is fetched from Kali over the lab segment by `cvp-enrol-key` rather than pasted,
because neither VM has a usable clipboard.

## D-018 Transcripts: synced every minute, snapshotted root-only on the gateway, checked for in-place edits

**Date:** 2026-10-09 · **Status:** active (replaces D-012)

A review found the drop-box was not append-only (D-017) and that syncing by
hand after an engagement could lose the only copy. The guidance (offline
monitoring article) asks for transcripts captured outside the sandbox, kept at
least 30 days, scanned with pattern rules, reviewed by a model, and a random
5-10% of unflagged ones read anyway.

- Kali: a root-owned `cvp-sync.timer` runs `sync-transcripts` every minute as
  the operator's user, and `cvp-run` syncs again when Claude Code exits.
- Gateway: Kali writes only to `/var/cvp/incoming` (`rrsync -wo -no-del`).
  `cvp-archive` runs every 5 minutes and copies anything new into a root-only
  snapshot under `/var/cvp/archive` (hard links for unchanged
  files). Kali can't reach a snapshotted version. Because JSONL transcripts
  only grow, a file that changed other than by growing, or disappeared, is
  logged as NON-APPEND / MISSING. Snapshots are pruned at 45 days; the newest
  always holds every file.
- `cvp-review` lists those warnings, pattern hits per session, and a random 10%
  of the unflagged sessions. Model review is a manual step in a separate
  Claude session outside the lab.
- nftables drop lines now also go to `/var/log/cvp-lab-nft.log` (rsyslog, 45
  days) instead of relying on journald, whose retention isn't time-based.

Not met: the guidance prefers transcripts written by an orchestrator outside
the sandbox (stream-json). Interactive Claude Code on Kali writes its own, so
anything faked before the first sync would not be detected; the Squid and
nftables logs remain the independent record. Kali-side `-no-overwrite` was
rejected because growing transcripts have to be re-sent.

## D-019 Target scope enforced on Kali; the gateway serves Kali only

**Date:** 2026-10-09 · **Status:** active - partial, see CHECKLIST §8

The guidance recommends enforcing engagement scope in the network ("allow-list
egress to the model API endpoint and explicitly in-scope targets"). Kali and
the targets share one /24 segment, so their traffic never crosses the gateway.

- `cvp-scope` (nftables on Kali, output policy drop) allows only the gateway's
  proxy/SSH/ping and the engagement's in-scope IPs. The set is empty after
  every boot; `sudo cvp-scope set` fills it, and `cvp-run` refuses to start
  unless it matches the CLAUDE.md in-scope table.
- It is on-host, so it holds only while the agent has no root (`cvp-run` also
  refuses to start if passwordless sudo works). A root process could flush it
  or send raw frames past it.
- Squid's `src` ACL and the nftables 3128 rule now admit only 10.0.3.11, so a
  compromised Windows target can't use the proxy to reach the Anthropic hosts.

Off-host enforcement would need the targets on their own LAN segment with the
gateway routing Kali to in-scope targets only. That changes the 10.0.3.21-30
addressing, so it's left as an option for later.

## D-020 Root-owned managed settings, a fail-closed launcher, and a pinned model

**Date:** 2026-10-09 · **Status:** active (replaces the settings location in D-010)

The auto mode article says to "treat autoMode settings as security
configuration: deploy them through managed settings". A user-level
`~/.claude/settings.json` can be edited by the agent, which runs as the same
user.

- `kali/managed-settings.json` installs to `/etc/claude-code/managed-settings.json`,
  root-owned. It adds `forceLoginMethod: "claudeai"`,
  `disableBypassPermissionsMode`, `blockReadsOutsideWorkingDirectories` (with
  the wordlist directories added back), `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, and
  a tampering `soft_deny` rule.
- The model is pinned with `model` + `availableModels` + `enforceAvailableModels`
  to the ID the operator gives `setup-kali.sh build`. The Mythos model ID isn't
  in Anthropic's public model list, so it isn't hard-coded or guessed.
- `cvp-run <hours>` is the only supported way to start Claude Code. It refuses
  to start unless the workspace is outside the public repo, the network is one
  lab interface with no route out, the firewall scope matches CLAUDE.md, no
  credential variable or `apiKeyHelper` would override the OAuth login, the
  login is claude.ai for the expected account, the managed settings pin the
  model, the proxy allows Anthropic and refuses others, sudo needs a password,
  no VMware shared folder is mounted, and the sync timer is running. The time
  limit is required (the guidance says not to accept a generous default), and
  everything the run started is killed when it ends.

## D-021 Requirement labels corrected; login and update allow-lists split

**Date:** 2026-10-09 · **Status:** active

Re-reading the three support articles (all updated 2026-10-06): only the
Security Requirements are mandatory, and for an individual that is §3 plus
Incident Reporting, Cooperation and Ongoing Review from §1. Off-host egress
control and 30-day retention are recommendations for this tier (requirements
only in §4/§5), and phishing-resistant MFA means one qualifying method, not
two keys. The checklist now labels them that way.

The login list used `.claude.ai` / `.claude.com`, which already covered
`downloads.claude.ai`; uncommenting that line for updates would also have made
Squid refuse to start (overlapping entries). Login now uses exact `claude.ai`
and `claude.com`, and a separate `cvp-mode update` list adds only
`downloads.claude.ai`. Switching back to `run` restarts Squid so no tunnel
opened under a wider list survives.
