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
$LifecycleTrustRelative = 'scripts/Initialize-HmsLifecycleTrust.ps1'

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

function Get-HmsCanonicalHead {
    param([Parameter(Mandatory)][string]$Path)
    $head = ((& git -C $Path rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw "Unable to capture canonical HMS HEAD for $Path" }
    $type = ((& git -C $Path cat-file -t $head 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'commit') { throw "Captured HMS HEAD is not an available commit: $head" }
    return $head
}

function Get-HmsLifecycleTrustBootstrap {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Head)
    $expected = ((& git -C $RepoRoot rev-parse "$Head`:$LifecycleTrustRelative" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $expected -notmatch '^[0-9a-f]{40}$') { throw 'Lifecycle trust bootstrap committed blob is unavailable.' }
    $type = ((& git -C $RepoRoot cat-file -t $expected 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'blob') { throw 'Lifecycle trust bootstrap object is not a committed blob.' }

    $gitExe = @((Get-Command git.exe -CommandType Application -ErrorAction Stop))[0].Source
    $cmdExe = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ('hms-lifecycle-blob-' + [guid]::NewGuid().ToString('N') + '.bin')
    $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ('hms-lifecycle-blob-' + [guid]::NewGuid().ToString('N') + '.err')
    foreach ($commandPath in @($gitExe,$cmdExe,$RepoRoot,$stdoutPath,$stderrPath)) {
        if ([string]::IsNullOrWhiteSpace($commandPath) -or $commandPath -match '["%\r\n]') {
            throw "Lifecycle trust bootstrap command path is unsafe for exact cmd.exe redirection: $commandPath"
        }
    }
    if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) { throw "Resolved git.exe does not exist: $gitExe" }
    if (-not (Test-Path -LiteralPath $cmdExe -PathType Leaf)) { throw "Trusted cmd.exe does not exist: $cmdExe" }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cmdExe
    $psi.Arguments = ('/d /q /v:off /s /c ""{0}" -C "{1}" cat-file blob {2} > "{3}" 2> "{4}""' -f $gitExe,$RepoRoot,$expected,$stdoutPath,$stderrPath)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { throw 'Could not start trusted cmd.exe for lifecycle trust bootstrap.' }
        if (-not $proc.WaitForExit(10000)) {
            try { $proc.Kill() } catch {}
            throw 'Lifecycle trust bootstrap git cat-file timed out after 10 seconds.'
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [IO.File]::ReadAllText($stderrPath) } else { '' }
        if ($proc.ExitCode -ne 0) { throw "Lifecycle trust bootstrap git cat-file failed: $stderr" }
        if (-not (Test-Path -LiteralPath $stdoutPath -PathType Leaf)) { throw 'Lifecycle trust bootstrap output file was not created.' }
        if (-not [string]::IsNullOrEmpty($stderr)) { throw "Lifecycle trust bootstrap git cat-file produced unexpected stderr: $stderr" }
        $bytes = [IO.File]::ReadAllBytes($stdoutPath)
    }
    finally {
        $proc.Dispose()
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + [string]$bytes.Length + [char]0))
    $sha1 = [Security.Cryptography.SHA1]::Create()
    $hashStream = New-Object IO.MemoryStream
    try {
        $hashStream.Write($header,0,$header.Length)
        if ($bytes.Length -gt 0) { $hashStream.Write($bytes,0,$bytes.Length) }
        $hashStream.Position = 0
        $actual = (($sha1.ComputeHash($hashStream) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $hashStream.Dispose(); $sha1.Dispose() }
    if ($actual -cne $expected) { throw "Lifecycle trust bootstrap identity mismatch. Expected $expected, found $actual." }
    try { $source = (New-Object Text.UTF8Encoding($false,$true)).GetString([byte[]]$bytes) }
    catch { throw "Lifecycle trust bootstrap is not strict UTF-8: $($_.Exception.Message)" }
    return [pscustomobject]@{ Sha=$expected; ScriptBlock=[ScriptBlock]::Create($source) }
}

function Read-SuperLock {
    param([Parameter(Mandatory)][string]$JsonText)
    try { $lock = $JsonText | ConvertFrom-Json }
    catch { throw "Committed Superpowers lock is invalid JSON: $($_.Exception.Message)" }
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
    param([scriptblock]$ReaderScript)
    if (Test-Path -LiteralPath $CompositeManifest) {
        if ($null -eq $ReaderScript) { throw 'Authenticated composite manifest reader is unavailable.' }
        return & $ReaderScript -ManifestPath $CompositeManifest
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

    # Preserve existing module choices from the exact pre-update committed reader. This authority
    # is captured before any HMS fetch/fast-forward so an update cannot reinterpret prior state
    # through a newly downloaded or live-worktree reader.
    $preUpdateHead = Get-HmsCanonicalHead -Path $InstallRoot
    $preTrustBootstrap = Get-HmsLifecycleTrustBootstrap -RepoRoot $InstallRoot -Head $preUpdateHead
    . $preTrustBootstrap.ScriptBlock
    $preReaderSnapshot = Get-HmsCommittedScriptSnapshot -RepoRoot $InstallRoot -Head $preUpdateHead -RelativePath 'scripts/Read-HmsCompositeModuleState.ps1' -Label 'Pre-update composite module-state reader'
    $state = Get-ModuleState -ReaderScript $preReaderSnapshot.ScriptBlock

    # Fail fast on local UI-source drift before HMS/external network reconciliation.
    if (-not $SkipTaste) { Assert-ExistingPinnedSourceClean -Path $TasteRoot -Label 'GPT Taste' }
    if (-not $SkipImpeccable) { Assert-ExistingPinnedSourceClean -Path $ImpeccableRoot -Label 'Impeccable' }

    # Source reconciliation and composite compilation are one cross-process transaction.
    Update-CleanRepo -Path $InstallRoot -ExpectedRemote $HmsRemote
    Assert-NoHiddenIndexState -Path $InstallRoot
    $trustedHead = Get-HmsCanonicalHead -Path $InstallRoot

    # Re-import from the exact post-update committed bootstrap. All subsequent executable helpers
    # and their lock inputs are now bound to this one post-update HEAD, not mutable worktree paths.
    $postTrustBootstrap = Get-HmsLifecycleTrustBootstrap -RepoRoot $InstallRoot -Head $trustedHead
    . $postTrustBootstrap.ScriptBlock

    # Developer/CI test harnesses are intentionally not executable from the trusted production lifecycle.
    # Permanent CI qualifies those validators on exact committed release candidates.

    if (-not $SkipSuperpowers) {
        $superLockText = Get-HmsCommittedUtf8Text -RepoRoot $InstallRoot -Head $trustedHead -RelativePath 'superpowers.lock.json' -Label 'Superpowers lock'
        $lock = Read-SuperLock -JsonText $superLockText.Text
        Sync-PinnedRepo -Path $SuperpowersRoot -Remote ([string]$lock.repository) -Commit ([string]$lock.commit)
    }

    $uiSnapshot = Get-HmsCommittedLifecycleScriptSnapshot -RepoRoot $InstallRoot -Head $trustedHead -ScriptRelativePath 'scripts/Sync-UiSkills.ps1' -LockRelativePath 'ui-skills.lock.json' -Label 'UI source reconciliation'
    $uiArgs = @{}
    if ($SkipTaste) { $uiArgs.SkipTaste = $true }
    if ($SkipImpeccable) { $uiArgs.SkipImpeccable = $true }
    & $uiSnapshot.ScriptBlock @uiArgs

    $deliverySnapshot = Get-HmsCommittedLifecycleScriptSnapshot -RepoRoot $InstallRoot -Head $trustedHead -ScriptRelativePath 'scripts/Sync-DeliveryTools.ps1' -LockRelativePath 'delivery-tools.lock.json' -Label 'Delivery source reconciliation'
    $deliveryArgs = @{}
    if (-not $SkipCodeGraph) { $deliveryArgs.EnableCodeGraphIfNew = $true }
    if ($SkipCodeGraph) { $deliveryArgs.SkipCodeGraph = $true }
    if ($SkipThreeLevelDelivery) { $deliveryArgs.SkipThreeLevelDelivery = $true }
    & $deliverySnapshot.ScriptBlock @deliveryArgs

    # The builder acquires this named Mutex recursively on the same lifecycle thread and retains
    # its existing trusted-context verification/materialization contract.
    $builderSnapshot = Get-HmsCommittedScriptSnapshot -RepoRoot $InstallRoot -Head $trustedHead -RelativePath 'scripts/Build-HmsCompositeSkill.ps1' -Label 'Composite builder public bootstrap'
    & $builderSnapshot.ScriptBlock `
        -InstallRoot $InstallRoot `
        -Hms ([bool]$state.hms) `
        -Superpowers ([bool]$state.superpowers) `
        -Taste ([bool]$state.taste) `
        -Impeccable ([bool]$state.impeccable) `
        -TrustedRepoRoot $InstallRoot `
        -TrustedHead $trustedHead `
        -TrustedBootstrapBlob ([string]$builderSnapshot.Sha)

    Write-Host 'HMS Skills Codex update PASS.'
    Write-Host 'Existing module ON/OFF choices were preserved.'
    Write-Host 'Codex public skill remains: $hms-superpowers'
    Write-Host "Pre-update state authority: committed snapshot $preUpdateHead"
    Write-Host "Post-update lifecycle authority: committed snapshot $trustedHead"
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
