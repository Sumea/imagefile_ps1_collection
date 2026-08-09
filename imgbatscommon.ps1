<#
    common.ps1 - Shared output, progress, and logging functions
    for the image batch converter family.

    Dot-source this at the top of each script:
        . (Join-Path $PSScriptRoot 'common.ps1')

    All public functions are prefixed Img- to avoid any clashes with
    built-in PowerShell cmdlets or anything else on PATH.
#>

# =====================================================================
# Nerd-font glyphs and spinner frames
# =====================================================================

$script:NF = @{
    Arrow      = '→'      # result separator  (nf-md-arrow_right)
    Saved      = ''      # green savings      (nf-md-arrow_down_bold)
    Grew       = ''      # yellow - got bigger (nf-md-arrow_up_bold)
    Same       = '󰁔'      # no change          (nf-md-equal)
    Skip       = ''      # already done       (nf-md-skip_next)
    Warn       = ''      # warning            (nf-md-alert)
    Ok         = ''      # success tick       (nf-md-check_bold)
    Bridge     = ''      # bridge/decode step (nf-md-transit_connection)
    Encode     = ''      # encoding step      (nf-md-image_edit)
    Log        = ''      # log file           (nf-md-file_document)
    Spinner    = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
}

# =====================================================================
# Logging state
# =====================================================================

$script:LogPath      = $null
$script:LogMarkdown  = $false
$script:SpinnerJob   = $null
$script:SpinnerStop  = $null

# =====================================================================
# Public: initialise logging for a run
# =====================================================================

function Img-StartLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Markdown
    )

    $script:LogPath     = $Path
    $script:LogMarkdown = $Markdown

    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $header =
        if ($Markdown) {
            "# Image batch log`n_Started: $ts_`n"
        }
        else {
            "Image batch log — $ts`n" + ('─' * 60)
        }

    Set-Content -LiteralPath $Path -Value $header -Encoding UTF8
    Write-Host "$($script:NF.Log) Logging to $Path" -ForegroundColor DarkGray
}

function script:Write-Log {
    param([string]$Line)
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $Line -Encoding UTF8
    }
}

# =====================================================================
# Public: file-name truncation helper
# =====================================================================

function Img-TruncatePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxChars = 45
    )

    if ($Path.Length -le $MaxChars) {
        return $Path
    }

    return '…' + $Path.Substring($Path.Length - ($MaxChars - 1))
}

# =====================================================================
# Public: spinner — start / stop
#
# Runs in a background job so the main thread stays free to call the
# encoder synchronously. The job only writes to the console via the
# RunspacePool trick: instead of a proper job (which can't write to
# the parent's console handle directly), we use a .NET thread with
# $Host.UI shared via a closure — the cleanest pattern for in-process
# spinner animation in PowerShell 5.1 and 7.
# =====================================================================

function Img-StartSpinner {
    param(
        [Parameter(Mandatory)][string]$Label,
        [int]$FileIndex   = 0,
        [int]$FileTotal   = 0
    )

    # Stop any previous spinner that wasn't explicitly stopped
    Img-StopSpinner

    $frames    = $script:NF.Spinner
    $counter   = [System.Text.StringBuilder]::new()
    $startTime = [DateTime]::Now

    $prefix =
        if ($FileTotal -gt 0) {
            "[$FileIndex/$FileTotal]"
        }
        else {
            ''
        }

    # Shared stop-signal: a single-element array so the thread closure
    # can see mutations (plain booleans in closures are copied by value).
    $script:SpinnerStop = @($false)
    $stopRef = $script:SpinnerStop

    $labelTrunc = Img-TruncatePath -Path $Label -MaxChars 40
    $ui = $Host.UI

    $script:SpinnerJob = [System.Threading.Thread]::new([System.Threading.ThreadStart] {
        $i = 0
        while (-not $stopRef[0]) {
            $elapsed = [DateTime]::Now - $startTime
            $ts =
                if ($elapsed.TotalSeconds -lt 60) {
                    "$([int]$elapsed.TotalSeconds)s"
                }
                else {
                    "$([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s"
                }

            $frame = $frames[$i % $frames.Count]
            $line  = "  $prefix $labelTrunc  $frame  $ts   "

            $ui.Write("`r$line")
            [System.Threading.Thread]::Sleep(100)
            $i++
        }
        # Clear the spinner line
        $ui.Write("`r" + (' ' * 72) + "`r")
    })

    $script:SpinnerJob.IsBackground = $true
    $script:SpinnerJob.Start()
}

function Img-StopSpinner {
    if ($null -ne $script:SpinnerStop) {
        $script:SpinnerStop[0] = $true
        $script:SpinnerJob?.Join(500)
        $script:SpinnerStop = $null
        $script:SpinnerJob  = $null
    }
}

# =====================================================================
# Public: per-file result line
# =====================================================================

function Img-WriteResult {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][IO.FileInfo]$OutputFile,
        [string]$Tag,
        [string]$RelativeBase = $PWD.Path
    )

    $saved   = $InputFile.Length - $OutputFile.Length
    $percent = if ($InputFile.Length) { [math]::Round([math]::Abs($saved) * 100 / $InputFile.Length, 1) } else { 0 }

    $origStr   = Img-FormatSize $InputFile.Length
    $resultStr = Img-FormatSize $OutputFile.Length

    $relative  = [IO.Path]::GetRelativePath($RelativeBase, $InputFile.FullName)
    $display   = Img-TruncatePath -Path $relative -MaxChars 45

    if ($saved -gt 0) {
        $glyph = $script:NF.Saved
        $color = 'Green'
        $sign  = '-'
    }
    elseif ($saved -lt 0) {
        $glyph = $script:NF.Grew
        $color = 'Yellow'
        $sign  = '+'
    }
    else {
        $glyph = $script:NF.Same
        $color = 'Gray'
        $sign  = ' '
    }

    $tagText = if ($Tag) { " [$Tag]" } else { '' }
    $line    = "$glyph $display : $origStr $($script:NF.Arrow) $resultStr ($sign$percent%)$tagText"

    Write-Host $line -ForegroundColor $color
    Write-Log $line
}

# =====================================================================
# Public: skip notification
# =====================================================================

function Img-WriteSkip {
    param([string]$Path)

    $display = Img-TruncatePath -Path ([IO.Path]::GetRelativePath($PWD.Path, $Path)) -MaxChars 55
    $line    = "$($script:NF.Skip) $display (skipped)"
    Write-Verbose $line
    Write-Log "SKIP $display"
}

# =====================================================================
# Public: warning wrapper (also logs)
# =====================================================================

function Img-WriteWarning {
    param([string]$Message)
    Write-Warning $Message
    Write-Log "$($script:NF.Warn) WARNING: $Message"
}

# =====================================================================
# Public: summary block
# =====================================================================

function Img-WriteSummary {
    param(
        [long]$TotalOriginal,
        [long]$TotalOutput,
        [int]$SkippedCount = 0
    )

    $saved   = $TotalOriginal - $TotalOutput
    $sign    = if ($saved -ge 0) { '-' } else { '+' }
    $percent =
        if ($TotalOriginal) { [math]::Round([math]::Abs($saved) * 100 / $TotalOriginal, 1) }
        else { 0 }

    $color =
        if ($saved -gt 0)    { 'Green' }
        elseif ($saved -lt 0) { 'Yellow' }
        else                 { 'Gray' }

    $doneLine = "$($script:NF.Ok) Done.  $sign$(Img-FormatSize ([math]::Abs($saved))) ($percent%)"

    Write-Host ""
    Write-Host $doneLine -ForegroundColor $color

    if ($SkippedCount -gt 0) {
        $skipLine = "$($script:NF.Skip) Skipped $SkippedCount file(s) that already had output."
        Write-Host $skipLine -ForegroundColor DarkGray
        Write-Log $skipLine
    }

    Write-Log ""
    Write-Log $doneLine
}

# =====================================================================
# Public: format bytes
# =====================================================================

function Img-FormatSize {
    param([long]$Bytes)

    $abs = [math]::Abs($Bytes)

    switch ($abs) {
        { $_ -ge 1GB } { return "{0:N2} GB" -f ($abs / 1GB) }
        { $_ -ge 1MB } { return "{0:N2} MB" -f ($abs / 1MB) }
        { $_ -ge 1KB } { return "{0:N2} KB" -f ($abs / 1KB) }
        default        { return "$abs B" }
    }
}

# =====================================================================
# Public: -Log parameter resolution helper
# Called once at script startup; returns the resolved path or $null.
# =====================================================================

function Img-ResolveLogPath {
    param(
        [string]$LogParam,
        [string]$ScriptName
    )

    if (-not $LogParam) { return $null }

    # If the user passed just a bare switch value (e.g. -Log without a
    # path), fall back to a datestamped name next to the script.
    if ($LogParam -eq $true -or $LogParam -eq '1') {
        $ts   = Get-Date -Format 'yyyyMMdd-HHmm'
        return Join-Path $PWD.Path "$ScriptName-$ts.log"
    }

    return $LogParam
}
