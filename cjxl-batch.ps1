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
    [ValidateRange(0,100)]
    [int]$Quality,

    # ----- General encode options -----
    [Alias("s")]
    [AllowEmptyString()]
    [string]$Suffix,

    [Alias("e")]
    [ValidateRange(1,10)]
    [int]$Effort = 7,

    [Alias("a")]
    [ValidateRange(0,25)]
    [double]$AlphaDistance,

    [Alias("t")]
    [int]$Threads,

    [Alias("p")]
    [switch]$Progressive,

    [Alias("m")]
    [switch]$Modular,

    [Alias("j")]
    [switch]$LosslessJPEG,

    [Alias("pn")]
    [int]$PhotonNoiseISO,

    [Alias("fd")]
    [ValidateRange(0,4)]
    [int]$FasterDecoding,

    [Alias("be")]
    [ValidateRange(1,11)]
    [int]$BrotliEffort,

    [Alias("rx")]
    [switch]$rejxl,

    # ----- Batch behaviour -----
    [Alias("comp")]
    [switch]$Competitive,

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
    Batch convert common image files to JPEG-XL with cjxl

Usage:
    cjxl-batch.ps1 [-d DISTANCE | -q QUALITY] [options]

Quality:
  -d, -Distance <0-25>          Butteraugli distance (default 1.0)
  -q, -Quality <0-100>          Quality setting (alternative to -Distance)

General:
  -rx, -rejxl                   Include existing .jxl files as input too (for re-encoding)
  -e,  -Effort <1-10>           Encoder effort (default 7)
  -s,  -Suffix <text>           Output suffix override. (default: adds ".ll" for lossless,
                                 ".md" for modular, ".jpg" for reversible JPEG, otherwise none)
  -a,  -AlphaDistance <0-25>    Distance for alpha channel
  -t,  -Threads <n>             Worker threads. cjxl default.
  -p,  -Progressive
  -m,  -Modular					Uses JXL format's modular lossy compression. 
									Certain types of images compress extremely well in this mode.
  -j,  -LosslessJPEG            Preserve JPEG bitstream when input is JPEG and -Distance 0
  -pn, -PhotonNoiseISO <ISO>
  -fd, -FasterDecoding <0-4>
  -be, -BrotliEffort <1-11>

  -comp, -Competitive           Try several encodes per file (lossless, lossy d1.0,
                                 lossy modular d1.0, and -j lossless-JPEG if applicable)
                                 and keep only the smallest result. -Quality is ignored
                                 in this mode. Sorry for the inflexibility.
  -r,   -Recursive              Work recursively into subfolders
  -dir <name>                   Put output in a subfolder (created inside each folder
                                 processed; combines with -Recursive)
  -del, -RecycleOriginal        After encoding, send whichever of original/output is
                                 larger to the Recycle Bin
  -h,  -Help                    (You are here)
"@
    return
}

# =====================================================================
# Helper functions
# =====================================================================

function Get-CandidateSuffix {
    <#
        Works out the default output suffix for a given encode mode.
        Only called when the user did NOT supply -Suffix explicitly.
    #>
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [double]$Distance,
        [switch]$LosslessJPEG,
        [switch]$Modular
    )

    switch ($true) {

        # jxl input should never overwrite itself
        { $File.Extension -eq '.jxl' } {
            return '_new'
        }

        # reversible JPEG recompression
        {
            $Distance -eq 0 -and
            $LosslessJPEG -and
            $File.Extension -match '\.jpe?g$'
        } {
            return '.jpg'
        }

        # ordinary lossless
        { $Distance -eq 0 } {
            return '.ll'
        }

        # modular
        { $Modular } {
            return '.md'
        }

        default {
            return ''
        }
    }
}

function Get-OutputPath {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [string]$Suffix,
        [string]$OutputDirectory
    )

    $name = "$($File.BaseName)$Suffix.jxl"

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
        [Parameter(Mandatory)][IO.FileInfo]$OutputFile,
        [string]$Tag
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

    $tagText = if ($Tag) { " [$Tag]" } else { "" }

    Write-Host "$relative : $sign$(Format-Size ([math]::Abs($saved))) ($percent%)$tagText" -ForegroundColor $color
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

function Build-CjxlArgs {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$InputFile,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$UseQuality,
        [double]$Distance,
        [int]$Quality,
        [int]$Effort,
        [Nullable[double]]$AlphaDistance,
        [Nullable[int]]$Threads,
        [switch]$Progressive,
        [switch]$Modular,
        [switch]$LosslessJPEG,
        [Nullable[int]]$PhotonNoiseISO,
        [Nullable[int]]$FasterDecoding,
        [Nullable[int]]$BrotliEffort
    )

    $cjxlArgs = @($InputFile.FullName, $OutputPath)

    if ($UseQuality) {
        $cjxlArgs += '-q', $Quality
    }
    else {
        $cjxlArgs += '-d', $Distance
    }

    $cjxlArgs += '-e', $Effort

    if ($null -ne $AlphaDistance) {
        $cjxlArgs += '-a', $AlphaDistance
    }
    if ($null -ne $Threads) {
        $cjxlArgs += "--num_threads=$Threads"
    }
    if ($Progressive) {
        $cjxlArgs += '--progressive'
    }
    if ($Modular) {
        $cjxlArgs += '--modular=1'
    }
    if ($LosslessJPEG) {
        $cjxlArgs += '--lossless_jpeg=1'
    }
    else {
        $cjxlArgs += '--lossless_jpeg=0'
    }
    if ($null -ne $PhotonNoiseISO) {
        $cjxlArgs += "--photon_noise_iso=$PhotonNoiseISO"
    }
    if ($null -ne $FasterDecoding) {
        $cjxlArgs += "--faster_decoding=$FasterDecoding"
    }
    if ($null -ne $BrotliEffort) {
        $cjxlArgs += "--brotli_effort=$BrotliEffort"
    }

    return $cjxlArgs
}

function Invoke-CjxlEncode {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath
    )

    & cjxl.exe --quiet @Arguments

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "cjxl failed (exit code $LASTEXITCODE) for $OutputPath"
        return $null
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Write-Warning "Expected output file missing: $OutputPath"
        return $null
    }

    return Get-Item -LiteralPath $OutputPath
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

function Select-SmallestFile {
    param([Parameter(Mandatory)][IO.FileInfo[]]$Files)
    return $Files | Sort-Object Length | Select-Object -First 1
}

# =====================================================================
# Resolve "was this actually specified?" ONCE, at script scope, where
# $PSBoundParameters and $PSCmdlet.ParameterSetName are meaningful.
# =====================================================================

$useQuality        = $PSCmdlet.ParameterSetName -eq 'Quality'
$hasSuffixOverride = $PSBoundParameters.ContainsKey('Suffix')

$alphaDistanceValue  = if ($PSBoundParameters.ContainsKey('AlphaDistance'))  { $AlphaDistance }  else { $null }
$threadsValue        = if ($PSBoundParameters.ContainsKey('Threads'))        { $Threads }        else { $null }
$photonNoiseValue    = if ($PSBoundParameters.ContainsKey('PhotonNoiseISO')) { $PhotonNoiseISO }  else { $null }
$fasterDecodingValue = if ($PSBoundParameters.ContainsKey('FasterDecoding')) { $FasterDecoding }  else { $null }
$brotliEffortValue   = if ($PSBoundParameters.ContainsKey('BrotliEffort'))   { $BrotliEffort }    else { $null }

if ($RecycleOriginal) {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

# =====================================================================
# Gather input files
# =====================================================================

$extensions = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp')
if ($rejxl) {
    $extensions += '.jxl'
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
# Main loop
# =====================================================================

foreach ($file in $files) {

    if ($Competitive) {

        # ---- Build the list of candidate encodes to try ----
        $candidateSpecs = @(
            @{ Tag = 'lossless';      Distance = 0.0; Modular = $false; LosslessJPEG = $false }
            @{ Tag = 'lossy';         Distance = 1.0; Modular = $false; LosslessJPEG = $false }
            @{ Tag = 'lossy-modular'; Distance = 1.0; Modular = $true;  LosslessJPEG = $false }
        )

        if ($LosslessJPEG -and $file.Extension -match '\.jpe?g$') {
            $candidateSpecs += @{ Tag = 'jpeg-lossless'; Distance = 0.0; Modular = $false; LosslessJPEG = $true }
        }

        $candidates = @()

        foreach ($spec in $candidateSpecs) {

            $tempPath = Get-OutputPath -File $file -Suffix ".$($spec.Tag)-tmp" -OutputDirectory $OutputDirectory

            $cjxlArgs = Build-CjxlArgs `
                -InputFile $file -OutputPath $tempPath `
                -UseQuality $false -Distance $spec.Distance -Quality 0 -Effort $Effort `
                -AlphaDistance $alphaDistanceValue -Threads $threadsValue `
                -Progressive:$Progressive -Modular:$spec.Modular -LosslessJPEG:$spec.LosslessJPEG `
                -PhotonNoiseISO $photonNoiseValue -FasterDecoding $fasterDecodingValue `
                -BrotliEffort $brotliEffortValue

            Write-Verbose "cjxl.exe $($cjxlArgs -join ' ')"

            if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode candidate '$($spec.Tag)'")) {
                continue
            }

            $result = Invoke-CjxlEncode -Arguments $cjxlArgs -OutputPath $tempPath
            if ($result) {
                # Remember which spec produced this file, so the winner
                # can carry a suffix that reflects the mode that won -
                # not a generic one computed independently of the result.
                $candidateSuffix = Get-CandidateSuffix -File $file -Distance $spec.Distance -Modular:$spec.Modular -LosslessJPEG:$spec.LosslessJPEG
                $candidates += [PSCustomObject]@{
                    File   = $result
                    Suffix = $candidateSuffix
                    Tag    = $spec.Tag
                }
            }
        }

        if (-not $candidates) {
            Write-Warning "All candidate encodes failed for $($file.FullName)"
            continue
        }

        # ---- Keep only the smallest candidate ----
        $winner = $candidates | Sort-Object { $_.File.Length } | Select-Object -First 1
        Remove-LosingCandidates -All $candidates.File -Winner $winner.File

        $finalSuffix = if ($hasSuffixOverride) { $Suffix } else { $winner.Suffix }
        $finalPath   = Get-OutputPath -File $file -Suffix $finalSuffix -OutputDirectory $OutputDirectory

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
    else {

        # ---- Single-mode conversion ----
        $suffix =
            if ($hasSuffixOverride) { $Suffix }
            else { Get-CandidateSuffix -File $file -Distance $Distance -LosslessJPEG:$LosslessJPEG -Modular:$Modular }

        $output = Get-OutputPath -File $file -Suffix $suffix -OutputDirectory $OutputDirectory

        if (Test-Path -LiteralPath $output) {
            Write-Verbose "$output already exists, skipping."
            continue
        }

        $cjxlArgs = Build-CjxlArgs `
            -InputFile $file -OutputPath $output `
            -UseQuality $useQuality -Distance $Distance -Quality $Quality -Effort $Effort `
            -AlphaDistance $alphaDistanceValue -Threads $threadsValue `
            -Progressive:$Progressive -Modular:$Modular -LosslessJPEG:$LosslessJPEG `
            -PhotonNoiseISO $photonNoiseValue -FasterDecoding $fasterDecodingValue `
            -BrotliEffort $brotliEffortValue

        Write-Verbose "cjxl.exe $($cjxlArgs -join ' ')"

        if (-not $PSCmdlet.ShouldProcess($file.FullName, "Encode to $output")) {
            continue
        }

        $outputFile = Invoke-CjxlEncode -Arguments $cjxlArgs -OutputPath $output
        if (-not $outputFile) {
            continue
        }

        Remove-OriginalIfLarger -Original $file -Output $outputFile -Enabled:$RecycleOriginal
        Update-Statistics -InputFile $file -OutputFile $outputFile
        Write-ConversionResult -InputFile $file -OutputFile $outputFile
    }
}

Write-Summary
