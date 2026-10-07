# cvp-lab

Build files for an isolated VMware Workstation lab running Claude Code (Kali) under
the Anthropic Cyber Verification Program, Defense Access for Individuals tier.
Read CHECKLIST.md first - it is the source of truth and links every file.

Conventions:
- British English, hyphens not dashes, $ = AUD.
- Lab addressing: gateway 10.0.3.1, Kali 10.0.3.10, Windows target 10.0.3.20.
- Never add credentials, tokens or real hostnames/IPs from client environments.
- Anthropic requirements are from the two support articles linked in CHECKLIST.md
  §References; re-fetch them before changing anything that claims to be a requirement.
- Config files are hand-written; nftables.conf passes `nft -c`, scripts pass `bash -n`,
  settings.json parses. Squid and PowerShell have not been executed yet.