from pathlib import Path
import subprocess

repo = Path.cwd()


def replace_once(path, old, new, label):
    p = repo / path
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one occurrence, found {count}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8", newline="\n")


expected = {
    "scripts/Sync-DeliveryTools.ps1": "2ff59aaba1867bceb7827a0e6e42f17993606e24",
    "scripts/Build-HmsCompositeSkill.impl.ps1": "b2778cdfe7219ce1d16c9ae8dc48179a56c3d232",
    "scripts/Test-HmsSkills.ps1": "5af65c7e4ca24f18b636b28b10e1c76239c0e5e2",
}
for path, sha in expected.items():
    actual = subprocess.check_output(["git", "rev-parse", f"HEAD:{path}"], text=True).strip().lower()
    if actual != sha:
        raise SystemExit(f"baseline blob mismatch for {path}: expected {sha}, found {actual}")

replace_once(
    "scripts/Sync-DeliveryTools.ps1",
    """        [Parameter(Mandatory)]$ExistingManifest,
        [Parameter(Mandatory)]$BackupIdentity
    )""",
    """        [Parameter(Mandatory)]$ExistingManifest,
        [Parameter(Mandatory)]$BackupIdentity,
        [ref]$PreviousIdentityRef
    )""",
    "CodeGraph helper signature",
)

replace_once(
    "scripts/Sync-DeliveryTools.ps1",
    """    $existingIdentity = Assert-CodeGraphBundleAgainstManifest -Path $CurrentPath -Manifest $ExistingManifest
    Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $BackupIdentity
    Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $BackupIdentity
    Move-Item -LiteralPath $CurrentPath -Destination $BackupPath
    # Path-independent validation only. Never execute a launcher from a randomized backup path.
    Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
    return $existingIdentity""",
    """    $existingIdentity = Assert-CodeGraphBundleAgainstManifest -Path $CurrentPath -Manifest $ExistingManifest
    if ($null -ne $PreviousIdentityRef) { $PreviousIdentityRef.Value = $existingIdentity }

    $markerRewritten = $false
    try {
        Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $BackupIdentity
        $markerRewritten = $true
        Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $BackupIdentity
        Move-Item -LiteralPath $CurrentPath -Destination $BackupPath
        # Path-independent validation only. Never execute a launcher from a randomized backup path.
        Assert-CodeGraphTransactionBundle -Path $BackupPath -Identity $BackupIdentity
    }
    catch {
        $transitionError = $_
        if ($markerRewritten -and (Test-Path -LiteralPath $CurrentPath) -and -not (Test-Path -LiteralPath $BackupPath)) {
            try {
                Write-CodeGraphBundleMarker -Path $CurrentPath -Identity $existingIdentity
                Assert-CodeGraphTransactionBundle -Path $CurrentPath -Identity $existingIdentity
            }
            catch {
                throw "CodeGraph current-to-backup transition failed and original marker restoration was incomplete. Original: $($transitionError.Exception.Message). Rollback: $($_.Exception.Message)"
            }
        }
        throw $transitionError
    }
    return $existingIdentity""",
    "CodeGraph previous identity handoff and marker rollback",
)

replace_once(
    "scripts/Sync-DeliveryTools.ps1",
    "$previousIdentity = Move-CodeGraphCurrentToRollbackBackup -CurrentPath $current -BackupPath $backup -ExistingManifest $existingManifest -BackupIdentity $backupIdentity",
    "$previousIdentity = Move-CodeGraphCurrentToRollbackBackup -CurrentPath $current -BackupPath $backup -ExistingManifest $existingManifest -BackupIdentity $backupIdentity -PreviousIdentityRef ([ref]$previousIdentity)",
    "CodeGraph production caller ref handoff",
)

replace_once(
    "scripts/Build-HmsCompositeSkill.impl.ps1",
    """        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTreeSha256
    )
    Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
    $parent = Split-Path -Parent $Path
    $leaf = '.hms-composite-rollback-reserved-' + [guid]::NewGuid().ToString('N')
    $reserved = Join-Path $parent $leaf
    if (Test-Path -LiteralPath $reserved) { throw "Composite rollback reservation path already exists: $reserved" }
    Rename-Item -LiteralPath $Path -NewName $leaf -ErrorAction Stop
    Assert-OwnedCompositeIdentity -Path $reserved -ExpectedTreeSha256 $ExpectedTreeSha256
    return $reserved
}""",
    """        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTreeSha256,
        [ref]$ReservedPathRef
    )
    Assert-OwnedCompositeIdentity -Path $Path -ExpectedTreeSha256 $ExpectedTreeSha256
    $parent = Split-Path -Parent $Path
    $leaf = '.hms-composite-rollback-reserved-' + [guid]::NewGuid().ToString('N')
    $reserved = Join-Path $parent $leaf
    if (Test-Path -LiteralPath $reserved) { throw "Composite rollback reservation path already exists: $reserved" }
    Rename-Item -LiteralPath $Path -NewName $leaf -ErrorAction Stop
    if ($null -ne $ReservedPathRef) { $ReservedPathRef.Value = $reserved }
    Assert-OwnedCompositeIdentity -Path $reserved -ExpectedTreeSha256 $ExpectedTreeSha256
    return $reserved
}""",
    "Composite reservation caller-visible handoff",
)

replace_once(
    "scripts/Build-HmsCompositeSkill.impl.ps1",
    "$reservedBackup = Reserve-OwnedCompositeRollbackBackup -Path $backup -ExpectedTreeSha256 $previousCompositeTreeSha",
    "$reservedBackup = Reserve-OwnedCompositeRollbackBackup -Path $backup -ExpectedTreeSha256 $previousCompositeTreeSha -ReservedPathRef ([ref]$reservedBackup)",
    "Composite production caller ref handoff",
)

replace_once(
    "scripts/Test-HmsSkills.ps1",
    """$ownedTempCleanupPath = Join-Path $PSScriptRoot 'Test-HmsOwnedTempCleanup.ps1'
foreach ($path in @($implementationPath,$remediationPath,$ownedTempCleanupPath)) {""",
    """$ownedTempCleanupPath = Join-Path $PSScriptRoot 'Test-HmsOwnedTempCleanup.ps1'
$rollbackIdentityPath = Join-Path $PSScriptRoot 'Test-HmsRollbackIdentityHandoff.ps1'
foreach ($path in @($implementationPath,$remediationPath,$ownedTempCleanupPath,$rollbackIdentityPath)) {""",
    "Validator support registration",
)

replace_once(
    "scripts/Test-HmsSkills.ps1",
    "& $ownedTempCleanupPath -RepoRoot $RepoRoot",
    "& $ownedTempCleanupPath -RepoRoot $RepoRoot\n& $rollbackIdentityPath -RepoRoot $RepoRoot",
    "Validator regression invocation",
)
