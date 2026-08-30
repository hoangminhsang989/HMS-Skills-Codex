[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [string]$ExpectedHead
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


function Get-FullPathWithoutExistenceRequirement {
    param([Parameter(Mandatory)][string]$Path)
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return [IO.Path]::GetFullPath($Path).TrimEnd($trimChars)
}

function Get-ExistingProbePath {
    param([Parameter(Mandatory)][string]$Path)
    $probe = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $probe)) {
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) {
            throw "Unable to locate an existing parent for Git source path: $Path"
        }
        $probe = $parent
    }
    return $probe
}

function Get-LiteralBlobHash {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Path)
    $value = ((& git -C $RepoRoot hash-object --no-filters -- $Path 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $value -notmatch '^[0-9a-f]{40}$') {
        throw "Unable to compute literal Git blob hash for materialized file: $Path"
    }
    return $value
}

function Assert-SafeRelativeGitPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw 'Committed-copy tree produced an empty relative path.' }
    if ($RelativePath.Contains('\')) { throw "Committed-copy Git path contains a backslash and is unsafe on Windows: $RelativePath" }
    if ($RelativePath.StartsWith('/') -or $RelativePath -match '^[A-Za-z]:') { throw "Committed-copy Git path is rooted: $RelativePath" }
    foreach ($segment in @($RelativePath -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Committed-copy Git path contains an unsafe segment: $RelativePath"
        }
    }
}

function Get-SafeDestinationPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )
    Assert-SafeRelativeGitPath -RelativePath $RelativePath
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $candidate = $rootFull
    foreach ($segment in @($RelativePath -split '/')) { $candidate = Join-Path $candidate $segment }
    $candidateFull = [IO.Path]::GetFullPath($candidate)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Committed-copy destination escaped managed root: $RelativePath"
    }
    return $candidateFull
}

function Restore-ExecutableMode {
    param([Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$Mode)
    if ($Mode -notin @('100644','100755')) { throw "Unsupported committed file mode: $Mode" }
    if ($Mode -ceq '100755' -and $env:OS -cne 'Windows_NT') {
        & chmod 755 -- $Destination
        if ($LASTEXITCODE -ne 0) { throw "Failed to restore executable mode on materialized file: $Destination" }
    }
}

$sourceFull = Get-FullPathWithoutExistenceRequirement -Path $Source
$probePath = Get-ExistingProbePath -Path $Source
if (-not (Test-Path -LiteralPath $probePath -PathType Container)) { $probePath = Split-Path -Parent $probePath }

$repoTopRaw = ((& git -C $probePath rev-parse --show-toplevel 2>$null) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoTopRaw)) {
    throw "Committed-copy source is not inside a readable Git checkout: $Source"
}
$repoRoot = Get-FullPathWithoutExistenceRequirement -Path $repoTopRaw
$separator = [string][IO.Path]::DirectorySeparatorChar
$prefix = $repoRoot + $separator
if ($sourceFull -ieq $repoRoot) {
    $pathSpec = '.'
}
elseif ($sourceFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    $pathSpec = $sourceFull.Substring($prefix.Length).Replace('\','/')
}
else {
    throw "Committed-copy source escaped its Git repository root: $Source"
}

if ([string]::IsNullOrWhiteSpace($ExpectedHead)) {
    $head = ((& git -C $repoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
        throw "Committed-copy source HEAD is not a canonical 40-hex commit: $repoRoot"
    }
}
else {
    $head = $ExpectedHead.Trim().ToLowerInvariant()
    if ($head -notmatch '^[0-9a-f]{40}$') { throw "Committed-copy expected HEAD is invalid: $ExpectedHead" }
    $commitType = ((& git -C $repoRoot cat-file -t $head 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $commitType -cne 'commit') {
        throw "Committed-copy expected source commit is unavailable: $head"
    }
}

$objectSpec = if ($pathSpec -ceq '.') { "$head`:" } else { "$head`:$pathSpec" }
$sourceType = ((& git -C $repoRoot cat-file -t $objectSpec 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $sourceType -notin @('blob','tree')) {
    throw "Committed-copy path is not a regular blob/tree in source HEAD $head : $pathSpec"
}

$treeLines = @(& git -C $repoRoot -c 'core.quotePath=false' ls-tree -r $head -- $pathSpec 2>$null)
if ($LASTEXITCODE -ne 0 -or $treeLines.Count -eq 0) {
    throw "Committed-copy tree could not be enumerated from HEAD $head : $pathSpec"
}
$entries = [ordered]@{}
$archiveIndex = [ordered]@{}
$treePrefix = if ($pathSpec -ceq '.') { '' } else { $pathSpec.TrimEnd('/') + '/' }
foreach ($line in $treeLines) {
    $text = [string]$line
    if ($text -notmatch '^(100644|100755) blob ([0-9a-f]{40})\t(.+)$') {
        throw "Committed-copy path contains a non-regular or unparseable Git entry: $text"
    }
    $mode = $Matches[1]
    $blob = $Matches[2].ToLowerInvariant()
    $repoRelative = $Matches[3].Replace('\','/')
    Assert-SafeRelativeGitPath -RelativePath $repoRelative
    if ($sourceType -ceq 'blob') {
        $relative = Split-Path -Leaf $repoRelative
    }
    else {
        if (-not [string]::IsNullOrEmpty($treePrefix) -and -not $repoRelative.StartsWith($treePrefix, [StringComparison]::Ordinal)) {
            throw "Committed-copy tree entry escaped requested source path: $repoRelative"
        }
        $relative = if ([string]::IsNullOrEmpty($treePrefix)) { $repoRelative } else { $repoRelative.Substring($treePrefix.Length) }
    }
    Assert-SafeRelativeGitPath -RelativePath $relative
    if ($entries.Contains($relative)) { throw "Committed-copy tree produced a duplicate relative path: $relative" }
    if ($archiveIndex.Contains($repoRelative)) { throw "Committed-copy tree produced a duplicate archive path: $repoRelative" }
    $entries[$relative] = [pscustomobject]@{ Mode=$mode; Blob=$blob; ArchivePath=$repoRelative }
    $archiveIndex[$repoRelative] = $relative
}
if ($sourceType -ceq 'blob' -and $entries.Count -ne 1) {
    throw "Committed-copy blob source enumerated $($entries.Count) files instead of one: $pathSpec"
}

if (Test-Path -LiteralPath $Destination) { throw "Committed-copy destination already exists: $Destination" }

$gitCommand = Get-Command git -ErrorAction Stop
$gitExe = [string]$gitCommand.Source
if ([string]::IsNullOrWhiteSpace($gitExe)) { throw 'Unable to resolve git executable for exact-HEAD archive transport.' }

$transportOwned = New-HmsOwnedTempDirectory -Prefix 'hms-committed-copy-transport-' -Label 'Committed-copy transport root'
$transportRoot = [string]$transportOwned.Path
$transportGit = Join-Path $transportRoot 'repo.git'
$archivePath = Join-Path $transportRoot 'committed.zip'
$destinationCreated = $false
try {
    & $gitExe init --bare --quiet $transportGit
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $transportGit -PathType Container)) {
        throw 'Committed-copy could not initialize isolated Git object transport.'
    }

    $objectsPath = ((& $gitExe -C $repoRoot rev-parse --path-format=absolute --git-path objects 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($objectsPath) -or -not (Test-Path -LiteralPath $objectsPath -PathType Container)) {
        throw 'Committed-copy could not resolve source Git object directory.'
    }
    $alternatesPath = Join-Path $transportGit 'objects\info\alternates'
    [IO.File]::WriteAllText($alternatesPath, ($objectsPath.Replace('\','/') + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    # Source-repository worktree/info attributes are outside this isolated transport. These highest-precedence
    # attributes neutralize archive/EOL transforms; every extracted file must still hash to its exact qualified blob.
    $attributesPath = Join-Path $transportGit 'info\attributes'
    $neutralAttributes = '** -text -crlf -eol -ident -filter -working-tree-encoding -export-ignore -export-subst' + "`n"
    [IO.File]::WriteAllText($attributesPath, $neutralAttributes, (New-Object System.Text.UTF8Encoding($false)))

    & $gitExe "--git-dir=$transportGit" -c core.autocrlf=false -c core.eol=lf archive --format=zip "--output=$archivePath" $head -- $pathSpec
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Committed-copy exact-commit archive transport failed: $pathSpec"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $archiveFiles = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($archiveFiles.Count -ne $entries.Count) {
            throw "Committed-copy archive file count mismatch. Expected $($entries.Count), found $($archiveFiles.Count)."
        }
        foreach ($archiveEntry in $archiveFiles) {
            if (-not $archiveIndex.Contains($archiveEntry.FullName)) {
                throw "Committed-copy archive contained an unexpected file entry: $($archiveEntry.FullName)"
            }
        }

        if ($sourceType -ceq 'tree') {
            New-Item -ItemType Directory -Force -Path $Destination | Out-Null
            $destinationCreated = $true
        }

        foreach ($relative in @($entries.Keys)) {
            $entry = $entries[$relative]
            $archiveEntryPath = [string]$entry.ArchivePath
            $matches = @($archiveFiles | Where-Object { $_.FullName -ceq $archiveEntryPath })
            if ($matches.Count -ne 1) {
                throw "Committed-copy expected exactly one archive file '$archiveEntryPath', found $($matches.Count)."
            }

            $target = if ($sourceType -ceq 'blob') { [IO.Path]::GetFullPath($Destination) } else { Get-SafeDestinationPath -Root $Destination -RelativePath ([string]$relative) }
            if (Test-Path -LiteralPath $target) { throw "Committed-copy materialization destination already exists: $target" }
            $parent = Split-Path -Parent $target
            if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

            $input = $matches[0].Open()
            $output = New-Object System.IO.FileStream($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $input.CopyTo($output)
                $output.Flush()
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }

            $actual = Get-LiteralBlobHash -RepoRoot $repoRoot -Path $target
            if ($actual -cne [string]$entry.Blob) {
                throw "Committed-copy exact-commit archive transport changed committed bytes for '$archiveEntryPath'. Expected $($entry.Blob), found $actual."
            }
            Restore-ExecutableMode -Destination $target -Mode ([string]$entry.Mode)
        }
    }
    finally {
        $archive.Dispose()
    }

    if ($sourceType -ceq 'tree') {
        $materializedFiles = @(Get-ChildItem -LiteralPath $Destination -File -Recurse -Force)
        if ($materializedFiles.Count -ne $entries.Count) {
            throw "Committed-copy materialized file count mismatch. Expected $($entries.Count), found $($materializedFiles.Count)."
        }
    }
}
catch {
    # Destination belongs to the caller's identity-guarded staging root. Never recursively delete
    # a caller pathname after failure because a non-cooperating process may have replaced it.
    throw
}
finally {
    if ($null -ne $transportOwned) {
        Remove-HmsOwnedTempDirectory -Owned $transportOwned -Label 'Committed-copy transport root'
    }
}

Write-Host "PASS: materialized exact committed Git blobs from HEAD $head through an isolated no-EOL archive transport with literal per-file blob verification: $pathSpec"
