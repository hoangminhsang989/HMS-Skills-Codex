[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$HmsLink = Join-Path $SkillsRoot 'hms'
$HmsTarget = Join-Path $RepoRoot 'skills'
$SuperpowersRoot = Join-Path $env:USERPROFILE '.codex\superpowers'
$SuperpowersLink = Join-Path $SkillsRoot 'superpowers'
$SuperpowersTarget = Join-Path $SuperpowersRoot 'skills'

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    return $resolved.Path.TrimEnd('\')
}

function Get-ManagedJunctionState {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )

    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [pscustomobject]@{ State = 'Disabled'; Detail = 'Discovery junction is absent.' }
    }

    if (-not [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return [pscustomobject]@{ State = 'Conflict'; Detail = "Existing path is not a reparse point: $Link" }
    }

    if (-not (Test-Path -LiteralPath $Target)) {
        return [pscustomobject]@{ State = 'Conflict'; Detail = "Expected target is missing: $Target" }
    }

    $expected = Get-CanonicalPath -Path $Target
    $targets = @($item.Target)
    foreach ($candidate in $targets) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            $actual = Get-CanonicalPath -Path ([string]$candidate)
            if ($actual -ieq $expected) {
                return [pscustomobject]@{ State = 'Enabled'; Detail = "Junction targets $expected" }
            }
        }
        catch {
            # A broken or unreadable reparse target is a conflict, never an OFF state.
        }
    }

    return [pscustomobject]@{ State = 'Conflict'; Detail = "Existing reparse point does not target the managed path: $Link" }
}

function Assert-ManagedStateChangeAllowed {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][bool]$Enable
    )

    $state = Get-ManagedJunctionState -Link $Link -Target $Target
    if ($state.State -eq 'Conflict') {
        throw $state.Detail
    }
    if ($Enable -and -not (Test-Path -LiteralPath $Target)) {
        throw "Cannot enable discovery because the target does not exist: $Target"
    }
    return $state
}

function Remove-ManagedJunction {
    param([Parameter(Mandatory)][string]$Link)

    & $env:ComSpec /d /c "rmdir `"$Link`""
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove managed junction: $Link"
    }
    if (Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue) {
        throw "Managed junction still exists after removal: $Link"
    }
}

function Set-ManagedJunctionEnabled {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][bool]$Enable
    )

    $state = Assert-ManagedStateChangeAllowed -Link $Link -Target $Target -Enable $Enable

    if ($Enable) {
        if ($state.State -eq 'Enabled') { return }
        $parent = Split-Path -Parent $Link
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
        $after = Get-ManagedJunctionState -Link $Link -Target $Target
        if ($after.State -ne 'Enabled') {
            throw "Junction enable verification failed for $Link : $($after.Detail)"
        }
        return
    }

    if ($state.State -eq 'Disabled') { return }
    Remove-ManagedJunction -Link $Link
    $after = Get-ManagedJunctionState -Link $Link -Target $Target
    if ($after.State -ne 'Disabled') {
        throw "Junction disable verification failed for $Link : $($after.Detail)"
    }
}

function Set-BothManagedJunctions {
    param([Parameter(Mandatory)][bool]$Enable)

    # Preflight every path before making the first mutation.
    $hmsBefore = Assert-ManagedStateChangeAllowed -Link $HmsLink -Target $HmsTarget -Enable $Enable
    $superBefore = Assert-ManagedStateChangeAllowed -Link $SuperpowersLink -Target $SuperpowersTarget -Enable $Enable

    $hmsWasEnabled = $hmsBefore.State -eq 'Enabled'
    $superWasEnabled = $superBefore.State -eq 'Enabled'

    try {
        Set-ManagedJunctionEnabled -Link $HmsLink -Target $HmsTarget -Enable $Enable
        Set-ManagedJunctionEnabled -Link $SuperpowersLink -Target $SuperpowersTarget -Enable $Enable
    }
    catch {
        $originalError = $_
        try {
            Set-ManagedJunctionEnabled -Link $HmsLink -Target $HmsTarget -Enable $hmsWasEnabled
            Set-ManagedJunctionEnabled -Link $SuperpowersLink -Target $SuperpowersTarget -Enable $superWasEnabled
        }
        catch {
            throw "State change failed and rollback was incomplete. Original error: $($originalError.Exception.Message). Rollback error: $($_.Exception.Message)"
        }
        throw $originalError
    }
}

function Invoke-ManagerSelfTest {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Manager self-test requires Windows because it verifies NTFS junction behavior.'
    }

    $root = Join-Path ([IO.Path]::GetTempPath()) ("hms-manager-selftest-" + [guid]::NewGuid().ToString('N'))
    $agents = Join-Path $root 'agents\skills'
    $target = Join-Path $root 'repo\skills'
    $link = Join-Path $agents 'hms'
    $marker = Join-Path $target 'marker.txt'

    try {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Set-Content -LiteralPath $marker -Value 'preserve-me'

        $initial = Get-ManagedJunctionState -Link $link -Target $target
        if ($initial.State -ne 'Disabled') { throw "Expected Disabled initial state, found $($initial.State)." }

        Set-ManagedJunctionEnabled -Link $link -Target $target -Enable $true
        $enabled = Get-ManagedJunctionState -Link $link -Target $target
        if ($enabled.State -ne 'Enabled') { throw "Expected Enabled state, found $($enabled.State)." }

        Set-ManagedJunctionEnabled -Link $link -Target $target -Enable $false
        $disabled = Get-ManagedJunctionState -Link $link -Target $target
        if ($disabled.State -ne 'Disabled') { throw "Expected Disabled state after OFF, found $($disabled.State)." }
        if (-not (Test-Path -LiteralPath $marker)) { throw 'OFF removed data from the junction target.' }

        New-Item -ItemType Directory -Force -Path $link | Out-Null
        $conflict = Get-ManagedJunctionState -Link $link -Target $target
        if ($conflict.State -ne 'Conflict') { throw "Expected Conflict state, found $($conflict.State)." }
        $blocked = $false
        try {
            Set-ManagedJunctionEnabled -Link $link -Target $target -Enable $true
        }
        catch {
            $blocked = $true
        }
        if (-not $blocked) { throw 'Conflict path was incorrectly overwritten.' }

        Write-Host 'PASS: HMS Superpowers Manager self-test verified enable, disable, target preservation, and conflict fail-closed behavior.'
    }
    finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

if ($SelfTest) {
    Invoke-ManagerSelfTest
    return
}

if ($env:OS -ne 'Windows_NT') {
    throw 'HMS Superpowers Manager UI is supported on Windows only.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HMS Superpowers Manager'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(560, 390)
$form.MinimumSize = New-Object System.Drawing.Size(576, 429)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'HMS Superpowers Manager'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$title.Location = New-Object System.Drawing.Point(24, 20)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Bật/tắt discovery cho Codex. OFF không xóa repo hoặc dữ liệu skill.'
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(27, 58)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

function New-StatusCard {
    param(
        [string]$Name,
        [int]$Top
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(24, $Top)
    $panel.Size = New-Object System.Drawing.Size(512, 80)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = $Name
    $nameLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $nameLabel.Location = New-Object System.Drawing.Point(16, 13)
    $nameLabel.AutoSize = $true
    $panel.Controls.Add($nameLabel)

    $stateLabel = New-Object System.Windows.Forms.Label
    $stateLabel.Text = 'Checking...'
    $stateLabel.Location = New-Object System.Drawing.Point(17, 43)
    $stateLabel.AutoSize = $true
    $panel.Controls.Add($stateLabel)

    $toggle = New-Object System.Windows.Forms.Button
    $toggle.Text = '...'
    $toggle.Size = New-Object System.Drawing.Size(100, 38)
    $toggle.Location = New-Object System.Drawing.Point(394, 20)
    $panel.Controls.Add($toggle)

    $form.Controls.Add($panel)
    return [pscustomobject]@{ Panel = $panel; State = $stateLabel; Toggle = $toggle }
}

$hmsCard = New-StatusCard -Name 'HMS Superpowers' -Top 92
$superCard = New-StatusCard -Name 'Upstream Superpowers' -Top 182

$masterButton = New-Object System.Windows.Forms.Button
$masterButton.Text = 'BẬT CẢ HAI'
$masterButton.Size = New-Object System.Drawing.Size(160, 42)
$masterButton.Location = New-Object System.Drawing.Point(24, 286)
$form.Controls.Add($masterButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Làm mới'
$refreshButton.Size = New-Object System.Drawing.Size(100, 42)
$refreshButton.Location = New-Object System.Drawing.Point(196, 286)
$form.Controls.Add($refreshButton)

$validateButton = New-Object System.Windows.Forms.Button
$validateButton.Text = 'Validate'
$validateButton.Size = New-Object System.Drawing.Size(100, 42)
$validateButton.Location = New-Object System.Drawing.Point(306, 286)
$form.Controls.Add($validateButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Đóng'
$closeButton.Size = New-Object System.Drawing.Size(120, 42)
$closeButton.Location = New-Object System.Drawing.Point(416, 286)
$form.Controls.Add($closeButton)

$note = New-Object System.Windows.Forms.Label
$note.Text = 'Sau khi đổi trạng thái, hãy restart/refresh Codex để session đang chạy cập nhật discovery.'
$note.ForeColor = [System.Drawing.Color]::DimGray
$note.Location = New-Object System.Drawing.Point(26, 344)
$note.AutoSize = $true
$form.Controls.Add($note)

function Set-CardVisual {
    param(
        $Card,
        [string]$State,
        [string]$Detail
    )

    switch ($State) {
        'Enabled' {
            $Card.State.Text = 'ON — Đã bật'
            $Card.State.ForeColor = [System.Drawing.Color]::FromArgb(22, 130, 74)
            $Card.Toggle.Text = 'TẮT'
            $Card.Toggle.BackColor = [System.Drawing.Color]::FromArgb(230, 238, 234)
            $Card.Toggle.Enabled = $true
        }
        'Disabled' {
            $Card.State.Text = 'OFF — Đã tắt'
            $Card.State.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
            $Card.Toggle.Text = 'BẬT'
            $Card.Toggle.BackColor = [System.Drawing.Color]::FromArgb(222, 238, 255)
            $Card.Toggle.Enabled = $true
        }
        default {
            $Card.State.Text = 'CONFLICT — Không tự sửa'
            $Card.State.ForeColor = [System.Drawing.Color]::Firebrick
            $Card.Toggle.Text = 'BỊ CHẶN'
            $Card.Toggle.BackColor = [System.Drawing.Color]::MistyRose
            $Card.Toggle.Enabled = $false
            $Card.Toggle.Tag = $Detail
        }
    }
}

function Refresh-UiState {
    $hms = Get-ManagedJunctionState -Link $HmsLink -Target $HmsTarget
    $super = Get-ManagedJunctionState -Link $SuperpowersLink -Target $SuperpowersTarget
    Set-CardVisual -Card $hmsCard -State $hms.State -Detail $hms.Detail
    Set-CardVisual -Card $superCard -State $super.State -Detail $super.Detail

    if ($hms.State -eq 'Conflict' -or $super.State -eq 'Conflict') {
        $masterButton.Text = 'CONFLICT'
        $masterButton.Enabled = $false
        $masterButton.BackColor = [System.Drawing.Color]::MistyRose
        return
    }

    $masterButton.Enabled = $true
    if ($hms.State -eq 'Enabled' -and $super.State -eq 'Enabled') {
        $masterButton.Text = 'TẮT CẢ HAI'
        $masterButton.Tag = $false
    }
    else {
        $masterButton.Text = 'BẬT CẢ HAI'
        $masterButton.Tag = $true
    }
}

function Show-ManagerError {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, 'HMS Superpowers Manager', 'OK', 'Error') | Out-Null
}

$hmsCard.Toggle.Add_Click({
    try {
        $state = Get-ManagedJunctionState -Link $HmsLink -Target $HmsTarget
        Set-ManagedJunctionEnabled -Link $HmsLink -Target $HmsTarget -Enable ($state.State -eq 'Disabled')
        Refresh-UiState
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$superCard.Toggle.Add_Click({
    try {
        $state = Get-ManagedJunctionState -Link $SuperpowersLink -Target $SuperpowersTarget
        Set-ManagedJunctionEnabled -Link $SuperpowersLink -Target $SuperpowersTarget -Enable ($state.State -eq 'Disabled')
        Refresh-UiState
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$masterButton.Add_Click({
    try {
        Set-BothManagedJunctions -Enable ([bool]$masterButton.Tag)
        Refresh-UiState
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$refreshButton.Add_Click({ Refresh-UiState })

$validateButton.Add_Click({
    try {
        & (Join-Path $RepoRoot 'scripts\Test-HmsSkills.ps1')
        [System.Windows.Forms.MessageBox]::Show('Validation PASS.', 'HMS Superpowers Manager', 'OK', 'Information') | Out-Null
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$closeButton.Add_Click({ $form.Close() })
$form.Add_Shown({ Refresh-UiState })

[void]$form.ShowDialog()
