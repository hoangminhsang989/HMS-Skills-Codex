[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [string]$OutputRoot = (Join-Path $env:USERPROFILE '.codex\hms-composite'),
    [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.agents\skills'),
    [bool]$Hms = $true,
    [bool]$Superpowers = $true,
    [bool]$Taste = $true,
    [bool]$Impeccable = $true,
    [string]$TrustedRepoRoot,
    [string]$TrustedHead,
    [string]$TrustedBootstrapBlob
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('HmsOwnedTempNative' -as [type])) {
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
        int minimumStructSize = IntPtr.Size == 8 ? 24 : 16;
        int size = Math.Max(minimumStructSize, nameOffset + nameBytes.Length + 2); // trailing UTF-16 NUL/padding; FileNameLength still excludes it.
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
        [uint32]$DesiredAccess = [uint32]0x00010000,
        [Parameter(Mandatory)][string]$Label
    )

    if ($env:OS -cne 'Windows_NT') { throw "$Label Windows directory handle requested on non-Windows host: $Path" }

    # DELETE access is required for FileRenameInfo. BACKUP_SEMANTICS opens a directory handle;
    # OPEN_REPARSE_POINT prevents silently following a replacement reparse point.
    $handle = [HmsOwnedTempNative]::CreateFileW(
        $Path,
        $DesiredAccess,
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
    $opened = Open-HmsOwnedDirectoryIdentityHandle -Path $Path -ShareMode ([uint32]7) -DesiredAccess ([uint32]0x00000080) -Label $Label
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

    # Hold the root with DELETE access but without FILE_SHARE_DELETE for its entire lifetime.
    # Non-cooperating processes cannot rename/replace the exact owned root while HMS is using it;
    # cleanup itself renames and deletes that exact object through the same durable handle.
    $guarded = Open-HmsOwnedDirectoryIdentityHandle -Path $path -ShareMode ([uint32]3) -Label $Label
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
}


$selfRelative = 'scripts/Build-HmsCompositeSkill.ps1'
$implementationRelative = 'scripts/Build-HmsCompositeSkill.impl.ps1'
$helperRelative = 'scripts/Copy-HmsCommittedGitPath.ps1'
$superLockRelative = 'superpowers.lock.json'
$uiLockRelative = 'ui-skills.lock.json'
$trustedValues = @($TrustedRepoRoot,$TrustedHead,$TrustedBootstrapBlob)
$trustedCount = @($trustedValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
if ($trustedCount -notin @(0,3)) { throw 'Composite builder trusted snapshot context is incomplete.' }
$trustedBootstrap = $trustedCount -eq 3
$trustedBlob = $null
if ($trustedBootstrap) {
    try { $repoRoot = (Resolve-Path -LiteralPath $TrustedRepoRoot -ErrorAction Stop).Path.TrimEnd('\') }
    catch { throw "Composite builder trusted repository root is invalid: $TrustedRepoRoot" }
    $head = $TrustedHead.Trim().ToLowerInvariant()
    if ($head -notmatch '^[0-9a-f]{40}$') { throw "Composite builder trusted HEAD is invalid: $TrustedHead" }
    $trustedBlob = $TrustedBootstrapBlob.Trim().ToLowerInvariant()
    if ($trustedBlob -notmatch '^[0-9a-f]{40}$') { throw "Composite builder trusted bootstrap blob is invalid: $TrustedBootstrapBlob" }
    $expectedTrustedSelf = ((& git -C $repoRoot rev-parse "$head`:$selfRelative" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $expectedTrustedSelf -notmatch '^[0-9a-f]{40}$' -or $expectedTrustedSelf -cne $trustedBlob) {
        throw 'Composite builder trusted snapshot context does not match the captured committed builder.'
    }
    $trustedType = ((& git -C $repoRoot cat-file -t $expectedTrustedSelf 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $trustedType -cne 'blob') { throw 'Composite builder trusted bootstrap object is not a committed blob.' }
}
else {
    if ([string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) { throw 'Composite builder direct bootstrap has no file-backed repository root.' }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
        throw 'Composite support materialization could not resolve a canonical repository HEAD.'
    }
}

function Get-ExpectedSupportBlob {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Label)
    $value = ((& git -C $repoRoot rev-parse "$head`:$RelativePath" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $value -notmatch '^[0-9a-f]{40}$') {
        throw "$Label support materialization could not resolve committed blob: $RelativePath"
    }
    $type = ((& git -C $repoRoot cat-file -t $value 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'blob') { throw "$Label committed support object is not a blob: $RelativePath" }
    return $value
}

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

function Assert-NoHiddenIndexState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PathSpec,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        throw "$Label source is not a Git checkout while qualifying hidden index state: $Path"
    }
    if ([string]::IsNullOrWhiteSpace($PathSpec) -or $PathSpec.Contains('\') -or $PathSpec.StartsWith('/') -or $PathSpec -match '^[A-Za-z]:') {
        throw "$Label hidden-index pathspec is unsafe: $PathSpec"
    }
    foreach ($segment in @($PathSpec -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "$Label hidden-index pathspec contains an unsafe segment: $PathSpec"
        }
    }
    $lines = @(& git -C $Path ls-files -v -- $PathSpec 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "$Label Git index flags could not be inspected under '$PathSpec': $Path" }
    $hidden = @($lines | Where-Object {
        $text = [string]$_
        $text -match '^S ' -or $text -cmatch '^[a-z] '
    })
    if ($hidden.Count -ne 0) {
        $sample = (($hidden | Select-Object -First 8) -join '; ')
        throw "$Label enumerated skill-tree files use skip-worktree/assume-unchanged index flags; refusing live module selection under '$PathSpec': $sample"
    }
}

function Write-SupportBlobExact {
    param(
        [Parameter(Mandatory)][string]$BlobSha,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label
    )
    if ($BlobSha -notmatch '^[0-9a-f]{40}$') { throw "$Label support blob SHA is invalid: $BlobSha" }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Contains('\') -or $RelativePath.StartsWith('/') -or $RelativePath -match '^[A-Za-z]:') {
        throw "$Label support relative path is unsafe: $RelativePath"
    }
    foreach ($segment in @($RelativePath -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "$Label support relative path contains an unsafe segment: $RelativePath"
        }
    }

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $Destination) { throw "$Label support destination already exists: $Destination" }

    $gitExe = [string](Get-Command git -ErrorAction Stop).Source
    if ([string]::IsNullOrWhiteSpace($gitExe)) { throw "$Label could not resolve git executable." }

    $transportOwned = New-HmsOwnedTempDirectory -Prefix 'hms-support-transport-' -Label "$Label support transport root"
    $transportRoot = [string]$transportOwned.Path
    $transportGit = Join-Path $transportRoot 'repo.git'
    $archivePath = Join-Path $transportRoot 'support.zip'
    try {
        & $gitExe init --bare --quiet $transportGit
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $transportGit -PathType Container)) {
            throw "$Label could not initialize isolated Git object transport."
        }

        $objectsPath = ((& $gitExe -C $repoRoot rev-parse --path-format=absolute --git-path objects 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($objectsPath) -or -not (Test-Path -LiteralPath $objectsPath -PathType Container)) {
            throw "$Label could not resolve the source Git object directory."
        }
        $alternatesPath = Join-Path $transportGit 'objects\info\alternates'
        [IO.File]::WriteAllText($alternatesPath, ($objectsPath.Replace('\','/') + "`n"), (New-Object System.Text.UTF8Encoding($false)))

        # The isolated bare transport intentionally has no source-repository info/attributes.
        # Its highest-precedence attributes neutralize archive/EOL transforms; the literal blob hash below
        # remains the final fail-closed authority and rejects any transport that changes committed bytes.
        $attributesPath = Join-Path $transportGit 'info\attributes'
        $neutralAttributes = '** -text -crlf -eol -ident -filter -working-tree-encoding -export-ignore -export-subst' + "`n"
        [IO.File]::WriteAllText($attributesPath, $neutralAttributes, (New-Object System.Text.UTF8Encoding($false)))

        & $gitExe "--git-dir=$transportGit" -c core.autocrlf=false -c core.eol=lf archive --format=zip "--output=$archivePath" $head -- $RelativePath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            throw "$Label exact-HEAD archive transport failed for: $RelativePath"
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $matches = @($archive.Entries | Where-Object { $_.FullName -ceq $RelativePath })
            if ($matches.Count -ne 1) {
                throw "$Label exact-HEAD archive transport expected one entry '$RelativePath', found $($matches.Count)."
            }
            $input = $matches[0].Open()
            $output = New-Object System.IO.FileStream($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $input.CopyTo($output)
                $output.Flush()
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }

        $actual = ((& $gitExe -C $repoRoot hash-object --no-filters -- $Destination 2>$null) -join '').Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $actual -notmatch '^[0-9a-f]{40}$') { throw "$Label exact support materialization could not be hashed." }
        if ($actual -cne $BlobSha) {
            throw "$Label exact-HEAD archive transport changed committed bytes. Expected $BlobSha, found $actual."
        }
    }
    catch {
        # Destination lives inside the identity-guarded support root. The owned parent performs cleanup;
        # never delete a child pathname here after verification failure because it may have been replaced.
        throw
    }
    finally {
        if ($null -ne $transportOwned) {
            Remove-HmsOwnedTempDirectory -Owned $transportOwned -Label "$Label support transport root"
        }
    }
}

function Test-ExactHeadLifecycleCaller {
    foreach ($relative in @('install.ps1','update.ps1')) {
        $candidatePath = Join-Path $repoRoot $relative
        if (-not (Test-Path -LiteralPath $candidatePath)) { continue }
        $resolvedCandidate = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
        foreach ($frame in @(Get-PSCallStack)) {
            $scriptName = [string]$frame.ScriptName
            if ([string]::IsNullOrWhiteSpace($scriptName)) { continue }
            try { $resolvedCaller = (Resolve-Path -LiteralPath $scriptName -ErrorAction Stop).Path }
            catch { continue }
            if ($resolvedCaller -ine $resolvedCandidate) { continue }

            $expectedCaller = Get-ExpectedSupportBlob -RelativePath $relative -Label "Lifecycle caller $relative"
            $actualCaller = ((& git -C $repoRoot hash-object --no-filters -- $resolvedCandidate 2>$null) -join '').Trim().ToLowerInvariant()
            if ($LASTEXITCODE -ne 0 -or $actualCaller -notmatch '^[0-9a-f]{40}$') {
                throw "Lifecycle caller literal bytes could not be hashed: $relative"
            }
            if ($actualCaller -cne $expectedCaller) {
                throw "Lifecycle caller bytes do not match HMS HEAD $head; refusing inherited composite-lock ownership. Expected $expectedCaller, found ${actualCaller}: $relative"
            }
            return $true
        }
    }
    return $false
}

$expectedSelf = Get-ExpectedSupportBlob -RelativePath $selfRelative -Label 'Public composite bootstrap'
if ($trustedBootstrap) {
    $actualSelf = $trustedBlob
}
else {
    if ([string]::IsNullOrWhiteSpace([string]$PSCommandPath)) { throw 'Public composite bootstrap has no file-backed path to authenticate.' }
    $actualSelf = ((& git -C $repoRoot hash-object --no-filters -- $PSCommandPath 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $actualSelf -notmatch '^[0-9a-f]{40}$') {
        throw 'Public composite bootstrap literal worktree bytes could not be hashed.'
    }
}
if ($actualSelf -cne $expectedSelf) {
    throw "Public composite bootstrap bytes do not match HMS HEAD $head; refusing hidden worktree drift. Expected $expectedSelf, found $actualSelf."
}

# Only collection roots that the committed implementation enumerates from the live filesystem
# need an index-visibility gate. Support files and single-skill sources remain authorized by exact
# committed-object materialization / explicit presence checks and must not be globally rejected.
if ($Hms) { Assert-NoHiddenIndexState -Path $InstallRoot -PathSpec 'skills' -Label 'HMS Skills Codex' }
if ($Superpowers) { Assert-NoHiddenIndexState -Path (Join-Path $env:USERPROFILE '.codex\superpowers') -PathSpec 'skills' -Label 'Superpowers' }

$lifecycleOwnsBuildMutex = Test-ExactHeadLifecycleCaller
$supportOwnedRoot = $null
$supportRoot = $null
$supportReadGuards = @()
try {
    $expectedImplementation = Get-ExpectedSupportBlob -RelativePath $implementationRelative -Label 'Composite implementation'
    $expectedHelper = Get-ExpectedSupportBlob -RelativePath $helperRelative -Label 'Committed-copy helper'
    $expectedSuperLock = Get-ExpectedSupportBlob -RelativePath $superLockRelative -Label 'Superpowers lock'
    $expectedUiLock = Get-ExpectedSupportBlob -RelativePath $uiLockRelative -Label 'UI skills lock'
    $supportOwnedRoot = New-HmsOwnedTempDirectory -Prefix 'hms-builder-support-' -Label 'Composite builder support root'
    $supportRoot = [string]$supportOwnedRoot.Path
    $implementationPath = Join-Path $supportRoot 'Build-HmsCompositeSkill.impl.ps1'
    $committedCopyHelper = Join-Path $supportRoot 'Copy-HmsCommittedGitPath.ps1'
    $committedSuperLock = Join-Path $supportRoot 'superpowers.lock.json'
    $committedUiLock = Join-Path $supportRoot 'ui-skills.lock.json'
    Write-SupportBlobExact -BlobSha $expectedImplementation -RelativePath $implementationRelative -Destination $implementationPath -Label 'Composite implementation'
    Write-SupportBlobExact -BlobSha $expectedHelper -RelativePath $helperRelative -Destination $committedCopyHelper -Label 'Committed-copy helper'
    Write-SupportBlobExact -BlobSha $expectedSuperLock -RelativePath $superLockRelative -Destination $committedSuperLock -Label 'Superpowers lock'
    Write-SupportBlobExact -BlobSha $expectedUiLock -RelativePath $uiLockRelative -Destination $committedUiLock -Label 'UI skills lock'
    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $implementationPath -ExpectedBlob $expectedImplementation -Label 'Composite implementation'
    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $committedCopyHelper -ExpectedBlob $expectedHelper -Label 'Committed-copy helper'
    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $committedSuperLock -ExpectedBlob $expectedSuperLock -Label 'Superpowers lock'
    $supportReadGuards += Open-VerifiedSupportReadGuard -Path $committedUiLock -ExpectedBlob $expectedUiLock -Label 'UI skills lock'

    $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
    try { $source = [IO.File]::ReadAllText($implementationPath, $utf8Strict) }
    catch { throw "Composite build implementation is not valid UTF-8: $($_.Exception.Message)" }

    function Replace-ExactlyOnce {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Needle,
            [Parameter(Mandatory)][string]$Replacement,
            [Parameter(Mandatory)][string]$Label
        )
        $count = [regex]::Matches($Text, [regex]::Escape($Needle)).Count
        if ($count -ne 1) { throw "$Label bootstrap contract mismatch: expected exactly one occurrence, found $count." }
        return $Text.Replace($Needle, $Replacement)
    }

    function Replace-RegexRequiredWhen {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Pattern,
            [Parameter(Mandatory)][string]$Replacement,
            [Parameter(Mandatory)][bool]$Required,
            [Parameter(Mandatory)][string]$Label
        )
        $regex = New-Object System.Text.RegularExpressions.Regex($Pattern,[System.Text.RegularExpressions.RegexOptions]::Multiline)
        $count = $regex.Matches($Text).Count
        if ($Required -and $count -ne 1) { throw "$Label bootstrap contract mismatch: expected exactly one occurrence, found $count." }
        if (-not $Required -and $count -gt 1) { throw "$Label bootstrap contract mismatch: expected at most one occurrence, found $count." }
        if ($count -eq 0) { return $Text }
        return $regex.Replace($Text, $Replacement, 1)
    }

    $escapedHelper = $committedCopyHelper.Replace("'", "''")
    $directoryCopyNeedle = '    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force'
    $directoryCopyReplacement = "    & '$escapedHelper' -Source `$Source -Destination `$Destination -ExpectedHead `$ExpectedHead"
    $source = Replace-ExactlyOnce -Text $source -Needle $directoryCopyNeedle -Replacement $directoryCopyReplacement -Label 'Committed skill-tree copy'

    $resolverCopyNeedle = "    Copy-Item -LiteralPath `$ModelResolverSource -Destination (Join-Path `$modelDispatcherDestination 'Resolve-HmsModelRoute.ps1') -Force"
    $resolverCopyReplacement = "    & '$escapedHelper' -Source `$ModelResolverSource -Destination (Join-Path `$modelDispatcherDestination 'Resolve-HmsModelRoute.ps1') -ExpectedHead ([string]`$sourceHeadsBefore['hms'])"
    $source = Replace-ExactlyOnce -Text $source -Needle $resolverCopyNeedle -Replacement $resolverCopyReplacement -Label 'Committed model-resolver copy'

    $escapedSuperLock = $committedSuperLock.Replace("'", "''")
    $superLockNeedle = '$SuperpowersLockPath = Join-Path $InstallRoot ''superpowers.lock.json'''
    $superLockReplacement = "`$SuperpowersLockPath = '$escapedSuperLock'"
    $source = Replace-ExactlyOnce -Text $source -Needle $superLockNeedle -Replacement $superLockReplacement -Label 'Committed Superpowers lock binding'

    $escapedUiLock = $committedUiLock.Replace("'", "''")
    $uiLockNeedle = '$UiLockPath = Join-Path $InstallRoot ''ui-skills.lock.json'''
    $uiLockReplacement = "`$UiLockPath = '$escapedUiLock'"
    $source = Replace-ExactlyOnce -Text $source -Needle $uiLockNeedle -Replacement $uiLockReplacement -Label 'Committed UI lock binding'

    $canonicalRemoteNeedle = '$CanonicalHmsRemote = ''https://github.com/hoangminhsang989/HMS-Skills-Codex.git'''
    $canonicalRemoteReplacement = $canonicalRemoteNeedle + "`n`$ExpectedHmsSupportHead = '$head'"
    $source = Replace-ExactlyOnce -Text $source -Needle $canonicalRemoteNeedle -Replacement $canonicalRemoteReplacement -Label 'HMS support HEAD binding'

    $hmsIdentityNeedle = "        hms = (Assert-GitSourceIdentity -Path `$InstallRoot -ExpectedRepository `$CanonicalHmsRemote -Label 'HMS Skills Codex')"
    $hmsIdentityReplacement = "        hms = (Assert-GitSourceIdentity -Path `$InstallRoot -ExpectedRepository `$CanonicalHmsRemote -ExpectedCommit `$ExpectedHmsSupportHead -Label 'HMS Skills Codex')"
    $source = Replace-ExactlyOnce -Text $source -Needle $hmsIdentityNeedle -Replacement $hmsIdentityReplacement -Label 'HMS source/support identity binding'

    $legacyAuthorityLiteral = '1. Owner instruction and current project authority always outrank every internal module.'
    $authorityLiteral = '1. Authority precedence is fixed, highest to lowest: Owner instruction > latest valid HMS checkpoint / frozen authority > HMS fail-closed + safety rules > HMS model risk floor + dedicated model dispatcher > HMS project-specific product / UI authority > explicitly requested Three-Level Delivery governance > enabled Superpowers engineering method > CodeGraph context/evidence + enabled UI advisors > Codex defaults. Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.'
    $authorityNeedle = "        '$legacyAuthorityLiteral',"
    $authorityReplacement = "        '$authorityLiteral',"
    $source = Replace-ExactlyOnce -Text $source -Needle $authorityNeedle -Replacement $authorityReplacement -Label 'Generated authority precedence'

    $legacyUiSequence = 'Apply only enabled work modules, sequentially, inside owner/project UI authority. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
    $uiSequence = 'Apply only enabled work modules sequentially after the applicable higher HMS checkpoint, fail-closed/safety, and required-model-floor gates are satisfied. Taste owns unresolved direction when enabled; Impeccable owns audit/polish when enabled; Superpowers owns implementation when enabled; HMS owns evidence/release when enabled.'
    $source = Replace-ExactlyOnce -Text $source -Needle $legacyUiSequence -Replacement $uiSequence -Label 'UI authority sequence'

    # Exactly one cross-process lock owner exists on every path:
    # - direct implementation: committed implementation owns the mutex;
    # - direct public wrapper: transformed runtime file retains that same implementation mutex;
    # - exact install/update lifecycle: lifecycle already owns the mutex, so only that path strips
    #   the implementation acquire/release before executing the transformed runtime file.
    if ($lifecycleOwnsBuildMutex) {
        $dynamicLockMarker = '$buildMutex = New-Object System.Threading.Mutex($false, $BuildMutexName)'
        if (-not $source.Contains($dynamicLockMarker)) {
            throw 'Lifecycle-owned runtime expected the committed implementation mutex marker but it was absent.'
        }
        $implementationLockPattern = '(?m)^\$buildMutex = New-Object System\.Threading\.Mutex\(\$false, \$BuildMutexName\)\r?\n\$mutexOwned = \$false\r?\n\$stage = \$null\r?\ntry \{\r?\n    try \{\r?\n        \$mutexOwned = \$buildMutex\.WaitOne\(\[TimeSpan\]::FromSeconds\(120\)\)\r?\n    \}\r?\n    catch \[System\.Threading\.AbandonedMutexException\] \{\r?\n        \$mutexOwned = \$true\r?\n    \}\r?\n    if \(-not \$mutexOwned\) \{ throw "Timed out waiting for composite build lock: \$BuildMutexName" \}\r?\n'
        $implementationLockPattern = $implementationLockPattern.Replace('\\','\')
        $implementationLockReplacement = '$buildMutex = $null' + "`n" + '$mutexOwned = $false' + "`n" + '$stage = $null' + "`n" + 'try {' + "`n"
        $source = Replace-RegexRequiredWhen -Text $source -Pattern $implementationLockPattern -Replacement $implementationLockReplacement -Required $true -Label 'Lifecycle-owned implementation composite mutex acquisition'

        $implementationDisposePattern = '(?m)^    \$buildMutex\.Dispose\(\)\r?$'.Replace('\\','\')
        $source = Replace-RegexRequiredWhen -Text $source -Pattern $implementationDisposePattern -Replacement '    if ($null -ne $buildMutex) { $buildMutex.Dispose() }' -Required $true -Label 'Lifecycle-owned implementation composite mutex disposal'
    }

    # Parse and execute the exact transformed string already held in memory. There is no runtime
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

    $generatedSkill = Join-Path (Join-Path $OutputRoot 'hms-superpowers') 'SKILL.md'
    if (-not (Test-Path -LiteralPath $generatedSkill)) { throw "Generated composite SKILL.md is missing after build: $generatedSkill" }
    $generatedText = [IO.File]::ReadAllText($generatedSkill, $utf8Strict)
    if ($generatedText -notmatch [regex]::Escape($authorityLiteral)) { throw 'Generated composite omitted the canonical HMS authority precedence.' }
    if ($generatedText -match [regex]::Escape($legacyAuthorityLiteral)) { throw 'Generated composite retained the superseded project-authority precedence.' }
    if ($generatedText -notmatch [regex]::Escape('Project-specific authority never bypasses an HMS checkpoint, fail-closed/safety rule, or required model floor.')) {
        throw 'Generated composite did not preserve the project-authority safety boundary.'
    }

    Write-Host "PASS: public bootstrap, file-executed runtime implementation, committed-copy helper, and lock inputs are bound to HMS HEAD $head; support bytes are isolated exact-HEAD archive transports with literal blob verification, runtime ownership is single-lock serialized, and authority precedence is pinned below HMS checkpoint/safety/model-floor gates."
}
finally {
    foreach ($guard in @($supportReadGuards)) {
        if ($null -ne $guard) { try { $guard.Dispose() } catch { } }
    }
    if ($null -ne $supportOwnedRoot) {
        Remove-HmsOwnedTempDirectory -Owned $supportOwnedRoot -Label 'Composite builder support root'
    }
}
