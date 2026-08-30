[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$builderPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.ps1'
$builderImplPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.impl.ps1'
$copyHelperPath = Join-Path $RepoRoot 'scripts\Copy-HmsCommittedGitPath.ps1'
foreach ($path in @($builderPath,$builderImplPath,$copyHelperPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Trust-remediation support file is missing: $path" }
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -ne 0) {
        throw "PowerShell parser rejected trust-remediation file '$path': $((@($parseErrors) | ForEach-Object { $_.Message }) -join ' | ')"
    }
}

$builderText = Get-Content -LiteralPath $builderPath -Raw
$helperText = Get-Content -LiteralPath $copyHelperPath -Raw
$canonicalAuthority = 'Authority precedence is fixed, highest to lowest: Owner instruction > latest valid HMS checkpoint / frozen authority > HMS fail-closed + safety rules > HMS model risk floor + dedicated model dispatcher > HMS project-specific product / UI authority > explicitly requested Three-Level Delivery governance > enabled Superpowers engineering method > CodeGraph context/evidence + enabled UI advisors > Codex defaults.'
$badAuthority = 'Owner instruction and current project authority always outrank every internal module.'
foreach ($literal in @(
    'Copy-HmsCommittedGitPath.ps1',
    'support file does not match exact HEAD blob',
    $canonicalAuthority,
    'Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.',
    'Generated composite omitted the canonical HMS authority precedence.'
)) {
    if ($builderText -notmatch [regex]::Escape($literal)) { throw "Builder trust wrapper is missing required contract literal: $literal" }
}
foreach ($literal in @(
    'Assert-MaterializedFilesMatchHead',
    'Archive attributes/filters must not transform committed bytes.',
    'hash-object --no-filters'
)) {
    if ($helperText -notmatch [regex]::Escape($literal)) { throw "Committed-copy helper is missing required exact-blob contract literal: $literal" }
}
if ($builderText -match [regex]::Escape("'$badAuthority'")) {
    throw 'Builder trust wrapper retained the superseded generated authority rule.'
}

# Trust-root regression: hidden drift in builder support bytes must be rejected before support execution.
$supportTemp = Join-Path ([IO.Path]::GetTempPath()) ('hms-support-bind-' + [guid]::NewGuid().ToString('N'))
$supportRepo = Join-Path $supportTemp 'repo'
$supportScripts = Join-Path $supportRepo 'scripts'
$supportRelative = 'scripts/Build-HmsCompositeSkill.impl.ps1'
$supportFlagSet = $false
try {
    New-Item -ItemType Directory -Force -Path $supportScripts | Out-Null
    Copy-Item -LiteralPath $builderPath -Destination (Join-Path $supportScripts 'Build-HmsCompositeSkill.ps1') -Force
    Copy-Item -LiteralPath $builderImplPath -Destination (Join-Path $supportScripts 'Build-HmsCompositeSkill.impl.ps1') -Force
    Copy-Item -LiteralPath $copyHelperPath -Destination (Join-Path $supportScripts 'Copy-HmsCommittedGitPath.ps1') -Force
    & git -C $supportRepo init | Out-Null
    & git -C $supportRepo config user.email 'hms-ci@example.invalid'
    & git -C $supportRepo config user.name 'HMS Support Regression'
    & git -C $supportRepo add scripts
    & git -C $supportRepo commit -m 'fixture: exact builder support bytes' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit builder support regression fixture.' }

    & git -C $supportRepo update-index --skip-worktree -- $supportRelative
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set skip-worktree on builder implementation fixture.' }
    $supportFlagSet = $true
    Add-Content -LiteralPath (Join-Path $supportRepo ($supportRelative -replace '/', '\')) -Value "`n# HMS_HIDDEN_SUPPORT_DRIFT"
    $supportStatus = ((& git -C $supportRepo status --porcelain=v1 --untracked-files=all) -join "`n")
    if (-not [string]::IsNullOrWhiteSpace($supportStatus)) { throw "Support hidden-drift premise was not reproduced: $supportStatus" }

    $supportRejected = $false
    try {
        & (Join-Path $supportScripts 'Build-HmsCompositeSkill.ps1') -InstallRoot $supportRepo -OutputRoot (Join-Path $supportTemp 'out') -SkillsRoot (Join-Path $supportTemp 'skills') -Hms $false -Superpowers $false -Taste $false -Impeccable $false
    }
    catch {
        if ($_.Exception.Message -match 'Composite implementation support file does not match exact HEAD blob') { $supportRejected = $true } else { throw }
    }
    if (-not $supportRejected) { throw 'Builder accepted hidden drift in its implementation support file.' }
}
finally {
    if ($supportFlagSet -and (Test-Path -LiteralPath $supportRepo)) {
        & git -C $supportRepo update-index --no-skip-worktree -- $supportRelative 2>$null
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
    if (-not [string]::IsNullOrWhiteSpace($ordinaryStatus)) {
        throw "skip-worktree regression did not reproduce the hidden-drift premise: $ordinaryStatus"
    }
    if ([IO.File]::ReadAllText($skillPath) -notmatch [regex]::Escape($sentinel)) {
        throw 'Live worktree sentinel disappeared before committed-object copy.'
    }

    & $copyHelperPath -Source $skill -Destination $destination
    $publishedPath = Join-Path $destination 'SKILL.md'
    if (-not (Test-Path -LiteralPath $publishedPath)) { throw 'Committed-object helper did not publish the expected SKILL.md.' }
    $published = [IO.File]::ReadAllText($publishedPath)
    if ($published -cne $committedText) {
        throw 'Committed-object helper output differs from the committed fixture bytes.'
    }
    if ($published -match [regex]::Escape($sentinel)) {
        throw 'skip-worktree worktree bytes leaked into committed-object output.'
    }
    $publishedBlob = ((& git -C $repo hash-object --no-filters -- $publishedPath) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $publishedBlob -cne $committedBlob) {
        throw "Published bytes are not the committed Git blob. Expected $committedBlob, found $publishedBlob."
    }

    # git archive consults repository-local info/attributes. export-subst must not silently transform committed bytes.
    $infoAttributes = Join-Path $repo '.git\info\attributes'
    $hadInfoAttributes = Test-Path -LiteralPath $infoAttributes
    $originalInfoAttributes = if ($hadInfoAttributes) { [IO.File]::ReadAllText($infoAttributes) } else { $null }
    try {
        [IO.File]::WriteAllText($infoAttributes, "skills/test-skill/SKILL.md export-subst`n", $utf8NoBom)
        $attributeRejected = $false
        try { & $copyHelperPath -Source $skill -Destination $attributeDestination }
        catch {
            if ($_.Exception.Message -match 'materialized blob mismatch') { $attributeRejected = $true } else { throw }
        }
        if (-not $attributeRejected) { throw 'Committed-copy helper accepted git-archive export-subst byte transformation.' }
        if (Test-Path -LiteralPath $attributeDestination) { throw 'Archive-attribute rejection published a destination.' }
    }
    finally {
        if ($hadInfoAttributes) { [IO.File]::WriteAllText($infoAttributes, $originalInfoAttributes, $utf8NoBom) }
        else { Remove-Item -LiteralPath $infoAttributes -Force -ErrorAction SilentlyContinue }
    }

    if ([IO.File]::ReadAllText($skillPath) -notmatch [regex]::Escape($sentinel)) {
        throw 'Committed-object helper mutated the adversarial source worktree.'
    }
}
finally {
    if ($skipFlagSet -and (Test-Path -LiteralPath $repo)) {
        & git -C $repo update-index --no-skip-worktree -- $relativeSkill 2>$null
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host 'PASS: builder support bytes are HEAD-blob-bound; committed Git-object copy defeats skip-worktree and rejects archive-attribute byte transformation; generated authority precedence is enforced.'
