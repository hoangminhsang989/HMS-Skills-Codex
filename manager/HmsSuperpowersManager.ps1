[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 decodes UTF-8-without-BOM .ps1 files through the
# active ANSI code page. Keep this public entry point ASCII-only and decode
# reviewed executable dependencies explicitly from verified byte snapshots.
$repoRoot = Split-Path -Parent $PSScriptRoot
$head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
    throw 'Manager runtime trust boundary could not resolve a canonical HMS repository HEAD.'
}

function Get-LiteralGitBlobId {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + [string]$Bytes.Length + [char]0))
    $sha1 = [Security.Cryptography.SHA1]::Create()
    $stream = New-Object IO.MemoryStream
    try {
        $stream.Write($header, 0, $header.Length)
        if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
        $stream.Position = 0
        $digest = $sha1.ComputeHash($stream)
        return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $stream.Dispose()
        $sha1.Dispose()
    }
}

function Read-ExactHeadFileBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing: $Path" }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Contains('\\') -or $RelativePath.StartsWith('/') -or $RelativePath -match '^[A-Za-z]:') {
        throw "$Label repository-relative path is unsafe: $RelativePath"
    }
    foreach ($segment in @($RelativePath -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') { throw "$Label repository-relative path is unsafe: $RelativePath" }
    }

    $expected = ((& git -C $repoRoot rev-parse "$head`:$RelativePath" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $expected -notmatch '^[0-9a-f]{40}$') { throw "$Label committed blob could not be resolved at HMS HEAD $head." }
    $type = ((& git -C $repoRoot cat-file -t $expected 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'blob') { throw "$Label committed object is not a blob at HMS HEAD $head." }

    $stream = $null
    try {
        # FileShare.Read blocks cooperating Windows writers/deleters during the snapshot.
        # Security does not rely on that lock: the exact bytes read here are the same bytes
        # hashed below and later decoded/executed, so pathname swaps after this read are inert.
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt [int]::MaxValue) { throw "$Label is too large to verify safely." }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Label ended before the verified byte snapshot was complete." }
            $offset += $read
        }
    }
    catch {
        throw "$Label literal bytes could not be snapshotted: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $actual = Get-LiteralGitBlobId -Bytes $bytes
    if ($actual -cne $expected) { throw "$Label literal bytes do not match HMS HEAD $head. Expected $expected, found $actual." }
    return [pscustomobject]@{ Bytes=$bytes; ExpectedBlob=$expected; ActualBlob=$actual }
}

# Detect drift in the currently executing public shim. The implementation and every
# later executable dependency are additionally executed only from the exact byte
# snapshots returned by Read-ExactHeadFileBytes, eliminating verify-then-open TOCTOU.
$null = Read-ExactHeadFileBytes -Path $PSCommandPath -RelativePath 'manager/HmsSuperpowersManager.ps1' -Label 'Manager public shim'
$implementationPath = Join-Path $PSScriptRoot 'HmsSuperpowersManager.utf8.ps1'
$implementationRecord = Read-ExactHeadFileBytes -Path $implementationPath -RelativePath 'manager/HmsSuperpowersManager.utf8.ps1' -Label 'Manager UTF-8 implementation'
$strictReaderPath = Join-Path $repoRoot 'scripts\Read-HmsCompositeModuleState.ps1'
$strictReaderRecord = Read-ExactHeadFileBytes -Path $strictReaderPath -RelativePath 'scripts/Read-HmsCompositeModuleState.ps1' -Label 'Strict composite manifest reader'

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
try {
    $source = $utf8Strict.GetString([byte[]]$implementationRecord.Bytes)
    $strictReaderSource = $utf8Strict.GetString([byte[]]$strictReaderRecord.Bytes)
}
catch {
    throw "Manager executable dependency is not valid UTF-8: $($_.Exception.Message)"
}

try {
    $__HmsVerifiedStrictReaderScriptBlock_v1 = [ScriptBlock]::Create($strictReaderSource)
}
catch {
    throw "Strict composite manifest reader failed to parse from its verified byte snapshot: $($_.Exception.Message)"
}

# ScriptBlock.Create has no file-backed PSScriptRoot. Replace the implementation's
# single repo-root bootstrap line with the path proven by this file-backed shim.
$needle = '$RepoRoot = Split-Path -Parent $PSScriptRoot'
$occurrences = [regex]::Matches($source, [regex]::Escape($needle)).Count
if ($occurrences -ne 1) {
    throw "Manager UTF-8 bootstrap contract mismatch: expected exactly one repo-root bootstrap line, found $occurrences."
}
$escapedRepoRoot = $repoRoot.Replace("'", "''")
$replacement = '$RepoRoot = ''' + $escapedRepoRoot + ''''
$source = $source.Replace($needle, $replacement)

# The UTF-8 implementation retains its legacy parser for source readability, but
# the public runtime replaces that entry point with the shared strict reader loaded
# from the verified in-memory bytes above. No later live-path execution is allowed.
$stateNeedle = 'function Get-CurrentModuleState {'
$stateOccurrences = [regex]::Matches($source, [regex]::Escape($stateNeedle)).Count
if ($stateOccurrences -ne 1) {
    throw "Manager state-reader contract mismatch: expected exactly one Get-CurrentModuleState declaration, found $stateOccurrences."
}
$source = $source.Replace($stateNeedle, 'function Get-CurrentModuleState-Legacy {')
$strictWrapper = @'
function Get-CurrentModuleState {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return Get-LegacyInferredState }
    return & $__HmsVerifiedStrictReaderScriptBlock_v1 -ManifestPath $ManifestPath
}
'@
$insertMarker = 'function Assert-BuilderAvailable {'
$insertOccurrences = [regex]::Matches($source, [regex]::Escape($insertMarker)).Count
if ($insertOccurrences -ne 1) {
    throw "Manager strict-reader insertion contract mismatch: expected one Assert-BuilderAvailable declaration, found $insertOccurrences."
}
$source = $source.Replace($insertMarker, $strictWrapper + "`r`n" + $insertMarker)

try {
    $implementation = [ScriptBlock]::Create($source)
}
catch {
    throw "Manager UTF-8 implementation failed to parse after deterministic bootstrap binding: $($_.Exception.Message)"
}

if ($SelfTest) {
    & $implementation -SelfTest
}
else {
    & $implementation
}
