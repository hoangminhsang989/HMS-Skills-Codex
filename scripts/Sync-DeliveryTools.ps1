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
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool ReplaceFileW(string replacedFileName,string replacementFileName,string backupFileName,uint flags,IntPtr exclude,IntPtr reserved);
    public static bool ReplaceFileWithoutBackup(string replacedFileName,string replacementFileName,out int error)
    { bool ok=ReplaceFileW(replacedFileName,replacementFileName,null,0,IntPtr.Zero,IntPtr.Zero);error=ok?0:Marshal.GetLastWin32Error();return ok; }
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
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool GetFileSizeEx(SafeFileHandle h,out long size);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SetFilePointerEx(SafeFileHandle h,long distance,out long newPointer,uint moveMethod);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool ReadFile(SafeFileHandle h,byte[] buffer,uint bytesToRead,out uint bytesRead,IntPtr overlapped);
    public static byte[] ReadAllBytesByHandle(SafeFileHandle handle,out int error)
    {
        long size;
        if(!GetFileSizeEx(handle,out size)){error=Marshal.GetLastWin32Error();return null;}
        if(size<0 || size>Int32.MaxValue){error=223;return null;}
        long position;
        if(!SetFilePointerEx(handle,0,out position,0)){error=Marshal.GetLastWin32Error();return null;}
        byte[] result=new byte[(int)size];
        int offset=0;
        while(offset<result.Length)
        {
            int count=Math.Min(1048576,result.Length-offset);
            byte[] chunk=new byte[count];
            uint read;
            if(!ReadFile(handle,chunk,(uint)count,out read,IntPtr.Zero)){error=Marshal.GetLastWin32Error();return null;}
            if(read==0){error=38;return null;}
            Buffer.BlockCopy(chunk,0,result,offset,(int)read);
            offset+=(int)read;
        }
        error=0;return result;
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

function Get-HmsDeliveryDirectoryIdentityFromHandle { param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label) $info=New-Object 'HmsDeliveryExactFsNative+BY_HANDLE_FILE_INFORMATION';if(-not[HmsDeliveryExactFsNative]::GetFileInformationByHandle($Handle,[ref]$info)){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "$Label could not read exact directory identity (Win32=$code)."};if(($info.FileAttributes-band[uint32]0x10)-eq 0 -or ($info.FileAttributes-band[uint32]0x400)-ne 0){throw "$Label must be a regular non-reparse directory."};return([string]$info.VolumeSerialNumber+':'+[string]$info.FileIndexHigh+':'+[string]$info.FileIndexLow) }
function Open-HmsDeliveryDirectoryGuard { param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label) if ($env:OS -cne 'Windows_NT'){return $null};$h=[HmsDeliveryExactFsNative]::CreateFileW($Path,[uint32]0x00010001,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero);if ($null -eq $h -or $h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if ($null -ne $h){$h.Dispose()};throw "$Label could not open exact DELETE-capable directory handle (Win32=$code): $Path"};try{$id=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $h -Label $Label;return [pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw} }
function Move-HmsDeliveryDirectoryGuard { param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label) $before=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $Guard.Handle -Label $Label;if ($before -cne [string]$Guard.Identity){throw "$Label exact directory identity changed before rename."};if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"};$code=0;if(-not[HmsDeliveryExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact handle rename failed (Win32=$code): $Destination"};$after=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename";if ($after -cne [string]$Guard.Identity){throw "$Label exact directory identity changed across rename."};$Guard.Path=$Destination }
function Get-HmsDeliveryFileIdentityFromHandle {
    param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label)
    $info=New-Object 'HmsDeliveryExactFsNative+BY_HANDLE_FILE_INFORMATION'
    if(-not[HmsDeliveryExactFsNative]::GetFileInformationByHandle($Handle,[ref]$info)){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "$Label could not read exact file identity (Win32=$code)."}
    if(($info.FileAttributes-band[uint32]0x10)-ne 0 -or ($info.FileAttributes-band[uint32]0x400)-ne 0){throw "$Label must be a regular non-reparse file."}
    return([string]$info.VolumeSerialNumber+':'+[string]$info.FileIndexHigh+':'+[string]$info.FileIndexLow)
}
function Open-HmsDeliveryFileGuard {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $h=[HmsDeliveryExactFsNative]::CreateFileW($Path,[uint32]2147549184,[uint32]1,[IntPtr]::Zero,[uint32]3,[uint32]0x00200000,[IntPtr]::Zero)
    if($null -eq $h -or $h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if($null -ne $h){$h.Dispose()};throw "$Label could not open exact read+DELETE file handle (Win32=$code): $Path"}
    try{$id=Get-HmsDeliveryFileIdentityFromHandle -Handle $h -Label $Label;return [pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw}
}
function Read-HmsDeliveryFileBytesFromGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    if($null -eq $Guard.Handle -or $Guard.Handle.IsClosed -or $Guard.Handle.IsInvalid){throw "$Label exact file guard is unavailable for read."}
    if((Get-HmsDeliveryFileIdentityFromHandle -Handle $Guard.Handle -Label $Label)-cne[string]$Guard.Identity){throw "$Label exact file identity changed before read."}
    $readCode=0;$bytes=[HmsDeliveryExactFsNative]::ReadAllBytesByHandle($Guard.Handle,[ref]$readCode);if($readCode -ne 0 -or $null -eq $bytes){throw "$Label exact guarded-handle read failed (Win32=$readCode)."}
    if((Get-HmsDeliveryFileIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-read")-cne[string]$Guard.Identity){throw "$Label exact file identity changed across read."}
    return [byte[]]$bytes
}
function Move-HmsDeliveryFileGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label)
    if((Get-HmsDeliveryFileIdentityFromHandle -Handle $Guard.Handle -Label $Label)-cne[string]$Guard.Identity){throw "$Label exact file identity changed before rename."}
    if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"}
    $code=0;if(-not[HmsDeliveryExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact file handle rename failed (Win32=$code): $Destination"}
    if((Get-HmsDeliveryFileIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename")-cne[string]$Guard.Identity){throw "$Label exact file identity changed across rename."}
    $Guard.Path=$Destination
}
function Remove-HmsDeliveryFileGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    if((Get-HmsDeliveryFileIdentityFromHandle -Handle $Guard.Handle -Label $Label)-cne[string]$Guard.Identity){throw "$Label exact file identity changed before deletion."}
    $code=0;if(-not[HmsDeliveryExactFsNative]::DeleteByHandle($Guard.Handle,[ref]$code)){throw "$Label exact file delete-pending transition failed (Win32=$code): $($Guard.Path)"}
    $Guard.Handle.Dispose();$Guard.Handle=$null
}
function Test-HmsExactBytesEqual {
    param([byte[]]$Left,[byte[]]$Right)
    if($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length){return $false}
    for($i=0;$i -lt $Left.Length;$i++){if($Left[$i]-ne$Right[$i]){return $false}}
    return $true
}

function Remove-HmsDeliveryExactChildren {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    if ($null -eq $Guard.Handle -or $Guard.Handle.IsClosed -or $Guard.Handle.IsInvalid) { throw "$Label exact parent handle is unavailable for child enumeration." }
    $enumCode=0
    $entries=@([HmsDeliveryExactFsNative]::EnumerateChildrenByHandle($Guard.Handle,[ref]$enumCode))
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
        $child=[HmsDeliveryExactFsNative]::CreateFileW($childPath,$access,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero)
        if ($null -eq $child -or $child.IsInvalid) {
            $code=[Runtime.InteropServices.Marshal]::GetLastWin32Error(); if($null -ne $child){$child.Dispose()}
            throw "$Label exact child open failed after enumeration (Win32=$code): $childPath"
        }
        try {
            $info=New-Object 'HmsDeliveryExactFsNative+BY_HANDLE_FILE_INFORMATION'
            if (-not [HmsDeliveryExactFsNative]::GetFileInformationByHandle($child,[ref]$info)) { $code=[Runtime.InteropServices.Marshal]::GetLastWin32Error(); throw "$Label exact child identity read failed (Win32=$code): $childPath" }
            $actualId=([uint64]$info.FileIndexHigh * [uint64]4294967296) + [uint64]$info.FileIndexLow
            if ($actualId -ne [uint64]$entry.FileId) { throw "$Label child identity changed between enumeration and exact-handle open; refusing foreign replacement: $childPath" }
            $actualDirectory=(($info.FileAttributes -band [uint32]0x10) -ne 0)
            $actualReparse=(($info.FileAttributes -band [uint32]0x400) -ne 0)
            if ($actualDirectory -ne $expectedDirectory -or $actualReparse -ne $expectedReparse) { throw "$Label child type changed between enumeration and exact-handle open: $childPath" }
            if ($actualDirectory -and -not $actualReparse) {
                Remove-HmsDeliveryExactChildren -Guard ([pscustomobject]@{Handle=$child;Path=$childPath}) -Label "$Label child '$name'"
            }
            if (($info.FileAttributes -band [uint32]1) -ne 0) {
                $attrs=[IO.File]::GetAttributes($childPath)
                [IO.File]::SetAttributes($childPath,($attrs -band (-bnot [IO.FileAttributes]::ReadOnly)))
            }
            $deleteCode=0
            if (-not [HmsDeliveryExactFsNative]::DeleteByHandle($child,[ref]$deleteCode)) { throw "$Label exact child delete-pending transition failed (Win32=$deleteCode): $childPath" }
            $child.Dispose(); $child=$null
            if (Test-Path -LiteralPath $childPath) { throw "$Label child pathname became occupied after exact-object deletion; refusing further destructive work: $childPath" }
        }
        finally { if ($null -ne $child) { $child.Dispose() } }
    }
    $remainingCode=0
    $remaining=@([HmsDeliveryExactFsNative]::EnumerateChildrenByHandle($Guard.Handle,[ref]$remainingCode))
    if ($remainingCode -ne 0) { throw "$Label exact post-delete enumeration failed (Win32=$remainingCode): $($Guard.Path)" }
    if ($remaining.Count -ne 0) { throw "$Label exact parent gained or retained children during cleanup; refusing root deletion: $($Guard.Path)" }
}

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
        Remove-HmsDeliveryExactChildren -Guard $guard -Label $Label
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


function Get-CodeGraphArchiveLogicalTreeSha256 {
    param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][string]$Architecture)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $files = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Name) })
        if ($files.Count -eq 0) { throw "CodeGraph verified archive contains no files: $ArchivePath" }
        $prefix = "codegraph-win32-$Architecture/"
        $prefixed = @($files | Where-Object { ([string]$_.FullName).Replace('\\','/').StartsWith($prefix,[StringComparison]::Ordinal) })
        $selected = if ($prefixed.Count -gt 0) { $prefixed } else { $files }
        $records = New-Object System.Collections.Generic.List[string]
        $seen = @{}
        foreach ($entry in $selected) {
            $name = ([string]$entry.FullName).Replace('\\','/')
            $logical = if ($prefixed.Count -gt 0) { $name.Substring($prefix.Length) } else { $name.TrimStart('/') }
            if ([string]::IsNullOrWhiteSpace($logical) -or $logical.StartsWith('/') -or $logical.Contains('\\') -or $logical -match '(^|/)\.\.(/|$)' -or $logical -match '^[A-Za-z]:') { throw "CodeGraph archive contains unsafe logical path: $name" }
            $key = $logical.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "CodeGraph archive contains duplicate Windows logical path: $logical" }
            $seen[$key] = $true
            $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            $records.Add($logical + "`t" + $hash)
        }
        $sorted = [string[]]@($records); [Array]::Sort($sorted,[StringComparer]::Ordinal)
        $payload = [string]::Join("`n",$sorted)
        $treeSha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($treeSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))).Replace('-','').ToLowerInvariant() }
        finally { $treeSha.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Get-HmsDeliveryFileSha256 {
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
function Open-CodeGraphVerifiedArchive {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedSha256,[Parameter(Mandatory)][string]$Architecture)
    $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $actual = Get-HmsDeliveryFileSha256 -Path $Path
        if ($actual -cne $ExpectedSha256) { throw "CodeGraph release asset SHA-256 mismatch. Expected $ExpectedSha256, found $actual" }
        $tree = Get-CodeGraphArchiveLogicalTreeSha256 -ArchivePath $Path -Architecture $Architecture
        return [pscustomobject]@{ Stream=$stream; ExpectedTreeSha256=$tree; AssetSha256=$actual }
    }
    catch { $stream.Dispose(); throw }
}

function Move-CodeGraphCandidateToCurrent {
    param([Parameter(Mandatory)][string]$CandidatePath,[Parameter(Mandatory)][string]$CurrentPath,[Parameter(Mandatory)]$Identity)
    if (Test-Path -LiteralPath $CurrentPath) { throw "CodeGraph current path is occupied before candidate activation: $CurrentPath" }
    $guard = Open-HmsDeliveryDirectoryGuard -Path $CandidatePath -Label 'CodeGraph candidate activation'
    try {
        Assert-CodeGraphTransactionBundle -Path $CandidatePath -Identity $Identity
        $probe = [string]$env:HMS_TEST_CODEGRAPH_CANDIDATE_GUARD_READY
        if (-not [string]::IsNullOrWhiteSpace($probe)) { [IO.File]::WriteAllText($probe,$CandidatePath,(New-Object Text.UTF8Encoding($false))); Start-Sleep -Milliseconds 1200 }
        Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $CurrentPath -Label 'CodeGraph candidate activation'
        Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $Identity
        return $guard
    }
    catch {
        $e=$_
        if ($null -ne $guard -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and [string]$guard.Path -ceq $CurrentPath -and -not (Test-Path -LiteralPath $CandidatePath)) {
            try { Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $CandidatePath -Label 'CodeGraph candidate activation rollback'; Assert-CodeGraphTransactionBundle -Path $CandidatePath -Identity $Identity }
            catch { throw "CodeGraph candidate activation failed and exact-object return also failed. Original: $($e.Exception.Message). Return: $($_.Exception.Message)" }
        }
        if ($null -ne $guard -and $null -ne $guard.Handle) { $guard.Handle.Dispose(); $guard.Handle = $null }
        throw $e
    }
}

function Open-ManagedCodeGraphManifestState {
    if(-not(Test-Path -LiteralPath $CodeGraphRoot)){return $null}
    if(-not(Test-Path -LiteralPath $CodeGraphManifest)){throw "Refusing to overwrite existing CodeGraph path not owned by HMS Skills Codex: $CodeGraphRoot"}
    $guard=Open-HmsDeliveryFileGuard -Path $CodeGraphManifest -Label 'Managed CodeGraph manifest'
    try{
        $record=Convert-CodeGraphJsonGuardToObject -Guard $guard -Label 'Managed CodeGraph manifest'
        if([string]$record.Object.managed_by -cne $ManagedBy){throw "Unexpected CodeGraph installation owner at $CodeGraphRoot"}
        return [pscustomobject]@{Manifest=$record.Object;Bytes=[byte[]]$record.Bytes;Guard=$guard}
    }catch{$guard.Handle.Dispose();throw}
}
function Read-ManagedCodeGraphManifest {
    $state=Open-ManagedCodeGraphManifestState
    if($null -eq $state){return $null}
    try{return $state.Manifest}finally{if($null -ne $state.Guard -and $null -ne $state.Guard.Handle){$state.Guard.Handle.Dispose();$state.Guard.Handle=$null}}
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
        $hash = Get-HmsDeliveryFileSha256 -Path $item.FullName
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

function Convert-CodeGraphJsonGuardToObject {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    $bytes=Read-HmsDeliveryFileBytesFromGuard -Guard $Guard -Label $Label
    $strict=New-Object Text.UTF8Encoding($false,$true)
    try{$text=$strict.GetString([byte[]]$bytes);$obj=$text|ConvertFrom-Json}catch{throw "$Label exact bytes are not valid UTF-8 JSON: $($_.Exception.Message)"}
    return [pscustomobject]@{Bytes=[byte[]]$bytes;Object=$obj}
}
function Assert-CodeGraphMarkerGuardIdentity {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$Label)
    $record=Convert-CodeGraphJsonGuardToObject -Guard $Guard -Label $Label
    foreach($field in @('managed_by','artifact','transaction_id','role','version','tag','commit','asset','sha256','bundle_tree_sha256')){
        if([string]$record.Object.$field -cne [string]$Identity[$field]){throw "$Label marker mismatch for '$field'."}
    }
    return $record
}
function Write-CodeGraphBundleMarker {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Identity,$ExpectedPreviousIdentity=$null)
    Assert-RegularCodeGraphBundle -Path $Path -Label 'CodeGraph transaction bundle'
    $treeHash=[string]$Identity['bundle_tree_sha256']
    if([string]::IsNullOrWhiteSpace($treeHash)){$treeHash=Get-CodeGraphBundleTreeSha256 -Path $Path;$Identity['bundle_tree_sha256']=$treeHash}
    if($treeHash -notmatch '^[0-9a-f]{64}$'){throw "CodeGraph transaction identity has invalid bundle tree SHA-256: $treeHash"}
    $markerPath=Join-Path $Path $CodeGraphBundleMarkerName
    $publishParent=Split-Path -Parent $Path
    $publishTemp=Join-Path $publishParent ('.hms-codegraph-marker-publish-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $oldReserved=Join-Path $publishParent ('.hms-codegraph-marker-previous-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $discard=Join-Path $publishParent ('.hms-codegraph-marker-discard-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $json=$Identity|ConvertTo-Json -Depth 4
    $expectedBytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json+"`n")
    $existingGuard=$null;$candidateGuard=$null;$oldMoved=$false;$candidatePublished=$false
    try{
        if(Test-Path -LiteralPath $markerPath){
            if($null -eq $ExpectedPreviousIdentity){throw "CodeGraph transaction marker unexpectedly exists without previous-identity authority: $markerPath"}
            $existingGuard=Open-HmsDeliveryFileGuard -Path $markerPath -Label 'Existing CodeGraph transaction marker'
            $null=Assert-CodeGraphMarkerGuardIdentity -Guard $existingGuard -Identity $ExpectedPreviousIdentity -Label 'Existing CodeGraph transaction marker'
            Move-HmsDeliveryFileGuard -Guard $existingGuard -Destination $oldReserved -Label 'Previous CodeGraph marker reservation'
            $oldMoved=$true
            $probe=[string]$env:HMS_TEST_CODEGRAPH_MARKER_RESERVED_READY
            if(-not[string]::IsNullOrWhiteSpace($probe)){[IO.File]::WriteAllText($probe,$markerPath,(New-Object Text.UTF8Encoding($false)));Start-Sleep -Milliseconds 1200}
        }elseif($null -ne $ExpectedPreviousIdentity){throw "Expected previous CodeGraph transaction marker disappeared before exact publication: $markerPath"}
        [IO.File]::WriteAllBytes($publishTemp,$expectedBytes)
        $candidateGuard=Open-HmsDeliveryFileGuard -Path $publishTemp -Label 'Candidate CodeGraph transaction marker'
        $candidateBytes=Read-HmsDeliveryFileBytesFromGuard -Guard $candidateGuard -Label 'Candidate CodeGraph transaction marker'
        if(-not(Test-HmsExactBytesEqual -Left $candidateBytes -Right $expectedBytes)){throw 'Candidate CodeGraph marker bytes changed before publication.'}
        Move-HmsDeliveryFileGuard -Guard $candidateGuard -Destination $markerPath -Label 'Candidate CodeGraph marker publication'
        $candidatePublished=$true
        $null=Assert-CodeGraphMarkerGuardIdentity -Guard $candidateGuard -Identity $Identity -Label 'Published CodeGraph transaction marker'
        if($null -ne $existingGuard){Remove-HmsDeliveryFileGuard -Guard $existingGuard -Label 'Previous CodeGraph marker disposal';$existingGuard=$null;$oldMoved=$false}
        $candidateGuard.Handle.Dispose();$candidateGuard.Handle=$null;$candidateGuard=$null
    }catch{
        $writeError=$_;$rollbackErrors=@()
        if($null -ne $candidateGuard){try{if($candidatePublished){Move-HmsDeliveryFileGuard -Guard $candidateGuard -Destination $discard -Label 'Candidate CodeGraph marker rollback reservation'};Remove-HmsDeliveryFileGuard -Guard $candidateGuard -Label 'Candidate CodeGraph marker rollback disposal';$candidateGuard=$null}catch{$rollbackErrors+="Candidate marker rollback failed: $($_.Exception.Message)"}}
        if($null -ne $existingGuard -and $oldMoved){try{if(Test-Path -LiteralPath $markerPath){throw "Canonical CodeGraph marker pathname became occupied during rollback: $markerPath"};Move-HmsDeliveryFileGuard -Guard $existingGuard -Destination $markerPath -Label 'Previous CodeGraph marker restoration';$null=Assert-CodeGraphMarkerGuardIdentity -Guard $existingGuard -Identity $ExpectedPreviousIdentity -Label 'Restored previous CodeGraph marker';$existingGuard.Handle.Dispose();$existingGuard.Handle=$null;$existingGuard=$null;$oldMoved=$false}catch{$rollbackErrors+="Previous marker restoration failed: $($_.Exception.Message)"}}
        if($rollbackErrors.Count){throw "CodeGraph marker publication failed and exact-object rollback was incomplete. Original: $($writeError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')"}
        throw $writeError
    }finally{if($null -ne $candidateGuard -and $null -ne $candidateGuard.Handle){$candidateGuard.Handle.Dispose()};if($null -ne $existingGuard -and $null -ne $existingGuard.Handle){$existingGuard.Handle.Dispose()}}
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


function Assert-CodeGraphInstallManifestGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)]$Manifest,[Parameter(Mandatory)][string]$Label)
    $record=Convert-CodeGraphJsonGuardToObject -Guard $Guard -Label $Label
    foreach($field in @('managed_by','version','tag','commit','asset','sha256','bundle_transaction_id','bundle_tree_sha256')){
        $manifestValue=$null
        if($Manifest -is [System.Collections.IDictionary]){
            if(-not $Manifest.Contains($field)){throw "$Label expected manifest is missing '$field'."}
            $manifestValue=$Manifest[$field]
        }
        else{
            if($Manifest.PSObject.Properties.Name -cnotcontains $field){throw "$Label expected manifest is missing '$field'."}
            $manifestValue=$Manifest.$field
        }
        if([string]$record.Object.$field -cne [string]$manifestValue){throw "$Label manifest mismatch for '$field'."}
    }
    return $record
}
function Publish-CodeGraphInstallManifest {
    param([Parameter(Mandatory)]$Manifest,$ExistingState)
    $parent=Split-Path -Parent $CodeGraphManifest
    $temp=Join-Path $parent ('.hms-codegraph-manifest-candidate-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $previousReserved=Join-Path $parent ('.hms-codegraph-manifest-previous-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $discard=Join-Path $parent ('.hms-codegraph-manifest-discard-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $json=$Manifest|ConvertTo-Json
    $expected=(New-Object Text.UTF8Encoding($false)).GetBytes($json+"`n")
    $candidateGuard=$null;$oldMoved=$false;$candidatePublished=$false
    try{
        [IO.File]::WriteAllBytes($temp,$expected)
        $candidateGuard=Open-HmsDeliveryFileGuard -Path $temp -Label 'Candidate CodeGraph install manifest'
        if(-not(Test-HmsExactBytesEqual -Left (Read-HmsDeliveryFileBytesFromGuard -Guard $candidateGuard -Label 'Candidate CodeGraph install manifest') -Right $expected)){throw 'Candidate CodeGraph install manifest bytes changed before publication.'}
        if($null -ne $ExistingState){
            if($null -eq $ExistingState.Guard -or $ExistingState.Guard.Handle.IsClosed){throw 'Existing CodeGraph manifest exact guard is unavailable before publication.'}
            $null=Assert-CodeGraphInstallManifestGuard -Guard $ExistingState.Guard -Manifest $ExistingState.Manifest -Label 'Existing CodeGraph install manifest'
            Move-HmsDeliveryFileGuard -Guard $ExistingState.Guard -Destination $previousReserved -Label 'Previous CodeGraph install manifest reservation';$oldMoved=$true
            $probe=[string]$env:HMS_TEST_CODEGRAPH_MANIFEST_RESERVED_READY
            if(-not[string]::IsNullOrWhiteSpace($probe)){[IO.File]::WriteAllText($probe,$CodeGraphManifest,(New-Object Text.UTF8Encoding($false)));Start-Sleep -Milliseconds 1200}
        }
        Move-HmsDeliveryFileGuard -Guard $candidateGuard -Destination $CodeGraphManifest -Label 'Candidate CodeGraph install manifest publication';$candidatePublished=$true
        $null=Assert-CodeGraphInstallManifestGuard -Guard $candidateGuard -Manifest $Manifest -Label 'Published CodeGraph install manifest'
        if($null -ne $ExistingState){Remove-HmsDeliveryFileGuard -Guard $ExistingState.Guard -Label 'Previous CodeGraph install manifest disposal';$ExistingState.Guard=$null;$oldMoved=$false}
        $result=$candidateGuard;$candidateGuard=$null;return $result
    }catch{
        $writeError=$_;$rollbackErrors=@()
        if($null -ne $candidateGuard){try{if($candidatePublished){Move-HmsDeliveryFileGuard -Guard $candidateGuard -Destination $discard -Label 'Candidate CodeGraph install manifest rollback reservation'};Remove-HmsDeliveryFileGuard -Guard $candidateGuard -Label 'Candidate CodeGraph install manifest rollback disposal';$candidateGuard=$null}catch{$rollbackErrors+="Candidate manifest rollback failed: $($_.Exception.Message)"}}
        if($null -ne $ExistingState -and $oldMoved -and $null -ne $ExistingState.Guard){try{if(Test-Path -LiteralPath $CodeGraphManifest){throw "Canonical CodeGraph manifest pathname became occupied during publication rollback: $CodeGraphManifest"};Move-HmsDeliveryFileGuard -Guard $ExistingState.Guard -Destination $CodeGraphManifest -Label 'Previous CodeGraph install manifest restoration';$null=Assert-CodeGraphInstallManifestGuard -Guard $ExistingState.Guard -Manifest $ExistingState.Manifest -Label 'Restored previous CodeGraph install manifest';$oldMoved=$false}catch{$rollbackErrors+="Previous manifest restoration failed: $($_.Exception.Message)"}}
        if($rollbackErrors.Count){throw "CodeGraph manifest publication failed and exact-object rollback was incomplete. Original: $($writeError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')"}
        throw $writeError
    }finally{if($null -ne $candidateGuard -and $null -ne $candidateGuard.Handle){$candidateGuard.Handle.Dispose()}}
}
function Restore-CodeGraphManifestAfterFailure {
    param([Parameter(Mandatory)]$CandidateManifest,[Parameter(Mandatory)]$CandidateGuard,[byte[]]$PreviousBytes,[Parameter(Mandatory)][bool]$HadPrevious)
    if($null -eq $CandidateGuard -or $null -eq $CandidateGuard.Handle -or $CandidateGuard.Handle.IsClosed){throw 'CodeGraph candidate manifest exact guard is unavailable during rollback.'}
    $null=Assert-CodeGraphInstallManifestGuard -Guard $CandidateGuard -Manifest $CandidateManifest -Label 'CodeGraph candidate manifest rollback authority'
    $parent=Split-Path -Parent $CodeGraphManifest
    $discard=Join-Path $parent ('.hms-codegraph-manifest-rollback-discard-'+[guid]::NewGuid().ToString('N')+'.tmp')
    Move-HmsDeliveryFileGuard -Guard $CandidateGuard -Destination $discard -Label 'CodeGraph candidate manifest rollback reservation'
    if($HadPrevious){
        if($null -eq $PreviousBytes){throw 'CodeGraph rollback is missing previous manifest bytes.'}
        $temp=Join-Path $parent ('.hms-codegraph-manifest-restore-'+[guid]::NewGuid().ToString('N')+'.tmp')
        [IO.File]::WriteAllBytes($temp,$PreviousBytes)
        $previousGuard=Open-HmsDeliveryFileGuard -Path $temp -Label 'Previous CodeGraph manifest reconstruction'
        try{
            if(-not(Test-HmsExactBytesEqual -Left (Read-HmsDeliveryFileBytesFromGuard -Guard $previousGuard -Label 'Previous CodeGraph manifest reconstruction') -Right $PreviousBytes)){throw 'Previous CodeGraph manifest reconstruction changed before restoration.'}
            Move-HmsDeliveryFileGuard -Guard $previousGuard -Destination $CodeGraphManifest -Label 'Previous CodeGraph manifest restoration'
            if(-not(Test-HmsExactBytesEqual -Left (Read-HmsDeliveryFileBytesFromGuard -Guard $previousGuard -Label 'Restored previous CodeGraph manifest') -Right $PreviousBytes)){throw 'Restored previous CodeGraph manifest bytes do not match exact pre-transaction bytes.'}
        }finally{if($null -ne $previousGuard -and $null -ne $previousGuard.Handle){$previousGuard.Handle.Dispose()}}
    }
    Remove-HmsDeliveryFileGuard -Guard $CandidateGuard -Label 'Rolled-back candidate CodeGraph manifest disposal'
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
        $CandidateManifestGuard,
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
            Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $PreviousIdentity -ExpectedPreviousIdentity $BackupIdentity
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
            if ($null -eq $CandidateManifestGuard -or $null -eq $CandidateManifestGuard.Handle -or $CandidateManifestGuard.Handle.IsClosed) { throw 'CodeGraph candidate manifest exact guard disappeared before rollback adjudication.' }
            if ($currentBundleState -ceq 'previous') {
                Restore-CodeGraphManifestAfterFailure -CandidateManifest $PublishedManifest -CandidateGuard $CandidateManifestGuard -PreviousBytes $PreviousManifestBytes -HadPrevious $true
            }
            elseif ($currentBundleState -ceq 'candidate') {
                $null=Assert-CodeGraphInstallManifestGuard -Guard $CandidateManifestGuard -Manifest $PublishedManifest -Label 'Preserved candidate CodeGraph install manifest'
                $CandidateManifestGuard.Handle.Dispose();$CandidateManifestGuard.Handle=$null
            }
            else {
                Restore-CodeGraphManifestAfterFailure -CandidateManifest $PublishedManifest -CandidateGuard $CandidateManifestGuard -PreviousBytes $null -HadPrevious $false
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
    $currentGuard = Open-HmsDeliveryDirectoryGuard -Path $CurrentPath -Label 'CodeGraph current-to-backup transition'
    try {
        $existingIdentity = Assert-CodeGraphBundleAgainstManifest -Path $CurrentPath -Manifest $ExistingManifest
        if ($null -ne $PreviousIdentityRef) { $PreviousIdentityRef.Value = $existingIdentity }
        $markerRewritten = $false
        try {
            Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $BackupIdentity -ExpectedPreviousIdentity $existingIdentity
            $markerRewritten = $true
            Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $BackupIdentity
            $probe = [string]$env:HMS_TEST_CODEGRAPH_CURRENT_GUARD_READY
            if (-not [string]::IsNullOrWhiteSpace($probe)) { [IO.File]::WriteAllText($probe,$CurrentPath,(New-Object Text.UTF8Encoding($false))); Start-Sleep -Milliseconds 1200 }
            Move-HmsDeliveryDirectoryGuard -Guard $currentGuard -Destination $BackupPath -Label 'CodeGraph current-to-backup transition'
            Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
        }
        catch {
            $transitionError = $_
            if ($markerRewritten -and [string]$currentGuard.Path -ceq $CurrentPath -and (Test-Path -LiteralPath $CurrentPath) -and -not (Test-Path -LiteralPath $BackupPath)) {
                try { Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $existingIdentity -ExpectedPreviousIdentity $BackupIdentity; Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $existingIdentity }
                catch { throw "CodeGraph current-to-backup transition failed and original marker restoration was incomplete. Original: $($transitionError.Exception.Message). Rollback: $($_.Exception.Message)" }
            }
            throw $transitionError
        }
        return $existingIdentity
    }
    finally { if ($null -ne $currentGuard -and $null -ne $currentGuard.Handle) { $currentGuard.Handle.Dispose() } }
}

function Sync-CodeGraphBundle {
    param([Parameter(Mandatory)]$Spec)

    if ($env:OS -ne 'Windows_NT') { throw 'The HMS pinned CodeGraph bundle installer currently supports Windows only.' }
    $existingManifestState = Open-ManagedCodeGraphManifestState
    $existingManifest = if ($null -eq $existingManifestState) { $null } else { $existingManifestState.Manifest }
    $wasInstalled = $null -ne $existingManifest
    $existingManifestBytes = if ($null -eq $existingManifestState) { $null } else { [byte[]]$existingManifestState.Bytes }
    try {
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
        $candidateActivationGuard = $null
        $manifestPublished = $false
        $publishedManifest = $null
        $manifestPublicationGuard = $null
        try {
            New-Item -ItemType Directory -Force -Path $temp | Out-Null
            Write-CodeGraphTempMarker -Path $temp -TransactionId $transactionId
            Assert-CodeGraphTempRoot -Path $temp -TransactionId $transactionId
            New-Item -ItemType Directory -Force -Path $extract | Out-Null
            $url = "https://github.com/colbymchenry/codegraph/releases/download/$([string]$Spec.tag)/$assetName"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
            $archiveAuthority = $null
            try {
                $archiveAuthority = Open-CodeGraphVerifiedArchive -Path $zip -ExpectedSha256 $expectedSha -Architecture $arch
                Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
                $inner = Join-Path $extract ("codegraph-win32-" + $arch)
                if (Test-Path -LiteralPath $inner) {
                    $flat = Join-Path $temp 'flat'
                    New-Item -ItemType Directory -Force -Path $flat | Out-Null
                    Get-ChildItem -LiteralPath $inner -Force | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $flat -Force }
                    $candidate = $flat
                }
                $candidateCommand = Join-Path $candidate 'bin\codegraph.cmd'
                $commandItem = Get-Item -LiteralPath $candidateCommand -Force -ErrorAction Stop
                if ([bool]$commandItem.PSIsContainer -or [bool]($commandItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "CodeGraph launcher must be a regular non-reparse file: $candidateCommand" }
                # Do not execute extracted release bytes before publication. The exact locked ZIP SHA and
                # archive-derived logical tree are immutable authority for every persisted candidate byte.
                $actualCandidateTree = Get-CodeGraphBundleTreeSha256 -Path $candidate
                if ($actualCandidateTree -cne [string]$archiveAuthority.ExpectedTreeSha256) { throw "CodeGraph extracted candidate tree does not match the exact verified archive. Expected $($archiveAuthority.ExpectedTreeSha256), found $actualCandidateTree" }
                $candidateTreeSha = [string]$archiveAuthority.ExpectedTreeSha256
                $candidateIdentity = New-CodeGraphBundleIdentity -TransactionId $transactionId -Role 'candidate' -Version ([string]$Spec.version) -Tag ([string]$Spec.tag) -Commit ([string]$Spec.commit) -Asset $assetName -Sha256 $expectedSha -BundleTreeSha256 $candidateTreeSha
                Write-CodeGraphBundleMarker -Path $candidate -Identity $candidateIdentity
                Assert-CodeGraphTransactionBundle -Path $candidate -Identity $candidateIdentity
            }
            finally { if ($null -ne $archiveAuthority -and $null -ne $archiveAuthority.Stream) { $archiveAuthority.Stream.Dispose(); $archiveAuthority.Stream = $null } }

            New-Item -ItemType Directory -Force -Path $CodeGraphRoot | Out-Null
            try {
                if (Test-Path -LiteralPath $current) {
                    if ($null -eq $existingManifest) { throw 'Existing CodeGraph current bundle has no HMS ownership manifest.' }
                    $backup = Join-Path $CodeGraphRoot ("backup-" + [guid]::NewGuid().ToString('N'))
                    $backupIdentity = New-CodeGraphBundleIdentity -TransactionId $transactionId -Role 'backup' -Version ([string]$existingManifest.version) -Tag ([string]$existingManifest.tag) -Commit ([string]$existingManifest.commit) -Asset ([string]$existingManifest.asset) -Sha256 ([string]$existingManifest.sha256) -BundleTreeSha256 ([string]$existingManifest.bundle_tree_sha256)
                    $previousIdentity = Move-CodeGraphCurrentToRollbackBackup -CurrentPath $current -BackupPath $backup -ExistingManifest $existingManifest -BackupIdentity $backupIdentity -PreviousIdentityRef ([ref]$previousIdentity)
                    if ($env:HMS_TEST_FAIL_CODEGRAPH_AFTER_BACKUP_RENAME -ceq '1') { throw 'Injected CodeGraph failure after previous current crossed the backup rename boundary.' }
                }

                $candidateActivationGuard = Move-CodeGraphCandidateToCurrent -CandidatePath $candidate -CurrentPath $current -Identity $candidateIdentity
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
                $manifestPublicationGuard = Publish-CodeGraphInstallManifest -Manifest $publishedManifest -ExistingState $existingManifestState
                $manifestPublished = $true
                Assert-CodeGraphTransactionBundle -Path $current -Identity $candidateIdentity
                if ($null -ne $candidateActivationGuard -and $null -ne $candidateActivationGuard.Handle) { $candidateActivationGuard.Handle.Dispose(); $candidateActivationGuard.Handle = $null; $candidateActivationGuard = $null }
                if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
                    Remove-CodeGraphTransactionBundle -Path $backup -Identity $backupIdentity
                }
                if ($null -ne $manifestPublicationGuard -and $null -ne $manifestPublicationGuard.Handle) { $manifestPublicationGuard.Handle.Dispose();$manifestPublicationGuard.Handle=$null;$manifestPublicationGuard=$null }
            }
            catch {
                $installError = $_
                if ($null -ne $candidateActivationGuard -and $null -ne $candidateActivationGuard.Handle) { $candidateActivationGuard.Handle.Dispose(); $candidateActivationGuard.Handle = $null; $candidateActivationGuard = $null }
                if ($null -eq $candidateIdentity) { throw $installError }
                $rollback = Repair-CodeGraphRollbackState -CurrentPath $current -BackupPath $backup -CandidateIdentity $candidateIdentity -BackupIdentity $backupIdentity -PreviousIdentity $previousIdentity -ManifestPublished $manifestPublished -PublishedManifest $publishedManifest -CandidateManifestGuard $manifestPublicationGuard -PreviousManifestBytes $existingManifestBytes -HadPrevious $wasInstalled
                $rollbackErrors = @($rollback.RollbackErrors)
                if ($rollbackErrors.Count -gt 0) {
                    throw "CodeGraph installation failed and rollback was incomplete. Original: $($installError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')"
                }
                throw $installError
            }
        }
        finally {
            if ($null -ne $candidateActivationGuard -and $null -ne $candidateActivationGuard.Handle) { $candidateActivationGuard.Handle.Dispose(); $candidateActivationGuard = $null }
            if ($null -ne $manifestPublicationGuard -and $null -ne $manifestPublicationGuard.Handle) { $manifestPublicationGuard.Handle.Dispose();$manifestPublicationGuard.Handle=$null }
            if (Test-Path -LiteralPath $temp) { Remove-CodeGraphTempRoot -Path $temp -TransactionId $transactionId }
        }
    }

    return [pscustomobject]@{ WasInstalled = $wasInstalled; Command = $command }
    }
    finally { if ($null -ne $existingManifestState -and $null -ne $existingManifestState.Guard -and $null -ne $existingManifestState.Guard.Handle) { $existingManifestState.Guard.Handle.Dispose();$existingManifestState.Guard.Handle=$null } }
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