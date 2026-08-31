[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$builderPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.ps1'
$modelPath = Join-Path $RepoRoot 'manager\HmsModelSettings.utf8.ps1'
$resolverPath = Join-Path $RepoRoot 'scripts\Resolve-HmsModelRoute.ps1'
$builderImplPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.impl.ps1'
$deliveryPath = Join-Path $RepoRoot 'scripts\Sync-DeliveryTools.ps1'
$uninstallPath = Join-Path $RepoRoot 'uninstall.ps1'
foreach ($path in @($builderPath,$modelPath,$resolverPath,$builderImplPath,$deliveryPath,$uninstallPath)) {
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

# Run the production UTF-8 implementation self-test directly so exact-handle sharing/read compatibility
# is qualified before the public lifecycle workflows. This uses only temp settings files.
& $modelPath -SelfTest
Write-Host 'PASS: direct Model Settings self-test is compatible with exact guarded reads/writes.'

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

# Permanent destructive primitive proof: a DELETE-capable directory handle opened without
# FILE_SHARE_DELETE must keep the exact validated root non-renamable by a foreign process.
if (-not ('HmsLateExactRootProbeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class HmsLateExactRootProbeNative
{
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr sa,uint creation,uint flags,IntPtr template);
}
'@
}
$probeRoot = Join-Path $env:TEMP ('hms-review34-root-lock-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
Set-Content -LiteralPath (Join-Path $probeRoot 'sentinel.txt') -Value 'owned' -Encoding UTF8
$probeHandle = [HmsLateExactRootProbeNative]::CreateFileW(
    $probeRoot,
    [uint32]0x00010000,
    [uint32]3,
    [IntPtr]::Zero,
    [uint32]3,
    [uint32]0x02200000,
    [IntPtr]::Zero
)
if ($null -eq $probeHandle -or $probeHandle.IsInvalid) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($null -ne $probeHandle) { $probeHandle.Dispose() }
    throw "Review34 exact-root probe could not open DELETE-capable directory handle (Win32=$code)."
}
$probeJob = $null
try {
    $probeJob = Start-Job -ScriptBlock {
        param($Path)
        try {
            Rename-Item -LiteralPath $Path -NewName ('foreign-' + [guid]::NewGuid().ToString('N')) -ErrorAction Stop
            return $true
        }
        catch { return $false }
    } -ArgumentList $probeRoot
    $null = Wait-Job -Job $probeJob -Timeout 20
    if ($probeJob.State -ne 'Completed') { throw 'Exact-root hostile rename probe did not complete.' }
    if ([bool](Receive-Job -Job $probeJob -ErrorAction Stop)) { throw 'Foreign process renamed a DELETE-guarded exact root.' }
}
finally {
    if ($null -ne $probeJob) { Remove-Job -Job $probeJob -Force -ErrorAction SilentlyContinue }
    $probeHandle.Dispose()
    Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: exact DELETE-capable directory guards deny hostile root rename through destructive transitions.'
Write-Host 'PASS: review34 exact-object resolver, rollback activation, delivery cleanup, and uninstall boundaries are permanently qualified.'
