[CmdletBinding()]
param(
    [string]$AuthorityPath = (Join-Path $PSScriptRoot 'setup-authority.json'),
    [string]$ToolsLockPath = (Join-Path $PSScriptRoot 'setup-tools.lock.json'),
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [string]$AppRoot = (Join-Path $env:LOCALAPPDATA 'Programs\HMS Superpowers'),
    [ValidateSet('Install','Repair','Diagnose')]
    [string]$Mode = 'Install'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CanonicalHmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
$SupportMarkerName = '.hms-owned-support-v1.json'
$SetupRemoteRef = 'refs/remotes/hms-setup/authority'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-HmsNormalizedRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git',[StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring(0,$value.Length - 4) }
    return $value.ToLowerInvariant()
}

function Get-HmsSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-HmsSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$Expected
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Pinned artifact is missing: $Path" }
    $actual = Get-HmsSha256 -Path $Path
    if ($actual -cne $Expected.ToLowerInvariant()) { throw "SHA-256 mismatch for $Path. Expected $($Expected.ToLowerInvariant()), found $actual." }
}

function Assert-HmsNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "HMS setup rejected a reparse point in a trusted path: $cursor" }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or $parent.FullName -ceq $cursor) { break }
        $cursor = $parent.FullName
    }
}

function Assert-HmsSafeDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowCreate
    )
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetPathRoot($full).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($full) -or $full -ceq $root) { throw "$Label path is unsafe: $full" }
    Assert-HmsNoReparsePath -Path $full
    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "$Label path is not a directory: $full" }
    }
    elseif ($AllowCreate) {
        $parent = Split-Path -Parent $full
        if ([string]::IsNullOrWhiteSpace($parent)) { throw "$Label has no safe parent: $full" }
        Assert-HmsNoReparsePath -Path $parent
        $null = New-Item -ItemType Directory -Path $full -Force
        Assert-HmsNoReparsePath -Path $full
    }
    else { throw "$Label directory is missing: $full" }
    return $full
}

function Assert-HmsTreeNoReparse {
    param([Parameter(Mandatory)][string]$Directory)
    $null = Assert-HmsSafeDirectory -Path $Directory -Label 'support tree'
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force -Recurse -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Support tree contains a reparse point: $($item.FullName)" }
    }
}

function Write-HmsSupportMarker {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateSet('mingit','codex')][string]$Kind,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Asset,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ArtifactSha256
    )
    $marker = [ordered]@{ schema_version = 1; owner = 'HMS Superpowers'; kind = $Kind; tag = $Tag; asset = $Asset; artifact_sha256 = $ArtifactSha256 }
    [IO.File]::WriteAllText((Join-Path $Directory $SupportMarkerName),($marker | ConvertTo-Json -Depth 4),$Utf8NoBom)
}

function Assert-HmsOwnedSupportDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateSet('mingit','codex')][string]$Kind
    )
    $safe = Assert-HmsSafeDirectory -Path $Directory -Label "$Kind support directory"
    $markerPath = Join-Path $safe $SupportMarkerName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw "Refusing to replace an unmarked support directory: $safe" }
    $markerItem = Get-Item -LiteralPath $markerPath -Force
    if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Support marker is a reparse point: $markerPath" }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ([int]$marker.schema_version -ne 1 -or [string]$marker.owner -cne 'HMS Superpowers' -or [string]$marker.kind -cne $Kind) { throw "Support marker ownership mismatch: $markerPath" }
    return $safe
}

function Remove-HmsOwnedSupportDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateSet('mingit','codex')][string]$Kind
    )
    $null = Assert-HmsOwnedSupportDirectory -Directory $Directory -Kind $Kind
    Assert-HmsTreeNoReparse -Directory $Directory
    Remove-Item -LiteralPath $Directory -Recurse -Force
}

function Invoke-HmsPinnedDownload {
    param(
        [Parameter(Mandatory)][ValidatePattern('^https://github\.com/')][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Sha256
    )
    $parent = Assert-HmsSafeDirectory -Path (Split-Path -Parent $Destination) -Label 'download staging root' -AllowCreate
    $destinationFull = [IO.Path]::GetFullPath($Destination)
    if (-not $destinationFull.StartsWith($parent + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Pinned download destination escaped its staging root.' }
    if (Test-Path -LiteralPath $destinationFull) { throw "Pinned download destination already exists: $destinationFull" }
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $destinationFull -MaximumRedirection 5
        Assert-HmsSha256 -Path $destinationFull -Expected $Sha256
    }
    catch { Remove-Item -LiteralPath $destinationFull -Force -ErrorAction SilentlyContinue; throw }
    finally { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol }
    return $destinationFull
}

function Get-HmsReleaseAssetUri {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Asset
    )
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Pinned repository identity is malformed.' }
    if ($Tag -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Pinned release tag is malformed.' }
    if ($Asset -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Pinned release asset is malformed.' }
    return "https://github.com/$Repository/releases/download/$Tag/$Asset"
}

function Invoke-HmsVersionProbe {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [int]$TimeoutMilliseconds = 10000
    )
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = '--version'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { return $null }
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMilliseconds)) { try { $proc.Kill() } catch {}; return $null }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0) { return $null }
        return (($stdout + "`n" + $stderr).Trim())
    }
    catch { return $null }
    finally { $proc.Dispose() }
}

function Invoke-HmsAtomicSupportActivation {
    param(
        [Parameter(Mandatory)][string]$StagedDirectory,
        [Parameter(Mandatory)][string]$TargetDirectory,
        [Parameter(Mandatory)][ValidateSet('mingit','codex')][string]$Kind
    )
    $parent = Assert-HmsSafeDirectory -Path (Split-Path -Parent $TargetDirectory) -Label 'support root' -AllowCreate
    $stage = Assert-HmsSafeDirectory -Path $StagedDirectory -Label "$Kind staged support"
    if ((Split-Path -Parent $stage) -cne $parent) { throw 'Support staging directory must share the target parent for atomic activation.' }
    Assert-HmsTreeNoReparse -Directory $stage

    $backup = $null
    if (Test-Path -LiteralPath $TargetDirectory) {
        $null = Assert-HmsOwnedSupportDirectory -Directory $TargetDirectory -Kind $Kind
        $backup = Join-Path $parent ('.backup-' + $Kind + '-' + [guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $TargetDirectory -Destination $backup
    }
    try { Move-Item -LiteralPath $stage -Destination $TargetDirectory }
    catch {
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $TargetDirectory)) { Move-Item -LiteralPath $backup -Destination $TargetDirectory }
        throw
    }
    if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) { Remove-HmsOwnedSupportDirectory -Directory $backup -Kind $Kind }
}

function Ensure-HmsMinGit {
    param(
        [Parameter(Mandatory)][pscustomobject]$Lock,
        [Parameter(Mandatory)][string]$SupportRoot
    )
    $target = Join-Path $SupportRoot 'git'
    $expectedGit = Join-Path $target 'cmd\git.exe'
    if (Test-Path -LiteralPath $target) {
        $null = Assert-HmsOwnedSupportDirectory -Directory $target -Kind 'mingit'
        if (Test-Path -LiteralPath $expectedGit -PathType Leaf) {
            $gitItem = Get-Item -LiteralPath $expectedGit -Force
            $version = if (($gitItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { Invoke-HmsVersionProbe -Executable $expectedGit } else { $null }
            if ($null -ne $version -and $version -match 'git version 2\.55\.0') { return $expectedGit }
        }
    }

    $stage = Join-Path $SupportRoot ('.stage-mingit-' + [guid]::NewGuid().ToString('N'))
    $downloadRoot = Join-Path $SupportRoot ('.download-mingit-' + [guid]::NewGuid().ToString('N'))
    $null = Assert-HmsSafeDirectory -Path $stage -Label 'MinGit stage' -AllowCreate
    $null = Assert-HmsSafeDirectory -Path $downloadRoot -Label 'MinGit download stage' -AllowCreate
    $archive = Join-Path $downloadRoot ([string]$Lock.asset)
    try {
        $uri = Get-HmsReleaseAssetUri -Repository ([string]$Lock.repository) -Tag ([string]$Lock.tag) -Asset ([string]$Lock.asset)
        $null = Invoke-HmsPinnedDownload -Uri $uri -Destination $archive -Sha256 ([string]$Lock.sha256)
        Expand-Archive -LiteralPath $archive -DestinationPath $stage
        Assert-HmsTreeNoReparse -Directory $stage
        $stagedGit = Join-Path $stage 'cmd\git.exe'
        if (-not (Test-Path -LiteralPath $stagedGit -PathType Leaf)) { throw 'Pinned MinGit archive did not contain cmd\git.exe.' }
        $gitItem = Get-Item -LiteralPath $stagedGit -Force
        if (($gitItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Pinned MinGit git.exe is a reparse point.' }
        $version = Invoke-HmsVersionProbe -Executable $stagedGit
        if ($null -eq $version -or $version -notmatch 'git version 2\.55\.0') { throw 'Pinned MinGit failed its version smoke check.' }
        Write-HmsSupportMarker -Directory $stage -Kind 'mingit' -Tag ([string]$Lock.tag) -Asset ([string]$Lock.asset) -ArtifactSha256 ([string]$Lock.sha256)
        Invoke-HmsAtomicSupportActivation -StagedDirectory $stage -TargetDirectory $target -Kind 'mingit'
        return (Join-Path $target 'cmd\git.exe')
    }
    finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $downloadRoot) { Remove-Item -LiteralPath $downloadRoot -Force -ErrorAction SilentlyContinue }
    }
}

function Test-HmsPinnedCodexExecutable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSha256
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    try { Assert-HmsSha256 -Path $Path -Expected $ExpectedSha256 } catch { return $false }
    $version = Invoke-HmsVersionProbe -Executable $Path
    return ($null -ne $version -and $version -match '0\.152\.1')
}

function Resolve-HmsCodex {
    param(
        [Parameter(Mandatory)][pscustomobject]$Lock,
        [Parameter(Mandatory)][string]$SupportRoot
    )
    $userCandidates = @(Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
    foreach ($candidate in $userCandidates) {
        if (Test-HmsPinnedCodexExecutable -Path ([string]$candidate) -ExpectedSha256 ([string]$Lock.exe_sha256)) { return [IO.Path]::GetFullPath([string]$candidate) }
    }

    $target = Join-Path $SupportRoot 'codex'
    $expectedExe = Join-Path $target 'codex.exe'
    if (Test-Path -LiteralPath $target) {
        $null = Assert-HmsOwnedSupportDirectory -Directory $target -Kind 'codex'
        if (Test-HmsPinnedCodexExecutable -Path $expectedExe -ExpectedSha256 ([string]$Lock.exe_sha256)) { return $expectedExe }
    }

    $stage = Join-Path $SupportRoot ('.stage-codex-' + [guid]::NewGuid().ToString('N'))
    $downloadRoot = Join-Path $SupportRoot ('.download-codex-' + [guid]::NewGuid().ToString('N'))
    $null = Assert-HmsSafeDirectory -Path $stage -Label 'Codex stage' -AllowCreate
    $null = Assert-HmsSafeDirectory -Path $downloadRoot -Label 'Codex download stage' -AllowCreate
    $archive = Join-Path $downloadRoot ([string]$Lock.asset)
    try {
        $uri = Get-HmsReleaseAssetUri -Repository ([string]$Lock.repository) -Tag ([string]$Lock.tag) -Asset ([string]$Lock.asset)
        $null = Invoke-HmsPinnedDownload -Uri $uri -Destination $archive -Sha256 ([string]$Lock.archive_sha256)
        Expand-Archive -LiteralPath $archive -DestinationPath $stage
        Assert-HmsTreeNoReparse -Directory $stage
        $matches = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object { $_.Name -ceq 'codex-x86_64-pc-windows-msvc.exe' })
        if ($matches.Count -ne 1) { throw "Pinned Codex archive must contain exactly one expected x64 executable; found $($matches.Count)." }
        $sourceExe = $matches[0].FullName
        Assert-HmsSha256 -Path $sourceExe -Expected ([string]$Lock.exe_sha256)
        $finalExe = Join-Path $stage 'codex.exe'
        if ($sourceExe -cne $finalExe) { Copy-Item -LiteralPath $sourceExe -Destination $finalExe }
        Assert-HmsSha256 -Path $finalExe -Expected ([string]$Lock.exe_sha256)
        if (-not (Test-HmsPinnedCodexExecutable -Path $finalExe -ExpectedSha256 ([string]$Lock.exe_sha256)) { throw 'Pinned Codex fallback failed its executable/version smoke check.' }
        Write-HmsSupportMarker -Directory $stage -Kind 'codex' -Tag ([string]$Lock.tag) -Asset ([string]$Lock.asset) -ArtifactSha256 ([string]$Lock.archive_sha256)
        Invoke-HmsAtomicSupportActivation -StagedDirectory $stage -TargetDirectory $target -Kind 'codex'
        return (Join-Path $target 'codex.exe')
    }
    finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $downloadRoot) { Remove-Item -LiteralPath $downloadRoot -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-HmsToolsLock {
    param([Parameter(Mandatory)][pscustomobject]$Lock)
    if ([int]$Lock.schema_version -ne 1) { throw 'Unsupported setup-tools.lock.json schema_version.' }
    if ([string]$Lock.mingit.repository -cne 'git-for-windows/git' -or [string]$Lock.mingit.tag -cne 'v2.55.0.windows.5' -or [string]$Lock.mingit.asset -cne 'MinGit-2.55.0.5-64-bit.zip' -or ([string]$Lock.mingit.sha256).ToLowerInvariant() -cne '56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e') { throw 'MinGit setup lock does not match the v0.3.0 authority.' }
    if ([string]$Lock.codex.repository -cne 'openai/codex' -or [string]$Lock.codex.tag -cne 'rust-v0.152.1' -or [string]$Lock.codex.asset -cne 'codex-x86_64-pc-windows-msvc.exe.zip' -or ([string]$Lock.codex.archive_sha256).ToLowerInvariant() -cne '11634c7da0aadf53dff3ec0bad9fd3715371afff189becac433270b21cf299c9' -or ([string]$Lock.codex.exe_sha256).ToLowerInvariant() -cne '01b0fd4167393e004b9174c77ae5f8570486118e19dc4216cfc62a62a74b6ee6') { throw 'Codex setup lock does not match the v0.3.0 authority.' }
}

function Assert-HmsSetupAuthority {
    param([Parameter(Mandatory)][pscustomobject]$Authority)
    if ([int]$Authority.schema_version -ne 1) { throw 'Unsupported setup authority schema_version.' }
    if ([string]$Authority.product_version -cne '0.3.0') { throw 'Setup authority product_version must be 0.3.0.' }
    if ((ConvertTo-HmsNormalizedRemote ([string]$Authority.repository)) -cne (ConvertTo-HmsNormalizedRemote $CanonicalHmsRemote)) { throw 'Setup authority repository mismatch.' }
    if ([string]$Authority.commit -notmatch '^[0-9a-f]{40}$' -or [string]$Authority.tree -notmatch '^[0-9a-f]{40}$') { throw 'Setup authority commit/tree must be canonical lowercase Git SHA-1 values.' }
    if ([string]$Authority.mode -ceq 'candidate') {
        if ([string]$Authority.source_ref -cne 'refs/heads/stage/hms-superpowers-v0.3.0-windows-setup-menu') { throw 'Candidate setup authority source_ref mismatch.' }
        if ($null -ne $Authority.release_tag -and -not [string]::IsNullOrWhiteSpace([string]$Authority.release_tag)) { throw 'Candidate setup authority must not carry a release tag.' }
    }
    elseif ([string]$Authority.mode -ceq 'release') {
        if ([string]$Authority.source_ref -cne 'refs/tags/v0.3.0' -or [string]$Authority.release_tag -cne 'v0.3.0') { throw 'Release setup authority tag/ref mismatch.' }
    }
    else { throw 'Setup authority mode must be candidate or release.' }
}

function Invoke-HmsGit {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )
    $output = @(& $GitExe -C $RepoRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($FailureMessage + ' ' + (($output -join "`n").Trim())) }
    return (($output -join "`n").Trim())
}

function Test-HmsGitAncestor {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Older,
        [Parameter(Mandatory)][string]$Newer
    )
    & $GitExe -C $RepoRoot merge-base --is-ancestor $Older $Newer 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($LASTEXITCODE -eq 1) { return $false }
    throw "Unable to compare HMS commit ancestry: $Older -> $Newer"
}

function Assert-HmsCleanCheckout {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $status = Invoke-HmsGit -GitExe $GitExe -RepoRoot $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all') -FailureMessage 'Unable to inspect HMS checkout status.'
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw "Refusing setup mutation on a non-clean HMS checkout: $status" }
    $lines = @(& $GitExe -C $RepoRoot ls-files -v 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect HMS Git index flags.' }
    $hidden = @($lines | Where-Object { ([string]$_ -match '^S ') -or ([string]$_ -cmatch '^[a-z] ') })
    if ($hidden.Count -ne 0) { throw ('HMS checkout uses hidden index flags: ' + (($hidden | Select-Object -First 8) -join '; ')) }
}

function Reconcile-HmsCheckout {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][pscustomobject]$Authority,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $repo = [IO.Path]::GetFullPath($RepoRoot)
    Assert-HmsNoReparsePath -Path $repo
    $gitMeta = Join-Path $repo '.git'
    $isExistingRepo = Test-Path -LiteralPath $gitMeta

    if (-not $isExistingRepo) {
        if (Test-Path -LiteralPath $repo) {
            $null = Assert-HmsSafeDirectory -Path $repo -Label 'HMS install root'
            if (@(Get-ChildItem -LiteralPath $repo -Force).Count -ne 0) { throw "Fresh HMS install root is not empty: $repo" }
        }
        else {
            $parent = Split-Path -Parent $repo
            $null = Assert-HmsSafeDirectory -Path $parent -Label 'HMS install parent' -AllowCreate
            $null = New-Item -ItemType Directory -Path $repo
        }
        & $GitExe init --initial-branch=main $repo 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the HMS checkout.' }
        & $GitExe -C $repo remote add origin $CanonicalHmsRemote 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to configure the HMS origin.' }
    }
    else {
        if (-not (Test-Path -LiteralPath $gitMeta -PathType Container)) { throw 'HMS install root must use a normal .git directory, not an indirection file.' }
        $null = Assert-HmsSafeDirectory -Path $repo -Label 'HMS install root'
        $origin = Invoke-HmsGit -GitExe $GitExe -RepoRoot $repo -Arguments @('remote','get-url','origin') -FailureMessage 'Unable to resolve HMS origin.'
        if ((ConvertTo-HmsNormalizedRemote $origin) -cne (ConvertTo-HmsNormalizedRemote $CanonicalHmsRemote)) { throw "Unexpected HMS origin: $origin" }
        $branch = Invoke-HmsGit -GitExe $GitExe -RepoRoot $repo -Arguments @('symbolic-ref','--quiet','--short','HEAD') -FailureMessage 'HMS checkout must be attached to main.'
        if ($branch -cne 'main') { throw "HMS checkout must be on main; found $branch" }
        Assert-HmsCleanCheckout -GitExe $GitExe -RepoRoot $repo
    }

    $sourceRef = [string]$Authority.source_ref
    & $GitExe -C $repo fetch --no-tags origin ($sourceRef + ':' + $SetupRemoteRef) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to fetch exact HMS setup authority ref: $sourceRef" }
    $fetched = (Invoke-HmsGit -GitExe $GitExe -RepoRoot $repo -Arguments @('rev-parse',$SetupRemoteRef) -FailureMessage 'Unable to resolve fetched HMS setup authority.').ToLowerInvariant()
    if ($fetched -cne [string]$Authority.commit) { throw "Fetched HMS authority commit mismatch. Expected $($Authority.commit), found $fetched." }
    $fetchedTree = (Invoke-HmsGit -GitExe $GitExe -RepoRoot $repo -Arguments @('rev-parse',($fetched + '^{tree}')) -FailureMessage 'Unable to resolve fetched HMS authority tree.').ToLowerInvariant()
    if ($fetchedTree -cne [string]$Authority.tree) { throw "Fetched HMS authority tree mismatch. Expected $($Authority.tree), found $fetchedTree." }

    $headExists = $true
    $head = ''
    try { $head = (Invoke-HmsGit -GitExe $GitExe -RepoRoot $repo -Arguments @('rev-parse','HEAD') -FailureMessage 'Unable to resolve existing HMS HEAD.').ToLowerInvariant() }
    catch { if ($isExistingRepo) { throw }; $headExists = $false }

    if (-not $headExists) {
        & $GitExe -C $repo checkout -B main $fetched 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to activate exact HMS setup authority on main.' }
    }
    elseif ($head -cne $fetched) {
        if (Test-HmsGitAncestor -GitExe $GitExe -RepoRoot $repo -Older $head -Newer $fetched) {
            & $GitExe -C $repo merge --ff-only $SetupRemoteRef 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to fast-forward HMS checkout to setup authority.' }
        }
        elseif (Test-HmsGitAncestor -GitExe $GitExe -RepoRoot $repo -Older $fetched -Newer $head) {
            & $GitExe -C $repo fetch --no-tags origin 'refs/heads/main:refs/remotes/origin/main' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to verify newer HMS checkout against canonical origin/main.' }
            $originMain = (Invoke-HmsGit -GitExe $GitExe -RepoRoot $repo -Arguments @('rev-parse','refs/remotes/origin/main') -FailureMessage 'Unable to resolve canonical origin/main.').ToLowerInvariant()
            if ($head -cne $originMain) { throw 'Refusing to treat an unverified local descendant as a newer HMS release.' }
            Write-Host "Verified newer HMS checkout present at $head; setup will not downgrade it."
        }
        else { throw 'HMS checkout history diverges from the setup authority.' }
    }

    & $GitExe -C $repo config branch.main.remote origin 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure HMS main remote tracking.' }
    & $GitExe -C $repo config branch.main.merge refs/heads/main 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to configure HMS main merge tracking.' }
    Assert-HmsCleanCheckout -GitExe $GitExe -RepoRoot $repo
    return $repo
}

function Invoke-HmsLifecycleRepair {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$CodexExe
    )
    $launcher = Join-Path $RepoRoot 'HMS-Lifecycle.cmd'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Authenticated HMS lifecycle launcher is missing.' }
    $launcherItem = Get-Item -LiteralPath $launcher -Force
    if (($launcherItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Authenticated HMS lifecycle launcher is a reparse point.' }
    if ($launcher -match '["\r\n]') { throw 'Authenticated HMS lifecycle launcher path is unsafe for cmd.exe.' }

    $cmdExe = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    if (-not (Test-Path -LiteralPath $cmdExe -PathType Leaf)) { throw 'Trusted Windows cmd.exe is missing.' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cmdExe
    $psi.Arguments = ('/d /q /v:off /s /c ""{0}" repair"' -f $launcher)
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['PATH'] = (Split-Path -Parent $GitExe) + ';' + (Split-Path -Parent $CodexExe) + ';' + [Environment]::GetEnvironmentVariable('PATH','Process')
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { throw 'Unable to start authenticated HMS repair.' }
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(900000)) { try { $proc.Kill() } catch {}; throw 'Authenticated HMS repair exceeded the 15-minute setup bound.' }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.TrimEnd() }
        if ($proc.ExitCode -ne 0) { throw "Authenticated HMS repair failed with exit code $($proc.ExitCode): $stderr" }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Warning $stderr.TrimEnd() }
    }
    finally { $proc.Dispose() }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'HMS Windows Setup supports Windows only.' }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'HMS Windows Setup supports x64 Windows only.' }
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1 -or [string]$PSVersionTable.PSEdition -cne 'Desktop') { throw 'HMS Windows Setup requires Windows PowerShell 5.1 Desktop edition.' }
if ([string]::IsNullOrWhiteSpace($env:USERPROFILE) -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'Required Windows user profile paths are unavailable.' }
if (-not (Test-Path -LiteralPath $ToolsLockPath -PathType Leaf)) { throw "Setup tools lock is missing: $ToolsLockPath" }
if (-not (Test-Path -LiteralPath $AuthorityPath -PathType Leaf)) { throw "Setup authority is missing: $AuthorityPath" }

$toolsLock = Get-Content -LiteralPath $ToolsLockPath -Raw | ConvertFrom-Json
$authority = Get-Content -LiteralPath $AuthorityPath -Raw | ConvertFrom-Json
Assert-HmsToolsLock -Lock $toolsLock
Assert-HmsSetupAuthority -Authority $authority
$app = Assert-HmsSafeDirectory -Path $AppRoot -Label 'HMS application root' -AllowCreate
$supportRoot = Assert-HmsSafeDirectory -Path (Join-Path $app 'support') -Label 'HMS support root' -AllowCreate
$gitExe = Ensure-HmsMinGit -Lock $toolsLock.mingit -SupportRoot $supportRoot
$codexExe = Resolve-HmsCodex -Lock $toolsLock.codex -SupportRoot $supportRoot
$repo = Reconcile-HmsCheckout -GitExe $gitExe -Authority $authority -RepoRoot $InstallRoot
if ($Mode -in @('Install','Repair')) { Invoke-HmsLifecycleRepair -RepoRoot $repo -GitExe $gitExe -CodexExe $codexExe }
$finalHead = (Invoke-HmsGit -GitExe $gitExe -RepoRoot $repo -Arguments @('rev-parse','HEAD') -FailureMessage 'Unable to capture final HMS HEAD.').ToLowerInvariant()
Write-Host "PASS: HMS Windows setup bootstrap qualified support tools and checkout. Mode=$Mode HEAD=$finalHead"
