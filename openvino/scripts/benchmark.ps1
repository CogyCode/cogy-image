<#
.SYNOPSIS
    Measures how fast Cogy Image reads screenshots, its generation speed and
    the model server's GPU memory.

.DESCRIPTION
    - Inspection: -Trials POST /inspect calls with a generated 1920 x 1080
      screenshot. Each has different text, so no cached prefix is reused.
      Reports the time per screenshot. (OVMS's prompt_tokens counts text
      only, so the image's size in tokens is not reported.)
    - Generation: streams a -GenTokens completion and times the tokens after
      the first.
    - Two at once: two inspections sent together.
    - GPU memory of the model server (ovms.exe) from the Windows
      "GPU Process Memory" performance counters.

.PARAMETER BaseUrl
    Server URL. Default: this PC's private address and the configured port.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [int]$GenTokens = 256,
    [int]$Trials = 3
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$S = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\settings.psd1')
if (-not $BaseUrl) {
    $ip = Get-PrivateIp $S.PrivateRange
    if (-not $ip) { throw 'This PC is not on the private network; pass -BaseUrl' }
    $BaseUrl = "http://$($ip):$($S.Port)"
}
$Model = (Invoke-RestMethod "$BaseUrl/v3/models" -TimeoutSec 10).data[0].id
Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromMinutes(10)

# An /inspect request with a fresh 1920 x 1080 test screenshot.
function New-InspectBody {
    $png = New-TestScreenshot "Error $(Get-Random): payment failed" "Save $(Get-Random)" -Width 1920 -Height 1080
    @{ image = [Convert]::ToBase64String($png); caption = 'The form saved without errors' } | ConvertTo-Json
}

function Invoke-Inspect([string]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "$BaseUrl/inspect" -Method Post -ContentType 'application/json' -Body $Body -TimeoutSec 600
    [pscustomobject]@{ Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                       CompletionTokens = $r.usage.completion_tokens }
}

# Tokens per second after the first, streaming a -GenTokens completion; 0
# when too few tokens arrive to time.
function Measure-Generation {
    $body = @{
        model = $Model; stream = $true; max_tokens = $GenTokens; ignore_eos = $true; temperature = 0
        stream_options = @{ include_usage = $true }
        messages = @(@{ role = 'user'; content = "Run $([guid]::NewGuid()). Describe a settings page in detail." })
    } | ConvertTo-Json -Depth 5
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$BaseUrl/v3/chat/completions")
    $req.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode): $($resp.Content.ReadAsStringAsync().Result)" }
    $reader = New-Object IO.StreamReader($resp.Content.ReadAsStreamAsync().Result)
    $first = $null; $last = $null; $usage = $null; $chunks = 0
    while ($null -ne ($line = $reader.ReadLine())) {
        if (-not $line.StartsWith('data: ') -or $line -eq 'data: [DONE]') { continue }
        $chunk = $line.Substring(6) | ConvertFrom-Json
        if ($chunk.choices -and $chunk.choices[0].delta.content) {
            $t = $sw.Elapsed.TotalSeconds
            if ($null -eq $first) { $first = $t }
            $last = $t
            $chunks++
        }
        if ($chunk.usage) { $usage = $chunk.usage }
    }
    $reader.Dispose(); $resp.Dispose()
    $count = if ($usage -and $usage.completion_tokens) { $usage.completion_tokens } else { $chunks }
    if ($null -eq $first -or $last -le $first) { return 0.0 }
    [math]::Round(($count - 1) / ($last - $first), 1)
}

function Get-Median($Values) { $s = @($Values | Sort-Object); $s[[int][math]::Floor($s.Count / 2)] }

Write-Host "Server: $BaseUrl   Model: $Model"

$inspections = foreach ($t in 1..$Trials) {
    $r = Invoke-Inspect (New-InspectBody)
    Write-Host ("  inspection {0}: {1} s, {2} tokens written" -f $t, $r.Seconds, $r.CompletionTokens)
    $r
}

$gen = foreach ($t in 1..$Trials) {
    $g = Measure-Generation
    Write-Host "  generation $($t): $g tok/s"
    $g
}

# Two inspections at once.
$sw = [Diagnostics.Stopwatch]::StartNew()
$tasks = 1..2 | ForEach-Object {
    $http.PostAsync("$BaseUrl/inspect", (New-Object System.Net.Http.StringContent((New-InspectBody), [Text.Encoding]::UTF8, 'application/json')))
}
[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
$wall = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$ok = @($tasks | Where-Object { $_.Result.IsSuccessStatusCode }).Count
Write-Host "  2 at once: $ok of 2 succeeded in $wall s"

# GPU memory of the model server process.
$ovmsPid = (Get-CimInstance Win32_Service -Filter "Name='$($S.OvmsServiceName)'").ProcessId
$mem = $null
if ($ovmsPid) {
    $ctr = Get-Counter "\GPU Process Memory(pid_$($ovmsPid)_*)\Dedicated Usage", "\GPU Process Memory(pid_$($ovmsPid)_*)\Shared Usage" -ErrorAction SilentlyContinue
    if ($ctr) {
        $ded = ($ctr.CounterSamples | Where-Object Path -like '*dedicated usage' | Measure-Object CookedValue -Sum).Sum
        $shr = ($ctr.CounterSamples | Where-Object Path -like '*shared usage' | Measure-Object CookedValue -Sum).Sum
        $mem = [pscustomobject]@{ DedicatedGB = [math]::Round($ded / 1GB, 2); SharedGB = [math]::Round($shr / 1GB, 2) }
    }
}

Write-Host ''
Write-Host ('Screenshot (1920 x 1080): {0} s per inspection (median)' -f (Get-Median $inspections.Seconds))
Write-Host ('Generation:               {0} tok/s (median, {1} tokens)' -f (Get-Median $gen), $GenTokens)
Write-Host ('2 inspections at once:    {0} s for both' -f $wall)
if ($mem) {
    Write-Host ('GPU memory (model server): {0} GB shared + {1} GB dedicated = {2} GB' -f
        $mem.SharedGB, $mem.DedicatedGB, ($mem.SharedGB + $mem.DedicatedGB))
} else {
    Write-Host 'GPU memory: counters unavailable (run elevated; the model server must be running)'
}
