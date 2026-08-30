[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 may decode UTF-8-without-BOM .ps1 files through the
# active ANSI code page. Keep this public shim ASCII-only and decode the
# reviewed Vietnamese UI implementation explicitly as strict UTF-8.
$repoRoot = Split-Path -Parent $PSScriptRoot
$head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
    throw 'Model settings runtime trust boundary could not resolve a canonical HMS repository HEAD.'
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

Assert-ExactHeadFile -Path $PSCommandPath -RelativePath 'manager/HmsModelSettings.ps1' -Label 'Model settings public shim'
$implementationPath = Join-Path $PSScriptRoot 'HmsModelSettings.utf8.ps1'
Assert-ExactHeadFile -Path $implementationPath -RelativePath 'manager/HmsModelSettings.utf8.ps1' -Label 'Model settings UTF-8 implementation'
$resolverPath = Join-Path $repoRoot 'scripts\Resolve-HmsModelRoute.ps1'
Assert-ExactHeadFile -Path $resolverPath -RelativePath 'scripts/Resolve-HmsModelRoute.ps1' -Label 'Model route resolver'

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
