[CmdletBinding()]
param(
    [switch]$EnsureCodeGraphConfig,
    [switch]$EnableCodeGraphIfNew,
    [switch]$RemoveCodeGraphConfig,
    [switch]$SkipCodeGraph,
    [switch]$SkipThreeLevelDelivery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockPath = Join-Path $RepoRoot 'delivery-tools.lock.json'
$CodeGraphRoot = Join-Path $env:USERPROFILE '.codex\codegraph'
$ThreeLevelRoot = Join-Path $env:USERPROFILE '.codex\three-level-delivery'
$CodeGraphManifest = Join-Path $CodeGraphRoot 'hms-codegraph-install.json'
$ManagedBy = 'HMS-Skills-Codex'
$CodeGraphBundleMarkerName = '.hms-codegraph-bundle.json'
$CodeGraphTempMarkerName = '.hms-codegraph-temp.json'

if ($env:OS -ceq 'Windows_NT' -and -not ('HmsDeliveryExactFsNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class HmsDeliveryExactFsNative
{
    [StructLayout(LayoutKind.Sequential)] public struct FILETIME_PARTS { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)] public struct BY_HANDLE_FILE_INFORMATION
    { public uint FileAttributes; public FILETIME_PARTS CreationTime; public FILETIME_PARTS LastAccessTime; public FILETIME_PARTS LastWriteTime; public uint VolumeSerialNumber; public uint FileSizeHigh; public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow; }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr sa,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool GetFileInformationByHandle(SafeFileHandle h,out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SetFileInformationByHandle(SafeFileHandle h,int infoClass,IntPtr info,uint size);
    public static bool RenameByHandle(SafeFileHandle handle,string destination,out int error)
    {
        byte[] nameBytes=Encoding.Unicode.GetBytes(destination);int rootOffset=IntPtr.Size==8?8:4;int lengthOffset=IntPtr.Size==8?16:8;int nameOffset=IntPtr.Size==8?20:12;int minimum=IntPtr.Size==8?24:16;int size=Math.Max(minimum,nameOffset+nameBytes.Length+2);IntPtr buffer=Marshal.AllocHGlobal(size);
        try{for(int i=0;i<size;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteByte(buffer,0,0);Marshal.WriteIntPtr(buffer,rootOffset,IntPtr.Zero);Marshal.WriteInt32(buffer,lengthOffset,nameBytes.Length);Marshal.Copy(nameBytes,0,IntPtr.Add(buffer,nameOffset),nameBytes.Length);bool ok=SetFileInformationByHandle(handle,3,buffer,(uint)size);error=ok?0:Marshal.GetLastWin32Error();return ok;}finally{Marshal.FreeHGlobal(buffer);}
    }
    public static bool DeleteByHandle(SafeFileHandle handle,out int error)
    { IntPtr buffer=Marshal.AllocHGlobal(4);try{Marshal.WriteInt32(buffer,1);bool ok=SetFileInformationByHandle(handle,4,buffer,4);error=ok?0:Marshal.GetLastWin32Error();return ok;}finally{Marshal.FreeHGlobal(buffer);} }
}
'@
}

function Get-HmsDeliveryDirectoryIdentityFromHandle { param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label) $info=New-Object 'HmsDeliveryExactFsNative+BY_HANDLE_FILE_INFORMATION';if(-not[HmsDeliveryExactFsNative]::GetFileInformationByHandle($Handle,[ref]$info)){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "$Label could not read exact directory identity (Win32=$code)."};if(($info.FileAttributes-band[uint32]0x10)-eq 0 -or ($info.FileAttributes-band[uint32]0x400)-ne 0){throw "$Label must be a regular non-reparse directory."};return([string]$info.VolumeSerialNumber+':'+[string]$info.FileIndexHigh+':'+[string]$info.FileIndexLow) }
function Open-HmsDeliveryDirectoryGuard { param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label) if ($env:OS -cne 'Windows_NT'){return $null};$h=[HmsDeliveryExactFsNative]::CreateFileW($Path,[uint32]0x00010000,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero);if ($null -eq $h -or $h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if ($null -ne $h){$h.Dispose()};throw "$Label could not open exact DELETE-capable directory handle (Win32=$code): $Path"};try{$id=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $h -Label $Label;return [pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw} }
function Move-HmsDeliveryDirectoryGuard { param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label) $before=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $Guard.Handle -Label $Label;if ($before -cne [string]$Guard.Identity){throw "$Label exact directory identity changed before rename."};if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"};$code=0;if(-not[HmsDeliveryExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact handle rename failed (Win32=$code): $Destination"};$after=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename";if ($after -cne [string]$Guard.Identity){throw "$Label exact directory identity changed across rename."};$Guard.Path=$Destination }
function Get-HmsDeliveryPortableDirectoryIdentity {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$Label portable identity requires a regular non-reparse directory: $Path"
    }

    $kernel = [string](& uname -s 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kernel)) {
        throw "$Label could not identify the non-Windows kernel for filesystem identity."
    }
    if ($kernel.Trim() -ceq 'Linux') {
        $values = @(& stat -Lc '%d:%i' -- $Path 2>$null)
    }
    elseif ($kernel.Trim() -ceq 'Darwin') {
        $values = @(& stat -f '%d:%i' $Path 2>$null)
    }
    else {
        throw "$Label does not support portable filesystem identity on kernel '$($kernel.Trim())'."
    }
    if ($LASTEXITCODE -ne 0 -or $values.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$values[0])) {
        throw "$Label could not capture portable device/inode identity: $Path"
    }
    return ([string]$values[0]).Trim()
}

function Invoke-HmsDeliveryExactDirectoryRemoval {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$QuarantinePrefix,[Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][scriptblock]$Validate)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    if ($env:OS -cne 'Windows_NT') {
        $ownedIdentity = Get-HmsDeliveryPortableDirectoryIdentity -Path $Path -Label $Label
        &$Validate $Path
        $q = Join-Path (Split-Path -Parent $Path) ($QuarantinePrefix + [guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $q) { throw "$Label portable quarantine destination is occupied: $q" }
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $q) -ErrorAction Stop
        if ((Get-HmsDeliveryPortableDirectoryIdentity -Path $q -Label "$Label post-rename") -cne $ownedIdentity) { throw "$Label portable directory identity changed across quarantine rename: $q" }
        &$Validate $q

        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) {
            if ((Get-HmsDeliveryPortableDirectoryIdentity -Path $q -Label "$Label pre-child-delete") -cne $ownedIdentity) { throw "$Label portable quarantine root identity changed before child deletion: $q" }
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
        if ((Get-HmsDeliveryPortableDirectoryIdentity -Path $q -Label "$Label pre-root-delete") -cne $ownedIdentity) { throw "$Label portable quarantine root identity changed before empty-root deletion: $q" }
        if (@(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop).Count -ne 0) { throw "$Label portable quarantine root is not empty after child deletion: $q" }
        Remove-Item -LiteralPath $q -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $q) { throw "$Label portable quarantine root remained after empty-root deletion: $q" }
        return
    }

    $guard = Open-HmsDeliveryDirectoryGuard -Path $Path -Label $Label
    $renamed = $false
    $deleteStarted = $false
    $q = Join-Path (Split-Path -Parent $Path) ($QuarantinePrefix + [guid]::NewGuid().ToString('N'))
    try {
        &$Validate $Path
        Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $q -Label $Label
        $renamed = $true
        &$Validate $q
        $deleteStarted = $true
        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) { Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop }
        $code = 0
        if (-not [HmsDeliveryExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)) { throw "$Label exact root delete-pending transition failed (Win32=$code): $q" }
        $guard.Handle.Dispose()
        $guard.Handle = $null
        if (Test-Path -LiteralPath $q) { throw "$Label exact quarantine remained after handle deletion: $q" }
    }
    catch {
        $e = $_
        if (-not $deleteStarted -and $renamed -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and -not (Test-Path -LiteralPath $Path)) {
            try { Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $Path -Label "$Label pre-delete rollback" } catch {}
        }
        elseif ($deleteStarted -and (Test-Path -LiteralPath $q)) {
            throw "$Label deletion failed after destructive child removal started; exact quarantined remainder was not restored: $q. Original: $($e.Exception.Message)"
        }
        throw $e
    }
    finally { if ($null -ne $guard -and $null -ne $guard.Handle) { $guard.Handle.Dispose() } }
}


function ConvertTo-NormalizedRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    return $value.ToLowerInvariant()
}

function Read-ValidatedDeliveryLock {
    if (-not (Test-Path -LiteralPath $LockPath)) { throw "Delivery tools lock file not found: $LockPath" }
    try { $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json }
    catch { throw "Delivery tools lock file is invalid JSON: $($_.Exception.Message)" }

    $cg = $lock.codegraph
    $tld = $lock.three_level_delivery
    if ($null -eq $cg -or $null -eq $tld) { throw 'delivery-tools.lock.json must contain codegraph and three_level_delivery.' }

    if ([string]$cg.repository -cne 'https://github.com/colbymchenry/codegraph') { throw "Unexpected CodeGraph repository in lock: $($cg.repository)" }
    if ([string]$cg.version -cne '1.6.0' -or [string]$cg.tag -cne 'v1.6.0') { throw 'Unexpected CodeGraph version/tag in lock.' }
    if ([string]$cg.commit -cne 'dfccdf62547fcd76d343344d823a0e1998d3a89f') { throw "Unexpected CodeGraph commit in lock: $($cg.commit)" }
    if ([string]$cg.mcp_server -cne 'codegraph') { throw "Unexpected CodeGraph MCP name in lock: $($cg.mcp_server)" }
    foreach ($arch in @('x64', 'arm64')) {
        $asset = $cg.windows_assets.$arch
        if ($null -eq $asset) { throw "Missing CodeGraph Windows asset for $arch" }
        if ([string]$asset.sha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid CodeGraph SHA-256 for $arch" }
    }

    if ([string]$tld.repository -cne 'https://github.com/nguyenduytamgithub/three-level-delivery.git') { throw "Unexpected Three-Level Delivery repository in lock: $($tld.repository)" }
    if ([string]$tld.version -cne '0.1.4' -or [string]$tld.tag -cne 'v0.1.4') { throw 'Unexpected Three-Level Delivery version/tag in lock.' }
    if ([string]$tld.commit -cne '667d15066784dd192e34efdff432ad47ae2298a9') { throw "Unexpected Three-Level Delivery commit in lock: $($tld.commit)" }
    if ([string]$tld.skill_path -cne 'three-level-delivery' -or [string]$tld.skill_name -cne 'three-level-delivery') { throw 'Unexpected Three-Level Delivery skill contract in lock.' }
    return $lock
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

function Sync-ThreeLevelDeliverySource {
    param([Parameter(Mandatory)]$Spec)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git.exe is required for Three-Level Delivery source pinning.' }
    if (Test-Path -LiteralPath $ThreeLevelRoot) {
        if (-not (Test-Path -LiteralPath (Join-Path $ThreeLevelRoot '.git'))) { throw "Refusing to overwrite existing non-Git Three-Level Delivery path: $ThreeLevelRoot" }
        Assert-ExpectedOrigin -Path $ThreeLevelRoot -ExpectedRemote ([string]$Spec.repository)
        $dirty = & git -C $ThreeLevelRoot status --porcelain
        if ($LASTEXITCODE -ne 0) { throw "git status failed for $ThreeLevelRoot" }
        if ($dirty) { throw "Refusing to reconcile dirty Three-Level Delivery source: $ThreeLevelRoot" }
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ThreeLevelRoot) | Out-Null
        & git clone ([string]$Spec.repository) $ThreeLevelRoot
        if ($LASTEXITCODE -ne 0) { throw 'Three-Level Delivery clone failed.' }
        Assert-ExpectedOrigin -Path $ThreeLevelRoot -ExpectedRemote ([string]$Spec.repository)
    }

    & git -C $ThreeLevelRoot fetch --tags --prune ([string]$Spec.repository)
    if ($LASTEXITCODE -ne 0) { throw 'Three-Level Delivery fetch failed.' }
    & git -C $ThreeLevelRoot cat-file -e "$([string]$Spec.commit)^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Pinned Three-Level Delivery commit is unavailable: $($Spec.commit)" }
    $tagCommit = (& git -C $ThreeLevelRoot rev-list -n 1 ([string]$Spec.tag)).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $tagCommit -ne [string]$Spec.commit) { throw "Three-Level Delivery tag/commit mismatch. Expected $($Spec.tag) -> $($Spec.commit), found $tagCommit" }
    & git -C $ThreeLevelRoot checkout --detach ([string]$Spec.commit)
    if ($LASTEXITCODE -ne 0) { throw 'Three-Level Delivery pinned checkout failed.' }
    $head = (& git -C $ThreeLevelRoot rev-parse HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -ne [string]$Spec.commit) { throw "Three-Level Delivery HEAD mismatch. Expected $($Spec.commit), found $head" }

    $skillFile = Join-Path (Join-Path $ThreeLevelRoot ([string]$Spec.skill_path)) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile)) { throw "Three-Level Delivery canonical SKILL.md is missing: $skillFile" }
    $text = Get-Content -LiteralPath $skillFile -Raw
    $frontmatter = [regex]::Match($text, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n')
    if (-not $frontmatter.Success) { throw 'Three-Level Delivery canonical skill frontmatter is missing.' }
    $fm = $frontmatter.Groups[1].Value
    $name = [regex]::Match($fm, '(?m)^name:\s*([^\r\n]+?)\s*$')
    $version = [regex]::Match($fm, '(?m)^\s*version:\s*["'']?([^"''\r\n]+)["'']?\s*$')
    $repository = [regex]::Match($fm, '(?m)^\s*repository:\s*["'']?([^"''\r\n]+)["'']?\s*$')
    if (-not $name.Success -or $name.Groups[1].Value.Trim() -cne [string]$Spec.skill_name) { throw 'Three-Level Delivery canonical skill name mismatch.' }
    if (-not $version.Success -or $version.Groups[1].Value.Trim() -cne [string]$Spec.version) { throw 'Three-Level Delivery canonical skill version mismatch.' }
    if (-not $repository.Success -or (ConvertTo-NormalizedRemote $repository.Groups[1].Value.Trim()) -ne (ConvertTo-NormalizedRemote ([string]$Spec.repository))) { throw 'Three-Level Delivery canonical repository metadata mismatch.' }

    $dirtyAfter = & git -C $ThreeLevelRoot status --porcelain
    if ($LASTEXITCODE -ne 0 -or $dirtyAfter) { throw 'Three-Level Delivery source is not clean after pin qualification.' }
    Write-Host "Three-Level Delivery pin: $head"
}

function Get-CodeGraphArchitecture {
    $raw = $null
    try { $raw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }
    catch { $raw = [string]$env:PROCESSOR_ARCHITECTURE }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Unable to determine Windows architecture for CodeGraph.' }
    switch -Regex ($raw.ToLowerInvariant()) {
        'arm64' { return 'arm64' }
        'amd64|x64' { return 'x64' }
        default { throw "Unsupported Windows architecture for pinned CodeGraph bundle: $raw" }
    }
}

function Read-ManagedCodeGraphManifest {
    if (-not (Test-Path -LiteralPath $CodeGraphRoot)) { return $null }
    if (-not (Test-Path -LiteralPath $CodeGraphManifest)) {
        throw "Refusing to overwrite existing CodeGraph path not owned by HMS Skills Codex: $CodeGraphRoot"
    }
    try { $manifest = Get-Content -LiteralPath $CodeGraphManifest -Raw | ConvertFrom-Json }
    catch { throw "Managed CodeGraph manifest is invalid JSON: $($_.Exception.Message)" }
    if ([string]$manifest.managed_by -cne $ManagedBy) { throw "Unexpected CodeGraph installation owner at $CodeGraphRoot" }
    return $manifest
}

function Assert-CodeGraphVersion {
    param(
        [Parameter(Mandatory)][string]$CommandPath,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    if (-not (Test-Path -LiteralPath $CommandPath)) { throw "CodeGraph launcher missing: $CommandPath" }
    $item = Get-Item -LiteralPath $CommandPath -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "CodeGraph launcher must be a regular non-reparse file: $CommandPath" }
    $output = (& $CommandPath --version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "CodeGraph --version failed: $output" }
    if ($output -notmatch [regex]::Escape($ExpectedVersion)) { throw "Unexpected CodeGraph version output. Expected $ExpectedVersion, found: $output" }
}

function Assert-RegularCodeGraphBundle {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not [bool]$item.PSIsContainer) { throw "$Label is not a directory: $Path" }
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "$Label must not be a reparse point: $Path" }
}

function Add-CodeGraphBundleTreeRecords {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LogicalPrefix,
        [Parameter(Mandatory)]$Records
    )
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
        if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "CodeGraph bundle tree contains a reparse point: $($item.FullName)" }
        $logical = if ([string]::IsNullOrEmpty($LogicalPrefix)) { [string]$item.Name } else { $LogicalPrefix + "/" + [string]$item.Name }
        if ([bool]$item.PSIsContainer) {
            Add-CodeGraphBundleTreeRecords -Directory $item.FullName -LogicalPrefix $logical -Records $Records
            continue
        }
        if ([string]::IsNullOrEmpty($LogicalPrefix) -and [string]$item.Name -ceq $CodeGraphBundleMarkerName) { continue }
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $Records.Add($logical + "`t" + $hash)
    }
}

function Get-CodeGraphBundleTreeSha256 {
    param([Parameter(Mandatory)][string]$Path)
    Assert-RegularCodeGraphBundle -Path $Path -Label "CodeGraph bundle tree"
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $records = New-Object System.Collections.Generic.List[string]
    Add-CodeGraphBundleTreeRecords -Directory $root -LogicalPrefix "" -Records $records
    if ($records.Count -eq 0) { throw "CodeGraph bundle tree contains no authenticated files: $Path" }
    $sorted = [string[]]@($records)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $payload = [string]::Join("`n", $sorted)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function New-CodeGraphBundleIdentity {
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$Asset,
        [Parameter(Mandatory)][string]$Sha256,
        [string]$BundleTreeSha256
    )
    return [ordered]@{
        schema_version = 1
        managed_by = $ManagedBy
        artifact = 'hms-codegraph-transaction-bundle'
        transaction_id = $TransactionId
        role = $Role
        version = $Version
        tag = $Tag
        commit = $Commit
        asset = $Asset
        sha256 = $Sha256
        bundle_tree_sha256 = $BundleTreeSha256
    }
}

function Write-CodeGraphBundleMarker {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Identity)
    Assert-RegularCodeGraphBundle -Path $Path -Label 'CodeGraph transaction bundle'
    $treeHash = [string]$Identity['bundle_tree_sha256']
    if ([string]::IsNullOrWhiteSpace($treeHash)) {
        $treeHash = Get-CodeGraphBundleTreeSha256 -Path $Path
        $Identity['bundle_tree_sha256'] = $treeHash
    }
    if ($treeHash -notmatch '^[0-9a-f]{64}$') { throw "CodeGraph transaction identity has invalid bundle tree SHA-256: $treeHash" }
    $markerPath = Join-Path $Path $CodeGraphBundleMarkerName
    $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $markerItem -and ([bool]$markerItem.PSIsContainer -or [bool]($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "CodeGraph transaction marker must be a regular non-reparse file before publication: $markerPath"
    }
    $publishParent = Split-Path -Parent $Path
    $publishTemp = Join-Path $publishParent ('.hms-codegraph-marker-publish-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = $Identity | ConvertTo-Json -Depth 4
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + "`n")
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($publishTemp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if ($null -eq $markerItem) {
        # Same-volume File.Move publishes a new marker without exposing a partial canonical file.
        [IO.File]::Move($publishTemp,$markerPath)
    }
    else {
        # ReplaceFile semantics keep the previous canonical marker intact if publication fails.
        # On failure the random temp file is intentionally retained rather than pathname-deleted.
        [IO.File]::Replace($publishTemp,$markerPath,$null,$true)
    }
}

function Assert-CodeGraphTransactionBundle {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Identity)
    Assert-RegularCodeGraphBundle -Path $Path -Label 'CodeGraph transaction bundle'
    $markerPath = Join-Path $Path $CodeGraphBundleMarkerName
    $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $markerItem -or [bool]$markerItem.PSIsContainer -or [bool]($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "CodeGraph transaction marker is missing or not a regular file: $Path"
    }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json }
    catch { throw "CodeGraph transaction marker is invalid JSON: $Path" }
    foreach ($field in @('managed_by','artifact','transaction_id','role','version','tag','commit','asset','sha256')) {
        if ([string]$marker.$field -cne [string]$Identity[$field]) { throw "CodeGraph transaction marker mismatch for '$field': $Path" }
    }
    $expectedTree = [string]$Identity['bundle_tree_sha256']
    if (-not [string]::IsNullOrWhiteSpace($expectedTree)) {
        if ($expectedTree -notmatch '^[0-9a-f]{64}$') { throw "CodeGraph expected bundle tree SHA-256 is invalid: $Path" }
        if ([string]$marker.bundle_tree_sha256 -cne $expectedTree) { throw "CodeGraph transaction marker tree SHA-256 mismatch: $Path" }
        $actualTree = Get-CodeGraphBundleTreeSha256 -Path $Path
        if ($actualTree -cne $expectedTree) { throw "CodeGraph bundle tree SHA-256 mismatch. Expected $expectedTree, found $actualTree : $Path" }
    }
}

function Remove-CodeGraphTransactionBundle {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Identity)
    $assertCodeGraphTransactionBundle = ${function:Assert-CodeGraphTransactionBundle}
    $validator={param($p) & $assertCodeGraphTransactionBundle -Path $p -Identity $Identity}.GetNewClosure()
    Invoke-HmsDeliveryExactDirectoryRemoval -Path $Path -QuarantinePrefix '.hms-codegraph-deleting-' -Label 'CodeGraph transaction bundle cleanup' -Validate $validator
}


function Write-CodeGraphTempMarker {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$TransactionId)
    Assert-RegularCodeGraphBundle -Path $Path -Label 'CodeGraph temporary root'
    [ordered]@{ schema_version=1; managed_by=$ManagedBy; artifact='hms-codegraph-transaction-temp'; transaction_id=$TransactionId } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Path $CodeGraphTempMarkerName) -Encoding UTF8
}

function Assert-CodeGraphTempRoot {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$TransactionId)
    Assert-RegularCodeGraphBundle -Path $Path -Label 'CodeGraph temporary root'
    $markerPath = Join-Path $Path $CodeGraphTempMarkerName
    $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $markerItem -or [bool]$markerItem.PSIsContainer -or [bool]($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "CodeGraph temporary-root marker is missing or not a regular file: $Path"
    }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json }
    catch { throw "CodeGraph temporary-root marker is invalid JSON: $Path" }
    if ([string]$marker.managed_by -cne $ManagedBy -or [string]$marker.artifact -cne 'hms-codegraph-transaction-temp' -or [string]$marker.transaction_id -cne $TransactionId) {
        throw "CodeGraph temporary-root marker ownership mismatch: $Path"
    }
}

function Remove-CodeGraphTempRoot {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$TransactionId)
    $assertCodeGraphTempRoot = ${function:Assert-CodeGraphTempRoot}
    $validator={param($p) & $assertCodeGraphTempRoot -Path $p -TransactionId $TransactionId}.GetNewClosure()
    Invoke-HmsDeliveryExactDirectoryRemoval -Path $Path -QuarantinePrefix '.hms-codegraph-temp-removing-' -Label 'CodeGraph temporary-root cleanup' -Validate $validator
}


function Restore-CodeGraphManifestAfterFailure {
    param(
        [Parameter(Mandatory)]$CandidateManifest,
        [byte[]]$PreviousBytes,
        [Parameter(Mandatory)][bool]$HadPrevious
    )
    $item = Get-Item -LiteralPath $CodeGraphManifest -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or [bool]$item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'CodeGraph candidate manifest is missing or not a regular file during rollback.'
    }
    try { $currentManifest = Get-Content -LiteralPath $CodeGraphManifest -Raw | ConvertFrom-Json }
    catch { throw "CodeGraph candidate manifest is invalid during rollback: $($_.Exception.Message)" }
    foreach ($field in @('managed_by','version','tag','commit','asset','sha256','bundle_transaction_id','bundle_tree_sha256')) {
        if ([string]$currentManifest.$field -cne [string]$CandidateManifest[$field]) {
            throw "CodeGraph candidate manifest changed before rollback for '$field'; refusing to overwrite it."
        }
    }
    if ($HadPrevious) {
        if ($null -eq $PreviousBytes) { throw 'CodeGraph rollback is missing previous manifest bytes.' }
        $parent = Split-Path -Parent $CodeGraphManifest
        $temp = Join-Path $parent ('.hms-codegraph-manifest-restore-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $discard = Join-Path $parent ('.hms-codegraph-manifest-discard-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($temp, $PreviousBytes)
            [IO.File]::Replace($temp, $CodeGraphManifest, $discard, $true)
        }
        finally {
            foreach ($cleanup in @($temp,$discard)) { if (Test-Path -LiteralPath $cleanup) { Remove-Item -LiteralPath $cleanup -Force -ErrorAction SilentlyContinue } }
        }
    }
    else {
        Remove-Item -LiteralPath $CodeGraphManifest -Force
    }
}

function Repair-CodeGraphRollbackState {
    param(
        [Parameter(Mandatory)][string]$CurrentPath,
        [string]$BackupPath,
        [Parameter(Mandatory)]$CandidateIdentity,
        $BackupIdentity,
        $PreviousIdentity,
        [Parameter(Mandatory)][bool]$ManifestPublished,
        $PublishedManifest,
        [byte[]]$PreviousManifestBytes,
        [Parameter(Mandatory)][bool]$HadPrevious,
        [scriptblock]$CandidateRemovalAction
    )

    $rollbackErrors = @()
    $candidateRemovalCompleted = $false
    $backupActivated = $false
    $candidatePreserved = $false
    $currentBundleState = 'absent'
    $canRestorePrevious = $false
    $reservedBackupPath = $null
    $reservedBackupGuard = $null

    if ($HadPrevious -and $null -ne $BackupIdentity -and -not [string]::IsNullOrWhiteSpace($BackupPath) -and (Test-Path -LiteralPath $BackupPath)) {
        $reservationGuard = $null
        try {
            $reservationGuard = Open-HmsDeliveryDirectoryGuard -Path $BackupPath -Label 'CodeGraph rollback reservation'
            Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
            $reserveLeaf = '.hms-codegraph-rollback-reserved-' + [guid]::NewGuid().ToString('N')
            $reservedBackupPath = Join-Path (Split-Path -Parent $BackupPath) $reserveLeaf
            Move-HmsDeliveryDirectoryGuard -Guard $reservationGuard -Destination $reservedBackupPath -Label 'CodeGraph rollback reservation'
            Assert-CodeGraphTransactionBundle -Path $reservedBackupPath -Identity $BackupIdentity
            $reservedBackupGuard = $reservationGuard
            $reservationGuard = $null
            $canRestorePrevious = $true
        }
        catch {
            $rollbackErrors += "CodeGraph backup reservation failed before candidate removal: $($_.Exception.Message)"
            if ($null -ne $reservationGuard -and $null -ne $reservationGuard.Handle -and -not $reservationGuard.Handle.IsClosed) {
                try {
                    if ([string]$reservationGuard.Path -cne $BackupPath -and -not (Test-Path -LiteralPath $BackupPath)) { Move-HmsDeliveryDirectoryGuard -Guard $reservationGuard -Destination $BackupPath -Label 'CodeGraph backup reservation rollback' }
                } catch { $rollbackErrors += "CodeGraph backup reservation rollback failed: $($_.Exception.Message)" }
                $reservationGuard.Handle.Dispose()
            }
        }
    }

    if ($canRestorePrevious -or -not $HadPrevious) {
        try {
            if (Test-Path -LiteralPath $CurrentPath) {
                if ($null -ne $CandidateRemovalAction) {
                    & $CandidateRemovalAction $CurrentPath $CandidateIdentity
                }
                else {
                    Remove-CodeGraphTransactionBundle -Path $CurrentPath -Identity $CandidateIdentity
                }
            }
            $candidateRemovalCompleted = -not (Test-Path -LiteralPath $CurrentPath)
        }
        catch {
            $rollbackErrors += $_.Exception.Message
            $candidateRemovalCompleted = -not (Test-Path -LiteralPath $CurrentPath)
        }
    }

    if ($canRestorePrevious -and -not $candidateRemovalCompleted -and $null -ne $reservedBackupGuard) {
        try {
            Assert-CodeGraphTransactionBundle -Path $reservedBackupPath -Identity $BackupIdentity
            if (Test-Path -LiteralPath $BackupPath) { throw "Cannot return reserved CodeGraph backup because the original backup pathname became occupied: $BackupPath" }
            Move-HmsDeliveryDirectoryGuard -Guard $reservedBackupGuard -Destination $BackupPath -Label 'CodeGraph reserved backup return after candidate preservation'
            Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
            $reservedBackupPath = $null
            $reservedBackupGuard.Handle.Dispose(); $reservedBackupGuard = $null
        }
        catch { $rollbackErrors += "CodeGraph reserved backup could not be returned after candidate preservation: $($_.Exception.Message)" }
    }

    if ($canRestorePrevious -and $candidateRemovalCompleted) {
        try {
            if ($null -eq $reservedBackupGuard -or $reservedBackupGuard.Handle.IsClosed) { throw 'CodeGraph exact reserved-backup handle disappeared before rollback activation.' }
            Assert-CodeGraphTransactionBundle -Path $reservedBackupPath -Identity $BackupIdentity
            if ($null -eq $PreviousIdentity) { throw 'CodeGraph previous candidate identity is unavailable before rollback activation.' }
            if (Test-Path -LiteralPath $CurrentPath) { throw "Cannot restore CodeGraph backup because current became occupied: $CurrentPath" }
            Move-HmsDeliveryDirectoryGuard -Guard $reservedBackupGuard -Destination $CurrentPath -Label 'CodeGraph rollback activation'
            Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $BackupIdentity
            Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $PreviousIdentity
            Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $PreviousIdentity
            $backupActivated = $true
            $reservedBackupPath = $null
            $reservedBackupGuard.Handle.Dispose(); $reservedBackupGuard = $null
        }
        catch { $rollbackErrors += $_.Exception.Message }
    }

    if (Test-Path -LiteralPath $CurrentPath) {
        try {
            Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $CandidateIdentity
            $currentBundleState = 'candidate'
            $candidatePreserved = $true
        }
        catch {
            if ($HadPrevious -and $null -ne $PreviousIdentity) {
                try {
                    Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $PreviousIdentity
                    $currentBundleState = 'previous'
                    $backupActivated = $true
                }
                catch {
                    $rollbackErrors += "Active CodeGraph current bundle matches neither candidate nor previous transaction identity: $($_.Exception.Message)"
                    $currentBundleState = 'unknown'
                }
            }
            else {
                $rollbackErrors += "Active CodeGraph current bundle does not match the candidate transaction identity: $($_.Exception.Message)"
                $currentBundleState = 'unknown'
            }
        }
    }

    if ($ManifestPublished) {
        try {
            if ($currentBundleState -ceq 'previous') {
                Restore-CodeGraphManifestAfterFailure -CandidateManifest $PublishedManifest -PreviousBytes $PreviousManifestBytes -HadPrevious $true
            }
            elseif ($currentBundleState -ceq 'candidate') {
                # Candidate remains the active verified bundle, so its already-published manifest remains authoritative.
            }
            else {
                Restore-CodeGraphManifestAfterFailure -CandidateManifest $PublishedManifest -PreviousBytes $null -HadPrevious $false
            }
        }
        catch { $rollbackErrors += $_.Exception.Message }
    }

    if ($null -ne $reservedBackupGuard -and $null -ne $reservedBackupGuard.Handle) { $reservedBackupGuard.Handle.Dispose(); $reservedBackupGuard = $null }

    return [pscustomobject]@{
        RollbackErrors = @($rollbackErrors)
        CandidateRemovalCompleted = $candidateRemovalCompleted
        BackupActivated = $backupActivated
        CandidatePreserved = $candidatePreserved
        CurrentBundleState = $currentBundleState
        ReservedBackupPath = $reservedBackupPath
    }
}

function Assert-CodeGraphBundleAgainstManifest {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Manifest)
    Assert-RegularCodeGraphBundle -Path $Path -Label 'Existing HMS CodeGraph bundle'
    foreach ($field in @('version','tag','commit','asset','sha256','bundle_transaction_id','bundle_tree_sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$Manifest.$field)) { throw "Managed CodeGraph manifest is missing '$field'." }
    }
    if ([string]$Manifest.bundle_transaction_id -notmatch '^[0-9a-f]{32}$') { throw 'Managed CodeGraph manifest has an invalid bundle transaction ID.' }
    if ([string]$Manifest.bundle_tree_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Managed CodeGraph manifest has an invalid bundle tree SHA-256.' }
    $identity = New-CodeGraphBundleIdentity -TransactionId ([string]$Manifest.bundle_transaction_id) -Role 'candidate' -Version ([string]$Manifest.version) -Tag ([string]$Manifest.tag) -Commit ([string]$Manifest.commit) -Asset ([string]$Manifest.asset) -Sha256 ([string]$Manifest.sha256) -BundleTreeSha256 ([string]$Manifest.bundle_tree_sha256)
    Assert-CodeGraphTransactionBundle -Path $Path -Identity $identity
    return $identity
}

function Move-CodeGraphCurrentToRollbackBackup {
    param(
        [Parameter(Mandatory)][string]$CurrentPath,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)]$ExistingManifest,
        [Parameter(Mandatory)]$BackupIdentity,
        [ref]$PreviousIdentityRef
    )
    if (-not (Test-Path -LiteralPath $CurrentPath)) { throw "CodeGraph current bundle disappeared before backup preparation: $CurrentPath" }
    if (Test-Path -LiteralPath $BackupPath) { throw "CodeGraph rollback backup path is already occupied: $BackupPath" }

    # Authenticate the existing bundle from the root-manifest-pinned transaction marker and
    # deterministic tree hash before touching or executing any bytes beneath current.
    $existingIdentity = Assert-CodeGraphBundleAgainstManifest -Path $CurrentPath -Manifest $ExistingManifest
    if ($null -ne $PreviousIdentityRef) { $PreviousIdentityRef.Value = $existingIdentity }

    $markerRewritten = $false
    try {
        Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $BackupIdentity
        $markerRewritten = $true
        Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $BackupIdentity
        Move-Item -LiteralPath $CurrentPath -Destination $BackupPath
        # Path-independent validation only. Never execute a launcher from a randomized backup path.
        Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
    }
    catch {
        $transitionError = $_
        if ($markerRewritten -and (Test-Path -LiteralPath $CurrentPath) -and -not (Test-Path -LiteralPath $BackupPath)) {
            try {
                Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $existingIdentity
                Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $existingIdentity
            }
            catch {
                throw "CodeGraph current-to-backup transition failed and original marker restoration was incomplete. Original: $($transitionError.Exception.Message). Rollback: $($_.Exception.Message)"
            }
        }
        throw $transitionError
    }
    return $existingIdentity
}

function Sync-CodeGraphBundle {
    param([Parameter(Mandatory)]$Spec)

    if ($env:OS -ne 'Windows_NT') { throw 'The HMS pinned CodeGraph bundle installer currently supports Windows only.' }
    $existingManifest = Read-ManagedCodeGraphManifest
    $wasInstalled = $null -ne $existingManifest
    $existingManifestBytes = $null
    if ($wasInstalled) {
        $manifestItem = Get-Item -LiteralPath $CodeGraphManifest -Force -ErrorAction Stop
        if ([bool]$manifestItem.PSIsContainer -or [bool]($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Managed CodeGraph manifest must be a regular file.' }
        $existingManifestBytes = [IO.File]::ReadAllBytes($CodeGraphManifest)
    }
    $arch = Get-CodeGraphArchitecture
    $asset = $Spec.windows_assets.$arch
    $assetName = [string]$asset.name
    $expectedSha = [string]$asset.sha256
    $current = Join-Path $CodeGraphRoot 'current'
    $command = Join-Path $current 'bin\codegraph.cmd'

    $alreadyExact = $false
    if ($wasInstalled -and (Test-Path -LiteralPath $current)) {
        if ([string]$existingManifest.version -ceq [string]$Spec.version -and
            [string]$existingManifest.tag -ceq [string]$Spec.tag -and
            [string]$existingManifest.commit -ceq [string]$Spec.commit -and
            [string]$existingManifest.asset -ceq $assetName -and
            [string]$existingManifest.sha256 -ceq $expectedSha) {
            $null = Assert-CodeGraphBundleAgainstManifest -Path $current -Manifest $existingManifest
            $alreadyExact = $true
        }
    }

    if (-not $alreadyExact) {
        $transactionId = [guid]::NewGuid().ToString('N')
        $temp = Join-Path $env:TEMP ("hms-codegraph-" + [guid]::NewGuid().ToString('N'))
        $zip = Join-Path $temp $assetName
        $extract = Join-Path $temp 'extract'
        $candidate = $extract
        $backup = $null
        $candidateIdentity = $null
        $backupIdentity = $null
        $previousIdentity = $null
        $manifestPublished = $false
        $publishedManifest = $null
        try {
            New-Item -ItemType Directory -Force -Path $temp | Out-Null
            Write-CodeGraphTempMarker -Path $temp -TransactionId $transactionId
            Assert-CodeGraphTempRoot -Path $temp -TransactionId $transactionId
            New-Item -ItemType Directory -Force -Path $extract | Out-Null
            $url = "https://github.com/colbymchenry/codegraph/releases/download/$([string]$Spec.tag)/$assetName"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
            $actualSha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualSha -ne $expectedSha) { throw "CodeGraph release asset SHA-256 mismatch. Expected $expectedSha, found $actualSha" }
            Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

            $inner = Join-Path $extract ("codegraph-win32-" + $arch)
            if (Test-Path -LiteralPath $inner) {
                $flat = Join-Path $temp 'flat'
                New-Item -ItemType Directory -Force -Path $flat | Out-Null
                Get-ChildItem -LiteralPath $inner -Force | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $flat -Force }
                $candidate = $flat
            }
            $candidateCommand = Join-Path $candidate 'bin\codegraph.cmd'
            # Execution is allowed only here, while bytes are still inside the freshly downloaded,
            # exact-SHA-qualified release candidate. Persisted/renamed bundles are validated by bytes only.
            Assert-CodeGraphVersion -CommandPath $candidateCommand -ExpectedVersion ([string]$Spec.version)
            $candidateTreeSha = Get-CodeGraphBundleTreeSha256 -Path $candidate
            $candidateIdentity = New-CodeGraphBundleIdentity -TransactionId $transactionId -Role 'candidate' -Version ([string]$Spec.version) -Tag ([string]$Spec.tag) -Commit ([string]$Spec.commit) -Asset $assetName -Sha256 $expectedSha -BundleTreeSha256 $candidateTreeSha
            Write-CodeGraphBundleMarker -Path $candidate -Identity $candidateIdentity
            Assert-CodeGraphTransactionBundle -Path $candidate -Identity $candidateIdentity

            New-Item -ItemType Directory -Force -Path $CodeGraphRoot | Out-Null
            try {
                if (Test-Path -LiteralPath $current) {
                    if ($null -eq $existingManifest) { throw 'Existing CodeGraph current bundle has no HMS ownership manifest.' }
                    $backup = Join-Path $CodeGraphRoot ("backup-" + [guid]::NewGuid().ToString('N'))
                    $backupIdentity = New-CodeGraphBundleIdentity -TransactionId $transactionId -Role 'backup' -Version ([string]$existingManifest.version) -Tag ([string]$existingManifest.tag) -Commit ([string]$existingManifest.commit) -Asset ([string]$existingManifest.asset) -Sha256 ([string]$existingManifest.sha256) -BundleTreeSha256 ([string]$existingManifest.bundle_tree_sha256)
                    $previousIdentity = Move-CodeGraphCurrentToRollbackBackup -CurrentPath $current -BackupPath $backup -ExistingManifest $existingManifest -BackupIdentity $backupIdentity -PreviousIdentityRef ([ref]$previousIdentity)
                    if ($env:HMS_TEST_FAIL_CODEGRAPH_AFTER_BACKUP_RENAME -ceq '1') { throw 'Injected CodeGraph failure after previous current crossed the backup rename boundary.' }
                }

                Move-Item -LiteralPath $candidate -Destination $current
                Assert-CodeGraphTransactionBundle -Path $current -Identity $candidateIdentity
                $publishedManifest = [ordered]@{
                    managed_by = $ManagedBy
                    version = [string]$Spec.version
                    tag = [string]$Spec.tag
                    commit = [string]$Spec.commit
                    asset = $assetName
                    sha256 = $expectedSha
                    bundle_transaction_id = $transactionId
                    bundle_tree_sha256 = [string]$candidateIdentity.bundle_tree_sha256
                }
                $manifestTemp = Join-Path $CodeGraphRoot ('.hms-codegraph-manifest-' + $transactionId + '.tmp')
                $publishedManifest | ConvertTo-Json | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
                if ($wasInstalled) { [IO.File]::Replace($manifestTemp, $CodeGraphManifest, $null, $true) }
                else { [IO.File]::Move($manifestTemp, $CodeGraphManifest) }
                $manifestPublished = $true
                if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                    Remove-CodeGraphTransactionBundle -Path $backup -Identity $backupIdentity
                }
            }
            catch {
                $installError = $_
                if ($null -eq $candidateIdentity) { throw $installError }
                $rollback = Repair-CodeGraphRollbackState -CurrentPath $current -BackupPath $backup -CandidateIdentity $candidateIdentity -BackupIdentity $backupIdentity -PreviousIdentity $previousIdentity -ManifestPublished $manifestPublished -PublishedManifest $publishedManifest -PreviousManifestBytes $existingManifestBytes -HadPrevious $wasInstalled
                $rollbackErrors = @($rollback.RollbackErrors)
                if ($rollbackErrors.Count -gt 0) {
                    throw "CodeGraph installation failed and rollback was incomplete. Original: $($installError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')"
                }
                throw $installError
            }
        }
        finally {
            if (Test-Path -LiteralPath $temp) { Remove-CodeGraphTempRoot -Path $temp -TransactionId $transactionId }
        }
    }

    return [pscustomobject]@{ WasInstalled = $wasInstalled; Command = $command }
}

function Get-CodexMcpEntry {
    param([Parameter(Mandatory)][string]$Name)
    $codex = Get-Command codex -ErrorAction Stop
    $jsonText = (& $codex.Source mcp list --json 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "codex mcp list --json failed; refusing MCP config mutation: $jsonText" }
    try { $decoded = $jsonText | ConvertFrom-Json }
    catch { throw "codex mcp list returned invalid JSON: $($_.Exception.Message)" }
    $matches = @(@($decoded) | Where-Object { [string]$_.name -ceq $Name })
    if ($matches.Count -gt 1) { throw "Codex reported duplicate MCP server entries named '$Name'." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Test-ExpectedCodeGraphMcpEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$CommandPath
    )
    if ([string]$Entry.transport.type -cne 'stdio') { return $false }
    $configured = [string]$Entry.transport.command
    try {
        if ([IO.Path]::GetFullPath($configured).TrimEnd('\') -ine [IO.Path]::GetFullPath($CommandPath).TrimEnd('\')) { return $false }
    }
    catch { return $false }
    $args = @($Entry.transport.args)
    if ($args.Count -ne 2 -or [string]$args[0] -cne 'serve' -or [string]$args[1] -cne '--mcp') { return $false }
    return $true
}

function Ensure-CodeGraphMcpConfig {
    param([Parameter(Mandatory)][string]$CommandPath)
    $entry = Get-CodexMcpEntry -Name 'codegraph'
    if ($null -ne $entry) {
        if (-not (Test-ExpectedCodeGraphMcpEntry -Entry $entry -CommandPath $CommandPath)) {
            throw 'Existing Codex MCP server named codegraph is not the HMS-managed pinned CodeGraph command. Refusing to overwrite it.'
        }
        Write-Host 'CodeGraph MCP config already matches the HMS-managed absolute command.'
        return
    }

    $codex = Get-Command codex -ErrorAction Stop
    $output = (& $codex.Source mcp add codegraph -- $CommandPath serve --mcp 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "codex mcp add codegraph failed: $output" }
    $after = Get-CodexMcpEntry -Name 'codegraph'
    if ($null -eq $after -or -not (Test-ExpectedCodeGraphMcpEntry -Entry $after -CommandPath $CommandPath)) {
        throw 'Codex did not preserve the exact HMS-managed CodeGraph MCP command after registration.'
    }
    Write-Host 'CodeGraph MCP config registered through the official Codex CLI.'
}

function Remove-CodeGraphMcpConfig {
    param([Parameter(Mandatory)][string]$CommandPath)
    $entry = Get-CodexMcpEntry -Name 'codegraph'
    if ($null -eq $entry) { return }
    if (-not (Test-ExpectedCodeGraphMcpEntry -Entry $entry -CommandPath $CommandPath)) {
        throw 'Existing Codex MCP server named codegraph is not the HMS-managed pinned command. Refusing to remove it.'
    }
    $codex = Get-Command codex -ErrorAction Stop
    $output = (& $codex.Source mcp remove codegraph 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "codex mcp remove codegraph failed: $output" }
    if ($null -ne (Get-CodexMcpEntry -Name 'codegraph')) { throw 'CodeGraph MCP config remained after Codex reported removal.' }
    Write-Host 'HMS-managed CodeGraph MCP config removed.'
}

$lock = Read-ValidatedDeliveryLock

if ($RemoveCodeGraphConfig) {
    if ($SkipCodeGraph) { throw '-RemoveCodeGraphConfig cannot be combined with -SkipCodeGraph.' }
    $manifest = Read-ManagedCodeGraphManifest
    if ($null -eq $manifest) {
        if ($null -ne (Get-CodexMcpEntry -Name 'codegraph')) { throw 'CodeGraph MCP config exists but the HMS-managed bundle is absent; ownership cannot be proven.' }
        return
    }
    $managedCurrent = Join-Path $CodeGraphRoot 'current'
    $managedCommand = Join-Path $managedCurrent 'bin\codegraph.cmd'
    $null = Assert-CodeGraphBundleAgainstManifest -Path $managedCurrent -Manifest $manifest
    Remove-CodeGraphMcpConfig -CommandPath $managedCommand
    return
}

if (-not $SkipCodeGraph) {
    $cgState = Sync-CodeGraphBundle -Spec $lock.codegraph
    if ($EnsureCodeGraphConfig -or ($EnableCodeGraphIfNew -and -not $cgState.WasInstalled)) {
        Ensure-CodeGraphMcpConfig -CommandPath $cgState.Command
    }
    else {
        $existingEntry = Get-CodexMcpEntry -Name 'codegraph'
        if ($null -ne $existingEntry -and -not (Test-ExpectedCodeGraphMcpEntry -Entry $existingEntry -CommandPath $cgState.Command)) {
            throw 'Existing CodeGraph MCP config conflicts with the HMS-managed pinned installation.'
        }
    }
    Write-Host "CodeGraph pin: $([string]$lock.codegraph.tag) / $([string]$lock.codegraph.commit)"
}

if (-not $SkipThreeLevelDelivery) {
    Sync-ThreeLevelDeliverySource -Spec $lock.three_level_delivery
}

Write-Host 'Pinned delivery tools reconciliation PASS.'