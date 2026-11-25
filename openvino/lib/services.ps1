# Windows service control. Dot-sourced by common.ps1.

function Stop-ServiceIfRunning([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Info "Stopping service $Name"
        Stop-Service -Name $Name -Force
    }
}

# Stops and deletes service $Name, waiting up to 30 s for it to go.
function Remove-ServiceIfPresent([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    & sc.exe delete $Name | Out-Null
    for ($i = 0; $i -lt 30 -and (Get-Service -Name $Name -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
}

# Restarts service $Name 10 s after a failure (30 s from the third), with the
# failure count reset daily. failureflag 1 also applies these actions when the
# service stops with an error rather than crashing.
function Set-RestartOnFailure([string]$Name) {
    & sc.exe failure $Name reset= 86400 actions= restart/10000/restart/10000/restart/30000 | Out-Null
    & sc.exe failureflag $Name 1 | Out-Null
}
