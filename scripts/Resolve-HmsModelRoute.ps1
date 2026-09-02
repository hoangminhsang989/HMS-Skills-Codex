[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL',
        'NORMAL_WORK',
        'MODERATE_DEBUG_OR_IMPLEMENTATION',
        'COMPLEX_WORK',
        'ARCHITECTURE_SECURITY_MIGRATION',
        'CRITICAL_BLOCKER_RELEASE_GATE',
        'FINAL_STAGE_REVIEW'
    )]
    [string]$RiskClass,

    [Parameter(Mandatory)]
    [ValidateSet(
        'LUNA_LOW_RISK',
        'TERRA_MEDIUM_OR_STRONGER',
        'TERRA_HIGH_OR_STRONGER',
        'SOL_HIGH',
        'SOL_XHIGH',
        'SOL_MAX',
        'SOL_MAX_AND_INDEPENDENT_REVIEW'
    )]
    [string]$RequiredFloor,

    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.codex\hms-composite\model-settings.json'),

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('HmsModelRouteNative' -as [type])) {
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

function Get-DefaultSettings {
    return [pscustomobject]@{
        schema_version = 1
        managed_by = 'HMS-Skills-Codex'
        artifact = 'hms-model-settings'
        models = [pscustomobject]@{
            luna = $true
            terra = $true
            sol = $true
        }
    }
}

function Assert-ExactSchemaVersionOne {
    param([Parameter(Mandatory)]$Value)
    $type = $Value.GetType()
    $isInteger = ($type -eq [int]) -or ($type -eq [long])
    if (-not $isInteger -or [long]$Value -ne 1) {
        throw "Unsupported model settings schema_version type/value: $($type.FullName) / $Value"
    }
}

function Read-Settings {
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
}


$floorRank = @{
    'LUNA_LOW_RISK' = 1
    'TERRA_MEDIUM_OR_STRONGER' = 2
    'TERRA_HIGH_OR_STRONGER' = 3
    'SOL_HIGH' = 4
    'SOL_XHIGH' = 5
    'SOL_MAX' = 6
    'SOL_MAX_AND_INDEPENDENT_REVIEW' = 6
}

$riskMinimumFloor = @{
    'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL' = 'LUNA_LOW_RISK'
    'NORMAL_WORK' = 'TERRA_MEDIUM_OR_STRONGER'
    'MODERATE_DEBUG_OR_IMPLEMENTATION' = 'TERRA_HIGH_OR_STRONGER'
    'COMPLEX_WORK' = 'SOL_HIGH'
    'ARCHITECTURE_SECURITY_MIGRATION' = 'SOL_XHIGH'
    'CRITICAL_BLOCKER_RELEASE_GATE' = 'SOL_MAX'
    'FINAL_STAGE_REVIEW' = 'SOL_MAX_AND_INDEPENDENT_REVIEW'
}

$minimumFloor = [string]$riskMinimumFloor[$RiskClass]
if ([int]$floorRank[$RequiredFloor] -lt [int]$floorRank[$minimumFloor]) {
    throw "Required model floor '$RequiredFloor' is below risk-class minimum '$minimumFloor' for '$RiskClass'."
}
if ($RiskClass -ceq 'FINAL_STAGE_REVIEW' -and $RequiredFloor -cne 'SOL_MAX_AND_INDEPENDENT_REVIEW') {
    throw 'FINAL_STAGE_REVIEW requires SOL_MAX_AND_INDEPENDENT_REVIEW so the reviewer-independence requirement cannot be erased.'
}

$floorTable = @{
    'LUNA_LOW_RISK' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-luna'
        Candidates = @(
            [pscustomobject]@{ Key='luna'; Model='gpt-5.6-luna'; Effort='maximum-available-for-luna' },
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='medium' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'TERRA_MEDIUM_OR_STRONGER' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-terra'
        Candidates = @(
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='medium' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'TERRA_HIGH_OR_STRONGER' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-terra'
        Candidates = @(
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='high' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'SOL_HIGH' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' })
    }
    'SOL_XHIGH' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='xhigh' })
    }
    'SOL_MAX' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='max' })
    }
    'SOL_MAX_AND_INDEPENDENT_REVIEW' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='max' })
    }
}

$settingsMutexName = 'Local\HMS-Skills-Codex-ModelSettings-v1'
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
$route = $floorTable[$RequiredFloor]
$enabled = @()
foreach ($name in @('luna','terra','sol')) {
    if ($settings.models.$name -isnot [bool]) { throw "Model setting '$name' must be boolean." }
    if ($settings.models.$name) { $enabled += $name }
}

$assignment = $null
foreach ($candidate in @($route.Candidates)) {
    if ($settings.models.($candidate.Key)) {
        $assignment = $candidate
        break
    }
}

if ($null -eq $assignment) {
    $result = [pscustomobject]@{
        status = 'BLOCKED'
        reason = 'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR'
        risk_class = $RiskClass
        risk_minimum_floor = $minimumFloor
        required_floor = $RequiredFloor
        preferred_model = $route.PreferredModel
        assigned_model = $null
        effort = $null
        reassigned = $false
        enabled_models = $enabled
        settings_path = $SettingsPath
    }
}
else {
    $result = [pscustomobject]@{
        status = 'ASSIGNED'
        reason = if ($assignment.Model -ceq $route.PreferredModel) { 'PREFERRED_MODEL_ENABLED' } else { 'PREFERRED_MODEL_DISABLED_REASSIGNED_TO_STRONGER_ENABLED_MODEL' }
        risk_class = $RiskClass
        risk_minimum_floor = $minimumFloor
        required_floor = $RequiredFloor
        preferred_model = $route.PreferredModel
        assigned_model = $assignment.Model
        effort = $assignment.Effort
        reassigned = [bool]($assignment.Model -cne $route.PreferredModel)
        enabled_models = $enabled
        settings_path = $SettingsPath
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
}
else {
    $result
}
