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
foreach($literal in @('HmsDeliveryExactFsNative','Invoke-HmsDeliveryExactDirectoryRemoval','reservedBackupGuard','Move-HmsDeliveryDirectoryGuard -Guard $reservedBackupGuard -Destination $CurrentPath','GetFileInformationByHandleEx','EnumerateChildrenByHandle','Remove-HmsDeliveryExactChildren','Open-HmsDeliveryFileGuard','Move-HmsDeliveryFileGuard','Publish-CodeGraphInstallManifest','ExpectedPreviousIdentity')){if($deliveryText-notmatch[regex]::Escape($literal)){throw "Delivery tools are missing exact-object contract: $literal"}}
$uninstallText=[IO.File]::ReadAllText($uninstallPath)
foreach($literal in @('HmsUninstallExactFsNative','Invoke-HmsUninstallExactDirectoryRemoval','DeleteByHandle','GetFileInformationByHandleEx','EnumerateChildrenByHandle','Remove-HmsUninstallExactChildren')){if($uninstallText-notmatch[regex]::Escape($literal)){throw "Uninstall is missing exact-object cleanup contract: $literal"}}
foreach($bad in @('Remove-Item -LiteralPath $quarantine -Recurse -Force','Remove-Item -LiteralPath $q -Recurse -Force')){if($deliveryText-match[regex]::Escape($bad)){throw "Delivery exact cleanup reverted to root-path recursive deletion: $bad"}}
foreach($entry in @([pscustomobject]@{Name='delivery';Text=$deliveryText;Forbidden='foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) { Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop }'},[pscustomobject]@{Name='uninstall';Text=$uninstallText;Forbidden='foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) { Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop }'},[pscustomobject]@{Name='builder';Text=$builderText;Forbidden='Remove-Item -LiteralPath $child.FullName -Recurse'})){if($entry.Text-match[regex]::Escape([string]$entry.Forbidden)){throw "$($entry.Name) exact Windows cleanup still recursively deletes mutable child pathnames."}}

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

# Fresh-review regression: hostile occupancy during marker/manifest canonical gaps must be preserved, never overwritten.
. $deliveryPath -SkipCodeGraph -SkipThreeLevelDelivery
$raceRoot=Join-Path $env:TEMP ('hms-codegraph-exact-file-race-'+[guid]::NewGuid().ToString('N'))
$markerBundle=Join-Path $raceRoot 'bundle';$markerProbe=Join-Path $raceRoot 'marker-probe.txt';$manifestProbe=Join-Path $raceRoot 'manifest-probe.txt'
$markerJob=$null;$manifestJob=$null;$manifestState=$null
try{
    New-Item -ItemType Directory -Force -Path $markerBundle | Out-Null
    [IO.File]::WriteAllText((Join-Path $markerBundle 'payload.txt'),'payload',(New-Object Text.UTF8Encoding($false)))
    $tree=Get-CodeGraphBundleTreeSha256 -Path $markerBundle
    $old=New-CodeGraphBundleIdentity -TransactionId ('1'*32) -Role 'candidate' -Version 'old' -Tag 'v-old' -Commit 'old' -Asset 'old.zip' -Sha256 ('a'*64) -BundleTreeSha256 $tree
    $new=New-CodeGraphBundleIdentity -TransactionId ('2'*32) -Role 'backup' -Version 'old' -Tag 'v-old' -Commit 'old' -Asset 'old.zip' -Sha256 ('a'*64) -BundleTreeSha256 $tree
    Write-CodeGraphBundleMarker -Path $markerBundle -Identity $old
    $env:HMS_TEST_CODEGRAPH_MARKER_RESERVED_READY=$markerProbe
    $markerJob=Start-Job -ScriptBlock {param($Probe)while(-not(Test-Path -LiteralPath $Probe)){Start-Sleep -Milliseconds 40};$p=[IO.File]::ReadAllText($Probe);[IO.File]::WriteAllText($p,'FOREIGN-MARKER-MUST-SURVIVE',(New-Object Text.UTF8Encoding($false)))} -ArgumentList $markerProbe
    $markerRejected=$false
    try{Write-CodeGraphBundleMarker -Path $markerBundle -Identity $new -ExpectedPreviousIdentity $old}catch{if($_.Exception.Message -match 'destination is occupied|rollback was incomplete'){$markerRejected=$true}else{throw}}
    $null=Wait-Job -Job $markerJob -Timeout 20;Receive-Job -Job $markerJob -ErrorAction Stop|Out-Null
    if(-not$markerRejected){throw 'Marker publication did not fail closed when canonical pathname was occupied during exact reservation.'}
    if([IO.File]::ReadAllText((Join-Path $markerBundle $CodeGraphBundleMarkerName)) -cne 'FOREIGN-MARKER-MUST-SURVIVE'){throw 'Marker publication overwrote/deleted hostile canonical replacement.'}

    $CodeGraphRoot=Join-Path $raceRoot 'codegraph';New-Item -ItemType Directory -Force -Path $CodeGraphRoot|Out-Null;$CodeGraphManifest=Join-Path $CodeGraphRoot 'hms-codegraph-install.json'
    $previous=[ordered]@{managed_by=$ManagedBy;version='old';tag='v-old';commit='old';asset='old.zip';sha256=('b'*64);bundle_transaction_id=('3'*32);bundle_tree_sha256=('c'*64)}
    [IO.File]::WriteAllText($CodeGraphManifest,(($previous|ConvertTo-Json)+"`n"),(New-Object Text.UTF8Encoding($false)))
    $manifestState=Open-ManagedCodeGraphManifestState
    $candidate=[ordered]@{managed_by=$ManagedBy;version='new';tag='v-new';commit='new';asset='new.zip';sha256=('d'*64);bundle_transaction_id=('4'*32);bundle_tree_sha256=('e'*64)}
    $env:HMS_TEST_CODEGRAPH_MANIFEST_RESERVED_READY=$manifestProbe
    $manifestJob=Start-Job -ScriptBlock {param($Probe)while(-not(Test-Path -LiteralPath $Probe)){Start-Sleep -Milliseconds 40};$p=[IO.File]::ReadAllText($Probe);[IO.File]::WriteAllText($p,'FOREIGN-MANIFEST-MUST-SURVIVE',(New-Object Text.UTF8Encoding($false)))} -ArgumentList $manifestProbe
    $manifestRejected=$false
    try{$g=Publish-CodeGraphInstallManifest -Manifest $candidate -ExistingState $manifestState;if($null-ne$g){$g.Handle.Dispose()}}catch{if($_.Exception.Message -match 'destination is occupied|rollback was incomplete'){$manifestRejected=$true}else{throw}}
    $null=Wait-Job -Job $manifestJob -Timeout 20;Receive-Job -Job $manifestJob -ErrorAction Stop|Out-Null
    if(-not$manifestRejected){throw 'Manifest publication did not fail closed when canonical pathname was occupied during exact reservation.'}
    if([IO.File]::ReadAllText($CodeGraphManifest) -cne 'FOREIGN-MANIFEST-MUST-SURVIVE'){throw 'Manifest publication overwrote/deleted hostile canonical replacement.'}
}
finally{
    foreach($n in @('HMS_TEST_CODEGRAPH_MARKER_RESERVED_READY','HMS_TEST_CODEGRAPH_MANIFEST_RESERVED_READY')){Remove-Item -LiteralPath "Env:\$n" -ErrorAction SilentlyContinue}
    foreach($j in @($markerJob,$manifestJob)){if($null-ne$j){Remove-Job -Job $j -Force -ErrorAction SilentlyContinue}}
    if($null-ne$manifestState -and $null-ne$manifestState.Guard -and $null-ne$manifestState.Guard.Handle){$manifestState.Guard.Handle.Dispose()}
    if(Test-Path -LiteralPath $raceRoot){Remove-Item -LiteralPath $raceRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
Write-Host 'PASS: exact marker/manifest publication preserves hostile canonical replacements and fails closed.'
