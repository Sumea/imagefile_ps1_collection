[CmdletBinding(
    DefaultParameterSetName='JxlDistance',
    SupportsShouldProcess
)]
param(
    # ----- JXL quality mode (mutually exclusive) -----
    [Parameter(ParameterSetName='JxlDistance')]
    [Alias("jxld")]
    [ValidateRange(0,25)]
    [double]$JxlDistance = 1.0,

    [Parameter(ParameterSetName='JxlQuality')]
    [Alias("jxlq")]
    [ValidateRange(0,100)]
    [int]$JxlQuality,

    [Alias("jxle")]
    [ValidateRange(1,10)]
    [int]$JxlEffort = 9,

    # ----- AVIF -----
    [Alias("avifq")]
    [ValidateRange(0,63)]
    [int]$AvifQuality = 18,

    [Alias("avife")]
    [ValidateRange(0,10)]
    [int]$AvifEffort = 9,

    # ----- WebP -----
    [Alias("webpq")]
    [ValidateRange(0,100)]
    [int]$WebpQuality = 92,

    [Alias("webpe")]
    [ValidateRange(1,10)]
    [int]$WebpEffort = 10,

    # ----- JPEG (cjpegli) -----
    [Alias("jpgd")]
    [ValidateRange(0,25)]
    [double]$JpegliDistance = 1.0,

    # ----- General -----
    [Alias("j")]
    [switch]$LosslessJPEG,

    [Alias("rx")]
    [switch]$ReencodeExisting,

    [Alias("pr")]
    [switch]$Prune,

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
    Batch-converts a folder of images by trying cjxl (JPEG XL), avifenc
    (AVIF), and cwebp (WebP) per file at "visually lossless"-ish, high
    quality settings, and keeping whichever result is smallest. JXL also
    contributes its own lossless, lossy, and lossy-modular candidates to
    the same contest (see cjxl-batch.ps1 for background on those modes).

    Animated GIF/APNG input is detected and routed straight to an
    animated-WebP conversion via ffmpeg instead of the still-image
    contest, since AVIF/WebP/JXL still encoders can't meaningfully
    compete on a multi-frame source without extra frame-extraction
    machinery this script doesn't attempt.

    Fully single-threaded / sequential by design (like the pre-parallel
    cjxl-batch.ps1 this is based on) - one file, one candidate, one
    subprocess at a time. Slower overall than the parallel scripts, but
    predictable and easy to run unattended in the background.

Usage:
    batch-comp-imageshrink.ps1 [options]

JPEG XL:
  -jxld, -JxlDistance <0-25>     Butteraugli distance for the lossy JXL
                                  candidates (default 1.0). Mutually
                                  exclusive with -JxlQuality.
  -jxlq, -JxlQuality <0-100>     Quality scale alternative to -JxlDistance.
  -jxle, -JxlEffort <1-10>       Encoder effort (default 9).

AVIF:
  -avifq, -AvifQuality <0-63>    Direct aom cq-level (constant-quality level),
                                  scoped to the color planes only (multiformat-
                                  bats.ps1 has no separate alpha-quality knob,
                                  but this scoping avoids a bare cq-level
                                  silently also overriding alpha quality).
                                  LOWER = higher quality, opposite of every
                                  other quality knob in this script. Encoded
                                  via '-a end-usage=q -a color:cq-level=N', the
                                  confirmed-current recommended approach for
                                  best offline AVIF quality (not the same as
                                  'cq' end-usage, which is for bitrate-capped
                                  streaming). Default 18.
  -avife, -AvifEffort <0-10>     Effort, HIGHER = more effort/slower - the
                                  opposite scale from avifenc's own -s/speed
                                  flag, converted internally (effort 6 ->
                                  speed 4). Default 8.

WebP:
  -webpq, -WebpQuality <0-100>   cwebp -q (default 92).
  -webpe, -WebpEffort <1-10>     Unified effort scale, same range as -JxlEffort.
                                  Drives cwebp -m (compression method), which
                                  caps at 6 - so -WebpEffort 6 through 10 all
                                  use -m 6, but ALSO drives -pass (analysis
                                  passes, 1-10), which keeps climbing past 6.
                                  So -WebpEffort 6 = -m 6 -pass 6, and
                                  -WebpEffort 10 = -m 6 -pass 10. Default 10.

JPEG (cjpegli):
  -jpgd, -JpegliDistance <0-25>  cjpegli -d (default 1.0). Rarely the
                                  overall winner, but when it is, it's also
                                  the most universally-compatible result.

General:
  -j,   -LosslessJPEG            Also try JXL's reversible-JPEG-recompression
                                  candidate when the input is a JPEG.
  -rx,  -ReencodeExisting        Include existing .jxl files as additional
                                  still-image input too (for re-competing).
                                  Since avifenc/cwebp/cjpegli can't read .jxl
                                  directly, each .jxl gets bridged through a
                                  PNG first: a same-named .png next to it is
                                  reused as-is (never overwritten) if one
                                  exists, otherwise djxl decodes a temporary
                                  one that's deleted once this file is done.
                                  Requires djxl.exe on PATH.
  -pr,    -Prune                  Skips conversion entirely. Instead, scans
                                  for files that share a base name across
                                  ANY recognized extension (leftover output
                                  from earlier runs, manually-made
                                  alternates, etc.) and keeps only the
                                  smallest of each group. Without
                                  -RecycleOriginal this is a dry run that
                                  only lists what it would remove.
  -r,   -Recursive               Work recursively into subfolders.
  -dir <name>                    Put output in a subfolder (created inside
                                  each folder processed; combines with
                                  -Recursive).
  -del, -RecycleOriginal         After conversion, send whichever of the
                                  original source file or the winning output
                                  is larger to the Recycle Bin.
  -h,   -Help                    (You are here)
"@
    return
}

# =====================================================================
# Helper functions - shared
# =====================================================================

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
        [Parameter(Mandatory)][IO.FileInfo]$OutputFile,
        [string]$Tag
    )

    $saved = $InputFile.Length - $OutputFile.Length
    $sign  = if ($saved -ge 0) { "-" } else { "+" }

    $percent =
        if ($InputFile.Length) { [math]::Round($OutputFile.Length * 100 / $InputFile.Length, 1) }
        else { 0 }

    $relative = [IO.Path]::GetRelativePath($PWD.Path, $InputFile.FullName)

    $color =
        if ($saved -gt 0)   { "Green" }
        elseif ($saved -lt 0) { "Yellow" }
        else                { "Gray" }

    $tagText = if ($Tag) { " [$Tag]" } else { "" }

    Write-Host "$relative : $sign$(Format-Size ([math]::Abs($saved))) ($percent%)$tagText" -ForegroundColor $color
}

function Write-Summary {
    $saved = $script:totalOriginal - $script:totalOutput
    $sign  = if ($saved -ge 0) { "-" } else { "+" }

    $percent =
        if ($script:totalOriginal) { [math]::Round($script:totalOutput * 100 / $script:totalOriginal, 1) }
        else { 0 }

    $color =
        if ($saved -gt 0)   { "Green" }
        elseif ($saved -lt 0) { "Yellow" }
        else                { "Gray" }

    Write-Host "I'm done boss." -ForegroundColor Cyan

    if ($script:skippedCount -gt 0) {
        Write-Host "Skipped $($script:skippedCount) file(s) that already had a converted output." -ForegroundColor DarkGray
    }

    Write-Host "$sign$(Format-Size ([math]::Abs($saved))) ($percent%)" -ForegroundColor $color
}

function Get-TempOutputPath {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Extension,
        [string]$OutputDirectory
    )

    $name = "$($File.BaseName).$Tag-tmp$Extension"

    if ($OutputDirectory) {
        $dir = Join-Path $File.DirectoryName $OutputDirectory
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        return Join-Path $dir $name
    }

    return Join-Path $File.DirectoryName $name
}

function Get-FinalOutputPath {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$Extension,
        [string]$Suffix,
        [string]$OutputDirectory
    )

    $name = "$($File.BaseName)$Suffix$Extension"

    if ($OutputDirectory) {
        $dir = Join-Path $File.DirectoryName $OutputDirectory
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        return Join-Path $dir $name
    }

    return Join-Path $File.DirectoryName $name
}

function Test-AnyFinalOutputExists {
    <#
        Since the winning format isn't known until all candidates are
        tried, "has this file already been processed?" has to check
        every plausible final filename, not just one.
    #>
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [string]$OutputDirectory
    )

    $possible = @(
        Get-FinalOutputPath -File $File -Extension '.jxl' -Suffix ''     -OutputDirectory $OutputDirectory
        Get-FinalOutputPath -File $File -Extension '.jxl' -Suffix '.ll'  -OutputDirectory $OutputDirectory
        Get-FinalOutputPath -File $File -Extension '.jxl' -Suffix '.md'  -OutputDirectory $OutputDirectory
        Get-FinalOutputPath -File $File -Extension '.jxl' -Suffix '.jpg' -OutputDirectory $OutputDirectory
        Get-FinalOutputPath -File $File -Extension '.avif' -Suffix ''    -OutputDirectory $OutputDirectory
        Get-FinalOutputPath -File $File -Extension '.webp' -Suffix ''    -OutputDirectory $OutputDirectory
        Get-FinalOutputPath -File $File -Extension '.jpg' -Suffix ''     -OutputDirectory $OutputDirectory
        Get-FinalOutputPath -File $File -Extension '.jpg' -Suffix '_new' -OutputDirectory $OutputDirectory
    )

    return [bool]($possible | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

function Remove-LosingCandidates {
    param(
        [Parameter(Mandatory)][IO.FileInfo[]]$All,
        [Parameter(Mandatory)][IO.FileInfo]$Winner
    )

    foreach ($f in $All) {
        if ($f.FullName -ne $Winner.FullName) {
            if ($PSCmdlet.ShouldProcess($f.FullName, "Delete losing candidate")) {
                Remove-Item -LiteralPath $f.FullName -Force
            }
        }
    }
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
# Helper functions - JXL (ported from jxl-bats.ps1's pre-parallel version)
# =====================================================================

function Get-CandidateSuffix {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [double]$Distance,
        [switch]$LosslessJPEG,
        [switch]$Modular
    )

    switch ($true) {
        { $Distance -eq 0 -and $LosslessJPEG -and $File.Extension -match '\.jpe?g$' } { return '.jpg' }
        { $Distance -eq 0 } { return '.ll' }
        { $Modular }        { return '.md' }
        default             { return '' }
    }
}

function Build-CjxlArgs {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$UseQuality,
        [double]$Distance,
        [int]$Quality,
        [int]$Effort,
        [switch]$Modular,
        [switch]$LosslessJPEG
    )

    $cjxlArgs = @($InputFile.FullName, $OutputPath)

    if ($UseQuality) { $cjxlArgs += '-q', $Quality }
    else             { $cjxlArgs += '-d', $Distance }

    $cjxlArgs += '-e', $Effort

    if ($Modular) { $cjxlArgs += '--modular=1' }

    if ($LosslessJPEG) { $cjxlArgs += '--lossless_jpeg=1' }
    else                { $cjxlArgs += '--lossless_jpeg=0' }

    return $cjxlArgs
}

function Invoke-CjxlEncode {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $outputText = & cjxl.exe --quiet @Arguments 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        Write-Warning "cjxl failed for $OutputPath"
        if ($outputText) { Write-Warning $outputText.Trim() }
        return $null
    }

    return Get-Item -LiteralPath $OutputPath
}

# =====================================================================
# Helper functions - AVIF / WebP
# =====================================================================

function Invoke-AvifencEncode {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath
    )

    # --min/--max are deprecated by avifenc itself (superseded by cq-level
    # below). tune=ssim is deliberately NOT set: avifenc's own default tune
    # for color is already 'iq' as of libaom 3.13.0+ (this build reports
    # 3.14.1), which is newer than ssim and the tool's own preferred choice
    # - explicitly forcing ssim here would be a regression, not a tune-up.
    $outputText = & avifenc.exe --min 0 --max 63 -a end-usage=q -a color:cq-level=$AvifQuality -s $script:avifSpeedValue -y 444 -d 10 -a color:sharpness=2 -a color:enable-chroma-deltaq=1 $InputFile.FullName $OutputPath 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        Write-Warning "avifenc failed for $($InputFile.FullName)"
        if ($outputText) { Write-Warning $outputText.Trim() }
        return $null
    }

    return Get-Item -LiteralPath $OutputPath
}

function Invoke-CwebpEncode {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $outputText = & cwebp.exe -quiet -q $WebpQuality -m $script:webpMethodValue -pass $script:webpPassValue -mt -sharp_yuv $InputFile.FullName -o $OutputPath 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        Write-Warning "cwebp failed for $($InputFile.FullName)"
        if ($outputText) { Write-Warning $outputText.Trim() }
        return $null
    }

    return Get-Item -LiteralPath $OutputPath
}

function Invoke-CjpegliEncode {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $outputText = & cjpegli.exe $InputFile.FullName $OutputPath -d $JpegliDistance --quiet 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        Write-Warning "cjpegli failed for $($InputFile.FullName)"
        if ($outputText) { Write-Warning $outputText.Trim() }
        return $null
    }

    return Get-Item -LiteralPath $OutputPath
}

function Get-JxlBridgeFile {
    <#
        avifenc, cwebp, and cjpegli can't read .jxl input directly, so
        re-competing an existing .jxl (-ReencodeExisting) needs a decoded
        intermediate for those three candidates. If a same-named .png
        already sits next to the .jxl, that's reused as-is - it's never
        overwritten. Otherwise djxl decodes a temporary one, which the
        caller is responsible for deleting once done with this file (see
        the .IsTemp flag on the return value).

        Returns $null if no usable source could be produced (e.g. djxl
        isn't available or the decode failed) - callers should then skip
        the AVIF/WebP/JPEG candidates for this file and fall back to
        JXL-only candidates, which don't need this bridge.
    #>
    param([Parameter(Mandatory)][IO.FileInfo]$JxlFile)

    $realPngPath = Join-Path $JxlFile.DirectoryName "$($JxlFile.BaseName).png"

    if (Test-Path -LiteralPath $realPngPath) {
        return [PSCustomObject]@{ File = (Get-Item -LiteralPath $realPngPath); IsTemp = $false }
    }

    $tempPngPath = Join-Path $JxlFile.DirectoryName "$($JxlFile.BaseName).rejxl-bridge-tmp.png"

    if (-not $PSCmdlet.ShouldProcess($JxlFile.FullName, "Decode to temporary PNG for AVIF/WebP/JPEG re-competing")) {
        return $null
    }

    $outputText = & $script:djxlExe $JxlFile.FullName $tempPngPath --quiet 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempPngPath)) {
        Write-Warning "djxl failed to decode $($JxlFile.FullName)"
        if ($outputText) { Write-Warning $outputText.Trim() }
        return $null
    }

    return [PSCustomObject]@{ File = (Get-Item -LiteralPath $tempPngPath); IsTemp = $true }
}

# =====================================================================
# Helper functions - animated GIF/APNG detection and conversion
# =====================================================================

function Test-IsApng {
    <#
        Cheap animated-PNG detection: scans PNG chunks for an 'acTL'
        chunk, which the APNG spec requires to appear before the first
        IDAT if the file is animated. An ordinary still PNG never has
        one. This lets a .png file that's actually an APNG (a very
        common way APNGs are saved in practice) be routed correctly
        without relying on the file extension alone.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $header = New-Object byte[] 8
            if ($stream.Read($header, 0, 8) -ne 8) { return $false }
            if ($header[0] -ne 0x89 -or $header[1] -ne 0x50) { return $false }

            while ($stream.Position -lt $stream.Length) {

                $lenBytes = New-Object byte[] 4
                if ($stream.Read($lenBytes, 0, 4) -ne 4) { break }
                [array]::Reverse($lenBytes)
                $len = [BitConverter]::ToUInt32($lenBytes, 0)

                $typeBytes = New-Object byte[] 4
                if ($stream.Read($typeBytes, 0, 4) -ne 4) { break }
                $type = [Text.Encoding]::ASCII.GetString($typeBytes)

                if ($type -eq 'acTL') { return $true }
                if ($type -eq 'IDAT') { return $false }

                $stream.Position += ([long]$len + 4)   # chunk data + CRC
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $false
    }

    return $false
}

function Invoke-AnimatedToWebp {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $outputText = & ffmpeg -y -hide_banner -loglevel warning -i $InputFile.FullName -quality $WebpQuality -compression_level $script:webpMethodValue $OutputPath 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        Write-Warning "ffmpeg failed to convert $($InputFile.FullName)"
        if ($outputText) { Write-Warning $outputText.Trim() }
        return $null
    }

    return Get-Item -LiteralPath $OutputPath
}

# =====================================================================
# Helper function - -Prune pass
# =====================================================================

function Invoke-PrunePass {
    <#
        Scans for groups of files sharing the same base name across every
        recognized extension (source formats and encoder outputs alike),
        and keeps only the smallest in each group. This is a standalone
        cleanup pass, separate from normal conversion - it does no
        encoding itself, and only touches files that already exist.

        Without -RecycleOriginal this is a dry run: it lists what would
        be removed but deletes nothing, since this is the kind of
        operation worth previewing before trusting it on a real folder.
    #>
    param([Parameter(Mandatory)][string]$RootPath, [switch]$Recurse)

    $cleanExtensions = @('.png', '.jpg', '.jpeg', '.bmp', '.tif', '.tiff', '.jxl', '.avif', '.webp')

    $allFiles = Get-ChildItem -LiteralPath $RootPath -File -Recurse:$Recurse |
        Where-Object { $cleanExtensions -contains $_.Extension.ToLower() }

    $groups = $allFiles | Group-Object { Join-Path $_.DirectoryName $_.BaseName }
    $multiFileGroups = $groups | Where-Object { $_.Count -gt 1 }

    if (-not $multiFileGroups) {
        Write-Host "Nothing to clean - no base name has more than one matching file." -ForegroundColor Cyan
        return
    }

    $dryRun = -not $RecycleOriginal

    if ($dryRun) {
        Write-Host "-Prune without -RecycleOriginal is a dry run: listing what WOULD be removed, deleting nothing." -ForegroundColor Yellow
    }

    foreach ($group in $multiFileGroups) {

        $members = $group.Group | Sort-Object Length
        $winner  = $members[0]
        $losers  = $members[1..($members.Count - 1)]

        Write-Host "$($group.Name): keeping $($winner.Name) ($(Format-Size $winner.Length)), removing $($losers.Count) other(s)" -ForegroundColor Cyan

        foreach ($loser in $losers) {

            Write-Host "  - $($loser.Name) ($(Format-Size $loser.Length))" -ForegroundColor DarkGray

            if ($dryRun) { continue }

            if ($PSCmdlet.ShouldProcess($loser.FullName, "Send to Recycle Bin (superseded by $($winner.Name))")) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $loser.FullName,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )
            }
        }
    }
}

# =====================================================================
# Resolve settings and tool paths
# =====================================================================

$jxlUseQuality = $PSCmdlet.ParameterSetName -eq 'JxlQuality'
$script:avifSpeedValue = 10 - $AvifEffort
$script:webpMethodValue = [Math]::Min($WebpEffort, 6)
$script:webpPassValue   = $WebpEffort

if ($RecycleOriginal) {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

if ($Prune) {
    Invoke-PrunePass -RootPath $PWD.Path -Recurse:$Recursive
    return
}

foreach ($exeName in @('cjxl.exe', 'avifenc.exe', 'cwebp.exe', 'cjpegli.exe')) {
    try {
        [void](Get-Command $exeName -ErrorAction Stop)
    }
    catch {
        Write-Error "$exeName was not found on PATH. All four encoders are required for this script."
        return
    }
}

if ($ReencodeExisting) {
    try {
        $script:djxlExe = (Get-Command djxl.exe -ErrorAction Stop).Source
    }
    catch {
        Write-Error "djxl.exe was not found on PATH. It's needed to bridge existing .jxl files to AVIF/WebP/JPEG for -ReencodeExisting. Install it or drop -ReencodeExisting."
        return
    }
}

# =====================================================================
# Gather input files
# =====================================================================

$stillExtensions = @('.png', '.jpg', '.jpeg', '.bmp', '.tif', '.tiff')
if ($ReencodeExisting) { $stillExtensions += '.jxl' }

$animatedExtensions = @('.gif', '.apng')

$allExtensions = $stillExtensions + $animatedExtensions

# -LiteralPath (rather than a wildcard -Path combined with -Include) avoids
# a known PowerShell quirk where that combination can silently miss files
# in folders whose names contain spaces or other special characters.
$files = Get-ChildItem -LiteralPath $PWD.Path -File -Recurse:$Recursive |
    Where-Object { $allExtensions -contains $_.Extension.ToLower() }

if (-not $files) {
    Write-Warning "No matching image files found."
    return
}

$hasAnimatedCandidate = $files | Where-Object {
    $animatedExtensions -contains $_.Extension.ToLower() -or
    ($_.Extension -eq '.png' -and (Test-IsApng -Path $_.FullName))
}

if ($hasAnimatedCandidate) {
    try {
        [void](Get-Command ffmpeg -ErrorAction Stop)
    }
    catch {
        Write-Error "ffmpeg was not found on PATH. It's needed for animated GIF/APNG input - remove those files or install ffmpeg."
        return
    }
}

$totalOriginal = 0L
$totalOutput   = 0L
$skippedCount  = 0

# =====================================================================
# Main loop
# =====================================================================

foreach ($file in $files) {

    $isAnimated =
        $animatedExtensions -contains $file.Extension.ToLower() -or
        ($file.Extension -eq '.png' -and (Test-IsApng -Path $file.FullName))

    if ($isAnimated) {

        $finalPath = Get-FinalOutputPath -File $file -Extension '.webp' -Suffix '' -OutputDirectory $OutputDirectory

        if (Test-Path -LiteralPath $finalPath) {
            Write-Verbose "$finalPath already exists, skipping."
            $skippedCount++
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($file.FullName, "Convert animated input to $finalPath")) {
            continue
        }

        $outputFile = Invoke-AnimatedToWebp -InputFile $file -OutputPath $finalPath
        if (-not $outputFile) { continue }

        Remove-OriginalIfLarger -Original $file -Output $outputFile -Enabled:$RecycleOriginal
        Update-Statistics -InputFile $file -OutputFile $outputFile
        Write-ConversionResult -InputFile $file -OutputFile $outputFile -Tag 'animated-webp'
        continue
    }

    # ---- Still image: run the three-tool contest ----

    if (Test-AnyFinalOutputExists -File $file -OutputDirectory $OutputDirectory) {
        Write-Verbose "$($file.FullName) already has a converted output, skipping."
        $skippedCount++
        continue
    }

    $specs = @(
        @{ Tool = 'jxl';     Tag = 'jxl-lossless';      Distance = 0.0;         Modular = $false }
        @{ Tool = 'jxl';     Tag = 'jxl-lossy';         Distance = $JxlDistance; Modular = $false }
        @{ Tool = 'jxl';     Tag = 'jxl-lossy-modular'; Distance = $JxlDistance; Modular = $true }
        @{ Tool = 'avif';    Tag = 'avif' }
        @{ Tool = 'webp';    Tag = 'webp' }
        @{ Tool = 'cjpegli'; Tag = 'jpegli' }
    )

    if ($LosslessJPEG -and $file.Extension -match '\.jpe?g$') {
        $specs += @{ Tool = 'jxl'; Tag = 'jxl-jpeg-lossless'; Distance = 0.0; Modular = $false; LosslessJPEG = $true }
    }

    # cjxl can re-encode a .jxl directly, but avifenc/cwebp/cjpegli cannot -
    # those three need a decoded PNG bridge when the input is itself a .jxl
    # (only possible when -ReencodeExisting is set, since that's the only
    # way a .jxl enters $files as still-image input).
    $bridgeSource = $null
    $bridgeIsTemp = $false

    if ($file.Extension -eq '.jxl') {
        $bridge = Get-JxlBridgeFile -JxlFile $file
        if ($bridge) {
            $bridgeSource = $bridge.File
            $bridgeIsTemp = $bridge.IsTemp
        }
    }
    else {
        $bridgeSource = $file
    }

    $candidates = @()

    foreach ($spec in $specs) {

        if ($spec.Tool -eq 'jxl') {

            $tempPath = Get-TempOutputPath -File $file -Tag $spec.Tag -Extension '.jxl' -OutputDirectory $OutputDirectory

            $cjxlArgs = Build-CjxlArgs `
                -InputFile $file -OutputPath $tempPath `
                -UseQuality $jxlUseQuality -Distance $spec.Distance -Quality $JxlQuality -Effort $JxlEffort `
                -Modular:$spec.Modular -LosslessJPEG:([bool]$spec.LosslessJPEG)

            Write-Verbose "cjxl.exe $($cjxlArgs -join ' ')"

            if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode candidate '$($spec.Tag)'")) { continue }

            $result = Invoke-CjxlEncode -Arguments $cjxlArgs -OutputPath $tempPath
            if ($result) {
                $suffix = Get-CandidateSuffix -File $file -Distance $spec.Distance -Modular:$spec.Modular -LosslessJPEG:([bool]$spec.LosslessJPEG)
                $candidates += [PSCustomObject]@{ File = $result; Extension = '.jxl'; Suffix = $suffix; Tag = $spec.Tag }
            }
        }
        elseif ($spec.Tool -eq 'avif') {

            if (-not $bridgeSource) { continue }

            $tempPath = Get-TempOutputPath -File $file -Tag $spec.Tag -Extension '.avif' -OutputDirectory $OutputDirectory

            if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode candidate 'avif'")) { continue }

            $result = Invoke-AvifencEncode -InputFile $bridgeSource -OutputPath $tempPath
            if ($result) {
                $candidates += [PSCustomObject]@{ File = $result; Extension = '.avif'; Suffix = ''; Tag = 'avif' }
            }
        }
        elseif ($spec.Tool -eq 'webp') {

            if (-not $bridgeSource) { continue }

            $tempPath = Get-TempOutputPath -File $file -Tag $spec.Tag -Extension '.webp' -OutputDirectory $OutputDirectory

            if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode candidate 'webp'")) { continue }

            $result = Invoke-CwebpEncode -InputFile $bridgeSource -OutputPath $tempPath
            if ($result) {
                $candidates += [PSCustomObject]@{ File = $result; Extension = '.webp'; Suffix = ''; Tag = 'webp' }
            }
        }
        elseif ($spec.Tool -eq 'cjpegli') {

            if (-not $bridgeSource) { continue }

            $tempPath = Get-TempOutputPath -File $file -Tag $spec.Tag -Extension '.jpg' -OutputDirectory $OutputDirectory

            if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode candidate 'jpegli'")) { continue }

            $result = Invoke-CjpegliEncode -InputFile $bridgeSource -OutputPath $tempPath
            if ($result) {
                # A plain .jpg output would collide with the source itself
                # if the source is already a .jpg/.jpeg - same "_new"
                # fallback convention used elsewhere in this family of
                # scripts for that self-overwrite case.
                $jpegliSuffix = if ($file.Extension -match '\.jpe?g$') { '_new' } else { '' }
                $candidates += [PSCustomObject]@{ File = $result; Extension = '.jpg'; Suffix = $jpegliSuffix; Tag = 'jpegli' }
            }
        }
    }

    if ($bridgeIsTemp -and $bridgeSource) {
        Remove-Item -LiteralPath $bridgeSource.FullName -Force -ErrorAction SilentlyContinue
    }

    if (-not $candidates) {
        Write-Warning "All candidate encodes failed for $($file.FullName)"
        continue
    }

    $winner = $candidates | Sort-Object { $_.File.Length } | Select-Object -First 1
    Remove-LosingCandidates -All $candidates.File -Winner $winner.File

    $finalPath = Get-FinalOutputPath -File $file -Extension $winner.Extension -Suffix $winner.Suffix -OutputDirectory $OutputDirectory

    if (Test-Path -LiteralPath $finalPath) {
        Write-Verbose "$finalPath already exists, skipping rename for $($file.FullName)."
        Remove-Item -LiteralPath $winner.File.FullName -Force
        continue
    }

    Rename-Item -LiteralPath $winner.File.FullName -NewName (Split-Path $finalPath -Leaf)
    $outputFile = Get-Item -LiteralPath $finalPath

    Remove-OriginalIfLarger -Original $file -Output $outputFile -Enabled:$RecycleOriginal
    Update-Statistics -InputFile $file -OutputFile $outputFile
    Write-ConversionResult -InputFile $file -OutputFile $outputFile -Tag $winner.Tag
}

Write-Summary
