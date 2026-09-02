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
$LifecycleTrustRelative = 'scripts/Initialize-HmsLifecycleTrust.ps1'

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

function Read-ValidatedSuperpowersLock {
    param([Parameter(Mandatory)][string]$JsonText)
    try { $lock = $JsonText | ConvertFrom-Json }
    catch { throw "Committed Superpowers lock is not valid JSON: $($_.Exception.Message)" }
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
    param([scriptblock]$ReaderScript)
    if (Test-Path -LiteralPath $CompositeManifest) {
        if ($null -eq $ReaderScript) { throw 'Authenticated composite manifest reader is unavailable.' }
        return & $ReaderScript -ManifestPath $CompositeManifest
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
    $trustedHead = Get-HmsCanonicalHead -Path $InstallRoot

    # Import trust helpers only from the exact committed Git object at the captured post-sync HEAD.
    # No live lifecycle helper pathname is reopened for executable authority after this boundary.
    $trustBootstrap = Get-HmsLifecycleTrustBootstrap -RepoRoot $InstallRoot -Head $trustedHead
    . $trustBootstrap.ScriptBlock

    $readerSnapshot = Get-HmsCommittedScriptSnapshot -RepoRoot $InstallRoot -Head $trustedHead -RelativePath 'scripts/Read-HmsCompositeModuleState.ps1' -Label 'Composite module-state reader'
    $state = Get-ModuleState -ReaderScript $readerSnapshot.ScriptBlock

    # Developer/CI test harnesses are intentionally not executable from the trusted production lifecycle.
    # Permanent CI qualifies those validators on exact committed release candidates.

    if (-not $SkipSuperpowers) {
        $superLockText = Get-HmsCommittedUtf8Text -RepoRoot $InstallRoot -Head $trustedHead -RelativePath 'superpowers.lock.json' -Label 'Superpowers lock'
        $superLock = Read-ValidatedSuperpowersLock -JsonText $superLockText.Text
        Sync-PinnedRepository -Remote ([string]$superLock.repository) -Path $SuperpowersRoot -Commit ([string]$superLock.commit)
    }

    $uiSnapshot = Get-HmsCommittedLifecycleScriptSnapshot -RepoRoot $InstallRoot -Head $trustedHead -ScriptRelativePath 'scripts/Sync-UiSkills.ps1' -LockRelativePath 'ui-skills.lock.json' -Label 'UI source reconciliation'
    $uiArgs = @{}
    if ($SkipTaste) { $uiArgs.SkipTaste = $true }
    if ($SkipImpeccable) { $uiArgs.SkipImpeccable = $true }
    & $uiSnapshot.ScriptBlock @uiArgs

    $deliverySnapshot = Get-HmsCommittedLifecycleScriptSnapshot -RepoRoot $InstallRoot -Head $trustedHead -ScriptRelativePath 'scripts/Sync-DeliveryTools.ps1' -LockRelativePath 'delivery-tools.lock.json' -Label 'Delivery source reconciliation'
    $deliveryArgs = @{}
    if (-not $SkipCodeGraph) { $deliveryArgs.EnsureCodeGraphConfig = $true }
    if ($SkipCodeGraph) { $deliveryArgs.SkipCodeGraph = $true }
    if ($SkipThreeLevelDelivery) { $deliveryArgs.SkipThreeLevelDelivery = $true }
    & $deliverySnapshot.ScriptBlock @deliveryArgs

    # The builder acquires this named Mutex recursively on the same lifecycle thread.
    # Its public bootstrap is also executed from the exact captured committed bytes and receives
    # the existing trusted-context tuple so all deeper support materialization stays HEAD-bound.
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

    Write-Host 'HMS Skills Codex installation PASS.'
    Write-Host 'Codex public skill: $hms-superpowers'
    Write-Host ('Enabled modules: ' + (@(('hms','superpowers','taste','impeccable') | Where-Object { [bool]$state.$_ }) -join ', '))
    if (-not $SkipCodeGraph) { Write-Host 'CodeGraph remains an MCP tool, not a separate public skill.' }
    Write-Host "Lifecycle helper authority: committed snapshot $trustedHead"
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
