[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementationPath = Join-Path $PSScriptRoot 'Test-HmsSkills.impl.ps1'
$remediationPath = Join-Path $PSScriptRoot 'Test-HmsTrustRemediations.ps1'
$ownedTempCleanupPath = Join-Path $PSScriptRoot 'Test-HmsOwnedTempCleanup.ps1'
$rollbackIdentityPath = Join-Path $PSScriptRoot 'Test-HmsRollbackIdentityHandoff.ps1'
$lateTrustPath = Join-Path $PSScriptRoot 'Test-HmsLateTrustBoundaries.ps1'
$lifecycleSnapshotPath = Join-Path $PSScriptRoot 'Test-HmsLifecycleSnapshotTrust.ps1'
foreach ($path in @($implementationPath,$remediationPath,$ownedTempCleanupPath,$rollbackIdentityPath,$lateTrustPath,$lifecycleSnapshotPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "HMS validator support file is missing: $path" }
}

& $implementationPath -RepoRoot $RepoRoot
& $remediationPath -RepoRoot $RepoRoot
& $ownedTempCleanupPath -RepoRoot $RepoRoot
& $rollbackIdentityPath -RepoRoot $RepoRoot
& $lateTrustPath -RepoRoot $RepoRoot
& $lifecycleSnapshotPath -RepoRoot $RepoRoot
