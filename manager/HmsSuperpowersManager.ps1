[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 decodes UTF-8-without-BOM .ps1 files through the
# active ANSI code page. Keep this public entry point ASCII-only and decode
# the reviewed UI implementation explicitly as strict UTF-8.
$repoRoot = Split-Path -Parent $PSScriptRoot
$head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
    throw 'Manager runtime trust boundary could not resolve a canonical HMS repository HEAD.'
}

function Assert-ExactHeadFile {
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
    $actual = ((& git -C $repoRoot hash-object --no-filters -- $Path 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $actual -notmatch '^[0-9a-f]{40}$') { throw "$Label literal worktree bytes could not be hashed." }
    if ($actual -cne $expected) { throw "$Label literal bytes do not match HMS HEAD $head. Expected $expected, found $actual." }
}

Assert-ExactHeadFile -Path $PSCommandPath -RelativePath 'manager/HmsSuperpowersManager.ps1' -Label 'Manager public shim'
$implementationPath = Join-Path $PSScriptRoot 'HmsSuperpowersManager.utf8.ps1'
Assert-ExactHeadFile -Path $implementationPath -RelativePath 'manager/HmsSuperpowersManager.utf8.ps1' -Label 'Manager UTF-8 implementation'
$strictReaderPath = Join-Path $repoRoot 'scripts\Read-HmsCompositeModuleState.ps1'
Assert-ExactHeadFile -Path $strictReaderPath -RelativePath 'scripts/Read-HmsCompositeModuleState.ps1' -Label 'Strict composite manifest reader'

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
try {
    $source = [IO.File]::ReadAllText($implementationPath, $utf8Strict)
}
catch {
    throw "Manager implementation is not valid UTF-8: $($_.Exception.Message)"
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
# the public runtime replaces that entry point with the shared strict manifest
# reader. Keep [CmdletBinding()]/param as the first statements in the dynamic source.
$stateNeedle = 'function Get-CurrentModuleState {'
$stateOccurrences = [regex]::Matches($source, [regex]::Escape($stateNeedle)).Count
if ($stateOccurrences -ne 1) {
    throw "Manager state-reader contract mismatch: expected exactly one Get-CurrentModuleState declaration, found $stateOccurrences."
}
$source = $source.Replace($stateNeedle, 'function Get-CurrentModuleState-Legacy {')
$escapedStrictReader = $strictReaderPath.Replace("'", "''")
$strictWrapper = @'
function Get-CurrentModuleState {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return Get-LegacyInferredState }
    return & '__STRICT_READER__' -ManifestPath $ManifestPath
}
'@
$strictWrapper = $strictWrapper.Replace('__STRICT_READER__', $escapedStrictReader)
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
