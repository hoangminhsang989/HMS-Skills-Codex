[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$head = ((& git -C $RepoRoot rev-parse HEAD 2>$null) -join '').Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw 'Lifecycle snapshot regression could not capture exact HEAD.' }

function Get-CommittedTestScript {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Label)
    $sha = ((& git -C $RepoRoot rev-parse "$head`:$RelativePath" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[0-9a-f]{40}$') { throw "$Label committed blob is unavailable." }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = "cat-file blob $sha"
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw "$Label git cat-file could not start." }
    $memory = New-Object IO.MemoryStream
    try {
        $proc.StandardOutput.BaseStream.CopyTo($memory)
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "$Label git cat-file failed: $stderr" }
        $bytes = $memory.ToArray()
    }
    finally { $memory.Dispose(); $proc.Dispose() }
    $text = (New-Object Text.UTF8Encoding($false,$true)).GetString([byte[]]$bytes)
    return [ScriptBlock]::Create($text)
}

$installPath = Join-Path $RepoRoot 'install.ps1'
$updatePath = Join-Path $RepoRoot 'update.ps1'
$installText = [IO.File]::ReadAllText($installPath)
$updateText = [IO.File]::ReadAllText($updatePath)
foreach ($text in @($installText,$updateText)) {
    foreach ($required in @(
        'Get-HmsLifecycleTrustBootstrap',
        'Get-HmsCommittedLifecycleScriptSnapshot',
        'Get-HmsCommittedScriptSnapshot',
        '-TrustedRepoRoot $InstallRoot',
        '-TrustedHead $trustedHead',
        '-TrustedBootstrapBlob ([string]$builderSnapshot.Sha)'
    )) {
        if ($text -notmatch [regex]::Escape($required)) { throw "Lifecycle entrypoint is missing committed-snapshot contract: $required" }
    }
    foreach ($forbidden in @(
        "& (Join-Path `$InstallRoot 'scripts\\Sync-UiSkills.ps1')",
        "& (Join-Path `$InstallRoot 'scripts\\Sync-DeliveryTools.ps1')",
        "& (Join-Path `$InstallRoot 'scripts\\Build-HmsCompositeSkill.ps1')"
    )) {
        if ($text -match [regex]::Escape($forbidden)) { throw "Lifecycle entrypoint still executes a mutable live helper pathname: $forbidden" }
    }
}
foreach ($required in @('preUpdateHead','Pre-update composite module-state reader','postTrustBootstrap')) {
    if ($updateText -notmatch [regex]::Escape($required)) { throw "Updater is missing pre/post committed authority separation: $required" }
}

$trustScript = Get-CommittedTestScript -RelativePath 'scripts/Initialize-HmsLifecycleTrust.ps1' -Label 'Lifecycle trust bootstrap'
. $trustScript

$targets = @(
    'scripts/Read-HmsCompositeModuleState.ps1',
    'scripts/Sync-UiSkills.ps1',
    'scripts/Sync-DeliveryTools.ps1',
    'scripts/Build-HmsCompositeSkill.ps1',
    'superpowers.lock.json',
    'ui-skills.lock.json',
    'delivery-tools.lock.json'
)
$original = @{}
foreach ($relative in $targets) {
    $path = Join-Path $RepoRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
    $original[$relative] = [IO.File]::ReadAllBytes($path)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('hms-lifecycle-snapshot-' + [guid]::NewGuid().ToString('N'))
$outputRoot = Join-Path $testRoot 'output'
$skillsRoot = Join-Path $testRoot 'skills'
$manifestPath = Join-Path $testRoot 'manifest.json'
$oldHome = $env:HOME
$oldUserProfile = $env:USERPROFILE
try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $manifest = [ordered]@{
        schema_version = 1
        managed_by = 'HMS-Skills-Codex'
        artifact = 'hms-superpowers-composite'
        modules = [ordered]@{ hms=$false; superpowers=$false; taste=$false; impeccable=$false }
    }
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))

    # HEAD is already captured above. Replace every cited live helper/lock after capture with bytes
    # that would fail immediately if production reopened the mutable pathname.
    foreach ($relative in @(
        'scripts/Read-HmsCompositeModuleState.ps1',
        'scripts/Sync-UiSkills.ps1',
        'scripts/Sync-DeliveryTools.ps1',
        'scripts/Build-HmsCompositeSkill.ps1'
    )) {
        $path = Join-Path $RepoRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $existing = (New-Object Text.UTF8Encoding($false,$true)).GetString([byte[]]$original[$relative])
        [IO.File]::WriteAllText($path,("throw 'HMS_LIVE_HELPER_INJECTION_EXECUTED: $relative'`n" + $existing),(New-Object Text.UTF8Encoding($false)))
    }
    foreach ($relative in @('superpowers.lock.json','ui-skills.lock.json','delivery-tools.lock.json')) {
        $path = Join-Path $RepoRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        [IO.File]::WriteAllText($path,'{"HMS_LIVE_LOCK_INJECTION":true}',(New-Object Text.UTF8Encoding($false)))
    }

    $reader = Get-HmsCommittedScriptSnapshot -RepoRoot $RepoRoot -Head $head -RelativePath 'scripts/Read-HmsCompositeModuleState.ps1' -Label 'Adversarial module-state reader'
    $state = & $reader.ScriptBlock -ManifestPath $manifestPath
    if ([bool]$state.hms -or [bool]$state.superpowers -or [bool]$state.taste -or [bool]$state.impeccable) { throw 'Committed reader returned unexpected module state.' }

    $env:HOME = $testRoot
    $env:USERPROFILE = $testRoot
    $ui = Get-HmsCommittedLifecycleScriptSnapshot -RepoRoot $RepoRoot -Head $head -ScriptRelativePath 'scripts/Sync-UiSkills.ps1' -LockRelativePath 'ui-skills.lock.json' -Label 'Adversarial UI reconciliation'
    & $ui.ScriptBlock -SkipTaste -SkipImpeccable

    $delivery = Get-HmsCommittedLifecycleScriptSnapshot -RepoRoot $RepoRoot -Head $head -ScriptRelativePath 'scripts/Sync-DeliveryTools.ps1' -LockRelativePath 'delivery-tools.lock.json' -Label 'Adversarial delivery reconciliation'
    & $delivery.ScriptBlock -SkipCodeGraph -SkipThreeLevelDelivery

    $superLock = Get-HmsCommittedUtf8Text -RepoRoot $RepoRoot -Head $head -RelativePath 'superpowers.lock.json' -Label 'Adversarial Superpowers lock'
    $parsedSuperLock = $superLock.Text | ConvertFrom-Json
    if ([string]$parsedSuperLock.repository -cne 'https://github.com/obra/superpowers.git') { throw 'Committed Superpowers lock snapshot was not used.' }

    $builder = Get-HmsCommittedScriptSnapshot -RepoRoot $RepoRoot -Head $head -RelativePath 'scripts/Build-HmsCompositeSkill.ps1' -Label 'Adversarial composite builder'
    & $builder.ScriptBlock `
        -InstallRoot $RepoRoot `
        -OutputRoot $outputRoot `
        -SkillsRoot $skillsRoot `
        -Hms $false `
        -Superpowers $false `
        -Taste $false `
        -Impeccable $false `
        -TrustedRepoRoot $RepoRoot `
        -TrustedHead $head `
        -TrustedBootstrapBlob ([string]$builder.Sha)

    $builtManifest = Join-Path $outputRoot 'hms-superpowers\manifest.json'
    if (-not (Test-Path -LiteralPath $builtManifest -PathType Leaf)) { throw 'Committed builder snapshot did not produce the expected isolated composite.' }
    Write-Host 'PASS: post-HEAD live helper and lock injection cannot execute or influence committed lifecycle snapshots.'
}
finally {
    $env:HOME = $oldHome
    $env:USERPROFILE = $oldUserProfile
    foreach ($relative in $targets) {
        $path = Join-Path $RepoRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        [IO.File]::WriteAllBytes($path,[byte[]]$original[$relative])
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$dirty = @(& git -C $RepoRoot status --porcelain -- $targets)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw "Lifecycle snapshot regression did not restore adversarial live bytes: $($dirty -join '; ')" }
