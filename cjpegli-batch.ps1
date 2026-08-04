[CmdletBinding(
    DefaultParameterSetName='Distance',
    SupportsShouldProcess
)]
param(
    # ----- Quality mode (mutually exclusive) -----
    [Parameter(ParameterSetName='Distance')]
    [Alias("d")]
    [ValidateRange(0,25)]
    [double]$Distance = 1.0,

    [Parameter(ParameterSetName='Quality')]
    [Alias("q")]
    [ValidateRange(1,100)]
    [int]$Quality,

    # ----- Encode options -----
    [Alias("cs")]
    [ValidateRange(1,4)]
    [int]$ChromaSubsampling,

    [Alias("seq")]
    [switch]$Sequential,

    [switch]$Xyb,

    [switch]$StdQuant,

    [Alias("naq")]
    [switch]$NoAdaptiveQuantization,

    [switch]$FixedCode,

    # ----- General -----
    [Alias("s")]
    [AllowEmptyString()]
    [string]$Suffix,

    [Alias("par")]
    [ValidateRange(1,32)]
    [int]$Parallel = 3,

    [Alias("r")]
    [switch]$Recursive,

    [Alias("del")]
    [switch]$RecycleOriginal,

    [Alias("dir")]
    [string]$OutputDirectory,

    [Alias("h","?")]
    [switch]$Help
)

# =====================================================================
# Help text
# =====================================================================
if ($Help) {
@"
    Batch convert common image files to JPEG with cjpegli

Usage:
    cjpegli-batch.ps1 [-d DISTANCE | -q QUALITY] [options]

Quality:
  -d,  -Distance <0-25>          Max butteraugli distance (default 1.0, visually lossless).
                                  Recommended 0.5 .. 3.0.
  -q,  -Quality <1-100>          Quality setting, remapped internally to distance.
                                  Recommended 68 .. 96.

Encode options:
  -cs, -ChromaSubsampling <1-4>  1=420, 2=422, 3=440, 4=444 (4 = no subsampling, highest quality)
  -seq,-Sequential               Use progressive level 0 (sequential JPEG) instead of the
                                  tool's default (progressive level 2). Use this if a
                                  downstream app can't read progressive JPEGs.
       -Xyb                      Convert to XYB colorspace before encoding
       -StdQuant                 Use standard Annex K quantization tables
  -naq,-NoAdaptiveQuantization   Disable adaptive quantization
       -FixedCode                Disable Huffman code optimization. Requires -Sequential
                                  (progressive level 0) - enabled automatically if you
                                  pass -FixedCode without -Sequential.

General:
  -s,  -Suffix <text>            Output suffix override. (default: blank, or "_new" when
                                  the input is already a .jpg/.jpeg AND no -OutputDirectory
                                  is set, to avoid self-overwrite)
  -par,-Parallel <n>              How many cjpegli processes to run at once (default 3).
                                  cjpegli is light on CPU but slow, so running several in
                                  parallel usually finishes a folder faster.
  -r,  -Recursive                Work recursively into subfolders
  -dir <name>                    Put output in a subfolder (created inside each folder
                                  processed; combines with -Recursive)
  -del,-RecycleOriginal          After encoding, send whichever of original/output is
                                  larger to the Recycle Bin
  -h,  -Help                     (You are here)
"@
    return
}

# =====================================================================
# Helper functions
# =====================================================================

function Get-DefaultSuffix {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [string]$OutputDirectory
    )

    if ($OutputDirectory) {
        return ''
    }

    if ($File.Extension -match '\.jpe?g$') {
        return '_new'
    }
    return ''
}

function Get-OutputPath {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [string]$Suffix,
        [string]$OutputDirectory
    )

    $name = "$($File.BaseName)$Suffix.jpg"

    if ($OutputDirectory) {

        $dir = Join-Path $File.DirectoryName $OutputDirectory

        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }

        return Join-Path $dir $name
    }

    return Join-Path $File.DirectoryName $name
}

function Format-Size {
    param([long]$Bytes)

    $abs = [math]::Abs($Bytes)

    switch ($abs) {
        { $_ -ge 1GB } { "{0:N2} GB" -f ($abs / 1GB); break }
        { $_ -ge 1MB } { "{0:N2} MB" -f ($abs / 1MB); break }
        { $_ -ge 1KB } { "{0:N2} KB" -f ($abs / 1KB); break }
        default        { "$abs bytes" }
    }
}

function Update-Statistics {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][IO.FileInfo]$OutputFile
    )

    $script:totalOriginal += $InputFile.Length
    $script:totalOutput   += $OutputFile.Length
}

function Write-ConversionResult {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][IO.FileInfo]$OutputFile
    )

    $saved = $InputFile.Length - $OutputFile.Length

    $sign = if ($saved -ge 0) { "-" } else { "+" }

    $percent =
        if ($InputFile.Length) {
            [math]::Round($OutputFile.Length * 100 / $InputFile.Length, 1)
        }
        else {
            0
        }

    $relative = [IO.Path]::GetRelativePath($PWD.Path, $InputFile.FullName)

    $color =
        if ($saved -gt 0)   { "Green" }
        elseif ($saved -lt 0) { "Yellow" }
        else                { "Gray" }

    Write-Host "$relative : $sign$(Format-Size ([math]::Abs($saved))) ($percent%)" -ForegroundColor $color
}

function Write-Summary {
    $saved = $script:totalOriginal - $script:totalOutput

    $sign = if ($saved -ge 0) { "-" } else { "+" }

    $percent =
        if ($script:totalOriginal) {
            [math]::Round($script:totalOutput * 100 / $script:totalOriginal, 1)
        }
        else {
            0
        }

    $color =
        if ($saved -gt 0)   { "Green" }
        elseif ($saved -lt 0) { "Yellow" }
        else                { "Gray" }

    Write-Host "I'm done boss." -ForegroundColor Cyan
    Write-Host "$sign$(Format-Size ([math]::Abs($saved))) ($percent%)" -ForegroundColor $color
}

function Build-CjpegliArgs {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$UseQuality,
        [double]$Distance,
        [int]$Quality,
        [Nullable[int]]$ChromaSubsampling,
        [Nullable[int]]$ProgressiveLevel,
        [switch]$Xyb,
        [switch]$StdQuant,
        [switch]$NoAdaptiveQuantization,
        [switch]$FixedCode
    )

    $cjpegliArgs = @($InputFile.FullName, $OutputPath)

    if ($UseQuality) {
        $cjpegliArgs += '-q', $Quality
    }
    else {
        $cjpegliArgs += '-d', $Distance
    }

    if ($null -ne $ChromaSubsampling) {
        $subsamplingMap = @{ 1 = '420'; 2 = '422'; 3 = '440'; 4 = '444' }
        $cjpegliArgs += "--chroma_subsampling=$($subsamplingMap[$ChromaSubsampling])"
    }

    if ($null -ne $ProgressiveLevel) {
        $cjpegliArgs += '-p', $ProgressiveLevel
    }

    if ($Xyb)                    { $cjpegliArgs += '--xyb' }
    if ($StdQuant)                { $cjpegliArgs += '--std_quant' }
    if ($NoAdaptiveQuantization)  { $cjpegliArgs += '--noadaptive_quantization' }
    if ($FixedCode)               { $cjpegliArgs += '--fixed_code' }

    return $cjpegliArgs
}

function Invoke-ParallelEncode {
    <#
        Runs a set of cjpegli invocations with up to $MaxConcurrent running
        at once, using background jobs. $ExePath should be a resolved full
        path (not just "cjpegli.exe") so the spawned job process doesn't
        have to re-resolve it against its own copy of PATH.
    #>
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][array]$Tasks,
        [int]$MaxConcurrent = 3
    )

    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($t in $Tasks) { $queue.Enqueue($t) }

    $running = @{}

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {

        while ($running.Count -lt $MaxConcurrent -and $queue.Count -gt 0) {
            $task = $queue.Dequeue()

            $job = Start-Job -ScriptBlock {
                param($Exe, $CmdArgs)
                $outputText = & $Exe --quiet @CmdArgs 2>&1 | Out-String
                [PSCustomObject]@{
                    ExitCode = $LASTEXITCODE
                    Output   = $outputText
                }
            } -ArgumentList $ExePath, $task.Arguments

            $running[$job.Id] = @{ Job = $job; Task = $task }
        }

        Start-Sleep -Milliseconds 150

        $doneIds = @()
        foreach ($id in $running.Keys) {
            $entry = $running[$id]
            if ($entry.Job.State -in 'Completed', 'Failed', 'Stopped') {
                $jobResult = Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue
                Remove-Job -Job $entry.Job -Force

                Write-Output ([PSCustomObject]@{
                    Task         = $entry.Task
                    ExitCode     = $jobResult.ExitCode
                    Output       = $jobResult.Output
                    OutputExists = Test-Path -LiteralPath $entry.Task.OutputPath
                })

                $doneIds += $id
            }
        }
        foreach ($id in $doneIds) { $running.Remove($id) }
    }
}

function Remove-OriginalIfLarger {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$Original,
        [Parameter(Mandatory)][IO.FileInfo]$Output,
        [switch]$Enabled
    )

    if (-not $Enabled) {
        return
    }

    $toDelete =
        if ($Output.Length -lt $Original.Length) { $Original }
        elseif ($Original.Length -lt $Output.Length) { $Output }
        else { $null }

    if (-not $toDelete) {
        return
    }

    if ($PSCmdlet.ShouldProcess($toDelete.FullName, "Send to Recycle Bin")) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $toDelete.FullName,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
    }
}

# =====================================================================
# Resolve "was this actually specified?" ONCE, at script scope.
# =====================================================================

$useQuality        = $PSCmdlet.ParameterSetName -eq 'Quality'
$hasSuffixOverride = $PSBoundParameters.ContainsKey('Suffix')

$chromaSubsamplingValue = if ($PSBoundParameters.ContainsKey('ChromaSubsampling')) { $ChromaSubsampling } else { $null }

if ($FixedCode -and -not $Sequential) {
    Write-Warning "-FixedCode requires progressive level 0; enabling -Sequential automatically."
    $Sequential = $true
}
$progressiveLevelValue = if ($Sequential) { 0 } else { $null }

if ($RecycleOriginal) {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

try {
    $exePath = (Get-Command cjpegli.exe -ErrorAction Stop).Source
}
catch {
    Write-Error "cjpegli.exe was not found on PATH. Make sure it's installed and accessible, then try again."
    return
}

# =====================================================================
# Gather input files
# =====================================================================

$extensions = @('.ppm', '.pnm', '.pfm', '.pam', '.pgx', '.png', '.apng', '.gif', '.jpg', '.jpeg', '.exr')

# -LiteralPath (rather than a wildcard -Path combined with -Include) avoids
# a known PowerShell quirk where that combination can silently miss files
# in folders whose names contain spaces or other special characters.
$files = Get-ChildItem -LiteralPath $PWD.Path -File -Recurse:$Recursive |
    Where-Object { $extensions -contains $_.Extension.ToLower() }

if (-not $files) {
    Write-Warning "No matching image files found."
    return
}

$totalOriginal = 0L
$totalOutput   = 0L

# =====================================================================
# Build task list
# =====================================================================

$tasks = @()

foreach ($file in $files) {

    $suffix =
        if ($hasSuffixOverride) { $Suffix }
        else { Get-DefaultSuffix -File $file -OutputDirectory $OutputDirectory }

    $output = Get-OutputPath -File $file -Suffix $suffix -OutputDirectory $OutputDirectory

    if (Test-Path -LiteralPath $output) {
        Write-Verbose "$output already exists, skipping."
        continue
    }

    $cjpegliArgs = Build-CjpegliArgs `
        -InputFile $file -OutputPath $output `
        -UseQuality $useQuality -Distance $Distance -Quality $Quality `
        -ChromaSubsampling $chromaSubsamplingValue -ProgressiveLevel $progressiveLevelValue `
        -Xyb:$Xyb -StdQuant:$StdQuant -NoAdaptiveQuantization:$NoAdaptiveQuantization -FixedCode:$FixedCode

    Write-Verbose "cjpegli.exe $($cjpegliArgs -join ' ')"

    if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode to $output")) {
        continue
    }

    $tasks += [PSCustomObject]@{
        InputFile  = $file
        OutputPath = $output
        Arguments  = $cjpegliArgs
    }
}

# =====================================================================
# Run and report
# =====================================================================

foreach ($result in (Invoke-ParallelEncode -ExePath $exePath -Tasks $tasks -MaxConcurrent $Parallel)) {

    $task = $result.Task

    if ($result.ExitCode -ne 0) {
        Write-Warning "cjpegli failed (exit code $($result.ExitCode)) for $($task.OutputPath)"
        continue
    }
    if (-not $result.OutputExists) {
        Write-Warning "Expected output file missing: $($task.OutputPath)"
        continue
    }

    $outputFile = Get-Item -LiteralPath $task.OutputPath

    Remove-OriginalIfLarger -Original $task.InputFile -Output $outputFile -Enabled:$RecycleOriginal
    Update-Statistics -InputFile $task.InputFile -OutputFile $outputFile
    Write-ConversionResult -InputFile $task.InputFile -OutputFile $outputFile
}

Write-Summary
