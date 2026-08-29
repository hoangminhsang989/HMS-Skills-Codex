[CmdletBinding()]
param(
    [string]$Cwd = (Get-Location).Path,
    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$uiLockPath = Join-Path $RepoRoot 'ui-skills.lock.json'
if (-not (Test-Path -LiteralPath $uiLockPath)) { throw "UI skills lock file not found: $uiLockPath" }
$uiLock = Get-Content -LiteralPath $uiLockPath -Raw | ConvertFrom-Json

if ($env:OS -eq 'Windows_NT') {
    $windowsPowerShell = Get-Command powershell.exe -ErrorAction Stop
    $ps51Version = (& $windowsPowerShell.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') -join "`n"
    if ($LASTEXITCODE -ne 0 -or $ps51Version.Trim() -notmatch '^5\.1\.') { throw "Expected Windows PowerShell 5.1, found: $($ps51Version.Trim())" }
    $managerPath = Join-Path $RepoRoot 'manager\HmsSuperpowersManager.ps1'
    & $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $managerPath -SelfTest
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell 5.1 Manager self-test failed with exit code $LASTEXITCODE." }
    Write-Host "PASS: unified Manager self-test qualified on Windows PowerShell $($ps51Version.Trim())."
}

$compositeRoot = Join-Path $env:USERPROFILE '.codex\hms-composite\hms-superpowers'
$manifestPath = Join-Path $compositeRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Composite manifest is missing: $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex' -or [string]$manifest.artifact -cne 'hms-superpowers-composite') { throw 'Composite ownership manifest mismatch.' }

$skillFiles = @(Get-ChildItem -LiteralPath $compositeRoot -Filter 'SKILL.md' -File -Recurse)
if ($skillFiles.Count -ne 1 -or $skillFiles[0].FullName -ne (Join-Path $compositeRoot 'SKILL.md')) {
    throw "Unified composite must contain exactly one root SKILL.md. Observed count: $($skillFiles.Count)"
}
foreach ($key in @('hms','superpowers','taste','impeccable')) {
    if (-not [bool]$manifest.modules.$key) { throw "Clean CI install expected module '$key' ON." }
}

$sourceSkillNames = @()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'skills') -Filter 'SKILL.md' -File -Recurse)) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $m = [regex]::Match($text, '(?m)^name:\s*([^\r\n]+?)\s*$')
    if ($m.Success) { $sourceSkillNames += $m.Groups[1].Value.Trim() }
}
$forbiddenRawHmsNames = @($sourceSkillNames | Where-Object { $_ -ne 'hms-superpowers' } | Sort-Object -Unique)
$forbiddenExternalNames = @(
    [string]$uiLock.taste.codex_discovery_name,
    [string]$uiLock.impeccable.codex_discovery_name
)

$node = Get-Command node -ErrorAction Stop
$npmRoot = (& npm root -g).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($npmRoot)) { throw 'Unable to determine global npm root for Codex CLI.' }
$codexJs = Join-Path $npmRoot '@openai\codex\bin\codex.js'
if (-not (Test-Path -LiteralPath $codexJs)) { throw "Pinned Codex CLI entry point not found: $codexJs" }

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $node.Source
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.CreateNoWindow = $true
$startInfo.ArgumentList.Add($codexJs)
$startInfo.ArgumentList.Add('app-server')
$startInfo.ArgumentList.Add('--stdio')

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) { throw 'Failed to start Codex app-server.' }
$stderrTask = $process.StandardError.ReadToEndAsync()

function Send-AppServerMessage {
    param([Parameter(Mandatory)]$Message)
    $json = $Message | ConvertTo-Json -Compress -Depth 20
    $process.StandardInput.WriteLine($json)
    $process.StandardInput.Flush()
}

function Read-AppServerResponse {
    param([Parameter(Mandatory)][int]$Id)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $readTask = $process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) { throw "Timed out waiting for Codex app-server response id $Id." }
        $line = $readTask.Result
        if ($null -eq $line) { throw "Codex app-server stdout closed while waiting for response id $Id." }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json }
        catch { throw "Codex app-server emitted non-JSON stdout: $line" }
        if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq $Id) {
            if ($null -ne $message.PSObject.Properties['error'] -and $null -ne $message.error) { throw "Codex app-server request $Id failed." }
            return $message
        }
    }
    throw "Timed out waiting for Codex app-server response id $Id."
}

try {
    Send-AppServerMessage -Message @{ method='initialize'; id=1; params=@{ clientInfo=@{ name='hms_skills_ci'; title='HMS Skills CI'; version='0.2.0' } } }
    $initializeResponse = Read-AppServerResponse -Id 1
    if ($null -ne $initializeResponse.result.codexHome) { Write-Host "Codex app-server codexHome: $($initializeResponse.result.codexHome)" }
    Send-AppServerMessage -Message @{ method='initialized' }
    Send-AppServerMessage -Message @{ method='skills/list'; id=2; params=@{ cwds=@([IO.Path]::GetFullPath($Cwd)); forceReload=$true } }

    $response = Read-AppServerResponse -Id 2
    $entries = @($response.result.data)
    if ($entries.Count -ne 1) { throw "Expected one skills/list cwd result, found $($entries.Count)." }
    $entry = $entries[0]
    if (@($entry.errors).Count -gt 0) { throw "Codex skills/list reported discovery errors: $($entry.errors | ConvertTo-Json -Compress -Depth 10)" }

    $skills = @($entry.skills)
    $names = @($skills | ForEach-Object { [string]$_.name })
    $sortedNames = @($names | Sort-Object -Unique)
    Write-Host ('Codex discovered skills: ' + ($sortedNames -join ', '))

    if (@($names | Where-Object { $_ -eq 'hms-superpowers' }).Count -ne 1) { throw 'Expected exactly one discovered hms-superpowers skill.' }
    foreach ($name in $forbiddenRawHmsNames) {
        if ($names -contains $name) { throw "Internal HMS module leaked into public Codex discovery: $name" }
    }
    foreach ($name in $forbiddenExternalNames) {
        if (-not [string]::IsNullOrWhiteSpace($name) -and $names -contains $name) { throw "UI advisor leaked into public Codex discovery: $name" }
    }
    foreach ($name in $names) {
        if ($name -like 'superpowers:*') { throw "Upstream Superpowers source skill leaked into public Codex discovery: $name" }
    }

    Write-Host 'PASS: Codex discovered exactly one HMS composite entry point; HMS, Superpowers, Taste, and Impeccable remain internal modules.'
}
finally {
    try { $process.StandardInput.Close() } catch { }
    if (-not $process.HasExited) { try { $process.Kill($true) } catch { } }
    try { $process.WaitForExit(5000) | Out-Null } catch { }
    try { if ($stderrTask.IsCompleted) { $null = $stderrTask.Result } } catch { }
    $process.Dispose()
}
