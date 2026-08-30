[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementationPath = Join-Path $PSScriptRoot 'Test-HmsSkills.impl.ps1'
$remediationPath = Join-Path $PSScriptRoot 'Test-HmsTrustRemediations.ps1'
foreach ($path in @($implementationPath,$remediationPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "HMS validator support file is missing: $path" }
}

& $implementationPath -RepoRoot $RepoRoot
& $remediationPath -RepoRoot $RepoRoot
