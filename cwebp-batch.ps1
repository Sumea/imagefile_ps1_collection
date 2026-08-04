[CmdletBinding(
    DefaultParameterSetName='Quality',
    SupportsShouldProcess
)]
param(
    # ----- Quality mode (mutually exclusive) -----
    [Parameter(ParameterSetName='Quality')]
    [Alias("q")]
    [ValidateRange(0,100)]
    [double]$Quality = 75,

    [Parameter(ParameterSetName='Lossless')]
    [Alias("z")]
    [ValidateRange(0,9)]
    [int]$LosslessLevel,

    # ----- Encode options -----
    [Alias("nl")]
    [ValidateRange(0,100)]
    [int]$NearLossless,

    [Alias("m")]
    [ValidateRange(0,6)]
    [int]$Method,

    [Alias("aq")]
    [ValidateRange(0,100)]
    [int]$AlphaQuality,

    [Alias("sns")]
    [ValidateRange(0,100)]
    [int]$SpatialNoiseShaping,

    [Alias("f")]
    [ValidateRange(0,100)]
    [int]$FilterStrength,

    [Alias("sharp")]
    [ValidateRange(0,7)]
    [int]$Sharpness,

    [switch]$Strong,
    [switch]$Simple,

    [Alias("yuv")]
    [switch]$SharpYuv,

    [switch]$Exact,

    [switch]$Mt,

    [switch]$LowMemory,

    [ValidateSet('all','none','exif','icc','xmp')]
    [string]$Metadata,

    [ValidateSet('default','photo','picture','drawing','icon','text')]
    [string]$Preset,

    [Alias("rw")]
    [switch]$rewebp,

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
    Batch convert common image files to WebP with cwebp

Usage:
    cwebp-batch.ps1 [-q QUALITY | -z LOSSLESSLEVEL] [options]

Quality (mutually exclusive):
  -q,  -Quality <0-100>          Lossy quality factor (default 75)
  -z,  -LosslessLevel <0-9>      Activates lossless mode at the given
                                  compression level (0=fast .. 9=slowest)

Encode options:
  -nl,   -NearLossless <0-100>   Near-lossless preprocessing. Mainly useful
                                  together with -LosslessLevel; 100=off.
  -m,    -Method <0-6>           Compression method (0=fast, 6=slowest)
  -aq,   -AlphaQuality <0-100>   Transparency-compression quality
  -sns,  -SpatialNoiseShaping <0-100>
  -f,    -FilterStrength <0-100>
  -sharp,-Sharpness <0-7>
         -Strong / -Simple       Filter type (strong vs simple). If both are
                                  given, -Strong wins.
  -yuv,  -SharpYuv               Sharper (slower) RGB->YUV conversion
         -Exact                  Preserve RGB values in transparent areas
         -Mt                     Let cwebp itself use multiple threads.
                                  Caution: combined with -Parallel this can
                                  oversubscribe your CPU - usually better to
                                  leave this off and raise -Parallel instead.
         -LowMemory              Reduce cwebp's own memory usage (slower per
                                  file, but helpful if you're running many
                                  -Parallel instances at once and are tight on RAM)
         -Metadata <all|none|exif|icc|xmp>
         -Preset <default|photo|picture|drawing|icon|text>
  -rw,   -rewebp                 Also include existing .webp files as input
                                  (for re-encoding)

General:
  -s,  -Suffix <text>            Output suffix override. (default: blank, or
                                  "_new" when the input is already .webp AND
                                  no -OutputDirectory is set, to avoid
                                  self-overwrite)
  -par,-Parallel <n>              How many cwebp processes to run at once
                                  (default 3).
  -r,  -Recursive                Work recursively into subfolders
  -dir <name>                    Put output in a subfolder (created inside
                                  each folder processed; combines with -Recursive)
  -del,-RecycleOriginal          After encoding, send whichever of
                                  original/output is larger to the Recycle Bin
  -h,  -Help                     (You are here)
"@
    return
}

# =====================================================================
# Helper functions
# =====================================================================

function Get-DefaultSuffix {
    <#
        cwebp always writes a .webp file. If the input is already .webp
        AND the output lands in the same folder as the input, an empty
        suffix would try to overwrite the source file, so default to
        "_new" in that case. If an -OutputDirectory subfolder is set,
        there's no collision risk, so skip the fallback.
    #>
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [string]$OutputDirectory
    )

    if ($OutputDirectory) {
        return ''
    }

    if ($File.Extension -eq '.webp') {
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

    $name = "$($File.BaseName)$Suffix.webp"

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

function Build-CwebpArgs {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$UseLossless,
        [double]$Quality,
        [int]$LosslessLevel,
        [Nullable[int]]$NearLossless,
        [Nullable[int]]$Method,
        [Nullable[int]]$AlphaQuality,
        [Nullable[int]]$SpatialNoiseShaping,
        [Nullable[int]]$FilterStrength,
        [Nullable[int]]$Sharpness,
        [switch]$Strong,
        [switch]$Simple,
        [switch]$SharpYuv,
        [switch]$Exact,
        [switch]$Mt,
        [switch]$LowMemory,
        [string]$Metadata,
        [string]$Preset
    )

    $cwebpArgs = @()

    # -preset must come first so any explicit flags below can still
    # override the values it implies (per cwebp's own help text).
    if ($Preset) {
        $cwebpArgs += '-preset', $Preset
    }

    if ($UseLossless) {
        $cwebpArgs += '-z', $LosslessLevel
    }
    else {
        $cwebpArgs += '-q', $Quality
    }

    if ($null -ne $NearLossless)        { $cwebpArgs += '-near_lossless', $NearLossless }
    if ($null -ne $Method)              { $cwebpArgs += '-m', $Method }
    if ($null -ne $AlphaQuality)        { $cwebpArgs += '-alpha_q', $AlphaQuality }
    if ($null -ne $SpatialNoiseShaping) { $cwebpArgs += '-sns', $SpatialNoiseShaping }
    if ($null -ne $FilterStrength)      { $cwebpArgs += '-f', $FilterStrength }
    if ($null -ne $Sharpness)           { $cwebpArgs += '-sharpness', $Sharpness }
    if ($Strong)                        { $cwebpArgs += '-strong' }
    if ($Simple)                        { $cwebpArgs += '-nostrong' }
    if ($SharpYuv)                      { $cwebpArgs += '-sharp_yuv' }
    if ($Exact)                         { $cwebpArgs += '-exact' }
    if ($Mt)                            { $cwebpArgs += '-mt' }
    if ($LowMemory)                     { $cwebpArgs += '-low_memory' }
    if ($Metadata)                      { $cwebpArgs += '-metadata', $Metadata }

    # Input file and -o output come last, per cwebp's documented usage.
    $cwebpArgs += $InputFile.FullName, '-o', $OutputPath

    return $cwebpArgs
}

function Invoke-ParallelEncode {
    <#
        Runs a set of cwebp invocations with up to $MaxConcurrent running
        at once, using background jobs. Streams results out one at a time
        as each job finishes (completion order, not submission order).

        Note: cwebp's own quiet flag is single-dash (-quiet), unlike
        cjxl/cjpegli's double-dash --quiet.
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
                $outputText = & $Exe -quiet @CmdArgs 2>&1 | Out-String
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

$useLossless       = $PSCmdlet.ParameterSetName -eq 'Lossless'
$hasSuffixOverride = $PSBoundParameters.ContainsKey('Suffix')

$nearLosslessValue          = if ($PSBoundParameters.ContainsKey('NearLossless'))          { $NearLossless }          else { $null }
$methodValue                = if ($PSBoundParameters.ContainsKey('Method'))                { $Method }                else { $null }
$alphaQualityValue          = if ($PSBoundParameters.ContainsKey('AlphaQuality'))          { $AlphaQuality }          else { $null }
$spatialNoiseShapingValue   = if ($PSBoundParameters.ContainsKey('SpatialNoiseShaping'))   { $SpatialNoiseShaping }   else { $null }
$filterStrengthValue        = if ($PSBoundParameters.ContainsKey('FilterStrength'))        { $FilterStrength }       else { $null }
$sharpnessValue             = if ($PSBoundParameters.ContainsKey('Sharpness'))              { $Sharpness }            else { $null }

if ($PSBoundParameters.ContainsKey('NearLossless') -and -not $useLossless) {
    Write-Warning "-NearLossless normally only has an effect together with -LosslessLevel; passing it through anyway."
}

if ($Strong -and $Simple) {
    Write-Warning "Both -Strong and -Simple specified; using -Strong."
    $Simple = $false
}

if ($RecycleOriginal) {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

# =====================================================================
# Gather input files
# =====================================================================

try {
    $exePath = (Get-Command cwebp.exe -ErrorAction Stop).Source
}
catch {
    Write-Error "cwebp.exe was not found on PATH. Make sure it's installed and accessible, then try again."
    return
}

$extensions = @('.png', '.jpg', '.jpeg', '.tif', '.tiff', '.bmp', '.gif')
if ($rewebp) {
    $extensions += '.webp'
}

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

    $cwebpArgs = Build-CwebpArgs `
        -InputFile $file -OutputPath $output `
        -UseLossless $useLossless -Quality $Quality -LosslessLevel $LosslessLevel `
        -NearLossless $nearLosslessValue -Method $methodValue -AlphaQuality $alphaQualityValue `
        -SpatialNoiseShaping $spatialNoiseShapingValue -FilterStrength $filterStrengthValue `
        -Sharpness $sharpnessValue -Strong:$Strong -Simple:$Simple -SharpYuv:$SharpYuv `
        -Exact:$Exact -Mt:$Mt -LowMemory:$LowMemory -Metadata $Metadata -Preset $Preset

    Write-Verbose "cwebp.exe $($cwebpArgs -join ' ')"

    if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode to $output")) {
        continue
    }

    $tasks += [PSCustomObject]@{
        InputFile  = $file
        OutputPath = $output
        Arguments  = $cwebpArgs
    }
}

# =====================================================================
# Run and report
# =====================================================================

foreach ($result in (Invoke-ParallelEncode -ExePath $exePath -Tasks $tasks -MaxConcurrent $Parallel)) {

    $task = $result.Task

    if ($result.ExitCode -ne 0) {
        Write-Warning "cwebp failed (exit code $($result.ExitCode)) for $($task.OutputPath)"
        if ($result.Output) { Write-Warning $result.Output.Trim() }
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
