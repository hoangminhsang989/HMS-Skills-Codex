[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$TrustedRepoRoot,
    [string]$TrustedHead,
    [string]$TrustedBootstrapBlob
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 decodes UTF-8-without-BOM .ps1 files through the
# active ANSI code page. Keep this public entry point ASCII-only and decode
# reviewed executable dependencies explicitly from verified byte snapshots.
$trustedValues = @($TrustedRepoRoot,$TrustedHead,$TrustedBootstrapBlob)
$trustedCount = @($trustedValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
if ($trustedCount -notin @(0,3)) {
    throw 'Manager trusted bootstrap context is incomplete; repo root, HEAD, and bootstrap blob must be supplied together.'
}
$trustedBootstrap = $trustedCount -eq 3
if ($trustedBootstrap) {
    try { $repoRoot = (Resolve-Path -LiteralPath $TrustedRepoRoot -ErrorAction Stop).Path.TrimEnd('\') }
    catch { throw "Manager trusted repository root is invalid: $TrustedRepoRoot" }
    $head = $TrustedHead.Trim().ToLowerInvariant()
    if ($head -notmatch '^[0-9a-f]{40}$') { throw "Manager trusted HEAD is invalid: $TrustedHead" }
    $trustedBlob = $TrustedBootstrapBlob.Trim().ToLowerInvariant()
    if ($trustedBlob -notmatch '^[0-9a-f]{40}$') { throw "Manager trusted bootstrap blob is invalid: $TrustedBootstrapBlob" }
    $expectedBootstrap = ((& git -C $repoRoot rev-parse "$head`:manager/HmsSuperpowersManager.ps1" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $expectedBootstrap -notmatch '^[0-9a-f]{40}$' -or $expectedBootstrap -cne $trustedBlob) {
        throw 'Manager trusted bootstrap context does not match the captured committed Manager shim.'
    }
    $bootstrapType = ((& git -C $repoRoot cat-file -t $expectedBootstrap 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $bootstrapType -cne 'blob') { throw 'Manager trusted bootstrap object is not a committed blob.' }
}
else {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
        throw 'Manager runtime trust boundary could not resolve a canonical HMS repository HEAD.'
    }
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
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Contains('\') -or $RelativePath.StartsWith('/') -or $RelativePath -match '^[A-Za-z]:') {
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
        # The exact bytes read here are the bytes hashed and later decoded/executed.
        # A pathname replacement after this snapshot cannot change executed code.
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

# Direct -File use remains fail-closed by authenticating the executing pathname.
# The official .cmd launcher supplies a trusted outer snapshot context instead,
# because code inside a modified file cannot authenticate statements that ran before it.
if (-not $trustedBootstrap) {
    if ([string]::IsNullOrWhiteSpace([string]$PSCommandPath)) { throw 'Manager direct bootstrap has no file-backed path to authenticate.' }
    $null = Read-ExactHeadFileBytes -Path $PSCommandPath -RelativePath 'manager/HmsSuperpowersManager.ps1' -Label 'Manager public shim'
}

$implementationPath = Join-Path $repoRoot 'manager\HmsSuperpowersManager.utf8.ps1'
$implementationRecord = Read-ExactHeadFileBytes -Path $implementationPath -RelativePath 'manager/HmsSuperpowersManager.utf8.ps1' -Label 'Manager UTF-8 implementation'
$strictReaderPath = Join-Path $repoRoot 'scripts\Read-HmsCompositeModuleState.ps1'
$strictReaderRecord = Read-ExactHeadFileBytes -Path $strictReaderPath -RelativePath 'scripts/Read-HmsCompositeModuleState.ps1' -Label 'Strict composite manifest reader'
$modelSettingsShimPath = Join-Path $repoRoot 'manager\HmsModelSettings.ps1'
$modelSettingsShimRecord = Read-ExactHeadFileBytes -Path $modelSettingsShimPath -RelativePath 'manager/HmsModelSettings.ps1' -Label 'Model settings public shim'

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
try {
    $source = $utf8Strict.GetString([byte[]]$implementationRecord.Bytes)
    $strictReaderSource = $utf8Strict.GetString([byte[]]$strictReaderRecord.Bytes)
    $modelSettingsShimSource = $utf8Strict.GetString([byte[]]$modelSettingsShimRecord.Bytes)
}
catch {
    throw "Manager executable dependency is not valid UTF-8: $($_.Exception.Message)"
}

try {
    $__HmsVerifiedStrictReaderScriptBlock_v1 = [ScriptBlock]::Create($strictReaderSource)
    $__HmsVerifiedModelSettingsShimScriptBlock_v1 = [ScriptBlock]::Create($modelSettingsShimSource)
}
catch {
    throw "Manager verified dependency failed to parse from its byte snapshot: $($_.Exception.Message)"
}
$__HmsTrustedRepoRoot_v1 = $repoRoot
$__HmsTrustedHead_v1 = $head
$__HmsVerifiedModelSettingsShimBlob_v1 = [string]$modelSettingsShimRecord.ExpectedBlob

# ScriptBlock.Create has no file-backed PSScriptRoot. Replace the implementation's
# single repo-root bootstrap line with the captured repository root.
$needle = '$RepoRoot = Split-Path -Parent $PSScriptRoot'
$occurrences = [regex]::Matches($source, [regex]::Escape($needle)).Count
if ($occurrences -ne 1) {
    throw "Manager UTF-8 bootstrap contract mismatch: expected exactly one repo-root bootstrap line, found $occurrences."
}
$escapedRepoRoot = $repoRoot.Replace("'", "''")
$replacement = '$RepoRoot = ''' + $escapedRepoRoot + ''''
$source = $source.Replace($needle, $replacement)

# Replace the legacy manifest parser with the strict reader loaded from verified bytes.
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

# Model Settings must not reopen its live public shim after Manager launch. Replace
# that process/file invocation with the exact Model Settings shim bytes snapshotted
# above and pass the same captured repository HEAD into its own dependency checks.
$modelInvokeNeedle = '        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ModelSettingsScript'
$modelInvokeReplacement = '        & $__HmsVerifiedModelSettingsShimScriptBlock_v1 -TrustedRepoRoot $__HmsTrustedRepoRoot_v1 -TrustedHead $__HmsTrustedHead_v1 -TrustedBootstrapBlob $__HmsVerifiedModelSettingsShimBlob_v1'
$modelInvokeCount = [regex]::Matches($source, [regex]::Escape($modelInvokeNeedle)).Count
if ($modelInvokeCount -ne 1) { throw "Manager Model Settings launch contract mismatch: expected one live shim invocation, found $modelInvokeCount." }
$source = $source.Replace($modelInvokeNeedle, $modelInvokeReplacement)
$modelExitNeedle = '        if ($LASTEXITCODE -ne 0) { throw "Model Settings popup exited with code $LASTEXITCODE." }'
$modelExitCount = [regex]::Matches($source, [regex]::Escape($modelExitNeedle)).Count
if ($modelExitCount -ne 1) { throw "Manager Model Settings exit-code contract mismatch: expected one legacy process check, found $modelExitCount." }
$source = $source.Replace($modelExitNeedle, '        # Verified Model Settings executes in-process; terminating errors propagate directly.')

try {
    $implementation = [ScriptBlock]::Create($source)
}
catch {
    throw "Manager UTF-8 implementation failed to parse after deterministic trust binding: $($_.Exception.Message)"
}

if ($SelfTest) {
    & $implementation -SelfTest
    & $__HmsVerifiedModelSettingsShimScriptBlock_v1 -SelfTest -TrustedRepoRoot $__HmsTrustedRepoRoot_v1 -TrustedHead $__HmsTrustedHead_v1 -TrustedBootstrapBlob $__HmsVerifiedModelSettingsShimBlob_v1
}
else {
    & $implementation
}
