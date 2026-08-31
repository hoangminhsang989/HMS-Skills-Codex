[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    Write-Host 'SKIP: exact-handle owned-temp cleanup regression is Windows-specific.'
    return
}

foreach ($relative in @('scripts\Build-HmsCompositeSkill.ps1','scripts\Copy-HmsCommittedGitPath.ps1')) {
    $path = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Owned-temp regression source is missing: $relative" }
    $text = [IO.File]::ReadAllText($path)
    foreach ($literal in @(
        'function Get-HmsOwnedDirectoryIdentityFromHandle',
        'function Open-HmsOwnedDirectoryIdentityHandle',
        'function New-HmsOwnedTempDirectory',
        'function Remove-HmsOwnedTempDirectory',
        'SetFileInformationByHandle',
        'RenameHmsOwnedDirectoryByHandle',
        'DeleteHmsOwnedDirectoryByHandle',
        'Open-HmsOwnedDirectoryIdentityHandle -Path $path -ShareMode ([uint32]3)',
        '[uint32]0x00010000',
        'minimumStructSize = IntPtr.Size == 8 ? 24 : 16',
        'nameOffset + nameBytes.Length + 2',
        "'.hms-owned-temp-quarantine-'",
        "'.hms-owned-temp-identity'"
    )) {
        if ($text -notmatch [regex]::Escape($literal)) { throw "$relative is missing exact-handle owned-temp contract: $literal" }
    }
    if ($text -match [regex]::Escape('int size = nameOffset + nameBytes.Length;')) {
        throw "$relative retained the unterminated FILE_RENAME_INFO allocation."
    }
    if ($text -match [regex]::Escape('During active use ShareMode excludes FILE_SHARE_DELETE')) {
        throw "$relative still claims share-mode exclusion is the cleanup authority."
    }
    if ($text -match [regex]::Escape('Remove-Item -LiteralPath $transportRoot -Recurse -Force -ErrorAction SilentlyContinue')) {
        throw "$relative still recursively deletes a transport pathname without identity binding."
    }
}

# Execute the exact production helper prelude from the public builder in isolation.
$builderPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.ps1'
$source = [IO.File]::ReadAllText($builderPath)
$start = $source.IndexOf("if (-not ('HmsOwnedTempNative' -as [type])) {")
$endMarker = "`n`n`n`$selfRelative = 'scripts/Build-HmsCompositeSkill.ps1'"
$end = $source.IndexOf($endMarker,$start)
if ($start -lt 0 -or $end -lt 0) { throw 'Could not isolate production owned-temp helper prelude.' }
$helperPath = Join-Path $env:TEMP ('hms-owned-temp-helper-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($helperPath,$source.Substring($start,$end-$start),(New-Object Text.UTF8Encoding($false)))
. $helperPath

# Case A: the durable root handle denies FILE_SHARE_DELETE for the entire active lifetime.
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

$removeFunction = [regex]::Match($source,'(?s)function Remove-HmsOwnedTempDirectory \{.*?\n\}\n\n\n\$selfRelative').Value
if ([string]::IsNullOrWhiteSpace($removeFunction)) { throw 'Could not isolate owned-temp removal function for destructive-order proof.' }
$deletePos = $removeFunction.IndexOf('DeleteHmsOwnedDirectoryByHandle')
$disposePos = $removeFunction.IndexOf('$Owned.Guard.Dispose()')
$rootRemovePos = $removeFunction.IndexOf('Remove-Item -LiteralPath $quarantine -Recurse -Force')
if ($deletePos -lt 0 -or $disposePos -lt 0 -or $deletePos -ge $disposePos) { throw 'Owned-temp exact handle is not retained through the root delete-pending transition.' }
$windowsReturnPos = $removeFunction.IndexOf('        return',$disposePos)
if ($windowsReturnPos -lt 0) { throw 'Windows owned-temp exact-handle branch has no terminal return before the non-Windows fallback.' }
if ($rootRemovePos -ge 0 -and $rootRemovePos -lt $windowsReturnPos) { throw 'Windows owned-temp cleanup still contains pathname-recursive root deletion before its exact-handle return.' }
Write-Host 'PASS: exact-object guard remains live until the directory handle enters delete-pending state.'

# Case B: loss of exact-object authority must fail closed rather than fall back to pathname deletion.
$ownedB = New-HmsOwnedTempDirectory -Prefix 'hms-owned-temp-lost-handle-' -Label 'lost-handle regression'
$originalB = [string]$ownedB.Path
$movedB = $originalB + '-owned-original'
$sentinelB = Join-Path $originalB 'FOREIGN-PRESERVE.txt'
try {
    $ownedB.Guard.Dispose(); $ownedB.Guard=$null
    Rename-Item -LiteralPath $originalB -NewName (Split-Path -Leaf $movedB) -ErrorAction Stop
    New-Item -ItemType Directory -Path $originalB -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText($sentinelB,'foreign replacement must survive',(New-Object Text.UTF8Encoding($false)))
    $rejected = $false
    try { Remove-HmsOwnedTempDirectory -Owned $ownedB -Label 'lost-handle regression' }
    catch {
        if ($_.Exception.Message -match 'exact-object cleanup handle is unavailable') { $rejected = $true }
        else { throw }
    }
    if (-not $rejected) { throw 'Cleanup fell back to pathname authority after exact handle loss.' }
    if (-not (Test-Path -LiteralPath $sentinelB -PathType Leaf)) { throw 'Lost-handle cleanup deleted the foreign replacement.' }
    if (-not (Test-Path -LiteralPath $movedB -PathType Container)) { throw 'Original exact owned directory disappeared after cleanup correctly failed closed.' }
}
finally {
    foreach ($p in @($originalB,$movedB,$helperPath)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
}
Write-Host 'PASS: exact-handle loss fails closed without pathname deletion fallback.'
Write-Host 'PASS: permanent owned-temp cleanup regression qualified exact-object deletion, foreign replacement preservation, and fail-closed handle loss.'
