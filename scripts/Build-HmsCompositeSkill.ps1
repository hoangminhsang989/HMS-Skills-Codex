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

$repoRoot = Split-Path -Parent $PSScriptRoot
$implementationRelative = 'scripts/Build-HmsCompositeSkill.impl.ps1'
$helperRelative = 'scripts/Copy-HmsCommittedGitPath.ps1'
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

$expectedImplementation = Get-ExpectedSupportBlob -RelativePath $implementationRelative -Label 'Composite implementation'
$expectedHelper = Get-ExpectedSupportBlob -RelativePath $helperRelative -Label 'Committed-copy helper'
$supportToken = [guid]::NewGuid().ToString('N')
$supportRoot = Join-Path ([IO.Path]::GetTempPath()) ("hms-builder-support-$supportToken")

try {
    New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
    $implementationPath = Join-Path $supportRoot 'Build-HmsCompositeSkill.impl.ps1'
    $committedCopyHelper = Join-Path $supportRoot 'Copy-HmsCommittedGitPath.ps1'
    Write-SupportBlobExact -BlobSha $expectedImplementation -Destination $implementationPath -Label 'Composite implementation'
    Write-SupportBlobExact -BlobSha $expectedHelper -Destination $committedCopyHelper -Label 'Committed-copy helper'

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

    $escapedHelper = $committedCopyHelper.Replace("'", "''")
    $directoryCopyNeedle = '    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force'
    $directoryCopyReplacement = "    & '$escapedHelper' -Source `$Source -Destination `$Destination"
    $source = Replace-ExactlyOnce -Text $source -Needle $directoryCopyNeedle -Replacement $directoryCopyReplacement -Label 'Committed skill-tree copy'

    $resolverCopyNeedle = "    Copy-Item -LiteralPath `$ModelResolverSource -Destination (Join-Path `$modelDispatcherDestination 'Resolve-HmsModelRoute.ps1') -Force"
    $resolverCopyReplacement = "    & '$escapedHelper' -Source `$ModelResolverSource -Destination (Join-Path `$modelDispatcherDestination 'Resolve-HmsModelRoute.ps1')"
    $source = Replace-ExactlyOnce -Text $source -Needle $resolverCopyNeedle -Replacement $resolverCopyReplacement -Label 'Committed model-resolver copy'

    $legacyAuthorityLiteral = '1. Owner instruction and current project authority always outrank every internal module.'
    $authorityLiteral = '1. Authority precedence is fixed, highest to lowest: Owner instruction > latest valid HMS checkpoint / frozen authority > HMS fail-closed + safety rules > HMS model risk floor + dedicated model dispatcher > HMS project-specific product / UI authority > explicitly requested Three-Level Delivery governance > enabled Superpowers engineering method > CodeGraph context/evidence + enabled UI advisors > Codex defaults. Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.'
    $authorityNeedle = "        '$legacyAuthorityLiteral',"
    $authorityReplacement = "        '$authorityLiteral',"
    $source = Replace-ExactlyOnce -Text $source -Needle $authorityNeedle -Replacement $authorityReplacement -Label 'Generated authority precedence'

    $legacyUiSequence = 'Apply only enabled work modules, sequentially, inside owner/project UI authority. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
    $uiSequence = 'Apply only enabled work modules sequentially after the applicable higher HMS checkpoint, fail-closed/safety, and required-model-floor gates are satisfied. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
    $source = Replace-ExactlyOnce -Text $source -Needle $legacyUiSequence -Replacement $uiSequence -Label 'UI authority sequence'

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

    Write-Host 'PASS: composite support and source bytes are materialized directly from exact HEAD blobs via binary git cat-file; generated authority precedence is pinned below HMS checkpoint/safety/model-floor gates.'
}
finally {
    if (Test-Path -LiteralPath $supportRoot) { Remove-Item -LiteralPath $supportRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
