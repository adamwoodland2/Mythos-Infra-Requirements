# cvp-lab

Build files for an isolated VMware Workstation lab running Claude Code (Kali) under
the Anthropic Cyber Verification Program, Defense Access for Individuals tier.
Read CHECKLIST.md first - it is the source of truth and links every file.

Conventions:
- British English, hyphens not dashes, $ = AUD.
- Lab addressing: gateway 10.0.3.1, Kali 10.0.3.11, Windows targets 10.0.3.21-30
  (as many as needed; win-app-01 = .21 to win-app-10 = .30).
- Gateway is Ubuntu Server 26.04 (Squid 7.2); interfaces ens33 = NAT, ens37 = lab.
- The repo is public (so the VMs can clone it): nothing private goes in it.
- Never add credentials, tokens or real hostnames/IPs from client environments.
- Anthropic requirements are from the support articles linked in CHECKLIST.md
  §References; re-fetch them before changing anything that claims to be a requirement.
  Only the CVP Security Requirements are mandatory (individuals: §3 plus Incident
  Reporting, Cooperation, Ongoing Review); the containment articles are recommendations.
- Claude Code policy lives in kali/managed-settings.json, installed root-owned to
  /etc/claude-code/; engagements start with `cvp-run <hours>`, scope with `cvp-scope`.
- Engagement material (findings, notes, transcripts) never goes in this repo.
- Config files are hand-written; nftables.conf and cvp-scope.nft pass `nft -c`, scripts
  pass `bash -n` and shellcheck, managed-settings.json parses. squid.conf with all three
  allow-lists passes `squid -k parse` and a loopback CONNECT test on Squid 7.2 (Ubuntu
  26.04 package). setup-kali.sh, cvp-run and cvp-scope have not been run on Kali yet.
  Windows targets are configured by hand (no scripts).