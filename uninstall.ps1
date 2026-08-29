[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [switch]$RemoveClones,
    [switch]$IncludeSuperpowers,
    [switch]$IncludeUiSkills,
    [switch]$IncludeDeliveryTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HmsRemote = 'https://github.com/hoangminhsang989/HMS-Skills-Codex.git'
$SuperpowersRemote = 'https://github.com/obra/superpowers.git'
$TasteRemote = 'https://github.com/Leonxlnx/taste-skill.git'
$ImpeccableRemote = 'https://github.com/pbakaus/impeccable.git'
$ThreeLevelRemote = 'https://github.com/nguyenduytamgithub/three-level-delivery.git'

$skillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$hmsLink = Join-Path $skillsRoot 'hms'
$superpowersLink = Join-Path $skillsRoot 'superpowers'
$tasteLink = Join-Path $skillsRoot 'gpt-taste'
$impeccableLink = Join-Path $skillsRoot 'impeccable'

$hmsClone = $InstallRoot
$superpowersClone = Join-Path $env:USERPROFILE '.codex\superpowers'
$tasteClone = Join-Path $env:USERPROFILE '.codex\taste-skill'
$impeccableClone = Join-Path $env:USERPROFILE '.codex\impeccable'
$codeGraphRoot = Join-Path $env:USERPROFILE '.codex\codegraph'
$threeLevelClone = Join-Path $env:USERPROFILE '.codex\three-level-delivery'

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
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Refusing to remove non-Git clone path: $Path" }
    if (-not (Test-Path -LiteralPath (Join-Path $Path $MarkerRelativePath))) {
        throw "Refusing to remove clone without expected marker '$MarkerRelativePath': $Path"
    }
    $origin = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) {
        throw "Refusing to remove clone with unexpected origin: $Path ($($origin.Trim()))"
    }
}

function Assert-ManagedCodeGraphRoot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-SafeRemovalPath -Path $Path
    $manifestPath = Join-Path $Path 'hms-codegraph-install.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Refusing to remove CodeGraph directory without HMS ownership manifest: $Path" }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Refusing to remove CodeGraph directory with invalid ownership manifest: $($_.Exception.Message)" }
    if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex') { throw "Refusing to remove CodeGraph directory with unexpected owner: $Path" }
    if ([string]$manifest.version -cne '1.6.0' -or [string]$manifest.commit -cne 'dfccdf62547fcd76d343344d823a0e1998d3a89f') {
        throw "Refusing to remove CodeGraph directory whose pinned identity is not recognized by this HMS candidate: $Path"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'current\bin\codegraph.cmd'))) { throw "Refusing to remove CodeGraph directory without expected launcher: $Path" }
}

function Assert-LinkTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not (Test-Path -LiteralPath $ExpectedTarget)) { throw "Expected junction target does not exist: $ExpectedTarget" }
    if (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing to remove non-link path: $Path" }

    $resolvedExpected = (Resolve-Path -LiteralPath $ExpectedTarget).Path
    $matches = $false
    foreach ($candidate in @($item.Target)) {
        if (-not $candidate) { continue }
        try {
            if ((Resolve-Path -LiteralPath $candidate).Path -ieq $resolvedExpected) {
                $matches = $true
                break
            }
        }
        catch { }
    }
    if (-not $matches) { throw "Refusing to remove junction with unexpected target: $Path" }
}

function Remove-VerifiedLink {
    param([Parameter(Mandatory)][string]$Path)
    if ($null -eq (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) { return }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove skill junction')) {
        Remove-Item -LiteralPath $Path -Force
        if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) { throw "Junction removal did not complete: $Path" }
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

function Remove-VerifiedManagedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove verified HMS-managed directory')) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        if (Test-Path -LiteralPath $Path) { throw "Managed directory removal did not complete: $Path" }
    }
}

# Preflight every selected target before the first mutation.
Assert-LinkTarget -Path $hmsLink -ExpectedTarget (Join-Path $hmsClone 'skills')
if ($IncludeSuperpowers) {
    Assert-LinkTarget -Path $superpowersLink -ExpectedTarget (Join-Path $superpowersClone 'skills')
}
if ($IncludeUiSkills) {
    Assert-LinkTarget -Path $tasteLink -ExpectedTarget (Join-Path $tasteClone 'skills\gpt-tasteskill')
    Assert-LinkTarget -Path $impeccableLink -ExpectedTarget (Join-Path $impeccableClone '.agents\skills\impeccable')
}

if ($RemoveClones) {
    Assert-CloneIdentity -Path $hmsClone -ExpectedRemote $HmsRemote -MarkerRelativePath 'skills\hms-superpowers\SKILL.md'
    if ($IncludeSuperpowers) {
        Assert-CloneIdentity -Path $superpowersClone -ExpectedRemote $SuperpowersRemote -MarkerRelativePath 'skills\brainstorming\SKILL.md'
    }
    if ($IncludeUiSkills) {
        Assert-CloneIdentity -Path $tasteClone -ExpectedRemote $TasteRemote -MarkerRelativePath 'skills\gpt-tasteskill\SKILL.md'
        Assert-CloneIdentity -Path $impeccableClone -ExpectedRemote $ImpeccableRemote -MarkerRelativePath '.agents\skills\impeccable\SKILL.md'
    }
    if ($IncludeDeliveryTools) {
        Assert-ManagedCodeGraphRoot -Path $codeGraphRoot
        Assert-CloneIdentity -Path $threeLevelClone -ExpectedRemote $ThreeLevelRemote -MarkerRelativePath 'three-level-delivery\SKILL.md'
    }
}

if ($IncludeDeliveryTools) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1'))) {
        throw 'Cannot safely remove CodeGraph MCP config because scripts/Sync-DeliveryTools.ps1 is unavailable.'
    }
    if ($PSCmdlet.ShouldProcess('Codex MCP server codegraph', 'Remove HMS-managed CodeGraph MCP configuration')) {
        & (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1') -RemoveCodeGraphConfig -SkipThreeLevelDelivery
    }
}

Remove-VerifiedLink -Path $hmsLink
if ($IncludeSuperpowers) { Remove-VerifiedLink -Path $superpowersLink }
if ($IncludeUiSkills) {
    Remove-VerifiedLink -Path $tasteLink
    Remove-VerifiedLink -Path $impeccableLink
}

if ($RemoveClones) {
    if ($IncludeSuperpowers) { Remove-VerifiedClone -Path $superpowersClone }
    if ($IncludeUiSkills) {
        Remove-VerifiedClone -Path $tasteClone
        Remove-VerifiedClone -Path $impeccableClone
    }
    if ($IncludeDeliveryTools) {
        Remove-VerifiedClone -Path $threeLevelClone
        Remove-VerifiedManagedDirectory -Path $codeGraphRoot
    }
    Remove-VerifiedClone -Path $hmsClone
}

Write-Host 'Requested HMS Skills Codex uninstall actions completed.'
