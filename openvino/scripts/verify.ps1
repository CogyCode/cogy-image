<#
.SYNOPSIS
    Checks that the installed Cogy Image meets its requirements.

.DESCRIPTION
    - Services: running, automatic start after OVMS and Tailscale, restart on failure
    - Network: the service listens on the private address only, OVMS on 127.0.0.1 only
      (from Windows' listener list, or by connecting to each local address
      when that list has no entry for the port)
    - Firewall: the API port is allowed from AllowFrom only
    - API: /health, POST /inspect reads a generated screenshot, bad input is
      refused, model listed, chat passthrough with text and with an image, a
      passthrough image given as a file path is refused
    - Images: a 4K screenshot is scaled down to the largest image size
    - Parallel: 2 requests are scheduled together
    - Context: a prompt just under the limit is served; one just over is refused
    - Crash recovery (-TestRestart): kills both processes and waits for the
      services to bring them back

    Needs administrator rights (asks through UAC), except with -SelfTest.
    Output also goes to %ProgramData%\CogyImage\logs\verify.log.

.PARAMETER SelfTest
    Runs only the API checks, as install.ps1's self-test: waits for /health,
    has POST /inspect read a generated screenshot, and sends a chat
    completion. Needs no administrator rights and writes no verify.log.

.PARAMETER TestRestart
    Also kills both processes and checks that the services bring them back.

.PARAMETER SkipContext
    Skips the context length checks.

.PARAMETER InstallDir
    Install directory used by install.ps1. Default %ProgramData%\<InstallDirName>.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$TestRestart,
    [switch]$SkipContext,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\settings.psd1')
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramData $S.InstallDirName }
$log = Join-Path $InstallDir 'logs\verify.log'
# How long the API checks wait for /health, and how often they poll it: the
# model may still be loading, or compiling for the GPU on its first start.
$ReadyMinutes = 15
$ReadyPollSec = 5
# How long a listen check waits for each connection when it has to connect.
$ConnectTimeoutMs = 2000

if (-not $SelfTest -and -not (Test-Admin)) {
    $p = Start-Elevated $PSCommandPath $PSBoundParameters
    if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '^(PASS|FAIL|INFO|  |Result)' } }
    exit $p.ExitCode
}

$failures = 0

# Prints a check's result and counts the failures.
function Write-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "PASS  $Name  $Detail" } else { Write-Host "FAIL  $Name  $Detail"; $script:failures++ }
}

# The HTTP status of a web request: 200 when it succeeds, 0 when there is no answer.
function Get-Status([scriptblock]$Request) {
    try { $null = & $Request; 200 } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } }
}

# Sends a chat completion through the passthrough and returns the web response.
function Invoke-Chat([string]$BaseUrl, [string]$Model, $Content, [int]$MaxTokens) {
    $body = @{ model = $Model; max_tokens = $MaxTokens; temperature = 0
               messages = @(@{ role = 'user'; content = $Content }) } | ConvertTo-Json -Depth 6
    Invoke-WebRequest "$BaseUrl/v3/chat/completions" -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 600
}

# The text of a chat completion response, trimmed, or ''.
function Get-Answer($Response) {
    $r = $Response.Content | ConvertFrom-Json
    "$($r.choices[0].message.content)".Trim()
}

# Chat content asking for the text of the test screenshot's button.
function New-ButtonQuestion([byte[]]$Png) {
    @(@{ type = 'text'; text = 'What is written on the blue button? Reply with the text only.' },
      @{ type = 'image_url'; image_url = @{ url = 'data:image/png;base64,' + [Convert]::ToBase64String($Png) } })
}

# Seconds to read the button of a $Width x $Height test screenshot.
function Read-Time([string]$BaseUrl, [string]$Model, [int]$Width, [int]$Height) {
    $img = New-TestScreenshot "Run $(Get-Random)" 'Save changes' -Width $Width -Height $Height
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-Chat $BaseUrl $Model (New-ButtonQuestion $img) 8
    $sw.Elapsed.TotalSeconds
}

# $Count words drawn at random from a list of UI words, as one string.
function New-RandomText([int]$Count) {
    $words = 'button form field label error banner window panel menu table list icon link page title'.Split(' ')
    $rng = New-Object Random
    (1..$Count | ForEach-Object { $words[$rng.Next($words.Length)] }) -join ' '
}

# The process ID of the python.exe running image.py, or $null.
function Get-ImageServicePid {
    $py = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object CommandLine -match 'image\.py' | Select-Object -First 1
    if ($py) { $py.ProcessId } else { $null }
}

# The checks install.ps1 runs as its self-test. Returns the test screenshot.
function Test-Api([string]$BaseUrl, [string]$Model) {
    $ready = Wait-Ready $BaseUrl $ReadyMinutes $ReadyPollSec
    Write-Check 'GET /health' $ready $(if ($ready) { 'ready' } else { "not ready within $ReadyMinutes minutes" })

    # No caption, so the text in the findings can only come from the image.
    $png = New-TestScreenshot 'Payment failed' 'Save changes'
    $body = @{ image = [Convert]::ToBase64String($png) } | ConvertTo-Json
    $r = Invoke-RestMethod "$BaseUrl/inspect" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $S.RequestTimeout
    $findings = "$($r.findings)"
    $read = $findings -match 'Payment failed' -and $findings -match 'Save changes'
    Write-Check 'POST /inspect reads the test screenshot' $read "$($r.seconds) s"
    if ($read) { Write-Host "INFO  findings: $($findings.Substring(0, [math]::Min(300, $findings.Length)))" }

    $ans = Get-Answer (Invoke-Chat $BaseUrl $Model 'Reply with exactly: OK' 64)
    Write-Check 'POST /v3/chat/completions (text)' ([bool]$ans) "'$ans'"
    , $png
}

function Test-Services {
    foreach ($name in $S.OvmsServiceName, $S.ServiceName) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
        Write-Check "$name running" ($svc -and $svc.State -eq 'Running') "$($svc.State)"
        $qc = (Invoke-Native sc.exe qc $name) -join "`n"
        Write-Check "$name starts at boot" ($qc -match 'AUTO_START') (($qc -split "`n" | Where-Object { $_ -match 'START_TYPE' }).Trim())
        $qf = (Invoke-Native sc.exe qfailure $name) -join "`n"
        Write-Check "$name restarts on failure" ($qf -match 'RESTART -- Delay = \d+') ((($qf -split "`n") | Where-Object { $_ -match 'RESTART' } | Select-Object -First 1).Trim())
    }
    $deps = @((Get-Service -Name $S.ServiceName).ServicesDependedOn | ForEach-Object Name)
    Write-Check "$($S.ServiceName) starts after $($S.OvmsServiceName) and Tailscale" `
        ($deps -contains $S.OvmsServiceName -and $deps -contains 'Tailscale') ($deps -join ', ')
    $tsSvc = Get-CimInstance Win32_Service -Filter "Name='Tailscale'"
    Write-Check 'Tailscale starts at boot' ($tsSvc.StartMode -eq 'Auto') $tsSvc.StartMode
}

# True when a TCP connection to $Address:$Port is accepted.
function Test-TcpPort([string]$Address, [int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try { $client.ConnectAsync($Address, $Port).Wait($ConnectTimeoutMs) -and $client.Connected }
    catch { $false }
    finally { $client.Dispose() }
}

# The local addresses accepting connections on $Port, and how they were found.
# Some machines list no listening sockets at all, so when the listener list
# has no entry for the port, each local IPv4 address is tried in turn.
function Get-ListenAddress([int]$Port) {
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($listen.Count) {
        return [pscustomobject]@{ Method = 'listener list'; Addresses = @($listen | ForEach-Object LocalAddress | Sort-Object -Unique) }
    }
    $local = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress | Sort-Object -Unique)
    [pscustomobject]@{ Method = 'connecting'; Addresses = @($local | Where-Object { Test-TcpPort $_ $Port }) }
}

# Checks that port $Port accepts connections on $Address and on no other address.
function Test-ListenOnly([string]$Name, [int]$Port, [string]$Address) {
    $found = Get-ListenAddress $Port
    $ok = $found.Addresses.Count -gt 0 -and -not ($found.Addresses | Where-Object { $_ -ne $Address })
    Write-Check $Name $ok "$($found.Addresses -join ', ') (by $($found.Method))"
}

function Test-Network([string]$Ip) {
    Test-ListenOnly "$($S.Name) listens on private address only" $S.Port $Ip
    Test-ListenOnly 'Model server listens on 127.0.0.1 only' $S.OvmsPort '127.0.0.1'
}

function Test-Firewall {
    $allowFrom = @($S.AllowFrom)
    $rules = @(Get-NetFirewallRule -Group $S.FirewallGroup -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True')
    $allow = $rules | Where-Object Action -eq 'Allow' | Where-Object {
        $remote = @(($_ | Get-NetFirewallAddressFilter).RemoteAddress)
        ($_ | Get-NetFirewallPortFilter).LocalPort -contains "$($S.Port)" -and
            -not ($allowFrom | Where-Object { $remote -notcontains $_ -and $remote -notcontains (ConvertTo-Netmask $_) }) }
    Write-Check "Firewall allows $($allowFrom -join ', ')" ([bool]$allow) ''
    $block = $rules | Where-Object Action -eq 'Block'
    $blockAddr = if ($block) { @(($block | Get-NetFirewallAddressFilter).RemoteAddress) } else { @() }
    $want = @(Get-BlockRanges $allowFrom)
    Write-Check 'Firewall blocks all other IPv4 sources' ($blockAddr.Count -eq $want.Count -and
        -not ($want | Where-Object { $blockAddr -notcontains $_ })) ($blockAddr -join ', ')
}

function Test-MoreApi([string]$BaseUrl, [string]$Model, [byte[]]$Png) {
    $bad = Get-Status { Invoke-WebRequest "$BaseUrl/inspect" -Method Post -ContentType 'application/json' -Body '{}' -UseBasicParsing }
    Write-Check 'POST /inspect without an image is refused' ($bad -eq 400) "HTTP $bad"
    $notImage = @{ image = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('%PDF-1.7 not an image')) } | ConvertTo-Json
    $bad = Get-Status { Invoke-WebRequest "$BaseUrl/inspect" -Method Post -ContentType 'application/json' -Body $notImage -UseBasicParsing }
    Write-Check 'POST /inspect with a non-image is refused' ($bad -eq 415) "HTTP $bad"
    $models = Invoke-RestMethod "$BaseUrl/v3/models" -TimeoutSec 10
    $ids = @($models.data | ForEach-Object id)
    Write-Check 'GET /v3/models' ($ids -contains $Model) ($ids -join ', ')
    $ans = Get-Answer (Invoke-Chat $BaseUrl $Model 'Is 17 a prime number? Answer yes or no.' 200)
    Write-Check 'POST /v3/chat/completions (text)' ([bool]$ans) "'$ans'"
    $ans = Get-Answer (Invoke-Chat $BaseUrl $Model (New-ButtonQuestion $Png) 32)
    Write-Check 'POST /v3/chat/completions (image)' ($ans -match 'Save changes') "'$ans'"
    $content = @(@{ type = 'text'; text = 'What is this?' },
                 @{ type = 'image_url'; image_url = @{ url = 'C:\Windows\win.ini' } })
    $bad = Get-Status { Invoke-Chat $BaseUrl $Model $content 8 }
    Write-Check 'Passthrough refuses an image given as a file path' ($bad -eq 400) "HTTP $bad"
}

# A 4K screenshot must be scaled down to MaxImagePixels. OVMS's prompt_tokens
# counts text only, so read times are compared instead: scaled down, a 4K
# screenshot reads in about the time of a 1920 x 1080 one; unscaled, it has 4
# times the image tokens. Short replies keep the times comparable.
function Test-ImageSize([string]$BaseUrl, [string]$Model) {
    $processor = Join-Path $InstallDir "models\$($Model -replace '/', '\')\processor_config.json"
    if (Test-Path $processor) {
        $edge = (Get-Content $processor -Raw | ConvertFrom-Json).image_processor.size.longest_edge
        Write-Check "Largest image set to $($S.MaxImagePixels) pixels" ($edge -eq $S.MaxImagePixels) "processor_config.json: $edge"
    }
    $hd = Read-Time $BaseUrl $Model 1920 1080
    $uhd = Read-Time $BaseUrl $Model 3840 2160
    Write-Check '4K screenshot scaled down (read in at most 1.6 x the time of 1920 x 1080)' ($uhd -le [math]::Max(1.6 * $hd, $hd + 1)) `
        ('{0:N1} s for 4K, {1:N1} s for 1920 x 1080' -f $uhd, $hd)
}

# Two requests at once must be scheduled together, not one after the other.
# OVMS logs "Scheduled requests: N" while it works.
function Test-Parallel([string]$BaseUrl, [string]$Model) {
    $gen = {
        param($BaseUrl, $Model)
        $b = @{ model = $Model; max_tokens = 300; ignore_eos = $true; temperature = 0
                messages = @(@{ role = 'user'; content = "Count upwards from $(Get-Random)." }) } | ConvertTo-Json -Depth 5
        $null = Invoke-RestMethod "$BaseUrl/v3/chat/completions" -Method Post -ContentType 'application/json' -Body $b -TimeoutSec 600
        'done'
    }
    $ovmsLog = Join-Path $InstallDir 'logs\ovms.log'
    $logStart = (Get-Item $ovmsLog).Length
    $jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $gen -ArgumentList $BaseUrl, $Model }
    $done = @($jobs | Wait-Job | Receive-Job -ErrorAction SilentlyContinue | Where-Object { $_ -eq 'done' }).Count
    $jobs | Remove-Job -Force
    $fs = [IO.File]::Open($ovmsLog, 'Open', 'Read', 'ReadWrite')
    $null = $fs.Seek($logStart, 'Begin')
    $newLog = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Dispose()
    $maxScheduled = ([regex]::Matches($newLog, 'Scheduled requests: (\d+)') | ForEach-Object { [int]$_.Groups[1].Value } |
                     Measure-Object -Maximum).Maximum
    Write-Check '2 requests in parallel' ($done -eq 2 -and $maxScheduled -ge 2) "$done of 2 completed; at most $maxScheduled scheduled together"
}

function Test-Context([string]$BaseUrl, [string]$Model) {
    $probe = (Invoke-Chat $BaseUrl $Model (New-RandomText 2000) 1).Content | ConvertFrom-Json
    $perWord = $probe.usage.prompt_tokens / 2000
    if (-not $perWord) {
        Write-Host 'INFO  context check skipped: the model server reports no prompt token count'
        return
    }
    $okWords = [int](($S.ContextLength - 600) / $perWord)
    $r = (Invoke-Chat $BaseUrl $Model (New-RandomText $okWords) 16).Content | ConvertFrom-Json
    Write-Check "Serves a $($r.usage.prompt_tokens)-token prompt" ($r.usage.prompt_tokens -gt $S.ContextLength - 1200) ''
    $tooLong = [int](($S.ContextLength + 600) / $perWord)
    $refused = $false; $msg = ''
    try { $null = Invoke-Chat $BaseUrl $Model (New-RandomText $tooLong) 16 } catch { $refused = $true; $msg = $_.ErrorDetails.Message }
    Write-Check "Refuses ~$([int]($tooLong * $perWord))-token prompt (limit $($S.ContextLength))" $refused $msg
}

# Kills the image service and the model server, and checks that their
# services bring them back. A process that is not found is not killed.
function Test-Restart([string]$BaseUrl) {
    $py = Get-ImageServicePid
    Write-Check "$($S.ServiceName) has a running process" ([bool]$py) "pid $py"
    if (-not $py) { return }
    Stop-Process -Id $py -Force
    Write-Host "INFO  killed image.py (pid $py); waiting for $($S.ServiceName) to restart it"
    $back = Wait-Ready $BaseUrl 5 3
    $py2 = Get-ImageServicePid
    Write-Check "$($S.Name) restarts after a crash" ($back -and $py2 -and $py2 -ne $py) "new pid $py2"

    $ovms = (Get-CimInstance Win32_Service -Filter "Name='$($S.OvmsServiceName)'").ProcessId
    Write-Check "$($S.OvmsServiceName) has a running process" ($ovms -gt 0) "pid $ovms"
    if (-not ($ovms -gt 0)) { return }
    Stop-Process -Id $ovms -Force
    Write-Host "INFO  killed ovms.exe (pid $ovms); waiting for $($S.OvmsServiceName) to restart it"
    $back = Wait-Ready $BaseUrl 5 3
    $ovms2 = (Get-CimInstance Win32_Service -Filter "Name='$($S.OvmsServiceName)'").ProcessId
    Write-Check 'Model server restarts after a crash' ($back -and $ovms2 -gt 0 -and $ovms2 -ne $ovms) "new pid $ovms2"
}

if (-not $SelfTest) { Start-Transcript -Path $log -Force | Out-Null }
try {
    $ip = Get-PrivateIp $S.PrivateRange
    if (-not $ip) { throw "This PC is not on Cogy Server's private network" }
    Write-Check 'Private address' $true $ip
    $base = "http://$($ip):$($S.Port)"
    $model = (Get-Content (Join-Path $InstallDir 'config.json') -Raw | ConvertFrom-Json).model_config_list[0].config.name

    $png = Test-Api $base $model
    if (-not $SelfTest) {
        Test-Services
        Test-Network $ip
        Test-Firewall
        Test-MoreApi $base $model $png
        Test-ImageSize $base $model
        Test-Parallel $base $model
        if (-not $SkipContext) { Test-Context $base $model }
        if ($TestRestart) { Test-Restart $base }
    }
}
catch {
    # An unexpected error counts as a failed check.
    Write-Check 'error' $false $_.Exception.Message
}
finally {
    Write-Host "Result: $(if ($failures) { "$failures check(s) failed" } else { 'all checks passed' })"
    if (-not $SelfTest) { Stop-Transcript | Out-Null }
}
exit [int]($failures -gt 0)
