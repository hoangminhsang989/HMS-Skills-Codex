[CmdletBinding()]
param(
    [switch]$EnsureDiscovery,
    [switch]$EnableIfNew,
    [switch]$SkipTaste,
    [switch]$SkipImpeccable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($EnsureDiscovery -or $EnableIfNew) {
    throw 'Direct UI-advisor discovery is disabled by the unified-skill architecture. Reconcile source only, then rebuild $hms-superpowers.'
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockPath = Join-Path $RepoRoot 'ui-skills.lock.json'
$CanonicalTasteRemote = 'https://github.com/Leonxlnx/taste-skill.git'
$CanonicalImpeccableRemote = 'https://github.com/pbakaus/impeccable.git'

function ConvertTo-NormalizedRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    return $value.ToLowerInvariant()
}

function Assert-ExpectedOrigin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRemote
    )
    $origin = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) {
        throw "Unexpected Git origin for $Path. Expected '$ExpectedRemote', found '$($origin.Trim())'."
    }
}

function Read-ValidatedUiSkillsLock {
    if (-not (Test-Path -LiteralPath $LockPath)) { throw "UI skills lock file not found: $LockPath" }
    try { $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json }
    catch { throw "UI skills lock file is invalid JSON: $($_.Exception.Message)" }

    $contracts = @{
        taste = [pscustomobject]@{ Repository = $CanonicalTasteRemote; SkillName = 'gpt-taste'; SkillPath = 'skills/gpt-tasteskill' }
        impeccable = [pscustomobject]@{ Repository = $CanonicalImpeccableRemote; SkillName = 'impeccable'; SkillPath = '.agents/skills/impeccable' }
    }

    foreach ($key in @('taste', 'impeccable')) {
        $entry = $lock.$key
        $contract = $contracts[$key]
        if ($null -eq $entry) { throw "Missing '$key' entry in ui-skills.lock.json" }
        if ([string]$entry.repository -cne $contract.Repository) { throw "Unexpected $key repository in UI skills lock: $($entry.repository)" }
        if ([string]$entry.skill_name -cne $contract.SkillName) { throw "Unexpected $key skill name in UI skills lock: $($entry.skill_name)" }
        if ([string]$entry.skill_path -cne $contract.SkillPath) { throw "Unexpected $key skill path in UI skills lock: $($entry.skill_path)" }
        if ([string]$entry.commit -notmatch '^[0-9a-f]{40}$') { throw "Invalid $key pinned commit: $($entry.commit)" }
    }
    return $lock
}

function Sync-PinnedRepository {
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Commit
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Refusing to overwrite existing non-Git path: $Path" }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
        $dirty = & git -C $Path status --porcelain
        if ($LASTEXITCODE -ne 0) { throw "git status failed for $Path" }
        if ($dirty) { throw "Refusing to reconcile dirty pinned repository: $Path" }
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        & git clone $Remote $Path
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Remote" }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
    }

    & git -C $Path fetch --tags --prune $Remote
    if ($LASTEXITCODE -ne 0) { throw "git fetch from verified pinned repository failed for $Path" }
    & git -C $Path cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Pinned commit is unavailable in $Path : $Commit" }
    & git -C $Path checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned commit failed for $Path" }

    $actual = (& git -C $Path rev-parse HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Commit) { throw "Pinned identity mismatch for $Path. Expected $Commit, found $actual" }
}

function Assert-SkillEntryPoint {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$SkillPath,
        [Parameter(Mandatory)][string]$ExpectedName
    )

    $skillFile = Join-Path (Join-Path $RepoPath $SkillPath) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile)) { throw "Pinned skill entry point not found: $skillFile" }
    $text = Get-Content -LiteralPath $skillFile -Raw
    $match = [regex]::Match($text, '(?m)^name:\s*([^\r\n]+?)\s*$')
    if (-not $match.Success -or $match.Groups[1].Value.Trim() -cne $ExpectedName) {
        throw "Pinned skill name mismatch at $skillFile. Expected '$ExpectedName'."
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git.exe is required but was not found in PATH.' }
$lock = Read-ValidatedUiSkillsLock

$specs = @()
if (-not $SkipTaste) {
    $specs += [pscustomobject]@{
        Name = 'GPT Taste'
        Root = (Join-Path $env:USERPROFILE '.codex\taste-skill')
        Repository = [string]$lock.taste.repository
        Commit = [string]$lock.taste.commit
        SkillPath = [string]$lock.taste.skill_path
        SkillName = [string]$lock.taste.skill_name
    }
}
if (-not $SkipImpeccable) {
    $specs += [pscustomobject]@{
        Name = 'Impeccable'
        Root = (Join-Path $env:USERPROFILE '.codex\impeccable')
        Repository = [string]$lock.impeccable.repository
        Commit = [string]$lock.impeccable.commit
        SkillPath = [string]$lock.impeccable.skill_path
        SkillName = [string]$lock.impeccable.skill_name
    }
}

foreach ($spec in $specs) {
    Sync-PinnedRepository -Remote $spec.Repository -Path $spec.Root -Commit $spec.Commit
    Assert-SkillEntryPoint -RepoPath $spec.Root -SkillPath $spec.SkillPath -ExpectedName $spec.SkillName
    Write-Host "$($spec.Name) pin: $($spec.Commit)"
}

Write-Host 'Pinned UI skill sources reconciliation PASS. Direct discovery remains disabled; use the HMS composite compiler.'
