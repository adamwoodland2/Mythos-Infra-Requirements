# CVP lab build runbook

Do the steps in order. Each step says what to do and what you should see. If you don't see it, stop and sort that out before going on.

Part 1 is required by the CVP Security Requirements; the rest is Anthropic's recommended containment practice, which this lab follows. Addresses, files, logs and known gaps: [docs/reference.md](docs/reference.md). Why things are built this way: [docs/decisions.md](docs/decisions.md).

Addresses: gateway `10.0.3.1` (`ens33` NAT, `ens37` lab) · Kali `10.0.3.11` · Windows targets `10.0.3.21-30` (`win-app-01` ... `win-app-10`).

---

## 1. Account (required, once)

Anthropic retains and monitors all traffic under the grant; zero data retention isn't available.

1. **Sign in to claude.ai only with Google.**
   Expect: you always use *Continue with Google*, never *Continue with email* (that's the magic-link sign-in the requirements rule out).
2. **Turn on 2-Step Verification on that Google account.**
   Expect: myaccount.google.com → Security shows 2-Step Verification *On*.
3. **Add a passkey or security key to the Google account** (required by 15 Dec 2026; a second one as a backup is sensible).
   Expect: it is listed under *Passkeys and security keys*.
4. **Remove the weaker Google second steps** (text message, Authenticator app, Google prompts), or enrol in Google's Advanced Protection Program.
   Expect: only passkeys or security keys are left, so there is no phishable fallback.
5. **Don't create an API key.** Claude Code uses the claude.ai login. If one is ever unavoidable before 15 Dec 2026: one key, kept in a password manager, never shared or put in code, replaced every 7 days, and gone by that date.
   Expect: no `ANTHROPIC_API_KEY` anywhere (`cvp-run` refuses to start if it finds one).
6. **Keep access personal.** Nobody else uses the account or the Kali session.
7. **Write down the incident timers** where you'll see them: suspected breach or misuse → report within 72 h; security incident → within 24 h; to `security@anthropic.com` or your account team. Investigate abuse Anthropic flags within 48 h; answer misuse enquiries within 7 days.
8. **Keep the evidence.** Anthropic may ask for proof of compliance: keep this repo's history, the escape-test reports and the gateway logs.

---

## 2. VMware networking (once)

1. **Create the LAN segment.** Any VM → Settings → Network Adapter → *LAN segment* → *LAN Segments...* → Add `cvp-lab`.
   Expect: `cvp-lab` can be selected on every VM.
2. **Gateway VM: two adapters.** Adapter 1 = NAT. Adapter 2 = LAN segment `cvp-lab`.
3. **Kali VM: one adapter, NAT for now.** It moves to `cvp-lab` in §6.
4. **Each Windows target VM: one adapter, NAT for now.** It moves to `cvp-lab` in §4.

---

## 3. Gateway VM

Ubuntu Server 26.04, 1 vCPU, 1 GB RAM, 20 GB disk.

1. **Install Ubuntu Server 26.04** with both adapters attached. If the installer can't configure the second adapter (there's no DHCP on `cvp-lab`), leave it unconfigured.
   Expect: you can log in at the VMware console. Manage the gateway from the console from now on.
2. **Check the interface names.**
   ```
   ip -br link
   ```
   Expect: `lo`, `ens33` and `ens37`.
   If not: note the names and put them in front of the command in step 4, e.g. `sudo WAN_IF=ens33 LAN_IF=ens38 bash ...`.
3. **Clone this repo.**
   ```
   git clone https://github.com/adamwoodland2/Mythos-Infra-Requirements ~/Mythos-Infra-Requirements
   ```
   Expect: `~/Mythos-Infra-Requirements` exists.
4. **Run the installer.**
   ```
   sudo bash ~/Mythos-Infra-Requirements/gateway/install-gateway.sh
   ```
   Expect: `WAN (NAT) = ens33, LAN (cvp-lab) = ens37`, then `[1/7]` to `[7/7]`, then `Done.`
   If not: fix what the error says and run it again; it is safe to re-run.
5. **Check the firewall.**
   ```
   sudo nft list ruleset | grep policy
   sysctl net.ipv4.ip_forward
   ```
   Expect: `policy drop` twice (input, forward) and `policy accept` once (output); then `net.ipv4.ip_forward = 0`.
6. **Check Squid.**
   ```
   sudo cvp-mode status
   ```
   Expect: `Active allow-list -> /etc/squid/allowlist-run.txt`, and under `--- entries ---` only `api.anthropic.com` and `platform.claude.com`.
7. **Check the snapshot timer.**
   ```
   systemctl list-timers cvp-archive.timer
   ```
   Expect: one `cvp-archive.timer` line with a NEXT time within 5 minutes.
8. **Snapshot the gateway VM** in VMware. Leave it running.

---

## 4. Windows target VMs (repeat for each)

Up to ten targets: `win-app-01` = `10.0.3.21` ... `win-app-10` = `10.0.3.30`.

1. **On NAT, install the application,** activate any licences and run Windows Update.
   Expect: the application works and Windows Update shows nothing pending.
2. **Download the validation script** (in PowerShell, still on NAT).
   ```
   iwr https://raw.githubusercontent.com/adamwoodland2/Mythos-Infra-Requirements/main/validation/validate-windows.ps1 -OutFile C:\validate-windows.ps1
   ```
   Expect: `C:\validate-windows.ps1` exists.
3. **Shut down and move the VM into the lab** in VMware: the only adapter → LAN segment `cvp-lab`; Options → Guest Isolation → untick *drag and drop* and *copy and paste*; Options → Shared Folders → *Disabled*. Boot.
4. **Set the address** on the adapter (Settings → Network → Ethernet → IP assignment → Edit → Manual → IPv4 on): IP `10.0.3.2N` (`.21` for `win-app-01` ... `.30` for `win-app-10`), subnet mask `255.255.255.0`, gateway blank, DNS blank. IPv6 off.
   Expect: `ipconfig` shows that IPv4 address and no default gateway.
5. **Make sure there's no proxy.**
   ```
   netsh winhttp reset proxy
   ```
   Expect: `Direct access (no proxy server).` Also Settings → Network → Proxy: everything off.
6. **Check it can't get out.**
   ```
   Test-NetConnection 8.8.8.8
   Test-NetConnection 10.0.3.1 -Port 3128
   ```
   Expect: `PingSucceeded : False` for the first; `TcpTestSucceeded : False` for the second (the gateway proxy serves Kali only).
7. **Snapshot the VM** in VMware. Leave it running.

---

## 5. Kali VM - build (on NAT)

1. **Install Kali on the NAT adapter using DHCP.** Don't set a static address in the installer; §6 sets it.
   Expect: Kali boots to the desktop and has internet.
2. **Leave VMware copy and paste on for now** (Settings → Options → Guest Isolation). You need it to sign in during step 4.
3. **Clone this repo.**
   ```
   git clone https://github.com/adamwoodland2/Mythos-Infra-Requirements ~/Mythos-Infra-Requirements
   ```
   Expect: `~/Mythos-Infra-Requirements` exists.
4. **Run the build** as your normal user, not root.
   ```
   bash ~/Mythos-Infra-Requirements/kali/setup-kali.sh build
   ```
   Answer its questions:
   1. *Business name* → your business name.
   2. *Email of the claude.ai account* → your Google address.
   3. Sign-in → copy the URL it prints into a browser on the host, choose *Continue with Google*, finish with your key, and paste the code back into Kali.
      Expect: a status block showing you signed in with your Google address.
   4. Model → open a second terminal, run `claude`, type `/model`, highlight *Mythos 5.1*, press Enter, type `/exit`. Back in the first terminal press Enter, then Enter again to accept `claude-mythos-5-1`.
      Expect: `ok: claude-mythos-5-1 answered`.

   Expect at the end: `Sync key: 256 SHA256:... cvpsync@kali (ED25519)`, then `Done. Still on NAT:`.
   If not: the last line says why; fix it and run the same command again (it skips the sign-in once you're signed in).
5. **Install the engagement tooling** you will need: wordlists, Python/Go dependencies, anything installed with `pip` or `go install`. Nothing can be downloaded once Kali is in the lab.
   Expect: each tool runs. Don't start `claude` again until §6; it now expects the lab proxy.
6. **Shut Kali down.**

---

## 6. Kali VM - into the lab

1. **Move Kali into the lab** in VMware: adapter → LAN segment `cvp-lab` (remove any other adapter); Options → Guest Isolation → untick *drag and drop* and *copy and paste*; Options → Shared Folders → *Disabled*. Boot.
   Expect: `ip -br link` shows only `lo` and `eth0`.
2. **Run the lab setup.**
   ```
   bash ~/Mythos-Infra-Requirements/kali/setup-kali.sh lab
   ```
   Expect: `ok: eth0 = 10.0.3.11/24, no default route, no other addresses`, then `[2/4]` to `[4/4]`, then `Done.`
   If it says `NetworkManager doesn't manage eth0`: comment out the `eth0` lines in the file it shows (keep the `lo` lines), run `sudo nmcli device set eth0 managed yes`, then run step 2 again.
3. **Log out of the Kali desktop and back in** (this loads the proxy settings).
4. **Check the ways out.**
   ```
   ping -c1 8.8.8.8
   curl -sI https://example.com
   curl -skI https://8.8.8.8
   curl -sI https://api.anthropic.com
   ```
   Expect, in order:
   1. `Network is unreachable`
   2. `HTTP/1.1 403 Forbidden`
   3. `HTTP/1.1 403 Forbidden`
   4. `HTTP/1.1 200 Connection established` followed by a second status line from Anthropic (any status).
5. **Check the scope firewall** (with `win-app-01` running).
   ```
   ping -c1 win-app-01
   sudo cvp-scope set 10.0.3.21
   ping -c1 win-app-01
   sudo cvp-scope none
   ```
   Expect, in order:
   1. `Operation not permitted` (not in scope, so blocked)
   2. `In-scope targets: 10.0.3.21`
   3. `1 received`
   4. `In-scope targets:` with nothing after it
6. **Hand the transcript-sync key to the gateway.** On Kali:
   ```
   bash ~/Mythos-Infra-Requirements/kali/setup-kali.sh share-key
   ```
   Expect: `Serving the PUBLIC key ...` and a line `Its fingerprint must match: 256 SHA256:...`.

   Then on the gateway console:
   ```
   sudo cvp-enrol-key
   ```
   Expect: `Installed for cvpsync: 256 SHA256:...` with the same fingerprint as Kali shows. Then press Ctrl+C on Kali.
7. **Check transcripts reach the gateway.** On Kali:
   ```
   sync-transcripts
   systemctl is-active cvp-sync.timer
   ```
   Expect: `... transcripts synced to cvpsync@10.0.3.1:kali/`, then `active`.

   Then on the gateway:
   ```
   sudo systemctl start cvp-archive.service
   sudo ls /var/cvp/archive
   ```
   Expect: a timestamped folder such as `20261009T231500Z`, and `latest`.
8. **Check Claude Code starts cleanly.** On Kali:
   ```
   mkdir -p ~/engagements/self-check
   cp ~/Mythos-Infra-Requirements/kali/CLAUDE.md.no-targets ~/engagements/self-check/CLAUDE.md
   cd ~/engagements/self-check
   cvp-run 1
   ```
   Expect: every line `ok` (a `warn` about the VMware user agent is fine), then `All checks passed. Starting Claude Code with a 1h limit.`
   If not: each `FAIL` line says what to fix.
9. **Check the session settings.** In Claude Code type `/status`.
   Expect: Proxy `http://10.0.3.1:3128`, your Google address, model `claude-mythos-5-1`, and Auto Mode in the mode indicator. Type `/exit`.
10. **Check the Auto Mode rules.**
    ```
    claude auto-mode config
    ```
    Expect: your `environment`, `hard_deny` and `soft_deny` entries alongside the built-in ones.

---

## 7. Validate the whole lab

1. **Run the Kali checks** (with `win-app-01` running and nothing in scope).
   ```
   bash ~/Mythos-Infra-Requirements/validation/validate-kali.sh 10.0.3.21
   ```
   Expect: `ALL AUTOMATED CHECKS PASSED` (it reports `win-app-01` as blocked by cvp-scope).
2. **Run them again with the target in scope.**
   ```
   sudo cvp-scope set 10.0.3.21
   bash ~/Mythos-Infra-Requirements/validation/validate-kali.sh 10.0.3.21
   sudo cvp-scope none
   ```
   Expect: `ALL AUTOMATED CHECKS PASSED` (this time it reports `win-app-01` as responding).
3. **Run the Windows checks** on each target (PowerShell as Administrator).
   ```
   powershell -ExecutionPolicy Bypass -File C:\validate-windows.ps1
   ```
   Expect: `ALL AUTOMATED CHECKS PASSED`.
4. **Start watching the gateway logs** in a window you can see.
   ```
   sudo tail -f /var/log/squid/access.log /var/log/cvp-lab-nft.log
   ```
5. **Start the escape test.** On Kali:
   ```
   mkdir -p ~/engagements/escape-test
   cp ~/Mythos-Infra-Requirements/kali/CLAUDE.md.no-targets ~/engagements/escape-test/CLAUDE.md
   cd ~/engagements/escape-test
   cvp-run 1
   ```
   Expect: `All checks passed. Starting Claude Code with a 1h limit.`
6. **Paste the test prompt:** everything between the two `---` lines in [kali/escape-test-prompt.md](kali/escape-test-prompt.md). Watch it run.
   Expect: every attempt fails. The gateway window shows `TCP_DENIED` or `cvp-lab-...-drop` lines, and `journalctl -k | grep cvp-scope-drop` on Kali shows the blocked lab-host attempts. Claude writes `escape-test.md` and reports which controls held.
   If anything gets out: stop, fix it, and repeat steps 5 to 6.
7. **Keep `~/engagements/escape-test/escape-test.md`** as evidence (never in the repo).
8. **Take the Kali gold snapshot** in VMware.

---

## 8. Each engagement

Before:

1. **Restore the Kali gold snapshot** and the targets' snapshots.
2. **Check the gateway is in run mode.**
   ```
   sudo cvp-mode status
   ```
   Expect: `Active allow-list -> /etc/squid/allowlist-run.txt`.
3. **Make the engagement folder** on Kali (outside the repo clone).
   ```
   mkdir -p ~/engagements/<name> && cd ~/engagements/<name>
   cp ~/Mythos-Infra-Requirements/kali/CLAUDE.md.template CLAUDE.md
   ```
4. **Fill in `CLAUDE.md`:** engagement name, date, your name, authorisation reference, one row per in-scope target with its permitted actions. Delete the operator-notes paragraph.
5. **Set the scope firewall to the same IPs.**
   ```
   sudo cvp-scope set <IP> [<IP> ...]
   ```
   Expect: `In-scope targets:` followed by exactly the IPs in the CLAUDE.md table.
6. **Start watching the gateway logs.**
   ```
   sudo tail -f /var/log/squid/access.log /var/log/cvp-lab-nft.log
   ```
7. **Start Claude Code** with a time limit you choose for this engagement (1-12 hours).
   ```
   cvp-run <hours>
   ```
   Expect: `All checks passed. Starting Claude Code with a <hours>h limit.`

During:

8. **Watch the tool calls and the gateway logs.** Stop (Ctrl+C, or suspend the VM) on anything you can't explain: a `TCP_DENIED`, a `cvp-lab-...-drop`, or a `cvp-scope-drop` on Kali (`journalctl -kf | grep cvp-scope-drop`).
9. **On long runs, every hour or two,** on the gateway:
   ```
   sudo cvp-review 1
   ```
   Expect: `(none)` under integrity warnings. Read any `FLAGGED` session.
10. **Only replicas or test systems.** Never point it at production, especially OT/ICS, medical or energy systems.

After:

11. **Review the transcripts** on the gateway (`cvp-run` syncs when Claude Code exits).
    ```
    sudo cvp-review
    ```
    Expect: `(none)` under integrity warnings. Read every `FLAGGED` session and every one in the random sample. For a second opinion, paste them into a Claude session outside the lab.
12. **If anything was out of scope:** stop, keep the logs, tell your Anthropic account team (and `security@anthropic.com` within 24/72 h if it meets §1 step 7), and sign Claude Code out on Kali.
13. **Clear the scope.**
    ```
    sudo cvp-scope none
    ```
    Expect: `In-scope targets:` with nothing after it.

---

## 9. Maintenance

1. **Update Claude Code.**
   ```
   sudo cvp-mode update        # gateway
   claude update               # Kali
   sudo cvp-mode run           # gateway
   ```
   Expect: `Squid allow-list now: update`, Claude Code reports the new version, then `Squid allow-list now: run`. Then take a new Kali gold snapshot and repeat §7 steps 4 to 8.
2. **Update Kali tools:** rebuild from §5 on NAT. Don't widen the allow-list for package repos.
3. **Patch the gateway monthly.**
   ```
   sudo apt update && sudo apt upgrade
   ```
   Expect: upgrades install. If apt asks about a changed config file, keep your version.
4. **Sign in again inside the lab** (if Claude Code says the login expired, or after a snapshot restore): in VMware tick *copy and paste* for Kali; log out of the Kali desktop and back in; run `claude`, type `/login`, press `c`; finish in the host browser with *Continue with Google*; paste the code back; `/exit`; untick *copy and paste*.
   Expect: `claude auth status --text` shows you signed in.
5. **Every quarter:** re-read the Anthropic articles listed in [docs/reference.md](docs/reference.md#references), and run `claude auto-mode defaults` for new built-in rules.
6. **15 Dec 2026:** phishing-resistant MFA deadline (§1 step 3); no API keys after this date.
