[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$RemoveClones,
    [switch]$IncludeSuperpowers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$hmsLink = Join-Path $skillsRoot 'hms'
$superpowersLink = Join-Path $skillsRoot 'superpowers'
$hmsClone = Join-Path $env:USERPROFILE '.codex\hms-skills-codex'
$superpowersClone = Join-Path $env:USERPROFILE '.codex\superpowers'

function Remove-LinkOnly {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to remove non-link path: $Path"
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove skill junction')) {
        Remove-Item -LiteralPath $Path -Force
    }
}

Remove-LinkOnly -Path $hmsLink
if ($IncludeSuperpowers) { Remove-LinkOnly -Path $superpowersLink }

if ($RemoveClones) {
    if ($PSCmdlet.ShouldProcess($hmsClone, 'Remove HMS clone')) {
        Remove-Item -LiteralPath $hmsClone -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($IncludeSuperpowers -and $PSCmdlet.ShouldProcess($superpowersClone, 'Remove Superpowers clone')) {
        Remove-Item -LiteralPath $superpowersClone -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Requested HMS Skills Codex uninstall actions completed.'
