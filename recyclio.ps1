# Requires PowerShell 7+
# Recycle Bin Auto Cleaner

Clear-Host

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "     Recycle Bin Auto Cleaner"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Choose interval:"
Write-Host "  1) 5 minutes"
Write-Host "  2) 10 minutes"
Write-Host "  3) 15 minutes"
Write-Host ""

do {
    $choice = Read-Host "Selection (1-3)"
} until ($choice -in "1","2","3")

$intervalMinutes = switch ($choice) {
    "1" { 5 }
    "2" { 10 }
    "3" { 15 }
}

$interval = $intervalMinutes * 60

function Show-Spinner {
    param(
        [scriptblock]$Action
    )

    $job = Start-Job $Action

    $spinner = @("|","/","-","\")
    $i = 0

    while ($job.State -eq "Running") {
        Write-Host -NoNewline "`rCleaning Recycle Bin $($spinner[$i % $spinner.Count]) "
        Start-Sleep -Milliseconds 120
        $i++
        $job = Get-Job $job.Id
    }

    Receive-Job $job | Out-Null
    Remove-Job $job

    Write-Host "`rCleaning Recycle Bin ✔            " -ForegroundColor Green
}

function Clear-Bin {
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
    }
    catch {
        # Ignore if already empty or another harmless error
    }
}

Write-Host ""
Write-Host "Started." -ForegroundColor Green
Write-Host "Press ESC or Q at any time to quit."
Write-Host ""

while ($true) {

    Show-Spinner {
        Clear-RecycleBin -Force
    }

    $nextRun = (Get-Date).AddSeconds($interval)

    for ($remaining = $interval; $remaining -gt 0; $remaining--) {

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)

            if ($key.Key -eq "Escape" -or
                $key.KeyChar -eq 'q' -or
                $key.KeyChar -eq 'Q') {

                Write-Host "`nExiting..." -ForegroundColor Yellow
                return
            }
        }

        $ts = [TimeSpan]::FromSeconds($remaining)

        Write-Host -NoNewline ("`rNext cleanup in {0:mm\:ss}    " -f $ts)

        Start-Sleep -Seconds 1
    }

    Write-Host ""
}
