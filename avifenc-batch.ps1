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
    [int]$Depth = '10',

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

    [Alias("h","?")]
    [switch]$Help
)

# =====================================================================
# Help text
# =====================================================================
if ($Help) {
@"
    Batch convert JPEG/PNG/y4m files to AVIF with avifenc

Usage:
    avifenc-batch.ps1 [options]

Quality:
  -q,   -Quality <0-63>          Direct aom cq-level (constant-quality
                                  level), scoped to the color planes only
                                  (alpha is controlled separately by
                                  -QAlpha, unaffected by this). LOWER =
                                  higher quality - the OPPOSITE direction
                                  from avifenc's own -q/--qcolor scale,
                                  which this replaces. Encoded via
                                  '-a end-usage=q -a color:cq-level=N',
                                  the confirmed-current recommended
                                  approach for best offline AVIF quality
                                  (not the same as 'cq' end-usage, which
                                  is for bitrate-capped streaming).
                                  Default 18.
  -qa,  -QAlpha <0-100>          avifenc's own --qalpha (100 = lossless).
                                  Optional - if omitted, avifenc's own
                                  default applies.
  -e,   -Effort <0-10>           Effort, HIGHER = more effort/slower - the
                                  opposite scale from avifenc's own -s/speed
                                  flag, converted internally (effort 8 ->
                                  speed 2). Default 9.
  -l,   -Lossless                Set all defaults to encode losslessly.

Encode options:
  -j,   -Jobs <n|all>            Worker threads used per avifenc process
                                  (this is avifenc internal
                                  multithreading limiting switch. Not parallel threads switch). (Default: all)
  -depth -Depth <8|10|12>        Output bit depth per channel. (JPEG/PNG input only) Default 10 as recommended by 8 out of 10 doctors.
  -y,   -Yuv <auto|444|422|420|400>  Chroma subsampling. (Default: 444 as recommended by 4 out of 5 doctors.)
  -p,   -Premultiply             Premultiply color by the alpha channel.
  -prog,-Progressive             Encode a simple layered image for progressive rendering.
        -SharpYuv                Use sharp RGB->YUV420 conversion (only applies if -Yuv 420).
  -rng, -Range <limited|full>    YUV range. (JPEG/PNG only, tool default: full)
  -noov,-NoOverwrite             Extra safety net: tells avifenc itself to refuse to
                                  overwrite an existing output file (the script already
                                  skips files whose output exists, so this mainly guards
                                  against a race if something else creates the file first).

General:
  -sfx, -Suffix <text>           Output suffix override. (default: blank, or ".ll" when
                                  -Lossless is set)
  -r,   -Recursive               Work recursively into subfolders
  -dir <name>                    Put output in a subfolder (created inside each folder
                                  processed; combines with -Recursive)
  -del, -RecycleOriginal         After encoding, send whichever of original/output is
                                  larger to the Recycle Bin
  -h,   -Help                    (You are here)

"@
    return
}

# =====================================================================
# Helper functions
# =====================================================================

function Get-DefaultSuffix {
    <#
        avifenc always writes a .avif file, which never collides with the
        jpg/png/y4m source extensions, so - unlike the JPEG-output tools -
        there's no need for a "_new" self-overwrite fallback here.
    #>
    param([switch]$Lossless)

    if ($Lossless) {
        return '.ll'
    }
    return ''
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

function Build-AvifencArgs {
    <#
        avifenc's documented syntax is "avifenc [options] input output",
        so options are placed first and the two positional paths last.
    #>
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

    # -a end-usage=q -a color:cq-level=N is the confirmed-current
    # recommended approach for best offline AVIF quality (constant
    # quantizer, not the bitrate-capped 'cq' end-usage). Scoped to
    # color: specifically so it doesn't also silently override alpha
    # quality - QAlpha stays an independent knob.
	$avifArgs += '--min', '0'
	$avifArgs +=	'--max', '63'	
    $avifArgs += '-a', 'end-usage=q'
    $avifArgs += '-a', "color:cq-level=$Quality"
	$avifArgs += '-a', 'color:sharpness=2'
	$avifArgs += '-a', 'color:enable-chroma-deltaq=1'

    if ($null -ne $QAlpha) {
        $avifArgs += '--qalpha', $QAlpha
    }
    if ($Lossless) {
        $avifArgs += '--lossless'
    }

    $speed = 10 - $Effort
    $avifArgs += '-s', $speed

    if ($Jobs) {
        $avifArgs += '-j', $Jobs
    }
    if ($null -ne $Depth) {
        $avifArgs += '-d', $Depth
    }
    if ($Yuv -and $Yuv -ne '444') {
        $avifArgs += '-y', $Yuv
    }
    if ($Premultiply) {
        $avifArgs += '--premultiply'
    }
    if ($Progressive) {
        $avifArgs += '--progressive'
    }
    if ($SharpYuv) {
        $avifArgs += '--sharpyuv'
    }
    if ($Range) {
        $avifArgs += '-r', $Range
    }
    if ($NoOverwrite) {
        $avifArgs += '--no-overwrite'
    }

    $avifArgs += $InputFile.FullName, $OutputPath

    return $avifArgs
}

function Invoke-AvifencEncode {
    <#
        avifenc has no --quiet/-v flag in its help output, so its own
        progress/summary text is suppressed on success - but captured and
        shown on failure, so a real error message is visible instead of
        just an exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $outputText = & $ExePath @Arguments 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "avifenc failed (exit code $LASTEXITCODE) for $OutputPath"
        if ($outputText) { Write-Warning $outputText.Trim() }
        return $null
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Write-Warning "Expected output file missing: $OutputPath"
        return $null
    }

    return Get-Item -LiteralPath $OutputPath
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

$hasSuffixOverride = $PSBoundParameters.ContainsKey('Suffix')
$qAlphaValue = if ($PSBoundParameters.ContainsKey('QAlpha')) { $QAlpha } else { $null }
$depthValue  = if ($PSBoundParameters.ContainsKey('Depth'))  { $Depth }  else { $null }

if ($RecycleOriginal) {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

try {
    $exePath = (Get-Command avifenc.exe -ErrorAction Stop).Source
}
catch {
    Write-Error "avifenc.exe was not found on PATH. Make sure it's installed and accessible, then try again."
    return
}

# =====================================================================
# Gather input files
# =====================================================================

$extensions = @('.jpg', '.jpeg', '.png', '.y4m')

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
# Main loop
# =====================================================================

foreach ($file in $files) {

    $suffix =
        if ($hasSuffixOverride) { $Suffix }
        else { Get-DefaultSuffix -Lossless:$Lossless }

    $output = Get-OutputPath -File $file -Suffix $suffix -OutputDirectory $OutputDirectory

    if (Test-Path -LiteralPath $output) {
        Write-Verbose "$output already exists, skipping."
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

    $outputFile = Invoke-AvifencEncode -ExePath $exePath -Arguments $avifArgs -OutputPath $output
    if (-not $outputFile) {
        continue
    }

    Remove-OriginalIfLarger -Original $file -Output $outputFile -Enabled:$RecycleOriginal
    Update-Statistics -InputFile $file -OutputFile $outputFile
    Write-ConversionResult -InputFile $file -OutputFile $outputFile
}

Write-Summary
