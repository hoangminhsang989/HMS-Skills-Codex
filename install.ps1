[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$SkipSuperpowers,
    [switch]$SkipTaste,
    [switch]$SkipImpeccable,
    [switch]$SkipCodeGraph,
    [switch]$SkipThreeLevelDelivery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
$CanonicalSuperpowersRemote = 'https://github.com/obra/superpowers.git'
$SuperpowersRoot = Join-Path $env:USERPROFILE '.codex\superpowers'
$CompositeRoot = Join-Path $env:USERPROFILE '.codex\hms-composite\hms-superpowers'
$CompositeManifest = Join-Path $CompositeRoot 'manifest.json'
$SkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$BuildMutexName = 'Local\HMS-Skills-Codex-CompositeBuild-v1'

function Assert-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git.exe is required but was not found in PATH.' }
}

function ConvertTo-NormalizedRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring(0, $value.Length - 4) }
    return $value.ToLowerInvariant()
}

function Assert-ExpectedOrigin {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedRemote)
    $origin = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) {
        throw "Unexpected Git origin for $Path. Expected '$ExpectedRemote', found '$($origin.Trim())'."
    }
}

function Assert-NoHiddenIndexState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return }
    $lines = @(& git -C $Path ls-files -v 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect Git index flags for $Path" }
    $hidden = @($lines | Where-Object {
        $text = [string]$_
        $text -match '^S ' -or $text -cmatch '^[a-z] '
    })
    if ($hidden.Count -ne 0) {
        $sample = (($hidden | Select-Object -First 8) -join '; ')
        throw "HMS tracked files use skip-worktree/assume-unchanged index flags; refusing lifecycle mutation because live trust inputs may be hidden: $sample"
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

function Assert-BranchMatchesFetchedRef {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$RemoteRef)
    $localHead = (& git -C $Path rev-parse HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD failed for $Path" }
    $fetchedHead = (& git -C $Path rev-parse $RemoteRef).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse failed for fetched ref $RemoteRef in $Path" }
    if ($localHead -notmatch '^[0-9a-f]{40}$' -or $fetchedHead -notmatch '^[0-9a-f]{40}$') { throw "Unable to prove canonical branch identities for $Path" }
    if ($localHead -ne $fetchedHead) { throw "HMS branch identity mismatch for $Path. Local HEAD $localHead does not equal verified fetched ref $RemoteRef at $fetchedHead." }
}

function Sync-Repository {
    param([Parameter(Mandatory)][string]$Remote,[Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Refusing to overwrite existing non-Git path: $Path" }
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
            Assert-BranchMatchesFetchedRef -Path $Path -RemoteRef $remoteRef
        }
        else {
            $head = (& git -C $Path rev-parse HEAD).Trim()
            if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-fA-F]{40}$') { throw "Unable to prove detached HEAD identity for $Path" }
        }
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        & git clone $Remote $Path
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Remote" }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
    }
}

function Read-ValidatedSuperpowersLock {
    $path = Join-Path $InstallRoot 'superpowers.lock.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Superpowers lock file not found: $path" }
    try { $lock = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { throw "Superpowers lock file is not valid JSON: $($_.Exception.Message)" }
    if ([string]$lock.repository -cne $CanonicalSuperpowersRemote) { throw "Unexpected Superpowers repository in lock: $($lock.repository)" }
    if ([string]$lock.commit -notmatch '^[0-9a-f]{40}$') { throw "Invalid Superpowers commit in lock: $($lock.commit)" }
    return $lock
}

function Sync-PinnedRepository {
    param([Parameter(Mandatory)][string]$Remote,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Commit)
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Refusing to overwrite existing non-Git path: $Path" }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
        $dirty = & git -C $Path status --porcelain
        if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Refusing to reconcile non-clean pinned repository: $Path" }
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        & git clone $Remote $Path
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Remote" }
        Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
    }
    & git -C $Path fetch --tags --prune $Remote
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed for pinned repository: $Path" }
    & git -C $Path cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Pinned commit is unavailable in $Path : $Commit" }
    & git -C $Path checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned commit failed for $Path" }
    $actual = (& git -C $Path rev-parse HEAD).Trim().ToLowerInvariant()
    if ($actual -ne $Commit) { throw "Pinned identity mismatch for $Path. Expected $Commit, found $actual" }
}

function Get-ModuleState {
    if (Test-Path -LiteralPath $CompositeManifest) {
        $reader = Join-Path $InstallRoot 'scripts\Read-HmsCompositeModuleState.ps1'
        if (-not (Test-Path -LiteralPath $reader)) { throw "Strict composite manifest reader is missing: $reader" }
        return & $reader -ManifestPath $CompositeManifest
    }

    $legacy = [ordered]@{
        hms = (Join-Path $SkillsRoot 'hms')
        superpowers = (Join-Path $SkillsRoot 'superpowers')
        taste = (Join-Path $SkillsRoot 'gpt-taste')
        impeccable = (Join-Path $SkillsRoot 'impeccable')
    }
    $state = [ordered]@{}
    $legacyFound = $false
    foreach ($key in $legacy.Keys) {
        $exists = $null -ne (Get-Item -LiteralPath $legacy[$key] -Force -ErrorAction SilentlyContinue)
        $state[$key] = $exists
        if ($exists) { $legacyFound = $true }
    }
    if ($legacyFound) { return [pscustomobject]$state }
    return [pscustomobject][ordered]@{
        hms = $true
        superpowers = (-not $SkipSuperpowers)
        taste = (-not $SkipTaste)
        impeccable = (-not $SkipImpeccable)
    }
}

$buildMutex = New-Object System.Threading.Mutex($false, $BuildMutexName)
$mutexOwned = $false
try {
    try {
        $mutexOwned = $buildMutex.WaitOne([TimeSpan]::FromSeconds(120))
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexOwned = $true
    }
    if (-not $mutexOwned) { throw "Timed out waiting for composite build lock: $BuildMutexName" }

    Assert-Git
    if (Test-Path -LiteralPath (Join-Path $InstallRoot '.git')) { Assert-NoHiddenIndexState -Path $InstallRoot }

    # Source reconciliation and composite compilation are one cross-process transaction.
    Sync-Repository -Remote $HmsRemote -Path $InstallRoot
    Assert-NoHiddenIndexState -Path $InstallRoot
    $state = Get-ModuleState

    & (Join-Path $InstallRoot 'scripts\Test-HmsSkills.ps1')
    & (Join-Path $InstallRoot 'scripts\Test-DeliveryTools.ps1')

    if (-not $SkipSuperpowers) {
        $superLock = Read-ValidatedSuperpowersLock
        Sync-PinnedRepository -Remote ([string]$superLock.repository) -Path $SuperpowersRoot -Commit ([string]$superLock.commit)
    }

    $uiArgs = @{}
    if ($SkipTaste) { $uiArgs.SkipTaste = $true }
    if ($SkipImpeccable) { $uiArgs.SkipImpeccable = $true }
    & (Join-Path $InstallRoot 'scripts\Sync-UiSkills.ps1') @uiArgs

    $deliveryArgs = @{}
    if (-not $SkipCodeGraph) { $deliveryArgs.EnsureCodeGraphConfig = $true }
    if ($SkipCodeGraph) { $deliveryArgs.SkipCodeGraph = $true }
    if ($SkipThreeLevelDelivery) { $deliveryArgs.SkipThreeLevelDelivery = $true }
    & (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1') @deliveryArgs

    # The builder acquires this named Mutex recursively on the same lifecycle thread.
    # Both successful WaitOne calls are required to release exactly once; release failures are fatal below.
    & (Join-Path $InstallRoot 'scripts\Build-HmsCompositeSkill.ps1') `
        -InstallRoot $InstallRoot `
        -Hms ([bool]$state.hms) `
        -Superpowers ([bool]$state.superpowers) `
        -Taste ([bool]$state.taste) `
        -Impeccable ([bool]$state.impeccable)

    Write-Host 'HMS Skills Codex installation PASS.'
    Write-Host 'Codex public skill: $hms-superpowers'
    Write-Host ('Enabled modules: ' + (@(('hms','superpowers','taste','impeccable') | Where-Object { [bool]$state.$_ }) -join ', '))
    if (-not $SkipCodeGraph) { Write-Host 'CodeGraph remains an MCP tool, not a separate public skill.' }
    Write-Host 'Restart Codex to refresh discovery.'
}
finally {
    $mutexReleaseError = $null
    if ($mutexOwned) {
        try {
            $buildMutex.ReleaseMutex()
            $mutexOwned = $false
        }
        catch {
            $mutexReleaseError = $_
        }
    }
    $buildMutex.Dispose()
    if ($null -ne $mutexReleaseError) {
        throw "Failed to release composite build lock after install lifecycle: $($mutexReleaseError.Exception.Message)"
    }
}
