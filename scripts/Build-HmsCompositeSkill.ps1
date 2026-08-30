[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [string]$OutputRoot = (Join-Path $env:USERPROFILE '.codex\hms-composite'),
    [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.agents\skills'),
    [bool]$Hms = $true,
    [bool]$Superpowers = $true,
    [bool]$Taste = $true,
    [bool]$Impeccable = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BuildMutexName = 'Local\HMS-Skills-Codex-CompositeBuild-v1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$selfRelative = 'scripts/Build-HmsCompositeSkill.ps1'
$implementationRelative = 'scripts/Build-HmsCompositeSkill.impl.ps1'
$helperRelative = 'scripts/Copy-HmsCommittedGitPath.ps1'
$superLockRelative = 'superpowers.lock.json'
$uiLockRelative = 'ui-skills.lock.json'
$head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
    throw 'Composite support materialization could not resolve a canonical repository HEAD.'
}

function Get-ExpectedSupportBlob {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Label)
    $value = ((& git -C $repoRoot rev-parse "$head`:$RelativePath" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $value -notmatch '^[0-9a-f]{40}$') {
        throw "$Label support materialization could not resolve committed blob: $RelativePath"
    }
    $type = ((& git -C $repoRoot cat-file -t $value 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'blob') { throw "$Label committed support object is not a blob: $RelativePath" }
    return $value
}

function Write-SupportBlobExact {
    param(
        [Parameter(Mandatory)][string]$BlobSha,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label
    )
    if ($BlobSha -notmatch '^[0-9a-f]{40}$') { throw "$Label support blob SHA is invalid: $BlobSha" }
    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $Destination) { throw "$Label support destination already exists: $Destination" }

    $gitExe = [string](Get-Command git -ErrorAction Stop).Source
    if ([string]::IsNullOrWhiteSpace($gitExe)) { throw "$Label could not resolve git executable." }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $gitExe
    $psi.WorkingDirectory = $repoRoot
    $psi.Arguments = "cat-file blob $BlobSha"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $stream = $null
    try {
        if (-not $process.Start()) { throw "$Label git cat-file process failed to start." }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = New-Object System.IO.FileStream($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $process.StandardOutput.BaseStream.CopyTo($stream)
        $stream.Flush()
        $stream.Dispose(); $stream = $null
        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "$Label git cat-file failed with exit code $($process.ExitCode): $stderr"
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $process.Dispose()
    }

    $actual = ((& git -C $repoRoot hash-object --no-filters -- $Destination 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $actual -notmatch '^[0-9a-f]{40}$') { throw "$Label exact support materialization could not be hashed." }
    if ($actual -cne $BlobSha) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "$Label binary cat-file support materialization mismatch. Expected $BlobSha, found $actual."
    }
}

function Test-ExactHeadLifecycleCaller {
    foreach ($relative in @('install.ps1','update.ps1')) {
        $candidatePath = Join-Path $repoRoot $relative
        if (-not (Test-Path -LiteralPath $candidatePath)) { continue }
        $resolvedCandidate = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
        foreach ($frame in @(Get-PSCallStack)) {
            $scriptName = [string]$frame.ScriptName
            if ([string]::IsNullOrWhiteSpace($scriptName)) { continue }
            try { $resolvedCaller = (Resolve-Path -LiteralPath $scriptName -ErrorAction Stop).Path }
            catch { continue }
            if ($resolvedCaller -ine $resolvedCandidate) { continue }

            $expectedCaller = Get-ExpectedSupportBlob -RelativePath $relative -Label "Lifecycle caller $relative"
            $actualCaller = ((& git -C $repoRoot hash-object "--path=$relative" -- $resolvedCandidate 2>$null) -join '').Trim().ToLowerInvariant()
            if ($LASTEXITCODE -ne 0 -or $actualCaller -notmatch '^[0-9a-f]{40}$') {
                throw "Lifecycle caller bytes could not be hashed with Git clean semantics: $relative"
            }
            if ($actualCaller -cne $expectedCaller) {
                throw "Lifecycle caller bytes do not match HMS HEAD $head; refusing inherited composite-lock ownership. Expected $expectedCaller, found $actualCaller: $relative"
            }
            return $true
        }
    }
    return $false
}

$expectedSelf = Get-ExpectedSupportBlob -RelativePath $selfRelative -Label 'Public composite bootstrap'
$actualSelf = ((& git -C $repoRoot hash-object "--path=$selfRelative" -- $PSCommandPath 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $actualSelf -notmatch '^[0-9a-f]{40}$') {
    throw 'Public composite bootstrap worktree bytes could not be hashed with Git clean semantics.'
}
if ($actualSelf -cne $expectedSelf) {
    throw "Public composite bootstrap bytes do not match HMS HEAD $head; refusing hidden worktree drift. Expected $expectedSelf, found $actualSelf."
}

$lifecycleOwnsBuildMutex = Test-ExactHeadLifecycleCaller
$buildMutex = $null
$mutexOwned = $false
$supportRoot = $null
try {
    if (-not $lifecycleOwnsBuildMutex) {
        $buildMutex = New-Object System.Threading.Mutex($false, $BuildMutexName)
        try {
            $mutexOwned = $buildMutex.WaitOne([TimeSpan]::FromSeconds(120))
        }
        catch [System.Threading.AbandonedMutexException] {
            $mutexOwned = $true
        }
        if (-not $mutexOwned) { throw "Timed out waiting for composite build lock before public bootstrap: $BuildMutexName" }
    }

    $expectedImplementation = Get-ExpectedSupportBlob -RelativePath $implementationRelative -Label 'Composite implementation'
    $expectedHelper = Get-ExpectedSupportBlob -RelativePath $helperRelative -Label 'Committed-copy helper'
    $expectedSuperLock = Get-ExpectedSupportBlob -RelativePath $superLockRelative -Label 'Superpowers lock'
    $expectedUiLock = Get-ExpectedSupportBlob -RelativePath $uiLockRelative -Label 'UI skills lock'
    $supportToken = [guid]::NewGuid().ToString('N')
    $supportRoot = Join-Path ([IO.Path]::GetTempPath()) ("hms-builder-support-$supportToken")

    New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
    $implementationPath = Join-Path $supportRoot 'Build-HmsCompositeSkill.impl.ps1'
    $committedCopyHelper = Join-Path $supportRoot 'Copy-HmsCommittedGitPath.ps1'
    $committedSuperLock = Join-Path $supportRoot 'superpowers.lock.json'
    $committedUiLock = Join-Path $supportRoot 'ui-skills.lock.json'
    Write-SupportBlobExact -BlobSha $expectedImplementation -Destination $implementationPath -Label 'Composite implementation'
    Write-SupportBlobExact -BlobSha $expectedHelper -Destination $committedCopyHelper -Label 'Committed-copy helper'
    Write-SupportBlobExact -BlobSha $expectedSuperLock -Destination $committedSuperLock -Label 'Superpowers lock'
    Write-SupportBlobExact -BlobSha $expectedUiLock -Destination $committedUiLock -Label 'UI skills lock'

    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    try { $source = [IO.File]::ReadAllText($implementationPath, $utf8Strict) }
    catch { throw "Composite build implementation is not valid UTF-8: $($_.Exception.Message)" }

    function Replace-ExactlyOnce {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Needle,
            [Parameter(Mandatory)][string]$Replacement,
            [Parameter(Mandatory)][string]$Label
        )
        $count = [regex]::Matches($Text, [regex]::Escape($Needle)).Count
        if ($count -ne 1) { throw "$Label bootstrap contract mismatch: expected exactly one occurrence, found $count." }
        return $Text.Replace($Needle, $Replacement)
    }

    function Replace-RegexAtMostOnce {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Pattern,
            [Parameter(Mandatory)][string]$Replacement,
            [Parameter(Mandatory)][string]$Label
        )
        $regex = New-Object System.Text.RegularExpressions.Regex($Pattern,[System.Text.RegularExpressions.RegexOptions]::Multiline)
        $count = $regex.Matches($Text).Count
        if ($count -gt 1) { throw "$Label bootstrap contract mismatch: expected at most one occurrence, found $count." }
        if ($count -eq 0) { return $Text }
        return $regex.Replace($Text, $Replacement, 1)
    }

    $escapedHelper = $committedCopyHelper.Replace("'", "''")
    $directoryCopyNeedle = '    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force'
    $directoryCopyReplacement = "    & '$escapedHelper' -Source `$Source -Destination `$Destination"
    $source = Replace-ExactlyOnce -Text $source -Needle $directoryCopyNeedle -Replacement $directoryCopyReplacement -Label 'Committed skill-tree copy'

    $resolverCopyNeedle = "    Copy-Item -LiteralPath `$ModelResolverSource -Destination (Join-Path `$modelDispatcherDestination 'Resolve-HmsModelRoute.ps1') -Force"
    $resolverCopyReplacement = "    & '$escapedHelper' -Source `$ModelResolverSource -Destination (Join-Path `$modelDispatcherDestination 'Resolve-HmsModelRoute.ps1')"
    $source = Replace-ExactlyOnce -Text $source -Needle $resolverCopyNeedle -Replacement $resolverCopyReplacement -Label 'Committed model-resolver copy'

    $escapedSuperLock = $committedSuperLock.Replace("'", "''")
    $superLockNeedle = '$SuperpowersLockPath = Join-Path $InstallRoot ''superpowers.lock.json'''
    $superLockReplacement = "`$SuperpowersLockPath = '$escapedSuperLock'"
    $source = Replace-ExactlyOnce -Text $source -Needle $superLockNeedle -Replacement $superLockReplacement -Label 'Committed Superpowers lock binding'

    $escapedUiLock = $committedUiLock.Replace("'", "''")
    $uiLockNeedle = '$UiLockPath = Join-Path $InstallRoot ''ui-skills.lock.json'''
    $uiLockReplacement = "`$UiLockPath = '$escapedUiLock'"
    $source = Replace-ExactlyOnce -Text $source -Needle $uiLockNeedle -Replacement $uiLockReplacement -Label 'Committed UI lock binding'

    $canonicalRemoteNeedle = '$CanonicalHmsRemote = ''https://github.com/hoangminhsang989/HMS-Skills-Codex.git'''
    $canonicalRemoteReplacement = $canonicalRemoteNeedle + "`n`$ExpectedHmsSupportHead = '$head'"
    $source = Replace-ExactlyOnce -Text $source -Needle $canonicalRemoteNeedle -Replacement $canonicalRemoteReplacement -Label 'HMS support HEAD binding'

    $hmsIdentityNeedle = "        hms = (Assert-GitSourceIdentity -Path `$InstallRoot -ExpectedRepository `$CanonicalHmsRemote -Label 'HMS Skills Codex')"
    $hmsIdentityReplacement = "        hms = (Assert-GitSourceIdentity -Path `$InstallRoot -ExpectedRepository `$CanonicalHmsRemote -ExpectedCommit `$ExpectedHmsSupportHead -Label 'HMS Skills Codex')"
    $source = Replace-ExactlyOnce -Text $source -Needle $hmsIdentityNeedle -Replacement $hmsIdentityReplacement -Label 'HMS source/support identity binding'

    $legacyAuthorityLiteral = '1. Owner instruction and current project authority always outrank every internal module.'
    $authorityLiteral = '1. Authority precedence is fixed, highest to lowest: Owner instruction > latest valid HMS checkpoint / frozen authority > HMS fail-closed + safety rules > HMS model risk floor + dedicated model dispatcher > HMS project-specific product / UI authority > explicitly requested Three-Level Delivery governance > enabled Superpowers engineering method > CodeGraph context/evidence + enabled UI advisors > Codex defaults. Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.'
    $authorityNeedle = "        '$legacyAuthorityLiteral',"
    $authorityReplacement = "        '$authorityLiteral',"
    $source = Replace-ExactlyOnce -Text $source -Needle $authorityNeedle -Replacement $authorityReplacement -Label 'Generated authority precedence'

    $legacyUiSequence = 'Apply only enabled work modules, sequentially, inside owner/project UI authority. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
    $uiSequence = 'Apply only enabled work modules sequentially after the applicable higher HMS checkpoint, fail-closed/safety, and required-model-floor gates are satisfied. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
    $source = Replace-ExactlyOnce -Text $source -Needle $legacyUiSequence -Replacement $uiSequence -Label 'UI authority sequence'

    # The public wrapper or exact install/update lifecycle owns the one cross-process lock.
    # The committed implementation remains independently lock-capable when invoked directly,
    # but its dynamic wrapper execution must never recursively acquire the same thread-affine Mutex.
    $implementationLockPattern = '(?m)^\$buildMutex = New-Object System\.Threading\.Mutex\(\$false, \$BuildMutexName\)\r?\n\$mutexOwned = \$false\r?\n\$stage = \$null\r?\ntry \{\r?\n    try \{\r?\n        \$mutexOwned = \$buildMutex\.WaitOne\(\[TimeSpan\]::FromSeconds\(120\)\)\r?\n    \}\r?\n    catch \[System\.Threading\.AbandonedMutexException\] \{\r?\n        \$mutexOwned = \$true\r?\n    \}\r?\n    if \(-not \$mutexOwned\) \{ throw "Timed out waiting for composite build lock: \$BuildMutexName" \}\r?\n'
    $implementationLockReplacement = '$buildMutex = $null' + "`n" + '$mutexOwned = $false' + "`n" + '$stage = $null' + "`n" + 'try {' + "`n"
    $source = Replace-RegexAtMostOnce -Text $source -Pattern $implementationLockPattern -Replacement $implementationLockReplacement -Label 'Dynamic implementation composite mutex acquisition'
    $source = Replace-RegexAtMostOnce -Text $source -Pattern '(?m)^    \$buildMutex\.Dispose\(\)\r?$' -Replacement '    if ($null -ne $buildMutex) { $buildMutex.Dispose() }' -Label 'Dynamic implementation composite mutex disposal'

    try { $implementation = [ScriptBlock]::Create($source) }
    catch { throw "Composite build implementation failed to parse after deterministic trust-boundary binding: $($_.Exception.Message)" }

    & $implementation -InstallRoot $InstallRoot -OutputRoot $OutputRoot -SkillsRoot $SkillsRoot -Hms $Hms -Superpowers $Superpowers -Taste $Taste -Impeccable $Impeccable

    $generatedSkill = Join-Path (Join-Path $OutputRoot 'hms-superpowers') 'SKILL.md'
    if (-not (Test-Path -LiteralPath $generatedSkill)) { throw "Generated composite SKILL.md is missing after build: $generatedSkill" }
    $generatedText = [IO.File]::ReadAllText($generatedSkill, $utf8Strict)
    if ($generatedText -notmatch [regex]::Escape($authorityLiteral)) { throw 'Generated composite omitted the canonical HMS authority precedence.' }
    if ($generatedText -match [regex]::Escape($legacyAuthorityLiteral)) { throw 'Generated composite retained the superseded project-authority precedence.' }
    if ($generatedText -notmatch [regex]::Escape('Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.')) {
        throw 'Generated composite did not preserve the project-authority safety boundary.'
    }

    Write-Host "PASS: public bootstrap, implementation, committed-copy helper, and lock inputs are bound to HMS HEAD $head; published source bytes are Git-object-derived and authority precedence is pinned below HMS checkpoint/safety/model-floor gates."
}
finally {
    if ($null -ne $supportRoot -and (Test-Path -LiteralPath $supportRoot)) {
        Remove-Item -LiteralPath $supportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $mutexReleaseError = $null
    if ($mutexOwned) {
        try {
            $buildMutex.ReleaseMutex()
            $mutexOwned = $false
        }
        catch {
            $mutexReleaseError = $_
        }
    }
    if ($null -ne $buildMutex) { $buildMutex.Dispose() }
    if ($null -ne $mutexReleaseError) {
        throw "Failed to release composite build lock after public wrapper lifecycle: $($mutexReleaseError.Exception.Message)"
    }
}
