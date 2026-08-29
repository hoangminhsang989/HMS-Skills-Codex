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
    if (-not $frontmatterMatch.Success) {
        $errors.Add("Missing YAML frontmatter: $($file.FullName)")
        continue
    }

    $frontmatter = $frontmatterMatch.Groups[1].Value
    $nameMatch = [regex]::Match($frontmatter, '(?m)^name:\s*([a-z0-9-]+)\s*$')
    $descMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(.+?)\s*$')

    if (-not $nameMatch.Success) {
        $errors.Add("Missing/invalid name: $($file.FullName)")
        continue
    }
    if (-not $descMatch.Success) {
        $errors.Add("Missing description: $($file.FullName)")
    }

    $name = $nameMatch.Groups[1].Value
    $folder = Split-Path -Leaf $file.DirectoryName
    if ($name -ne $folder) {
        $errors.Add("Skill name '$name' does not match folder '$folder': $($file.FullName)")
    }
    if ($names.ContainsKey($name)) {
        $errors.Add("Duplicate skill name '$name': $($file.FullName)")
    }
    else {
        $names[$name] = $file.FullName
    }

    if ($frontmatter.Length -gt 1024) {
        $errors.Add("Frontmatter exceeds 1024 characters: $($file.FullName)")
    }
}

$required = @(
    'hms-superpowers',
    'hms-authority-loader',
    'hms-authority-gate',
    'hms-scope-lock',
    'hms-model-router',
    'hms-isolated-execution',
    'hms-evidence-gate',
    'hms-independent-review',
    'hms-fail-closed',
    'hms-release-gate',
    'hms-handoff'
)

foreach ($requiredName in $required) {
    if (-not $names.ContainsKey($requiredName)) {
        $errors.Add("Required skill missing: $requiredName")
    }
}

$metadataPath = Join-Path $skillsRoot 'hms-superpowers\agents\openai.yaml'
if (-not (Test-Path -LiteralPath $metadataPath)) {
    $errors.Add('Codex metadata missing for hms-superpowers: skills/hms-superpowers/agents/openai.yaml')
}

$lockPath = Join-Path $RepoRoot 'superpowers.lock.json'
if (-not (Test-Path -LiteralPath $lockPath)) {
    $errors.Add('Missing superpowers.lock.json')
}
else {
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $repository = [string]$lock.repository
        $version = [string]$lock.version
        $commit = [string]$lock.commit
        if ($repository -ne 'https://github.com/obra/superpowers.git') {
            $errors.Add("Unexpected Superpowers repository in lock: $repository")
        }
        if ([string]::IsNullOrWhiteSpace($version)) {
            $errors.Add('Superpowers lock version is missing.')
        }
        if ($commit -notmatch '^[0-9a-f]{40}$') {
            $errors.Add("Superpowers lock commit is not a canonical lowercase SHA-1: $commit")
        }
    }
    catch {
        $errors.Add("Invalid superpowers.lock.json: $($_.Exception.Message)")
    }
}

if ($errors.Count -gt 0) {
    $message = "HMS skill validation failed:`n - " + ($errors -join "`n - ")
    throw $message
}

Write-Host "PASS: validated $($skillFiles.Count) HMS skills and the pinned Superpowers authority."
