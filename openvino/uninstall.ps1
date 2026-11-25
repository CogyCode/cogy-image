<#
.SYNOPSIS
    Removes Cogy Image, as installed by install.ps1.

.DESCRIPTION
    Removes the Windows services (the image service and the model server) and
    the firewall rules. Files (OVMS, model, logs) are kept unless -RemoveFiles
    is given, so a re-install does not download the model again. The PC stays
    on Cogy Server's private network; run "tailscale logout" to leave it.

.PARAMETER RemoveFiles
    Also delete the install directory (OVMS, model, cache, logs).

.PARAMETER InstallDir
    Install directory used by install.ps1. Default %ProgramData%\<InstallDirName>.
#>
[CmdletBinding()]
param(
    [switch]$RemoveFiles,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'config\settings.psd1')
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramData $S.InstallDirName }

if (-not (Test-Admin)) {
    $p = Start-Elevated $PSCommandPath $PSBoundParameters
    exit $p.ExitCode
}

foreach ($name in $S.ServiceName, $S.OvmsServiceName) {
    if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
        Write-Host "Removing service $name"
        Remove-ServiceIfPresent $name
    }
}

$rules = Get-NetFirewallRule -Group $S.FirewallGroup -ErrorAction SilentlyContinue
if ($rules) {
    Write-Host "Removing firewall rules ($($S.FirewallGroup))"
    $rules | Remove-NetFirewallRule
}

if ($RemoveFiles -and (Test-Path $InstallDir)) {
    Write-Host "Deleting $InstallDir"
    Remove-Item -Recurse -Force $InstallDir
}

Write-Host "$($S.Name) uninstalled." -ForegroundColor Green
