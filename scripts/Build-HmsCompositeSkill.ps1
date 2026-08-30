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
    return $value
}

$expectedImplementation = Get-ExpectedSupportBlob -RelativePath $implementationRelative -Label 'Composite implementation'
$expectedHelper = Get-ExpectedSupportBlob -RelativePath $helperRelative -Label 'Committed-copy helper'
$supportToken = [guid]::NewGuid().ToString('N')
$supportArchive = Join-Path ([IO.Path]::GetTempPath()) ("hms-builder-support-$supportToken.zip")
$supportRoot = Join-Path ([IO.Path]::GetTempPath()) ("hms-builder-support-$supportToken")

try {
    & git -C $repoRoot archive --format=zip "--output=$supportArchive" $head -- $implementationRelative $helperRelative
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $supportArchive)) {
        throw 'Composite support Git-object archive failed.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($supportArchive, $supportRoot)

    $implementationPath = Join-Path $supportRoot ($implementationRelative -replace '/', '\')
    $committedCopyHelper = Join-Path $supportRoot ($helperRelative -replace '/', '\')
    foreach ($entry in @(
        [pscustomobject]@{ Path=$implementationPath; Expected=$expectedImplementation; Label='Composite implementation' },
        [pscustomobject]@{ Path=$committedCopyHelper; Expected=$expectedHelper; Label='Committed-copy helper' }
    )) {
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { throw "$($entry.Label) committed support file is missing after archive extraction." }
        $actual = ((& git -C $repoRoot hash-object --no-filters -- $entry.Path 2>$null) -join '').Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $actual -notmatch '^[0-9a-f]{40}$') { throw "$($entry.Label) committed support file could not be hashed." }
        if ($actual -cne [string]$entry.Expected) {
            throw "$($entry.Label) archived support file does not match exact HEAD blob. Expected $($entry.Expected), found $actual. Archive attributes/filters must not transform support bytes."
        }
    }

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
    if ($generatedText -notmatch [regex]::Escape($authorityLiteral)) {
        throw 'Generated composite omitted the canonical HMS authority precedence.'
    }
    if ($generatedText -match [regex]::Escape($legacyAuthorityLiteral)) {
        throw 'Generated composite retained the superseded project-authority precedence.'
    }
    if ($generatedText -notmatch [regex]::Escape('Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.')) {
        throw 'Generated composite did not preserve the project-authority safety boundary.'
    }

    Write-Host 'PASS: composite support bytes and source copies are exact-HEAD Git-object-derived; generated authority precedence is pinned below HMS checkpoint/safety/model-floor gates.'
}
finally {
    Remove-Item -LiteralPath $supportArchive -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $supportRoot) { Remove-Item -LiteralPath $supportRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
