[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$SkipSuperpowers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
$SuperpowersRemote = 'https://github.com/obra/superpowers.git'
$SkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$HmsLink = Join-Path $SkillsRoot 'hms'
$SuperpowersRoot = Join-Path $env:USERPROFILE '.codex\superpowers'
$SuperpowersLink = Join-Path $SkillsRoot 'superpowers'

function Assert-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git.exe is required but was not found in PATH.'
    }
}

function Sync-Repository {
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
            throw "Refusing to overwrite existing non-Git path: $Path"
        }
        $dirty = & git -C $Path status --porcelain
        if ($LASTEXITCODE -ne 0) { throw "git status failed for $Path" }
        if ($dirty) { throw "Refusing to update dirty repository: $Path" }
        & git -C $Path pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed for $Path" }
    }
    else {
        $parent = Split-Path -Parent $Path
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        & git clone $Remote $Path
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Remote" }
    }
}

function Ensure-Junction {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Junction target does not exist: $Target"
    }

    if (Test-Path -LiteralPath $Link) {
        $item = Get-Item -LiteralPath $Link -Force
        $targets = @($item.Target)
        $resolvedTarget = (Resolve-Path -LiteralPath $Target).Path
        $same = $false
        foreach ($candidate in $targets) {
            if ($candidate) {
                try {
                    if ((Resolve-Path -LiteralPath $candidate).Path -eq $resolvedTarget) { $same = $true }
                } catch { }
            }
        }
        if ($same) { return }
        throw "Refusing to replace existing path with a different target: $Link"
    }

    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
}

Assert-Git
New-Item -ItemType Directory -Force -Path $SkillsRoot | Out-Null
Sync-Repository -Remote $HmsRemote -Path $InstallRoot
Ensure-Junction -Link $HmsLink -Target (Join-Path $InstallRoot 'skills')

if (-not $SkipSuperpowers) {
    Sync-Repository -Remote $SuperpowersRemote -Path $SuperpowersRoot
    Ensure-Junction -Link $SuperpowersLink -Target (Join-Path $SuperpowersRoot 'skills')
}

$validator = Join-Path $InstallRoot 'scripts\Test-HmsSkills.ps1'
& $validator

Write-Host 'HMS Skills Codex installation PASS.'
Write-Host "HMS skills: $HmsLink"
if (-not $SkipSuperpowers) { Write-Host "Superpowers skills: $SuperpowersLink" }
Write-Host 'Restart Codex to refresh skill discovery.'
