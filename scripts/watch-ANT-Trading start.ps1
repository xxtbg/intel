<#
.SYNOPSIS
    Watches a free Nasdaq feed for a stock's first trade and plays a sound 3 times when trading starts.

.DESCRIPTION
    Polls Nasdaq's public quote API (api.nasdaq.com - no key, no account) for the
    symbol every few seconds. Before the IPO opens, Nasdaq reports no sale price.
    The moment a real last-sale price / first trade appears, the script plays the
    alert sound 3 times and stops (or keeps watching with -KeepWatching).

    Primary feed : Nasdaq quote info + trades endpoints (the exchange itself).
    Fallback feed: Yahoo Finance chart API (free, no key), used automatically
                   if Nasdaq errors repeatedly. Its firstTradeDate field is
                   null until the first real trade prints.

.PARAMETER Symbol
    Ticker to watch. Default: ANT (Anthropic).

.PARAMETER PollSeconds
    How often to check. Default: 5 seconds. Don't go below 3 - be polite to the feed.

.PARAMETER SoundCount
    How many times to play the sound when trading starts. Default: 3.

.PARAMETER WavPath
    Optional path to a .wav file to play. If omitted, uses a two-tone beep
    generated in code (no file needed).

.PARAMETER KeepWatching
    If set, keeps polling after the alert instead of exiting.

.EXAMPLE
    .\Watch-TradingStart.ps1
    .\Watch-TradingStart.ps1 -Symbol ANT -PollSeconds 3
    .\Watch-TradingStart.ps1 -Symbol ANT -WavPath C:\Windows\Media\Alarm01.wav
#>
param(
    [string]$Symbol = "ANT",
    [int]$PollSeconds = 5,
    [int]$SoundCount = 3,
    [string]$WavPath = "",
    [switch]$KeepWatching
)

$ErrorActionPreference = "Stop"
$Symbol = $Symbol.ToUpperInvariant()

$headers = @{
    "User-Agent"    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    "Accept"        = "application/json, text/plain, */*"
    "Accept-Language" = "en-US,en;q=0.9"
}

function Play-AlertSound {
    param([int]$Times = 3, [string]$Wav = "")
    for ($i = 1; $i -le $Times; $i++) {
        if ($Wav -and (Test-Path $Wav)) {
            $player = New-Object System.Media.SoundPlayer $Wav
            $player.PlaySync()
        } else {
            # Two-tone beep, no external file needed. If the console beep is
            # unavailable on this machine, fall back to the system sound.
            try {
                [Console]::Beep(880, 300)
                [Console]::Beep(1320, 450)
            } catch {
                try {
                    [System.Media.SystemSounds]::Exclamation.Play()
                    Start-Sleep -Milliseconds 750
                } catch {
                    Write-Host "(sound playback not available on this machine)" -ForegroundColor Yellow
                }
            }
        }
        if ($i -lt $Times) { Start-Sleep -Milliseconds 350 }
    }
}

function Get-NasdaqFirstTrade {
    # Returns the last-sale price (double) once a trade exists, else $null.
    $infoUrl   = "https://api.nasdaq.com/api/quote/$Symbol/info?assetclass=stocks"
    $tradesUrl = "https://api.nasdaq.com/api/quote/$Symbol/trades?assetclass=stocks&limit=5"

    $info = Invoke-RestMethod -Uri $infoUrl -Headers $headers -TimeoutSec 15
    $pd = $info.data.primaryData
    if ($null -ne $pd -and $pd.lastSalePrice) {
        $clean = ($pd.lastSalePrice -replace '[^0-9.]', '')
        $price = 0.0
        if ([double]::TryParse($clean, [ref]$price) -and $price -gt 0) {
            return $price
        }
    }

    # Cross-check the trades feed: any real row means trading has started.
    try {
        $trades = Invoke-RestMethod -Uri $tradesUrl -Headers $headers -TimeoutSec 15
        $rows = $trades.data.rows
        if ($rows -and $rows.Count -gt 0 -and $rows[0].price) {
            $clean = ($rows[0].price -replace '[^0-9.]', '')
            $price = 0.0
            if ([double]::TryParse($clean, [ref]$price) -and $price -gt 0) {
                return $price
            }
        }
    } catch { }
    return $null
}

function Get-YahooFirstTrade {
    # Fallback: Yahoo Finance chart API. meta.firstTradeDate is null until
    # the first trade prints; regularMarketPrice alone is NOT a trigger
    # (Yahoo pre-fills it with the $83 IPO price before trading starts).
    $url = "https://query2.finance.yahoo.com/v8/finance/chart/$Symbol`?interval=1m&range=1d"
    $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15
    $meta = $resp.chart.result[0].meta
    if ($null -ne $meta.firstTradeDate) {
        return [double]$meta.regularMarketPrice
    }
    return $null
}

Write-Host "Watching $Symbol for its first trade (Nasdaq feed, every $PollSeconds s). Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "Sound will play $SoundCount times when trading starts."
Write-Host "Playing the alert sound once now so you can verify it works...`n" -ForegroundColor Cyan
Play-AlertSound -Times 1 -Wav $WavPath

$alerted = $false
$failStreak = 0

while ($true) {
    $stamp = Get-Date -Format "HH:mm:ss"
    try {
        $price = Get-NasdaqFirstTrade
        $source = "Nasdaq"
        if ($null -eq $price -and $failStreak -ge 3) {
            $price = Get-YahooFirstTrade
            $source = "Yahoo (fallback)"
        }
        $failStreak = 0

        if ($null -ne $price) {
            Write-Host "[$stamp] *** TRADING STARTED: $Symbol first/last sale `$$price ($source) ***" -ForegroundColor Green
            Play-AlertSound -Times $SoundCount -Wav $WavPath
            if (-not $KeepWatching) { break }
            if ($alerted) { Start-Sleep -Seconds $PollSeconds; continue }
            $alerted = $true
        } else {
            Write-Host "[$stamp] $Symbol - no trade yet."
        }
    } catch {
        $failStreak++
        Write-Host "[$stamp] Feed check failed ($failStreak in a row): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Start-Sleep -Seconds $PollSeconds
}

Write-Host "`nDone."
