[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ResolverPath = Join-Path $RepoRoot 'scripts\Resolve-HmsModelRoute.ps1'
$SettingsRoot = Join-Path $env:USERPROFILE '.codex\hms-composite'
$SettingsPath = Join-Path $SettingsRoot 'model-settings.json'

if (-not ('HmsModelSettingsNative' -as [type])) {
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
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileSizeEx(SafeFileHandle hFile, out long fileSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFilePointerEx(SafeFileHandle hFile, long distance, out long newPosition, uint moveMethod);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadFile(SafeFileHandle hFile, IntPtr buffer, uint bytesToRead, out uint bytesRead, IntPtr overlapped);

    public static SafeFileHandle OpenLockedModelSettingsFile(string path, out int error)
    {
        // GENERIC_READ | DELETE; share READ only. Existing content can be read by HMS, but no
        // cooperating or non-cooperating writer can mutate/rename/replace this exact object.
        SafeFileHandle h = CreateFileW(path, 0x80010000u, 0x00000001u, IntPtr.Zero, 3u, 0x00200000u, IntPtr.Zero);
        error = h.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        return h;
    }

    public static byte[] ReadAllHmsModelSettingsBytes(SafeFileHandle handle, out int error)
    {
        long size;
        if (!GetFileSizeEx(handle, out size)) { error = Marshal.GetLastWin32Error(); return null; }
        if (size < 0 || size > 1048576) { error = 223; return null; } // ERROR_FILE_TOO_LARGE / bounded settings contract.
        long position;
        if (!SetFilePointerEx(handle, 0, out position, 0)) { error = Marshal.GetLastWin32Error(); return null; }
        byte[] result = new byte[(int)size];
        if (size == 0) { error = 0; return result; }
        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            int offset = 0;
            while (offset < result.Length)
            {
                uint read;
                uint remaining = (uint)(result.Length - offset);
                if (!ReadFile(handle, IntPtr.Add(buffer, offset), remaining, out read, IntPtr.Zero))
                {
                    error = Marshal.GetLastWin32Error();
                    return null;
                }
                if (read == 0) { error = 38; return null; } // ERROR_HANDLE_EOF: exact bytes changed/truncated unexpectedly.
                offset += (int)read;
            }
            Marshal.Copy(buffer, result, 0, result.Length);
            error = 0;
            return result;
        }
        finally { Marshal.FreeHGlobal(buffer); }
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

function Read-HmsModelSettingsTextFromGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    if ($null -eq $Guard.Handle -or $Guard.Handle.IsClosed -or $Guard.Handle.IsInvalid) { throw "$Label exact settings guard is unavailable for read." }
    $identity = Get-HmsModelSettingsIdentityFromHandle -Handle $Guard.Handle -Label $Label
    if ($identity -cne [string]$Guard.Identity) { throw "$Label exact settings identity changed before guarded read." }
    $errorCode = 0
    $bytes = [HmsModelSettingsNative]::ReadAllHmsModelSettingsBytes($Guard.Handle,[ref]$errorCode)
    if ($null -eq $bytes) { throw "$Label exact settings bytes could not be read through the locked handle (Win32=$errorCode)." }
    $strict = New-Object System.Text.UTF8Encoding($false,$true)
    try { return $strict.GetString([byte[]]$bytes) }
    catch { throw "$Label exact settings bytes are not valid UTF-8: $($_.Exception.Message)" }
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

$ModelDefinitions = @(
    [pscustomobject]@{
        Key = 'luna'
        Name = 'GPT-5.6 Luna'
        Role = 'Low-risk deterministic and high-volume mechanical work'
        DescriptionVi = 'Việc cơ học, lặp lại, read-only/housekeeping hoặc chỉnh sửa rất hẹp; Luna chỉ chạy ở mức reasoning cao nhất runtime cho phép.'
    },
    [pscustomobject]@{
        Key = 'terra'
        Name = 'GPT-5.6 Terra'
        Role = 'Normal work, implementation, and ordinary debugging'
        DescriptionVi = 'Công việc phát triển bình thường; Terra medium cho việc thường, Terra high cho implementation/debug không tầm thường.'
    },
    [pscustomobject]@{
        Key = 'sol'
        Name = 'GPT-5.6 Sol'
        Role = 'Complex work, architecture/security/migration, critical and final gates'
        DescriptionVi = 'Công việc phức tạp; Sol high cho complex work, xhigh cho architecture/security/migration, max cho blocker/release/final review.'
    }
)

$RiskFloorMap = [ordered]@{
    'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL' = 'LUNA_LOW_RISK'
    'NORMAL_WORK' = 'TERRA_MEDIUM_OR_STRONGER'
    'MODERATE_DEBUG_OR_IMPLEMENTATION' = 'TERRA_HIGH_OR_STRONGER'
    'COMPLEX_WORK' = 'SOL_HIGH'
    'ARCHITECTURE_SECURITY_MIGRATION' = 'SOL_XHIGH'
    'CRITICAL_BLOCKER_RELEASE_GATE' = 'SOL_MAX'
    'FINAL_STAGE_REVIEW' = 'SOL_MAX_AND_INDEPENDENT_REVIEW'
}

function Assert-ResolverAvailable {
    if (-not (Test-Path -LiteralPath $ResolverPath)) { throw "Model resolver is missing: $ResolverPath" }
}

function New-DefaultModelState {
    return [ordered]@{ luna=$true; terra=$true; sol=$true }
}

function Assert-ExactSchemaVersionOne {
    param([Parameter(Mandatory)]$Value)
    $type = $Value.GetType()
    $isInteger = ($type -eq [int]) -or ($type -eq [long])
    if (-not $isInteger -or [long]$Value -ne 1) {
        throw "Unsupported model settings schema_version type/value: $($type.FullName) / $Value"
    }
}

function Assert-StateBooleans {
    param([Parameter(Mandatory)]$State)
    foreach ($key in @('luna','terra','sol')) {
        $value = $State[$key]
        if ($value -isnot [bool]) { throw "Model state '$key' must be boolean." }
    }
}

function Convert-StateToSettingsObject {
    param([Parameter(Mandatory)]$State)
    Assert-StateBooleans -State $State
    return [ordered]@{
        schema_version = 1
        managed_by = 'HMS-Skills-Codex'
        artifact = 'hms-model-settings'
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        models = [ordered]@{
            luna = $State.luna
            terra = $State.terra
            sol = $State.sol
        }
    }
}

function Assert-RegularSettingsFile {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Model settings path must be a regular file: $Path"
    }
}

function Convert-ModelSettingsTextToState {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Label)
    try { $settings = $Text | ConvertFrom-Json }
    catch { throw "$Label are invalid JSON: $($_.Exception.Message)" }
    if ($null -eq $settings.PSObject.Properties['schema_version']) { throw 'Model settings are missing schema_version.' }
    Assert-ExactSchemaVersionOne -Value $settings.schema_version
    if ([string]$settings.managed_by -cne 'HMS-Skills-Codex') { throw 'Model settings ownership mismatch.' }
    if ([string]$settings.artifact -cne 'hms-model-settings') { throw 'Model settings artifact mismatch.' }
    if ($null -eq $settings.models) { throw 'Model settings are missing models.' }
    $state = [ordered]@{}
    foreach ($key in @('luna','terra','sol')) {
        $property = $settings.models.PSObject.Properties[$key]
        if ($null -eq $property) { throw "Model settings are missing '$key'." }
        if ($property.Value -isnot [bool]) { throw "Model setting '$key' must be boolean." }
        $state[$key] = $property.Value
    }
    return $state
}

function Read-ModelStateFromGuard {
    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)
    $text = Read-HmsModelSettingsTextFromGuard -Guard $Guard -Label $Label
    return Convert-ModelSettingsTextToState -Text $text -Label $Label
}

function Read-ModelState-Unserialized {
    param([string]$Path = $SettingsPath)
    if (-not (Test-Path -LiteralPath $Path)) { return New-DefaultModelState }
    Assert-RegularSettingsFile -Path $Path
    try { $text = [IO.File]::ReadAllText($Path,(New-Object System.Text.UTF8Encoding($false,$true))) }
    catch { throw "Model settings could not be read: $($_.Exception.Message)" }
    return Convert-ModelSettingsTextToState -Text $text -Label 'Model settings'
}

function Read-ModelState {
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

function Write-ModelState {
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
            $null = Read-ModelStateFromGuard -Guard $existingGuard -Label 'Existing model settings'
            $hadExisting = $true
        }

        [IO.File]::WriteAllText($temp,$json,$utf8)
        $candidateGuard = Open-HmsModelSettingsFileGuard -Path $temp -Label 'Candidate model settings'
        $actualCandidateText = Read-HmsModelSettingsTextFromGuard -Guard $candidateGuard -Label 'Candidate model settings'
        if ($actualCandidateText -cne $json) { throw 'Candidate model settings bytes changed before publication.' }
        $null = Read-ModelStateFromGuard -Guard $candidateGuard -Label 'Candidate model settings'

        if ($hadExisting) {
            Move-HmsModelSettingsFileGuard -Guard $existingGuard -SourcePath $Path -DestinationPath $previousReserved -Label 'Previous model settings reservation'
            $previousMoved = $true
        }

        Move-HmsModelSettingsFileGuard -Guard $candidateGuard -SourcePath $temp -DestinationPath $Path -Label 'Candidate model settings publication'
        $candidatePublished = $true

        $verified = Read-ModelStateFromGuard -Guard $candidateGuard -Label 'Published candidate model settings'
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
                $null = Read-ModelStateFromGuard -Guard $existingGuard -Label 'Restored previous model settings'
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

function Resolve-Route {
    param(
        [Parameter(Mandatory)][string]$RiskClass,
        [Parameter(Mandatory)][string]$RequiredFloor,
        [string]$Path = $SettingsPath
    )
    Assert-ResolverAvailable
    return & $ResolverPath -RiskClass $RiskClass -RequiredFloor $RequiredFloor -SettingsPath $Path
}

function Invoke-ModelSettingsSelfTest {
    Assert-ResolverAvailable

    foreach ($definition in $ModelDefinitions) {
        if ([string]::IsNullOrWhiteSpace($definition.DescriptionVi)) { throw "Missing Vietnamese description for model '$($definition.Key)'." }
    }

    $root = Join-Path ([IO.Path]::GetTempPath()) ('hms-model-settings-' + [guid]::NewGuid().ToString('N'))
    $path = Join-Path $root 'model-settings.json'
    try {
        New-Item -ItemType Directory -Force -Path $root | Out-Null

        $allOn = [ordered]@{ luna=$true; terra=$true; sol=$true }
        Write-ModelState -State $allOn -Path $path
        $normal = Resolve-Route -RiskClass 'NORMAL_WORK' -RequiredFloor 'TERRA_MEDIUM_OR_STRONGER' -Path $path
        if ($normal.status -cne 'ASSIGNED' -or $normal.assigned_model -cne 'gpt-5.6-terra' -or [bool]$normal.reassigned) {
            throw 'All-ON routing did not assign NORMAL_WORK to Terra.'
        }

        $lunaOff = [ordered]@{ luna=$false; terra=$true; sol=$true }
        Write-ModelState -State $lunaOff -Path $path
        $fast = Resolve-Route -RiskClass 'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL' -RequiredFloor 'LUNA_LOW_RISK' -Path $path
        if ($fast.status -cne 'ASSIGNED' -or $fast.assigned_model -cne 'gpt-5.6-terra' -or -not [bool]$fast.reassigned) {
            throw 'Luna-OFF routing did not safely reassign low-risk work to Terra.'
        }

        $terraOff = [ordered]@{ luna=$true; terra=$false; sol=$true }
        Write-ModelState -State $terraOff -Path $path
        $moderate = Resolve-Route -RiskClass 'MODERATE_DEBUG_OR_IMPLEMENTATION' -RequiredFloor 'TERRA_HIGH_OR_STRONGER' -Path $path
        if ($moderate.status -cne 'ASSIGNED' -or $moderate.assigned_model -cne 'gpt-5.6-sol' -or -not [bool]$moderate.reassigned) {
            throw 'Terra-OFF routing did not safely reassign moderate work to Sol.'
        }

        $solOff = [ordered]@{ luna=$true; terra=$true; sol=$false }
        Write-ModelState -State $solOff -Path $path
        $architecture = Resolve-Route -RiskClass 'ARCHITECTURE_SECURITY_MIGRATION' -RequiredFloor 'SOL_XHIGH' -Path $path
        if ($architecture.status -cne 'BLOCKED' -or $architecture.reason -cne 'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR') {
            throw 'Sol-OFF routing did not fail closed for Sol-required architecture work.'
        }

        # Prove a higher-authority floor is consumed directly rather than recomputed
        # from the NORMAL_WORK label.
        $raisedFloor = Resolve-Route -RiskClass 'NORMAL_WORK' -RequiredFloor 'SOL_XHIGH' -Path $path
        if ($raisedFloor.status -cne 'BLOCKED' -or $raisedFloor.required_floor -cne 'SOL_XHIGH') {
            throw 'Raised required floor was not preserved by the dispatcher.'
        }

        $loweredRejected = $false
        try {
            $null = Resolve-Route -RiskClass 'ARCHITECTURE_SECURITY_MIGRATION' -RequiredFloor 'TERRA_HIGH_OR_STRONGER' -Path $path
        }
        catch {
            if ($_.Exception.Message -match 'below risk-class minimum') { $loweredRejected = $true } else { throw }
        }
        if (-not $loweredRejected) { throw 'Dispatcher accepted a required floor below the risk-class minimum.' }

        $allOff = [ordered]@{ luna=$false; terra=$false; sol=$false }
        Write-ModelState -State $allOff -Path $path
        $blocked = Resolve-Route -RiskClass 'NORMAL_WORK' -RequiredFloor 'TERRA_MEDIUM_OR_STRONGER' -Path $path
        if ($blocked.status -cne 'BLOCKED' -or $blocked.reason -cne 'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR') {
            throw 'All-OFF routing did not block model-routed work.'
        }

        # Strict JSON typing: values that merely coerce to schema 1 or boolean must fail.
        Remove-Item -LiteralPath $path -Force
        [IO.File]::WriteAllText($path, '{"schema_version":true,"managed_by":"HMS-Skills-Codex","artifact":"hms-model-settings","models":{"luna":true,"terra":true,"sol":true}}', (New-Object System.Text.UTF8Encoding($false)))
        $schemaRejected = $false
        try { $null = Read-ModelState -Path $path } catch { if ($_.Exception.Message -match 'schema_version') { $schemaRejected = $true } else { throw } }
        if (-not $schemaRejected) { throw 'Boolean schema_version was incorrectly accepted as schema version 1.' }

        Remove-Item -LiteralPath $path -Force
        [IO.File]::WriteAllText($path, '{"schema_version":1,"managed_by":"HMS-Skills-Codex","artifact":"hms-model-settings","models":{"luna":"false","terra":true,"sol":true}}', (New-Object System.Text.UTF8Encoding($false)))
        $booleanRejected = $false
        try { $null = Read-ModelState -Path $path } catch { if ($_.Exception.Message -match 'must be boolean') { $booleanRejected = $true } else { throw } }
        if (-not $booleanRejected) { throw 'String model toggle was incorrectly accepted as boolean.' }

        Write-Host 'PASS: HMS Model Settings verified atomic persistence, strict schema typing, direct required-floor dispatch, Luna->Terra fallback, Terra->Sol fallback, and fail-closed Sol-required routing.'
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

if ($SelfTest) {
    Invoke-ModelSettingsSelfTest
    return
}

if ($env:OS -ne 'Windows_NT') { throw 'HMS Model Settings UI is supported on Windows only.' }
Assert-ResolverAvailable

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HMS Model Settings'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(760, 570)
$form.MinimumSize = New-Object System.Drawing.Size(776, 609)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'HMS Model Settings'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.Location = New-Object System.Drawing.Point(26, 20)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Choose which GPT-5.6 models may receive HMS task slices.'
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(29, 61)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

$fallback = New-Object System.Windows.Forms.Label
$fallback.Text = 'Fallback: Luna OFF -> Terra -> Sol | Terra OFF -> Sol | Sol-required work with Sol OFF -> BLOCKED'
$fallback.ForeColor = [System.Drawing.Color]::FromArgb(90, 60, 20)
$fallback.Location = New-Object System.Drawing.Point(29, 86)
$fallback.AutoSize = $true
$form.Controls.Add($fallback)

$checks = @{}
$top = 122
foreach ($model in $ModelDefinitions) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(28, $top)
    $panel.Size = New-Object System.Drawing.Size(704, 102)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'

    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $model.Name
    $check.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $check.Location = New-Object System.Drawing.Point(16, 10)
    $check.AutoSize = $true
    $panel.Controls.Add($check)

    $role = New-Object System.Windows.Forms.Label
    $role.Text = $model.Role
    $role.ForeColor = [System.Drawing.Color]::DimGray
    $role.Location = New-Object System.Drawing.Point(38, 39)
    $role.AutoSize = $true
    $panel.Controls.Add($role)

    $vi = New-Object System.Windows.Forms.Label
    $vi.Text = 'Tiếng Việt: ' + $model.DescriptionVi
    $vi.ForeColor = [System.Drawing.Color]::FromArgb(50, 70, 95)
    $vi.Location = New-Object System.Drawing.Point(38, 63)
    $vi.MaximumSize = New-Object System.Drawing.Size(640, 0)
    $vi.AutoSize = $true
    $panel.Controls.Add($vi)

    $form.Controls.Add($panel)
    $checks[$model.Key] = $check
    $top += 112
}

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(30, 465)
$status.Size = New-Object System.Drawing.Size(700, 30)
$status.ForeColor = [System.Drawing.Color]::FromArgb(30, 100, 60)
$form.Controls.Add($status)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Save'
$saveButton.Size = New-Object System.Drawing.Size(105, 42)
$saveButton.Location = New-Object System.Drawing.Point(28, 510)
$form.Controls.Add($saveButton)

$allOnButton = New-Object System.Windows.Forms.Button
$allOnButton.Text = 'Enable All'
$allOnButton.Size = New-Object System.Drawing.Size(115, 42)
$allOnButton.Location = New-Object System.Drawing.Point(143, 510)
$form.Controls.Add($allOnButton)

$allOffButton = New-Object System.Windows.Forms.Button
$allOffButton.Text = 'Disable All'
$allOffButton.Size = New-Object System.Drawing.Size(115, 42)
$allOffButton.Location = New-Object System.Drawing.Point(268, 510)
$form.Controls.Add($allOffButton)

$testButton = New-Object System.Windows.Forms.Button
$testButton.Text = 'Test Routing'
$testButton.Size = New-Object System.Drawing.Size(130, 42)
$testButton.Location = New-Object System.Drawing.Point(393, 510)
$form.Controls.Add($testButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Size = New-Object System.Drawing.Size(199, 42)
$closeButton.Location = New-Object System.Drawing.Point(533, 510)
$form.Controls.Add($closeButton)

function Show-ModelError {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, 'HMS Model Settings', 'OK', 'Error') | Out-Null
}

function Read-UiState {
    return [ordered]@{
        luna = [bool]$checks['luna'].Checked
        terra = [bool]$checks['terra'].Checked
        sol = [bool]$checks['sol'].Checked
    }
}

function Refresh-UiState {
    $state = Read-ModelState
    foreach ($key in @('luna','terra','sol')) { $checks[$key].Checked = $state[$key] }
    $enabled = @($state.Keys | Where-Object { $state[$_] })
    if ($enabled.Count -eq 0) {
        $status.Text = 'Model pool: OFF - no model can receive routed HMS work.'
        $status.ForeColor = [System.Drawing.Color]::DarkRed
    }
    else {
        $status.Text = 'Model pool: ON - enabled: ' + ($enabled -join ', ')
        $status.ForeColor = [System.Drawing.Color]::FromArgb(30, 100, 60)
    }
}

function Save-UiState {
    $state = Read-UiState
    Write-ModelState -State $state
    Refresh-UiState
}

$saveButton.Add_Click({
    try { Save-UiState }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$allOnButton.Add_Click({
    try {
        foreach ($key in @('luna','terra','sol')) { $checks[$key].Checked = $true }
        Save-UiState
    }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$allOffButton.Add_Click({
    try {
        foreach ($key in @('luna','terra','sol')) { $checks[$key].Checked = $false }
        Save-UiState
    }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$testButton.Add_Click({
    try {
        Save-UiState
        $lines = @()
        foreach ($class in @($RiskFloorMap.Keys)) {
            $route = Resolve-Route -RiskClass $class -RequiredFloor ([string]$RiskFloorMap[$class])
            if ($route.status -ceq 'ASSIGNED') {
                $lines += ($class + ' -> ' + $route.assigned_model + ' / ' + $route.effort)
            }
            else {
                $lines += ($class + ' -> BLOCKED (' + $route.required_floor + ')')
            }
        }
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'HMS Model Routing Test', 'OK', 'Information') | Out-Null
    }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$closeButton.Add_Click({ $form.Close() })
Refresh-UiState
[void]$form.ShowDialog()
