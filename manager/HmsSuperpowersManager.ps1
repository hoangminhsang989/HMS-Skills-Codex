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
