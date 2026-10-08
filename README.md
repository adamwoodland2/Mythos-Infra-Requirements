# cvp-lab

Build files for a VMware Workstation lab that runs Claude Code (Kali) against local
Windows targets under the Anthropic Cyber Verification Program, **Defense Access for
Individuals** tier.

> **Personal use only.** These are my own build files for my own lab. The repo is
> public only so the lab VMs can clone it without credentials. It isn't maintained
> for anyone else, comes with no support or warranty, and isn't affiliated with or
> endorsed by Anthropic.

Based on documentation at https://support.claude.com/en/articles/17317514-agent-containment-best-practices-for-cvp-participants and https://support.claude.com/en/articles/17202708-cyber-verification-program-security-requirements.

Start with [CHECKLIST.md](CHECKLIST.md). Everything else is a drop-in file it points at.

```
gateway/   egress gateway VM: nftables, Squid, allow-lists, mode switch, logrotate, installer
kali/      Claude Code sandbox VM: settings.json, CLAUDE.md template, net config, transcript sync, escape test
windows/   target VM: static-IP / no-egress PowerShell
```

Lab addressing assumed throughout (change in the files if you use something else):

| Host | IP |
|---|---|
| gateway (Squid :3128) | 10.0.3.1 |
| Kali / Claude Code | 10.0.3.11 |
| Windows target | 10.0.3.21-30 |

Nothing in this repo should ever contain a credential. The Kali OAuth token lives in
`~/.claude/.credentials.json` on the VM only, and the transcript sync deliberately
excludes it.
