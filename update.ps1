[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$SkipSuperpowers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'

function Assert-ExpectedOrigin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRemote
    )

    $origin = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ($origin.Trim().TrimEnd('/') -ne $ExpectedRemote.Trim().TrimEnd('/')) {
        throw "Unexpected Git origin for $Path. Expected '$ExpectedRemote', found '$($origin.Trim())'."
    }
}

function Update-CleanRepo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRemote
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        throw "Git repository not found: $Path"
    }
    Assert-ExpectedOrigin -Path $Path -ExpectedRemote $ExpectedRemote
    $dirty = & git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "git status failed for $Path" }
    if ($dirty) { throw "Refusing to update dirty repository: $Path" }
    & git -C $Path pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed for $Path" }
}

function Sync-PinnedRepo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Remote,
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

    & git -C $Path fetch --tags --prune origin
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed for $Path" }
    & git -C $Path cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Pinned commit is unavailable in $Path: $Commit" }
    & git -C $Path checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned commit failed for $Path" }

    $actual = (& git -C $Path rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $Commit) {
        throw "Pinned identity mismatch for $Path. Expected $Commit, found $actual"
    }
}

Update-CleanRepo -Path $InstallRoot -ExpectedRemote $HmsRemote

if (-not $SkipSuperpowers) {
    $lockPath = Join-Path $InstallRoot 'superpowers.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath)) { throw "Superpowers lock file not found: $lockPath" }
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $remote = [string]$lock.repository
    $commit = ([string]$lock.commit).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($remote) -or $commit -notmatch '^[0-9a-f]{40}$') {
        throw 'Superpowers lock file is invalid.'
    }
    Sync-PinnedRepo -Path (Join-Path $env:USERPROFILE '.codex\superpowers') -Remote $remote -Commit $commit
}

& (Join-Path $InstallRoot 'scripts\Test-HmsSkills.ps1')

Write-Host 'HMS Skills Codex update PASS.'
if (-not $SkipSuperpowers) { Write-Host "Superpowers pin: $commit" }
Write-Host 'Restart Codex if the running session does not refresh skill metadata automatically.'
