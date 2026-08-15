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
    Clock      = [char]0xF017   # fa-clock-o - Font Awesome codepoint, within
                                  # the Basic Multilingual Plane so a plain
                                  # [char] cast is safe (nerd-md icons above
                                  # U+FFFF need [char]::ConvertFromUtf32
                                  # instead, since [char] only holds one
                                  # UTF-16 code unit)
    Spinner    = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
}

# =====================================================================
# Logging state
# =====================================================================

$script:LogPath      = $null
$script:LogMarkdown  = $false
$script:SpinnerJob   = $null
$script:SpinnerStop  = $null

# Reset the C# quit flag if the type is already compiled from a
# previous run in this session - otherwise re-running after a Shift+Q
# quit causes the script to quit immediately on the next run.
if ('SpinnerWorker' -as [type]) {
    [SpinnerWorker]::QuitRequested = $false
}

# =====================================================================
# Public: graceful quit via Shift+Q.
#
# Ctrl+C on a signal thread with no PS runspace crashes the process
# (a known PowerShell limitation that can't be worked around cleanly
# without moving the handler entirely into C#). Instead, call
# Img-PollQuit at the start of each file's processing block. If the
# user pressed Shift+Q since the last check, it returns $true and the
# caller should break its loop cleanly.
# =====================================================================

function Img-ResetQuitState {
    <#
        Call once at the start of each script run. The SpinnerWorker C#
        class is compiled once per PS session and its static fields persist
        between runs, so without this a Shift+Q from a previous run would
        immediately re-trigger the next one.
    #>
    if ('SpinnerWorker' -as [type]) {
        [SpinnerWorker]::ResetQuitState()
    }
}

function Img-PollQuit {
    <#
        Returns $true if Shift+Q or Shift+Escape has been pressed.
        Key detection runs in the C# spinner thread via Console.KeyAvailable,
        no PS runspace involved.
    #>
    if ('SpinnerWorker' -as [type]) {
        return [SpinnerWorker]::QuitRequested
    }
    return $false
}

function Img-IsForceQuit {
    <#
        Returns $true specifically if Shift+Escape was pressed (force quit).
        Used by the caller to decide whether to clean up bridge temp files
        and skip the summary, versus just stopping the loop cleanly.
    #>
    if ('SpinnerWorker' -as [type]) {
        return [SpinnerWorker]::ForceQuitRequested
    }
    return $false
}

function Img-SetActiveProcess {
    <#
        Register the currently-running encoder process so Shift+Escape can
        kill it immediately. Call before each encoder invocation, clear
        after with Img-SetActiveProcess $null.
    #>
    param([System.Diagnostics.Process]$Process)
    if ('SpinnerWorker' -as [type]) {
        [SpinnerWorker]::ActiveProcess = $Process
    }
}

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
# Spinner worker C# class - compiled once at module load
# =====================================================================

if (-not ("SpinnerWorker" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Threading;

public class SpinnerWorker {
    // Shift+Q: finish current file then stop.
    public static volatile bool QuitRequested = false;
    // Shift+Escape: kill the current encoder process and stop immediately.
    public static volatile bool ForceQuitRequested = false;
    // Set to the active encoder process so forced quit can kill it.
    public static volatile Process ActiveProcess = null;

    // Call this at the start of each script run to clear state from any
    // previous run in the same PS session.
    public static void ResetQuitState() {
        QuitRequested      = false;
        ForceQuitRequested = false;
        ActiveProcess      = null;
    }

    private string[] frames;
    private DateTime startTime;
    private string prefix;
    private string labelTrunc;
    private dynamic ui;
    private int frameCount;
    private ManualResetEvent stopEvent;

    public SpinnerWorker(string[] frames, DateTime startTime, string prefix,
                         string labelTrunc, dynamic ui, int frameCount,
                         ManualResetEvent stopEvent) {
        this.frames     = frames;
        this.startTime  = startTime;
        this.prefix     = prefix;
        this.labelTrunc = labelTrunc;
        this.ui         = ui;
        this.frameCount = frameCount;
        this.stopEvent  = stopEvent;
    }

    public void Run() {
        int i = 0;
        while (!stopEvent.WaitOne(100)) {

            // Poll for Shift+Q (graceful) and Shift+Esc (forced) without blocking.
            while (Console.KeyAvailable) {
                ConsoleKeyInfo k = Console.ReadKey(true);
                if ((k.Modifiers & ConsoleModifiers.Shift) != 0) {
                    if (k.Key == ConsoleKey.Q) {
                        QuitRequested = true;
                    }
                    else if (k.Key == ConsoleKey.Escape) {
                        ForceQuitRequested = true;
                        QuitRequested      = true;
                        // Kill the active process immediately.
                        Process p = ActiveProcess;
                        if (p != null) {
                            try { p.Kill(); } catch {}
                        }
                    }
                }
            }

            TimeSpan elapsed = DateTime.Now - startTime;
            int totalSecs = (int)elapsed.TotalSeconds;
            int totalMins = (int)elapsed.TotalMinutes;
            int secs      = elapsed.Seconds;

            string ts = totalSecs < 60
                ? totalSecs.ToString() + "s"
                : totalMins.ToString() + "m " + secs.ToString() + "s";

            string frame = frames[i % frameCount];
            string hint;
            if (ForceQuitRequested) {
                hint = " [force quitting...]";
            } else if (QuitRequested) {
                hint = " [quitting after this file...]";
            } else {
                hint = "   [Shift+Q: quit  Shift+Esc: force quit]";
            }
            string line = "  " + prefix + " " + labelTrunc + "  " + frame + "  " + ts + hint;

            ui.Write("\r" + line);
            i++;
        }
        // Clear the spinner line
        ui.Write("\r" + new string(' ', 80) + "\r");
    }
}
"@
}

# =====================================================================
# Public: spinner — start / stop
#
# Runs in a background thread using compiled C# with proper synchronization.
# Uses ManualResetEvent for reliable thread shutdown.
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
    $startTime = [DateTime]::Now

    $prefix =
        if ($FileTotal -gt 0) {
            "[$FileIndex/$FileTotal]"
        }
        else {
            ''
        }

    # Shared stop-signal using .NET synchronization primitive
    $script:SpinnerStop = [System.Threading.ManualResetEvent]::new($false)
    $stopEvent = $script:SpinnerStop

    $labelTrunc = Img-TruncatePath -Path $Label -MaxChars 40
    $ui = $Host.UI

    # Create the C# worker object
    $frameArray = [string[]]$frames
    $frameCount = $frameArray.Length
    
    try {
        $worker = [SpinnerWorker]::new($frameArray, $startTime, $prefix, $labelTrunc, $ui, $frameCount, $stopEvent)
        $script:SpinnerJob = [System.Threading.Thread]::new([System.Threading.ThreadStart]$worker.Run)
        $script:SpinnerJob.IsBackground = $true
        $script:SpinnerJob.Start()
    }
    catch {
        Write-Verbose "Spinner failed to start: $_"
        $script:SpinnerJob = $null
        if ($null -ne $script:SpinnerStop) {
            $script:SpinnerStop.Dispose()
        }
        $script:SpinnerStop = $null
    }
}

function Img-StopSpinner {
    if ($null -ne $script:SpinnerStop) {
        try {
            # Signal the thread to stop
            $script:SpinnerStop.Set() | Out-Null
            
            # Wait for thread to exit
            if ($null -ne $script:SpinnerJob) {
                [void]$script:SpinnerJob.Join(1000)
            }
        }
        catch {
            Write-Verbose "Error stopping spinner: $_"
        }
        finally {
            # Clean up resources
            $script:SpinnerStop.Dispose()
            $script:SpinnerStop = $null
            $script:SpinnerJob  = $null
        }
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
        [Nullable[TimeSpan]]$Elapsed,
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

    $timeText = ''
    if ($null -ne $Elapsed) {
        $timeStr = if ($Elapsed.TotalSeconds -lt 60) {
            "{0:N1}s" -f $Elapsed.TotalSeconds
        }
        else {
            "$([int]$Elapsed.TotalMinutes)m $($Elapsed.Seconds)s"
        }
        $timeText = "  $($script:NF.Clock) $timeStr"
    }

    $line = "$glyph $display : $origStr $($script:NF.Arrow) $resultStr ($sign$percent%)$tagText$timeText"

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
