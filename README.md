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
gateway/   egress gateway VM: nftables, Squid, allow-lists, mode switch, transcript drop-box,
           snapshots and review, logrotate, installer
kali/      Claude Code sandbox VM: setup script, managed settings, scope firewall, cvp-run
           launcher, net config, transcript sync, CLAUDE.md template, escape test
```

Windows targets are configured by hand (CHECKLIST §5).

Lab addressing assumed throughout (change in the files if you use something else):

| Host | IP |
|---|---|
| gateway (Squid :3128) | 10.0.3.1 |
| Kali / Claude Code | 10.0.3.11 |
| Windows targets (as many as needed) | 10.0.3.21-30 |

Nothing in this repo should ever contain a credential or engagement material. The
Kali OAuth token lives in `~/.claude/.credentials.json` on the VM only, and the
transcript sync deliberately excludes it. Engagement directories live outside the
clone (e.g. `~/engagements/<name>`).
