[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$builderPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.ps1'
$builderImplPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.impl.ps1'
$copyHelperPath = Join-Path $RepoRoot 'scripts\Copy-HmsCommittedGitPath.ps1'
$installPath = Join-Path $RepoRoot 'install.ps1'
$updatePath = Join-Path $RepoRoot 'update.ps1'
foreach ($path in @($builderPath,$builderImplPath,$copyHelperPath,$installPath,$updatePath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Trust-remediation support file is missing: $path" }
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -ne 0) {
        throw "PowerShell parser rejected trust-remediation file '$path': $((@($parseErrors) | ForEach-Object { $_.Message }) -join ' | ')"
    }
}

$builderText = Get-Content -LiteralPath $builderPath -Raw
$helperText = Get-Content -LiteralPath $copyHelperPath -Raw
$installText = Get-Content -LiteralPath $installPath -Raw
$updateText = Get-Content -LiteralPath $updatePath -Raw
$canonicalAuthority = 'Authority precedence is fixed, highest to lowest: Owner instruction > latest valid HMS checkpoint / frozen authority > HMS fail-closed + safety rules > HMS model risk floor + dedicated model dispatcher > HMS project-specific product / UI authority > explicitly requested Three-Level Delivery governance > enabled Superpowers engineering method > CodeGraph context/evidence + enabled UI advisors > Codex defaults.'
$badAuthority = 'Owner instruction and current project authority always outrank every internal module.'
foreach ($literal in @(
    'Copy-HmsCommittedGitPath.ps1',
    'Write-SupportBlobExact',
    'cat-file blob',
    'superpowers.lock.json',
    'ui-skills.lock.json',
    'ExpectedHmsSupportHead',
    'Public composite bootstrap bytes do not match HMS HEAD',
    $canonicalAuthority,
    'Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.',
    'Generated composite omitted the canonical HMS authority precedence.'
)) {
    if ($builderText -notmatch [regex]::Escape($literal)) { throw "Builder trust wrapper is missing required contract literal: $literal" }
}
foreach ($literal in @(
    'Write-GitBlobExact',
    'cat-file blob',
    'hash-object --no-filters',
    'materialized committed Git blobs directly from HEAD'
)) {
    if ($helperText -notmatch [regex]::Escape($literal)) { throw "Committed-copy helper is missing required raw-blob contract literal: $literal" }
}
foreach ($entry in @(
    [pscustomobject]@{ Name='installer'; Text=$installText },
    [pscustomobject]@{ Name='updater'; Text=$updateText }
)) {
    foreach ($literal in @('Assert-NoHiddenIndexState','skip-worktree/assume-unchanged index flags')) {
        if ($entry.Text -notmatch [regex]::Escape($literal)) { throw "$($entry.Name) is missing hidden-index trust gate literal: $literal" }
    }
}
if ($builderText -match [regex]::Escape("'$badAuthority'")) {
    throw 'Builder trust wrapper retained the superseded generated authority rule.'
}
if ($builderText -match 'git\s+-C\s+\$repoRoot\s+archive' -or $helperText -match 'git\s+-C\s+\$repoRoot\s+archive') {
    throw 'Raw committed-byte materialization regressed to git archive.'
}

# Trust-root regression: public bootstrap must detect its own hidden drift; all other support/lock inputs execute from HEAD blobs.
$supportTemp = Join-Path ([IO.Path]::GetTempPath()) ('hms-support-bind-' + [guid]::NewGuid().ToString('N'))
$supportRepo = Join-Path $supportTemp 'repo'
$supportScripts = Join-Path $supportRepo 'scripts'
$builderRelative = 'scripts/Build-HmsCompositeSkill.ps1'
$supportRelative = 'scripts/Build-HmsCompositeSkill.impl.ps1'
$helperRelative = 'scripts/Copy-HmsCommittedGitPath.ps1'
$superLockRelative = 'superpowers.lock.json'
$uiLockRelative = 'ui-skills.lock.json'
$sourceRelative = 'skills/fixture-source/SKILL.md'
$hiddenFlags = New-Object System.Collections.Generic.List[string]
try {
    New-Item -ItemType Directory -Force -Path $supportScripts | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $supportRepo 'skills\fixture-source') | Out-Null
    Copy-Item -LiteralPath $builderPath -Destination (Join-Path $supportScripts 'Build-HmsCompositeSkill.ps1') -Force
    Copy-Item -LiteralPath $copyHelperPath -Destination (Join-Path $supportScripts 'Copy-HmsCommittedGitPath.ps1') -Force

    $syntheticImpl = @'
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$OutputRoot,
    [string]$SkillsRoot,
    [bool]$Hms = $true,
    [bool]$Superpowers = $true,
    [bool]$Taste = $true,
    [bool]$Impeccable = $true
)
$SuperpowersLockPath = Join-Path $InstallRoot 'superpowers.lock.json'
$UiLockPath = Join-Path $InstallRoot 'ui-skills.lock.json'
$CanonicalHmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
if ($false) {
    $unusedHeads = [ordered]@{
        hms = (Assert-GitSourceIdentity -Path $InstallRoot -ExpectedRepository $CanonicalHmsRemote -Label 'HMS Skills Codex')
    }
}
function Copy-SkillModule {
    param([string]$Source,[string]$Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}
$ModelResolverSource = 'unused'
$modelDispatcherDestination = 'unused'
if ($false) {
    Copy-Item -LiteralPath $ModelResolverSource -Destination (Join-Path $modelDispatcherDestination 'Resolve-HmsModelRoute.ps1') -Force
}
$lines = @(
        '1. Owner instruction and current project authority always outrank every internal module.',
        'fixture continuation'
)
$uiSequence = 'Apply only enabled work modules, sequentially, inside owner/project UI authority. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
$target = Join-Path $OutputRoot 'hms-superpowers'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-SkillModule -Source (Join-Path $InstallRoot 'skills\fixture-source') -Destination (Join-Path $target 'references\fixture-source')
$superRaw = [IO.File]::ReadAllText($SuperpowersLockPath)
$uiRaw = [IO.File]::ReadAllText($UiLockPath)
Set-Content -LiteralPath (Join-Path $target 'SKILL.md') -Value (($lines + $uiSequence + $superRaw + $uiRaw) -join "`r`n") -Encoding UTF8
'@
    [IO.File]::WriteAllText((Join-Path $supportScripts 'Build-HmsCompositeSkill.impl.ps1'), $syntheticImpl, (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $supportRepo $superLockRelative), '{"fixture":"COMMITTED_SUPER_LOCK"}', (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $supportRepo $uiLockRelative), '{"fixture":"COMMITTED_UI_LOCK"}', (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $supportRepo ($sourceRelative -replace '/', '\')), "COMMITTED_HELPER_SOURCE`n", (New-Object System.Text.UTF8Encoding($false)))

    & git -C $supportRepo init | Out-Null
    & git -C $supportRepo config user.email 'hms-ci@example.invalid'
    & git -C $supportRepo config user.name 'HMS Support Regression'
    & git -C $supportRepo config core.autocrlf false
    & git -C $supportRepo add .
    & git -C $supportRepo commit -m 'fixture: exact builder support and lock bytes' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit builder support regression fixture.' }

    # Public wrapper is the bootstrap trust root: hidden drift in the wrapper itself must stop before any build.
    & git -C $supportRepo update-index --skip-worktree -- $builderRelative
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set skip-worktree on public builder fixture.' }
    $hiddenFlags.Add($builderRelative)
    Add-Content -LiteralPath (Join-Path $supportRepo ($builderRelative -replace '/', '\')) -Value '# HMS_HIDDEN_PUBLIC_BOOTSTRAP_DRIFT'
    $supportStatus = ((& git -C $supportRepo status --porcelain=v1 --untracked-files=all) -join "`n")
    if (-not [string]::IsNullOrWhiteSpace($supportStatus)) { throw "Public-bootstrap hidden-drift premise was not reproduced: $supportStatus" }
    $selfRejected = $false
    try {
        & (Join-Path $supportScripts 'Build-HmsCompositeSkill.ps1') -InstallRoot $supportRepo -OutputRoot (Join-Path $supportTemp 'self-reject') -SkillsRoot (Join-Path $supportTemp 'self-skills') -Hms $false -Superpowers $false -Taste $false -Impeccable $false
    }
    catch {
        if ($_.Exception.Message -match 'Public composite bootstrap bytes do not match HMS HEAD') { $selfRejected = $true } else { throw }
    }
    if (-not $selfRejected) { throw 'Hidden public-builder drift was not rejected by exact self-blob identity.' }
    & git -C $supportRepo update-index --no-skip-worktree -- $builderRelative
    $hiddenFlags.Remove($builderRelative) | Out-Null
    & git -C $supportRepo restore --worktree -- $builderRelative
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restore public builder after self-drift regression.' }

    # Implementation/helper/lock worktree bytes are hidden and malicious; build must still use committed HEAD blobs.
    foreach ($relative in @($supportRelative,$helperRelative,$superLockRelative,$uiLockRelative)) {
        & git -C $supportRepo update-index --skip-worktree -- $relative
        if ($LASTEXITCODE -ne 0) { throw "Failed to set skip-worktree on support fixture: $relative" }
        $hiddenFlags.Add($relative)
    }
    [IO.File]::WriteAllText((Join-Path $supportRepo ($supportRelative -replace '/', '\')), "throw 'HMS_HIDDEN_SUPPORT_DRIFT_EXECUTED'`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $supportRepo ($helperRelative -replace '/', '\')), "throw 'HMS_HIDDEN_HELPER_DRIFT_EXECUTED'`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $supportRepo $superLockRelative), '{"fixture":"HMS_HIDDEN_SUPER_LOCK_DRIFT"}', (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $supportRepo $uiLockRelative), '{"fixture":"HMS_HIDDEN_UI_LOCK_DRIFT"}', (New-Object System.Text.UTF8Encoding($false)))
    $supportStatus = ((& git -C $supportRepo status --porcelain=v1 --untracked-files=all) -join "`n")
    if (-not [string]::IsNullOrWhiteSpace($supportStatus)) { throw "Support/lock hidden-drift premise was not reproduced: $supportStatus" }

    $fixtureOutput = Join-Path $supportTemp 'out'
    & (Join-Path $supportScripts 'Build-HmsCompositeSkill.ps1') -InstallRoot $supportRepo -OutputRoot $fixtureOutput -SkillsRoot (Join-Path $supportTemp 'skills') -Hms $false -Superpowers $false -Taste $false -Impeccable $false
    $fixtureSkill = Join-Path $fixtureOutput 'hms-superpowers\SKILL.md'
    if (-not (Test-Path -LiteralPath $fixtureSkill)) { throw 'Committed support implementation was not executed successfully.' }
    $fixtureText = Get-Content -LiteralPath $fixtureSkill -Raw
    foreach ($forbidden in @('HMS_HIDDEN_SUPPORT_DRIFT_EXECUTED','HMS_HIDDEN_HELPER_DRIFT_EXECUTED','HMS_HIDDEN_SUPER_LOCK_DRIFT','HMS_HIDDEN_UI_LOCK_DRIFT')) {
        if ($fixtureText -match [regex]::Escape($forbidden)) { throw "Hidden live support/lock bytes reached committed execution: $forbidden" }
    }
    foreach ($required in @($canonicalAuthority,'COMMITTED_SUPER_LOCK','COMMITTED_UI_LOCK')) {
        if ($fixtureText -notmatch [regex]::Escape($required)) { throw "Synthetic committed support execution missed expected committed content: $required" }
    }
    $copiedFixture = Join-Path $fixtureOutput 'hms-superpowers\references\fixture-source\SKILL.md'
    if (-not (Test-Path -LiteralPath $copiedFixture)) { throw 'Committed helper did not materialize synthetic committed source.' }
    if ([IO.File]::ReadAllText($copiedFixture) -cne "COMMITTED_HELPER_SOURCE`n") { throw 'Committed helper output did not match committed synthetic source bytes.' }
}
finally {
    if (Test-Path -LiteralPath $supportRepo) {
        foreach ($relative in @($hiddenFlags)) { & git -C $supportRepo update-index --no-skip-worktree -- $relative 2>$null }
    }
    if (Test-Path -LiteralPath $supportTemp) { Remove-Item -LiteralPath $supportTemp -Recurse -Force -ErrorAction SilentlyContinue }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hms-skip-worktree-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $tempRoot 'repo'
$skill = Join-Path $repo 'skills\test-skill'
$relativeSkill = 'skills/test-skill/SKILL.md'
$destination = Join-Path $tempRoot 'published\test-skill'
$attributeDestination = Join-Path $tempRoot 'published-attribute\test-skill'
$skipFlagSet = $false
try {
    New-Item -ItemType Directory -Force -Path $skill | Out-Null
    & git -C $repo init | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize skip-worktree regression repository.' }
    & git -C $repo config user.email 'hms-ci@example.invalid'
    & git -C $repo config user.name 'HMS Trust Regression'
    & git -C $repo config core.autocrlf false
    if ($LASTEXITCODE -ne 0) { throw 'Failed to configure skip-worktree regression repository.' }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $committedText = (@('---','name: test-skill','description: committed source fixture','---','','# committed bytes','$Format:%H$','') -join "`n")
    $skillPath = Join-Path $skill 'SKILL.md'
    [IO.File]::WriteAllText($skillPath, $committedText, $utf8NoBom)
    & git -C $repo add -- $relativeSkill
    if ($LASTEXITCODE -ne 0) { throw 'Failed to stage skip-worktree regression fixture.' }
    & git -C $repo commit -m 'fixture: committed skill bytes' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit skip-worktree regression fixture.' }

    $committedBlob = ((& git -C $repo rev-parse "HEAD:$relativeSkill") -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $committedBlob -notmatch '^[0-9a-f]{40}$') { throw 'Failed to resolve committed fixture blob identity.' }

    & git -C $repo update-index --skip-worktree -- $relativeSkill
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set skip-worktree on regression fixture.' }
    $skipFlagSet = $true
    $indexFlag = ((& git -C $repo ls-files -v -- $relativeSkill) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $indexFlag -notmatch '^S\s') { throw "skip-worktree flag was not proven on fixture: $indexFlag" }

    $sentinel = 'HMS_SKIP_WORKTREE_UNREVIEWED_SENTINEL'
    [IO.File]::WriteAllText($skillPath, ($committedText + $sentinel + "`n"), $utf8NoBom)
    $ordinaryStatus = ((& git -C $repo status --porcelain=v1 --untracked-files=all) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw 'Ordinary Git status failed during skip-worktree regression.' }
    if (-not [string]::IsNullOrWhiteSpace($ordinaryStatus)) { throw "skip-worktree regression did not reproduce the hidden-drift premise: $ordinaryStatus" }

    & $copyHelperPath -Source $skill -Destination $destination
    $publishedPath = Join-Path $destination 'SKILL.md'
    if (-not (Test-Path -LiteralPath $publishedPath)) { throw 'Raw-blob helper did not publish the expected SKILL.md.' }
    $published = [IO.File]::ReadAllText($publishedPath)
    if ($published -cne $committedText) { throw 'Raw-blob helper output differs from committed fixture bytes.' }
    if ($published -match [regex]::Escape($sentinel)) { throw 'skip-worktree worktree bytes leaked into raw-blob output.' }
    $publishedBlob = ((& git -C $repo hash-object --no-filters -- $publishedPath) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $publishedBlob -cne $committedBlob) { throw "Published bytes are not the committed Git blob. Expected $committedBlob, found $publishedBlob." }

    # Repository-local archive attributes must be irrelevant because the helper reads raw blob objects directly.
    $infoAttributes = Join-Path $repo '.git\info\attributes'
    $hadInfoAttributes = Test-Path -LiteralPath $infoAttributes
    $originalInfoAttributes = if ($hadInfoAttributes) { [IO.File]::ReadAllText($infoAttributes) } else { $null }
    try {
        [IO.File]::WriteAllText($infoAttributes, "skills/test-skill/SKILL.md export-subst export-ignore`n", $utf8NoBom)
        & $copyHelperPath -Source $skill -Destination $attributeDestination
        $attributePath = Join-Path $attributeDestination 'SKILL.md'
        if (-not (Test-Path -LiteralPath $attributePath)) { throw 'Raw-blob helper was incorrectly affected by export-ignore.' }
        $attributeText = [IO.File]::ReadAllText($attributePath)
        if ($attributeText -cne $committedText) { throw 'Repository-local export attributes transformed raw committed bytes.' }
        if ($attributeText -notmatch [regex]::Escape('$Format:%H$')) { throw 'export-subst altered literal committed content.' }
        $attributeBlob = ((& git -C $repo hash-object --no-filters -- $attributePath) -join '').Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $attributeBlob -cne $committedBlob) { throw 'Raw-blob materialization under archive attributes no longer matches committed blob identity.' }
    }
    finally {
        if ($hadInfoAttributes) { [IO.File]::WriteAllText($infoAttributes, $originalInfoAttributes, $utf8NoBom) }
        else { Remove-Item -LiteralPath $infoAttributes -Force -ErrorAction SilentlyContinue }
    }

    if ([IO.File]::ReadAllText($skillPath) -notmatch [regex]::Escape($sentinel)) { throw 'Raw-blob helper mutated the adversarial source worktree.' }
}
finally {
    if ($skipFlagSet -and (Test-Path -LiteralPath $repo)) { & git -C $repo update-index --no-skip-worktree -- $relativeSkill 2>$null }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host 'PASS: public builder hidden drift is rejected; implementation/helper/lock support executes from exact HMS HEAD blobs; binary cat-file source materialization defeats skip-worktree and archive/filter transformations; lifecycle scripts reject hidden index state; generated authority precedence is enforced.'
