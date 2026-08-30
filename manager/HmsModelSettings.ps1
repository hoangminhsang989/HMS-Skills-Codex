[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 may decode UTF-8-without-BOM .ps1 files through the
# active ANSI code page. Keep this public shim ASCII-only and decode the
# reviewed Vietnamese UI implementation explicitly as strict UTF-8.
$implementationPath = Join-Path $PSScriptRoot 'HmsModelSettings.utf8.ps1'
if (-not (Test-Path -LiteralPath $implementationPath)) {
    throw "Model settings implementation is missing: $implementationPath"
}

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
try {
    $source = [IO.File]::ReadAllText($implementationPath, $utf8Strict)
}
catch {
    throw "Model settings implementation is not valid UTF-8: $($_.Exception.Message)"
}

$needle = '$RepoRoot = Split-Path -Parent $PSScriptRoot'
$occurrences = [regex]::Matches($source, [regex]::Escape($needle)).Count
if ($occurrences -ne 1) {
    throw "Model settings UTF-8 bootstrap contract mismatch: expected exactly one repo-root bootstrap line, found $occurrences."
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$escapedRepoRoot = $repoRoot.Replace("'", "''")
$replacement = '$RepoRoot = ''' + $escapedRepoRoot + ''''
$source = $source.Replace($needle, $replacement)

try {
    $implementation = [ScriptBlock]::Create($source)
}
catch {
    throw "Model settings UTF-8 implementation failed to parse after deterministic bootstrap binding: $($_.Exception.Message)"
}

if ($SelfTest) {
    & $implementation -SelfTest
}
else {
    & $implementation
}
