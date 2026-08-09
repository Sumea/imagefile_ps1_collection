[CmdletBinding(SupportsShouldProcess)]
param(
    # ----- Quality -----
    [Alias("q")]
    [ValidateRange(0,63)]
    [int]$Quality = 18,

    [Alias("qa")]
    [ValidateRange(0,100)]
    [int]$QAlpha,

    [Alias("e")]
    [ValidateRange(0,10)]
    [int]$Effort = 9,

    [Alias("l")]
    [switch]$Lossless,

    # ----- Encode options -----
    [Alias("j")]
    [string]$Jobs = 'all',

    [ValidateSet(8,10,12)]
    [int]$Depth = 10,

    [Alias("y")]
    [ValidateSet('auto','444','422','420','400')]
    [string]$Yuv = '444',

    [Alias("p")]
    [switch]$Premultiply,

    [Alias("prog")]
    [switch]$Progressive,

    [switch]$SharpYuv,

    [Alias("rng")]
    [ValidateSet('limited','full')]
    [string]$Range,

    [Alias("noov")]
    [switch]$NoOverwrite,

    # ----- General -----
    [Alias("sfx")]
    [AllowEmptyString()]
    [string]$Suffix,

    [Alias("r")]
    [switch]$Recursive,

    [Alias("del")]
    [switch]$RecycleOriginal,

    [Alias("dir")]
    [string]$OutputDirectory,

    [string]$Log,

    [Alias("h","?")]
    [switch]$Help
)

. (Join-Path $PSScriptRoot 'imgbatscommon.ps1')

# =====================================================================
# Help text
# =====================================================================
if ($Help) {
@"
    Batch convert JPEG/PNG/y4m files to AVIF with avifenc

    Single-threaded at the script level - avifenc already uses many CPU
    cores internally per encode, so process-level parallelism would
    oversubscribe the CPU rather than help.

Usage:
    avifenc-bats.ps1 [options]

Quality:
  -q,   -Quality <0-63>          Direct aom cq-level. LOWER = higher quality.
                                  Encoded via '-a end-usage=q -a color:cq-level=N'.
                                  Default 18.
  -qa,  -QAlpha <0-100>          avifenc --qalpha (100 = lossless alpha). Optional.
  -e,   -Effort <0-10>           Effort, higher = more effort/slower (inverted
                                  from avifenc's own -s/speed). Default 9.
  -l,   -Lossless                Set all defaults to encode losslessly.

Encode options:
  -j,   -Jobs <n|all>            Internal worker threads per avifenc invocation.
  -depth -Depth <8|10|12>        Output bit depth. Default 10.
  -y,   -Yuv <auto|444|422|420|400>  Chroma subsampling. Default 444.
  -p,   -Premultiply
  -prog,-Progressive
        -SharpYuv
  -rng, -Range <limited|full>
  -noov,-NoOverwrite

General:
  -sfx, -Suffix <text>           Output suffix override. (".ll" for -Lossless)
  -r,   -Recursive               Work recursively into subfolders
  -dir <name>                    Output subfolder
  -del, -RecycleOriginal         Send larger of original/output to Recycle Bin
  -Log [path]                    Write a log file. Omit path for auto-named log.
  -h,   -Help                    (You are here)
"@
    return
}

# =====================================================================
# Helpers
# =====================================================================

function Get-DefaultSuffix {
    param([switch]$Lossless)
    return ($Lossless ? '.ll' : '')
}

function Get-OutputPath {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [string]$Suffix,
        [string]$OutputDirectory
    )

    $name = "$($File.BaseName)$Suffix.avif"

    if ($OutputDirectory) {
        $dir = Join-Path $File.DirectoryName $OutputDirectory
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        return Join-Path $dir $name
    }

    return Join-Path $File.DirectoryName $name
}

function Build-AvifencArgs {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$Quality,
        [Nullable[int]]$QAlpha,
        [int]$Effort,
        [switch]$Lossless,
        [string]$Jobs,
        [Nullable[int]]$Depth,
        [string]$Yuv,
        [switch]$Premultiply,
        [switch]$Progressive,
        [switch]$SharpYuv,
        [string]$Range,
        [switch]$NoOverwrite
    )

    $avifArgs = @()
    $avifArgs += '-a', 'end-usage=q'
    $avifArgs += '-a', "color:cq-level=$Quality"

    if ($null -ne $QAlpha)  { $avifArgs += '--qalpha', $QAlpha }
    if ($Lossless)           { $avifArgs += '--lossless' }

    $avifArgs += '-s', (10 - $Effort)

    if ($Jobs)               { $avifArgs += '-j', $Jobs }
    if ($null -ne $Depth)    { $avifArgs += '-d', $Depth }
    if ($Yuv -and $Yuv -ne 'auto') { $avifArgs += '-y', $Yuv }
    if ($Premultiply)        { $avifArgs += '--premultiply' }
    if ($Progressive)        { $avifArgs += '--progressive' }
    if ($SharpYuv)           { $avifArgs += '--sharpyuv' }
    if ($Range)              { $avifArgs += '-r', $Range }
    if ($NoOverwrite)        { $avifArgs += '--no-overwrite' }

    $avifArgs += $InputFile.FullName, $OutputPath
    return $avifArgs
}

function Remove-OriginalIfLarger {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$Original,
        [Parameter(Mandatory)][IO.FileInfo]$Output,
        [switch]$Enabled
    )

    if (-not $Enabled) { return }

    $toDelete =
        if ($Output.Length -lt $Original.Length) { $Original }
        elseif ($Original.Length -lt $Output.Length) { $Output }
        else { $null }

    if (-not $toDelete) { return }

    if ($PSCmdlet.ShouldProcess($toDelete.FullName, "Send to Recycle Bin")) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $toDelete.FullName,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
    }
}

# =====================================================================
# Init
# =====================================================================

$hasSuffixOverride = $PSBoundParameters.ContainsKey('Suffix')
$qAlphaValue       = if ($PSBoundParameters.ContainsKey('QAlpha')) { $QAlpha } else { $null }
$depthValue        = if ($PSBoundParameters.ContainsKey('Depth'))  { $Depth }  else { $null }

if ($RecycleOriginal) {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

try {
    $exePath = (Get-Command avifenc.exe -ErrorAction Stop).Source
}
catch {
    Write-Error "avifenc.exe was not found on PATH."
    return
}

$logPath = Img-ResolveLogPath -LogParam $Log -ScriptName 'avifenc-bats'
if ($logPath) { Img-StartLog -Path $logPath }

# =====================================================================
# Gather files
# =====================================================================

$extensions = @('.jpg', '.jpeg', '.png', '.y4m')

$files = Get-ChildItem -LiteralPath $PWD.Path -File -Recurse:$Recursive |
    Where-Object { $extensions -contains $_.Extension.ToLower() }

if (-not $files) {
    Img-WriteWarning "No matching image files found."
    return
}

Write-Host "  $($files.Count) file(s) to process" -ForegroundColor DarkGray

$totalOriginal = 0L
$totalOutput   = 0L
$fileIndex     = 0

# =====================================================================
# Main loop
# =====================================================================

foreach ($file in $files) {

    $fileIndex++

    $suffix =
        if ($hasSuffixOverride) { $Suffix }
        else { Get-DefaultSuffix -Lossless:$Lossless }

    $output = Get-OutputPath -File $file -Suffix $suffix -OutputDirectory $OutputDirectory

    if (Test-Path -LiteralPath $output) {
        Img-WriteSkip -Path $file.FullName
        continue
    }

    $avifArgs = Build-AvifencArgs `
        -InputFile $file -OutputPath $output `
        -Quality $Quality -QAlpha $qAlphaValue -Effort $Effort -Lossless:$Lossless `
        -Jobs $Jobs -Depth $depthValue -Yuv $Yuv `
        -Premultiply:$Premultiply -Progressive:$Progressive -SharpYuv:$SharpYuv -Range $Range `
        -NoOverwrite:$NoOverwrite

    Write-Verbose "avifenc.exe $($avifArgs -join ' ')"

    if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode to $output")) {
        continue
    }

    Img-StartSpinner -Label $file.Name -FileIndex $fileIndex -FileTotal $files.Count

    $outputText = & $exePath @avifArgs 2>&1 | Out-String

    Img-StopSpinner

    if ($LASTEXITCODE -ne 0) {
        Img-WriteWarning "avifenc failed (exit $LASTEXITCODE) for $($file.FullName)"
        if ($outputText) { Img-WriteWarning $outputText.Trim() }
        continue
    }

    if (-not (Test-Path -LiteralPath $output)) {
        Img-WriteWarning "Expected output missing: $output"
        continue
    }

    $outputFile = Get-Item -LiteralPath $output

    Remove-OriginalIfLarger -Original $file -Output $outputFile -Enabled:$RecycleOriginal
    $totalOriginal += $file.Length
    $totalOutput   += $outputFile.Length
    Img-WriteResult -InputFile $file -OutputFile $outputFile
}

Img-WriteSummary -TotalOriginal $totalOriginal -TotalOutput $totalOutput
