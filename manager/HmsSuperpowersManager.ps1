[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 decodes UTF-8-without-BOM .ps1 files through the
# active ANSI code page. Keep this public entry point ASCII-only and decode
# the reviewed UI implementation explicitly as strict UTF-8.
$implementationPath = Join-Path $PSScriptRoot 'HmsSuperpowersManager.utf8.ps1'
if (-not (Test-Path -LiteralPath $implementationPath)) {
    throw "Manager implementation is missing: $implementationPath"
}

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
$repoRoot = Split-Path -Parent $PSScriptRoot
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
$strictReaderPath = Join-Path $repoRoot 'scripts\Read-HmsCompositeModuleState.ps1'
if (-not (Test-Path -LiteralPath $strictReaderPath)) {
    throw "Strict composite manifest reader is missing: $strictReaderPath"
}
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
