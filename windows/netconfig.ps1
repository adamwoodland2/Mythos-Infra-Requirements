# netconfig.ps1  -  run as Administrator on the Windows target VM AFTER moving
# its network adapter from NAT to the "cvp-lab" LAN segment.
# Static IP, NO default gateway, NO DNS, NO proxy. The target has no reason to
# leave the lab segment. Do any licence activation / updates on NAT beforehand.

$ErrorActionPreference = 'Stop'
$ip   = '10.0.3.20'
$pref = 24

$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Write-Host "Configuring adapter: $($adapter.Name)"

# Clear any DHCP / previous config
Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
Set-NetIPInterface  -InterfaceIndex $adapter.ifIndex -Dhcp Disabled

# Static address, deliberately no -DefaultGateway
New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $pref | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses

# IPv6 off on this adapter (lab is IPv4 only)
Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue

# Make sure no WinHTTP / WinINET proxy is set
netsh winhttp reset proxy | Out-Null
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' ProxyEnable 0

# Hosts entries so the lab works without DNS
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
if (-not (Select-String -Path $hosts -Pattern 'cvp-gw' -Quiet)) {
    Add-Content $hosts "`n10.0.3.1`tcvp-gw`n10.0.3.10`tkali-cvp"
}

Write-Host "Done. Verify:  Test-NetConnection 10.0.3.10 ; Test-NetConnection 8.8.8.8 (should FAIL)"
