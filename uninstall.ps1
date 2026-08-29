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
$compositeRoot = Join-Path $env:USERPROFILE '.codex\hms-composite\hms-superpowers'
$compositeLink = Join-Path $skillsRoot 'hms-superpowers'
$hmsLegacyLink = Join-Path $skillsRoot 'hms'
$superpowersLegacyLink = Join-Path $skillsRoot 'superpowers'
$tasteLegacyLink = Join-Path $skillsRoot 'gpt-taste'
$impeccableLegacyLink = Join-Path $skillsRoot 'impeccable'

$hmsClone = $InstallRoot
$superpowersClone = Join-Path $env:USERPROFILE '.codex\superpowers'
$tasteClone = Join-Path $env:USERPROFILE '.codex\taste-skill'
$impeccableClone = Join-Path $env:USERPROFILE '.codex\impeccable'
$codeGraphRoot = Join-Path $env:USERPROFILE '.codex\codegraph'
$threeLevelClone = Join-Path $env:USERPROFILE '.codex\three-level-delivery'

function ConvertTo-NormalizedRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring(0, $value.Length - 4) }
    return $value.ToLowerInvariant()
}

function Assert-SafeRemovalPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    $userRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
    $codexRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex')).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root -or $full -eq $userRoot -or $full -eq $codexRoot) { throw "Refusing unsafe recursive removal target: $Path" }
}

function Assert-CloneIdentity {
    param([string]$Path,[string]$ExpectedRemote,[string]$MarkerRelativePath)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-SafeRemovalPath -Path $Path
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Refusing to remove non-Git clone path: $Path" }
    if (-not (Test-Path -LiteralPath (Join-Path $Path $MarkerRelativePath))) { throw "Refusing to remove clone without expected marker '$MarkerRelativePath': $Path" }
    $origin = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) { throw "Refusing to remove clone with unexpected origin: $Path" }
}

function Assert-OwnedCompositeRoot {
    if (-not (Test-Path -LiteralPath $compositeRoot)) { return }
    Assert-SafeRemovalPath -Path $compositeRoot
    $manifestPath = Join-Path $compositeRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Refusing to remove composite without ownership manifest: $compositeRoot" }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Refusing to remove composite with invalid manifest: $($_.Exception.Message)" }
    if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex' -or [string]$manifest.artifact -cne 'hms-superpowers-composite') { throw "Refusing to remove composite with unexpected ownership: $compositeRoot" }
}

function Assert-ManagedCodeGraphRoot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-SafeRemovalPath -Path $Path
    $manifestPath = Join-Path $Path 'hms-codegraph-install.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Refusing to remove CodeGraph directory without HMS ownership manifest: $Path" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex') { throw "Unexpected CodeGraph owner: $Path" }
}

function Get-ExactJunctionState {
    param([string]$Path,[string]$ExpectedTarget)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 'Absent' }
    if (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing to remove non-reparse path: $Path" }
    $linkType = if ($null -eq $item.PSObject.Properties['LinkType']) { '' } else { [string]$item.LinkType }
    if ($linkType -ine 'Junction') { throw "Refusing to remove non-Junction reparse point: $Path (LinkType='$linkType')" }
    if (-not (Test-Path -LiteralPath $ExpectedTarget)) { throw "Expected Junction target does not exist: $ExpectedTarget" }
    $expected = (Resolve-Path -LiteralPath $ExpectedTarget).Path
    foreach ($candidate in @($item.Target)) {
        if (-not $candidate) { continue }
        try { if ((Resolve-Path -LiteralPath $candidate).Path -ieq $expected) { return 'Exact' } } catch { }
    }
    throw "Refusing to remove Junction with unexpected target: $Path"
}

function Restore-Quarantine {
    param([string]$Original,[string]$Quarantine)
    if ($null -eq (Get-Item -LiteralPath $Quarantine -Force -ErrorAction SilentlyContinue)) { return }
    if ($null -ne (Get-Item -LiteralPath $Original -Force -ErrorAction SilentlyContinue)) { throw "Cannot restore quarantined Junction because original path is occupied: $Original" }
    Rename-Item -LiteralPath $Quarantine -NewName (Split-Path -Leaf $Original) -ErrorAction Stop
}

function Remove-VerifiedJunction {
    param([string]$Path,[string]$ExpectedTarget)
    $state = Get-ExactJunctionState -Path $Path -ExpectedTarget $ExpectedTarget
    if ($state -eq 'Absent') { return }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove verified skill Junction')) { return }

    $parent = Split-Path -Parent $Path
    $leaf = '.hms-uninstall-' + [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent $leaf
    Rename-Item -LiteralPath $Path -NewName $leaf -ErrorAction Stop
    try {
        if ((Get-ExactJunctionState -Path $quarantine -ExpectedTarget $ExpectedTarget) -ne 'Exact') { throw 'Quarantined Junction identity mismatch.' }
        & $env:ComSpec /d /c "rmdir `"$quarantine`""
        if ($LASTEXITCODE -ne 0) { throw "rmdir failed with exit code $LASTEXITCODE" }
    }
    catch {
        $e = $_
        try { Restore-Quarantine -Original $Path -Quarantine $quarantine }
        catch { throw "Junction removal failed and rollback was incomplete. Original: $($e.Exception.Message). Rollback: $($_.Exception.Message)" }
        throw $e
    }
}

function Remove-VerifiedDirectory {
    param([string]$Path,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-SafeRemovalPath -Path $Path
    if ($PSCmdlet.ShouldProcess($Path, $Action)) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        if (Test-Path -LiteralPath $Path) { throw "Removal did not complete: $Path" }
    }
}

# Preflight all selected managed paths before mutation.
if (Test-Path -LiteralPath $compositeRoot) { Assert-OwnedCompositeRoot }
Get-ExactJunctionState -Path $compositeLink -ExpectedTarget $compositeRoot | Out-Null
Get-ExactJunctionState -Path $hmsLegacyLink -ExpectedTarget (Join-Path $hmsClone 'skills') | Out-Null
if ($IncludeSuperpowers) { Get-ExactJunctionState -Path $superpowersLegacyLink -ExpectedTarget (Join-Path $superpowersClone 'skills') | Out-Null }
if ($IncludeUiSkills) {
    Get-ExactJunctionState -Path $tasteLegacyLink -ExpectedTarget (Join-Path $tasteClone 'skills\gpt-tasteskill') | Out-Null
    Get-ExactJunctionState -Path $impeccableLegacyLink -ExpectedTarget (Join-Path $impeccableClone '.agents\skills\impeccable') | Out-Null
}

if ($RemoveClones) {
    Assert-OwnedCompositeRoot
    Assert-CloneIdentity -Path $hmsClone -ExpectedRemote $HmsRemote -MarkerRelativePath 'skills\hms-superpowers\SKILL.md'
    if ($IncludeSuperpowers) { Assert-CloneIdentity -Path $superpowersClone -ExpectedRemote $SuperpowersRemote -MarkerRelativePath 'skills\brainstorming\SKILL.md' }
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
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1'))) { throw 'Cannot safely remove delivery-tool configuration because Sync-DeliveryTools.ps1 is unavailable.' }
    if ($PSCmdlet.ShouldProcess('Codex MCP server codegraph', 'Remove HMS-managed CodeGraph MCP configuration')) {
        & (Join-Path $InstallRoot 'scripts\Sync-DeliveryTools.ps1') -RemoveCodeGraphConfig -SkipThreeLevelDelivery
    }
}

Remove-VerifiedJunction -Path $compositeLink -ExpectedTarget $compositeRoot
Remove-VerifiedJunction -Path $hmsLegacyLink -ExpectedTarget (Join-Path $hmsClone 'skills')
if ($IncludeSuperpowers) { Remove-VerifiedJunction -Path $superpowersLegacyLink -ExpectedTarget (Join-Path $superpowersClone 'skills') }
if ($IncludeUiSkills) {
    Remove-VerifiedJunction -Path $tasteLegacyLink -ExpectedTarget (Join-Path $tasteClone 'skills\gpt-tasteskill')
    Remove-VerifiedJunction -Path $impeccableLegacyLink -ExpectedTarget (Join-Path $impeccableClone '.agents\skills\impeccable')
}

if ($RemoveClones) {
    Remove-VerifiedDirectory -Path $compositeRoot -Action 'Remove verified HMS composite bundle'
    if ($IncludeSuperpowers) { Remove-VerifiedDirectory -Path $superpowersClone -Action 'Remove verified Superpowers clone' }
    if ($IncludeUiSkills) {
        Remove-VerifiedDirectory -Path $tasteClone -Action 'Remove verified Taste clone'
        Remove-VerifiedDirectory -Path $impeccableClone -Action 'Remove verified Impeccable clone'
    }
    if ($IncludeDeliveryTools) {
        Remove-VerifiedDirectory -Path $threeLevelClone -Action 'Remove verified Three-Level Delivery clone'
        Remove-VerifiedDirectory -Path $codeGraphRoot -Action 'Remove verified HMS CodeGraph directory'
    }
    Remove-VerifiedDirectory -Path $hmsClone -Action 'Remove verified HMS clone'
}

Write-Host 'Requested HMS Skills Codex uninstall actions completed.'
