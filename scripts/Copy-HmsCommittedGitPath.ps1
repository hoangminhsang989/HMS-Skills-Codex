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

& git -C $repoRoot cat-file -e "$head`:$pathSpec" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Committed-copy path does not exist in source HEAD $head : $pathSpec"
}

$treeLines = @(& git -C $repoRoot ls-tree -r $head -- $pathSpec 2>$null)
if ($LASTEXITCODE -ne 0 -or $treeLines.Count -eq 0) {
    throw "Committed-copy tree could not be enumerated from HEAD $head : $pathSpec"
}
foreach ($line in $treeLines) {
    if ([string]$line -notmatch '^(100644|100755) blob [0-9a-f]{40}\t') {
        throw "Committed-copy path contains a non-regular Git entry; refusing archive extraction: $line"
    }
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

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $item = Get-Item -LiteralPath $extracted -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        Copy-Item -LiteralPath $extracted -Destination $Destination -Recurse -Force
    }
    else {
        Copy-Item -LiteralPath $extracted -Destination $Destination -Force
    }
}
finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
