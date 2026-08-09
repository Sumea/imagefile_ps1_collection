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
# Runs in a background thread. Uses a .NET object to encapsulate state
# and avoid PowerShell script block execution in the thread.
# =====================================================================

$script:SpinnerWorkerCode = @"
public class SpinnerWorker {
    private string[] frames;
    private DateTime startTime;
    private string prefix;
    private string labelTrunc;
    private dynamic ui;
    private int frameCount;
    private bool[] stopRef;

    public SpinnerWorker(string[] frames, DateTime startTime, string prefix, string labelTrunc, dynamic ui, int frameCount, bool[] stopRef) {
        this.frames = frames;
        this.startTime = startTime;
        this.prefix = prefix;
        this.labelTrunc = labelTrunc;
        this.ui = ui;
        this.frameCount = frameCount;
        this.stopRef = stopRef;
    }

    public void Run() {
        int i = 0;
        while (!stopRef[0]) {
            TimeSpan elapsed = DateTime.Now - startTime;
            int totalSecs = (int)elapsed.TotalSeconds;
            int totalMins = (int)elapsed.TotalMinutes;
            int secs = elapsed.Seconds;

            string ts;
            if (totalSecs < 60) {
                ts = totalSecs.ToString() + "s";
            } else {
                ts = totalMins.ToString() + "m " + secs.ToString() + "s";
            }

            string frame = frames[i % frameCount];
            string line = "  " + prefix + " " + labelTrunc + "  " + frame + "  " + ts + "   ";

            ui.Write("\r" + line);
            System.Threading.Thread.Sleep(100);
            i++;
        }
        // Clear the spinner line
        ui.Write("\r" + new string(' ', 72) + "\r");
    }
}
"@

# Add the C# type once at script load time
try {
    Add-Type -TypeDefinition $script:SpinnerWorkerCode -ErrorAction Stop
} catch {
    # Type may already be loaded
}

function Img-StartSpinner {
    param(
        [Parameter(Mandatory)][string]$Label,
        [int]$FileIndex   = 0,
        [int]$FileTotal   = 0
    )

    # Stop any previous spinner that wasn't explicitly stopped
    Img-StopSpinner

    $frames    = $script:NF.Spinner
    $startTime = [DateTime]::Now

    $prefix =
        if ($FileTotal -gt 0) {
            "[$FileIndex/$FileTotal]"
        }
        else {
            ''
        }

    # Shared stop-signal
    $script:SpinnerStop = @($false)
    $stopRef = $script:SpinnerStop

    $labelTrunc = Img-TruncatePath -Path $Label -MaxChars 40
    $ui = $Host.UI

    # Create the C# worker object
    $frameArray = [string[]]$frames
    $frameCount = $frameArray.Length
    $worker = [SpinnerWorker]::new($frameArray, $startTime, $prefix, $labelTrunc, $ui, $frameCount, $stopRef)

    # Create thread with the worker's Run method
    $script:SpinnerJob = [System.Threading.Thread]::new([System.Threading.ThreadStart]$worker.Run)
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
