[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\hms-skills-codex'),
    [string]$OutputRoot = (Join-Path $env:USERPROFILE '.codex\hms-composite'),
    [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.agents\skills'),
    [bool]$Hms = $true,
    [bool]$Superpowers = $true,
    [bool]$Taste = $true,
    [bool]$Impeccable = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CompositeName = 'hms-superpowers'
$ManagedBy = 'HMS-Skills-Codex'
$Artifact = 'hms-superpowers-composite'
$FinalRoot = Join-Path $OutputRoot $CompositeName
$CompositeLink = Join-Path $SkillsRoot $CompositeName
$SuperpowersRoot = Join-Path $env:USERPROFILE '.codex\superpowers'
$TasteRoot = Join-Path $env:USERPROFILE '.codex\taste-skill'
$ImpeccableRoot = Join-Path $env:USERPROFILE '.codex\impeccable'
$UiLockPath = Join-Path $InstallRoot 'ui-skills.lock.json'

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\')
}

function Get-GitHeadOrNull {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return $null }
    $head = & git -C $Path rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $value = $head.Trim().ToLowerInvariant()
    if ($value -notmatch '^[0-9a-f]{40}$') { return $null }
    return $value
}

function Read-UiLock {
    if (-not (Test-Path -LiteralPath $UiLockPath)) { throw "UI skills lock file not found: $UiLockPath" }
    try { $lock = Get-Content -LiteralPath $UiLockPath -Raw | ConvertFrom-Json }
    catch { throw "UI skills lock is invalid JSON: $($_.Exception.Message)" }
    if ([string]$lock.taste.skill_path -cne 'skills/gpt-tasteskill') { throw 'Unexpected Taste skill path in ui-skills.lock.json.' }
    if ([string]$lock.impeccable.skill_path -cne '.agents/skills/impeccable') { throw 'Unexpected Impeccable skill path in ui-skills.lock.json.' }
    return $lock
}

function Get-ExactJunctionState {
    param([Parameter(Mandatory)][string]$Link,[Parameter(Mandatory)][string]$Target)
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [pscustomobject]@{ State='Absent'; Detail='Path is absent.' } }
    if (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [pscustomobject]@{ State='Conflict'; Detail="Existing path is not a reparse point: $Link" } }
    $linkType = if ($null -eq $item.PSObject.Properties['LinkType']) { '' } else { [string]$item.LinkType }
    if ($linkType -ine 'Junction') { return [pscustomobject]@{ State='Conflict'; Detail="Existing reparse point is not a Junction: $Link (LinkType='$linkType')" } }
    if (-not (Test-Path -LiteralPath $Target)) { return [pscustomobject]@{ State='Conflict'; Detail="Expected Junction target is missing: $Target" } }
    $expected = Get-CanonicalPath -Path $Target
    foreach ($candidate in @($item.Target)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try { if ((Get-CanonicalPath -Path ([string]$candidate)) -ieq $expected) { return [pscustomobject]@{ State='Exact'; Detail="Junction targets $expected" } } } catch { }
    }
    return [pscustomobject]@{ State='Conflict'; Detail="Junction target does not match the managed target: $Link" }
}

function Ensure-ExactJunction {
    param([Parameter(Mandatory)][string]$Link,[Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { throw "Cannot create Junction because target is missing: $Target" }
    $state = Get-ExactJunctionState -Link $Link -Target $Target
    if ($state.State -eq 'Exact') { return }
    if ($state.State -eq 'Conflict') { throw $state.Detail }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Link) | Out-Null
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    $after = Get-ExactJunctionState -Link $Link -Target $Target
    if ($after.State -ne 'Exact') { throw "Junction creation verification failed: $Link : $($after.Detail)" }
}

function Restore-Quarantine {
    param([Parameter(Mandatory)][string]$Original,[Parameter(Mandatory)][string]$Quarantine)
    if ($null -eq (Get-Item -LiteralPath $Quarantine -Force -ErrorAction SilentlyContinue)) { return }
    if ($null -ne (Get-Item -LiteralPath $Original -Force -ErrorAction SilentlyContinue)) { throw "Cannot restore quarantined path because original is occupied: $Original" }
    Rename-Item -LiteralPath $Quarantine -NewName (Split-Path -Leaf $Original) -ErrorAction Stop
}

function Remove-ExactJunction {
    param([Parameter(Mandatory)][string]$Link,[Parameter(Mandatory)][string]$Target)
    $state = Get-ExactJunctionState -Link $Link -Target $Target
    if ($state.State -eq 'Absent') { return }
    if ($state.State -ne 'Exact') { throw "Refusing to remove non-managed discovery path: $Link : $($state.Detail)" }
    $parent = Split-Path -Parent $Link
    $leaf = '.hms-removing-' + [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent $leaf
    Rename-Item -LiteralPath $Link -NewName $leaf -ErrorAction Stop
    try {
        $boundary = Get-ExactJunctionState -Link $quarantine -Target $Target
        if ($boundary.State -ne 'Exact') { throw "Quarantined Junction identity mismatch: $($boundary.Detail)" }
        & $env:ComSpec /d /c "rmdir `"$quarantine`""
        if ($LASTEXITCODE -ne 0) { throw "rmdir failed with exit code $LASTEXITCODE" }
    }
    catch {
        $originalError = $_
        try { Restore-Quarantine -Original $Link -Quarantine $quarantine }
        catch { throw "Junction removal failed and rollback was incomplete. Original: $($originalError.Exception.Message). Rollback: $($_.Exception.Message)" }
        throw $originalError
    }
}

function Assert-OwnedCompositeRoot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $manifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Refusing to replace unowned composite directory: $Path" }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Refusing to replace composite directory with invalid manifest: $Path" }
    if ([string]$manifest.managed_by -cne $ManagedBy -or [string]$manifest.artifact -cne $Artifact) { throw "Refusing to replace composite directory with unexpected ownership: $Path" }
}

function Copy-SkillModule {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md'))) { throw "Skill source does not contain SKILL.md: $Source" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    foreach ($skillFile in @(Get-ChildItem -LiteralPath $Destination -Filter 'SKILL.md' -File -Recurse -ErrorAction SilentlyContinue)) {
        Rename-Item -LiteralPath $skillFile.FullName -NewName 'MODULE.md' -ErrorAction Stop
    }
}

function Copy-SkillCollection {
    param([Parameter(Mandatory)][string]$SkillsDirectory,[Parameter(Mandatory)][string]$DestinationRoot,[Parameter(Mandatory)][string]$ModulePrefix)
    if (-not (Test-Path -LiteralPath $SkillsDirectory)) { throw "Skill collection is missing: $SkillsDirectory" }
    $copied = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $SkillsDirectory -Directory | Sort-Object Name)) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md'))) { continue }
        $destination = Join-Path $DestinationRoot $dir.Name
        Copy-SkillModule -Source $dir.FullName -Destination $destination
        $copied += ($ModulePrefix + '/' + $dir.Name + '/MODULE.md')
    }
    if ($copied.Count -eq 0) { throw "No skill modules were found under: $SkillsDirectory" }
    return $copied
}

function Write-CompositeSkill {
    param([Parameter(Mandatory)][string]$StageRoot,[Parameter(Mandatory)]$Modules,[string[]]$HmsReferences,[string[]]$SuperpowersReferences,[string]$TasteReference,[string]$ImpeccableReference)
    $enabled = @($Modules.Keys | Where-Object { [bool]$Modules[$_] })
    $enabledText = if ($enabled.Count -eq 0) { 'none' } else { $enabled -join ', ' }
    $lines = @(
        '---',
        'name: hms-superpowers',
        'description: Use as the single HMS entry point for project work; it routes each task to exactly one enabled internal module owner and keeps governance, engineering method, visual direction, and UI polish separated.',
        '---',
        '',
        '# HMS Unified Superpower',
        '',
        'This file is generated by HMS Skills Manager. Do not edit the generated bundle by hand.',
        '',
        ('Enabled modules: ' + $enabledText),
        '',
        '## Arbitration kernel',
        '',
        '1. Owner instruction and current project authority always outrank every internal module.',
        '2. Assign exactly one primary module owner for each decision or task slice.',
        '3. Other enabled modules may advise or provide method, but they must not compete for ownership.',
        '4. Never let two modules mutate the same files or design authority concurrently.',
        '5. If module guidance conflicts, apply the role matrix below instead of blending incompatible instructions.',
        '6. Load only the module references needed for the current task; MODULE.md files are references, not separately invokable Codex skills.',
        '',
        '## Exclusive role matrix',
        '',
        '| Work type | Primary owner | Other modules |',
        '| --- | --- | --- |',
        '| Authority, checkpoint, scope, model route, evidence, review gate, release, handoff | HMS Core | Others are subordinate |',
        '| Engineering plan, worktree method, debugging, TDD, implementation workflow | Superpowers | HMS governs boundaries; UI advisors do not own engineering |',
        '| Visual direction, aesthetic options, taste critique | GPT Taste | Advisory only; cannot override project UI authority |',
        '| UI audit, consistency, typography, spacing, accessibility, final polish | Impeccable | Advisory/polish only; cannot redesign frozen authority |',
        '| UI production implementation | Superpowers | Taste proposes direction; Impeccable audits/polishes; HMS governs if enabled |',
        '',
        '## UI sequence when multiple UI modules are enabled',
        '',
        'Run UI work sequentially: project/HMS UI authority -> GPT Taste direction -> Impeccable audit/polish -> Superpowers implementation -> HMS evidence/release gates.',
        'Do not ask Taste and Impeccable to independently redesign the same artifact. Taste owns direction; Impeccable owns quality audit and polish inside the accepted direction.',
        '',
        '## Module loading contract',
        ''
    )
    if ([bool]$Modules['hms']) {
        $lines += '### HMS Core'
        $lines += 'HMS Core owns governance and final arbitration. Read references/hms/hms-superpowers/MODULE.md first, then load only supporting HMS MODULE.md files required by the current gate.'
        foreach ($ref in @($HmsReferences)) { $lines += ('- ' + $ref) }
        $lines += ''
    }
    if ([bool]$Modules['superpowers']) {
        $lines += '### Superpowers'
        $lines += 'Superpowers owns technical method only. It cannot expand HMS scope, change authority, or authorize merge/release.'
        foreach ($ref in @($SuperpowersReferences)) { $lines += ('- ' + $ref) }
        $lines += ''
    }
    if ([bool]$Modules['taste']) {
        $lines += '### GPT Taste'
        $lines += 'Taste owns visual direction and critique only. Use it only where higher UI authority leaves discretion.'
        $lines += ('- ' + $TasteReference)
        $lines += ''
    }
    if ([bool]$Modules['impeccable']) {
        $lines += '### Impeccable'
        $lines += 'Impeccable owns UI audit and polish only. It may improve quality inside an accepted direction but cannot replace frozen product or design authority.'
        $lines += ('- ' + $ImpeccableReference)
        $lines += ''
    }
    if ($enabled.Count -eq 0) {
        $lines += 'No modules are enabled. This bundle must not be exposed to Codex discovery.'
    }
    else {
        $lines += '## Completion rule'
        $lines += ''
        $lines += 'Use one entry point, one primary owner per task slice, sequential advisors, and the strongest applicable evidence gate.'
    }
    Set-Content -LiteralPath (Join-Path $StageRoot 'SKILL.md') -Value ($lines -join "`r`n") -Encoding UTF8
}

$uiLock = Read-UiLock
$modules = [ordered]@{ hms=[bool]$Hms; superpowers=[bool]$Superpowers; taste=[bool]$Taste; impeccable=[bool]$Impeccable }
if ($Hms -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'skills\hms-superpowers\SKILL.md'))) { throw 'HMS Core is enabled but HMS skill sources are missing.' }
if ($Superpowers -and -not (Test-Path -LiteralPath (Join-Path $SuperpowersRoot 'skills'))) { throw 'Superpowers is enabled but the pinned source repository is missing.' }
$tasteSource = Join-Path $TasteRoot ([string]$uiLock.taste.skill_path)
$impeccableSource = Join-Path $ImpeccableRoot ([string]$uiLock.impeccable.skill_path)
if ($Taste -and -not (Test-Path -LiteralPath (Join-Path $tasteSource 'SKILL.md'))) { throw 'GPT Taste is enabled but its pinned skill source is missing.' }
if ($Impeccable -and -not (Test-Path -LiteralPath (Join-Path $impeccableSource 'SKILL.md'))) { throw 'Impeccable is enabled but its pinned skill source is missing.' }

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $SkillsRoot | Out-Null
Assert-OwnedCompositeRoot -Path $FinalRoot

$legacy = @(
    [pscustomobject]@{ Name='hms'; Link=(Join-Path $SkillsRoot 'hms'); Target=(Join-Path $InstallRoot 'skills') },
    [pscustomobject]@{ Name='superpowers'; Link=(Join-Path $SkillsRoot 'superpowers'); Target=(Join-Path $SuperpowersRoot 'skills') },
    [pscustomobject]@{ Name='taste'; Link=(Join-Path $SkillsRoot 'gpt-taste'); Target=$tasteSource },
    [pscustomobject]@{ Name='impeccable'; Link=(Join-Path $SkillsRoot 'impeccable'); Target=$impeccableSource }
)
foreach ($entry in $legacy) {
    if ($null -eq (Get-Item -LiteralPath $entry.Link -Force -ErrorAction SilentlyContinue)) { continue }
    $state = Get-ExactJunctionState -Link $entry.Link -Target $entry.Target
    if ($state.State -ne 'Exact') { throw "Legacy discovery conflict blocks single-skill migration: $($entry.Link) : $($state.Detail)" }
}
if (Test-Path -LiteralPath $FinalRoot) {
    $state = Get-ExactJunctionState -Link $CompositeLink -Target $FinalRoot
    if ($state.State -eq 'Conflict') { throw "Composite discovery conflict: $($state.Detail)" }
}
elseif ($null -ne (Get-Item -LiteralPath $CompositeLink -Force -ErrorAction SilentlyContinue)) {
    throw "Composite discovery path exists before its managed target exists: $CompositeLink"
}

$stage = Join-Path $OutputRoot ('.stage-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $OutputRoot ('.backup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    $refsRoot = Join-Path $stage 'references'
    $hmsRefs = @(); $superRefs = @(); $tasteRef = $null; $impeccableRef = $null
    if ($Hms) { $hmsRefs = @(Copy-SkillCollection -SkillsDirectory (Join-Path $InstallRoot 'skills') -DestinationRoot (Join-Path $refsRoot 'hms') -ModulePrefix 'references/hms') }
    if ($Superpowers) { $superRefs = @(Copy-SkillCollection -SkillsDirectory (Join-Path $SuperpowersRoot 'skills') -DestinationRoot (Join-Path $refsRoot 'superpowers') -ModulePrefix 'references/superpowers') }
    if ($Taste) { Copy-SkillModule -Source $tasteSource -Destination (Join-Path $refsRoot 'taste'); $tasteRef = 'references/taste/MODULE.md' }
    if ($Impeccable) { Copy-SkillModule -Source $impeccableSource -Destination (Join-Path $refsRoot 'impeccable'); $impeccableRef = 'references/impeccable/MODULE.md' }
    Write-CompositeSkill -StageRoot $stage -Modules $modules -HmsReferences $hmsRefs -SuperpowersReferences $superRefs -TasteReference $tasteRef -ImpeccableReference $impeccableRef

    $enabled = @($modules.Keys | Where-Object { [bool]$modules[$_] })
    $manifest = [ordered]@{
        schema_version=1; managed_by=$ManagedBy; artifact=$Artifact; composite_skill=$CompositeName; generated_at_utc=[DateTime]::UtcNow.ToString('o'); modules=$modules; enabled_modules=$enabled
        source_heads=[ordered]@{ hms=(Get-GitHeadOrNull -Path $InstallRoot); superpowers=(Get-GitHeadOrNull -Path $SuperpowersRoot); taste=(Get-GitHeadOrNull -Path $TasteRoot); impeccable=(Get-GitHeadOrNull -Path $ImpeccableRoot) }
        routing_contract=[ordered]@{ governance='hms'; engineering_method='superpowers'; visual_direction='taste'; ui_audit_polish='impeccable'; concurrency='one-primary-owner-per-task-slice' }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8

    if (Test-Path -LiteralPath $FinalRoot) { Rename-Item -LiteralPath $FinalRoot -NewName (Split-Path -Leaf $backup) -ErrorAction Stop }
    Rename-Item -LiteralPath $stage -NewName (Split-Path -Leaf $FinalRoot) -ErrorAction Stop

    $removedLegacy = @(); $createdComposite = $false
    try {
        foreach ($entry in $legacy) {
            if ($null -ne (Get-Item -LiteralPath $entry.Link -Force -ErrorAction SilentlyContinue)) { Remove-ExactJunction -Link $entry.Link -Target $entry.Target; $removedLegacy += $entry }
        }
        if ($enabled.Count -gt 0) {
            $before = Get-ExactJunctionState -Link $CompositeLink -Target $FinalRoot
            Ensure-ExactJunction -Link $CompositeLink -Target $FinalRoot
            if ($before.State -eq 'Absent') { $createdComposite = $true }
        }
        else {
            $state = Get-ExactJunctionState -Link $CompositeLink -Target $FinalRoot
            if ($state.State -eq 'Exact') { Remove-ExactJunction -Link $CompositeLink -Target $FinalRoot }
            elseif ($state.State -eq 'Conflict') { throw $state.Detail }
        }
    }
    catch {
        $mutationError = $_; $rollbackErrors = @()
        try { if ($createdComposite -and (Test-Path -LiteralPath $FinalRoot)) { Remove-ExactJunction -Link $CompositeLink -Target $FinalRoot } } catch { $rollbackErrors += $_.Exception.Message }
        foreach ($entry in $removedLegacy) { try { Ensure-ExactJunction -Link $entry.Link -Target $entry.Target } catch { $rollbackErrors += $_.Exception.Message } }
        try {
            if (Test-Path -LiteralPath $FinalRoot) { Remove-Item -LiteralPath $FinalRoot -Recurse -Force }
            if (Test-Path -LiteralPath $backup) { Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $FinalRoot) -ErrorAction Stop }
        }
        catch { $rollbackErrors += $_.Exception.Message }
        if ($rollbackErrors.Count -gt 0) { throw "Composite activation failed and rollback was incomplete. Original: $($mutationError.Exception.Message). Rollback: $($rollbackErrors -join ' | ')" }
        throw $mutationError
    }

    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    $enabledText = if ($enabled.Count -eq 0) { 'none' } else { $enabled -join ', ' }
    Write-Host "PASS: compiled one Codex skill '$CompositeName' from enabled modules: $enabledText."
    Write-Host "Composite bundle: $FinalRoot"
    if ($enabled.Count -gt 0) { Write-Host "Codex discovery: $CompositeLink" } else { Write-Host 'Codex discovery disabled because no modules are enabled.' }
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
