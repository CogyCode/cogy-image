# Pinned downloads, OpenVINO Model Server, the embeddable Python and the
# model. Dot-sourced by common.ps1.

# Gives SYSTEM and Administrators full control of $Dir and Users read and
# execute only, since the services run as SYSTEM. Everything below inherits it.
function Protect-InstallDir([string]$Dir) {
    & icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed ($LASTEXITCODE)" }
    & icacls.exe "$Dir\*" /reset /T /C /Q | Out-Null
}

# Downloads $Url to $OutFile unless it is already there with SHA-256 $Sha256,
# and checks it. A download with another hash is deleted.
function Get-VerifiedFile([string]$Url, [string]$Sha256, [string]$OutFile) {
    if ((Test-Path $OutFile) -and (Get-FileHash $OutFile -Algorithm SHA256).Hash -eq $Sha256) {
        Write-Info "Already downloaded: $(Split-Path $OutFile -Leaf)"
        return
    }
    Write-Info "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    $hash = (Get-FileHash $OutFile -Algorithm SHA256).Hash
    if ($hash -ne $Sha256) {
        Remove-Item $OutFile -Force
        throw "SHA-256 mismatch for $(Split-Path $OutFile -Leaf): got $hash"
    }
    Write-Info 'SHA-256 OK'
}

# True when $Exe exists and $VersionFile records $Version.
function Test-InstalledVersion([string]$Exe, [string]$VersionFile, [string]$Version) {
    (Test-Path $Exe) -and (Test-Path $VersionFile) -and ((Get-Content $VersionFile -Raw).Trim() -eq $Version)
}

# Installs the pinned OpenVINO Model Server release into $OvmsDir, using
# $WorkDir for the download.
function Install-Ovms([string]$OvmsDir, [string]$WorkDir, [hashtable]$Settings) {
    $versionFile = Join-Path $OvmsDir 'ovms-version.txt'
    if (Test-InstalledVersion (Join-Path $OvmsDir 'ovms.exe') $versionFile $Settings.OvmsVersion) {
        Write-Info 'Already installed'
        return
    }
    if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    $zip = Join-Path $WorkDir $Settings.OvmsZip
    $url = "https://github.com/openvinotoolkit/model_server/releases/download/$($Settings.OvmsTag)/$($Settings.OvmsZip)"
    Get-VerifiedFile $url $Settings.OvmsSha256 $zip
    Expand-Archive -Path $zip -DestinationPath $WorkDir -Force
    $unpacked = Join-Path $WorkDir 'ovms'
    if (-not (Test-Path (Join-Path $unpacked 'ovms.exe'))) { throw "$($Settings.OvmsZip) has no ovms\ovms.exe" }
    if (Test-Path $OvmsDir) { Remove-Item -Recurse -Force $OvmsDir }
    Move-Item $unpacked $OvmsDir
    Set-Content -Path $versionFile -Value $Settings.OvmsVersion -Encoding ascii
    Remove-Item -Recurse -Force $WorkDir
}

# Installs the pinned embeddable Python into $PythonDir.
function Install-EmbeddablePython([string]$PythonDir, [hashtable]$Settings) {
    $versionFile = Join-Path $PythonDir 'python-version.txt'
    if (Test-InstalledVersion (Join-Path $PythonDir 'python.exe') $versionFile $Settings.PythonVersion) {
        Write-Info 'Already installed'
        return
    }
    $zip = Join-Path $env:TEMP "python-$($Settings.PythonVersion)-embed.zip"
    Get-VerifiedFile $Settings.PythonZipUrl $Settings.PythonSha256 $zip
    if (Test-Path $PythonDir) { Remove-Item -Recurse -Force $PythonDir }
    Expand-Archive -Path $zip -DestinationPath $PythonDir -Force
    Remove-Item $zip -Force
    Set-Content -Path $versionFile -Value $Settings.PythonVersion -Encoding ascii
}

function Get-ModelDir([string]$ModelsDir, [string]$Id) { Join-Path $ModelsDir ($Id -replace '/', '\') }

# True when the model in $Dir is fully downloaded: weight files present, none
# still a Git LFS pointer, no download in progress, and the image encoder
# there. Without the encoder the model loads as text-only.
function Test-ModelComplete([string]$Dir) {
    $bins = @(Get-ChildItem $Dir -Filter 'openvino_*.bin' -ErrorAction SilentlyContinue)
    $pointers = @($bins | Where-Object { $_.Length -lt 1KB -and (Get-Content $_.FullName -TotalCount 1) -match '^version https://git-lfs' })
    ($bins | Measure-Object Length -Sum).Sum -gt 50MB -and $pointers.Count -eq 0 -and
        (Test-Path (Join-Path $Dir 'openvino_vision_embeddings_model.xml')) -and
        -not (Test-Path "$Dir.lfswip") -and -not (Get-ChildItem $Dir -Filter '*lfs_part' -ErrorAction SilentlyContinue)
}

# Downloads model $Id from Hugging Face with ovms --pull unless it is
# complete, replacing any incomplete download.
function Install-Model([string]$Id, [string]$ModelsDir, [string]$OvmsExe) {
    $dir = Get-ModelDir $ModelsDir $Id
    if (Test-ModelComplete $dir) {
        Write-Info 'Already downloaded'
    } else {
        if (Test-Path $dir) {
            Write-Info 'Removing incomplete download'
            Remove-Item -Recurse -Force $dir
        }
        Remove-Item -Force "$dir.lfswip" -ErrorAction SilentlyContinue
        Write-Info 'Downloading from Hugging Face (this can take a while)...'
        Invoke-Native $OvmsExe --pull --source_model $Id --model_repository_path $ModelsDir --task text_generation |
            Where-Object { $_ -match 'error|fail|download|finished' } | ForEach-Object { Write-Info $_ }
        if (-not (Test-ModelComplete $dir)) { throw "Download of $Id failed or has no image encoder (ovms exit $LASTEXITCODE)" }
    }
    $sizeGB = (Get-ChildItem $dir -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
               Measure-Object Length -Sum).Sum / 1GB
    Write-Info ('On disk: {0:N2} GB' -f $sizeGB)
}

# Removes every model under $ModelsDir except $KeepDir, with any leftover
# download markers and empty organisation folders.
function Remove-UnusedModels([string]$ModelsDir, [string]$KeepDir) {
    foreach ($org in Get-ChildItem $ModelsDir -Directory) {
        foreach ($m in Get-ChildItem $org.FullName -Directory) {
            if ($m.FullName -ne $KeepDir) {
                Write-Info "Removing unused model $($org.Name)/$($m.Name)"
                Remove-Item -Recurse -Force $m.FullName
            }
        }
        Get-ChildItem $org.FullName -Filter '*.lfswip' | Where-Object { ($_.FullName -replace '\.lfswip$', '') -ne $KeepDir } | Remove-Item -Force
        if (-not (Get-ChildItem $org.FullName)) { Remove-Item -Force $org.FullName }
    }
}

# Sets the model's context limit: OVMS caps prompt plus output at
# max_position_embeddings in the model's config.json.
function Set-ModelContextLength([string]$ModelDir, [int]$Length) {
    $file = Join-Path $ModelDir 'config.json'
    $text = Get-Content $file -Raw
    $new = [regex]::Replace($text, '"max_position_embeddings"\s*:\s*\d+', "`"max_position_embeddings`": $Length")
    if ($new -ne $text) { [IO.File]::WriteAllText($file, $new) }
}

# Sets the largest image, in pixels, that the model's processor scales images
# down to. Qwen3-VL reads it from size.longest_edge, older models from
# max_pixels. OpenVINO GenAI reads the image settings from the image_processor
# section of processor_config.json when there is one (its video_processor is
# left alone), else from preprocessor_config.json, so both are set. Returns
# $true when any setting was found.
function Set-ModelMaxImagePixels([string]$ModelDir, [int]$Pixels) {
    $found = $false
    foreach ($name in 'processor_config.json', 'preprocessor_config.json') {
        $file = Join-Path $ModelDir $name
        if (-not (Test-Path $file)) { continue }
        $j = Get-Content $file -Raw | ConvertFrom-Json
        $target = if ($name -eq 'processor_config.json') { $j.image_processor } else { $j }
        if (-not $target) { continue }
        $changed = $false
        if ($target.size -and $null -ne $target.size.longest_edge) {
            if ($target.size.longest_edge -ne $Pixels) { $target.size.longest_edge = $Pixels; $changed = $true }
            $found = $true
        }
        if ($null -ne $target.max_pixels) {
            if ($target.max_pixels -ne $Pixels) { $target.max_pixels = $Pixels; $changed = $true }
            $found = $true
        }
        if ($changed) { [IO.File]::WriteAllText($file, ($j | ConvertTo-Json -Depth 20)) }
    }
    $found
}
