from pathlib import Path
import subprocess

BASELINES = {
    "scripts/Build-HmsCompositeSkill.ps1": "11377176ffd9dfda86eb1283de47e04f7bb53637",
    "scripts/Copy-HmsCommittedGitPath.ps1": "7da34164adf828279f200b70e6f3c8220747f97f",
}

NEXT_MARKERS = {
    "scripts/Build-HmsCompositeSkill.ps1": "$repoRoot = Split-Path -Parent $PSScriptRoot",
    "scripts/Copy-HmsCommittedGitPath.ps1": "function Get-FullPathWithoutExistenceRequirement {",
}


def blob(path):
    return subprocess.check_output(["git", "rev-parse", f"HEAD:{path}"], text=True).strip().lower()


for path, expected in BASELINES.items():
    actual = blob(path)
    if actual != expected:
        raise SystemExit(f"baseline drift {path}: expected {expected}, found {actual}")

helper = r'''if (-not ('HmsOwnedTempNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class HmsOwnedTempNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME_PARTS
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME_PARTS CreationTime;
        public FILETIME_PARTS LastAccessTime;
        public FILETIME_PARTS LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(
        SafeFileHandle hFile,
        out BY_HANDLE_FILE_INFORMATION lpFileInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle hFile,
        int FileInformationClass,
        IntPtr lpFileInformation,
        uint dwBufferSize);

    public static bool RenameHmsOwnedDirectoryByHandle(SafeFileHandle handle, string destination, out int error)
    {
        byte[] nameBytes = Encoding.Unicode.GetBytes(destination);
        int rootOffset = IntPtr.Size == 8 ? 8 : 4;
        int lengthOffset = IntPtr.Size == 8 ? 16 : 8;
        int nameOffset = IntPtr.Size == 8 ? 20 : 12;
        int size = nameOffset + nameBytes.Length;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
            Marshal.WriteByte(buffer, 0, 0); // ReplaceIfExists = FALSE.
            Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
            Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);
            Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);
            bool ok = SetFileInformationByHandle(handle, 3, buffer, (uint)size); // FileRenameInfo.
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
}

function Get-HmsOwnedDirectoryIdentityFromHandle {
    param(
        [Parameter(Mandatory)]$Handle,
        [Parameter(Mandatory)][string]$Label
    )
    $info = New-Object 'HmsOwnedTempNative+BY_HANDLE_FILE_INFORMATION'
    if (-not [HmsOwnedTempNative]::GetFileInformationByHandle($Handle, [ref]$info)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "$Label could not read owned-directory identity (Win32=$code)."
    }
    if (($info.FileAttributes -band [uint32]0x10) -eq 0) { throw "$Label owned object is not a directory." }
    if (($info.FileAttributes -band [uint32]0x400) -ne 0) { throw "$Label owned directory is a reparse point." }
    return ([string]$info.VolumeSerialNumber + ':' + [string]$info.FileIndexHigh + ':' + [string]$info.FileIndexLow)
}

function Open-HmsOwnedDirectoryIdentityHandle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][uint32]$ShareMode,
        [Parameter(Mandatory)][string]$Label
    )

    if ($env:OS -cne 'Windows_NT') { throw "$Label Windows directory handle requested on non-Windows host: $Path" }

    # DELETE access is required for FileRenameInfo. BACKUP_SEMANTICS opens a directory handle;
    # OPEN_REPARSE_POINT prevents silently following a replacement reparse point.
    $handle = [HmsOwnedTempNative]::CreateFileW(
        $Path,
        [uint32]0x00010000,
        $ShareMode,
        [IntPtr]::Zero,
        [uint32]3,
        [uint32]0x02200000,
        [IntPtr]::Zero
    )
    if ($null -eq $handle -or $handle.IsInvalid) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($null -ne $handle) { $handle.Dispose() }
        throw "$Label could not open DELETE-capable directory identity handle (Win32=$code): $Path"
    }
    try {
        $identity = Get-HmsOwnedDirectoryIdentityFromHandle -Handle $handle -Label $Label
        return [pscustomobject]@{ Handle=$handle; Identity=$identity }
    }
    catch {
        $handle.Dispose()
        throw
    }
}

function Get-HmsOwnedDirectoryIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    if ($env:OS -cne 'Windows_NT') {
        $markerPath = Join-Path $Path '.hms-owned-temp-identity'
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not [bool]$item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$Label non-Windows owned path is not a regular directory: $Path"
        }
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw "$Label non-Windows identity marker is missing: $Path" }
        return ('marker:' + ([IO.File]::ReadAllText($markerPath)).Trim())
    }
    $opened = Open-HmsOwnedDirectoryIdentityHandle -Path $Path -ShareMode ([uint32]7) -Label $Label
    try { return [string]$opened.Identity }
    finally { $opened.Handle.Dispose() }
}

function New-HmsOwnedTempDirectory {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Label
    )

    $path = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $path) { throw "$Label random path already exists: $path" }
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null

    if ($env:OS -cne 'Windows_NT') {
        $token = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $path '.hms-owned-temp-identity'),$token,(New-Object Text.UTF8Encoding($false)))
        return [pscustomobject]@{ Path=$path; Identity=('marker:' + $token); Guard=$null }
    }

    # The handle is the durable object authority. A pathname can move or be replaced, but cleanup
    # renames the exact object referenced by this DELETE-capable handle into its quarantine name.
    $guarded = Open-HmsOwnedDirectoryIdentityHandle -Path $path -ShareMode ([uint32]7) -Label $Label
    return [pscustomobject]@{ Path=$path; Identity=[string]$guarded.Identity; Guard=$guarded.Handle }
}

function Remove-HmsOwnedTempDirectory {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][string]$Label
    )

    $path = [string]$Owned.Path
    $expectedIdentity = [string]$Owned.Identity
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($expectedIdentity)) { throw "$Label cleanup identity is incomplete." }
    $parent = Split-Path -Parent $path
    $quarantine = Join-Path $parent ('.hms-owned-temp-quarantine-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $quarantine) { throw "$Label random quarantine path already exists: $quarantine" }

    if ($env:OS -ceq 'Windows_NT') {
        if ($null -eq $Owned.Guard -or $Owned.Guard.IsClosed -or $Owned.Guard.IsInvalid) { throw "$Label exact-object cleanup handle is unavailable." }
        $handleIdentity = Get-HmsOwnedDirectoryIdentityFromHandle -Handle $Owned.Guard -Label $Label
        if ($handleIdentity -cne $expectedIdentity) { throw "$Label exact-object handle identity changed. Expected $expectedIdentity, found $handleIdentity." }
        $renameError = 0
        if (-not [HmsOwnedTempNative]::RenameHmsOwnedDirectoryByHandle($Owned.Guard,$quarantine,[ref]$renameError)) {
            throw "$Label exact-object handle rename to quarantine failed (Win32=$renameError): $quarantine"
        }
        $postRenameIdentity = Get-HmsOwnedDirectoryIdentityFromHandle -Handle $Owned.Guard -Label "$Label post-rename handle"
        if ($postRenameIdentity -cne $expectedIdentity) { throw "$Label exact-object identity changed across handle rename." }
        $quarantineIdentity = Get-HmsOwnedDirectoryIdentity -Path $quarantine -Label "$Label quarantine"
        if ($quarantineIdentity -cne $expectedIdentity) { throw "$Label quarantine pathname does not reference the exact owned object." }
        $Owned.Guard.Dispose(); $Owned.Guard=$null
    }
    else {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "$Label owned directory disappeared before cleanup: $path" }
        $currentIdentity = Get-HmsOwnedDirectoryIdentity -Path $path -Label $Label
        if ($currentIdentity -cne $expectedIdentity) { throw "$Label cleanup rejected a foreign pathname replacement. Expected identity $expectedIdentity, found ${currentIdentity}: $path" }
        Rename-Item -LiteralPath $path -NewName (Split-Path -Leaf $quarantine) -ErrorAction Stop
        $quarantineIdentity = Get-HmsOwnedDirectoryIdentity -Path $quarantine -Label "$Label quarantine"
        if ($quarantineIdentity -cne $expectedIdentity) { throw "$Label quarantine identity changed across rename." }
    }

    Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $quarantine) { throw "$Label quarantine still exists after cleanup: $quarantine" }
}
'''

for path, next_marker in NEXT_MARKERS.items():
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    start_marker = "if (-not ('HmsOwnedTempNative' -as [type])) {"
    start = text.find(start_marker)
    end = text.find(next_marker, start)
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: could not locate owned-temp helper block")
    old = text[start:end]
    if old.count("function Remove-HmsOwnedTempDirectory") != 1:
        raise SystemExit(f"{path}: helper block shape mismatch")
    updated = text[:start] + helper + "\n\n" + text[end:]
    p.write_text(updated, encoding="utf-8", newline="\n")

for path in BASELINES:
    text = Path(path).read_text(encoding="utf-8")
    required = [
        'SetFileInformationByHandle',
        'RenameHmsOwnedDirectoryByHandle',
        '[uint32]0x00010000',
        'exact-object handle rename to quarantine failed',
        "'.hms-owned-temp-identity'",
    ]
    for literal in required:
        if literal not in text:
            raise SystemExit(f"{path}: missing exact-handle remediation literal: {literal}")
    if 'During active use ShareMode excludes FILE_SHARE_DELETE' in text:
        raise SystemExit(f"{path}: superseded share-mode authority remains")

subprocess.check_call(["git", "diff", "--check"])
changed = subprocess.check_output(["git", "diff", "--name-only"], text=True).splitlines()
if sorted(changed) != sorted(BASELINES):
    raise SystemExit("unexpected patch scope: " + ", ".join(changed))
print("PATCH_OK=YES")
