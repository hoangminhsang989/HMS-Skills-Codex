[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$RemoveClones,
    [switch]$IncludeSuperpowers,
    [switch]$IncludeUiSkills,
    [switch]$IncludeDeliveryTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
$SuperpowersRemote = 'https://github.com/obra/superpowers.git'
$TasteRemote = 'https://github.com/Leonxlnx/taste-skill.git'
$ImpeccableRemote = 'https://github.com/pbakaus/impeccable.git'
$ThreeLevelRemote = 'https://github.com/nguyenduytamgithub/three-level-delivery.git'
$BuildMutexName = 'Local\HMS-Skills-Codex-CompositeBuild-v1'

$skillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$compositeRoot = Join-Path $env:USERPROFILE '.codex\hms-composite\hms-superpowers'
$compositeLink = Join-Path $skillsRoot 'hms-superpowers'
$hmsLegacyLink = Join-Path $skillsRoot 'hms'
$superpowersLegacyLink = Join-Path $skillsRoot 'superpowers'
$tasteLegacyLink = Join-Path $skillsRoot 'gpt-taste'
$impeccableLegacyLink = Join-Path $skillsRoot 'impeccable'

$hmsClone = $InstallRoot
$superpowersClone = Join-Path $env:USERPROFILE '.codex\superpowers'
$tasteClone = Join-Path $env:USERPROFILE '.codex\taste-skill'
$impeccableClone = Join-Path $env:USERPROFILE '.codex\impeccable'
$codeGraphRoot = Join-Path $env:USERPROFILE '.codex\codegraph'
$threeLevelClone = Join-Path $env:USERPROFILE '.codex\three-level-delivery'

if ($env:OS -ceq 'Windows_NT' -and -not ('HmsUninstallExactFsNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class HmsUninstallExactFsNative
{
    [StructLayout(LayoutKind.Sequential)] public struct FILETIME_PARTS { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)] public struct BY_HANDLE_FILE_INFORMATION
    { public uint FileAttributes; public FILETIME_PARTS CreationTime; public FILETIME_PARTS LastAccessTime; public FILETIME_PARTS LastWriteTime; public uint VolumeSerialNumber; public uint FileSizeHigh; public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow; }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr sa,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool GetFileInformationByHandle(SafeFileHandle h,out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SetFileInformationByHandle(SafeFileHandle h,int infoClass,IntPtr info,uint size);
    public sealed class HmsChildEntry
    {
        public string Name;
        public ulong FileId;
        public uint Attributes;
        public HmsChildEntry(string name, ulong fileId, uint attributes) { Name=name; FileId=fileId; Attributes=attributes; }
    }
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,int infoClass,IntPtr info,uint size);
    public static HmsChildEntry[] EnumerateChildrenByHandle(SafeFileHandle handle,out int error)
    {
        var result=new System.Collections.Generic.List<HmsChildEntry>();
        const int bufferSize=65536;
        IntPtr buffer=Marshal.AllocHGlobal(bufferSize);
        try
        {
            bool restart=true;
            while(true)
            {
                bool ok=GetFileInformationByHandleEx(handle,restart?11:10,buffer,(uint)bufferSize);
                restart=false;
                if(!ok)
                {
                    int code=Marshal.GetLastWin32Error();
                    if(code==18){error=0;break;}
                    error=code;return null;
                }
                int offset=0;
                while(true)
                {
                    IntPtr entry=IntPtr.Add(buffer,offset);
                    uint next=unchecked((uint)Marshal.ReadInt32(entry,0));
                    uint attrs=unchecked((uint)Marshal.ReadInt32(entry,56));
                    uint nameBytes=unchecked((uint)Marshal.ReadInt32(entry,60));
                    ulong fileId=unchecked((ulong)Marshal.ReadInt64(entry,96));
                    if(nameBytes>32768 || (nameBytes&1)!=0){error=13;return null;}
                    string name=Marshal.PtrToStringUni(IntPtr.Add(entry,104),(int)(nameBytes/2));
                    if(name!="." && name!="..") result.Add(new HmsChildEntry(name,fileId,attrs));
                    if(next==0)break;
                    if(next<104 || offset+(long)next>=bufferSize){error=13;return null;}
                    offset+=(int)next;
                }
            }
            error=0;return result.ToArray();
        }
        finally{Marshal.FreeHGlobal(buffer);}
    }
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

function Remove-HmsUninstallExactChildren {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    if ($null -eq $Guard.Handle -or $Guard.Handle.IsClosed -or $Guard.Handle.IsInvalid) { throw "$Label exact parent handle is unavailable for child enumeration." }
    $enumCode=0
    $entries=@([HmsUninstallExactFsNative]::EnumerateChildrenByHandle($Guard.Handle,[ref]$enumCode))
    if ($enumCode -ne 0) { throw "$Label exact child enumeration failed (Win32=$enumCode): $($Guard.Path)" }
    $probe=[string]$env:HMS_TEST_EXACT_CHILD_ENUM_READY
    if (-not [string]::IsNullOrWhiteSpace($probe) -and $entries.Count -gt 0) {
        $env:HMS_TEST_EXACT_CHILD_ENUM_READY=''
        [IO.File]::WriteAllText($probe,(Join-Path $Guard.Path ([string]$entries[0].Name)),(New-Object Text.UTF8Encoding($false)))
        Start-Sleep -Milliseconds 1200
    }
    foreach ($entry in $entries) {
        $name=[string]$entry.Name
        if ([string]::IsNullOrWhiteSpace($name) -or $name -in @('.','..') -or $name.Contains('\') -or $name.Contains('/')) { throw "$Label exact child enumeration returned an unsafe name: $name" }
        $childPath=Join-Path $Guard.Path $name
        $expectedDirectory=(([uint32]$entry.Attributes -band [uint32]0x10) -ne 0)
        $expectedReparse=(([uint32]$entry.Attributes -band [uint32]0x400) -ne 0)
        $access=[uint32]0x00010080
        if ($expectedDirectory -and -not $expectedReparse) { $access=[uint32]($access -bor [uint32]1) }
        $child=[HmsUninstallExactFsNative]::CreateFileW($childPath,$access,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero)
        if ($null -eq $child -or $child.IsInvalid) {
            $code=[Runtime.InteropServices.Marshal]::GetLastWin32Error(); if($null -ne $child){$child.Dispose()}
            throw "$Label exact child open failed after enumeration (Win32=$code): $childPath"
        }
        try {
            $info=New-Object 'HmsUninstallExactFsNative+BY_HANDLE_FILE_INFORMATION'
            if (-not [HmsUninstallExactFsNative]::GetFileInformationByHandle($child,[ref]$info)) { $code=[Runtime.InteropServices.Marshal]::GetLastWin32Error(); throw "$Label exact child identity read failed (Win32=$code): $childPath" }
            $actualId=([uint64]$info.FileIndexHigh * [uint64]4294967296) + [uint64]$info.FileIndexLow
            if ($actualId -ne [uint64]$entry.FileId) { throw "$Label child identity changed between enumeration and exact-handle open; refusing foreign replacement: $childPath" }
            $actualDirectory=(($info.FileAttributes -band [uint32]0x10) -ne 0)
            $actualReparse=(($info.FileAttributes -band [uint32]0x400) -ne 0)
            if ($actualDirectory -ne $expectedDirectory -or $actualReparse -ne $expectedReparse) { throw "$Label child type changed between enumeration and exact-handle open: $childPath" }
            if ($actualDirectory -and -not $actualReparse) {
                Remove-HmsUninstallExactChildren -Guard ([pscustomobject]@{Handle=$child;Path=$childPath}) -Label "$Label child '$name'"
            }
            if (($info.FileAttributes -band [uint32]1) -ne 0) {
                $attrs=[IO.File]::GetAttributes($childPath)
                [IO.File]::SetAttributes($childPath,($attrs -band (-bnot [IO.FileAttributes]::ReadOnly)))
            }
            $deleteCode=0
            if (-not [HmsUninstallExactFsNative]::DeleteByHandle($child,[ref]$deleteCode)) { throw "$Label exact child delete-pending transition failed (Win32=$deleteCode): $childPath" }
            $child.Dispose(); $child=$null
            if (Test-Path -LiteralPath $childPath) { throw "$Label child pathname became occupied after exact-object deletion; refusing further destructive work: $childPath" }
        }
        finally { if ($null -ne $child) { $child.Dispose() } }
    }
    $remainingCode=0
    $remaining=@([HmsUninstallExactFsNative]::EnumerateChildrenByHandle($Guard.Handle,[ref]$remainingCode))
    if ($remainingCode -ne 0) { throw "$Label exact post-delete enumeration failed (Win32=$remainingCode): $($Guard.Path)" }
    if ($remaining.Count -ne 0) { throw "$Label exact parent gained or retained children during cleanup; refusing root deletion: $($Guard.Path)" }
}

function Get-HmsUninstallDirectoryIdentityFromHandle { param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label) $info=New-Object 'HmsUninstallExactFsNative+BY_HANDLE_FILE_INFORMATION';if(-not[HmsUninstallExactFsNative]::GetFileInformationByHandle($Handle,[ref]$info)){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "$Label could not read exact directory identity (Win32=$code)."};if(($info.FileAttributes-band[uint32]0x10)-eq 0-or($info.FileAttributes-band[uint32]0x400)-ne 0){throw "$Label must be a regular non-reparse directory."};return([string]$info.VolumeSerialNumber+':'+[string]$info.FileIndexHigh+':'+[string]$info.FileIndexLow) }
function Open-HmsUninstallDirectoryGuard { param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label) if ($env:OS -cne 'Windows_NT'){return $null};$h=[HmsUninstallExactFsNative]::CreateFileW($Path,[uint32]0x00010001,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero);if ($null -eq $h -or $h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if ($null -ne $h){$h.Dispose()};throw "$Label could not open exact DELETE-capable directory handle (Win32=$code): $Path"};try{$id=Get-HmsUninstallDirectoryIdentityFromHandle -Handle $h -Label $Label;return [pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw} }
function Move-HmsUninstallDirectoryGuard { param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label) $before=Get-HmsUninstallDirectoryIdentityFromHandle -Handle $Guard.Handle -Label $Label;if ($before -cne [string]$Guard.Identity){throw "$Label exact directory identity changed before rename."};if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"};$code=0;if(-not[HmsUninstallExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact handle rename failed (Win32=$code): $Destination"};$after=Get-HmsUninstallDirectoryIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename";if ($after -cne [string]$Guard.Identity){throw "$Label exact directory identity changed across rename."};$Guard.Path=$Destination }
function Get-HmsUninstallPortableDirectoryIdentity {
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

function Invoke-HmsUninstallExactDirectoryRemoval {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Validate,
        [scriptblock]$OnQuarantined = $null
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }

    if ($env:OS -cne 'Windows_NT') {
        $ownedIdentity = Get-HmsUninstallPortableDirectoryIdentity -Path $Path -Label $Label
        &$Validate $Path
        $q = Join-Path (Split-Path -Parent $Path) ($Prefix + [guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $q) { throw "$Label portable quarantine destination is occupied: $q" }
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $q) -ErrorAction Stop
        if ((Get-HmsUninstallPortableDirectoryIdentity -Path $q -Label "$Label post-rename") -cne $ownedIdentity) { throw "$Label portable directory identity changed across quarantine rename: $q" }
        &$Validate $q
        if ($null -ne $OnQuarantined) { &$OnQuarantined $q }

        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) {
            if ((Get-HmsUninstallPortableDirectoryIdentity -Path $q -Label "$Label pre-child-delete") -cne $ownedIdentity) { throw "$Label portable quarantine root identity changed before child deletion: $q" }
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
        if ((Get-HmsUninstallPortableDirectoryIdentity -Path $q -Label "$Label pre-root-delete") -cne $ownedIdentity) { throw "$Label portable quarantine root identity changed before empty-root deletion: $q" }
        if (@(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop).Count -ne 0) { throw "$Label portable quarantine root is not empty after child deletion: $q" }
        Remove-Item -LiteralPath $q -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $q) { throw "$Label portable quarantine root remained after empty-root deletion: $q" }
        return
    }

    $guard = Open-HmsUninstallDirectoryGuard -Path $Path -Label $Label
    $renamed = $false
    $deleteStarted = $false
    $q = Join-Path (Split-Path -Parent $Path) ($Prefix + [guid]::NewGuid().ToString('N'))
    try {
        &$Validate $Path
        Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $q -Label $Label
        $renamed = $true
        &$Validate $q
        if ($null -ne $OnQuarantined) { &$OnQuarantined $q }
        $deleteStarted = $true
        Remove-HmsUninstallExactChildren -Guard $guard -Label $Label
        $code = 0
        if (-not [HmsUninstallExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)) { throw "$Label exact root delete-pending transition failed (Win32=$code): $q" }
        $guard.Handle.Dispose()
        $guard.Handle = $null
        if (Test-Path -LiteralPath $q) { throw "$Label exact quarantine remained after handle deletion: $q" }
    }
    catch {
        $e = $_
        if (-not $deleteStarted -and $renamed -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and -not (Test-Path -LiteralPath $Path)) {
            try { Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $Path -Label "$Label pre-delete rollback" } catch {}
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
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring(0, $value.Length - 4) }
    return $value.ToLowerInvariant()
}

function Assert-SafeRemovalPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    $userRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
    $codexRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root -or $full -eq $userRoot -or $full -eq $codexRoot) { throw "Refusing unsafe recursive removal target: $Path" }
}

function Assert-CloneIdentity {
    param([string]$Path,[string]$ExpectedRemote,[string]$MarkerRelativePath)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-SafeRemovalPath -Path $Path
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Refusing to remove non-Git clone path: $Path" }
    if (-not (Test-Path -LiteralPath (Join-Path $Path $MarkerRelativePath))) { throw "Refusing to remove clone without expected marker '$MarkerRelativePath': $Path" }
    $gitDir = Join-Path $Path '.git'
    $origin = & git "--git-dir=$gitDir" config --get remote.origin.url
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) { throw "Refusing to remove clone with unexpected origin: $Path" }
}

function Assert-OwnedCompositeRoot {
    param([string]$Path = $compositeRoot)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    Assert-SafeRemovalPath -Path $Path
    if (-not [bool]$item.PSIsContainer) { throw "Refusing to remove non-directory composite path: $Path" }
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing to remove composite reparse point: $Path" }
    $manifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Refusing to remove composite without ownership manifest: $Path" }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Refusing to remove composite with invalid manifest: $($_.Exception.Message)" }
    if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex' -or [string]$manifest.artifact -cne 'hms-superpowers-composite') { throw "Refusing to remove composite with unexpected ownership: $Path" }
}

function Assert-ManagedCodeGraphRoot {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    Assert-SafeRemovalPath -Path $Path
    if (-not [bool]$item.PSIsContainer) { throw "Refusing to remove non-directory CodeGraph path: $Path" }
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing to remove CodeGraph reparse point: $Path" }
    $manifestPath = Join-Path $Path 'hms-codegraph-install.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Refusing to remove CodeGraph directory without HMS ownership manifest: $Path" }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Refusing to remove CodeGraph directory with invalid HMS ownership manifest: $($_.Exception.Message)" }
    if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex') { throw "Unexpected CodeGraph owner: $Path" }
}

function Get-ExactJunctionState {
    param([string]$Path,[string]$ExpectedTarget)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 'Absent' }
    if (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing to remove non-reparse path: $Path" }
    $linkType = if ($null -eq $item.PSObject.Properties['LinkType']) { '' } else { [string]$item.LinkType }
    if ($linkType -ine 'Junction') { throw "Refusing to remove non-Junction reparse point: $Path (LinkType='$linkType')" }
    if (-not (Test-Path -LiteralPath $ExpectedTarget)) { throw "Expected Junction target does not exist: $ExpectedTarget" }
    $expected = (Resolve-Path -LiteralPath $ExpectedTarget).Path
    foreach ($candidate in @($item.Target)) {
        if (-not $candidate) { continue }
        try { if ((Resolve-Path -LiteralPath $candidate).Path -ieq $expected) { return 'Exact' } } catch { }
    }
    throw "Refusing to remove Junction with unexpected target: $Path"
}

function Restore-Quarantine {
    param([string]$Original,[string]$Quarantine)
    if ($null -eq (Get-Item -LiteralPath $Quarantine -Force -ErrorAction SilentlyContinue)) { return }
    if ($null -ne (Get-Item -LiteralPath $Original -Force -ErrorAction SilentlyContinue)) { throw "Cannot restore quarantined path because original path is occupied: $Original" }
    Rename-Item -LiteralPath $Quarantine -NewName (Split-Path -Leaf $Original) -ErrorAction Stop
}

function Remove-VerifiedJunction {
    param([string]$Path,[string]$ExpectedTarget)
    $state = Get-ExactJunctionState -Path $Path -ExpectedTarget $ExpectedTarget
    if ($state -eq 'Absent') { return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove verified skill Junction')) { return }

    $parent = Split-Path -Parent $Path
    $leaf = '.hms-uninstall-' + [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent $leaf
    Rename-Item -LiteralPath $Path -NewName $leaf -ErrorAction Stop
    try {
        if ((Get-ExactJunctionState -Path $quarantine -ExpectedTarget $ExpectedTarget) -ne 'Exact') { throw 'Quarantined Junction identity mismatch.' }
        & $env:ComSpec /d /c "rmdir `"$quarantine`""
        if ($LASTEXITCODE -ne 0) { throw "rmdir failed with exit code $LASTEXITCODE" }
    }
    catch {
        $e = $_
        try { Restore-Quarantine -Original $Path -Quarantine $quarantine }
        catch { throw "Junction removal failed and rollback was incomplete. Original: $($e.Exception.Message). Rollback: $($_.Exception.Message)" }
        throw $e
    }
}

function Remove-VerifiedClone {
    param([string]$Path,[string]$ExpectedRemote,[string]$MarkerRelativePath,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-CloneIdentity -Path $Path -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return }

    $assertCloneIdentity = ${function:Assert-CloneIdentity}
    $validator = {
        param($p)
        & $assertCloneIdentity -Path $p -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath
    }.GetNewClosure()
    $quarantineValidator = {
        param($quarantine)
        & $assertCloneIdentity -Path $quarantine -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath
    }.GetNewClosure()

    Invoke-HmsUninstallExactDirectoryRemoval `
        -Path $Path `
        -Prefix '.hms-clone-removing-' `
        -Label 'Verified clone uninstall cleanup' `
        -Validate $validator `
        -OnQuarantined $quarantineValidator
}



function Remove-VerifiedCompositeRoot {
    param([string]$Path,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-OwnedCompositeRoot -Path $Path
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return }
    $assertOwnedCompositeRoot = ${function:Assert-OwnedCompositeRoot}
    $validator={param($p) & $assertOwnedCompositeRoot -Path $p}.GetNewClosure()
    Invoke-HmsUninstallExactDirectoryRemoval -Path $Path -Prefix '.hms-composite-removing-' -Label 'Verified composite uninstall cleanup' -Validate $validator
}



function Remove-VerifiedCodeGraphRoot {
    param([string]$Path,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-ManagedCodeGraphRoot -Path $Path
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return }
    $assertManagedCodeGraphRoot = ${function:Assert-ManagedCodeGraphRoot}
    $validator={param($p) & $assertManagedCodeGraphRoot -Path $p}.GetNewClosure()
    Invoke-HmsUninstallExactDirectoryRemoval -Path $Path -Prefix '.hms-codegraph-removing-' -Label 'Verified CodeGraph uninstall cleanup' -Validate $validator
}


function Remove-VerifiedDirectory {
    param([string]$Path,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-SafeRemovalPath -Path $Path
    if ($PSCmdlet.ShouldProcess($Path, $Action)) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        if (Test-Path -LiteralPath $Path) { throw "Removal did not complete: $Path" }
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

    # Preflight all selected managed paths before mutation while the same lock excludes
    # builders/installers/updaters/source reconcilers from touching these paths.
    if (Test-Path -LiteralPath $compositeRoot) { Assert-OwnedCompositeRoot }
    Get-ExactJunctionState -Path $compositeLink -ExpectedTarget $compositeRoot | Out-Null
    Get-ExactJunctionState -Path $hmsLegacyLink -ExpectedTarget (Join-Path $hmsClone 'skills') | Out-Null
    if ($IncludeSuperpowers) { Get-ExactJunctionState -Path $superpowersLegacyLink -ExpectedTarget (Join-Path $superpowersClone 'skills') | Out-Null }
    if ($IncludeUiSkills) {
        Get-ExactJunctionState -Path $tasteLegacyLink -ExpectedTarget (Join-Path $tasteClone 'skills\gpt-tasteskill') | Out-Null
        Get-ExactJunctionState -Path $impeccableLegacyLink -ExpectedTarget (Join-Path $impeccableClone '.agents\skills\impeccable') | Out-Null
    }

    if ($RemoveClones) {
        Assert-OwnedCompositeRoot
        Assert-CloneIdentity -Path $hmsClone -ExpectedRemote $HmsRemote -MarkerRelativePath 'skills\hms-superpowers\SKILL.md'
        if ($IncludeSuperpowers) { Assert-CloneIdentity -Path $superpowersClone -ExpectedRemote $SuperpowersRemote -MarkerRelativePath 'skills\brainstorming\SKILL.md' }
        if ($IncludeUiSkills) {
            Assert-CloneIdentity -Path $tasteClone -ExpectedRemote $TasteRemote -MarkerRelativePath 'skills\gpt-tasteskill\SKILL.md'
            Assert-CloneIdentity -Path $impeccableClone -ExpectedRemote $ImpeccableRemote -MarkerRelativePath '.agents\skills\impeccable\SKILL.md'
        }
        if ($IncludeDeliveryTools) {
            Assert-ManagedCodeGraphRoot -Path $codeGraphRoot
            Assert-CloneIdentity -Path $threeLevelClone -ExpectedRemote $ThreeLevelRemote -MarkerRelativePath 'three-level-delivery\SKILL.md'
        }
    }

    if ($IncludeDeliveryTools) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1'))) { throw 'Cannot safely remove delivery-tool configuration because Sync-DeliveryTools.ps1 is unavailable.' }
        if ($PSCmdlet.ShouldProcess('Codex MCP server codegraph', 'Remove HMS-managed CodeGraph MCP configuration')) {
            & (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1') -RemoveCodeGraphConfig -SkipThreeLevelDelivery
        }
    }

    Remove-VerifiedJunction -Path $compositeLink -ExpectedTarget $compositeRoot
    Remove-VerifiedJunction -Path $hmsLegacyLink -ExpectedTarget (Join-Path $hmsClone 'skills')
    if ($IncludeSuperpowers) { Remove-VerifiedJunction -Path $superpowersLegacyLink -ExpectedTarget (Join-Path $superpowersClone 'skills') }
    if ($IncludeUiSkills) {
        Remove-VerifiedJunction -Path $tasteLegacyLink -ExpectedTarget (Join-Path $tasteClone 'skills\gpt-tasteskill')
        Remove-VerifiedJunction -Path $impeccableLegacyLink -ExpectedTarget (Join-Path $impeccableClone '.agents\skills\impeccable')
    }

    if ($RemoveClones) {
        Remove-VerifiedCompositeRoot -Path $compositeRoot -Action 'Remove verified HMS composite bundle'
        if ($IncludeSuperpowers) { Remove-VerifiedClone -Path $superpowersClone -ExpectedRemote $SuperpowersRemote -MarkerRelativePath 'skills\brainstorming\SKILL.md' -Action 'Remove verified Superpowers clone' }
        if ($IncludeUiSkills) {
            Remove-VerifiedClone -Path $tasteClone -ExpectedRemote $TasteRemote -MarkerRelativePath 'skills\gpt-tasteskill\SKILL.md' -Action 'Remove verified Taste clone'
            Remove-VerifiedClone -Path $impeccableClone -ExpectedRemote $ImpeccableRemote -MarkerRelativePath '.agents\skills\impeccable\SKILL.md' -Action 'Remove verified Impeccable clone'
        }
        if ($IncludeDeliveryTools) {
            Remove-VerifiedClone -Path $threeLevelClone -ExpectedRemote $ThreeLevelRemote -MarkerRelativePath 'three-level-delivery\SKILL.md' -Action 'Remove verified Three-Level Delivery clone'
            Remove-VerifiedCodeGraphRoot -Path $codeGraphRoot -Action 'Remove verified HMS CodeGraph directory'
        }
        Remove-VerifiedClone -Path $hmsClone -ExpectedRemote $HmsRemote -MarkerRelativePath 'skills\hms-superpowers\SKILL.md' -Action 'Remove verified HMS clone'
    }

    Write-Host 'Requested HMS Skills Codex uninstall actions completed.'
}
finally {
    if ($mutexOwned) {
        try { $buildMutex.ReleaseMutex() } catch { }
    }
    $buildMutex.Dispose()
}
