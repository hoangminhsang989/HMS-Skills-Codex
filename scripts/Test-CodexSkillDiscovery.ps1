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

$requiredHmsSkills = @(
    'hms-superpowers',
    'hms-authority-loader',
    'hms-authority-gate',
    'hms-scope-lock',
    'hms-model-router',
    'hms-isolated-execution',
    'hms-evidence-gate',
    'hms-independent-review',
    'hms-fail-closed',
    'hms-release-gate',
    'hms-handoff',
    'hms-ui-design-authority'
)
$requiredUpstreamSkills = @('superpowers:brainstorming')
$requiredUiAdvisorSkills = @(
    [string]$uiLock.taste.codex_discovery_name,
    [string]$uiLock.impeccable.codex_discovery_name
)
foreach ($name in $requiredUiAdvisorSkills) {
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'UI advisor Codex discovery name is missing from ui-skills.lock.json.' }
}

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
            if ($null -ne $message.PSObject.Properties['error'] -and $null -ne $message.error) {
                throw "Codex app-server request $Id failed: $($message.error | ConvertTo-Json -Compress -Depth 10)"
            }
            return $message
        }
    }
    throw "Timed out waiting for Codex app-server response id $Id."
}

try {
    Send-AppServerMessage -Message @{
        method = 'initialize'
        id = 1
        params = @{ clientInfo = @{ name = 'hms_skills_ci'; title = 'HMS Skills CI'; version = '0.2.0' } }
    }
    $initializeResponse = Read-AppServerResponse -Id 1
    if ($null -ne $initializeResponse.result.codexHome) { Write-Host "Codex app-server codexHome: $($initializeResponse.result.codexHome)" }

    Send-AppServerMessage -Message @{ method = 'initialized' }
    Send-AppServerMessage -Message @{
        method = 'skills/list'
        id = 2
        params = @{ cwds = @([IO.Path]::GetFullPath($Cwd)); forceReload = $true }
    }

    $response = Read-AppServerResponse -Id 2
    $entries = @($response.result.data)
    if ($entries.Count -ne 1) { throw "Expected one skills/list cwd result, found $($entries.Count)." }
    $entry = $entries[0]
    $discoveryErrors = @($entry.errors)
    if ($discoveryErrors.Count -gt 0) { throw "Codex skills/list reported discovery errors: $($discoveryErrors | ConvertTo-Json -Compress -Depth 10)" }

    $skills = @($entry.skills)
    $names = @($skills | ForEach-Object { [string]$_.name })
    $sortedNames = @($names | Sort-Object -Unique)
    Write-Host ("Codex discovered skills: " + ($sortedNames -join ', '))

    foreach ($required in @($requiredHmsSkills + $requiredUpstreamSkills + $requiredUiAdvisorSkills)) {
        if ($names -notcontains $required) {
            throw "Codex skills/list did not discover required skill '$required'. Observed names: $($sortedNames -join ', ')"
        }
    }

    foreach ($uniqueName in @('hms-superpowers', 'hms-ui-design-authority') + $requiredUiAdvisorSkills) {
        if (@($skills | Where-Object { $_.name -eq $uniqueName }).Count -ne 1) {
            throw "Expected exactly one discovered '$uniqueName' skill."
        }
    }

    Write-Host "PASS: Codex app-server skills/list discovered all $($requiredHmsSkills.Count) HMS skills, pinned Superpowers, $($requiredUiAdvisorSkills -join ', ')."
}
finally {
    try { $process.StandardInput.Close() } catch { }
    if (-not $process.HasExited) { try { $process.Kill($true) } catch { } }
    try { $process.WaitForExit(5000) | Out-Null } catch { }
    try {
        if ($stderrTask.IsCompleted) {
            $stderr = $stderrTask.Result
            if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Verbose "Codex app-server stderr: $stderr" }
        }
    }
    catch { }
    $process.Dispose()
}
