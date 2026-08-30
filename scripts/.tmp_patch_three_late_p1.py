from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_HEAD = "7cca53640f3b09fbbb0468e82aa9bdd65c09e162"
EXPECTED_BLOBS = {
    "scripts/Build-HmsCompositeSkill.ps1": "92ff3a2f58a0999c7396c6cedefd95d79a3a4284",
    "scripts/Copy-HmsCommittedGitPath.ps1": "85b6ed896f16f77b6572d42fe6907a69cdd56fe9",
    "manager/HmsModelSettings.utf8.ps1": "ae67031df973828cb70f900e4a2423788569feaa",
    "scripts/Resolve-HmsModelRoute.ps1": "1314ab567a994d908c6832596e7775d32df6c18c",
    "scripts/Test-HmsOwnedTempCleanup.ps1": "d5cc7fc6947cfdb1d8d8f1268053056bb3cd41a4",
    "scripts/Test-HmsSkills.ps1": "2f00c5e34ab0b390000fee6e97ea21f6402c4be9",
}

def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()

def require(cond, msg):
    if not cond:
        raise RuntimeError(msg)

def replace_once(text, old, new, label):
    count = text.count(old)
    require(count == 1, f"{label}: expected one exact occurrence, found {count}")
    return text.replace(old, new, 1)

def regex_once(text, pattern, replacement, label, flags=re.S):
    rx = re.compile(pattern, flags)
    matches = list(rx.finditer(text))
    require(len(matches) == 1, f"{label}: expected one regex occurrence, found {len(matches)}")
    return rx.sub(replacement, text, count=1)

def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")

def write(rel, text):
    (ROOT / rel).write_text(text, encoding="utf-8", newline="\n")

require(git("rev-parse", "HEAD").lower() == EXPECTED_HEAD, "temporary patcher must run only on the frozen 7cca baseline")
for rel, expected in EXPECTED_BLOBS.items():
    actual = git("rev-parse", f"HEAD:{rel}").lower()
    require(actual == expected, f"baseline blob mismatch for {rel}: expected {expected}, found {actual}")

# ---------------------------------------------------------------------------
# P1 #1 + #2: builder runtime executes in memory; owned temp root remains
# identity-bound through deletion and never falls back to root pathname delete.
# ---------------------------------------------------------------------------

def patch_owned_temp(rel):
    text = read(rel)
    csharp_tail = r'''        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@'''
    csharp_new = r'''        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static bool DeleteHmsOwnedDirectoryByHandle(SafeFileHandle handle, out int error)
    {
        IntPtr buffer = Marshal.AllocHGlobal(4);
        try
        {
            Marshal.WriteInt32(buffer, 1); // FILE_DISPOSITION_INFO.DeleteFile = TRUE.
            bool ok = SetFileInformationByHandle(handle, 4, buffer, 4); // FileDispositionInfo.
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@'''
    text = replace_once(text, csharp_tail, csharp_new, f"{rel} native exact-handle delete")

    text = replace_once(
        text,
        "        [Parameter(Mandatory)][uint32]$ShareMode,\n        [Parameter(Mandatory)][string]$Label\n",
        "        [Parameter(Mandatory)][uint32]$ShareMode,\n        [uint32]$DesiredAccess = [uint32]0x00010000,\n        [Parameter(Mandatory)][string]$Label\n",
        f"{rel} handle desired-access parameter",
    )
    text = replace_once(
        text,
        "        [uint32]0x00010000,\n        $ShareMode,\n",
        "        $DesiredAccess,\n        $ShareMode,\n",
        f"{rel} CreateFile desired access",
    )
    text = replace_once(
        text,
        "Open-HmsOwnedDirectoryIdentityHandle -Path $Path -ShareMode ([uint32]7) -Label $Label",
        "Open-HmsOwnedDirectoryIdentityHandle -Path $Path -ShareMode ([uint32]7) -DesiredAccess ([uint32]0x00000080) -Label $Label",
        f"{rel} read-only identity probe",
    )
    text = replace_once(
        text,
        "    # The handle is the durable object authority. A pathname can move or be replaced, but cleanup\n    # renames the exact object referenced by this DELETE-capable handle into its quarantine name.\n    $guarded = Open-HmsOwnedDirectoryIdentityHandle -Path $path -ShareMode ([uint32]7) -Label $Label",
        "    # Hold the root with DELETE access but without FILE_SHARE_DELETE for its entire lifetime.\n    # Non-cooperating processes cannot rename/replace the exact owned root while HMS is using it;\n    # cleanup itself renames and deletes that exact object through the same durable handle.\n    $guarded = Open-HmsOwnedDirectoryIdentityHandle -Path $path -ShareMode ([uint32]3) -Label $Label",
        f"{rel} no-share-delete owned root",
    )

    marker = "\n\n\n$repoRoot = Split-Path -Parent $PSScriptRoot" if rel.endswith("Build-HmsCompositeSkill.ps1") else "\n\n\nfunction Get-FullPathWithoutExistenceRequirement"
    pattern = r"function Remove-HmsOwnedTempDirectory \{.*?\n\}" + re.escape(marker)
    new_func = r'''function Remove-HmsOwnedTempDirectory {
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

        # The original DELETE-capable guard deliberately remains live here with FILE_SHARE_DELETE denied.
        # Recursive work may mutate children of this exact owned root, but another process cannot rename
        # the root or substitute a foreign quarantine pathname between validation and deletion.
        foreach ($child in @(Get-ChildItem -LiteralPath $quarantine -Force -ErrorAction Stop)) {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
        $deleteError = 0
        if (-not [HmsOwnedTempNative]::DeleteHmsOwnedDirectoryByHandle($Owned.Guard,[ref]$deleteError)) {
            throw "$Label exact-object directory delete-pending transition failed (Win32=$deleteError): $quarantine"
        }
        $Owned.Guard.Dispose(); $Owned.Guard = $null
        if (Test-Path -LiteralPath $quarantine) { throw "$Label exact-object quarantine still exists after handle deletion: $quarantine" }
        return
    }

    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "$Label owned directory disappeared before cleanup: $path" }
    $currentIdentity = Get-HmsOwnedDirectoryIdentity -Path $path -Label $Label
    if ($currentIdentity -cne $expectedIdentity) { throw "$Label cleanup rejected a foreign pathname replacement. Expected identity $expectedIdentity, found ${currentIdentity}: $path" }
    Rename-Item -LiteralPath $path -NewName (Split-Path -Leaf $quarantine) -ErrorAction Stop
    $quarantineIdentity = Get-HmsOwnedDirectoryIdentity -Path $quarantine -Label "$Label quarantine"
    if ($quarantineIdentity -cne $expectedIdentity) { throw "$Label quarantine identity changed across rename." }
    Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $quarantine) { throw "$Label quarantine still exists after cleanup: $quarantine" }
}'''
    text = regex_once(text, pattern, new_func + marker, f"{rel} owned temp cleanup function")
    write(rel, text)

patch_owned_temp("scripts/Build-HmsCompositeSkill.ps1")
patch_owned_temp("scripts/Copy-HmsCommittedGitPath.ps1")

# Builder: keep all committed support inputs read-locked after a handle-bound verification,
# then parse + execute the transformed implementation from the same in-memory string.
builder_rel = "scripts/Build-HmsCompositeSkill.ps1"
builder = read(builder_rel)
insert_after = r'''function Get-ExpectedSupportBlob {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Label)
    $value = ((& git -C $repoRoot rev-parse "$head`:$RelativePath" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $value -notmatch '^[0-9a-f]{40}$') {
        throw "$Label support materialization could not resolve committed blob: $RelativePath"
    }
    $type = ((& git -C $repoRoot cat-file -t $value 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'blob') { throw "$Label committed support object is not a blob: $RelativePath" }
    return $value
}
'''
support_guard = r'''
function Open-VerifiedSupportReadGuard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedBlob,
        [Parameter(Mandatory)][string]$Label
    )
    $stream = $null
    try {
        # FileShare.Read allows execution/readers but denies mutation, rename, and replacement while
        # the transformed runtime is using this exact authenticated support object.
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $actual = ((& git -C $repoRoot hash-object --no-filters -- $Path 2>$null) -join '').Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $actual -notmatch '^[0-9a-f]{40}$') { throw "$Label guarded support file could not be hashed." }
        if ($actual -cne $ExpectedBlob) { throw "$Label guarded support bytes changed. Expected $ExpectedBlob, found $actual." }
        return $stream
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}
'''
builder = replace_once(builder, insert_after, insert_after + support_guard, "builder support read guard")
builder = replace_once(builder, "$supportOwnedRoot = $null\n$supportRoot = $null\ntry {", "$supportOwnedRoot = $null\n$supportRoot = $null\n$supportReadGuards = @()\ntry {", "builder support guard state")
builder = replace_once(builder, "    $runtimeImplementationPath = Join-Path $supportRoot 'Build-HmsCompositeSkill.runtime.ps1'\n", "", "builder runtime pathname declaration")
materialized = r'''    Write-SupportBlobExact -BlobSha $expectedImplementation -RelativePath $implementationRelative -Destination $implementationPath -Label 'Composite implementation'
    Write-SupportBlobExact -BlobSha $expectedHelper -RelativePath $helperRelative -Destination $committedCopyHelper -Label 'Committed-copy helper'
    Write-SupportBlobExact -BlobSha $expectedSuperLock -RelativePath $superLockRelative -Destination $committedSuperLock -Label 'Superpowers lock'
    Write-SupportBlobExact -BlobSha $expectedUiLock -RelativePath $uiLockRelative -Destination $committedUiLock -Label 'UI skills lock'
'''
materialized_new = materialized + r'''    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $implementationPath -ExpectedBlob $expectedImplementation -Label 'Composite implementation'
    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $committedCopyHelper -ExpectedBlob $expectedHelper -Label 'Committed-copy helper'
    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $committedSuperLock -ExpectedBlob $expectedSuperLock -Label 'Superpowers lock'
    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $committedUiLock -ExpectedBlob $expectedUiLock -Label 'UI skills lock'
'''
builder = replace_once(builder, materialized, materialized_new, "builder support read-lock activation")
old_runtime = r'''    # Execute transformed support as a real script file. Direct committed implementation file execution
    # is the independently proven Windows liveness path; do not introduce a dynamic ScriptBlock boundary.
    [IO.File]::WriteAllText($runtimeImplementationPath, $source, $utf8Strict)
    $runtimeTokens = $null
    $runtimeParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($runtimeImplementationPath,[ref]$runtimeTokens,[ref]$runtimeParseErrors) | Out-Null
    if (@($runtimeParseErrors).Count -ne 0) {
        throw "Composite runtime implementation failed to parse after deterministic trust-boundary binding: $((@($runtimeParseErrors) | ForEach-Object { $_.Message }) -join ' | ')"
    }

    & $runtimeImplementationPath -InstallRoot $InstallRoot -OutputRoot $OutputRoot -SkillsRoot $SkillsRoot -Hms $Hms -Superpowers $Superpowers -Taste $Taste -Impeccable $Impeccable
'''
new_runtime = r'''    # Parse and execute the exact transformed string already held in memory. There is no runtime
    # pathname to reopen after validation, so a non-cooperating replacement cannot cross a parse/use gap.
    $runtimeTokens = $null
    $runtimeParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$runtimeTokens,[ref]$runtimeParseErrors) | Out-Null
    if (@($runtimeParseErrors).Count -ne 0) {
        throw "Composite in-memory runtime implementation failed to parse after deterministic trust-boundary binding: $((@($runtimeParseErrors) | ForEach-Object { $_.Message }) -join ' | ')"
    }
    try { $runtimeImplementation = [ScriptBlock]::Create($source) }
    catch { throw "Composite in-memory runtime ScriptBlock creation failed: $($_.Exception.Message)" }

    & $runtimeImplementation -InstallRoot $InstallRoot -OutputRoot $OutputRoot -SkillsRoot $SkillsRoot -Hms $Hms -Superpowers $Superpowers -Taste $Taste -Impeccable $Impeccable
'''
builder = replace_once(builder, old_runtime, new_runtime, "builder in-memory transformed execution")
old_finally = r'''finally {
    if ($null -ne $supportOwnedRoot) {
        Remove-HmsOwnedTempDirectory -Owned $supportOwnedRoot -Label 'Composite builder support root'
    }
}'''
new_finally = r'''finally {
    foreach ($guard in @($supportReadGuards)) {
        if ($null -ne $guard) { try { $guard.Dispose() } catch { } }
    }
    if ($null -ne $supportOwnedRoot) {
        Remove-HmsOwnedTempDirectory -Owned $supportOwnedRoot -Label 'Composite builder support root'
    }
}'''
builder = replace_once(builder, old_finally, new_finally, "builder support guard cleanup")
write(builder_rel, builder)

# ---------------------------------------------------------------------------
# P1 #3: model-settings write uses exact locked file handles and handle renames.
# Readers share the same named mutex so they never interpret the deliberate
# old-reservation -> candidate-publication namespace gap as default-all-ON.
# ---------------------------------------------------------------------------
model_rel = "manager/HmsModelSettings.utf8.ps1"
model = read(model_rel)
model_anchor = "$SettingsPath = Join-Path $SettingsRoot 'model-settings.json'\n\n"
model_native = r'''if (-not ('HmsModelSettingsNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HmsModelSettingsNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME_PARTS { public uint Low; public uint High; }
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
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr sa, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle hFile, int infoClass, IntPtr info, uint size);

    public static SafeFileHandle OpenLockedModelSettingsFile(string path, out int error)
    {
        // GENERIC_READ | DELETE; share READ only. Existing content can be read by HMS, but no
        // cooperating or non-cooperating writer can mutate/rename/replace this exact object.
        SafeFileHandle h = CreateFileW(path, 0x80010000u, 0x00000001u, IntPtr.Zero, 3u, 0x00200000u, IntPtr.Zero);
        error = h.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        return h;
    }

    public static bool RenameHmsModelSettingsFileByHandle(SafeFileHandle handle, string destination, out int error)
    {
        byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(destination);
        int rootOffset = IntPtr.Size == 8 ? 8 : 4;
        int lengthOffset = IntPtr.Size == 8 ? 16 : 8;
        int nameOffset = IntPtr.Size == 8 ? 20 : 12;
        int minimumStructSize = IntPtr.Size == 8 ? 24 : 16;
        int size = Math.Max(minimumStructSize, nameOffset + nameBytes.Length + 2);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
            Marshal.WriteByte(buffer, 0, 0); // ReplaceIfExists = FALSE.
            Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
            Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);
            Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);
            bool ok = SetFileInformationByHandle(handle, 3, buffer, (uint)size);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static bool DeleteHmsModelSettingsFileByHandle(SafeFileHandle handle, out int error)
    {
        IntPtr buffer = Marshal.AllocHGlobal(4);
        try
        {
            Marshal.WriteInt32(buffer, 1);
            bool ok = SetFileInformationByHandle(handle, 4, buffer, 4);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
}

function Get-HmsModelSettingsIdentityFromHandle {
    param([Parameter(Mandatory)]$Handle,[Parameter(Mandatory)][string]$Label)
    $info = New-Object 'HmsModelSettingsNative+BY_HANDLE_FILE_INFORMATION'
    if (-not [HmsModelSettingsNative]::GetFileInformationByHandle($Handle,[ref]$info)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "$Label could not read exact settings-file identity (Win32=$code)."
    }
    if (($info.FileAttributes -band [uint32]0x10) -ne 0 -or ($info.FileAttributes -band [uint32]0x400) -ne 0) {
        throw "$Label exact settings object must be a regular non-reparse file."
    }
    return ([string]$info.VolumeSerialNumber + ':' + [string]$info.FileIndexHigh + ':' + [string]$info.FileIndexLow)
}

function Open-HmsModelSettingsFileGuard {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    if ($env:OS -cne 'Windows_NT') { throw "$Label exact settings guard is Windows-specific: $Path" }
    $errorCode = 0
    $handle = [HmsModelSettingsNative]::OpenLockedModelSettingsFile($Path,[ref]$errorCode)
    if ($null -eq $handle -or $handle.IsInvalid) {
        if ($null -ne $handle) { $handle.Dispose() }
        throw "$Label could not lock the exact settings file for read+DELETE without write/delete sharing (Win32=$errorCode): $Path"
    }
    try {
        $identity = Get-HmsModelSettingsIdentityFromHandle -Handle $handle -Label $Label
        return [pscustomobject]@{ Handle=$handle; Identity=$identity; Path=$Path }
    }
    catch { $handle.Dispose(); throw }
}

function Move-HmsModelSettingsFileGuard {
    param(
        [Parameter(Mandatory)]$Guard,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$Label
    )
    if ($null -eq $Guard.Handle -or $Guard.Handle.IsClosed -or $Guard.Handle.IsInvalid) { throw "$Label exact settings guard is unavailable." }
    $before = Get-HmsModelSettingsIdentityFromHandle -Handle $Guard.Handle -Label $Label
    if ($before -cne [string]$Guard.Identity) { throw "$Label exact settings identity changed before handle rename." }
    if (Test-Path -LiteralPath $DestinationPath) { throw "$Label destination became occupied before exact handle rename: $DestinationPath" }
    $errorCode = 0
    if (-not [HmsModelSettingsNative]::RenameHmsModelSettingsFileByHandle($Guard.Handle,$DestinationPath,[ref]$errorCode)) {
        throw "$Label exact handle rename failed (Win32=$errorCode): $SourcePath -> $DestinationPath"
    }
    $after = Get-HmsModelSettingsIdentityFromHandle -Handle $Guard.Handle -Label "$Label post-rename"
    if ($after -cne [string]$Guard.Identity) { throw "$Label exact settings identity changed across handle rename." }
    $Guard.Path = $DestinationPath
}

function Remove-HmsModelSettingsFileGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    if ($null -eq $Guard.Handle -or $Guard.Handle.IsClosed -or $Guard.Handle.IsInvalid) { throw "$Label exact settings guard is unavailable for deletion." }
    $identity = Get-HmsModelSettingsIdentityFromHandle -Handle $Guard.Handle -Label $Label
    if ($identity -cne [string]$Guard.Identity) { throw "$Label exact settings identity changed before deletion." }
    $errorCode = 0
    if (-not [HmsModelSettingsNative]::DeleteHmsModelSettingsFileByHandle($Guard.Handle,[ref]$errorCode)) {
        throw "$Label exact settings-file delete-pending transition failed (Win32=$errorCode): $($Guard.Path)"
    }
    $Guard.Handle.Dispose(); $Guard.Handle = $null
}

'''
model = replace_once(model, model_anchor, model_anchor + model_native, "model native exact-file helpers")
model = replace_once(model, "function Read-ModelState {", "function Read-ModelState-Unserialized {", "model read function rename")
read_wrapper = r'''function Read-ModelState {
    param([string]$Path = $SettingsPath)
    $settingsMutexName = 'Local\HMS-Skills-Codex-ModelSettings-v1'
    $settingsMutex = New-Object System.Threading.Mutex($false,$settingsMutexName)
    $owned = $false
    try {
        try { $owned = $settingsMutex.WaitOne([TimeSpan]::FromSeconds(120)) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw "Timed out waiting for model settings reader lock: $settingsMutexName" }
        return Read-ModelState-Unserialized -Path $Path
    }
    finally {
        if ($owned) { try { $settingsMutex.ReleaseMutex() } catch { } }
        $settingsMutex.Dispose()
    }
}

'''
model = replace_once(model, "function Write-ModelState {", read_wrapper + "function Write-ModelState {", "model serialized read wrapper")
model = regex_once(
    model,
    r"function Write-ModelState \{.*?\n\}\n\nfunction Resolve-Route \{",
    r'''function Write-ModelState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$Path = $SettingsPath
    )

    Assert-StateBooleans -State $State
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    $settings = Convert-StateToSettingsObject -State $State
    $json = $settings | ConvertTo-Json -Depth 6
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $temp = Join-Path $parent ('.model-settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $previousReserved = Join-Path $parent ('.model-settings-' + [guid]::NewGuid().ToString('N') + '.previous')
    $candidateDiscard = Join-Path $parent ('.model-settings-' + [guid]::NewGuid().ToString('N') + '.discard')
    $existingGuard = $null
    $candidateGuard = $null
    $hadExisting = $false
    $previousMoved = $false
    $candidatePublished = $false

    try {
        if (Test-Path -LiteralPath $Path) {
            $existingGuard = Open-HmsModelSettingsFileGuard -Path $Path -Label 'Existing model settings'
            $null = Read-ModelState-Unserialized -Path $Path
            $hadExisting = $true
        }

        [IO.File]::WriteAllText($temp,$json,$utf8)
        $candidateGuard = Open-HmsModelSettingsFileGuard -Path $temp -Label 'Candidate model settings'
        $actualCandidateText = [IO.File]::ReadAllText($temp,$utf8)
        if ($actualCandidateText -cne $json) { throw 'Candidate model settings bytes changed before publication.' }
        $null = Read-ModelState-Unserialized -Path $temp

        if ($hadExisting) {
            Move-HmsModelSettingsFileGuard -Guard $existingGuard -SourcePath $Path -DestinationPath $previousReserved -Label 'Previous model settings reservation'
            $previousMoved = $true
        }

        Move-HmsModelSettingsFileGuard -Guard $candidateGuard -SourcePath $temp -DestinationPath $Path -Label 'Candidate model settings publication'
        $candidatePublished = $true

        $verified = Read-ModelState-Unserialized -Path $Path
        foreach ($key in @('luna','terra','sol')) {
            if ($verified[$key] -ne $State[$key]) { throw "Model setting verification mismatch for '$key'." }
        }

        if ($hadExisting) {
            Remove-HmsModelSettingsFileGuard -Guard $existingGuard -Label 'Previous model settings disposal'
            $existingGuard = $null
            $previousMoved = $false
        }
        $candidateGuard.Handle.Dispose(); $candidateGuard.Handle = $null; $candidateGuard = $null
    }
    catch {
        $writeError = $_
        $rollbackErrors = @()
        try {
            if ($null -ne $candidateGuard) {
                if ($candidatePublished) {
                    Move-HmsModelSettingsFileGuard -Guard $candidateGuard -SourcePath $Path -DestinationPath $candidateDiscard -Label 'Candidate model settings rollback reservation'
                }
                Remove-HmsModelSettingsFileGuard -Guard $candidateGuard -Label 'Candidate model settings rollback disposal'
                $candidateGuard = $null
                $candidatePublished = $false
            }
        }
        catch { $rollbackErrors += "Candidate rollback failed: $($_.Exception.Message)" }

        if ($hadExisting -and $previousMoved -and $null -ne $existingGuard) {
            try {
                if (Test-Path -LiteralPath $Path) { throw "Canonical model settings pathname became occupied during rollback: $Path" }
                Move-HmsModelSettingsFileGuard -Guard $existingGuard -SourcePath $previousReserved -DestinationPath $Path -Label 'Previous model settings restoration'
                $null = Read-ModelState-Unserialized -Path $Path
                $existingGuard.Handle.Dispose(); $existingGuard.Handle = $null; $existingGuard = $null
                $previousMoved = $false
            }
            catch { $rollbackErrors += "Previous settings restoration failed: $($_.Exception.Message)" }
        }

        if ($rollbackErrors.Count -gt 0) {
            throw "Model settings write failed and exact-object rollback was incomplete. Original: $($writeError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')"
        }
        throw $writeError
    }
    finally {
        foreach ($guard in @($candidateGuard,$existingGuard)) {
            if ($null -ne $guard -and $null -ne $guard.Handle) { try { $guard.Handle.Dispose() } catch { } }
        }
        # Never pathname-delete temp/reservation/discard artifacts here. If exact-handle authority was
        # lost, residue is safer than deleting an unrelated replacement; normal success removes all owned artifacts.
    }
}

function Resolve-Route {''',
    "model exact-object writer",
)
write(model_rel, model)

resolver_rel = "scripts/Resolve-HmsModelRoute.ps1"
resolver = read(resolver_rel)
resolver = replace_once(
    resolver,
    "$settings = Read-Settings -Path $SettingsPath\n",
    r'''$settingsMutexName = 'Local\HMS-Skills-Codex-ModelSettings-v1'
$settingsMutex = New-Object System.Threading.Mutex($false,$settingsMutexName)
$settingsMutexOwned = $false
try {
    try { $settingsMutexOwned = $settingsMutex.WaitOne([TimeSpan]::FromSeconds(120)) }
    catch [System.Threading.AbandonedMutexException] { $settingsMutexOwned = $true }
    if (-not $settingsMutexOwned) { throw "Timed out waiting for model settings reader lock: $settingsMutexName" }
    $settings = Read-Settings -Path $SettingsPath
}
finally {
    if ($settingsMutexOwned) { try { $settingsMutex.ReleaseMutex() } catch { } }
    $settingsMutex.Dispose()
}
''',
    "resolver serialized settings read",
)
write(resolver_rel, resolver)

# ---------------------------------------------------------------------------
# Permanent tests.
# ---------------------------------------------------------------------------
owned_test_rel = "scripts/Test-HmsOwnedTempCleanup.ps1"
owned_test = read(owned_test_rel)
owned_test = replace_once(
    owned_test,
    "        'RenameHmsOwnedDirectoryByHandle',\n",
    "        'RenameHmsOwnedDirectoryByHandle',\n        'DeleteHmsOwnedDirectoryByHandle',\n        'Open-HmsOwnedDirectoryIdentityHandle -Path $path -ShareMode ([uint32]3)',\n",
    "owned-temp test static additions",
)
old_case_a = regex_once.__name__  # keep linters quiet; actual replacement below
owned_test = regex_once(
    owned_test,
    r"# Case A:.*?Write-Host 'PASS: exact-handle cleanup deleted the exact original object and preserved a foreign original-path replacement\.'\n",
    r'''# Case A: the durable root handle denies FILE_SHARE_DELETE for the entire active lifetime.
# A non-cooperating process must be unable to rename/replace the exact root before cleanup.
$ownedA = New-HmsOwnedTempDirectory -Prefix 'hms-owned-temp-active-' -Label 'exact-handle regression'
$originalA = [string]$ownedA.Path
$movedA = $originalA + '-moved-by-foreign-process'
$jobA = $null
try {
    if ($ownedA.Guard.IsClosed -or $ownedA.Guard.IsInvalid) { throw 'Production exact-object handle is not live before race.' }
    $jobA = Start-Job -ScriptBlock {
        param($Original,$Moved)
        $ErrorActionPreference='Stop'
        try { Rename-Item -LiteralPath $Original -NewName (Split-Path -Leaf $Moved) -ErrorAction Stop; [pscustomobject]@{Renamed=$true;Error=''} }
        catch { [pscustomobject]@{Renamed=$false;Error=$_.Exception.Message} }
    } -ArgumentList $originalA,$movedA
    $null = Wait-Job -Job $jobA -Timeout 20
    if ($jobA.State -ne 'Completed') { throw "Cross-process rename probe did not complete. State=$($jobA.State)" }
    $probeA = Receive-Job -Job $jobA -ErrorAction Stop
    if ([bool]$probeA.Renamed) { throw 'Foreign process renamed the owned root despite the no-FILE_SHARE_DELETE guard.' }
    if (-not (Test-Path -LiteralPath $originalA -PathType Container)) { throw 'Owned root disappeared while exact guard was active.' }
    if (Test-Path -LiteralPath $movedA) { throw 'Hostile rename unexpectedly created a moved owned-root pathname.' }
    Remove-HmsOwnedTempDirectory -Owned $ownedA -Label 'exact-handle regression'
    if (Test-Path -LiteralPath $originalA) { throw 'Exact owned root remained after handle-bound cleanup.' }
}
finally {
    if ($null -ne $jobA) { Remove-Job -Job $jobA -Force -ErrorAction SilentlyContinue }
    if ($null -ne $ownedA.Guard) { $ownedA.Guard.Dispose(); $ownedA.Guard=$null }
    foreach ($p in @($originalA,$movedA)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
}
Write-Host 'PASS: active owned-temp root denies hostile rename/replacement and is deleted through its exact handle.'
''',
    "owned-temp Case A no-share-delete regression",
)
# Add structural order proof before Case B.
owned_test = replace_once(
    owned_test,
    "# Case B: loss of exact-object authority must fail closed rather than fall back to pathname deletion.\n",
    r'''$removeFunction = [regex]::Match($source,'(?s)function Remove-HmsOwnedTempDirectory \{.*?\n\}\n\n\n\$repoRoot').Value
if ([string]::IsNullOrWhiteSpace($removeFunction)) { throw 'Could not isolate owned-temp removal function for destructive-order proof.' }
$deletePos = $removeFunction.IndexOf('DeleteHmsOwnedDirectoryByHandle')
$disposePos = $removeFunction.IndexOf('$Owned.Guard.Dispose()')
$rootRemovePos = $removeFunction.IndexOf('Remove-Item -LiteralPath $quarantine -Recurse -Force')
if ($deletePos -lt 0 -or $disposePos -lt 0 -or $deletePos -ge $disposePos) { throw 'Owned-temp exact handle is not retained through the root delete-pending transition.' }
if ($rootRemovePos -ge 0 -and $env:OS -ceq 'Windows_NT') { throw 'Windows owned-temp cleanup still contains pathname-recursive root deletion.' }
Write-Host 'PASS: exact-object guard remains live until the directory handle enters delete-pending state.'

# Case B: loss of exact-object authority must fail closed rather than fall back to pathname deletion.
''',
    "owned-temp destructive order proof",
)
write(owned_test_rel, owned_test)

late_test_rel = "scripts/Test-HmsLateTrustBoundaries.ps1"
late_test = r'''[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$builderPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.ps1'
$modelPath = Join-Path $RepoRoot 'manager\HmsModelSettings.utf8.ps1'
$resolverPath = Join-Path $RepoRoot 'scripts\Resolve-HmsModelRoute.ps1'
foreach ($path in @($builderPath,$modelPath,$resolverPath)) {
    $tokens=$null; $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
    if (@($errors).Count -ne 0) { throw "Late-P1 regression parser rejected $path : $((@($errors)|ForEach-Object Message)-join ' | ')" }
}

$builderText = [IO.File]::ReadAllText($builderPath)
foreach ($literal in @('Open-VerifiedSupportReadGuard','Parser]::ParseInput($source','[ScriptBlock]::Create($source)','DeleteHmsOwnedDirectoryByHandle','ShareMode ([uint32]3)')) {
    if ($builderText -notmatch [regex]::Escape($literal)) { throw "Builder is missing late-P1 contract: $literal" }
}
if ($builderText -match [regex]::Escape('& $runtimeImplementationPath')) { throw 'Builder still reopens a transformed runtime pathname for execution.' }
if ($builderText -match [regex]::Escape("Build-HmsCompositeSkill.runtime.ps1")) { throw 'Builder still materializes a replaceable transformed runtime file.' }

$modelText = [IO.File]::ReadAllText($modelPath)
foreach ($literal in @('HmsModelSettingsNative','OpenLockedModelSettingsFile','RenameHmsModelSettingsFileByHandle','DeleteHmsModelSettingsFileByHandle','Previous model settings reservation','Candidate model settings publication','Read-ModelState-Unserialized')) {
    if ($modelText -notmatch [regex]::Escape($literal)) { throw "Model Settings is missing exact-object write contract: $literal" }
}
if ($modelText -match [regex]::Escape('[IO.File]::Replace($temp, $Path')) { throw 'Model Settings retained pathname File.Replace at the publication boundary.' }

$resolverText = [IO.File]::ReadAllText($resolverPath)
foreach ($literal in @("Local\\HMS-Skills-Codex-ModelSettings-v1",'Timed out waiting for model settings reader lock')) {
    if ($resolverText -notmatch [regex]::Escape($literal)) { throw "Resolver is missing serialized read contract: $literal" }
}

if ($env:OS -cne 'Windows_NT') {
    Write-Host 'SKIP: late-P1 exact settings-handle runtime regression is Windows-specific.'
    return
}

# Execute only the production native settings prelude/helpers, not the WinForms UI.
$start = $modelText.IndexOf("if (-not ('HmsModelSettingsNative' -as [type])) {")
$end = $modelText.IndexOf('$ModelDefinitions = @(',$start)
if ($start -lt 0 -or $end -lt 0) { throw 'Could not isolate production Model Settings exact-file helper prelude.' }
$helperPath = Join-Path $env:TEMP ('hms-model-settings-guard-helper-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($helperPath,$modelText.Substring($start,$end-$start),(New-Object Text.UTF8Encoding($false)))
. $helperPath

$root = Join-Path $env:TEMP ('hms-model-settings-guard-' + [guid]::NewGuid().ToString('N'))
$path = Join-Path $root 'model-settings.json'
$moved = Join-Path $root 'foreign-moved.json'
$reserved = Join-Path $root 'reserved.json'
$guard = $null
$job = $null
try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText($path,'{"schema_version":1,"managed_by":"HMS-Skills-Codex","artifact":"hms-model-settings","models":{"luna":true,"terra":true,"sol":true}}',(New-Object Text.UTF8Encoding($false)))
    $guard = Open-HmsModelSettingsFileGuard -Path $path -Label 'late-P1 settings guard regression'
    $job = Start-Job -ScriptBlock {
        param($Path,$Moved)
        try { Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $Moved) -ErrorAction Stop; [pscustomobject]@{Renamed=$true;Error=''} }
        catch { [pscustomobject]@{Renamed=$false;Error=$_.Exception.Message} }
    } -ArgumentList $path,$moved
    $null = Wait-Job -Job $job -Timeout 20
    if ($job.State -ne 'Completed') { throw "Settings replacement probe did not complete. State=$($job.State)" }
    $probe = Receive-Job -Job $job -ErrorAction Stop
    if ([bool]$probe.Renamed) { throw 'Foreign process renamed the validated settings file while exact guard was live.' }
    Move-HmsModelSettingsFileGuard -Guard $guard -SourcePath $path -DestinationPath $reserved -Label 'late-P1 settings reservation regression'
    if (Test-Path -LiteralPath $path) { throw 'Exact settings handle rename did not vacate canonical path.' }
    if (-not (Test-Path -LiteralPath $reserved -PathType Leaf)) { throw 'Exact settings handle rename did not create reservation.' }
    Remove-HmsModelSettingsFileGuard -Guard $guard -Label 'late-P1 settings disposal regression'
    $guard = $null
}
finally {
    if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    if ($null -ne $guard -and $null -ne $guard.Handle) { $guard.Handle.Dispose() }
    foreach ($p in @($helperPath,$root)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
}
Write-Host 'PASS: validated Model Settings file is pinned against foreign rename and moved/deleted only through its exact handle.'

# Resolver must not observe the writer's deliberate canonical-path gap.
$settingsRoot = Join-Path $env:TEMP ('hms-model-settings-reader-lock-' + [guid]::NewGuid().ToString('N'))
$settingsPath = Join-Path $settingsRoot 'model-settings.json'
$mutex = New-Object System.Threading.Mutex($false,'Local\HMS-Skills-Codex-ModelSettings-v1')
$mutexOwned = $false
$readerJob = $null
try {
    New-Item -ItemType Directory -Force -Path $settingsRoot | Out-Null
    [IO.File]::WriteAllText($settingsPath,'{"schema_version":1,"managed_by":"HMS-Skills-Codex","artifact":"hms-model-settings","models":{"luna":true,"terra":true,"sol":true}}',(New-Object Text.UTF8Encoding($false)))
    $mutexOwned = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
    if (-not $mutexOwned) { throw 'Could not acquire model-settings mutex for reader serialization regression.' }
    $readerJob = Start-Job -ScriptBlock {
        param($Resolver,$Settings)
        & $Resolver -RiskClass 'NORMAL_WORK' -RequiredFloor 'TERRA_MEDIUM_OR_STRONGER' -SettingsPath $Settings
    } -ArgumentList $resolverPath,$settingsPath
    Start-Sleep -Milliseconds 800
    if ($readerJob.State -ne 'Running') { throw "Resolver did not block on writer mutex. State=$($readerJob.State)" }
    $mutex.ReleaseMutex(); $mutexOwned=$false
    $null = Wait-Job -Job $readerJob -Timeout 20
    if ($readerJob.State -ne 'Completed') { throw "Resolver did not complete after writer mutex release. State=$($readerJob.State)" }
    $result = Receive-Job -Job $readerJob -ErrorAction Stop
    if ($result.status -cne 'ASSIGNED' -or $result.assigned_model -cne 'gpt-5.6-terra') { throw 'Resolver returned unexpected route after serialized read.' }
}
finally {
    if ($mutexOwned) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
    if ($null -ne $readerJob) { Remove-Job -Job $readerJob -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $settingsRoot) { Remove-Item -LiteralPath $settingsRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host 'PASS: model route resolver serializes persisted-settings reads with the writer transaction.'
Write-Host 'PASS: three late P1 trust boundaries are permanently qualified.'
'''
write(late_test_rel, late_test)

skills_rel = "scripts/Test-HmsSkills.ps1"
skills = read(skills_rel)
skills = replace_once(skills, "$rollbackIdentityPath = Join-Path $PSScriptRoot 'Test-HmsRollbackIdentityHandoff.ps1'\n", "$rollbackIdentityPath = Join-Path $PSScriptRoot 'Test-HmsRollbackIdentityHandoff.ps1'\n$lateTrustPath = Join-Path $PSScriptRoot 'Test-HmsLateTrustBoundaries.ps1'\n", "validator late trust path")
skills = replace_once(skills, "foreach ($path in @($implementationPath,$remediationPath,$ownedTempCleanupPath,$rollbackIdentityPath)) {", "foreach ($path in @($implementationPath,$remediationPath,$ownedTempCleanupPath,$rollbackIdentityPath,$lateTrustPath)) {", "validator late trust support list")
skills = replace_once(skills, "& $rollbackIdentityPath -RepoRoot $RepoRoot\n", "& $rollbackIdentityPath -RepoRoot $RepoRoot\n& $lateTrustPath -RepoRoot $RepoRoot\n", "validator late trust invocation")
write(skills_rel, skills)

# Basic post-patch invariants before the Windows author workflow executes PowerShell.
for rel in [
    "scripts/Build-HmsCompositeSkill.ps1",
    "scripts/Copy-HmsCommittedGitPath.ps1",
    "manager/HmsModelSettings.utf8.ps1",
    "scripts/Resolve-HmsModelRoute.ps1",
    "scripts/Test-HmsOwnedTempCleanup.ps1",
    "scripts/Test-HmsSkills.ps1",
    late_test_rel,
]:
    require((ROOT / rel).exists(), f"patched file missing: {rel}")

require("& $runtimeImplementationPath" not in read(builder_rel), "runtime pathname execution remained after patch")
require("[IO.File]::Replace($temp, $Path" not in read(model_rel), "pathname File.Replace remained after patch")
print("PASS: temporary patcher applied three late P1 production remediations and permanent regressions.")
