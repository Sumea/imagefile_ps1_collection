#!/usr/bin/env pwsh
#Requires -Version 7

<#
    Animated GIF/APNG/JXL -> animated AVIF, via ffmpeg's libaom-av1 encoder.

    Worth knowing before relying on this: unlike the WebP animated path
    (batch-webp.ps1), ffmpeg's animated AVIF support is comparatively
    less battle-tested - it works, but is a newer/thinner-trodden path,
    and playback support for animated AVIF varies more across browsers/
    devices than animated WebP does. Test the actual output on whatever
    you intend to view it in before trusting this for anything important.

    avifenc itself was deliberately NOT used for the animation part here:
    it requires each frame as a separate pre-extracted input file (like
    img2webp), which would mean a whole extra frame-extraction step just
    to feed it a GIF/APNG. ffmpeg can read those containers directly.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias("d")]
    [string]$Directory,

    [Alias("q")]
    [ValidateRange(0,63)]
    [int]$Quality = 18,

    [Alias("e")]
    [ValidateRange(0,8)]
    [int]$Effort = 7,

    [Alias("s")]
    [ValidateRange(1,100)]
    [int]$Scale = 100,

    [Alias("r")]
    [switch]$Recursive,

    [Alias("jxl")]
    [switch]$IncludeJxl,

    [Alias("dir")]
    [string]$OutputDirectory,

    [Alias("del")]
    [switch]$RecycleOriginal
	
	[Alias("h","?")]
    [switch]$Help
)
# =====================================================================
# Help text
# =====================================================================
if ($Help) {
@"
    Batch convert animated GIF, (A)PNG or JXL files to AVIF with FFMPEG

Usage:
    batch-avif-anim.ps1 [options]

Quality:
  -q,   -Quality <0-63>          Direct aom cq-level (constant-quality
                                  level). Default 18.
  -e,   -Effort <0-8>           Effort, HIGHER = more effort/slower - the
                                  opposite scale from AV1's own -s/speed
                                  flag, converted internally (effort 8 ->
                                  speed 0). Default 7.
  -s,	-Scale <1-100>		    Percentual scale of the output. 100 is 100%, 
								  50 is 50% of the original resolution. Default 100.


General:
  -jxl,	 -IncludeJxl			    Will search for JXL files. 
								  Assumed usecase is to redo animated JXL files 
								  born from other batch jobs. Animated JXL 
								  falls behind against animated WEBP and AVIF.
  -r,   -Recursive               Work recursively into subfolders
  -dir <name>                    Put output in a subfolder (created inside each folder
                                  processed; combines with -Recursive)
  -del, -RecycleOriginal         After encoding, send whichever of original/output is
                                  larger to the Recycle Bin
  -h,   -Help                    (You are here)

"@
    return
}

function Remove-OriginalIfLarger {
    <#
        After conversion, sends whichever of the original source or the
        new AVIF is larger to the Recycle Bin, keeping only the smaller
        one. Uses Microsoft.VisualBasic.FileIO, which is Windows-only
        (there's no cross-platform "Recycle Bin" concept in PowerShell 7),
        so this is a no-op with a warning on Linux/macOS.
    #>
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

function Convert-JxlToApng {
    <#
        Animated-JXL support in ffmpeg itself depends on whether that
        specific ffmpeg build was compiled with --enable-libjxl, which
        most common prebuilt distributions don't include. djxl (the
        decoder half of the same libjxl toolset as cjxl) reliably decodes
        animated JXL - including all frames - directly to APNG when given
        a .apng output filename, with no special animation flag needed.
        This produces that intermediate APNG so ffmpeg can encode it to
        AVIF exactly like it already does for GIF input.

        Returns the temp APNG as an IO.FileInfo on success, or $null on
        failure. The caller is responsible for deleting the temp file
        once done with it.
    #>
    param([Parameter(Mandatory)][IO.FileInfo]$JxlFile)

    $tempApngPath = Join-Path $JxlFile.DirectoryName "$($JxlFile.BaseName).jxl2avif-tmp.apng"

    & $djxlExe $JxlFile.FullName $tempApngPath --quiet

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempApngPath)) {
        Write-Warning "djxl failed to decode $($JxlFile.FullName)"
        return $null
    }

    return Get-Item -LiteralPath $tempApngPath
}

# =====================================================================
# Validate directory
# =====================================================================

if (-not $PSBoundParameters.ContainsKey('Directory')) {
    $Directory = (Get-Location).Path
}

if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    Write-Error "Error: '$Directory' is not a valid directory."
    exit 1
}

$directoryItem = Get-Item -LiteralPath $Directory

if ($RecycleOriginal) {
    if ($IsWindows) {
        Add-Type -AssemblyName Microsoft.VisualBasic
    }
    else {
        Write-Warning "-RecycleOriginal uses the Windows Recycle Bin and has no equivalent on this platform; ignoring."
        $RecycleOriginal = $false
    }
}

# ffmpeg's libaom-av1 -cpu-used ranges 0 (slowest/best) to 8 (fastest) -
# narrower than avifenc's own 0-10 speed scale, so -Effort uses that same
# 0-8 range directly (still HIGHER = more effort, inverted from cpu-used's
# own "higher = faster" direction).
$cpuUsedValue = 8 - $Effort

function Get-EffectiveBaseName {
    <#
        jxl-bats.ps1 (this project's JPEG-XL encoder script) tags its
        output filenames with the encode mode: "name.md.jxl" (modular),
        "name.ll.jxl" (lossless), "name.jpg.jxl" (reversible JPEG
        recompression). Converting one of those back to AVIF should
        produce "name.avif", not "name.md.avif" - the mode suffix isn't
        part of the actual filename, just metadata about how the JXL was
        encoded. Only applies to .jxl input; .gif has no such convention.
    #>
    param([Parameter(Mandatory)][IO.FileInfo]$File)

    if ($File.Extension -eq '.jxl' -and $File.BaseName -match '^(.*)\.(md|ll|jpg)$') {
        return $Matches[1]
    }

    return $File.BaseName
}

function Get-OutputPath {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$BaseName,
        [string]$OutputDirectory
    )

    $name = "$BaseName.avif"

    if ($OutputDirectory) {

        $dir = Join-Path $File.DirectoryName $OutputDirectory

        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }

        return Join-Path $dir $name
    }

    return Join-Path $File.DirectoryName $name
}

# =====================================================================
# Gather input files
# =====================================================================

# -LiteralPath (rather than a wildcard -Path combined with -Include) avoids
# a known PowerShell quirk where that combination can silently miss files
# in folders whose names contain spaces or other special characters.
$extensions = @('.gif')
if ($IncludeJxl) { $extensions += '.jxl' }

$files = Get-ChildItem -LiteralPath $directoryItem.FullName -File -Recurse:$Recursive |
    Where-Object { $extensions -contains $_.Extension.ToLower() }

if ($IncludeJxl -and ($files | Where-Object { $_.Extension -eq '.jxl' })) {
    try {
        $djxlExe = (Get-Command djxl.exe -ErrorAction Stop).Source
    }
    catch {
        Write-Error "djxl.exe was not found on PATH. It's needed to decode .jxl input (part of the libjxl toolset, alongside cjxl.exe). Install it or drop -IncludeJxl."
        exit 1
    }
}

foreach ($file in $files) {

    $effectiveBaseName = Get-EffectiveBaseName -File $file
    $output = Get-OutputPath -File $file -BaseName $effectiveBaseName -OutputDirectory $OutputDirectory

    Write-Host "Converting: $($file.FullName) -> $output"

    $tempApng = $null
    $ffmpegInput = $file.FullName

    if ($file.Extension -eq '.jxl') {
        $tempApng = Convert-JxlToApng -JxlFile $file
        if (-not $tempApng) {
            continue
        }
        $ffmpegInput = $tempApng.FullName
    }

    $scaleFilter = "scale=iw*$Scale/100:ih*$Scale/100"

    # -crf uses the same 0-63 scale as avifenc's own cq-level (lower =
    # better); -b:v 0 makes sure this is pure constant-quality mode with
    # no implicit bitrate ceiling, rather than any hybrid rate-controlled
    # mode.
    & ffmpeg -y -hide_banner -loglevel warning -i $ffmpegInput -vf $scaleFilter -c:v libaom-av1 -crf $Quality -b:v 0 -cpu-used $cpuUsedValue $output

    $ffmpegExitCode = $LASTEXITCODE

    if ($tempApng) {
        Remove-Item -LiteralPath $tempApng.FullName -Force -ErrorAction SilentlyContinue
    }

    if ($ffmpegExitCode -ne 0) {
        Write-Warning "ffmpeg failed (exit code $ffmpegExitCode) for $($file.FullName)"
        continue
    }

    if (-not (Test-Path -LiteralPath $output)) {
        Write-Warning "Expected output file missing: $output"
        continue
    }

    $outputFile = Get-Item -LiteralPath $output
    Remove-OriginalIfLarger -Original $file -Output $outputFile -Enabled:$RecycleOriginal
}

Write-Host "✅ Conversion complete!"
