[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillsRoot = Join-Path $RepoRoot 'skills'
if (-not (Test-Path -LiteralPath $skillsRoot)) { throw "Skills directory not found: $skillsRoot" }

$skillFiles = @(Get-ChildItem -LiteralPath $skillsRoot -Filter 'SKILL.md' -File -Recurse)
if ($skillFiles.Count -eq 0) { throw 'No SKILL.md files found.' }

$names = @{}
$errors = [System.Collections.Generic.List[string]]::new()
foreach ($file in $skillFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $frontmatterMatch = [regex]::Match($text, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n')
    if (-not $frontmatterMatch.Success) { $errors.Add("Missing YAML frontmatter: $($file.FullName)"); continue }
    $frontmatter = $frontmatterMatch.Groups[1].Value
    $nameMatch = [regex]::Match($frontmatter, '(?m)^name:\s*([a-z0-9-]+)\s*$')
    $descMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(.+?)\s*$')
    if (-not $nameMatch.Success) { $errors.Add("Missing/invalid name: $($file.FullName)"); continue }
    if (-not $descMatch.Success) { $errors.Add("Missing description: $($file.FullName)") }
    $name = $nameMatch.Groups[1].Value
    $folder = Split-Path -Leaf $file.DirectoryName
    if ($name -ne $folder) { $errors.Add("Skill name '$name' does not match folder '$folder': $($file.FullName)") }
    if ($names.ContainsKey($name)) { $errors.Add("Duplicate skill name '$name': $($file.FullName)") } else { $names[$name] = $file.FullName }
    if ($frontmatter.Length -gt 1024) { $errors.Add("Frontmatter exceeds 1024 characters: $($file.FullName)") }
}

$required = @(
    'hms-superpowers',
    'hms-authority-loader',
    'hms-authority-gate',
    'hms-scope-lock',
    'hms-model-router',
    'hms-model-dispatcher',
    'hms-isolated-execution',
    'hms-evidence-gate',
    'hms-independent-review',
    'hms-fail-closed',
    'hms-release-gate',
    'hms-handoff',
    'hms-ui-design-authority'
)
foreach ($requiredName in $required) { if (-not $names.ContainsKey($requiredName)) { $errors.Add("Required skill missing: $requiredName") } }

foreach ($skillName in @('hms-superpowers','hms-ui-design-authority')) {
    $metadataPath = Join-Path $skillsRoot "$skillName\agents\openai.yaml"
    if (-not (Test-Path -LiteralPath $metadataPath)) { $errors.Add("Codex metadata missing for ${skillName}: skills/$skillName/agents/openai.yaml") }
}

$architecturePath = Join-Path $RepoRoot 'docs\UNIFIED_SKILL_ARCHITECTURE.md'
if (-not (Test-Path -LiteralPath $architecturePath)) { $errors.Add('Missing docs/UNIFIED_SKILL_ARCHITECTURE.md') }

$modelDispatcherPath = Join-Path $skillsRoot 'hms-model-dispatcher\SKILL.md'
if (Test-Path -LiteralPath $modelDispatcherPath) {
    $modelDispatcherText = Get-Content -LiteralPath $modelDispatcherPath -Raw
    foreach ($literal in @(
        'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR',
        'Luna OFF: Luna-class work may move to Terra, then Sol.',
        'Terra OFF: Terra-class work may move to Sol.',
        'Sol OFF: Sol-required work has no lower safe substitute'
    )) {
        if ($modelDispatcherText -notmatch [regex]::Escape($literal)) { $errors.Add("Model dispatcher contract missing literal: $literal") }
    }
}

$modelLauncherPath = Join-Path $RepoRoot 'HMS-Model-Settings.cmd'
if (-not (Test-Path -LiteralPath $modelLauncherPath)) { $errors.Add('Missing HMS-Model-Settings.cmd launcher.') }

$lockPath = Join-Path $RepoRoot 'superpowers.lock.json'
if (-not (Test-Path -LiteralPath $lockPath)) { $errors.Add('Missing superpowers.lock.json') }
else {
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        if ([string]$lock.repository -cne 'https://github.com/obra/superpowers.git') { $errors.Add("Unexpected Superpowers repository in lock: $($lock.repository)") }
        if ([string]::IsNullOrWhiteSpace([string]$lock.version)) { $errors.Add('Superpowers lock version is missing.') }
        if ([string]$lock.commit -notmatch '^[0-9a-f]{40}$') { $errors.Add("Superpowers lock commit is invalid: $($lock.commit)") }
    }
    catch { $errors.Add("Invalid superpowers.lock.json: $($_.Exception.Message)") }
}

$uiLockPath = Join-Path $RepoRoot 'ui-skills.lock.json'
if (-not (Test-Path -LiteralPath $uiLockPath)) { $errors.Add('Missing ui-skills.lock.json') }
else {
    try {
        $uiLock = Get-Content -LiteralPath $uiLockPath -Raw | ConvertFrom-Json
        $contracts = @{
            taste = [pscustomobject]@{ Repository='https://github.com/Leonxlnx/taste-skill.git'; SkillName='gpt-taste'; SkillPath='skills/gpt-tasteskill'; DiscoveryName='taste-skill:gpt-taste' }
            impeccable = [pscustomobject]@{ Repository='https://github.com/pbakaus/impeccable.git'; SkillName='impeccable'; SkillPath='.agents/skills/impeccable'; DiscoveryName='impeccable:impeccable' }
        }
        foreach ($key in @('taste','impeccable')) {
            $entry = $uiLock.$key; $contract = $contracts[$key]
            if ($null -eq $entry) { $errors.Add("Missing '$key' entry in ui-skills.lock.json"); continue }
            if ([string]$entry.repository -cne $contract.Repository) { $errors.Add("Unexpected $key repository in UI skills lock: $($entry.repository)") }
            if ([string]$entry.skill_name -cne $contract.SkillName) { $errors.Add("Unexpected $key skill name in UI skills lock: $($entry.skill_name)") }
            if ([string]$entry.skill_path -cne $contract.SkillPath) { $errors.Add("Unexpected $key skill path in UI skills lock: $($entry.skill_path)") }
            if ([string]$entry.codex_discovery_name -cne $contract.DiscoveryName) { $errors.Add("Unexpected $key source discovery identity in UI skills lock: $($entry.codex_discovery_name)") }
            if ([string]$entry.commit -notmatch '^[0-9a-f]{40}$') { $errors.Add("Invalid $key pinned commit in UI skills lock: $($entry.commit)") }
        }
    }
    catch { $errors.Add("Invalid ui-skills.lock.json: $($_.Exception.Message)") }
}

$powerShellScripts = @(
    (Join-Path $RepoRoot 'install.ps1'),
    (Join-Path $RepoRoot 'update.ps1'),
    (Join-Path $RepoRoot 'uninstall.ps1'),
    (Join-Path $RepoRoot 'manager\HmsSuperpowersManager.ps1'),
    (Join-Path $RepoRoot 'manager\HmsSuperpowersManager.utf8.ps1'),
    (Join-Path $RepoRoot 'manager\HmsModelSettings.ps1'),
    (Join-Path $RepoRoot 'manager\HmsModelSettings.utf8.ps1'),
    (Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.ps1'),
    (Join-Path $RepoRoot 'scripts\Resolve-HmsModelRoute.ps1'),
    (Join-Path $RepoRoot 'scripts\Sync-UiSkills.ps1'),
    (Join-Path $RepoRoot 'scripts\Test-CodexSkillDiscovery.ps1')
)
foreach ($scriptPath in $powerShellScripts) {
    if (-not (Test-Path -LiteralPath $scriptPath)) { $errors.Add("Required PowerShell script missing: $scriptPath"); continue }
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in @($parseErrors)) { $errors.Add(("PowerShell parser error in {0} at line {1}, column {2}: {3}" -f $scriptPath,$parseError.Extent.StartLineNumber,$parseError.Extent.StartColumnNumber,$parseError.Message)) }
}

if ($errors.Count -gt 0) { throw ("HMS skill validation failed:`n - " + ($errors -join "`n - ")) }
Write-Host "PASS: validated $($skillFiles.Count) source skills, unified composite architecture, dedicated model dispatcher/settings, PowerShell syntax, and pinned external source contracts."
