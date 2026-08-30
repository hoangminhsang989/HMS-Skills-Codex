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
$endMarker = "`n`n`n`$repoRoot = Split-Path -Parent `$PSScriptRoot"
$end = $source.IndexOf($endMarker,$start)
if ($start -lt 0 -or $end -lt 0) { throw 'Could not isolate production owned-temp helper prelude.' }
$helperPath = Join-Path $env:TEMP ('hms-owned-temp-helper-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($helperPath,$source.Substring($start,$end-$start),(New-Object Text.UTF8Encoding($false)))
. $helperPath

# Case A: a non-cooperating process renames the exact object and puts foreign data at the old pathname.
# Cleanup must follow the exact live handle, delete only the original object, and preserve the replacement.
$ownedA = New-HmsOwnedTempDirectory -Prefix 'hms-owned-temp-active-' -Label 'exact-handle regression'
$originalA = [string]$ownedA.Path
$movedA = $originalA + '-moved-by-foreign-process'
$foreignSentinelA = Join-Path $originalA 'FOREIGN-PRESERVE.txt'
$jobA = $null
try {
    if ($ownedA.Guard.IsClosed -or $ownedA.Guard.IsInvalid) { throw 'Production exact-object handle is not live before race.' }
    $jobA = Start-Job -ScriptBlock {
        param($Original,$Moved)
        $ErrorActionPreference='Stop'
        try {
            Rename-Item -LiteralPath $Original -NewName (Split-Path -Leaf $Moved) -ErrorAction Stop
            [pscustomobject]@{ Renamed=$true; Error='' }
        }
        catch {
            [pscustomobject]@{ Renamed=$false; Error=$_.Exception.Message }
        }
    } -ArgumentList $originalA,$movedA
    $null = Wait-Job -Job $jobA -Timeout 20
    if ($jobA.State -ne 'Completed') { throw "Cross-process rename probe did not complete. State=$($jobA.State)" }
    $probeA = Receive-Job -Job $jobA -ErrorAction Stop
    if (-not [bool]$probeA.Renamed) { throw "Threat-model setup could not rename the owned root from a separate process: $($probeA.Error)" }
    if (Test-Path -LiteralPath $originalA) { throw 'Original pathname unexpectedly remained occupied after hostile rename setup.' }
    if (-not (Test-Path -LiteralPath $movedA -PathType Container)) { throw 'Hostile rename setup lost the exact owned directory.' }

    New-Item -ItemType Directory -Path $originalA -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText($foreignSentinelA,'foreign replacement must survive',(New-Object Text.UTF8Encoding($false)))

    Remove-HmsOwnedTempDirectory -Owned $ownedA -Label 'exact-handle regression'
    if (-not (Test-Path -LiteralPath $foreignSentinelA -PathType Leaf)) { throw 'Exact-handle cleanup deleted the foreign replacement at the original pathname.' }
    if (Test-Path -LiteralPath $movedA) { throw 'Exact owned object remained at its adversarially moved pathname after cleanup.' }
    $leftA = @(Get-ChildItem -LiteralPath (Split-Path -Parent $originalA) -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.hms-owned-temp-quarantine-*' })
    if ($leftA.Count -ne 0) { throw 'Exact-handle cleanup left quarantine residue.' }
}
finally {
    if ($null -ne $jobA) { Remove-Job -Job $jobA -Force -ErrorAction SilentlyContinue }
    if ($null -ne $ownedA.Guard) { $ownedA.Guard.Dispose(); $ownedA.Guard=$null }
    foreach ($p in @($originalA,$movedA)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
}
Write-Host 'PASS: exact-handle cleanup deleted the exact original object and preserved a foreign original-path replacement.'

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
