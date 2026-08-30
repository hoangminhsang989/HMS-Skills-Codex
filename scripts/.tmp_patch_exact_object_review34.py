from pathlib import Path
import re, subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = "34d5efbfb1977544f94f761e6100e4674f8917e3"
BLOBS = {
    "scripts/Resolve-HmsModelRoute.ps1": "da73ed589790d8176ed69a6d8a97812b612fb8f4",
    "scripts/Build-HmsCompositeSkill.impl.ps1": "fc0cf463cecd5bb5c218db5bc38b959304cd3a81",
    "scripts/Sync-DeliveryTools.ps1": "227f1ad0628c7c47a0cfe47f6bcbc29ab00c5200",
    "uninstall.ps1": "ff8fc282293faaf04234e156bc7ad0f9787021c9",
    "scripts/Test-HmsLateTrustBoundaries.ps1": "2fcc82979266031a5f13166d8148164071c241f2",
}

def git(*args):
    return subprocess.check_output(["git","-C",str(ROOT),*args], text=True).strip()

def req(cond,msg):
    if not cond: raise RuntimeError(msg)

def read(rel): return (ROOT/rel).read_text(encoding="utf-8")
def write(rel,text): (ROOT/rel).write_text(text,encoding="utf-8",newline="\n")
def rep(text,old,new,label):
    n=text.count(old); req(n==1,f"{label}: expected exactly 1 occurrence, found {n}")
    return text.replace(old,new,1)
def replace_function(text,name,new_body):
    pat=re.compile(rf"(?ms)^function {re.escape(name)} \{{.*?^\}}\r?\n")
    m=pat.search(text); req(m is not None,f"function not found: {name}")
    return text[:m.start()]+new_body.rstrip()+"\n\n"+text[m.end():]

req(subprocess.run(["git","-C",str(ROOT),"merge-base","--is-ancestor",BASE,"HEAD"]).returncode==0,"34d5 baseline must be ancestor")
for rel,blob in BLOBS.items(): req(git("rev-parse",f"HEAD:{rel}").lower()==blob,f"baseline blob mismatch: {rel}")

# ---------------------------------------------------------------------------
# 1. Resolver: identity-bound settings read, no pathname reopen.
# ---------------------------------------------------------------------------
rel="scripts/Resolve-HmsModelRoute.ps1"
t=read(rel)
anchor="Set-StrictMode -Version Latest\n$ErrorActionPreference = 'Stop'\n\n"
resolver_native=r'''if (-not ('HmsModelRouteNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class HmsModelRouteNative
{
    [StructLayout(LayoutKind.Sequential)] public struct FILETIME_PARTS { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)] public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes; public FILETIME_PARTS CreationTime; public FILETIME_PARTS LastAccessTime; public FILETIME_PARTS LastWriteTime;
        public uint VolumeSerialNumber; public uint FileSizeHigh; public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr sa,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle hFile,out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileSizeEx(SafeFileHandle hFile,out long fileSize);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFilePointerEx(SafeFileHandle hFile,long distance,out long newPosition,uint moveMethod);
    [DllImport("kernel32.dll", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadFile(SafeFileHandle hFile,IntPtr buffer,uint bytesToRead,out uint bytesRead,IntPtr overlapped);

    public static SafeFileHandle OpenLockedModelSettingsForRead(string path,out int error)
    {
        // GENERIC_READ; share READ only. A foreign writer/renamer cannot replace this exact object while parsed.
        SafeFileHandle h=CreateFileW(path,0x80000000u,0x00000001u,IntPtr.Zero,3u,0x00200000u,IntPtr.Zero);
        error=h.IsInvalid?Marshal.GetLastWin32Error():0; return h;
    }
    public static bool IsRegularNonReparseFile(SafeFileHandle h,out int error)
    {
        BY_HANDLE_FILE_INFORMATION info;
        if(!GetFileInformationByHandle(h,out info)){error=Marshal.GetLastWin32Error();return false;}
        error=0; return (info.FileAttributes&0x10u)==0 && (info.FileAttributes&0x400u)==0;
    }
    public static byte[] ReadAllBytes(SafeFileHandle h,out int error)
    {
        long size; if(!GetFileSizeEx(h,out size)){error=Marshal.GetLastWin32Error();return null;}
        if(size<0||size>1048576){error=223;return null;}
        long pos; if(!SetFilePointerEx(h,0,out pos,0)){error=Marshal.GetLastWin32Error();return null;}
        byte[] result=new byte[(int)size]; if(size==0){error=0;return result;}
        IntPtr buffer=Marshal.AllocHGlobal((int)size);
        try {
            int offset=0;
            while(offset<result.Length){uint got;uint remain=(uint)(result.Length-offset);if(!ReadFile(h,IntPtr.Add(buffer,offset),remain,out got,IntPtr.Zero)){error=Marshal.GetLastWin32Error();return null;}if(got==0){error=38;return null;}offset+=(int)got;}
            Marshal.Copy(buffer,result,0,result.Length);error=0;return result;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
}

'''
t=rep(t,anchor,anchor+resolver_native,"resolver native prelude")
new_read=r'''function Read-Settings {
    param([Parameter(Mandatory)][string]$Path)

    if ($env:OS -cne 'Windows_NT') {
        if (-not (Test-Path -LiteralPath $Path)) { return Get-DefaultSettings }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Model settings path must be a regular file: $Path" }
        try { $text = [IO.File]::ReadAllText($Path,(New-Object Text.UTF8Encoding($false,$true))) }
        catch { throw "Model settings could not be read: $($_.Exception.Message)" }
    }
    else {
        $errorCode = 0
        $handle = [HmsModelRouteNative]::OpenLockedModelSettingsForRead($Path,[ref]$errorCode)
        if ($null -eq $handle -or $handle.IsInvalid) {
            if ($null -ne $handle) { $handle.Dispose() }
            if ($errorCode -eq 2 -or $errorCode -eq 3) { return Get-DefaultSettings }
            throw "Model settings exact read handle could not be opened (Win32=$errorCode): $Path"
        }
        try {
            $regularError = 0
            if (-not [HmsModelRouteNative]::IsRegularNonReparseFile($handle,[ref]$regularError)) {
                if ($regularError -ne 0) { throw "Model settings exact file identity could not be read (Win32=$regularError): $Path" }
                throw "Model settings path must be a regular non-reparse file: $Path"
            }
            $readError = 0
            $bytes = [HmsModelRouteNative]::ReadAllBytes($handle,[ref]$readError)
            if ($null -eq $bytes) { throw "Model settings exact bytes could not be read (Win32=$readError): $Path" }
            try { $text = (New-Object Text.UTF8Encoding($false,$true)).GetString([byte[]]$bytes) }
            catch { throw "Model settings bytes are not valid UTF-8: $($_.Exception.Message)" }
        }
        finally { $handle.Dispose() }
    }

    try { $settings = $text | ConvertFrom-Json }
    catch { throw "Model settings are invalid JSON: $($_.Exception.Message)" }
    if ($null -eq $settings.PSObject.Properties['schema_version']) { throw 'Model settings are missing schema_version.' }
    Assert-ExactSchemaVersionOne -Value $settings.schema_version
    if ([string]$settings.managed_by -cne 'HMS-Skills-Codex') { throw 'Model settings ownership mismatch.' }
    if ([string]$settings.artifact -cne 'hms-model-settings') { throw 'Model settings artifact mismatch.' }
    if ($null -eq $settings.models) { throw 'Model settings are missing models.' }
    foreach ($name in @('luna','terra','sol')) {
        $property = $settings.models.PSObject.Properties[$name]
        if ($null -eq $property) { throw "Model settings are missing '$name'." }
        if ($property.Value -isnot [bool]) { throw "Model setting '$name' must be boolean." }
    }
    return $settings
}'''
t=replace_function(t,"Read-Settings",new_read)
write(rel,t)

# Shared C# shape for exact directory transition helpers.
rename_delete_cs = r'''using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class {CLASS}
{{
    [StructLayout(LayoutKind.Sequential)] public struct FILETIME_PARTS {{ public uint Low; public uint High; }}
    [StructLayout(LayoutKind.Sequential)] public struct BY_HANDLE_FILE_INFORMATION
    {{ public uint FileAttributes; public FILETIME_PARTS CreationTime; public FILETIME_PARTS LastAccessTime; public FILETIME_PARTS LastWriteTime; public uint VolumeSerialNumber; public uint FileSizeHigh; public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow; }}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr sa,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] public static extern bool GetFileInformationByHandle(SafeFileHandle h,out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SetFileInformationByHandle(SafeFileHandle h,int infoClass,IntPtr info,uint size);
    public static bool RenameByHandle(SafeFileHandle handle,string destination,out int error)
    {{
        byte[] nameBytes=Encoding.Unicode.GetBytes(destination);int rootOffset=IntPtr.Size==8?8:4;int lengthOffset=IntPtr.Size==8?16:8;int nameOffset=IntPtr.Size==8?20:12;int minimum=IntPtr.Size==8?24:16;int size=Math.Max(minimum,nameOffset+nameBytes.Length+2);IntPtr buffer=Marshal.AllocHGlobal(size);
        try{{for(int i=0;i<size;i++)Marshal.WriteByte(buffer,i,0);Marshal.WriteByte(buffer,0,0);Marshal.WriteIntPtr(buffer,rootOffset,IntPtr.Zero);Marshal.WriteInt32(buffer,lengthOffset,nameBytes.Length);Marshal.Copy(nameBytes,0,IntPtr.Add(buffer,nameOffset),nameBytes.Length);bool ok=SetFileInformationByHandle(handle,3,buffer,(uint)size);error=ok?0:Marshal.GetLastWin32Error();return ok;}}finally{{Marshal.FreeHGlobal(buffer);}}
    }}
    public static bool DeleteByHandle(SafeFileHandle handle,out int error)
    {{ IntPtr buffer=Marshal.AllocHGlobal(4);try{{Marshal.WriteInt32(buffer,1);bool ok=SetFileInformationByHandle(handle,4,buffer,4);error=ok?0:Marshal.GetLastWin32Error();return ok;}}finally{{Marshal.FreeHGlobal(buffer);}} }}
}}
'''

# ---------------------------------------------------------------------------
# 2. Composite rollback: handle-bound reserve/activation.
# ---------------------------------------------------------------------------
rel="scripts/Build-HmsCompositeSkill.impl.ps1"
t=read(rel)
anchor="$CanonicalHmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'\n\n"
cs=rename_delete_cs.format(CLASS="HmsCompositeExactFsNative")
pre=r'''if ($env:OS -ceq 'Windows_NT' -and -not ('HmsCompositeExactFsNative' -as [type])) {
    Add-Type -TypeDefinition @'
'''+cs+"'@\n}\n\n"+r'''function Get-HmsCompositeDirectoryIdentityFromHandle {
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
    if($null-eq$h -or $h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if($null-ne$h){$h.Dispose()};throw "$Label could not open exact DELETE-capable directory handle (Win32=$code): $Path"}
    try{$id=Get-HmsCompositeDirectoryIdentityFromHandle -Handle $h -Label $Label;return [pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw}
}
function Move-HmsCompositeDirectoryGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label)
    if($env:OS -cne 'Windows_NT'){Rename-Item -LiteralPath $Guard.Path -NewName (Split-Path -Leaf $Destination) -ErrorAction Stop;$Guard.Path=$Destination;return}
    $before=Get-HmsCompositeDirectoryIdentityFromHandle -Handle $Guard.Handle -Label $Label
    if($before-cne[string]$Guard.Identity){throw "$Label exact directory identity changed before rename."}
    if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"}
    $code=0;if(-not[HmsCompositeExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact handle rename failed (Win32=$code): $Destination"}
    $after=Get-HmsCompositeDirectoryIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename";if($after-cne[string]$Guard.Identity){throw "$Label exact directory identity changed across rename."};$Guard.Path=$Destination
}

'''
t=rep(t,anchor,anchor+pre,"composite exact-fs prelude")
new_reserve=r'''function Reserve-OwnedCompositeRollbackBackup {
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
}'''
t=replace_function(t,"Reserve-OwnedCompositeRollbackBackup",new_reserve)
new_restore=r'''function Restore-OwnedCompositeRollbackBackup {
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
            if(-not(Test-Path -LiteralPath $source)){
                try{Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $source -Label 'Composite rollback activation verification rollback'}catch{throw "Composite rollback activation validation failed and exact-object return also failed. Validation: $($verifyError.Exception.Message). Return: $($_.Exception.Message)"}
            }
            throw $verifyError
        }
    } finally {if($null-ne$guard.Handle){$guard.Handle.Dispose()}}
}'''
t=replace_function(t,"Restore-OwnedCompositeRollbackBackup",new_restore)
write(rel,t)

# ---------------------------------------------------------------------------
# 3. Delivery tools: exact guarded cleanup and rollback reservation activation.
# ---------------------------------------------------------------------------
rel="scripts/Sync-DeliveryTools.ps1"
t=read(rel)
anchor="$CodeGraphTempMarkerName = '.hms-codegraph-temp.json'\n\n"
cs=rename_delete_cs.format(CLASS="HmsDeliveryExactFsNative")
pre=r'''if ($env:OS -ceq 'Windows_NT' -and -not ('HmsDeliveryExactFsNative' -as [type])) {
    Add-Type -TypeDefinition @'
'''+cs+"'@\n}\n\n"+r'''function Get-HmsDeliveryDirectoryIdentityFromHandle { param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label) $info=New-Object 'HmsDeliveryExactFsNative+BY_HANDLE_FILE_INFORMATION';if(-not[HmsDeliveryExactFsNative]::GetFileInformationByHandle($Handle,[ref]$info)){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "$Label could not read exact directory identity (Win32=$code)."};if(($info.FileAttributes-band[uint32]0x10)-eq 0 -or ($info.FileAttributes-band[uint32]0x400)-ne 0){throw "$Label must be a regular non-reparse directory."};return([string]$info.VolumeSerialNumber+':'+[string]$info.FileIndexHigh+':'+[string]$info.FileIndexLow) }
function Open-HmsDeliveryDirectoryGuard { param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label) if($env:OS-cne'Windows_NT'){return $null};$h=[HmsDeliveryExactFsNative]::CreateFileW($Path,[uint32]0x00010000,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero);if($null-eq$h-or$h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if($null-ne$h){$h.Dispose()};throw "$Label could not open exact DELETE-capable directory handle (Win32=$code): $Path"};try{$id=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $h -Label $Label;return[pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw} }
function Move-HmsDeliveryDirectoryGuard { param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label) $before=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $Guard.Handle -Label $Label;if($before-cne[string]$Guard.Identity){throw "$Label exact directory identity changed before rename."};if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"};$code=0;if(-not[HmsDeliveryExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact handle rename failed (Win32=$code): $Destination"};$after=Get-HmsDeliveryDirectoryIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename";if($after-cne[string]$Guard.Identity){throw "$Label exact directory identity changed across rename."};$Guard.Path=$Destination }
function Invoke-HmsDeliveryExactDirectoryRemoval {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$QuarantinePrefix,[Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][scriptblock]$Validate)
    if(-not(Test-Path -LiteralPath $Path)){return}
    if($env:OS-cne'Windows_NT'){&$Validate $Path;$q=Join-Path(Split-Path -Parent $Path)($QuarantinePrefix+[guid]::NewGuid().ToString('N'));Rename-Item -LiteralPath $Path -NewName(Split-Path -Leaf $q)-ErrorAction Stop;&$Validate $q;Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction Stop;return}
    $guard=Open-HmsDeliveryDirectoryGuard -Path $Path -Label $Label;$renamed=$false;$deleteStarted=$false;$q=Join-Path(Split-Path -Parent $Path)($QuarantinePrefix+[guid]::NewGuid().ToString('N'))
    try{
        &$Validate $Path
        Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $q -Label $Label;$renamed=$true
        &$Validate $q
        $deleteStarted=$true
        foreach($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)){Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop}
        $code=0;if(-not[HmsDeliveryExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)){throw "$Label exact root delete-pending transition failed (Win32=$code): $q"}
        $guard.Handle.Dispose();$guard.Handle=$null
        if(Test-Path -LiteralPath $q){throw "$Label exact quarantine remained after handle deletion: $q"}
    }catch{
        $e=$_
        if(-not$deleteStarted-and$renamed-and$null-ne$guard.Handle-and-not$guard.Handle.IsClosed-and-not(Test-Path -LiteralPath $Path)){try{Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $Path -Label "$Label pre-delete rollback"}catch{}}
        elseif($deleteStarted-and(Test-Path -LiteralPath $q)){throw "$Label deletion failed after destructive child removal started; exact quarantined remainder was not restored: $q. Original: $($e.Exception.Message)"}
        throw $e
    }finally{if($null-ne$guard-and$null-ne$guard.Handle){$guard.Handle.Dispose()}}
}

'''
t=rep(t,anchor,anchor+pre,"delivery exact-fs prelude")
new_remove_bundle=r'''function Remove-CodeGraphTransactionBundle {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Identity)
    $validator={param($p) Assert-CodeGraphTransactionBundle -Path $p -Identity $Identity}.GetNewClosure()
    Invoke-HmsDeliveryExactDirectoryRemoval -Path $Path -QuarantinePrefix '.hms-codegraph-deleting-' -Label 'CodeGraph transaction bundle cleanup' -Validate $validator
}'''
t=replace_function(t,"Remove-CodeGraphTransactionBundle",new_remove_bundle)
new_remove_temp=r'''function Remove-CodeGraphTempRoot {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$TransactionId)
    $validator={param($p) Assert-CodeGraphTempRoot -Path $p -TransactionId $TransactionId}.GetNewClosure()
    Invoke-HmsDeliveryExactDirectoryRemoval -Path $Path -QuarantinePrefix '.hms-codegraph-temp-removing-' -Label 'CodeGraph temporary-root cleanup' -Validate $validator
}'''
t=replace_function(t,"Remove-CodeGraphTempRoot",new_remove_temp)
# Rewrite the exact reservation/activation statements inside Repair-CodeGraphRollbackState while preserving its state machine.
old=r'''    $canRestorePrevious = $false
    $reservedBackupPath = $null

    if ($HadPrevious -and $null -ne $BackupIdentity -and -not [string]::IsNullOrWhiteSpace($BackupPath) -and (Test-Path -LiteralPath $BackupPath)) {
        try {
            Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
            $reserveLeaf = '.hms-codegraph-rollback-reserved-' + [guid]::NewGuid().ToString('N')
            $reservedBackupPath = Join-Path (Split-Path -Parent $BackupPath) $reserveLeaf
            Rename-Item -LiteralPath $BackupPath -NewName $reserveLeaf -ErrorAction Stop
            Assert-CodeGraphTransactionBundle -Path $reservedBackupPath -Identity $BackupIdentity
            $canRestorePrevious = $true
        }
        catch {
            $rollbackErrors += "CodeGraph backup reservation failed before candidate removal: $($_.Exception.Message)"
            if ($null -ne $reservedBackupPath -and (Test-Path -LiteralPath $reservedBackupPath) -and -not (Test-Path -LiteralPath $BackupPath)) {
                try {
                    Assert-CodeGraphTransactionBundle -Path $reservedBackupPath -Identity $BackupIdentity
                    Rename-Item -LiteralPath $reservedBackupPath -NewName (Split-Path -Leaf $BackupPath) -ErrorAction Stop
                    Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
                    $reservedBackupPath = $null
                }
                catch {
                    $rollbackErrors += "CodeGraph backup reservation rollback failed: $($_.Exception.Message)"
                }
            }
        }
    }
'''
new=r'''    $canRestorePrevious = $false
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
'''
t=rep(t,old,new,"CodeGraph guarded reservation")
old2=r'''    if ($canRestorePrevious -and -not $candidateRemovalCompleted -and $null -ne $reservedBackupPath -and (Test-Path -LiteralPath $reservedBackupPath)) {
        try {
            Assert-CodeGraphTransactionBundle -Path $reservedBackupPath -Identity $BackupIdentity
            if (Test-Path -LiteralPath $BackupPath) { throw "Cannot return reserved CodeGraph backup because the original backup pathname became occupied: $BackupPath" }
            Rename-Item -LiteralPath $reservedBackupPath -NewName (Split-Path -Leaf $BackupPath) -ErrorAction Stop
            Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
            $reservedBackupPath = $null
        }
        catch { $rollbackErrors += "CodeGraph reserved backup could not be returned after candidate preservation: $($_.Exception.Message)" }
    }

    if ($canRestorePrevious -and $candidateRemovalCompleted) {
        try {
            if ($null -eq $reservedBackupPath -or -not (Test-Path -LiteralPath $reservedBackupPath)) { throw 'CodeGraph reserved backup disappeared before rollback activation.' }
            Assert-CodeGraphTransactionBundle -Path $reservedBackupPath -Identity $BackupIdentity
            if ($null -eq $PreviousIdentity) { throw 'CodeGraph previous candidate identity is unavailable before rollback activation.' }
            if (Test-Path -LiteralPath $CurrentPath) { throw "Cannot restore CodeGraph backup because current became occupied: $CurrentPath" }
            Move-Item -LiteralPath $reservedBackupPath -Destination $CurrentPath
            Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $BackupIdentity
            # Restore the original candidate-role marker before restoring the previous root manifest.
            # This keeps the active bundle and manifest on the same transaction identity after rollback.
            Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $PreviousIdentity
            Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $PreviousIdentity
            $backupActivated = $true
            $reservedBackupPath = $null
        }
        catch { $rollbackErrors += $_.Exception.Message }
    }
'''
new2=r'''    if ($canRestorePrevious -and -not $candidateRemovalCompleted -and $null -ne $reservedBackupGuard) {
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
'''
t=rep(t,old2,new2,"CodeGraph guarded activation")
# Dispose any retained guard before the function returns, without losing the reservation path evidence.
return_anchor="    return [pscustomobject]@{\n        RollbackErrors = @($rollbackErrors)"
t=rep(t,return_anchor,"    if ($null -ne $reservedBackupGuard -and $null -ne $reservedBackupGuard.Handle) { $reservedBackupGuard.Handle.Dispose(); $reservedBackupGuard = $null }\n\n"+return_anchor,"CodeGraph guard disposal")
write(rel,t)

# ---------------------------------------------------------------------------
# 4. Uninstall: exact guarded quarantine deletion for clone/composite/CodeGraph.
# ---------------------------------------------------------------------------
rel="uninstall.ps1"
t=read(rel)
anchor="$threeLevelClone = Join-Path $env:USERPROFILE '.codex\\three-level-delivery'\n\n"
cs=rename_delete_cs.format(CLASS="HmsUninstallExactFsNative")
pre=r'''if ($env:OS -ceq 'Windows_NT' -and -not ('HmsUninstallExactFsNative' -as [type])) {
    Add-Type -TypeDefinition @'
'''+cs+"'@\n}\n\n"+r'''function Get-HmsUninstallDirectoryIdentityFromHandle { param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label) $info=New-Object 'HmsUninstallExactFsNative+BY_HANDLE_FILE_INFORMATION';if(-not[HmsUninstallExactFsNative]::GetFileInformationByHandle($Handle,[ref]$info)){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw "$Label could not read exact directory identity (Win32=$code)."};if(($info.FileAttributes-band[uint32]0x10)-eq 0-or($info.FileAttributes-band[uint32]0x400)-ne 0){throw "$Label must be a regular non-reparse directory."};return([string]$info.VolumeSerialNumber+':'+[string]$info.FileIndexHigh+':'+[string]$info.FileIndexLow) }
function Open-HmsUninstallDirectoryGuard { param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label) if($env:OS-cne'Windows_NT'){return $null};$h=[HmsUninstallExactFsNative]::CreateFileW($Path,[uint32]0x00010000,[uint32]3,[IntPtr]::Zero,[uint32]3,[uint32]0x02200000,[IntPtr]::Zero);if($null-eq$h-or$h.IsInvalid){$code=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if($null-ne$h){$h.Dispose()};throw "$Label could not open exact DELETE-capable directory handle (Win32=$code): $Path"};try{$id=Get-HmsUninstallDirectoryIdentityFromHandle -Handle $h -Label $Label;return[pscustomobject]@{Handle=$h;Identity=$id;Path=$Path}}catch{$h.Dispose();throw} }
function Move-HmsUninstallDirectoryGuard { param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Label) $before=Get-HmsUninstallDirectoryIdentityFromHandle -Handle $Guard.Handle -Label $Label;if($before-cne[string]$Guard.Identity){throw "$Label exact directory identity changed before rename."};if(Test-Path -LiteralPath $Destination){throw "$Label destination is occupied: $Destination"};$code=0;if(-not[HmsUninstallExactFsNative]::RenameByHandle($Guard.Handle,$Destination,[ref]$code)){throw "$Label exact handle rename failed (Win32=$code): $Destination"};$after=Get-HmsUninstallDirectoryIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename";if($after-cne[string]$Guard.Identity){throw "$Label exact directory identity changed across rename."};$Guard.Path=$Destination }
function Invoke-HmsUninstallExactDirectoryRemoval {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Prefix,[Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][scriptblock]$Validate)
    if(-not(Test-Path -LiteralPath $Path)){return}
    if($env:OS-cne'Windows_NT'){&$Validate $Path;$q=Join-Path(Split-Path -Parent $Path)($Prefix+[guid]::NewGuid().ToString('N'));Rename-Item -LiteralPath $Path -NewName(Split-Path -Leaf $q)-ErrorAction Stop;&$Validate $q;Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction Stop;return}
    $guard=Open-HmsUninstallDirectoryGuard -Path $Path -Label $Label;$renamed=$false;$deleteStarted=$false;$q=Join-Path(Split-Path -Parent $Path)($Prefix+[guid]::NewGuid().ToString('N'))
    try{&$Validate $Path;Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $q -Label $Label;$renamed=$true;&$Validate $q;$deleteStarted=$true;foreach($child in@(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)){Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop};$code=0;if(-not[HmsUninstallExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)){throw "$Label exact root delete-pending transition failed (Win32=$code): $q"};$guard.Handle.Dispose();$guard.Handle=$null;if(Test-Path -LiteralPath $q){throw "$Label exact quarantine remained after handle deletion: $q"}}
    catch{$e=$_;if(-not$deleteStarted-and$renamed-and$null-ne$guard.Handle-and-not$guard.Handle.IsClosed-and-not(Test-Path -LiteralPath $Path)){try{Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $Path -Label "$Label pre-delete rollback"}catch{}}elseif($deleteStarted-and(Test-Path -LiteralPath $q)){throw "$Label deletion failed after destructive child removal started; exact quarantined remainder was not restored: $q. Original: $($e.Exception.Message)"};throw $e}
    finally{if($null-ne$guard-and$null-ne$guard.Handle){$guard.Handle.Dispose()}}
}

'''
t=rep(t,anchor,anchor+pre,"uninstall exact-fs prelude")
new_clone=r'''function Remove-VerifiedClone {
    param([string]$Path,[string]$ExpectedRemote,[string]$MarkerRelativePath,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-CloneIdentity -Path $Path -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return }
    $validator={param($p) Assert-CloneIdentity -Path $p -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath}.GetNewClosure()
    Invoke-HmsUninstallExactDirectoryRemoval -Path $Path -Prefix '.hms-clone-removing-' -Label 'Verified clone uninstall cleanup' -Validate $validator
}'''
t=replace_function(t,"Remove-VerifiedClone",new_clone)
new_comp=r'''function Remove-VerifiedCompositeRoot {
    param([string]$Path,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-OwnedCompositeRoot -Path $Path
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return }
    $validator={param($p) Assert-OwnedCompositeRoot -Path $p}.GetNewClosure()
    Invoke-HmsUninstallExactDirectoryRemoval -Path $Path -Prefix '.hms-composite-removing-' -Label 'Verified composite uninstall cleanup' -Validate $validator
}'''
t=replace_function(t,"Remove-VerifiedCompositeRoot",new_comp)
new_cg=r'''function Remove-VerifiedCodeGraphRoot {
    param([string]$Path,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-ManagedCodeGraphRoot -Path $Path
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return }
    $validator={param($p) Assert-ManagedCodeGraphRoot -Path $p}.GetNewClosure()
    Invoke-HmsUninstallExactDirectoryRemoval -Path $Path -Prefix '.hms-codegraph-removing-' -Label 'Verified CodeGraph uninstall cleanup' -Validate $validator
}'''
t=replace_function(t,"Remove-VerifiedCompositeRoot",new_comp)
t=replace_function(t,"Remove-VerifiedCodeGraphRoot",new_cg)
write(rel,t)

# ---------------------------------------------------------------------------
# 5. Permanent static + Windows primitive adversarial checks.
# ---------------------------------------------------------------------------
rel="scripts/Test-HmsLateTrustBoundaries.ps1"
t=read(rel)
t=rep(t,"$resolverPath = Join-Path $RepoRoot 'scripts\\Resolve-HmsModelRoute.ps1'\nforeach ($path in @($builderPath,$modelPath,$resolverPath)) {","$resolverPath = Join-Path $RepoRoot 'scripts\\Resolve-HmsModelRoute.ps1'\n$builderImplPath = Join-Path $RepoRoot 'scripts\\Build-HmsCompositeSkill.impl.ps1'\n$deliveryPath = Join-Path $RepoRoot 'scripts\\Sync-DeliveryTools.ps1'\n$uninstallPath = Join-Path $RepoRoot 'uninstall.ps1'\nforeach ($path in @($builderPath,$modelPath,$resolverPath,$builderImplPath,$deliveryPath,$uninstallPath)) {","late test parser paths")
old=r'''$resolverText = [IO.File]::ReadAllText($resolverPath)
foreach ($literal in @("Local\HMS-Skills-Codex-ModelSettings-v1",'Timed out waiting for model settings reader lock')) {
    if ($resolverText -notmatch [regex]::Escape($literal)) { throw "Resolver is missing serialized read contract: $literal" }
}
'''
new=r'''$resolverText = [IO.File]::ReadAllText($resolverPath)
foreach ($literal in @("Local\HMS-Skills-Codex-ModelSettings-v1",'Timed out waiting for model settings reader lock','HmsModelRouteNative','OpenLockedModelSettingsForRead','ReadAllBytes')) {
    if ($resolverText -notmatch [regex]::Escape($literal)) { throw "Resolver is missing identity-bound read contract: $literal" }
}
if ($resolverText -match [regex]::Escape('Get-Content -LiteralPath $Path')) { throw 'Resolver still reopens the settings pathname with Get-Content.' }

$builderImplText=[IO.File]::ReadAllText($builderImplPath)
foreach($literal in @('HmsCompositeExactFsNative','Open-HmsCompositeDirectoryGuard','Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $FinalPath')){if($builderImplText-notmatch[regex]::Escape($literal)){throw "Composite rollback is missing exact-object activation contract: $literal"}}
$deliveryText=[IO.File]::ReadAllText($deliveryPath)
foreach($literal in @('HmsDeliveryExactFsNative','Invoke-HmsDeliveryExactDirectoryRemoval','reservedBackupGuard','Move-HmsDeliveryDirectoryGuard -Guard $reservedBackupGuard -Destination $CurrentPath')){if($deliveryText-notmatch[regex]::Escape($literal)){throw "Delivery tools are missing exact-object contract: $literal"}}
$uninstallText=[IO.File]::ReadAllText($uninstallPath)
foreach($literal in @('HmsUninstallExactFsNative','Invoke-HmsUninstallExactDirectoryRemoval','DeleteByHandle')){if($uninstallText-notmatch[regex]::Escape($literal)){throw "Uninstall is missing exact-object cleanup contract: $literal"}}
foreach($bad in @('Remove-Item -LiteralPath $quarantine -Recurse -Force','Remove-Item -LiteralPath $q -Recurse -Force')){if($deliveryText-match[regex]::Escape($bad)){throw "Delivery exact cleanup reverted to root-path recursive deletion: $bad"}}
'''
t=rep(t,old,new,"late review34 static checks")
# Update closing declaration and add a generic production-style exact root guard runtime proof based on the already proven public native helper.
old_end="Write-Host 'PASS: model route resolver serializes persisted-settings reads with the writer transaction.'\nWrite-Host 'PASS: three late P1 trust boundaries are permanently qualified.'"
new_end=r'''Write-Host 'PASS: model route resolver serializes persisted-settings reads with the writer transaction.'

# Permanent destructive primitive proof: the production public builder exact-directory guard denies
# FILE_SHARE_DELETE, so a non-cooperating process cannot rename the exact root after validation.
$owned = New-HmsOwnedTempDirectory -Prefix 'hms-review34-root-lock-' -Label 'review34 root lock regression'
$probeJob=$null
try {
    Set-Content -LiteralPath (Join-Path $owned.Path 'sentinel.txt') -Value 'owned' -Encoding UTF8
    $probeJob=Start-Job -ScriptBlock {param($Path) try{Rename-Item -LiteralPath $Path -NewName ('foreign-'+[guid]::NewGuid().ToString('N')) -ErrorAction Stop;return $true}catch{return $false}} -ArgumentList $owned.Path
    $null=Wait-Job -Job $probeJob -Timeout 20
    if($probeJob.State-ne'Completed'){throw 'Exact-root hostile rename probe did not complete.'}
    if([bool](Receive-Job -Job $probeJob -ErrorAction Stop)){throw 'Foreign process renamed a DELETE-guarded exact root.'}
} finally {if($null-ne$probeJob){Remove-Job -Job $probeJob -Force -ErrorAction SilentlyContinue};Remove-HmsOwnedTempDirectory -Owned $owned -Label 'review34 root lock regression'}
Write-Host 'PASS: exact DELETE-capable directory guards deny hostile root rename through destructive transitions.'
Write-Host 'PASS: review34 exact-object resolver, rollback activation, delivery cleanup, and uninstall boundaries are permanently qualified.'
'''
t=rep(t,old_end,new_end,"late review34 runtime close")
write(rel,t)

# Sanity checks on produced source.
for rel in BLOBS:
    req((ROOT/rel).exists(),f"missing patched file: {rel}")
req("OpenLockedModelSettingsForRead" in read("scripts/Resolve-HmsModelRoute.ps1"),"resolver exact read missing")
req("Move-HmsCompositeDirectoryGuard -Guard $guard -Destination $FinalPath" in read("scripts/Build-HmsCompositeSkill.impl.ps1"),"composite exact activation missing")
req("$reservedBackupGuard" in read("scripts/Sync-DeliveryTools.ps1"),"delivery reserved guard missing")
req("Invoke-HmsUninstallExactDirectoryRemoval" in read("uninstall.ps1"),"uninstall exact removal missing")
print("PASS: patched five exact-head Codex P1 findings with exact-object handles and permanent regression contracts.")
