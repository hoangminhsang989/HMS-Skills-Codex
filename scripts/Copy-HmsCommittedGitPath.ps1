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

function Write-GitBlobExact {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BlobSha,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Mode
    )

    if ($BlobSha -notmatch '^[0-9a-f]{40}$') { throw "Invalid committed blob SHA: $BlobSha" }
    if ($Mode -notin @('100644','100755')) { throw "Unsupported committed file mode: $Mode" }
    if (Test-Path -LiteralPath $Destination) { throw "Committed-copy materialization destination already exists: $Destination" }

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    $gitCommand = Get-Command git -ErrorAction Stop
    $gitExe = [string]$gitCommand.Source
    if ([string]::IsNullOrWhiteSpace($gitExe)) { throw 'Unable to resolve git executable for binary cat-file materialization.' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $gitExe
    $psi.WorkingDirectory = $RepoRoot
    $psi.Arguments = "cat-file blob $BlobSha"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $started = $false
    $stream = $null
    try {
        $started = $process.Start()
        if (-not $started) { throw "git cat-file failed to start for blob $BlobSha" }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = New-Object System.IO.FileStream($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $process.StandardOutput.BaseStream.CopyTo($stream)
        $stream.Flush()
        $stream.Dispose(); $stream = $null
        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "git cat-file failed for blob $BlobSha with exit code $($process.ExitCode): $stderr"
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $process.Dispose()
    }

    $actual = Get-LiteralBlobHash -RepoRoot $RepoRoot -Path $Destination
    if ($actual -cne $BlobSha) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Binary cat-file materialization mismatch. Expected $BlobSha, found $actual."
    }

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
$entries = [ordered]@{}
$treePrefix = if ($pathSpec -ceq '.') { '' } else { $pathSpec.TrimEnd('/') + '/' }
foreach ($line in $treeLines) {
    $text = [string]$line
    if ($text -notmatch '^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') {
        throw "Committed-copy path contains a non-regular or unparseable Git entry: $text"
    }
    $mode = $Matches[1]
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
    Assert-SafeRelativeGitPath -RelativePath $relative
    if ($entries.Contains($relative)) { throw "Committed-copy tree produced a duplicate relative path: $relative" }
    $entries[$relative] = [pscustomobject]@{ Mode=$mode; Blob=$blob }
}
if ($sourceType -ceq 'blob' -and $entries.Count -ne 1) {
    throw "Committed-copy blob source enumerated $($entries.Count) files instead of one: $pathSpec"
}

if (Test-Path -LiteralPath $Destination) { throw "Committed-copy destination already exists: $Destination" }

if ($sourceType -ceq 'blob') {
    $entry = @($entries.Values)[0]
    Write-GitBlobExact -RepoRoot $repoRoot -BlobSha ([string]$entry.Blob) -Destination $Destination -Mode ([string]$entry.Mode)
}
else {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    try {
        foreach ($relative in @($entries.Keys)) {
            $entry = $entries[$relative]
            $target = Get-SafeDestinationPath -Root $Destination -RelativePath ([string]$relative)
            Write-GitBlobExact -RepoRoot $repoRoot -BlobSha ([string]$entry.Blob) -Destination $target -Mode ([string]$entry.Mode)
        }
        $materializedFiles = @(Get-ChildItem -LiteralPath $Destination -File -Recurse -Force)
        if ($materializedFiles.Count -ne $entries.Count) {
            throw "Committed-copy materialized file count mismatch. Expected $($entries.Count), found $($materializedFiles.Count)."
        }
    }
    catch {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

Write-Host "PASS: materialized committed Git blobs directly from HEAD $head without worktree/archive/filter transformation: $pathSpec"
