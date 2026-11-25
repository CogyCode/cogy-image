# Address ranges, Windows Firewall rules and the private network. Dot-sourced
# by common.ps1.

function ConvertTo-UInt32([string]$Ip) {
    $b = ([Net.IPAddress]::Parse($Ip)).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0)
}

function ConvertFrom-UInt32([uint32]$Number) {
    $b = [BitConverter]::GetBytes($Number); [Array]::Reverse($b); ([Net.IPAddress]$b).ToString()
}

function Test-InRange([string]$Ip, [string]$Cidr) {
    $net, $bits = $Cidr -split '/'
    $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - [int]$bits))
    ((ConvertTo-UInt32 $Ip) -band $mask) -eq ((ConvertTo-UInt32 $net) -band $mask)
}

# The first and last address of an address or CIDR range, as numbers.
function Get-AddressRange([string]$Entry) {
    $net, $bits = $Entry -split '/'
    $ip = [int64](ConvertTo-UInt32 $net)
    $size = if ($bits) { [int64][math]::Pow(2, 32 - [int]$bits) } else { [int64]1 }
    $start = $ip - ($ip % $size)
    , @($start, ($start + $size - 1))
}

# A CIDR range as Windows Firewall lists it (address/mask, such as 10.0.0.0/255.0.0.0); a
# single address unchanged.
function ConvertTo-Netmask([string]$Entry) {
    $net, $bits = $Entry -split '/'
    if (-not $bits) { return $Entry }
    $mask = [int64][math]::Pow(2, 32) - [int64][math]::Pow(2, 32 - [int]$bits)
    "$net/$(ConvertFrom-UInt32 $mask)"
}

# The IPv4 ranges ("a.b.c.d-e.f.g.h") outside every entry of $Allow, for a
# firewall block rule. Block rules win over any allow rule, including program
# rules Windows may create, so everything else is blocked explicitly.
function Get-BlockRanges([string[]]$Allow) {
    $ranges = @($Allow | ForEach-Object { , (Get-AddressRange $_) } | Sort-Object { $_[0] })
    $blocks = @()
    $next = [int64]1                      # 0.0.0.0 is not a source address
    $last = [int64][uint32]::MaxValue - 1 # nor is 255.255.255.255
    foreach ($r in $ranges) {
        if ($r[0] -gt $next) { $blocks += (ConvertFrom-UInt32 $next) + '-' + (ConvertFrom-UInt32 ([math]::Min($r[0] - 1, $last))) }
        if ($r[1] + 1 -gt $next) { $next = $r[1] + 1 }
    }
    if ($next -le $last) { $blocks += (ConvertFrom-UInt32 $next) + '-' + (ConvertFrom-UInt32 $last) }
    $blocks
}

# Replaces the rule group with an allow rule for $AllowFrom on TCP $Port and
# a block rule for every other IPv4 source. The service listens on an IPv4
# address only, so IPv6 needs no rule.
function Install-FirewallRules([string]$Group, [int]$Port, [string[]]$AllowFrom) {
    Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Group $Group -DisplayName "$Group API (allow)" `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress $AllowFrom -Profile Any | Out-Null
    $others = @(Get-BlockRanges $AllowFrom)
    if ($others.Count) {
        New-NetFirewallRule -Group $Group -DisplayName "$Group API (block all others)" `
            -Direction Inbound -Action Block -Protocol TCP -LocalPort $Port -RemoteAddress $others -Profile Any | Out-Null
    }
}

function Get-TailscaleExe { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }

# This PC's address on Cogy Server's private network, or $null when not joined.
function Get-PrivateIp([string]$Range) {
    $ts = Get-TailscaleExe
    if (-not (Test-Path $ts)) { return $null }
    $ip = @(Invoke-Native $ts ip -4 | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\.\d+\s*$' })
    $ip = if ($ip.Count) { $ip[0].Trim() } else { $null }
    if (-not $ip -or -not (Test-InRange $ip $Range)) { return $null }
    $ip
}
