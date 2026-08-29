[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$SkipSuperpowers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
$CanonicalSuperpowersRemote = 'https://github.com/obra/superpowers.git'
$SkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$HmsLink = Join-Path $SkillsRoot 'hms'
$SuperpowersRoot = Join-Path $env:USERPROFILE '.codex\superpowers'
$SuperpowersLink = Join-Path $SkillsRoot 'superpowers'

function Assert-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git.exe is required but was not found in PATH.'
    }
}

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

function Get-CurrentBranch {
    param([Parameter(Mandatory)][string]$Path)
    $branch = & git -C $Path symbolic-ref --quiet --short HEAD
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) { return $branch.Trim() }
    if ($exitCode -eq 1) { return $null }
    throw "git symbolic-ref failed for $Path with exit code $exitCode"
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
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
        $dirty = & git -C $Path status --porcelain
        if ($LASTEXITCODE -ne 0) { throw "git status failed for $Path" }
        if ($dirty) { throw "Refusing to update dirty repository: $Path" }

        $branch = Get-CurrentBranch -Path $Path
        if ($null -ne $branch) {
            $sourceRef = "refs/heads/$branch"
            $remoteRef = "refs/remotes/origin/$branch"
            & git -C $Path fetch --prune $Remote "${sourceRef}:${remoteRef}"
            if ($LASTEXITCODE -ne 0) { throw "git fetch from verified origin failed for $Path branch $branch" }
            & git -C $Path merge --ff-only $remoteRef
            if ($LASTEXITCODE -ne 0) { throw "git merge --ff-only failed for $Path from $remoteRef" }
        }
        else {
            $detachedHead = (& git -C $Path rev-parse HEAD).Trim()
            if ($LASTEXITCODE -ne 0 -or $detachedHead -notmatch '^[0-9a-fA-F]{40}$') {
                throw "Unable to prove detached HEAD identity for $Path"
            }
            Write-Verbose "Preserving detached HMS candidate at $detachedHead without mutable ref synchronization."
        }
    }
    else {
        $parent = Split-Path -Parent $Path
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        & git clone $Remote $Path
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Remote" }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
    }
}

function Read-ValidatedSuperpowersLock {
    param([Parameter(Mandatory)][string]$LockPath)

    if (-not (Test-Path -LiteralPath $LockPath)) {
        throw "Superpowers lock file not found: $LockPath"
    }

    try {
        $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Superpowers lock file is not valid JSON: $($_.Exception.Message)"
    }

    $repository = [string]$lock.repository
    $version = [string]$lock.version
    $commit = [string]$lock.commit

    if ($repository -cne $CanonicalSuperpowersRemote) {
        throw "Unexpected Superpowers repository in lock: $repository"
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw 'Superpowers lock version is missing.'
    }
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "Superpowers lock commit is not a canonical lowercase SHA-1: $commit"
    }

    return [pscustomobject]@{
        Repository = $repository
        Version = $version
        Commit = $commit
    }
}

function Sync-PinnedRepository {
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Commit
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
            throw "Refusing to overwrite existing non-Git path: $Path"
        }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
        $dirty = & git -C $Path status --porcelain
        if ($LASTEXITCODE -ne 0) { throw "git status failed for $Path" }
        if ($dirty) { throw "Refusing to update dirty repository: $Path" }
    }
    else {
        $parent = Split-Path -Parent $Path
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        & git clone $Remote $Path
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Remote" }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
    }

    & git -C $Path fetch --tags --prune $Remote
    if ($LASTEXITCODE -ne 0) { throw "git fetch from verified pinned repository failed for $Path" }

    & git -C $Path cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw ('Pinned commit is unavailable in {0}: {1}' -f $Path, $Commit)
    }

    & git -C $Path checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned commit failed for $Path" }

    $actual = (& git -C $Path rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Commit) {
        throw "Pinned identity mismatch for $Path. Expected $Commit, found $actual"
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
Sync-Repository -Remote $HmsRemote -Path $InstallRoot

$superpowersLock = $null
if (-not $SkipSuperpowers) {
    $superpowersLock = Read-ValidatedSuperpowersLock -LockPath (Join-Path $InstallRoot 'superpowers.lock.json')
}

$validator = Join-Path $InstallRoot 'scripts\Test-HmsSkills.ps1'
& $validator

New-Item -ItemType Directory -Force -Path $SkillsRoot | Out-Null
Ensure-Junction -Link $HmsLink -Target (Join-Path $InstallRoot 'skills')

if (-not $SkipSuperpowers) {
    Sync-PinnedRepository -Remote $superpowersLock.Repository -Path $SuperpowersRoot -Commit $superpowersLock.Commit
    Ensure-Junction -Link $SuperpowersLink -Target (Join-Path $SuperpowersRoot 'skills')
}

Write-Host 'HMS Skills Codex installation PASS.'
Write-Host "HMS skills: $HmsLink"
if (-not $SkipSuperpowers) {
    Write-Host "Superpowers skills: $SuperpowersLink"
    Write-Host "Superpowers pin: $($superpowersLock.Commit)"
}
Write-Host 'Restart Codex to refresh skill discovery.'
