from pathlib import Path
import subprocess

BASELINES = {
    "scripts/Build-HmsCompositeSkill.ps1": "f608fefc9b650b621aab15f6ead637ad4420018a",
    "scripts/Copy-HmsCommittedGitPath.ps1": "e641f62a4fd8a10552e81cabe2ab3b288dec06ea",
}

def blob(path):
    return subprocess.check_output(["git", "rev-parse", f"HEAD:{path}"], text=True).strip().lower()

def once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one occurrence, found {count}")
    return text.replace(old, new, 1)

for path, expected in BASELINES.items():
    actual = blob(path)
    if actual != expected:
        raise SystemExit(f"baseline drift {path}: expected {expected}, found {actual}")

native_helper = r'''if (-not ('HmsOwnedTempNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
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
}
'@
}

function Open-HmsOwnedDirectoryIdentityHandle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][uint32]$ShareMode,
        [Parameter(Mandatory)][string]$Label
    )

    if ($env:OS -cne 'Windows_NT') {
        throw "$Label filesystem-identity boundary is supported only on Windows: $Path"
    }

    # OPEN_EXISTING + BACKUP_SEMANTICS + OPEN_REPARSE_POINT.
    # During active use ShareMode excludes FILE_SHARE_DELETE so the owned root cannot be renamed away.
    $handle = [HmsOwnedTempNative]::CreateFileW(
        $Path,
        [uint32]0,
        $ShareMode,
        [IntPtr]::Zero,
        [uint32]3,
        [uint32]0x02200000,
        [IntPtr]::Zero
    )
    if ($null -eq $handle -or $handle.IsInvalid) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($null -ne $handle) { $handle.Dispose() }
        throw "$Label could not open owned-directory identity handle (Win32=$code): $Path"
    }

    try {
        $info = New-Object 'HmsOwnedTempNative+BY_HANDLE_FILE_INFORMATION'
        if (-not [HmsOwnedTempNative]::GetFileInformationByHandle($handle, [ref]$info)) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "$Label could not read owned-directory identity (Win32=$code): $Path"
        }
        if (($info.FileAttributes -band [uint32]0x10) -eq 0) {
            throw "$Label owned path is not a directory: $Path"
        }
        if (($info.FileAttributes -band [uint32]0x400) -ne 0) {
            throw "$Label owned directory became a reparse point: $Path"
        }
        $identity = ([string]$info.VolumeSerialNumber + ':' + [string]$info.FileIndexHigh + ':' + [string]$info.FileIndexLow)
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
    $guarded = Open-HmsOwnedDirectoryIdentityHandle -Path $path -ShareMode ([uint32]3) -Label $Label
    return [pscustomobject]@{
        Path = $path
        Identity = [string]$guarded.Identity
        Guard = $guarded.Handle
    }
}

function Remove-HmsOwnedTempDirectory {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][string]$Label
    )

    $path = [string]$Owned.Path
    $expectedIdentity = [string]$Owned.Identity
    if ($null -ne $Owned.Guard) {
        $Owned.Guard.Dispose()
        $Owned.Guard = $null
    }
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($expectedIdentity)) {
        throw "$Label cleanup identity is incomplete."
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "$Label owned directory disappeared before cleanup: $path"
    }

    $currentIdentity = Get-HmsOwnedDirectoryIdentity -Path $path -Label $Label
    if ($currentIdentity -cne $expectedIdentity) {
        throw "$Label cleanup rejected a foreign pathname replacement. Expected identity $expectedIdentity, found ${currentIdentity}: $path"
    }

    $parent = Split-Path -Parent $path
    $quarantine = Join-Path $parent ('.hms-owned-temp-quarantine-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $quarantine) {
        throw "$Label random quarantine path already exists: $quarantine"
    }

    Rename-Item -LiteralPath $path -NewName (Split-Path -Leaf $quarantine) -ErrorAction Stop
    $quarantineIdentity = Get-HmsOwnedDirectoryIdentity -Path $quarantine -Label "$Label quarantine"
    if ($quarantineIdentity -cne $expectedIdentity) {
        throw "$Label quarantine identity changed across rename. Expected $expectedIdentity, found ${quarantineIdentity}: $quarantine"
    }

    Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $quarantine) {
        throw "$Label quarantine still exists after cleanup: $quarantine"
    }
}
'''

marker = "Set-StrictMode -Version Latest\n$ErrorActionPreference = 'Stop'\n"

# Public builder support roots and its inner exact-HEAD archive transport.
p = Path("scripts/Build-HmsCompositeSkill.ps1")
t = p.read_text(encoding="utf-8")
t = once(t, marker, marker + "\n" + native_helper + "\n", "builder identity helper")

t = once(t,
'''    $transportRoot = Join-Path ([IO.Path]::GetTempPath()) ('hms-support-transport-' + [guid]::NewGuid().ToString('N'))
    $transportGit = Join-Path $transportRoot 'repo.git'
    $archivePath = Join-Path $transportRoot 'support.zip'
    try {
        New-Item -ItemType Directory -Force -Path $transportRoot | Out-Null
''',
'''    $transportOwned = New-HmsOwnedTempDirectory -Prefix 'hms-support-transport-' -Label "$Label support transport root"
    $transportRoot = [string]$transportOwned.Path
    $transportGit = Join-Path $transportRoot 'repo.git'
    $archivePath = Join-Path $transportRoot 'support.zip'
    try {
''', "builder support transport creation")

t = once(t,
'''    finally {
        if (Test-Path -LiteralPath $transportRoot) { Remove-Item -LiteralPath $transportRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
''',
'''    finally {
        if ($null -ne $transportOwned) {
            Remove-HmsOwnedTempDirectory -Owned $transportOwned -Label "$Label support transport root"
        }
    }
}
''', "builder support transport cleanup")

t = once(t,
'''            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "$Label exact-HEAD archive transport changed committed bytes. Expected $BlobSha, found $actual."
''',
'''            throw "$Label exact-HEAD archive transport changed committed bytes. Expected $BlobSha, found $actual."
''', "builder support destination mismatch cleanup")

t = once(t,
'''    catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    }
''',
'''    catch {
        # Destination lives inside the identity-guarded support root. The owned parent performs cleanup;
        # never delete a child pathname here after verification failure because it may have been replaced.
        throw
    }
''', "builder support destination catch cleanup")

t = once(t,
'''$lifecycleOwnsBuildMutex = Test-ExactHeadLifecycleCaller
$supportRoot = $null
try {
''',
'''$lifecycleOwnsBuildMutex = Test-ExactHeadLifecycleCaller
$supportOwnedRoot = $null
$supportRoot = $null
try {
''', "builder support state")

t = once(t,
'''    $supportToken = [guid]::NewGuid().ToString('N')
    $supportRoot = Join-Path ([IO.Path]::GetTempPath()) ("hms-builder-support-$supportToken")

    New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
''',
'''    $supportOwnedRoot = New-HmsOwnedTempDirectory -Prefix 'hms-builder-support-' -Label 'Composite builder support root'
    $supportRoot = [string]$supportOwnedRoot.Path
''', "builder support creation")

# Use a regex here because this was the exact mechanical mismatch in the first author attempt.
pattern = re.compile(r'''finally \{\n    if \(\$null -ne \$supportRoot -and \(Test-Path -LiteralPath \$supportRoot\)\) \{\n        Remove-Item -LiteralPath \$supportRoot -Recurse -Force -ErrorAction SilentlyContinue\n    \}\n\}\s*\Z''')
matches = list(pattern.finditer(t))
if len(matches) != 1:
    raise SystemExit(f"builder support cleanup: expected one occurrence, found {len(matches)}")
t = pattern.sub("finally {\n    if ($null -ne $supportOwnedRoot) {\n        Remove-HmsOwnedTempDirectory -Owned $supportOwnedRoot -Label 'Composite builder support root'\n    }\n}\n", t, count=1)
p.write_text(t, encoding="utf-8", newline="\n")

# Committed-copy transport: own the temp root and never delete a caller pathname on failure.
p = Path("scripts/Copy-HmsCommittedGitPath.ps1")
t = p.read_text(encoding="utf-8")
t = once(t, marker, marker + "\n" + native_helper + "\n", "copy identity helper")

t = once(t,
'''$transportRoot = Join-Path ([IO.Path]::GetTempPath()) ('hms-committed-copy-transport-' + [guid]::NewGuid().ToString('N'))
$transportGit = Join-Path $transportRoot 'repo.git'
$archivePath = Join-Path $transportRoot 'committed.zip'
$destinationCreated = $false
try {
    New-Item -ItemType Directory -Force -Path $transportRoot | Out-Null
''',
'''$transportOwned = New-HmsOwnedTempDirectory -Prefix 'hms-committed-copy-transport-' -Label 'Committed-copy transport root'
$transportRoot = [string]$transportOwned.Path
$transportGit = Join-Path $transportRoot 'repo.git'
$archivePath = Join-Path $transportRoot 'committed.zip'
$destinationCreated = $false
try {
''', "copy transport creation")

t = once(t,
'''                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                throw "Committed-copy exact-commit archive transport changed committed bytes for '$archiveEntryPath'. Expected $($entry.Blob), found $actual."
''',
'''                throw "Committed-copy exact-commit archive transport changed committed bytes for '$archiveEntryPath'. Expected $($entry.Blob), found $actual."
''', "copy target mismatch cleanup")

t = once(t,
'''catch {
    if (Test-Path -LiteralPath $Destination) {
        if ($sourceType -ceq 'tree' -or $destinationCreated) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue }
        else { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $transportRoot) { Remove-Item -LiteralPath $transportRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
''',
'''catch {
    # Destination belongs to the caller's identity-guarded staging root. Never recursively delete
    # a caller pathname after failure because a non-cooperating process may have replaced it.
    throw
}
finally {
    if ($null -ne $transportOwned) {
        Remove-HmsOwnedTempDirectory -Owned $transportOwned -Label 'Committed-copy transport root'
    }
}
''', "copy cleanup boundaries")
p.write_text(t, encoding="utf-8", newline="\n")

subprocess.check_call(["git", "diff", "--check"])
changed = subprocess.check_output(["git", "diff", "--name-only"], text=True).splitlines()
expected_changed = sorted(BASELINES)
if sorted(changed) != expected_changed:
    raise SystemExit("unexpected patch scope: " + ", ".join(changed))
print("PATCH_OK=YES")
