<#
.SYNOPSIS
    Installs Cogy Image: a vision-language model on OpenVINO Model Server,
    behind a small service on this PC's private network address, started at
    boot and restarted on failure. Names, ports and model: config\settings.psd1.

.DESCRIPTION
    Run join-network.ps1 first: this PC must be on Cogy Server's private network.
    Needs nothing preinstalled. Safe to re-run; each step is skipped when done.
      1. OpenVINO Model Server (pinned version, SHA-256 checked)
      2. Model download (ModelId, from Hugging Face)
      3. OVMS config and graph; context length and largest image size
      4. Check: this PC is on Cogy Server's private network
      5. Windows Firewall: the API port is reachable only from AllowFrom
      6. Python (embeddable) and the image service (image\*.py)
      7. Windows services: the model server on 127.0.0.1, the image service
         on the private address; automatic start, restart on failure
      8. Self-test (scripts\verify.ps1 -SelfTest): /health, POST /inspect
         with a generated screenshot, OpenAI passthrough

.PARAMETER InstallDir
    Where OVMS, the model, config and logs go. Default %ProgramData%\<InstallDirName>.

.PARAMETER ModelId
    OpenVINO vision model on Hugging Face. Default: ModelId in config\settings.psd1.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$ModelId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoDir = $PSScriptRoot
. (Join-Path $RepoDir 'lib\common.ps1')
$S = Import-PowerShellDataFile (Join-Path $RepoDir 'config\settings.psd1')
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramData $S.InstallDirName }

# Checked before elevating so the messages reach the caller's console.
if (-not @($S.AllowFrom | Where-Object { $_ }).Count) {
    Write-Host "AllowFrom is empty: set it to Cogy Server's private address in config\settings.psd1, then re-run." -ForegroundColor Red
    exit 1
}
if (-not (Get-PrivateIp $S.PrivateRange)) {
    Write-Host ("This PC is not on Cogy Server's private network. Run join-network.ps1 first; it installs Tailscale and joins the network:`n" +
                "    .\join-network.ps1 -LoginServer http://<server-ip>:8780 -AuthKey <key>") -ForegroundColor Red
    exit 1
}

if (-not (Test-Admin)) {
    $p = Start-Elevated $PSCommandPath $PSBoundParameters
    $log = Join-Path $InstallDir 'logs\install.log'
    if (Test-Path $log) { Get-Content $log -Tail 40 }
    exit $p.ExitCode
}

if (-not $ModelId) { $ModelId = $S.ModelId }
$OvmsDir    = Join-Path $InstallDir 'ovms'
$OvmsExe    = Join-Path $OvmsDir 'ovms.exe'
$ModelsDir  = Join-Path $InstallDir 'models'
$ModelDir   = Get-ModelDir $ModelsDir $ModelId
$CacheDir   = Join-Path $InstallDir 'cache'
$LogDir     = Join-Path $InstallDir 'logs'
$ConfigPath = Join-Path $InstallDir 'config.json'
$PythonDir  = Join-Path $InstallDir 'python'
$PythonExe  = Join-Path $PythonDir 'python.exe'
$ServiceDir = Join-Path $InstallDir 'image'
$WinSWDir   = Join-Path $InstallDir 'service'

foreach ($d in $InstallDir, $ModelsDir, $CacheDir, $LogDir) { New-Item -ItemType Directory -Force $d | Out-Null }
Protect-InstallDir $InstallDir

Start-Transcript -Path (Join-Path $LogDir 'install.log') -Force | Out-Null

try {
    Write-Step "Install directory $InstallDir"
    # Stop a running instance before replacing anything it uses.
    Stop-ServiceIfRunning $S.ServiceName
    Stop-ServiceIfRunning $S.OvmsServiceName

    # --- 1. OpenVINO Model Server --------------------------------------------
    Write-Step "OpenVINO Model Server $($S.OvmsVersion)"
    Install-Ovms $OvmsDir (Join-Path $InstallDir 'download') $S

    # --- 2. Model ------------------------------------------------------------
    Write-Step "Model $ModelId"
    Install-Model $ModelId $ModelsDir $OvmsExe
    Remove-UnusedModels $ModelsDir $ModelDir

    # --- 3. Config -----------------------------------------------------------
    Write-Step 'OVMS configuration'
    $json = (Get-Content (Join-Path $RepoDir 'config\config.json') -Raw).Replace('@MODEL_ID@', $ModelId)
    [IO.File]::WriteAllText($ConfigPath, $json)
    Copy-Item (Join-Path $RepoDir 'config\graph.pbtxt') (Join-Path $ModelDir 'graph.pbtxt') -Force
    Write-Info 'config.json and graph.pbtxt installed'

    Set-ModelContextLength $ModelDir $S.ContextLength
    Write-Info "Context length $($S.ContextLength)"

    # A 4K screenshot would otherwise cost about 8,000 image tokens.
    if (Set-ModelMaxImagePixels $ModelDir $S.MaxImagePixels) { Write-Info "Largest image $($S.MaxImagePixels) pixels" }
    else { Write-Info 'No image size setting found: the model''s own largest image size applies' }

    # --- 4. Private network --------------------------------------------------
    Write-Step "Cogy Server's private network"
    $PrivateIp = Get-PrivateIp $S.PrivateRange
    if (-not $PrivateIp) { throw 'This PC is not on the private network; run join-network.ps1 first' }
    Write-Info "Private address: $PrivateIp"

    # --- 5. Firewall ---------------------------------------------------------
    $allowFrom = @($S.AllowFrom)
    Write-Step "Firewall: port $($S.Port) from $($allowFrom -join ', ') only"
    Install-FirewallRules $S.FirewallGroup $S.Port $allowFrom
    Write-Info 'Rules installed'

    # --- 6. Python and the image service -------------------------------------
    Write-Step "Python $($S.PythonVersion) (embeddable, standard library only)"
    Install-EmbeddablePython $PythonDir $S
    Write-Info (Invoke-Native $PythonExe --version)

    Write-Step "$($S.Name) service code"
    New-Item -ItemType Directory -Force $ServiceDir | Out-Null
    Get-ChildItem (Join-Path $RepoDir 'image') -File -Filter '*.py' | Where-Object Name -notlike 'test_*' |
        Copy-Item -Destination $ServiceDir -Force
    Copy-Item (Join-Path $RepoDir 'config\inspect-prompt.txt') $ServiceDir -Force
    $ServiceConfig = Join-Path $ServiceDir 'image.json'
    $serviceCfg = [ordered]@{
        bind            = $PrivateIp
        port            = $S.Port
        upstream        = "http://127.0.0.1:$($S.OvmsPort)"
        model           = $ModelId
        prompt_file     = Join-Path $ServiceDir 'inspect-prompt.txt'
        max_tokens      = $S.MaxTokens
        max_image_bytes = $S.MaxImageBytes
        timeout         = $S.RequestTimeout
        log_file        = Join-Path $LogDir 'image.log'
    }
    [IO.File]::WriteAllText($ServiceConfig, ($serviceCfg | ConvertTo-Json))
    Write-Info "Installed to $ServiceDir"

    # --- 7. Services ---------------------------------------------------------
    Remove-ServiceIfPresent $S.ServiceName
    Remove-ServiceIfPresent $S.OvmsServiceName

    # The model server listens on localhost only: the image service is its only client.
    Write-Step "Windows service $($S.OvmsServiceName) (model server, 127.0.0.1:$($S.OvmsPort))"
    $bin = "`"$OvmsExe`" --config_path `"$ConfigPath`" --rest_port $($S.OvmsPort) --rest_bind_address 127.0.0.1 " +
           "--port 0 --cache_dir `"$CacheDir`" --log_level INFO --log_path `"$(Join-Path $LogDir 'ovms.log')`""
    New-Service -Name $S.OvmsServiceName -DisplayName $S.OvmsDisplayName -BinaryPathName $bin -StartupType Automatic `
        -Description "Model server for $($S.Name): $ModelId on http://127.0.0.1:$($S.OvmsPort)" | Out-Null
    Set-RestartOnFailure $S.OvmsServiceName
    Start-Service -Name $S.OvmsServiceName
    Write-Info 'Started'

    # WinSW runs the image service with a delayed start after the model server
    # and Tailscale, since it binds to the private address.
    Write-Step "Windows service $($S.ServiceName) ($($S.Name), http://$($PrivateIp):$($S.Port))"
    New-Item -ItemType Directory -Force $WinSWDir | Out-Null
    $wrapper = Join-Path $WinSWDir "$($S.ServiceName).exe"
    Get-VerifiedFile $S.WinSWUrl $S.WinSWSha256 $wrapper
    $xml = (Get-Content (Join-Path $RepoDir 'config\service.xml') -Raw).
        Replace('@SERVICE_NAME@', $S.ServiceName).
        Replace('@DISPLAY_NAME@', $S.ServiceDisplayName).
        Replace('@DESCRIPTION@', "$($S.Name) ($($S.Role)) on http://$($PrivateIp):$($S.Port)").
        Replace('@PYTHON@', $PythonExe).
        Replace('@SERVICE_PY@', (Join-Path $ServiceDir 'image.py')).
        Replace('@SERVICE_CONFIG@', $ServiceConfig).
        Replace('@SERVICE_DIR@', $ServiceDir).
        Replace('@OVMS_SERVICE@', $S.OvmsServiceName).
        Replace('@LOG_DIR@', $LogDir)
    [IO.File]::WriteAllText((Join-Path $WinSWDir "$($S.ServiceName).xml"), $xml)
    $out = Invoke-Native $wrapper install
    if ($LASTEXITCODE -ne 0) { throw "WinSW install failed ($LASTEXITCODE): $($out -join ' ')" }
    Set-RestartOnFailure $S.ServiceName
    Start-Service -Name $S.ServiceName
    Write-Info 'Started'

    # --- 8. Self-test --------------------------------------------------------
    Write-Step 'Self-test'
    & (Join-Path $RepoDir 'scripts\verify.ps1') -SelfTest -InstallDir $InstallDir
    if ($LASTEXITCODE -ne 0) { throw "Self-test failed; see $LogDir (image.log, ovms.log)" }

    $base = "http://$($PrivateIp):$($S.Port)"
    Write-Host ''
    Write-Host "$($S.Name) is installed." -ForegroundColor Green
    Write-Host "  Inspect: POST $base/inspect   {`"image`": `"<base64>`", `"caption`": `"...`"}"
    Write-Host "  Health:  GET  $base/health"
    Write-Host "  OpenAI:  POST $base/v3/chat/completions, GET $base/v3/models"
    Write-Host "  Model:   $ModelId  (context $($S.ContextLength))"
    Write-Host "  Logs:    $LogDir"
    $exit = 0
}
catch {
    Write-Host "`nINSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $exit = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $exit
