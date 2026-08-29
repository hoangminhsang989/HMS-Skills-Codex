[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SkillsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$UiLockPath = Join-Path $RepoRoot 'ui-skills.lock.json'

function Read-UiSkillsLock {
    if (-not (Test-Path -LiteralPath $UiLockPath)) {
        throw "UI skills lock file not found: $UiLockPath"
    }
    try {
        $lock = Get-Content -LiteralPath $UiLockPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "UI skills lock file is invalid JSON: $($_.Exception.Message)"
    }

    $expected = @{
        taste = @{
            Repository = 'https://github.com/Leonxlnx/taste-skill.git'
            SkillName = 'gpt-taste'
            SkillPath = 'skills/gpt-tasteskill'
        }
        impeccable = @{
            Repository = 'https://github.com/pbakaus/impeccable.git'
            SkillName = 'impeccable'
            SkillPath = '.agents/skills/impeccable'
        }
    }

    foreach ($key in @('taste', 'impeccable')) {
        $entry = $lock.$key
        if ($null -eq $entry) { throw "Missing '$key' entry in ui-skills.lock.json" }
        if ([string]$entry.repository -cne $expected[$key].Repository) {
            throw "Unexpected $key repository in UI skills lock: $($entry.repository)"
        }
        if ([string]$entry.skill_name -cne $expected[$key].SkillName) {
            throw "Unexpected $key skill name in UI skills lock: $($entry.skill_name)"
        }
        if ([string]$entry.skill_path -cne $expected[$key].SkillPath) {
            throw "Unexpected $key skill path in UI skills lock: $($entry.skill_path)"
        }
        if ([string]$entry.commit -notmatch '^[0-9a-f]{40}$') {
            throw "Invalid $key pinned commit in UI skills lock: $($entry.commit)"
        }
    }
    return $lock
}

$UiLock = Read-UiSkillsLock
$HmsTarget = Join-Path $RepoRoot 'skills'
$SuperpowersRoot = Join-Path $env:USERPROFILE '.codex\superpowers'
$TasteRoot = Join-Path $env:USERPROFILE '.codex\taste-skill'
$ImpeccableRoot = Join-Path $env:USERPROFILE '.codex\impeccable'

$ManagedEntries = @(
    [pscustomobject]@{ Key = 'hms'; Name = 'HMS Superpowers'; Link = (Join-Path $SkillsRoot 'hms'); Target = $HmsTarget },
    [pscustomobject]@{ Key = 'superpowers'; Name = 'Upstream Superpowers'; Link = (Join-Path $SkillsRoot 'superpowers'); Target = (Join-Path $SuperpowersRoot 'skills') },
    [pscustomobject]@{ Key = 'taste'; Name = 'GPT Taste'; Link = (Join-Path $SkillsRoot 'gpt-taste'); Target = (Join-Path $TasteRoot ([string]$UiLock.taste.skill_path)) },
    [pscustomobject]@{ Key = 'impeccable'; Name = 'Impeccable'; Link = (Join-Path $SkillsRoot 'impeccable'); Target = (Join-Path $ImpeccableRoot ([string]$UiLock.impeccable.skill_path)) }
)

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\')
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

    $linkTypeProperty = $item.PSObject.Properties['LinkType']
    $linkType = if ($null -eq $linkTypeProperty) { '' } else { [string]$item.LinkType }
    if ($linkType -ine 'Junction') {
        return [pscustomobject]@{ State = 'Conflict'; Detail = "Existing reparse point is not the managed Junction type: $Link (LinkType='$linkType')" }
    }

    if (-not (Test-Path -LiteralPath $Target)) {
        return [pscustomobject]@{ State = 'Conflict'; Detail = "Expected target is missing: $Target" }
    }

    $expected = Get-CanonicalPath -Path $Target
    foreach ($candidate in @($item.Target)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            if ((Get-CanonicalPath -Path ([string]$candidate)) -ieq $expected) {
                return [pscustomobject]@{ State = 'Enabled'; Detail = "Junction targets $expected" }
            }
        }
        catch { }
    }
    return [pscustomobject]@{ State = 'Conflict'; Detail = "Existing Junction does not target the managed path: $Link" }
}

function Assert-ManagedStateChangeAllowed {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][bool]$Enable
    )

    $state = Get-ManagedJunctionState -Link $Link -Target $Target
    if ($state.State -eq 'Conflict') { throw $state.Detail }
    if ($Enable -and -not (Test-Path -LiteralPath $Target)) {
        throw "Cannot enable discovery because the target does not exist: $Target"
    }
    return $state
}

function Restore-QuarantinedPath {
    param(
        [Parameter(Mandatory)][string]$Original,
        [Parameter(Mandatory)][string]$Quarantine
    )

    $quarantineItem = Get-Item -LiteralPath $Quarantine -Force -ErrorAction SilentlyContinue
    if ($null -eq $quarantineItem) { return }
    if ($null -ne (Get-Item -LiteralPath $Original -Force -ErrorAction SilentlyContinue)) {
        throw "Cannot restore quarantined path because the original path is occupied: $Original"
    }
    Rename-Item -LiteralPath $Quarantine -NewName (Split-Path -Leaf $Original) -ErrorAction Stop
}

function Remove-ManagedJunction {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )

    # Revalidate identity at the destructive boundary. Never trust an earlier pathname check.
    $boundary = Get-ManagedJunctionState -Link $Link -Target $Target
    if ($boundary.State -ne 'Enabled') {
        throw "Refusing destructive removal because junction identity is not currently managed: $Link : $($boundary.Detail)"
    }

    # Rename the exact entry to an unpredictable same-directory quarantine name first.
    # If a path substitution happened before this rename, the quarantined object is
    # revalidated and restored instead of being deleted.
    $parent = Split-Path -Parent $Link
    $quarantineLeaf = '.hms-removing-' + [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent $quarantineLeaf
    if ($null -ne (Get-Item -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue)) {
        throw "Unexpected quarantine collision: $quarantine"
    }

    try {
        Rename-Item -LiteralPath $Link -NewName $quarantineLeaf -ErrorAction Stop
    }
    catch {
        throw "Failed to quarantine managed junction before removal: $Link : $($_.Exception.Message)"
    }

    $quarantinedState = Get-ManagedJunctionState -Link $quarantine -Target $Target
    if ($quarantinedState.State -ne 'Enabled') {
        try {
            Restore-QuarantinedPath -Original $Link -Quarantine $quarantine
        }
        catch {
            throw "Quarantined path failed managed-junction revalidation and rollback was incomplete. State: $($quarantinedState.Detail). Rollback error: $($_.Exception.Message)"
        }
        throw "Quarantined path failed managed-junction revalidation; deletion refused and original path restored: $Link : $($quarantinedState.Detail)"
    }

    # Revalidate once more immediately before the only destructive call. The random
    # quarantine name also removes the original public pathname from the delete target.
    $finalBoundary = Get-ManagedJunctionState -Link $quarantine -Target $Target
    if ($finalBoundary.State -ne 'Enabled') {
        try {
            Restore-QuarantinedPath -Original $Link -Quarantine $quarantine
        }
        catch {
            throw "Final destructive-boundary revalidation failed and rollback was incomplete. State: $($finalBoundary.Detail). Rollback error: $($_.Exception.Message)"
        }
        throw "Final destructive-boundary revalidation failed; deletion refused and original path restored: $Link : $($finalBoundary.Detail)"
    }

    & $env:ComSpec /d /c "rmdir `"$quarantine`""
    if ($LASTEXITCODE -ne 0) {
        $removeExit = $LASTEXITCODE
        try {
            Restore-QuarantinedPath -Original $Link -Quarantine $quarantine
        }
        catch {
            throw "Managed junction removal failed with exit code $removeExit and rollback was incomplete: $($_.Exception.Message)"
        }
        throw "Managed junction removal failed with exit code $removeExit; original path restored: $Link"
    }
    if ($null -ne (Get-Item -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue)) {
        throw "Quarantined managed junction still exists after removal: $quarantine"
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
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Link) | Out-Null
        New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
        $after = Get-ManagedJunctionState -Link $Link -Target $Target
        if ($after.State -ne 'Enabled') { throw "Junction enable verification failed for $Link : $($after.Detail)" }
        return
    }

    if ($state.State -eq 'Disabled') { return }
    Remove-ManagedJunction -Link $Link -Target $Target
    $after = Get-ManagedJunctionState -Link $Link -Target $Target
    if ($after.State -ne 'Disabled') { throw "Junction disable verification failed for $Link : $($after.Detail)" }
}

function Set-ManagedGroupState {
    param(
        [Parameter(Mandatory)]$Entries,
        [Parameter(Mandatory)][bool]$Enable
    )

    $before = @{}
    foreach ($entry in @($Entries)) {
        $state = Assert-ManagedStateChangeAllowed -Link $entry.Link -Target $entry.Target -Enable $Enable
        $before[$entry.Key] = ($state.State -eq 'Enabled')
    }

    try {
        foreach ($entry in @($Entries)) {
            Set-ManagedJunctionEnabled -Link $entry.Link -Target $entry.Target -Enable $Enable
        }
    }
    catch {
        $originalError = $_
        try {
            foreach ($entry in @($Entries)) {
                Set-ManagedJunctionEnabled -Link $entry.Link -Target $entry.Target -Enable ([bool]$before[$entry.Key])
            }
        }
        catch {
            throw "State change failed and rollback was incomplete. Original error: $($originalError.Exception.Message). Rollback error: $($_.Exception.Message)"
        }
        throw $originalError
    }
}

function Assert-PinnedRepoIdentity {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$SkillPath
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { throw "Pinned repository is not installed: $Root" }
    $head = (& git -C $Root rev-parse HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -ne $ExpectedCommit) {
        throw "Pinned repository identity mismatch for $Root. Expected $ExpectedCommit, found $head"
    }
    $skillFile = Join-Path (Join-Path $Root $SkillPath) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile)) { throw "Pinned skill entry point missing: $skillFile" }
}

function Invoke-ManagerSelfTest {
    if ($env:OS -ne 'Windows_NT') { throw 'Manager self-test requires Windows because it verifies NTFS junction behavior.' }

    $root = Join-Path ([IO.Path]::GetTempPath()) ("hms-manager-selftest-" + [guid]::NewGuid().ToString('N'))
    $entries = @()
    try {
        foreach ($key in @('hms', 'superpowers', 'taste', 'impeccable')) {
            $target = Join-Path $root "targets\$key"
            $link = Join-Path $root "agents\skills\$key"
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'marker.txt') -Value "preserve-$key"
            $entries += [pscustomobject]@{ Key = $key; Name = $key; Link = $link; Target = $target }
        }

        Set-ManagedGroupState -Entries $entries -Enable $true
        foreach ($entry in $entries) {
            $enabledState = Get-ManagedJunctionState -Link $entry.Link -Target $entry.Target
            if ($enabledState.State -ne 'Enabled') { throw "Expected Enabled state for $($entry.Key)." }
            $enabledItem = Get-Item -LiteralPath $entry.Link -Force
            if ([string]$enabledItem.LinkType -ine 'Junction') { throw "Managed entry was not created as an exact Junction for $($entry.Key)." }
        }

        Set-ManagedGroupState -Entries $entries -Enable $false
        foreach ($entry in $entries) {
            if ((Get-ManagedJunctionState -Link $entry.Link -Target $entry.Target).State -ne 'Disabled') {
                throw "Expected Disabled state for $($entry.Key)."
            }
            if (-not (Test-Path -LiteralPath (Join-Path $entry.Target 'marker.txt'))) {
                throw "OFF removed target data for $($entry.Key)."
            }
        }

        # Conflict preflight must reject for the expected reason and preserve foreign data.
        $conflictEntry = $entries[2]
        New-Item -ItemType Directory -Force -Path $conflictEntry.Link | Out-Null
        $conflictSentinel = Join-Path $conflictEntry.Link 'FOREIGN-OWNER-SENTINEL.txt'
        Set-Content -LiteralPath $conflictSentinel -Value 'foreign-owner-data'
        $blockedForExpectedReason = $false
        try {
            Set-ManagedGroupState -Entries $entries -Enable $true
        }
        catch {
            if ($_.Exception.Message -match '^Existing path is not a reparse point:') {
                $blockedForExpectedReason = $true
            }
            else {
                throw
            }
        }
        if (-not $blockedForExpectedReason) { throw 'Conflict path was incorrectly accepted by group enable.' }
        if (-not (Test-Path -LiteralPath $conflictSentinel)) { throw 'Conflict sentinel was removed during rejected group enable.' }
        if ((Get-Content -LiteralPath $conflictSentinel -Raw).Trim() -cne 'foreign-owner-data') { throw 'Conflict sentinel content changed during rejected group enable.' }
        $conflictItem = Get-Item -LiteralPath $conflictEntry.Link -Force
        if ([bool]($conflictItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Foreign conflict directory was replaced by a reparse point.' }
        foreach ($entry in @($entries[0], $entries[1], $entries[3])) {
            if ((Get-ManagedJunctionState -Link $entry.Link -Target $entry.Target).State -ne 'Disabled') {
                throw 'Group preflight mutated another skill before rejecting a conflict.'
            }
        }
        Remove-Item -LiteralPath $conflictEntry.Link -Recurse -Force

        # Destructive-boundary test: simulate a path substitution after a prior valid
        # managed state. Remove-ManagedJunction itself must reject the replacement and
        # preserve its sentinel rather than deleting by pathname.
        $boundaryEntry = $entries[0]
        Set-ManagedJunctionEnabled -Link $boundaryEntry.Link -Target $boundaryEntry.Target -Enable $true
        & $env:ComSpec /d /c "rmdir `"$($boundaryEntry.Link)`""
        if ($LASTEXITCODE -ne 0) { throw 'Failed to prepare destructive-boundary substitution test.' }
        New-Item -ItemType Directory -Force -Path $boundaryEntry.Link | Out-Null
        $boundarySentinel = Join-Path $boundaryEntry.Link 'BOUNDARY-SENTINEL.txt'
        Set-Content -LiteralPath $boundarySentinel -Value 'do-not-delete'

        $boundaryRejected = $false
        try {
            Remove-ManagedJunction -Link $boundaryEntry.Link -Target $boundaryEntry.Target
        }
        catch {
            if ($_.Exception.Message -match '^Refusing destructive removal because junction identity is not currently managed:') {
                $boundaryRejected = $true
            }
            else {
                throw
            }
        }
        if (-not $boundaryRejected) { throw 'Destructive-boundary path substitution was incorrectly accepted.' }
        if (-not (Test-Path -LiteralPath $boundarySentinel)) { throw 'Destructive-boundary rejection removed the replacement sentinel.' }
        if ((Get-Content -LiteralPath $boundarySentinel -Raw).Trim() -cne 'do-not-delete') { throw 'Destructive-boundary rejection changed replacement sentinel content.' }
        Remove-Item -LiteralPath $boundaryEntry.Link -Recurse -Force

        Write-Host 'PASS: HMS Skills Manager self-test verified four-skill Junction enable/disable, exact Junction type, target preservation, transactional preflight, conflict sentinel preservation, and destructive-boundary revalidation.'
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HMS Skills Manager'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(620, 590)
$form.MinimumSize = New-Object System.Drawing.Size(636, 629)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'HMS Skills Manager'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$title.Location = New-Object System.Drawing.Point(24, 18)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Bật/tắt skill discovery cho Codex. OFF chỉ tháo junction, không xóa source.'
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.Location = New-Object System.Drawing.Point(27, 56)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

function New-StatusCard {
    param([string]$Name, [int]$Top)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(24, $Top)
    $panel.Size = New-Object System.Drawing.Size(572, 76)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = $Name
    $nameLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $nameLabel.Location = New-Object System.Drawing.Point(16, 11)
    $nameLabel.AutoSize = $true
    $panel.Controls.Add($nameLabel)

    $stateLabel = New-Object System.Windows.Forms.Label
    $stateLabel.Text = 'Checking...'
    $stateLabel.Location = New-Object System.Drawing.Point(17, 40)
    $stateLabel.AutoSize = $true
    $panel.Controls.Add($stateLabel)

    $toggle = New-Object System.Windows.Forms.Button
    $toggle.Text = '...'
    $toggle.Size = New-Object System.Drawing.Size(108, 38)
    $toggle.Location = New-Object System.Drawing.Point(446, 18)
    $panel.Controls.Add($toggle)

    $form.Controls.Add($panel)
    return [pscustomobject]@{ Panel = $panel; State = $stateLabel; Toggle = $toggle }
}

$cards = @{}
$top = 88
foreach ($entry in $ManagedEntries) {
    $cards[$entry.Key] = New-StatusCard -Name $entry.Name -Top $top
    $top += 84
}

$masterButton = New-Object System.Windows.Forms.Button
$masterButton.Text = 'BẬT TẤT CẢ'
$masterButton.Size = New-Object System.Drawing.Size(160, 42)
$masterButton.Location = New-Object System.Drawing.Point(24, 438)
$form.Controls.Add($masterButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Làm mới'
$refreshButton.Size = New-Object System.Drawing.Size(105, 42)
$refreshButton.Location = New-Object System.Drawing.Point(196, 438)
$form.Controls.Add($refreshButton)

$validateButton = New-Object System.Windows.Forms.Button
$validateButton.Text = 'Validate'
$validateButton.Size = New-Object System.Drawing.Size(105, 42)
$validateButton.Location = New-Object System.Drawing.Point(313, 438)
$form.Controls.Add($validateButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Đóng'
$closeButton.Size = New-Object System.Drawing.Size(160, 42)
$closeButton.Location = New-Object System.Drawing.Point(436, 438)
$form.Controls.Add($closeButton)

$authorityNote = New-Object System.Windows.Forms.Label
$authorityNote.Text = 'Taste + Impeccable là design advisor; HMS authority / Penpot / DESIGN.md luôn ưu tiên cao hơn.'
$authorityNote.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$authorityNote.Location = New-Object System.Drawing.Point(26, 500)
$authorityNote.AutoSize = $true
$form.Controls.Add($authorityNote)

$restartNote = New-Object System.Windows.Forms.Label
$restartNote.Text = 'Sau khi đổi trạng thái, restart/refresh Codex để cập nhật discovery.'
$restartNote.ForeColor = [System.Drawing.Color]::DimGray
$restartNote.Location = New-Object System.Drawing.Point(26, 528)
$restartNote.AutoSize = $true
$form.Controls.Add($restartNote)

function Set-CardVisual {
    param($Card, [string]$State, [string]$Detail)

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
    $states = @{}
    foreach ($entry in $ManagedEntries) {
        $state = Get-ManagedJunctionState -Link $entry.Link -Target $entry.Target
        $states[$entry.Key] = $state
        Set-CardVisual -Card $cards[$entry.Key] -State $state.State -Detail $state.Detail
    }

    if (@($states.Values | Where-Object State -eq 'Conflict').Count -gt 0) {
        $masterButton.Text = 'CONFLICT'
        $masterButton.Enabled = $false
        $masterButton.BackColor = [System.Drawing.Color]::MistyRose
        return
    }

    $masterButton.Enabled = $true
    if (@($states.Values | Where-Object State -ne 'Enabled').Count -eq 0) {
        $masterButton.Text = 'TẮT TẤT CẢ'
        $masterButton.Tag = $false
    }
    else {
        $masterButton.Text = 'BẬT TẤT CẢ'
        $masterButton.Tag = $true
    }
}

function Show-ManagerError {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, 'HMS Skills Manager', 'OK', 'Error') | Out-Null
}

foreach ($entry in $ManagedEntries) {
    $capturedEntry = $entry
    $cards[$entry.Key].Toggle.Add_Click({
        try {
            $state = Get-ManagedJunctionState -Link $capturedEntry.Link -Target $capturedEntry.Target
            Set-ManagedJunctionEnabled -Link $capturedEntry.Link -Target $capturedEntry.Target -Enable ($state.State -eq 'Disabled')
            Refresh-UiState
        }
        catch { Show-ManagerError -Message $_.Exception.Message }
    }.GetNewClosure())
}

$masterButton.Add_Click({
    try {
        Set-ManagedGroupState -Entries $ManagedEntries -Enable ([bool]$masterButton.Tag)
        Refresh-UiState
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$refreshButton.Add_Click({ Refresh-UiState })

$validateButton.Add_Click({
    try {
        & (Join-Path $RepoRoot 'scripts\Test-HmsSkills.ps1')
        Assert-PinnedRepoIdentity -Root $TasteRoot -ExpectedCommit ([string]$UiLock.taste.commit) -SkillPath ([string]$UiLock.taste.skill_path)
        Assert-PinnedRepoIdentity -Root $ImpeccableRoot -ExpectedCommit ([string]$UiLock.impeccable.commit) -SkillPath ([string]$UiLock.impeccable.skill_path)
        [System.Windows.Forms.MessageBox]::Show('PASS: HMS, Superpowers, GPT Taste và Impeccable đã qua validation local.', 'HMS Skills Manager', 'OK', 'Information') | Out-Null
    }
    catch { Show-ManagerError -Message $_.Exception.Message }
})

$closeButton.Add_Click({ $form.Close() })
Refresh-UiState
[void]$form.ShowDialog()
