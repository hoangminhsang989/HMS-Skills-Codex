[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [string]$ExpectedHead
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
        throw "Unable to compute literal Git blob hash for materialized file: $Path"
    }
    return $value
}

function Assert-SafeRelativeGitPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw 'Committed-copy tree produced an empty relative path.' }
    if ($RelativePath.Contains('\')) { throw "Committed-copy Git path contains a backslash and is unsafe on Windows: $RelativePath" }
    if ($RelativePath.StartsWith('/') -or $RelativePath -match '^[A-Za-z]:') { throw "Committed-copy Git path is rooted: $RelativePath" }
    foreach ($segment in @($RelativePath -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Committed-copy Git path contains an unsafe segment: $RelativePath"
        }
    }
}

function Get-SafeDestinationPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )
    Assert-SafeRelativeGitPath -RelativePath $RelativePath
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $candidate = $rootFull
    foreach ($segment in @($RelativePath -split '/')) { $candidate = Join-Path $candidate $segment }
    $candidateFull = [IO.Path]::GetFullPath($candidate)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Committed-copy destination escaped managed root: $RelativePath"
    }
    return $candidateFull
}

function Restore-ExecutableMode {
    param([Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Mode)
    if ($Mode -notin @('100644','100755')) { throw "Unsupported committed file mode: $Mode" }
    if ($Mode -ceq '100755' -and $env:OS -cne 'Windows_NT') {
        & chmod 755 -- $Destination
        if ($LASTEXITCODE -ne 0) { throw "Failed to restore executable mode on materialized file: $Destination" }
    }
}

$sourceFull = Get-FullPathWithoutExistenceRequirement -Path $Source
$probePath = Get-ExistingProbePath -Path $Source
if (-not (Test-Path -LiteralPath $probePath -PathType Container)) { $probePath = Split-Path -Parent $probePath }

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

if ([string]::IsNullOrWhiteSpace($ExpectedHead)) {
    $head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
        throw "Committed-copy source HEAD is not a canonical 40-hex commit: $repoRoot"
    }
}
else {
    $head = $ExpectedHead.Trim().ToLowerInvariant()
    if ($head -notmatch '^[0-9a-f]{40}$') { throw "Committed-copy expected HEAD is invalid: $ExpectedHead" }
    $commitType = ((& git -C $repoRoot cat-file -t $head 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $commitType -cne 'commit') {
        throw "Committed-copy expected source commit is unavailable: $head"
    }
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
$entries = [ordered]@{}
$archiveIndex = [ordered]@{}
$treePrefix = if ($pathSpec -ceq '.') { '' } else { $pathSpec.TrimEnd('/') + '/' }
foreach ($line in $treeLines) {
    $text = [string]$line
    if ($text -notmatch '^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') {
        throw "Committed-copy path contains a non-regular or unparseable Git entry: $text"
    }
    $mode = $Matches[1]
    $blob = $Matches[2].ToLowerInvariant()
    $repoRelative = $Matches[3].Replace('\','/')
    Assert-SafeRelativeGitPath -RelativePath $repoRelative
    if ($sourceType -ceq 'blob') {
        $relative = Split-Path -Leaf $repoRelative
    }
    else {
        if (-not [string]::IsNullOrEmpty($treePrefix) -and -not $repoRelative.StartsWith($treePrefix, [StringComparison]::Ordinal)) {
            throw "Committed-copy tree entry escaped requested source path: $repoRelative"
        }
        $relative = if ([string]::IsNullOrEmpty($treePrefix)) { $repoRelative } else { $repoRelative.Substring($treePrefix.Length) }
    }
    Assert-SafeRelativeGitPath -RelativePath $relative
    if ($entries.Contains($relative)) { throw "Committed-copy tree produced a duplicate relative path: $relative" }
    if ($archiveIndex.Contains($repoRelative)) { throw "Committed-copy tree produced a duplicate archive path: $repoRelative" }
    $entries[$relative] = [pscustomobject]@{ Mode=$mode; Blob=$blob; ArchivePath=$repoRelative }
    $archiveIndex[$repoRelative] = $relative
}
if ($sourceType -ceq 'blob' -and $entries.Count -ne 1) {
    throw "Committed-copy blob source enumerated $($entries.Count) files instead of one: $pathSpec"
}

if (Test-Path -LiteralPath $Destination) { throw "Committed-copy destination already exists: $Destination" }

$gitCommand = Get-Command git -ErrorAction Stop
$gitExe = [string]$gitCommand.Source
if ([string]::IsNullOrWhiteSpace($gitExe)) { throw 'Unable to resolve git executable for exact-HEAD archive transport.' }

$transportRoot = Join-Path ([IO.Path]::GetTempPath()) ('hms-committed-copy-transport-' + [guid]::NewGuid().ToString('N'))
$transportGit = Join-Path $transportRoot 'repo.git'
$archivePath = Join-Path $transportRoot 'committed.zip'
$destinationCreated = $false
try {
    New-Item -ItemType Directory -Force -Path $transportRoot | Out-Null
    & $gitExe init --bare --quiet $transportGit
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $transportGit -PathType Container)) {
        throw 'Committed-copy could not initialize isolated Git object transport.'
    }

    $objectsPath = ((& $gitExe -C $repoRoot rev-parse --path-format=absolute --git-path objects 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($objectsPath) -or -not (Test-Path -LiteralPath $objectsPath -PathType Container)) {
        throw 'Committed-copy could not resolve source Git object directory.'
    }
    $alternatesPath = Join-Path $transportGit 'objects\info\alternates'
    [IO.File]::WriteAllText($alternatesPath, ($objectsPath.Replace('\','/') + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    # Source-repository worktree/info attributes are outside this isolated transport. These highest-precedence
    # attributes neutralize archive/EOL transforms; every extracted file must still hash to its exact qualified blob.
    $attributesPath = Join-Path $transportGit 'info\attributes'
    $neutralAttributes = '** -text -crlf -eol -ident -filter -working-tree-encoding -export-ignore -export-subst' + "`n"
    [IO.File]::WriteAllText($attributesPath, $neutralAttributes, (New-Object System.Text.UTF8Encoding($false)))

    & $gitExe "--git-dir=$transportGit" -c core.autocrlf=false -c core.eol=lf archive --format=zip "--output=$archivePath" $head -- $pathSpec
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Committed-copy exact-commit archive transport failed: $pathSpec"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $archiveFiles = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($archiveFiles.Count -ne $entries.Count) {
            throw "Committed-copy archive file count mismatch. Expected $($entries.Count), found $($archiveFiles.Count)."
        }
        foreach ($archiveEntry in $archiveFiles) {
            if (-not $archiveIndex.Contains($archiveEntry.FullName)) {
                throw "Committed-copy archive contained an unexpected file entry: $($archiveEntry.FullName)"
            }
        }

        if ($sourceType -ceq 'tree') {
            New-Item -ItemType Directory -Force -Path $Destination | Out-Null
            $destinationCreated = $true
        }

        foreach ($relative in @($entries.Keys)) {
            $entry = $entries[$relative]
            $archiveEntryPath = [string]$entry.ArchivePath
            $matches = @($archiveFiles | Where-Object { $_.FullName -ceq $archiveEntryPath })
            if ($matches.Count -ne 1) {
                throw "Committed-copy expected exactly one archive file '$archiveEntryPath', found $($matches.Count)."
            }

            $target = if ($sourceType -ceq 'blob') { [IO.Path]::GetFullPath($Destination) } else { Get-SafeDestinationPath -Root $Destination -RelativePath ([string]$relative) }
            if (Test-Path -LiteralPath $target) { throw "Committed-copy materialization destination already exists: $target" }
            $parent = Split-Path -Parent $target
            if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

            $input = $matches[0].Open()
            $output = New-Object System.IO.FileStream($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $input.CopyTo($output)
                $output.Flush()
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }

            $actual = Get-LiteralBlobHash -RepoRoot $repoRoot -Path $target
            if ($actual -cne [string]$entry.Blob) {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                throw "Committed-copy exact-commit archive transport changed committed bytes for '$archiveEntryPath'. Expected $($entry.Blob), found $actual."
            }
            Restore-ExecutableMode -Destination $target -Mode ([string]$entry.Mode)
        }
    }
    finally {
        $archive.Dispose()
    }

    if ($sourceType -ceq 'tree') {
        $materializedFiles = @(Get-ChildItem -LiteralPath $Destination -File -Recurse -Force)
        if ($materializedFiles.Count -ne $entries.Count) {
            throw "Committed-copy materialized file count mismatch. Expected $($entries.Count), found $($materializedFiles.Count)."
        }
    }
}
catch {
    if (Test-Path -LiteralPath $Destination) {
        if ($sourceType -ceq 'tree' -or $destinationCreated) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue }
        else { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $transportRoot) { Remove-Item -LiteralPath $transportRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "PASS: materialized exact committed Git blobs from HEAD $head through an isolated no-EOL archive transport with literal per-file blob verification: $pathSpec"
