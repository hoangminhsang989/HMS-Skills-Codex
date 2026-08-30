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

# Serialize the complete write/verify/rollback transaction across processes.
# The reviewed UTF-8 implementation remains the authoritative write body; this
# shim renames it and injects one fail-closed cross-process wrapper after the
# top-level declarations so [CmdletBinding()]/param remain the first statements.
$writeNeedle = 'function Write-ModelState {'
$writeOccurrences = [regex]::Matches($source, [regex]::Escape($writeNeedle)).Count
if ($writeOccurrences -ne 1) {
    throw "Model settings writer contract mismatch: expected exactly one Write-ModelState declaration, found $writeOccurrences."
}
$source = $source.Replace($writeNeedle, 'function Write-ModelState-Unserialized {')
$writerWrapper = @'
function Write-ModelState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$Path = $SettingsPath
    )

    $settingsMutexName = 'Local\HMS-Skills-Codex-ModelSettings-v1'
    $settingsMutex = New-Object System.Threading.Mutex($false, $settingsMutexName)
    $settingsMutexOwned = $false
    try {
        try {
            $settingsMutexOwned = $settingsMutex.WaitOne([TimeSpan]::FromSeconds(120))
        }
        catch [System.Threading.AbandonedMutexException] {
            $settingsMutexOwned = $true
        }
        if (-not $settingsMutexOwned) { throw "Timed out waiting for model settings writer lock: $settingsMutexName" }
        Write-ModelState-Unserialized -State $State -Path $Path
    }
    finally {
        if ($settingsMutexOwned) {
            try { $settingsMutex.ReleaseMutex() } catch { }
        }
        $settingsMutex.Dispose()
    }
}
'@
$insertMarker = 'function Assert-ResolverAvailable {'
$insertOccurrences = [regex]::Matches($source, [regex]::Escape($insertMarker)).Count
if ($insertOccurrences -ne 1) {
    throw "Model settings wrapper insertion contract mismatch: expected one Assert-ResolverAvailable declaration, found $insertOccurrences."
}
$source = $source.Replace($insertMarker, $writerWrapper + "`r`n" + $insertMarker)

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
