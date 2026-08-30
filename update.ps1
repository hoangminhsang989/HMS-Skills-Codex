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
$TasteRoot = Join-Path $env:USERPROFILE '.codex\taste-skill'
$ImpeccableRoot = Join-Path $env:USERPROFILE '.codex\impeccable'
$CompositeManifest = Join-Path $env:USERPROFILE '.codex\hms-composite\hms-superpowers\manifest.json'
$SkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$BuildMutexName = 'Local\HMS-Skills-Codex-CompositeBuild-v1'

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
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) { throw "Unexpected Git origin for $Path." }
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
    if ($LASTEXITCODE -eq 0) { return $branch.Trim() }
    if ($LASTEXITCODE -eq 1) { return $null }
    throw "git symbolic-ref failed for $Path"
}

function Update-CleanRepo {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedRemote)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Git repository not found: $Path" }
    Assert-ExpectedOrigin -Path $Path -ExpectedRemote $ExpectedRemote
    $dirty = & git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Refusing to update non-clean repository: $Path" }
    $branch = Get-CurrentBranch -Path $Path
    if ($null -ne $branch) {
        $remoteRef = "refs/remotes/origin/$branch"
        & git -C $Path fetch --prune $ExpectedRemote "refs/heads/${branch}:${remoteRef}"
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed for $Path" }
        & git -C $Path merge --ff-only $remoteRef
        if ($LASTEXITCODE -ne 0) { throw "git merge --ff-only failed for $Path" }
        $head = (& git -C $Path rev-parse HEAD).Trim().ToLowerInvariant()
        $remoteHead = (& git -C $Path rev-parse $remoteRef).Trim().ToLowerInvariant()
        if ($head -ne $remoteHead) { throw "HMS branch identity mismatch for $Path." }
    }
}

function Assert-ExistingPinnedSourceClean {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "$Label source path exists but is not a Git checkout: $Path" }
    $dirty = & git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "$Label clean-state preflight failed: $Path" }
    if ($dirty) { throw "Refusing to reconcile non-clean pinned repository: $Path" }
}

function Read-SuperLock {
    $lock = Get-Content -LiteralPath (Join-Path $InstallRoot 'superpowers.lock.json') -Raw | ConvertFrom-Json
    if ([string]$lock.repository -cne $CanonicalSuperpowersRemote -or [string]$lock.commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid Superpowers lock.' }
    return $lock
}

function Sync-PinnedRepo {
    param([string]$Path,[string]$Remote,[string]$Commit)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        & git clone $Remote $Path
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Remote" }
    }
    Assert-ExpectedOrigin -Path $Path -ExpectedRemote $Remote
    $dirty = & git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Refusing to reconcile non-clean pinned repository: $Path" }
    & git -C $Path fetch --tags --prune $Remote
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed for $Path" }
    & git -C $Path checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) { throw "Pinned checkout failed for $Path" }
    $actual = (& git -C $Path rev-parse HEAD).Trim().ToLowerInvariant()
    if ($actual -ne $Commit) { throw "Pinned identity mismatch for $Path." }
}

function Get-ModuleState {
    if (Test-Path -LiteralPath $CompositeManifest) {
        $reader = Join-Path $InstallRoot 'scripts\Read-HmsCompositeModuleState.ps1'
        if (-not (Test-Path -LiteralPath $reader)) { throw "Strict composite manifest reader is missing: $reader" }
        return & $reader -ManifestPath $CompositeManifest
    }
    $legacy = [ordered]@{ hms='hms'; superpowers='superpowers'; taste='gpt-taste'; impeccable='impeccable' }
    $state = [ordered]@{}
    $found = $false
    foreach ($key in $legacy.Keys) {
        $exists = $null -ne (Get-Item -LiteralPath (Join-Path $SkillsRoot $legacy[$key]) -Force -ErrorAction SilentlyContinue)
        $state[$key] = $exists
        if ($exists) { $found = $true }
    }
    if ($found) { return [pscustomobject]$state }
    return [pscustomobject][ordered]@{ hms=$true; superpowers=(-not $SkipSuperpowers); taste=(-not $SkipTaste); impeccable=(-not $SkipImpeccable) }
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

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git.exe is required but was not found in PATH.' }
    Assert-NoHiddenIndexState -Path $InstallRoot
    $state = Get-ModuleState

    # Fail fast on local UI-source drift before HMS/external network reconciliation.
    if (-not $SkipTaste) { Assert-ExistingPinnedSourceClean -Path $TasteRoot -Label 'GPT Taste' }
    if (-not $SkipImpeccable) { Assert-ExistingPinnedSourceClean -Path $ImpeccableRoot -Label 'Impeccable' }

    # Source reconciliation and composite compilation are one cross-process transaction.
    Update-CleanRepo -Path $InstallRoot -ExpectedRemote $HmsRemote
    Assert-NoHiddenIndexState -Path $InstallRoot
    & (Join-Path $InstallRoot 'scripts\Test-HmsSkills.ps1')
    & (Join-Path $InstallRoot 'scripts\Test-DeliveryTools.ps1')

    if (-not $SkipSuperpowers) {
        $lock = Read-SuperLock
        Sync-PinnedRepo -Path $SuperpowersRoot -Remote ([string]$lock.repository) -Commit ([string]$lock.commit)
    }
    $uiArgs = @{}
    if ($SkipTaste) { $uiArgs.SkipTaste = $true }
    if ($SkipImpeccable) { $uiArgs.SkipImpeccable = $true }
    & (Join-Path $InstallRoot 'scripts\Sync-UiSkills.ps1') @uiArgs

    $deliveryArgs = @{}
    if (-not $SkipCodeGraph) { $deliveryArgs.EnableCodeGraphIfNew = $true }
    if ($SkipCodeGraph) { $deliveryArgs.SkipCodeGraph = $true }
    if ($SkipThreeLevelDelivery) { $deliveryArgs.SkipThreeLevelDelivery = $true }
    & (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1') @deliveryArgs

    # The builder acquires this named Mutex recursively on the same lifecycle thread.
    # Both successful WaitOne calls are required to release exactly once; release failures are fatal below.
    & (Join-Path $InstallRoot 'scripts\Build-HmsCompositeSkill.ps1') -InstallRoot $InstallRoot -Hms ([bool]$state.hms) -Superpowers ([bool]$state.superpowers) -Taste ([bool]$state.taste) -Impeccable ([bool]$state.impeccable)

    Write-Host 'HMS Skills Codex update PASS.'
    Write-Host 'Existing module ON/OFF choices were preserved.'
    Write-Host 'Codex public skill remains: $hms-superpowers'
    Write-Host 'Restart Codex if discovery does not refresh automatically.'
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
        throw "Failed to release composite build lock after update lifecycle: $($mutexReleaseError.Exception.Message)"
    }
}
