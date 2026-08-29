[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuilderPath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.ps1'
$OutputRoot = Join-Path $env:USERPROFILE '.codex\hms-composite'
$CompositeRoot = Join-Path $OutputRoot 'hms-superpowers'
$ManifestPath = Join-Path $CompositeRoot 'manifest.json'
$SkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$CompositeLink = Join-Path $SkillsRoot 'hms-superpowers'

$ModuleDefinitions = @(
    [pscustomobject]@{
        Key = 'hms'
        Name = 'HMS Core'
        Role = 'Authority, scope, evidence, review, release, handoff'
    },
    [pscustomobject]@{
        Key = 'superpowers'
        Name = 'Superpowers'
        Role = 'Engineering method: plan, debug, TDD, worktree, implementation'
    },
    [pscustomobject]@{
        Key = 'taste'
        Name = 'GPT Taste'
        Role = 'Visual direction and aesthetic critique only'
    },
    [pscustomobject]@{
        Key = 'impeccable'
        Name = 'Impeccable'
        Role = 'UI audit, consistency, accessibility, and final polish'
    }
)

function Assert-BuilderAvailable {
    if (-not (Test-Path -LiteralPath $BuilderPath)) { throw "Composite compiler is missing: $BuilderPath" }
}

function New-DefaultState {
    return [ordered]@{
        hms = $true
        superpowers = $true
        taste = $true
        impeccable = $true
    }
}

function Get-LegacyInferredState {
    $legacy = [ordered]@{
        hms = (Join-Path $SkillsRoot 'hms')
        superpowers = (Join-Path $SkillsRoot 'superpowers')
        taste = (Join-Path $SkillsRoot 'gpt-taste')
        impeccable = (Join-Path $SkillsRoot 'impeccable')
    }
    $state = [ordered]@{}
    $foundAny = $false
    foreach ($key in @('hms', 'superpowers', 'taste', 'impeccable')) {
        $exists = $null -ne (Get-Item -LiteralPath $legacy[$key] -Force -ErrorAction SilentlyContinue)
        $state[$key] = $exists
        if ($exists) { $foundAny = $true }
    }
    if (-not $foundAny) { return New-DefaultState }
    return $state
}

function Get-CurrentModuleState {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return Get-LegacyInferredState }
    try { $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json }
    catch { throw "Composite manifest is invalid JSON: $($_.Exception.Message)" }
    if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex' -or [string]$manifest.artifact -cne 'hms-superpowers-composite') {
        throw "Composite manifest ownership mismatch: $ManifestPath"
    }
    $state = [ordered]@{}
    foreach ($key in @('hms', 'superpowers', 'taste', 'impeccable')) {
        $property = $manifest.modules.PSObject.Properties[$key]
        if ($null -eq $property) { throw "Composite manifest is missing module state '$key'." }
        $state[$key] = [bool]$property.Value
    }
    return $state
}

function Invoke-CompositeBuild {
    param(
        [Parameter(Mandatory)]$State,
        [string]$BuildOutputRoot = $OutputRoot,
        [string]$BuildSkillsRoot = $SkillsRoot
    )
    Assert-BuilderAvailable
    & $BuilderPath `
        -InstallRoot $RepoRoot `
        -OutputRoot $BuildOutputRoot `
        -SkillsRoot $BuildSkillsRoot `
        -Hms ([bool]$State.hms) `
        -Superpowers ([bool]$State.superpowers) `
        -Taste ([bool]$State.taste) `
        -Impeccable ([bool]$State.impeccable)
}

function Assert-OneSkillBundle {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$DiscoveryRoot,
        [Parameter(Mandatory)]$ExpectedState
    )
    $final = Join-Path $Root 'hms-superpowers'
    $manifestFile = Join-Path $final 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestFile)) { throw 'Composite manifest was not created.' }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    foreach ($key in @('hms', 'superpowers', 'taste', 'impeccable')) {
        if ([bool]$manifest.modules.$key -ne [bool]$ExpectedState[$key]) {
            throw "Composite manifest state mismatch for '$key'."
        }
    }

    $publicSkillFiles = @(Get-ChildItem -LiteralPath $final -Filter 'SKILL.md' -File -Recurse -ErrorAction Stop)
    if ($publicSkillFiles.Count -ne 1) {
        throw "Composite bundle must contain exactly one SKILL.md, found $($publicSkillFiles.Count)."
    }
    if ($publicSkillFiles[0].FullName -ne (Join-Path $final 'SKILL.md')) {
        throw 'The only SKILL.md must be the composite root entry point.'
    }

    $enabledCount = @($ExpectedState.Keys | Where-Object { [bool]$ExpectedState[$_] }).Count
    $link = Join-Path $DiscoveryRoot 'hms-superpowers'
    $linkItem = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($enabledCount -eq 0) {
        if ($null -ne $linkItem) { throw 'Composite discovery remained enabled when all modules were OFF.' }
    }
    else {
        if ($null -eq $linkItem) { throw 'Composite discovery was not created for enabled modules.' }
        if ([string]$linkItem.LinkType -ine 'Junction') { throw 'Composite discovery is not an exact Junction.' }
    }

    foreach ($legacyName in @('hms', 'superpowers', 'gpt-taste', 'impeccable')) {
        if ($null -ne (Get-Item -LiteralPath (Join-Path $DiscoveryRoot $legacyName) -Force -ErrorAction SilentlyContinue)) {
            throw "Legacy direct discovery path remained visible: $legacyName"
        }
    }
}

function Invoke-ManagerSelfTest {
    if ($env:OS -ne 'Windows_NT') { throw 'Manager self-test requires Windows.' }
    Assert-BuilderAvailable

    $root = Join-Path ([IO.Path]::GetTempPath()) ('hms-unified-manager-' + [guid]::NewGuid().ToString('N'))
    $testOutput = Join-Path $root 'composite'
    $testSkills = Join-Path $root 'agents\skills'
    try {
        $allOn = [ordered]@{ hms = $true; superpowers = $true; taste = $true; impeccable = $true }
        Invoke-CompositeBuild -State $allOn -BuildOutputRoot $testOutput -BuildSkillsRoot $testSkills
        Assert-OneSkillBundle -Root $testOutput -DiscoveryRoot $testSkills -ExpectedState $allOn

        $tasteOff = [ordered]@{ hms = $true; superpowers = $true; taste = $false; impeccable = $true }
        Invoke-CompositeBuild -State $tasteOff -BuildOutputRoot $testOutput -BuildSkillsRoot $testSkills
        Assert-OneSkillBundle -Root $testOutput -DiscoveryRoot $testSkills -ExpectedState $tasteOff
        if (Test-Path -LiteralPath (Join-Path $testOutput 'hms-superpowers\references\taste')) {
            throw 'Taste reference remained in the composite after Taste was disabled.'
        }

        $allOff = [ordered]@{ hms = $false; superpowers = $false; taste = $false; impeccable = $false }
        Invoke-CompositeBuild -State $allOff -BuildOutputRoot $testOutput -BuildSkillsRoot $testSkills
        Assert-OneSkillBundle -Root $testOutput -DiscoveryRoot $testSkills -ExpectedState $allOff

        Write-Host 'PASS: HMS Skills Manager compiled module selections into exactly one public hms-superpowers skill and preserved exclusive role routing.'
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

if ($SelfTest) {
    Invoke-ManagerSelfTest
    return
}

if ($env:OS -ne 'Windows_NT') { throw 'HMS Skills Manager UI is supported on Windows only.' }
Assert-BuilderAvailable

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HMS Unified Skill Manager'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(760, 610)
$form.MinimumSize = New-Object System.Drawing.Size(776, 649)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'HMS Unified Skill Manager'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.Location = New-Object System.Drawing.Point(26, 20)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Codex sees one public skill: $hms-superpowers. Switches below select internal modules.'
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(29, 61)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

$routeNote = New-Object System.Windows.Forms.Label
$routeNote.Text = 'Routing: HMS=governance | Superpowers=engineering | Taste=visual direction | Impeccable=UI polish'
$routeNote.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$routeNote.Location = New-Object System.Drawing.Point(29, 86)
$routeNote.AutoSize = $true
$form.Controls.Add($routeNote)

$checks = @{}
$top = 125
foreach ($module in $ModuleDefinitions) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(28, $top)
    $panel.Size = New-Object System.Drawing.Size(704, 72)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'

    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $module.Name
    $check.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $check.Location = New-Object System.Drawing.Point(16, 10)
    $check.AutoSize = $true
    $panel.Controls.Add($check)

    $role = New-Object System.Windows.Forms.Label
    $role.Text = $module.Role
    $role.ForeColor = [System.Drawing.Color]::DimGray
    $role.Location = New-Object System.Drawing.Point(38, 40)
    $role.AutoSize = $true
    $panel.Controls.Add($role)

    $form.Controls.Add($panel)
    $checks[$module.Key] = $check
    $top += 82
}

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(30, 465)
$status.Size = New-Object System.Drawing.Size(700, 28)
$status.ForeColor = [System.Drawing.Color]::FromArgb(30, 100, 60)
$form.Controls.Add($status)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = 'Apply + Rebuild'
$applyButton.Size = New-Object System.Drawing.Size(145, 42)
$applyButton.Location = New-Object System.Drawing.Point(28, 510)
$form.Controls.Add($applyButton)

$allOnButton = New-Object System.Windows.Forms.Button
$allOnButton.Text = 'Enable All'
$allOnButton.Size = New-Object System.Drawing.Size(120, 42)
$allOnButton.Location = New-Object System.Drawing.Point(183, 510)
$form.Controls.Add($allOnButton)

$allOffButton = New-Object System.Windows.Forms.Button
$allOffButton.Text = 'Disable All'
$allOffButton.Size = New-Object System.Drawing.Size(120, 42)
$allOffButton.Location = New-Object System.Drawing.Point(313, 510)
$form.Controls.Add($allOffButton)

$validateButton = New-Object System.Windows.Forms.Button
$validateButton.Text = 'Validate'
$validateButton.Size = New-Object System.Drawing.Size(120, 42)
$validateButton.Location = New-Object System.Drawing.Point(443, 510)
$form.Controls.Add($validateButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Size = New-Object System.Drawing.Size(159, 42)
$closeButton.Location = New-Object System.Drawing.Point(573, 510)
$form.Controls.Add($closeButton)

function Show-ManagerError {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, 'HMS Unified Skill Manager', 'OK', 'Error') | Out-Null
}

function Read-UiState {
    return [ordered]@{
        hms = [bool]$checks['hms'].Checked
        superpowers = [bool]$checks['superpowers'].Checked
        taste = [bool]$checks['taste'].Checked
        impeccable = [bool]$checks['impeccable'].Checked
    }
}

function Refresh-UiState {
    $state = Get-CurrentModuleState
    foreach ($key in @('hms', 'superpowers', 'taste', 'impeccable')) { $checks[$key].Checked = [bool]$state[$key] }
    $enabled = @($state.Keys | Where-Object { [bool]$state[$_] })
    if ($enabled.Count -eq 0) {
        $status.Text = 'Composite discovery: OFF - no module enabled.'
        $status.ForeColor = [System.Drawing.Color]::DimGray
    }
    else {
        $status.Text = 'Composite discovery: ON - modules: ' + ($enabled -join ', ')
        $status.ForeColor = [System.Drawing.Color]::FromArgb(30, 100, 60)
    }
}

function Apply-UiState {
    $desired = Read-UiState
    Invoke-CompositeBuild -State $desired
    Refresh-UiState
}

$applyButton.Add_Click({
    try { Apply-UiState }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$allOnButton.Add_Click({
    try {
        foreach ($key in @('hms', 'superpowers', 'taste', 'impeccable')) { $checks[$key].Checked = $true }
        Apply-UiState
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$allOffButton.Add_Click({
    try {
        foreach ($key in @('hms', 'superpowers', 'taste', 'impeccable')) { $checks[$key].Checked = $false }
        Apply-UiState
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$validateButton.Add_Click({
    try {
        & (Join-Path $RepoRoot 'scripts\Test-HmsSkills.ps1')
        $state = Get-CurrentModuleState
        Invoke-CompositeBuild -State $state
        Assert-OneSkillBundle -Root $OutputRoot -DiscoveryRoot $SkillsRoot -ExpectedState $state
        [System.Windows.Forms.MessageBox]::Show('PASS: one public skill and module routing contract validated.', 'HMS Unified Skill Manager', 'OK', 'Information') | Out-Null
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$closeButton.Add_Click({ $form.Close() })
Refresh-UiState
[void]$form.ShowDialog()
