# Read-only validation for a Windows target VM.
#
# Run in Windows PowerShell after the gateway and Kali VMs are online:
#   powershell.exe -ExecutionPolicy Bypass -File .\validation\validate-windows.ps1
#
# No configuration is changed. The script exits 0 only when every check passes,
# otherwise it exits 1.

[CmdletBinding()]
param(
    [string]$GatewayIP = '10.0.3.1',
    [string]$KaliIP = '10.0.3.11',
    [string]$ExternalTestIP = '1.1.1.1',
    [ValidateRange(500, 10000)]
    [int]$TimeoutMs = 3000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0

function Write-Pass {
    param([string]$Message)
    Write-Host "PASS  $Message" -ForegroundColor Green
    $script:PassCount++
}

function Write-Fail {
    param([string]$Message)
    Write-Host "FAIL  $Message" -ForegroundColor Red
    $script:FailCount++
}

function Invoke-Check {
    param(
        [string]$Description,
        [scriptblock]$Test
    )

    try {
        $result = & $Test
        if ($result -eq $true) {
            Write-Pass $Description
        }
        else {
            Write-Fail $Description
        }
    }
    catch {
        Write-Fail "$Description ($($_.Exception.Message))"
    }
}

function Test-TcpPort {
    param(
        [string]$Address,
        [int]$Port
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMs)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

Write-Host 'CVP Windows target validation (read-only)'
Write-Host ''
Write-Host 'Scope: automated guest and network checks only. Account controls, VMware UI'
Write-Host 'settings and gateway log retention still require manual review.'
Write-Host ''

$upAdapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
$upInterfaceIndexes = @($upAdapters | ForEach-Object { $_.ifIndex })

$activeIPv4 = @(
    foreach ($index in $upInterfaceIndexes) {
        Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' }
    }
)

Invoke-Check 'exactly one network adapter is active' {
    return $upAdapters.Count -eq 1
}

Invoke-Check 'the active adapter has exactly one address in 10.0.3.21-30/24' {
    if ($activeIPv4.Count -ne 1) {
        return $false
    }
    return ($activeIPv4[0].IPAddress -match '^10\.0\.3\.(2[1-9]|30)$') -and
        ($activeIPv4[0].PrefixLength -eq 24)
}

Invoke-Check 'DHCP is disabled on every active adapter' {
    foreach ($index in $upInterfaceIndexes) {
        $interfaces = @(Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4)
        if ($interfaces.Count -eq 0) {
            return $false
        }
        foreach ($interface in $interfaces) {
            if ([string]$interface.Dhcp -ne 'Disabled') {
                return $false
            }
        }
    }
    return $upInterfaceIndexes.Count -gt 0
}

Invoke-Check 'no IPv4 default route exists' {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    return $routes.Count -eq 0
}

Invoke-Check 'no IPv6 default route exists' {
    $routes = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
    return $routes.Count -eq 0
}

Invoke-Check 'IPv6 is disabled on every active adapter' {
    foreach ($adapter in $upAdapters) {
        $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6'
        if ($binding.Enabled) {
            return $false
        }
    }
    return $upAdapters.Count -gt 0
}

Invoke-Check 'no DNS server is configured on an active adapter' {
    $servers = @(
        @(
            foreach ($index in $upInterfaceIndexes) {
                foreach ($family in 'IPv4', 'IPv6') {
                    $entry = Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily $family -ErrorAction SilentlyContinue
                    if ($null -ne $entry) {
                        $entry.ServerAddresses
                    }
                }
            }
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    return $servers.Count -eq 0
}

Invoke-Check 'WinINET proxy is disabled for the current user' {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $settings = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    if ($null -eq $settings -or $null -eq $settings.PSObject.Properties['ProxyEnable']) {
        return $true
    }
    return [int]$settings.ProxyEnable -eq 0
}

Invoke-Check 'WinHTTP is configured for direct access with no proxy' {
    $output = (& netsh winhttp show proxy 2>&1 | Out-String)
    return $output -match 'Direct access\s*\(no proxy server\)'
}

Invoke-Check 'no proxy environment variable is set' {
    $names = 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $false
        }
    }
    return $true
}

Invoke-Check "gateway $GatewayIP responds on the lab segment" {
    return [bool](Test-Connection -ComputerName $GatewayIP -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

Invoke-Check "Kali $KaliIP responds on the lab segment" {
    return [bool](Test-Connection -ComputerName $KaliIP -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

Invoke-Check "gateway proxy $GatewayIP`:3128 is not reachable from the Windows target" {
    return -not (Test-TcpPort -Address $GatewayIP -Port 3128)
}

Invoke-Check "gateway SSH $GatewayIP`:22 is not reachable from the Windows target" {
    return -not (Test-TcpPort -Address $GatewayIP -Port 22)
}

Invoke-Check "direct external TCP access to $ExternalTestIP`:443 is blocked" {
    return -not (Test-TcpPort -Address $ExternalTestIP -Port 443)
}

Write-Host ''
Write-Host "Summary: $($script:PassCount) passed, $($script:FailCount) failed"
if ($script:FailCount -eq 0) {
    Write-Host 'ALL AUTOMATED CHECKS PASSED' -ForegroundColor Green
    exit 0
}

Write-Host 'VALIDATION FAILED' -ForegroundColor Red
exit 1
