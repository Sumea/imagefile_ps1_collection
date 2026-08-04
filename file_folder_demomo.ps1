[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Separator = '_',
    [switch]$RemoveEmptyFolders
)

$bossparent = $PWD.Path
$files = Get-ChildItem -Path $bossparent -File -Recurse

foreach ($file in $files) {

    $relativeDir = [IO.Path]::GetRelativePath($bossparent, $file.DirectoryName)

    # File is already directly in the home folder - nothing to do.
    if ($relativeDir -eq '.') {
        continue
    }

    $parts  = $relativeDir -split '[\\/]'
    $prefix = $parts -join $Separator
    $newName = "$prefix$Separator$($file.Name)"
    $destPath = Join-Path $bossparent $newName

    # Avoid overwriting if the target name already exists.
    $counter = 1
    while (Test-Path -LiteralPath $destPath) {
        $newName = "$prefix$Separator$($file.BaseName)_$counter$($file.Extension)"
        $destPath = Join-Path $bossparent $newName
        $counter++
    }

    if ($PSCmdlet.ShouldProcess($file.FullName, "Move to $destPath")) {
        Move-Item -LiteralPath $file.FullName -Destination $destPath
        Write-Host "$relativeDir\$($file.Name) -> $newName" -ForegroundColor Green
    }
}

if ($RemoveEmptyFolders) {
    # Repeat a couple of passes so nested empty folders (parent becomes
    # empty only after its empty child is removed) get cleaned up too.
    for ($i = 0; $i -lt 5; $i++) {
        Get-ChildItem -Path $bossparent -Directory -Recurse |
            Where-Object { (Get-ChildItem -Path $_.FullName -Force | Measure-Object).Count -eq 0 } |
            ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, "Remove empty folder")) {
                    Remove-Item -LiteralPath $_.FullName
                }
            }
    }
}