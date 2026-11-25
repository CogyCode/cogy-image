# Readiness polling and the generated test screenshot used by the self-tests.
# Dot-sourced by common.ps1.

# Polls $BaseUrl/health every $IntervalSec seconds until the model is ready.
# Returns $false when it is not ready within $Minutes.
function Wait-Ready([string]$BaseUrl, [int]$Minutes, [int]$IntervalSec) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep $IntervalSec
        try { if ((Invoke-RestMethod "$BaseUrl/health" -TimeoutSec $IntervalSec).status -eq 'ready') { return $true } }
        catch {
            # 503 while the model loads, or no answer while the service starts: poll again.
        }
    }
    $false
}

# A PNG of a small app window with a red error banner reading $Banner and a
# button labelled $Button, as bytes. The self-tests check that the model
# reads both back.
function New-TestScreenshot([string]$Banner, [string]$Button, [int]$Width = 800, [int]$Height = 500) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap $Width, $Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $font = $big = $ms = $null
    try {
        $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([Drawing.Color]::White)
        $font = New-Object Drawing.Font 'Segoe UI', 14
        $big = New-Object Drawing.Font 'Segoe UI', 20, ([Drawing.FontStyle]::Bold)
        $g.FillRectangle([Drawing.Brushes]::Gainsboro, 0, 0, $Width, 40)
        $g.DrawString('Account settings', $font, [Drawing.Brushes]::Black, 12, 8)
        $g.FillRectangle([Drawing.Brushes]::Firebrick, 40, 70, $Width - 80, 60)
        $g.DrawString($Banner, $big, [Drawing.Brushes]::White, 56, 82)
        $g.DrawString('Email', $font, [Drawing.Brushes]::Black, 40, 160)
        $g.DrawRectangle([Drawing.Pens]::Gray, 40, 190, $Width - 80, 36)
        $g.DrawString('owner@example.com', $font, [Drawing.Brushes]::DimGray, 48, 194)
        $g.FillRectangle([Drawing.Brushes]::RoyalBlue, 40, 260, 200, 48)
        $g.DrawString($Button, $font, [Drawing.Brushes]::White, 62, 270)
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        , $ms.ToArray()
    } finally {
        foreach ($o in $ms, $font, $big, $g, $bmp) { if ($o) { $o.Dispose() } }
    }
}
