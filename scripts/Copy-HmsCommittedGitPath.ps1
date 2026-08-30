[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPathWithoutExistenceRequirement {
    param([Parameter(Mandatory)][string]$Path)
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return [IO.Path]::GetFullPath($Path).TrimEnd($trimChars)
}

function Get-ExistingProbePath {
    param([Parameter(Mandatory)][string]$Path)
    $probe = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $probe)) {
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) {
            throw "Unable to locate an existing parent for Git source path: $Path"
        }
        $probe = $parent
    }
    return $probe
}

function Get-LiteralBlobHash {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Path)
    $value = ((& git -C $RepoRoot hash-object --no-filters -- $Path 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $value -notmatch '^[0-9a-f]{40}$') {
        throw "Unable to compute literal Git blob hash for extracted file: $Path"
    }
    return $value
}

function Assert-MaterializedFilesMatchHead {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MaterializedPath,
        [Parameter(Mandatory)][string]$SourceType,
        [Parameter(Mandatory)]$ExpectedBlobs
    )

    if ($SourceType -ceq 'blob') {
        if (-not (Test-Path -LiteralPath $MaterializedPath -PathType Leaf)) {
            throw "Committed-copy materialization expected one file but did not find it: $MaterializedPath"
        }
        if ($ExpectedBlobs.Count -ne 1) { throw 'Committed-copy blob verification expected exactly one Git blob.' }
        $expected = [string](@($ExpectedBlobs.Values)[0])
        $actual = Get-LiteralBlobHash -RepoRoot $RepoRoot -Path $MaterializedPath
        if ($actual -cne $expected) {
            throw "Committed-copy materialized blob mismatch. Expected $expected, found $actual. Archive attributes/filters must not transform committed bytes."
        }
        return
    }

    if (-not (Test-Path -LiteralPath $MaterializedPath -PathType Container)) {
        throw "Committed-copy materialization expected a directory tree: $MaterializedPath"
    }
    $files = @(Get-ChildItem -LiteralPath $MaterializedPath -File -Recurse -Force)
    if ($files.Count -ne $ExpectedBlobs.Count) {
        throw "Committed-copy materialized file count mismatch. Expected $($ExpectedBlobs.Count), found $($files.Count). Archive export-ignore/local attributes must not change the committed tree."
    }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($MaterializedPath.Length).TrimStart('\','/').Replace('\','/')
        if (-not $ExpectedBlobs.Contains($relative)) {
            throw "Committed-copy materialization contains an unexpected file: $relative"
        }
        $expected = [string]$ExpectedBlobs[$relative]
        $actual = Get-LiteralBlobHash -RepoRoot $RepoRoot -Path $file.FullName
        if ($actual -cne $expected) {
            throw "Committed-copy materialized blob mismatch for '$relative'. Expected $expected, found $actual. Archive attributes/filters must not transform committed bytes."
        }
    }
}

$sourceFull = Get-FullPathWithoutExistenceRequirement -Path $Source
$probePath = Get-ExistingProbePath -Path $Source
if (-not (Test-Path -LiteralPath $probePath -PathType Container)) {
    $probePath = Split-Path -Parent $probePath
}

$repoTopRaw = ((& git -C $probePath rev-parse --show-toplevel 2>$null) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoTopRaw)) {
    throw "Committed-copy source is not inside a readable Git checkout: $Source"
}
$repoRoot = Get-FullPathWithoutExistenceRequirement -Path $repoTopRaw
$separator = [string][IO.Path]::DirectorySeparatorChar
$prefix = $repoRoot + $separator
if ($sourceFull -ieq $repoRoot) {
    $pathSpec = '.'
}
elseif ($sourceFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    $pathSpec = $sourceFull.Substring($prefix.Length).Replace('\','/')
}
else {
    throw "Committed-copy source escaped its Git repository root: $Source"
}

$head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
    throw "Committed-copy source HEAD is not a canonical 40-hex commit: $repoRoot"
}

$objectSpec = if ($pathSpec -ceq '.') { "$head`:" } else { "$head`:$pathSpec" }
$sourceType = ((& git -C $repoRoot cat-file -t $objectSpec 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $sourceType -notin @('blob','tree')) {
    throw "Committed-copy path is not a regular blob/tree in source HEAD $head : $pathSpec"
}

$treeLines = @(& git -C $repoRoot -c 'core.quotePath=false' ls-tree -r $head -- $pathSpec 2>$null)
if ($LASTEXITCODE -ne 0 -or $treeLines.Count -eq 0) {
    throw "Committed-copy tree could not be enumerated from HEAD $head : $pathSpec"
}
$expectedBlobs = [ordered]@{}
$treePrefix = if ($pathSpec -ceq '.') { '' } else { $pathSpec.TrimEnd('/') + '/' }
foreach ($line in $treeLines) {
    $text = [string]$line
    if ($text -notmatch '^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') {
        throw "Committed-copy path contains a non-regular or unparseable Git entry; refusing archive extraction: $text"
    }
    $blob = $Matches[2].ToLowerInvariant()
    $repoRelative = $Matches[3].Replace('\','/')
    if ($sourceType -ceq 'blob') {
        $relative = Split-Path -Leaf $repoRelative
    }
    else {
        if (-not [string]::IsNullOrEmpty($treePrefix) -and -not $repoRelative.StartsWith($treePrefix, [StringComparison]::Ordinal)) {
            throw "Committed-copy tree entry escaped requested source path: $repoRelative"
        }
        $relative = if ([string]::IsNullOrEmpty($treePrefix)) { $repoRelative } else { $repoRelative.Substring($treePrefix.Length) }
    }
    if ([string]::IsNullOrWhiteSpace($relative) -or $expectedBlobs.Contains($relative)) {
        throw "Committed-copy tree produced an invalid/duplicate relative path: $relative"
    }
    $expectedBlobs[$relative] = $blob
}
if ($sourceType -ceq 'blob' -and $expectedBlobs.Count -ne 1) {
    throw "Committed-copy blob source enumerated $($expectedBlobs.Count) files instead of one: $pathSpec"
}

if (Test-Path -LiteralPath $Destination) {
    throw "Committed-copy destination already exists: $Destination"
}

$token = [guid]::NewGuid().ToString('N')
$archivePath = Join-Path ([IO.Path]::GetTempPath()) ("hms-committed-$token.zip")
$extractRoot = Join-Path ([IO.Path]::GetTempPath()) ("hms-committed-$token")
try {
    & git -C $repoRoot archive --format=zip "--output=$archivePath" $head -- $pathSpec
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath)) {
        throw "git archive failed for committed source $head : $pathSpec"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractRoot)

    $extracted = $extractRoot
    if ($pathSpec -ne '.') {
        foreach ($segment in @($pathSpec -split '/')) {
            if ([string]::IsNullOrWhiteSpace($segment)) { continue }
            $extracted = Join-Path $extracted $segment
        }
    }
    if (-not (Test-Path -LiteralPath $extracted)) {
        throw "Committed-copy archive did not contain expected path: $pathSpec"
    }

    Assert-MaterializedFilesMatchHead -RepoRoot $repoRoot -MaterializedPath $extracted -SourceType $sourceType -ExpectedBlobs $expectedBlobs

    $destinationParent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationParent)) {
        New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    }
    $item = Get-Item -LiteralPath $extracted -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        Copy-Item -LiteralPath $extracted -Destination $Destination -Recurse -Force
    }
    else {
        Copy-Item -LiteralPath $extracted -Destination $Destination -Force
    }

    Assert-MaterializedFilesMatchHead -RepoRoot $repoRoot -MaterializedPath $Destination -SourceType $sourceType -ExpectedBlobs $expectedBlobs
}
finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
