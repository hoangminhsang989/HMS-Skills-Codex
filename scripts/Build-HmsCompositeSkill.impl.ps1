[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [string]$OutputRoot = (Join-Path $env:USERPROFILE '.codex\hms-composite'),
    [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.agents\skills'),
    [bool]$Hms = $true,
    [bool]$Superpowers = $true,
    [bool]$Taste = $true,
    [bool]$Impeccable = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CompositeName = 'hms-superpowers'
$ManagedBy = 'HMS-Skills-Codex'
$Artifact = 'hms-superpowers-composite'
$StageArtifact = 'hms-superpowers-composite-stage'
$FinalRoot = Join-Path $OutputRoot $CompositeName
$CompositeLink = Join-Path $SkillsRoot $CompositeName
$SuperpowersRoot = Join-Path $env:USERPROFILE '.codex\superpowers'
$TasteRoot = Join-Path $env:USERPROFILE '.codex\taste-skill'
$ImpeccableRoot = Join-Path $env:USERPROFILE '.codex\impeccable'
$SuperpowersLockPath = Join-Path $InstallRoot 'superpowers.lock.json'
$UiLockPath = Join-Path $InstallRoot 'ui-skills.lock.json'
$ModelRouterSource = Join-Path $InstallRoot 'skills\hms-model-router'
$ModelDispatcherSource = Join-Path $InstallRoot 'skills\hms-model-dispatcher'
$ModelResolverSource = Join-Path $InstallRoot 'scripts\Resolve-HmsModelRoute.ps1'
$ModelSettingsPath = Join-Path $OutputRoot 'model-settings.json'
$BuildMutexName = 'Local\HMS-Skills-Codex-CompositeBuild-v1'
$CanonicalHmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'

if ($env:OS -ceq 'Windows_NT' -and -not ('HmsCompositeExactFsNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class HmsCompositeExactFsNative
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

function Get-HmsCompositeDirectoryIdentityFromHandle {
    param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label)
    $info=New-Object 'HmsCompositeExactFsNative+BY_HANDLE_FILE_INFORMATION'
    if(-not [HmsCompositeExactFsNative]::GetFileInformationByHandle($Handle,[ref]$info)){ $code=[Runtime.InteropServices.Marshal]::GetLastWin32Error(); throw "$Label could not read exact directory identity (Win32=$code)." }
    if(($info.FileAttributes-band[uint32]0x10)-eq 0 -or ($info.FileAttributes-band[uint32]0x400)-ne 0){throw "$Label must be a regular non-reparse directory."}
    return ([string]$info.VolumeSerialNumber+':'+[string]$info.FileIndexHigh+':'+[string]$info.FileIndexLow)
}
function Open-HmsCompositeDirectoryGuard {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    if($env:OS -cne 'Windows_NT'){return $null}
    $h=[HmsCompositeExactFsNative]::CreateFileW($Path,[uint32]0x00010000,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero)
    if($null-eq$h -or $h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if ($null -ne $h){$h.Dispose()};throw "$Label could not open exact DELETE-capable directory handle (Win32=$code): $Path"}
    try{$id=Get-HmsCompositeDirectoryIdentityFromHandle -Handle $h -Label $Label;return [pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw}
}
function Move-HmsCompositeDirectoryGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label)
    if($env:OS -cne 'Windows_NT'){Rename-Item -LiteralPath $Guard.Path -NewName (Split-Path -Leaf $Destination) -ErrorAction Stop;$Guard.Path=$Destination;return}
    $before=Get-HmsCompositeDirectoryIdentityFromHandle -Handle $Guard.Handle -Label $Label
    if ($before -cne [string]$Guard.Identity){throw "$Label exact directory identity changed before rename."}
    if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"}
    $code=0;if(-not[HmsCompositeExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact handle rename failed (Win32=$code): $Destination"}
    $after=Get-HmsCompositeDirectoryIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename";if ($after -cne [string]$Guard.Identity){throw "$Label exact directory identity changed across rename."};$Guard.Path=$Destination
}

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\')
}

function Normalize-GitRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    return $value.ToLowerInvariant()
}

function Get-GitHeadOrNull {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return $null }
    $head = & git -C $Path rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $value = ($head -join '').Trim().ToLowerInvariant()
    if ($value -notmatch '^[0-9a-f]{40}$') { return $null }
    return $value
}

function Assert-GitSourceIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRepository,
        [string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "$Label source is not a Git checkout: $Path" }

    $origin = (& git -C $Path remote get-url origin 2>$null) -join ''
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($origin)) { throw "$Label source origin could not be read: $Path" }
    if ((Normalize-GitRemote -Remote $origin) -cne (Normalize-GitRemote -Remote $ExpectedRepository)) {
        throw "$Label source origin mismatch. Expected '$ExpectedRepository', found '$($origin.Trim())'."
    }

    $head = Get-GitHeadOrNull -Path $Path
    if ($null -eq $head) { throw "$Label source HEAD is not a canonical 40-hex commit: $Path" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCommit)) {
        $expected = $ExpectedCommit.Trim().ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{40}$') { throw "$Label expected commit is invalid: $ExpectedCommit" }
        if ($head -cne $expected) { throw "$Label source HEAD mismatch. Expected $expected, found $head." }
    }

    $status = (& git -C $Path status --porcelain=v1 --untracked-files=all 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "$Label source clean-state check failed: $Path" }
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw "$Label source is dirty; refusing to compile unreviewed bytes: $Path" }

    return $head
}

function Assert-CopyTreeContainsCommittedBytesOnly {
    param([Parameter(Mandatory)][string]$Source)

    $sourceRoot = Get-CanonicalPath -Path $Source
    $repoTopRaw = ((& git -C $Source rev-parse --show-toplevel 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoTopRaw)) {
        throw "Copy source is not inside a readable Git checkout: $Source"
    }
    $repoRoot = Get-CanonicalPath -Path $repoTopRaw
    $prefix = $repoRoot + '\'
    if ($sourceRoot -ieq $repoRoot) {
        $pathSpec = '.'
    }
    elseif ($sourceRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $pathSpec = $sourceRoot.Substring($prefix.Length).Replace('\','/')
    }
    else {
        throw "Copy source escaped its Git repository root: $Source"
    }

    # `git status --ignored` is deliberate. Ordinary clean checks omit ignored files,
    # but Copy-Item -Recurse would otherwise publish those local-only bytes.
    $status = (& git -C $repoRoot status --porcelain=v1 --untracked-files=all --ignored -- $pathSpec 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Copy-tree Git status failed: $Source" }
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "Copy tree contains non-committed or ignored content; refusing to publish local-only bytes: $Source"
    }
}

function Read-SuperpowersLock {
    if (-not (Test-Path -LiteralPath $SuperpowersLockPath)) { throw "Superpowers lock file not found: $SuperpowersLockPath" }
    try { $lock = Get-Content -LiteralPath $SuperpowersLockPath -Raw | ConvertFrom-Json }
    catch { throw "Superpowers lock is invalid JSON: $($_.Exception.Message)" }
    if ([string]$lock.repository -cne 'https://github.com/obra/superpowers.git') { throw 'Unexpected Superpowers repository in superpowers.lock.json.' }
    if ([string]$lock.commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid Superpowers commit in superpowers.lock.json.' }
    return $lock
}

function Read-UiLock {
    if (-not (Test-Path -LiteralPath $UiLockPath)) { throw "UI skills lock file not found: $UiLockPath" }
    try { $lock = Get-Content -LiteralPath $UiLockPath -Raw | ConvertFrom-Json }
    catch { throw "UI skills lock is invalid JSON: $($_.Exception.Message)" }
    if ([string]$lock.taste.repository -cne 'https://github.com/Leonxlnx/taste-skill.git') { throw 'Unexpected Taste repository in ui-skills.lock.json.' }
    if ([string]$lock.taste.skill_path -cne 'skills/gpt-tasteskill') { throw 'Unexpected Taste skill path in ui-skills.lock.json.' }
    if ([string]$lock.taste.commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid Taste commit in ui-skills.lock.json.' }
    if ([string]$lock.impeccable.repository -cne 'https://github.com/pbakaus/impeccable.git') { throw 'Unexpected Impeccable repository in ui-skills.lock.json.' }
    if ([string]$lock.impeccable.skill_path -cne '.agents/skills/impeccable') { throw 'Unexpected Impeccable skill path in ui-skills.lock.json.' }
    if ([string]$lock.impeccable.commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid Impeccable commit in ui-skills.lock.json.' }
    return $lock
}

function Assert-SelectedSourceIdentities {
    param([Parameter(Mandatory)]$SuperLock,[Parameter(Mandatory)]$UiLock)

    $heads = [ordered]@{
        hms = (Assert-GitSourceIdentity -Path $InstallRoot -ExpectedRepository $CanonicalHmsRemote -Label 'HMS Skills Codex')
        superpowers = $null
        taste = $null
        impeccable = $null
    }
    if ($Superpowers) {
        $heads['superpowers'] = Assert-GitSourceIdentity -Path $SuperpowersRoot -ExpectedRepository ([string]$SuperLock.repository) -ExpectedCommit ([string]$SuperLock.commit) -Label 'Superpowers'
    }
    if ($Taste) {
        $heads['taste'] = Assert-GitSourceIdentity -Path $TasteRoot -ExpectedRepository ([string]$UiLock.taste.repository) -ExpectedCommit ([string]$UiLock.taste.commit) -Label 'GPT Taste'
    }
    if ($Impeccable) {
        $heads['impeccable'] = Assert-GitSourceIdentity -Path $ImpeccableRoot -ExpectedRepository ([string]$UiLock.impeccable.repository) -ExpectedCommit ([string]$UiLock.impeccable.commit) -Label 'Impeccable'
    }
    return $heads
}

function Assert-SourceSnapshotsEqual {
    param([Parameter(Mandatory)]$Before,[Parameter(Mandatory)]$After)
    foreach ($key in @('hms','superpowers','taste','impeccable')) {
        if ([string]$Before[$key] -cne [string]$After[$key]) {
            throw "Source identity changed during composite compilation for '$key'. Before=$($Before[$key]) After=$($After[$key])"
        }
    }
}

function Get-ExactJunctionState {
    param([Parameter(Mandatory)][string]$Link,[Parameter(Mandatory)][string]$Target)
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [pscustomobject]@{ State='Absent'; Detail='Path is absent.' } }
    if (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [pscustomobject]@{ State='Conflict'; Detail="Existing path is not a reparse point: $Link" } }
    $linkType = if ($null -eq $item.PSObject.Properties['LinkType']) { '' } else { [string]$item.LinkType }
    if ($linkType -ine 'Junction') { return [pscustomobject]@{ State='Conflict'; Detail="Existing reparse point is not a Junction: $Link (LinkType='$linkType')" } }
    if (-not (Test-Path -LiteralPath $Target)) { return [pscustomobject]@{ State='Conflict'; Detail="Expected Junction target is missing: $Target" } }
    $expected = Get-CanonicalPath -Path $Target
    foreach ($candidate in @($item.Target)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try { if ((Get-CanonicalPath -Path ([string]$candidate)) -ieq $expected) { return [pscustomobject]@{ State='Exact'; Detail="Junction targets $expected" } } } catch { }
    }
    return [pscustomobject]@{ State='Conflict'; Detail="Junction target does not match the managed target: $Link" }
}

function Ensure-ExactJunction {
    param([Parameter(Mandatory)][string]$Link,[Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { throw "Cannot create Junction because target is missing: $Target" }
    $state = Get-ExactJunctionState -Link $Link -Target $Target
    if ($state.State -eq 'Exact') { return }
    if ($state.State -eq 'Conflict') { throw $state.Detail }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Link) | Out-Null
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    $after = Get-ExactJunctionState -Link $Link -Target $Target
    if ($after.State -ne 'Exact') { throw "Junction creation verification failed: $Link : $($after.Detail)" }
}

function Restore-Quarantine {
    param([Parameter(Mandatory)][string]$Original,[Parameter(Mandatory)][string]$Quarantine)
    if ($null -eq (Get-Item -LiteralPath $Quarantine -Force -ErrorAction SilentlyContinue)) { return }
    if ($null -ne (Get-Item -LiteralPath $Original -Force -ErrorAction SilentlyContinue)) { throw "Cannot restore quarantined path because original is occupied: $Original" }
    Rename-Item -LiteralPath $Quarantine -NewName (Split-Path -Leaf $Original) -ErrorAction Stop
}

function Remove-ExactJunction {
    param([Parameter(Mandatory)][string]$Link,[Parameter(Mandatory)][string]$Target)
    $state = Get-ExactJunctionState -Link $Link -Target $Target
    if ($state.State -eq 'Absent') { return }
    if ($state.State -ne 'Exact') { throw "Refusing to remove non-managed discovery path: $Link : $($state.Detail)" }
    $parent = Split-Path -Parent $Link
    $leaf = '.hms-removing-' + [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent $leaf
    Rename-Item -LiteralPath $Link -NewName $leaf -ErrorAction Stop
    try {
        $boundary = Get-ExactJunctionState -Link $quarantine -Target $Target
        if ($boundary.State -ne 'Exact') { throw "Quarantined Junction identity mismatch: $($boundary.Detail)" }
        & $env:ComSpec /d /c "rmdir `"$quarantine`""
        if ($LASTEXITCODE -ne 0) { throw "rmdir failed with exit code $LASTEXITCODE" }
    }
    catch {
        $originalError = $_
        try { Restore-Quarantine -Original $Link -Quarantine $quarantine }
        catch { throw "Junction removal failed and rollback was incomplete. Original: $($originalError.Exception.Message). Rollback: $($_.Exception.Message)" }
        throw $originalError
    }
}

function Assert-OwnedCompositeRoot {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not [bool]$item.PSIsContainer) { throw "Refusing composite operation on a non-directory path: $Path" }
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing composite operation on a reparse point: $Path" }
    $manifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Refusing to replace unowned composite directory: $Path" }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Refusing to replace composite directory with invalid manifest: $Path" }
    if ([string]$manifest.managed_by -cne $ManagedBy -or [string]$manifest.artifact -cne $Artifact) { throw "Refusing to replace composite directory with unexpected ownership: $Path" }
}

function Get-HmsCompositeFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}
function Add-OwnedCompositeTreeRecords {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LogicalPrefix,
        [Parameter(Mandatory)]$Records
    )
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
        if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Composite tree contains a reparse point: $($item.FullName)"
        }
        $logical = if ([string]::IsNullOrEmpty($LogicalPrefix)) { [string]$item.Name } else { $LogicalPrefix + "/" + [string]$item.Name }
        if ([bool]$item.PSIsContainer) {
            Add-OwnedCompositeTreeRecords -Directory $item.FullName -LogicalPrefix $logical -Records $Records
            continue
        }
        $hash = Get-HmsCompositeFileSha256 -Path $item.FullName
        $Records.Add($logical + "`t" + $hash)
    }
}

function Get-OwnedCompositeTreeSha256 {
    param([Parameter(Mandatory)][string]$Path)
    Assert-OwnedCompositeRoot -Path $Path
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $records = New-Object System.Collections.Generic.List[string]
    Add-OwnedCompositeTreeRecords -Directory $root -LogicalPrefix "" -Records $records
    if ($records.Count -eq 0) { throw "Composite tree contains no authenticated files: $Path" }
    $sorted = [string[]]@($records)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $payload = [string]::Join("`n", $sorted)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-OwnedCompositeIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTreeSha256
    )
    if ($ExpectedTreeSha256 -notmatch '^[0-9a-f]{64}$') { throw "Composite expected tree SHA-256 is invalid: $ExpectedTreeSha256" }
    $actual = Get-OwnedCompositeTreeSha256 -Path $Path
    if ($actual -cne $ExpectedTreeSha256) {
        throw "Composite tree identity mismatch. Expected $ExpectedTreeSha256, found $actual : $Path"
    }
}

function Reserve-OwnedCompositeRollbackBackup {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedTreeSha256,[ref]$ReservedPathRef)
    $parent=Split-Path -Parent $Path;$reserved=Join-Path $parent ('.hms-composite-rollback-reserved-'+[guid]::NewGuid().ToString('N'))
    if(Test-Path -LiteralPath $reserved){throw "Composite rollback reservation path already exists: $reserved"}
    if($env:OS -cne 'Windows_NT'){
        Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $reserved) -ErrorAction Stop
        if($null-ne$ReservedPathRef){$ReservedPathRef.Value=$reserved}
        Assert-OwnedCompositeIdentity -Path $reserved -ExpectedTreeSha256 $ExpectedTreeSha256
        return $reserved
    }
    $guard=Open-HmsCompositeDirectoryGuard -Path $Path -Label 'Composite rollback reservation'
    try{
        Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
        Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $reserved -Label 'Composite rollback reservation'
        if($null-ne$ReservedPathRef){$ReservedPathRef.Value=$reserved}
        Assert-OwnedCompositeIdentity -Path $reserved -ExpectedTreeSha256 $ExpectedTreeSha256
        return $reserved
    } finally {if($null-ne$guard.Handle){$guard.Handle.Dispose()}}
}


function Restore-OwnedCompositeRollbackBackup {
    param([string]$BackupPath,[string]$ReservedPath,[Parameter(Mandatory)][string]$FinalPath,[Parameter(Mandatory)][string]$ExpectedTreeSha256)
    $source=$null
    if(-not[string]::IsNullOrWhiteSpace($ReservedPath)-and(Test-Path -LiteralPath $ReservedPath)){$source=$ReservedPath}
    elseif(-not[string]::IsNullOrWhiteSpace($BackupPath)-and(Test-Path -LiteralPath $BackupPath)){$source=Reserve-OwnedCompositeRollbackBackup -Path $BackupPath -ExpectedTreeSha256 $ExpectedTreeSha256}
    else{throw 'Previous composite backup disappeared before rollback restoration.'}
    if($env:OS -cne 'Windows_NT'){
        Assert-OwnedCompositeIdentity -Path $source -ExpectedTreeSha256 $ExpectedTreeSha256
        if(Test-Path -LiteralPath $FinalPath){throw "Cannot restore previous composite because FinalRoot is occupied: $FinalPath"}
        Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $FinalPath) -ErrorAction Stop
        Assert-OwnedCompositeIdentity -Path $FinalPath -ExpectedTreeSha256 $ExpectedTreeSha256
        return
    }
    $guard=Open-HmsCompositeDirectoryGuard -Path $source -Label 'Composite rollback activation'
    $moved=$false
    try{
        Assert-OwnedCompositeIdentity -Path $source -ExpectedTreeSha256 $ExpectedTreeSha256
        if(Test-Path -LiteralPath $FinalPath){throw "Cannot restore previous composite because FinalRoot is occupied: $FinalPath"}
        Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $FinalPath -Label 'Composite rollback activation';$moved=$true
        try{Assert-OwnedCompositeIdentity -Path $FinalPath -ExpectedTreeSha256 $ExpectedTreeSha256}
        catch{
            $verifyError=$_
            if (-not (Test-Path -LiteralPath $source)){
                try{Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $source -Label 'Composite rollback activation verification rollback'}catch{throw "Composite rollback activation validation failed and exact-object return also failed. Validation: $($verifyError.Exception.Message). Return: $($_.Exception.Message)"}
            }
            throw $verifyError
        }
    } finally {if($null-ne$guard.Handle){$guard.Handle.Dispose()}}
}


function Remove-OwnedCompositeIdentityQuarantine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTreeSha256
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $parent = Split-Path -Parent $Path
    $quarantine = Join-Path $parent ('.hms-composite-deleting-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $quarantine) { throw "Composite identity quarantine path already exists: $quarantine" }
    if ($env:OS -cne 'Windows_NT') {
        Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $quarantine) -ErrorAction Stop
        Assert-OwnedCompositeIdentity -Path $quarantine -ExpectedTreeSha256 $ExpectedTreeSha256
        Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $quarantine) { throw "Composite identity quarantine removal did not complete: $quarantine" }
        return
    }
    $guard = Open-HmsCompositeDirectoryGuard -Path $Path -Label 'Composite identity quarantine'
    $renamed = $false
    $deleteStarted = $false
    try {
        Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
        Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $quarantine -Label 'Composite identity quarantine'
        $renamed = $true
        Assert-OwnedCompositeIdentity -Path $quarantine -ExpectedTreeSha256 $ExpectedTreeSha256
        $deleteStarted = $true
        foreach ($child in @(Get-ChildItem -LiteralPath $quarantine -Force -ErrorAction Stop)) {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
        $code = 0
        if (-not [HmsCompositeExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)) { throw "Composite exact quarantine delete-pending transition failed (Win32=$code): $quarantine" }
        $guard.Handle.Dispose(); $guard.Handle = $null
        if (Test-Path -LiteralPath $quarantine) { throw "Composite exact quarantine remained after handle deletion: $quarantine" }
    }
    catch {
        $e = $_
        if (-not $deleteStarted -and $renamed -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and -not (Test-Path -LiteralPath $Path)) {
            try {
                Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $Path -Label 'Composite identity quarantine rollback'
                Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
            } catch { throw "Composite identity quarantine validation failed and exact-object rollback was incomplete. Original: $($e.Exception.Message). Rollback: $($_.Exception.Message)" }
        }
        elseif ($deleteStarted -and (Test-Path -LiteralPath $quarantine)) {
            throw "Composite identity deletion failed after destructive child removal started; exact quarantined remainder was not restored: $quarantine. Original: $($e.Exception.Message)"
        }
        throw $e
    }
    finally { if ($null -ne $guard -and $null -ne $guard.Handle) { $guard.Handle.Dispose() } }
}

function Remove-OwnedCompositeQuarantine {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-OwnedCompositeRoot -Path $Path
    $parent = Split-Path -Parent $Path
    $leaf = '.hms-composite-deleting-' + [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent $leaf
    $deleteStarted = $false
    Rename-Item -LiteralPath $Path -NewName $leaf -ErrorAction Stop
    try {
        # Destructive-boundary revalidation: a non-cooperating process may replace a pathname
        # after earlier checks, so only this fresh random quarantine can cross into recursive deletion.
        Assert-OwnedCompositeRoot -Path $quarantine
        $deleteStarted = $true
        Remove-Item -LiteralPath $quarantine -Recurse -Force
        if (Test-Path -LiteralPath $quarantine) { throw "Composite quarantine removal did not complete: $quarantine" }
    }
    catch {
        $e = $_
        if (-not $deleteStarted) {
            try { Restore-Quarantine -Original $Path -Quarantine $quarantine }
            catch { throw "Composite quarantine pre-delete validation failed and rollback was incomplete. Original: $($e.Exception.Message). Rollback: $($_.Exception.Message)" }
        }
        elseif (Test-Path -LiteralPath $quarantine) {
            throw "Composite deletion failed after destructive removal started; quarantined remainder was not restored: $quarantine. Original: $($e.Exception.Message)"
        }
        throw $e
    }
}

function Assert-OwnedCompositeStage {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$StageId)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { throw "Composite stage is missing: $Path" }
    if (-not [bool]$item.PSIsContainer) { throw "Refusing stage operation on a non-directory path: $Path" }
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing stage operation on a reparse point: $Path" }
    $markerPath = Join-Path $Path '.hms-stage-owner.json'
    $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $markerItem -or [bool]$markerItem.PSIsContainer -or [bool]($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing stage operation without a regular ownership marker: $Path"
    }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json }
    catch { throw "Refusing stage operation with invalid ownership marker: $Path" }
    if ([string]$marker.managed_by -cne $ManagedBy -or [string]$marker.artifact -cne $StageArtifact -or [string]$marker.stage_id -cne $StageId) {
        throw "Refusing stage operation with unexpected ownership identity: $Path"
    }
}

function Move-OwnedCompositeStageToFinal {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$StageId,
        [Parameter(Mandatory)][string]$ExpectedTreeSha256
    )
    if (Test-Path -LiteralPath $FinalPath) { throw "Composite FinalRoot is occupied before staged activation: $FinalPath" }
    if ($env:OS -cne 'Windows_NT') {
        Assert-OwnedCompositeStage -Path $Path -StageId $StageId
        Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $FinalPath) -ErrorAction Stop
        Assert-OwnedCompositeStage -Path $FinalPath -StageId $StageId
        Assert-OwnedCompositeIdentity -Path $FinalPath -ExpectedTreeSha256 $ExpectedTreeSha256
        return $null
    }
    $guard = Open-HmsCompositeDirectoryGuard -Path $Path -Label 'Composite stage activation'
    try {
        Assert-OwnedCompositeStage -Path $Path -StageId $StageId
        Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
        $probe = [string]$env:HMS_TEST_STAGE_ACTIVATION_GUARD_READY
        if (-not [string]::IsNullOrWhiteSpace($probe)) {
            [IO.File]::WriteAllText($probe,$Path,(New-Object Text.UTF8Encoding($false)))
            Start-Sleep -Milliseconds 1200
        }
        Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $FinalPath -Label 'Composite stage activation'
        Assert-OwnedCompositeStage -Path $FinalPath -StageId $StageId
        Assert-OwnedCompositeIdentity -Path $FinalPath -ExpectedTreeSha256 $ExpectedTreeSha256
        return $guard
    }
    catch {
        $activationError = $_
        if ($null -ne $guard -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and [string]$guard.Path -ceq $FinalPath -and -not (Test-Path -LiteralPath $Path)) {
            try {
                Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $Path -Label 'Composite stage activation verification rollback'
                Assert-OwnedCompositeStage -Path $Path -StageId $StageId
                Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
            }
            catch { throw "Composite stage activation validation failed and exact-object return also failed. Validation: $($activationError.Exception.Message). Return: $($_.Exception.Message)" }
        }
        if ($null -ne $guard -and $null -ne $guard.Handle) { $guard.Handle.Dispose(); $guard.Handle = $null }
        throw $activationError
    }
}

function Remove-OwnedCompositeStageQuarantine {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$StageId)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $parent = Split-Path -Parent $Path
    $quarantine = Join-Path $parent ('.hms-stage-deleting-' + [guid]::NewGuid().ToString('N'))
    if ($env:OS -cne 'Windows_NT') {
        Assert-OwnedCompositeStage -Path $Path -StageId $StageId
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $quarantine) -ErrorAction Stop
        Assert-OwnedCompositeStage -Path $quarantine -StageId $StageId
        Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction Stop
        return
    }
    $guard = Open-HmsCompositeDirectoryGuard -Path $Path -Label 'Composite stage cleanup'
    $renamed = $false; $deleteStarted = $false
    try {
        Assert-OwnedCompositeStage -Path $Path -StageId $StageId
        Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $quarantine -Label 'Composite stage cleanup'
        $renamed = $true
        Assert-OwnedCompositeStage -Path $quarantine -StageId $StageId
        $deleteStarted = $true
        foreach ($child in @(Get-ChildItem -LiteralPath $quarantine -Force -ErrorAction Stop)) { Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop }
        $code = 0
        if (-not [HmsCompositeExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)) { throw "Composite stage exact delete-pending transition failed (Win32=$code): $quarantine" }
        $guard.Handle.Dispose(); $guard.Handle = $null
    }
    catch {
        $e=$_
        if (-not $deleteStarted -and $renamed -and $null -ne $guard.Handle -and -not (Test-Path -LiteralPath $Path)) {
            try { Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $Path -Label 'Composite stage cleanup rollback'; Assert-OwnedCompositeStage -Path $Path -StageId $StageId }
            catch { throw "Composite stage cleanup failed and exact-object rollback was incomplete. Original: $($e.Exception.Message). Rollback: $($_.Exception.Message)" }
        }
        elseif ($deleteStarted -and (Test-Path -LiteralPath $quarantine)) { throw "Composite stage deletion failed after destructive child removal started; exact quarantined remainder was not restored: $quarantine. Original: $($e.Exception.Message)" }
        throw $e
    }
    finally { if ($null -ne $guard -and $null -ne $guard.Handle) { $guard.Handle.Dispose() } }
}

function Copy-SkillModule {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$ExpectedHead)
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md'))) { throw "Skill source does not contain SKILL.md: $Source" }
    Assert-CopyTreeContainsCommittedBytesOnly -Source $Source
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    foreach ($skillFile in @(Get-ChildItem -LiteralPath $Destination -Filter 'SKILL.md' -File -Recurse -ErrorAction SilentlyContinue)) {
        Rename-Item -LiteralPath $skillFile.FullName -NewName 'MODULE.md' -ErrorAction Stop
    }
}

function Copy-SkillCollection {
    param(
        [Parameter(Mandatory)][string]$SkillsDirectory,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$ModulePrefix,
        [Parameter(Mandatory)][string]$ExpectedHead,
        [string[]]$ExcludeNames = @()
    )
    if (-not (Test-Path -LiteralPath $SkillsDirectory)) { throw "Skill collection is missing: $SkillsDirectory" }

    # Collection membership is authority from the committed tree, never from live
    # Get-ChildItem/Test-Path enumeration. A hidden/missing worktree child therefore
    # fails during exact committed-object materialization instead of silently vanishing.
    $skillsRoot = Get-CanonicalPath -Path $SkillsDirectory
    $repoTopRaw = ((& git -C $SkillsDirectory rev-parse --show-toplevel 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoTopRaw)) { throw "Skill collection is not inside a readable Git checkout: $SkillsDirectory" }
    $repoRoot = Get-CanonicalPath -Path $repoTopRaw
    $repoPrefix = $repoRoot + '\'
    if ($skillsRoot -ieq $repoRoot) { $pathSpec = '.' }
    elseif ($skillsRoot.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) { $pathSpec = $skillsRoot.Substring($repoPrefix.Length).Replace('\','/') }
    else { throw "Skill collection escaped its Git repository root: $SkillsDirectory" }

    $collectionHead = $ExpectedHead.Trim().ToLowerInvariant()
    if ($collectionHead -notmatch '^[0-9a-f]{40}$') { throw "Skill collection expected HEAD is not canonical: $ExpectedHead" }
    $collectionHeadType = ((& git -C $repoRoot cat-file -t $collectionHead 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $collectionHeadType -cne 'commit') { throw "Skill collection expected commit is unavailable: $collectionHead" }
    $treePaths = @(& git -C $repoRoot ls-tree -r --name-only $collectionHead -- $pathSpec 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Committed skill collection tree could not be enumerated: $SkillsDirectory" }
    $treePrefix = if ($pathSpec -eq '.') { '' } else { $pathSpec.TrimEnd('/') + '/' }
    $names = @()
    foreach ($treePathRaw in $treePaths) {
        $treePath = [string]$treePathRaw
        if (-not $treePath.StartsWith($treePrefix, [StringComparison]::Ordinal)) { continue }
        $relative = $treePath.Substring($treePrefix.Length)
        $parts = @($relative -split '/')
        if ($parts.Count -eq 2 -and $parts[1] -ceq 'SKILL.md' -and -not [string]::IsNullOrWhiteSpace($parts[0])) { $names += $parts[0] }
    }
    $names = @($names | Sort-Object -Unique)

    $copied = @()
    foreach ($name in $names) {
        if ($ExcludeNames -contains $name) { continue }
        $source = Join-Path $SkillsDirectory $name
        $destination = Join-Path $DestinationRoot $name
        Copy-SkillModule -Source $source -Destination $destination -ExpectedHead $collectionHead
        $copied += ($ModulePrefix + '/' + $name + '/MODULE.md')
    }
    if ($copied.Count -eq 0) { throw "No committed skill modules were found under: $SkillsDirectory" }
    return $copied
}

function Write-CompositeSkill {
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)]$Modules,
        [Parameter(Mandatory)][string]$ModelRouterReference,
        [Parameter(Mandatory)][string]$ModelDispatcherReference,
        [string[]]$HmsReferences,
        [string[]]$SuperpowersReferences,
        [string]$TasteReference,
        [string]$ImpeccableReference
    )
    $enabled = @($Modules.Keys | Where-Object { [bool]$Modules[$_] })
    $enabledText = if ($enabled.Count -eq 0) { 'none' } else { $enabled -join ', ' }
    $lines = @(
        '---',
        'name: hms-superpowers',
        'description: Use as the single HMS entry point for project work; it routes each task to exactly one enabled internal work-module owner and assigns an enabled GPT-5.6 model through the dedicated model router and dispatcher.',
        '---',
        '',
        '# HMS Unified Superpower',
        '',
        'This file is generated by HMS Skills Manager. Do not edit the generated bundle by hand.',
        '',
        ('Enabled work modules: ' + $enabledText),
        '',
        '## Arbitration kernel',
        '',
        '1. Owner instruction and current project authority always outrank every internal module.',
        '2. Assign exactly one enabled primary work-module owner for each decision or task slice.',
        '3. The model router and model dispatcher are always internal when the public skill is exposed; they classify/assign models but never own product/work decisions.',
        '4. Never assign exclusive work ownership to a disabled module. If a required owner is OFF and no higher authority defines a safe fallback, report MODULE_REQUIRED=<module> and stop that slice.',
        '5. Other enabled modules may advise or provide method, but they must not compete for ownership.',
        '6. Never let two modules mutate the same files or design authority concurrently.',
        '7. If module guidance conflicts, apply the enabled-role matrix below instead of blending incompatible instructions.',
        '8. Load only the module references needed for the current task; MODULE.md files are references, not separately invokable Codex skills.',
        '',
        '## Model routing',
        '',
        ('Always-internal risk router: ' + $ModelRouterReference),
        ('Always-internal model dispatcher: ' + $ModelDispatcherReference),
        ('Model settings: ' + $ModelSettingsPath),
        'For each non-trivial model-routed slice, the risk router emits RISK_CLASS plus REQUIRED_MODEL_FLOOR. Pass that floor directly to the dispatcher/resolver. Do not recompute or lower it.',
        'Safe reassignment is upward only: Luna -> Terra -> Sol, Terra -> Sol, and Sol-required work with Sol disabled is BLOCKED.',
        'Model ON/OFF policy is not proof that the runtime switched model. Never claim a switch without observable runtime evidence.',
        '',
        '## Enabled exclusive role matrix',
        '',
        '| Work type | Primary owner | Other modules |',
        '| --- | --- | --- |'
    )
    if ([bool]$Modules['hms']) {
        $lines += '| Authority, checkpoint, scope, model floor, evidence, review gate, release, handoff | HMS Core | Others are subordinate |'
    }
    if ([bool]$Modules['superpowers']) {
        $lines += '| Engineering plan, worktree method, debugging, TDD, implementation workflow | Superpowers | HMS governs boundaries when enabled; UI advisors do not own engineering |'
        $lines += '| UI production implementation | Superpowers | Taste direction and Impeccable audit/polish may support when enabled; HMS governs when enabled |'
    }
    if ([bool]$Modules['taste']) {
        $lines += '| Visual direction, aesthetic options, taste critique | GPT Taste | Advisory only; cannot override project UI authority |'
    }
    if ([bool]$Modules['impeccable']) {
        $lines += '| UI audit, consistency, typography, spacing, accessibility, final polish | Impeccable | Advisory/polish only; cannot redesign frozen authority |'
    }
    $lines += '| Model assignment from enabled pool | HMS Model Dispatcher | Not a work owner; cannot lower mandatory capability floor |'
    $lines += ''
    $lines += '## UI sequence when multiple UI modules are enabled'
    $lines += ''
    $lines += 'Apply only enabled work modules, sequentially, inside owner/project UI authority. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
    $lines += 'Do not ask disabled modules to act, and do not let Taste and Impeccable independently redesign the same artifact.'
    $lines += ''
    $lines += '## Module loading contract'
    $lines += ''
    $lines += '### HMS Model Router'
    $lines += 'Always load the risk router for non-trivial model-routed work so the required model floor is explicit before assignment.'
    $lines += ('- ' + $ModelRouterReference)
    $lines += ''
    $lines += '### HMS Model Dispatcher'
    $lines += 'Pass the required floor directly to the dispatcher. It reads the model pool and safely reassigns work only to an equal-or-stronger enabled model.'
    $lines += ('- ' + $ModelDispatcherReference)
    $lines += ''
    if ([bool]$Modules['hms']) {
        $lines += '### HMS Core'
        $lines += 'HMS Core owns governance and final arbitration. Read references/hms/hms-superpowers/MODULE.md first, then load only supporting HMS MODULE.md files required by the current gate.'
        foreach ($ref in @($HmsReferences)) { $lines += ('- ' + $ref) }
        $lines += ''
    }
    if ([bool]$Modules['superpowers']) {
        $lines += '### Superpowers'
        $lines += 'Superpowers owns technical method only. It cannot expand HMS scope, change authority, or authorize merge/release.'
        foreach ($ref in @($SuperpowersReferences)) { $lines += ('- ' + $ref) }
        $lines += ''
    }
    if ([bool]$Modules['taste']) {
        $lines += '### GPT Taste'
        $lines += 'Taste owns visual direction and critique only. Use it only where higher UI authority leaves discretion.'
        $lines += ('- ' + $TasteReference)
        $lines += ''
    }
    if ([bool]$Modules['impeccable']) {
        $lines += '### Impeccable'
        $lines += 'Impeccable owns UI audit and polish only. It may improve quality inside an accepted direction but cannot replace frozen product or design authority.'
        $lines += ('- ' + $ImpeccableReference)
        $lines += ''
    }
    if ($enabled.Count -eq 0) {
        $lines += 'No work modules are enabled. This bundle must not be exposed to Codex discovery even though model settings and the model-routing sources remain managed.'
    }
    else {
        $lines += '## Completion rule'
        $lines += ''
        $lines += 'Use one public entry point, one enabled primary work owner per slice, one explicit risk floor, one dedicated model assignment, sequential advisors, and the strongest applicable evidence gate.'
    }
    Set-Content -LiteralPath (Join-Path $StageRoot 'SKILL.md') -Value ($lines -join "`r`n") -Encoding UTF8
}

$stageId = $null
$buildMutex = New-Object System.Threading.Mutex($false, $BuildMutexName)
$mutexOwned = $false
$stage = $null
try {
    try {
        $mutexOwned = $buildMutex.WaitOne([TimeSpan]::FromSeconds(120))
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexOwned = $true
    }
    if (-not $mutexOwned) { throw "Timed out waiting for composite build lock: $BuildMutexName" }

    $superLock = Read-SuperpowersLock
    $uiLock = Read-UiLock
    $sourceHeadsBefore = Assert-SelectedSourceIdentities -SuperLock $superLock -UiLock $uiLock

    $modules = [ordered]@{ hms=[bool]$Hms; superpowers=[bool]$Superpowers; taste=[bool]$Taste; impeccable=[bool]$Impeccable }
    if (-not (Test-Path -LiteralPath (Join-Path $ModelRouterSource 'SKILL.md'))) { throw 'Dedicated model router source is missing.' }
    if (-not (Test-Path -LiteralPath (Join-Path $ModelDispatcherSource 'SKILL.md'))) { throw 'Dedicated model dispatcher source is missing.' }
    if (-not (Test-Path -LiteralPath $ModelResolverSource)) { throw 'Dedicated model route resolver script is missing.' }
    if ($Hms -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'skills\hms-superpowers\SKILL.md'))) { throw 'HMS Core is enabled but HMS skill sources are missing.' }
    if ($Superpowers -and -not (Test-Path -LiteralPath (Join-Path $SuperpowersRoot 'skills'))) { throw 'Superpowers is enabled but the pinned source repository is missing.' }
    $tasteSource = Join-Path $TasteRoot ([string]$uiLock.taste.skill_path)
    $impeccableSource = Join-Path $ImpeccableRoot ([string]$uiLock.impeccable.skill_path)
    if ($Taste -and -not (Test-Path -LiteralPath (Join-Path $tasteSource 'SKILL.md'))) { throw 'GPT Taste is enabled but its pinned skill source is missing.' }
    if ($Impeccable -and -not (Test-Path -LiteralPath (Join-Path $impeccableSource 'SKILL.md'))) { throw 'Impeccable is enabled but its pinned skill source is missing.' }

    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $SkillsRoot | Out-Null
    Assert-OwnedCompositeRoot -Path $FinalRoot

    $legacy = @(
        [pscustomobject]@{ Name='hms'; Link=(Join-Path $SkillsRoot 'hms'); Target=(Join-Path $InstallRoot 'skills') },
        [pscustomobject]@{ Name='superpowers'; Link=(Join-Path $SkillsRoot 'superpowers'); Target=(Join-Path $SuperpowersRoot 'skills') },
        [pscustomobject]@{ Name='taste'; Link=(Join-Path $SkillsRoot 'gpt-taste'); Target=$tasteSource },
        [pscustomobject]@{ Name='impeccable'; Link=(Join-Path $SkillsRoot 'impeccable'); Target=$impeccableSource }
    )
    foreach ($entry in $legacy) {
        if ($null -eq (Get-Item -LiteralPath $entry.Link -Force -ErrorAction SilentlyContinue)) { continue }
        $state = Get-ExactJunctionState -Link $entry.Link -Target $entry.Target
        if ($state.State -ne 'Exact') { throw "Legacy discovery conflict blocks single-skill migration: $($entry.Link) : $($state.Detail)" }
    }
    if (Test-Path -LiteralPath $FinalRoot) {
        $state = Get-ExactJunctionState -Link $CompositeLink -Target $FinalRoot
        if ($state.State -eq 'Conflict') { throw "Composite discovery conflict: $($state.Detail)" }
    }
    elseif ($null -ne (Get-Item -LiteralPath $CompositeLink -Force -ErrorAction SilentlyContinue)) {
        throw "Composite discovery path exists before its managed target exists: $CompositeLink"
    }

    $stageId = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $OutputRoot ('.stage-' + $stageId)
    $backup = Join-Path $OutputRoot ('.backup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    [ordered]@{ schema_version=1; managed_by=$ManagedBy; artifact=$StageArtifact; stage_id=$stageId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage '.hms-stage-owner.json') -Encoding UTF8
    Assert-OwnedCompositeStage -Path $stage -StageId $stageId

    $refsRoot = Join-Path $stage 'references'
    $hmsRefs = @(); $superRefs = @(); $tasteRef = $null; $impeccableRef = $null

    $modelRouterDestination = Join-Path $refsRoot 'model-router'
    Copy-SkillModule -Source $ModelRouterSource -Destination $modelRouterDestination -ExpectedHead ([string]$sourceHeadsBefore['hms'])
    $modelRouterRef = 'references/model-router/MODULE.md'

    $modelDispatcherDestination = Join-Path $refsRoot 'model-dispatcher'
    Copy-SkillModule -Source $ModelDispatcherSource -Destination $modelDispatcherDestination -ExpectedHead ([string]$sourceHeadsBefore['hms'])
    Copy-Item -LiteralPath $ModelResolverSource -Destination (Join-Path $modelDispatcherDestination 'Resolve-HmsModelRoute.ps1') -Force
    $modelDispatcherRef = 'references/model-dispatcher/MODULE.md'

    if ($Hms) {
        $hmsRefs = @(Copy-SkillCollection -SkillsDirectory (Join-Path $InstallRoot 'skills') -DestinationRoot (Join-Path $refsRoot 'hms') -ModulePrefix 'references/hms' -ExpectedHead ([string]$sourceHeadsBefore['hms']) -ExcludeNames @('hms-model-router','hms-model-dispatcher'))
    }
    if ($Superpowers) { $superRefs = @(Copy-SkillCollection -SkillsDirectory (Join-Path $SuperpowersRoot 'skills') -DestinationRoot (Join-Path $refsRoot 'superpowers') -ModulePrefix 'references/superpowers' -ExpectedHead ([string]$sourceHeadsBefore['superpowers'])) }
    if ($Taste) { Copy-SkillModule -Source $tasteSource -Destination (Join-Path $refsRoot 'taste') -ExpectedHead ([string]$sourceHeadsBefore['taste']); $tasteRef = 'references/taste/MODULE.md' }
    if ($Impeccable) { Copy-SkillModule -Source $impeccableSource -Destination (Join-Path $refsRoot 'impeccable') -ExpectedHead ([string]$sourceHeadsBefore['impeccable']); $impeccableRef = 'references/impeccable/MODULE.md' }

    $sourceHeadsAfter = Assert-SelectedSourceIdentities -SuperLock $superLock -UiLock $uiLock
    Assert-SourceSnapshotsEqual -Before $sourceHeadsBefore -After $sourceHeadsAfter

    Write-CompositeSkill -StageRoot $stage -Modules $modules -ModelRouterReference $modelRouterRef -ModelDispatcherReference $modelDispatcherRef -HmsReferences $hmsRefs -SuperpowersReferences $superRefs -TasteReference $tasteRef -ImpeccableReference $impeccableRef

    $enabled = @($modules.Keys | Where-Object { [bool]$modules[$_] })
    $manifest = [ordered]@{
        schema_version=1; managed_by=$ManagedBy; artifact=$Artifact; composite_skill=$CompositeName; generated_at_utc=[DateTime]::UtcNow.ToString('o'); modules=$modules; enabled_modules=$enabled
        source_heads=[ordered]@{ hms=$sourceHeadsAfter['hms']; superpowers=$sourceHeadsAfter['superpowers']; taste=$sourceHeadsAfter['taste']; impeccable=$sourceHeadsAfter['impeccable'] }
        routing_contract=[ordered]@{
            governance='hms'; engineering_method='superpowers'; visual_direction='taste'; ui_audit_polish='impeccable'; concurrency='one-primary-owner-per-task-slice'; composite_build_lock=$BuildMutexName; model_router='always-internal'; model_dispatcher='always-internal'; model_fallback='upward-only'; model_settings=$ModelSettingsPath
        }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
    $candidateCompositeTreeSha = Get-OwnedCompositeTreeSha256 -Path $stage
    $previousCompositeTreeSha = $null
    if (Test-Path -LiteralPath $FinalRoot) {
        $previousCompositeTreeSha = Get-OwnedCompositeTreeSha256 -Path $FinalRoot
    }

    $removedLegacy = @()
    $createdComposite = $false
    $oldMovedToBackup = $false
    $reservedBackup = $null
    $newActivated = $false
    $stageActivationGuard = $null
    try {
        if (Test-Path -LiteralPath $FinalRoot) {
            if ([string]::IsNullOrWhiteSpace([string]$previousCompositeTreeSha)) { throw 'Previous composite identity was not captured before activation.' }
            if ($env:OS -ceq 'Windows_NT') {
                $previousGuard = Open-HmsCompositeDirectoryGuard -Path $FinalRoot -Label 'Previous composite backup transition'
                try {
                    Assert-OwnedCompositeIdentity -Path $FinalRoot -ExpectedTreeSha256 $previousCompositeTreeSha
                    Move-HmsCompositeDirectoryGuard -Guard $previousGuard -Destination $backup -Label 'Previous composite backup transition'
                    $oldMovedToBackup = $true
                    Assert-OwnedCompositeIdentity -Path $backup -ExpectedTreeSha256 $previousCompositeTreeSha
                }
                finally { if ($null -ne $previousGuard -and $null -ne $previousGuard.Handle) { $previousGuard.Handle.Dispose() } }
            }
            else {
                Assert-OwnedCompositeIdentity -Path $FinalRoot -ExpectedTreeSha256 $previousCompositeTreeSha
                Rename-Item -LiteralPath $FinalRoot -NewName (Split-Path -Leaf $backup) -ErrorAction Stop
                $oldMovedToBackup = $true
                Assert-OwnedCompositeIdentity -Path $backup -ExpectedTreeSha256 $previousCompositeTreeSha
            }
            # Immediately move the exact previous bundle off the predictable backup pathname.
            # Rollback and successful disposal use only this random identity-verified reservation.
            $reservedBackup = Reserve-OwnedCompositeRollbackBackup -Path $backup -ExpectedTreeSha256 $previousCompositeTreeSha -ReservedPathRef ([ref]$reservedBackup)
        }

        if ($env:HMS_TEST_FAIL_STAGE_ACTIVATION -ceq '1') {
            throw 'Injected staged-root activation failure for rollback qualification.'
        }

        $stageActivationGuard = Move-OwnedCompositeStageToFinal -Path $stage -FinalPath $FinalRoot -StageId $stageId -ExpectedTreeSha256 $candidateCompositeTreeSha
        $newActivated = $true
        $stage = $null

        foreach ($entry in $legacy) {
            if ($null -ne (Get-Item -LiteralPath $entry.Link -Force -ErrorAction SilentlyContinue)) {
                Remove-ExactJunction -Link $entry.Link -Target $entry.Target
                $removedLegacy += $entry
            }
        }
        if ($enabled.Count -gt 0) {
            $before = Get-ExactJunctionState -Link $CompositeLink -Target $FinalRoot
            Ensure-ExactJunction -Link $CompositeLink -Target $FinalRoot
            if ($before.State -eq 'Absent') { $createdComposite = $true }
        }
        else {
            $state = Get-ExactJunctionState -Link $CompositeLink -Target $FinalRoot
            if ($state.State -eq 'Exact') { Remove-ExactJunction -Link $CompositeLink -Target $FinalRoot }
            elseif ($state.State -eq 'Conflict') { throw $state.Detail }
        }
        if ($null -ne $stageActivationGuard) {
            $finalHandleIdentity = Get-HmsCompositeDirectoryIdentityFromHandle -Handle $stageActivationGuard.Handle -Label 'Composite stage discovery publication'
            if ($finalHandleIdentity -cne [string]$stageActivationGuard.Identity) { throw 'Composite stage exact identity changed before discovery publication completed.' }
            Assert-OwnedCompositeIdentity -Path $FinalRoot -ExpectedTreeSha256 $candidateCompositeTreeSha
            $stageActivationGuard.Handle.Dispose(); $stageActivationGuard.Handle = $null; $stageActivationGuard = $null
        }
    }
    catch {
        $mutationError = $_
        if ($null -ne $stageActivationGuard -and $null -ne $stageActivationGuard.Handle) { $stageActivationGuard.Handle.Dispose(); $stageActivationGuard.Handle = $null; $stageActivationGuard = $null }
        $rollbackErrors = @()

        try {
            if ($createdComposite -and (Test-Path -LiteralPath $FinalRoot)) {
                Remove-ExactJunction -Link $CompositeLink -Target $FinalRoot
            }
        }
        catch { $rollbackErrors += $_.Exception.Message }

        foreach ($entry in $removedLegacy) {
            try { Ensure-ExactJunction -Link $entry.Link -Target $entry.Target }
            catch { $rollbackErrors += $_.Exception.Message }
        }

        try {
            if ($newActivated) {
                if (Test-Path -LiteralPath $FinalRoot) {
                    # Delete only the exact activated candidate tree. A foreign replacement at FinalRoot
                    # fails identity validation and is never removed.
                    Remove-OwnedCompositeIdentityQuarantine -Path $FinalRoot -ExpectedTreeSha256 $candidateCompositeTreeSha
                }
            }
            elseif (Test-Path -LiteralPath $FinalRoot) {
                throw "Cannot restore previous composite because FinalRoot became occupied before staged activation completed: $FinalRoot"
            }

            if ($oldMovedToBackup) {
                if ([string]::IsNullOrWhiteSpace([string]$previousCompositeTreeSha)) { throw 'Previous composite rollback identity is unavailable.' }
                Restore-OwnedCompositeRollbackBackup -BackupPath $backup -ReservedPath $reservedBackup -FinalPath $FinalRoot -ExpectedTreeSha256 $previousCompositeTreeSha
                $reservedBackup = $null
            }
        }
        catch { $rollbackErrors += $_.Exception.Message }

        if ($rollbackErrors.Count -gt 0) {
            throw "Composite activation failed and rollback was incomplete. Original: $($mutationError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')"
        }
        throw $mutationError
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$reservedBackup) -and (Test-Path -LiteralPath $reservedBackup)) {
        Remove-OwnedCompositeIdentityQuarantine -Path $reservedBackup -ExpectedTreeSha256 $previousCompositeTreeSha
        $reservedBackup = $null
    }
    $enabledText = if ($enabled.Count -eq 0) { 'none' } else { $enabled -join ', ' }
    Write-Host "PASS: compiled one Codex skill '$CompositeName' from enabled work modules: $enabledText; committed-only source trees, stable source snapshots, serialized activation, and rollback-qualified bundle swap verified."
    Write-Host "Composite bundle: $FinalRoot"
    if ($enabled.Count -gt 0) { Write-Host "Codex discovery: $CompositeLink" } else { Write-Host 'Codex discovery disabled because no work modules are enabled.' }
}
finally {
    $stageCleanupError = $null
    $mutexReleaseError = $null
    if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$stageId)) { throw 'Composite stage cleanup is missing its ownership identity.' }
            Remove-OwnedCompositeStageQuarantine -Path $stage -StageId $stageId
        }
        catch {
            $stageCleanupError = $_
        }
    }
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
        throw "Failed to release composite build lock after builder lifecycle: $($mutexReleaseError.Exception.Message)"
    }
    if ($null -ne $stageCleanupError) {
        throw "Failed to clean staged composite after builder lifecycle: $($stageCleanupError.Exception.Message)"
    }
}