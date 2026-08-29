[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$RemoveClones,
    [switch]$IncludeSuperpowers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
$SuperpowersRemote = 'https://github.com/obra/superpowers.git'
$skillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$hmsLink = Join-Path $skillsRoot 'hms'
$superpowersLink = Join-Path $skillsRoot 'superpowers'
$hmsClone = $InstallRoot
$superpowersClone = Join-Path $env:USERPROFILE '.codex\superpowers'

function ConvertTo-NormalizedRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    return $value.ToLowerInvariant()
}

function Assert-SafeRemovalPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    $userRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
    $codexRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')).TrimEnd('\', '/')

    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root -or $full -eq $userRoot -or $full -eq $codexRoot) {
        throw "Refusing unsafe recursive removal target: $Path"
    }
}

function Assert-CloneIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRemote,
        [Parameter(Mandatory)][string]$MarkerRelativePath
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-SafeRemovalPath -Path $Path
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        throw "Refusing to remove non-Git clone path: $Path"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Path $MarkerRelativePath))) {
        throw "Refusing to remove clone without expected marker '$MarkerRelativePath': $Path"
    }

    $origin = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) {
        throw "Refusing to remove clone with unexpected origin: $Path ($($origin.Trim()))"
    }
}

function Assert-LinkTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $ExpectedTarget)) {
        throw "Expected junction target does not exist: $ExpectedTarget"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to remove non-link path: $Path"
    }

    $resolvedExpected = (Resolve-Path -LiteralPath $ExpectedTarget).Path
    $matches = $false
    foreach ($candidate in @($item.Target)) {
        if (-not $candidate) { continue }
        try {
            if ((Resolve-Path -LiteralPath $candidate).Path -eq $resolvedExpected) {
                $matches = $true
                break
            }
        }
        catch { }
    }
    if (-not $matches) {
        throw "Refusing to remove junction with unexpected target: $Path"
    }
}

function Remove-VerifiedLink {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove skill junction')) {
        Remove-Item -LiteralPath $Path -Force
        if (Test-Path -LiteralPath $Path) { throw "Junction removal did not complete: $Path" }
    }
}

function Remove-VerifiedClone {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove verified clone')) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        if (Test-Path -LiteralPath $Path) { throw "Clone removal did not complete: $Path" }
    }
}

# Preflight every selected target before the first mutation so an identity mismatch
# cannot leave a partially uninstalled skill set.
Assert-LinkTarget -Path $hmsLink -ExpectedTarget (Join-Path $hmsClone 'skills')
if ($IncludeSuperpowers) {
    Assert-LinkTarget -Path $superpowersLink -ExpectedTarget (Join-Path $superpowersClone 'skills')
}
if ($RemoveClones) {
    Assert-CloneIdentity -Path $hmsClone -ExpectedRemote $HmsRemote -MarkerRelativePath 'skills\hms-superpowers\SKILL.md'
    if ($IncludeSuperpowers) {
        Assert-CloneIdentity -Path $superpowersClone -ExpectedRemote $SuperpowersRemote -MarkerRelativePath 'skills\brainstorming\SKILL.md'
    }
}

Remove-VerifiedLink -Path $hmsLink
if ($IncludeSuperpowers) { Remove-VerifiedLink -Path $superpowersLink }

if ($RemoveClones) {
    Remove-VerifiedClone -Path $hmsClone
    if ($IncludeSuperpowers) { Remove-VerifiedClone -Path $superpowersClone }
}

Write-Host 'Requested HMS Skills Codex uninstall actions completed.'
