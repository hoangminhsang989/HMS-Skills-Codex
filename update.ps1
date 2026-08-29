[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$SkipSuperpowers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-CleanRepo {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        throw "Git repository not found: $Path"
    }
    $dirty = & git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "git status failed for $Path" }
    if ($dirty) { throw "Refusing to update dirty repository: $Path" }
    & git -C $Path pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed for $Path" }
}

Update-CleanRepo -Path $InstallRoot

if (-not $SkipSuperpowers) {
    $superpowers = Join-Path $env:USERPROFILE '.codex\superpowers'
    if (Test-Path -LiteralPath (Join-Path $superpowers '.git')) {
        Update-CleanRepo -Path $superpowers
    }
}

& (Join-Path $InstallRoot 'scripts\Test-HmsSkills.ps1')

Write-Host 'HMS Skills Codex update PASS.'
Write-Host 'Restart Codex if the running session does not refresh skill metadata automatically.'
