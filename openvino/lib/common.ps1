# Helpers shared by join-network.ps1, install.ps1, uninstall.ps1 and the
# scripts. Dot-source this file; it loads the other helper files in lib\.

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }

# Runs a native program and returns its output as strings. Windows PowerShell
# 5.1 turns native stderr into a terminating error under
# ErrorActionPreference=Stop, so it is relaxed here; callers check
# $LASTEXITCODE.
function Invoke-Native {
    $ErrorActionPreference = 'Continue'
    $exe = $args[0]
    # An array, so that a single remaining argument is still splatted.
    $rest = @($args | Select-Object -Skip 1)
    & $exe @rest 2>&1 | ForEach-Object { "$_" }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunches a script elevated through UAC with the given parameters, waits
# for it, and returns its process.
function Start-Elevated([string]$ScriptPath, [Collections.IDictionary]$Parameters) {
    Write-Host 'Administrator rights needed; relaunching elevated (approve the UAC prompt)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]
        if ($v -is [switch]) {
            if ($v) { $argList += "-$k" }
        } else {
            $argList += "-$k", "`"$v`""
        }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
}

foreach ($helper in 'network', 'components', 'services', 'selftest') {
    . (Join-Path $PSScriptRoot "$helper.ps1")
}
