$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Silver Canteen AI - Fixed Public URL"
Set-Location -LiteralPath $PSScriptRoot

$FixedUrl = "https://throwing-company-evil.ngrok-free.dev"
$LocalUrl = "http://127.0.0.1:5000"

function Wait-BeforeExit {
    Write-Host ""
    Write-Host "Press Enter to close this window..." -ForegroundColor DarkGray
    [void](Read-Host)
}

function Test-LocalWebsite {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "$LocalUrl/api/test_db" -TimeoutSec 8
        $data = $response.Content | ConvertFrom-Json
        return $data.status -eq "ok"
    }
    catch {
        return $false
    }
}

Clear-Host
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Silver Canteen AI - Fixed Public URL" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Fixed URL: $FixedUrl" -ForegroundColor Green
Write-Host ""

if (-not (Test-Path -LiteralPath ".\ngrok.exe")) {
    Write-Host "ERROR: ngrok.exe was not found in the project folder." -ForegroundColor Red
    Wait-BeforeExit
    exit 1
}

Write-Host "[1/2] Checking the local website and database..." -ForegroundColor Yellow
if (-not (Test-LocalWebsite)) {
    Write-Host "The local website is not running. Starting app.py..." -ForegroundColor Yellow

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        Write-Host "ERROR: Python was not found. Install Python or start app.py manually." -ForegroundColor Red
        Wait-BeforeExit
        exit 1
    }

    Start-Process -FilePath $python.Source `
        -ArgumentList "app.py" `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Hidden

    $ready = $false
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-LocalWebsite) {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        Write-Host "ERROR: app.py started, but the website or database is not available." -ForegroundColor Red
        Write-Host "Run python app.py manually to view the detailed error." -ForegroundColor Yellow
        Wait-BeforeExit
        exit 1
    }
}
Write-Host "Local website and database are working." -ForegroundColor Green

Write-Host ""
Write-Host "[2/2] Starting the fixed public URL..." -ForegroundColor Yellow
Write-Host "Open or place this URL in the PPT:" -ForegroundColor White
Write-Host $FixedUrl -ForegroundColor Green
Write-Host ""
Write-Host "Keep this window open while presenting. Press Ctrl+C to stop sharing." -ForegroundColor White
Write-Host "The URL stays the same after restarting, but it only works while this computer is online." -ForegroundColor DarkGray
Write-Host ""

try {
    & ".\ngrok.exe" http 5000 --url $FixedUrl
}
catch {
    Write-Host ""
    Write-Host "Public sharing failed to start." -ForegroundColor Red
    Write-Host "Details: $($_.Exception.Message)" -ForegroundColor DarkRed
}

Write-Host ""
Write-Host "Public sharing has stopped." -ForegroundColor Yellow
Wait-BeforeExit
