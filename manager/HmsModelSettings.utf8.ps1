[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ResolverPath = Join-Path $RepoRoot 'scripts\Resolve-HmsModelRoute.ps1'
$SettingsRoot = Join-Path $env:USERPROFILE '.codex\hms-composite'
$SettingsPath = Join-Path $SettingsRoot 'model-settings.json'

$ModelDefinitions = @(
    [pscustomobject]@{
        Key = 'luna'
        Name = 'GPT-5.6 Luna'
        Role = 'Low-risk deterministic and high-volume mechanical work'
        DescriptionVi = 'Việc cơ học, lặp lại, read-only/housekeeping hoặc chỉnh sửa rất hẹp; Luna chỉ chạy ở mức reasoning cao nhất runtime cho phép.'
    },
    [pscustomobject]@{
        Key = 'terra'
        Name = 'GPT-5.6 Terra'
        Role = 'Normal work, implementation, and ordinary debugging'
        DescriptionVi = 'Công việc phát triển bình thường; Terra medium cho việc thường, Terra high cho implementation/debug không tầm thường.'
    },
    [pscustomobject]@{
        Key = 'sol'
        Name = 'GPT-5.6 Sol'
        Role = 'Complex work, architecture/security/migration, critical and final gates'
        DescriptionVi = 'Công việc phức tạp; Sol high cho complex work, xhigh cho architecture/security/migration, max cho blocker/release/final review.'
    }
)

function Assert-ResolverAvailable {
    if (-not (Test-Path -LiteralPath $ResolverPath)) { throw "Model resolver is missing: $ResolverPath" }
}

function New-DefaultModelState {
    return [ordered]@{ luna=$true; terra=$true; sol=$true }
}

function Convert-StateToSettingsObject {
    param([Parameter(Mandatory)]$State)
    return [ordered]@{
        schema_version = 1
        managed_by = 'HMS-Skills-Codex'
        artifact = 'hms-model-settings'
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        models = [ordered]@{
            luna = [bool]$State.luna
            terra = [bool]$State.terra
            sol = [bool]$State.sol
        }
    }
}

function Read-ModelState {
    param([string]$Path = $SettingsPath)

    if (-not (Test-Path -LiteralPath $Path)) { return New-DefaultModelState }

    try { $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Model settings are invalid JSON: $($_.Exception.Message)" }

    if ([int]$settings.schema_version -ne 1) { throw "Unsupported model settings schema_version: $($settings.schema_version)" }
    if ([string]$settings.managed_by -cne 'HMS-Skills-Codex') { throw 'Model settings ownership mismatch.' }
    if ([string]$settings.artifact -cne 'hms-model-settings') { throw 'Model settings artifact mismatch.' }
    if ($null -eq $settings.models) { throw 'Model settings are missing models.' }

    $state = [ordered]@{}
    foreach ($key in @('luna','terra','sol')) {
        $property = $settings.models.PSObject.Properties[$key]
        if ($null -eq $property) { throw "Model settings are missing '$key'." }
        if ($property.Value -isnot [bool]) { throw "Model setting '$key' must be boolean." }
        $state[$key] = [bool]$property.Value
    }
    return $state
}

function Write-ModelState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$Path = $SettingsPath
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    $settings = Convert-StateToSettingsObject -State $State
    $json = $settings | ConvertTo-Json -Depth 6
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $temp = Join-Path $parent ('.model-settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.model-settings-' + [guid]::NewGuid().ToString('N') + '.bak')

    try {
        [IO.File]::WriteAllText($temp, $json, $utf8)
        $null = Read-ModelState -Path $temp

        $hadExisting = Test-Path -LiteralPath $Path
        if ($hadExisting) { Move-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop }

        try {
            Move-Item -LiteralPath $temp -Destination $Path -ErrorAction Stop
            $verified = Read-ModelState -Path $Path
            foreach ($key in @('luna','terra','sol')) {
                if ([bool]$verified[$key] -ne [bool]$State[$key]) { throw "Model setting verification mismatch for '$key'." }
            }
        }
        catch {
            $writeError = $_
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $Path -ErrorAction Stop }
            throw $writeError
        }

        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Resolve-Route {
    param(
        [Parameter(Mandatory)][string]$RiskClass,
        [string]$Path = $SettingsPath
    )
    Assert-ResolverAvailable
    return & $ResolverPath -RiskClass $RiskClass -SettingsPath $Path
}

function Invoke-ModelSettingsSelfTest {
    Assert-ResolverAvailable

    foreach ($definition in $ModelDefinitions) {
        if ([string]::IsNullOrWhiteSpace($definition.DescriptionVi)) { throw "Missing Vietnamese description for model '$($definition.Key)'." }
    }

    $root = Join-Path ([IO.Path]::GetTempPath()) ('hms-model-settings-' + [guid]::NewGuid().ToString('N'))
    $path = Join-Path $root 'model-settings.json'
    try {
        New-Item -ItemType Directory -Force -Path $root | Out-Null

        $allOn = [ordered]@{ luna=$true; terra=$true; sol=$true }
        Write-ModelState -State $allOn -Path $path
        $normal = Resolve-Route -RiskClass 'NORMAL_WORK' -Path $path
        if ($normal.status -cne 'ASSIGNED' -or $normal.assigned_model -cne 'gpt-5.6-terra' -or [bool]$normal.reassigned) {
            throw 'All-ON routing did not assign NORMAL_WORK to Terra.'
        }

        $lunaOff = [ordered]@{ luna=$false; terra=$true; sol=$true }
        Write-ModelState -State $lunaOff -Path $path
        $fast = Resolve-Route -RiskClass 'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL' -Path $path
        if ($fast.status -cne 'ASSIGNED' -or $fast.assigned_model -cne 'gpt-5.6-terra' -or -not [bool]$fast.reassigned) {
            throw 'Luna-OFF routing did not safely reassign low-risk work to Terra.'
        }

        $terraOff = [ordered]@{ luna=$true; terra=$false; sol=$true }
        Write-ModelState -State $terraOff -Path $path
        $moderate = Resolve-Route -RiskClass 'MODERATE_DEBUG_OR_IMPLEMENTATION' -Path $path
        if ($moderate.status -cne 'ASSIGNED' -or $moderate.assigned_model -cne 'gpt-5.6-sol' -or -not [bool]$moderate.reassigned) {
            throw 'Terra-OFF routing did not safely reassign moderate work to Sol.'
        }

        $solOff = [ordered]@{ luna=$true; terra=$true; sol=$false }
        Write-ModelState -State $solOff -Path $path
        $architecture = Resolve-Route -RiskClass 'ARCHITECTURE_SECURITY_MIGRATION' -Path $path
        if ($architecture.status -cne 'BLOCKED' -or $architecture.reason -cne 'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR') {
            throw 'Sol-OFF routing did not fail closed for Sol-required architecture work.'
        }

        $allOff = [ordered]@{ luna=$false; terra=$false; sol=$false }
        Write-ModelState -State $allOff -Path $path
        $blocked = Resolve-Route -RiskClass 'NORMAL_WORK' -Path $path
        if ($blocked.status -cne 'BLOCKED' -or $blocked.reason -cne 'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR') {
            throw 'All-OFF routing did not block model-routed work.'
        }

        Write-Host 'PASS: HMS Model Settings verified ON/OFF persistence, Luna->Terra fallback, Terra->Sol fallback, and fail-closed Sol-required routing.'
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

if ($SelfTest) {
    Invoke-ModelSettingsSelfTest
    return
}

if ($env:OS -ne 'Windows_NT') { throw 'HMS Model Settings UI is supported on Windows only.' }
Assert-ResolverAvailable

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HMS Model Settings'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(760, 570)
$form.MinimumSize = New-Object System.Drawing.Size(776, 609)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'HMS Model Settings'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.Location = New-Object System.Drawing.Point(26, 20)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Choose which GPT-5.6 models may receive HMS task slices.'
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(29, 61)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

$fallback = New-Object System.Windows.Forms.Label
$fallback.Text = 'Fallback: Luna OFF -> Terra -> Sol | Terra OFF -> Sol | Sol-required work with Sol OFF -> BLOCKED'
$fallback.ForeColor = [System.Drawing.Color]::FromArgb(90, 60, 20)
$fallback.Location = New-Object System.Drawing.Point(29, 86)
$fallback.AutoSize = $true
$form.Controls.Add($fallback)

$checks = @{}
$top = 122
foreach ($model in $ModelDefinitions) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(28, $top)
    $panel.Size = New-Object System.Drawing.Size(704, 102)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'

    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $model.Name
    $check.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $check.Location = New-Object System.Drawing.Point(16, 10)
    $check.AutoSize = $true
    $panel.Controls.Add($check)

    $role = New-Object System.Windows.Forms.Label
    $role.Text = $model.Role
    $role.ForeColor = [System.Drawing.Color]::DimGray
    $role.Location = New-Object System.Drawing.Point(38, 39)
    $role.AutoSize = $true
    $panel.Controls.Add($role)

    $vi = New-Object System.Windows.Forms.Label
    $vi.Text = 'Tiếng Việt: ' + $model.DescriptionVi
    $vi.ForeColor = [System.Drawing.Color]::FromArgb(50, 70, 95)
    $vi.Location = New-Object System.Drawing.Point(38, 63)
    $vi.Size = New-Object System.Drawing.Size(640, 34)
    $panel.Controls.Add($vi)

    $form.Controls.Add($panel)
    $checks[$model.Key] = $check
    $top += 112
}

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(30, 465)
$status.Size = New-Object System.Drawing.Size(700, 30)
$status.ForeColor = [System.Drawing.Color]::FromArgb(30, 100, 60)
$form.Controls.Add($status)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Save'
$saveButton.Size = New-Object System.Drawing.Size(105, 42)
$saveButton.Location = New-Object System.Drawing.Point(28, 510)
$form.Controls.Add($saveButton)

$allOnButton = New-Object System.Windows.Forms.Button
$allOnButton.Text = 'Enable All'
$allOnButton.Size = New-Object System.Drawing.Size(115, 42)
$allOnButton.Location = New-Object System.Drawing.Point(143, 510)
$form.Controls.Add($allOnButton)

$allOffButton = New-Object System.Windows.Forms.Button
$allOffButton.Text = 'Disable All'
$allOffButton.Size = New-Object System.Drawing.Size(115, 42)
$allOffButton.Location = New-Object System.Drawing.Point(268, 510)
$form.Controls.Add($allOffButton)

$testButton = New-Object System.Windows.Forms.Button
$testButton.Text = 'Test Routing'
$testButton.Size = New-Object System.Drawing.Size(130, 42)
$testButton.Location = New-Object System.Drawing.Point(393, 510)
$form.Controls.Add($testButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Size = New-Object System.Drawing.Size(199, 42)
$closeButton.Location = New-Object System.Drawing.Point(533, 510)
$form.Controls.Add($closeButton)

function Show-ModelError {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, 'HMS Model Settings', 'OK', 'Error') | Out-Null
}

function Read-UiState {
    return [ordered]@{
        luna = [bool]$checks['luna'].Checked
        terra = [bool]$checks['terra'].Checked
        sol = [bool]$checks['sol'].Checked
    }
}

function Refresh-UiState {
    $state = Read-ModelState
    foreach ($key in @('luna','terra','sol')) { $checks[$key].Checked = [bool]$state[$key] }
    $enabled = @($state.Keys | Where-Object { [bool]$state[$_] })
    if ($enabled.Count -eq 0) {
        $status.Text = 'Model pool: OFF - no model can receive routed HMS work.'
        $status.ForeColor = [System.Drawing.Color]::DarkRed
    }
    else {
        $status.Text = 'Model pool: ON - enabled: ' + ($enabled -join ', ')
        $status.ForeColor = [System.Drawing.Color]::FromArgb(30, 100, 60)
    }
}

function Save-UiState {
    $state = Read-UiState
    Write-ModelState -State $state
    Refresh-UiState
}

$saveButton.Add_Click({
    try { Save-UiState }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$allOnButton.Add_Click({
    try {
        foreach ($key in @('luna','terra','sol')) { $checks[$key].Checked = $true }
        Save-UiState
    }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$allOffButton.Add_Click({
    try {
        foreach ($key in @('luna','terra','sol')) { $checks[$key].Checked = $false }
        Save-UiState
    }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$testButton.Add_Click({
    try {
        Save-UiState
        $classes = @(
            'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL',
            'NORMAL_WORK',
            'MODERATE_DEBUG_OR_IMPLEMENTATION',
            'COMPLEX_WORK',
            'ARCHITECTURE_SECURITY_MIGRATION',
            'CRITICAL_BLOCKER_RELEASE_GATE',
            'FINAL_STAGE_REVIEW'
        )
        $lines = @()
        foreach ($class in $classes) {
            $route = Resolve-Route -RiskClass $class
            if ($route.status -ceq 'ASSIGNED') {
                $lines += ($class + ' -> ' + $route.assigned_model + ' / ' + $route.effort)
            }
            else {
                $lines += ($class + ' -> BLOCKED (' + $route.required_floor + ')')
            }
        }
        [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'HMS Model Routing Test', 'OK', 'Information') | Out-Null
    }
    catch { Show-ModelError -Message $_.Exception.Message }
})

$closeButton.Add_Click({ $form.Close() })
Refresh-UiState
[void]$form.ShowDialog()
