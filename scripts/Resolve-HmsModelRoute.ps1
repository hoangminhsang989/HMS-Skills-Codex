[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL',
        'NORMAL_WORK',
        'MODERATE_DEBUG_OR_IMPLEMENTATION',
        'COMPLEX_WORK',
        'ARCHITECTURE_SECURITY_MIGRATION',
        'CRITICAL_BLOCKER_RELEASE_GATE',
        'FINAL_STAGE_REVIEW'
    )]
    [string]$RiskClass,

    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.codex\hms-composite\model-settings.json'),

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultSettings {
    return [pscustomobject]@{
        schema_version = 1
        managed_by = 'HMS-Skills-Codex'
        artifact = 'hms-model-settings'
        models = [pscustomobject]@{
            luna = $true
            terra = $true
            sol = $true
        }
    }
}

function Read-Settings {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return Get-DefaultSettings }

    try { $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Model settings are invalid JSON: $($_.Exception.Message)" }

    if ([int]$settings.schema_version -ne 1) { throw "Unsupported model settings schema_version: $($settings.schema_version)" }
    if ([string]$settings.managed_by -cne 'HMS-Skills-Codex') { throw 'Model settings ownership mismatch.' }
    if ([string]$settings.artifact -cne 'hms-model-settings') { throw 'Model settings artifact mismatch.' }
    if ($null -eq $settings.models) { throw 'Model settings are missing models.' }

    foreach ($name in @('luna','terra','sol')) {
        $property = $settings.models.PSObject.Properties[$name]
        if ($null -eq $property) { throw "Model settings are missing '$name'." }
        if ($property.Value -isnot [bool]) { throw "Model setting '$name' must be boolean." }
    }

    return $settings
}

$routeTable = @{
    'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-luna'
        RequiredFloor = 'LUNA_LOW_RISK'
        Candidates = @(
            [pscustomobject]@{ Key='luna'; Model='gpt-5.6-luna'; Effort='maximum-available-for-luna' },
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='medium' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'NORMAL_WORK' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-terra'
        RequiredFloor = 'TERRA_MEDIUM_OR_STRONGER'
        Candidates = @(
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='medium' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'MODERATE_DEBUG_OR_IMPLEMENTATION' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-terra'
        RequiredFloor = 'TERRA_HIGH_OR_STRONGER'
        Candidates = @(
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='high' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'COMPLEX_WORK' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        RequiredFloor = 'SOL_HIGH'
        Candidates = @(
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'ARCHITECTURE_SECURITY_MIGRATION' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        RequiredFloor = 'SOL_XHIGH'
        Candidates = @(
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='xhigh' }
        )
    }
    'CRITICAL_BLOCKER_RELEASE_GATE' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        RequiredFloor = 'SOL_MAX'
        Candidates = @(
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='max' }
        )
    }
    'FINAL_STAGE_REVIEW' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        RequiredFloor = 'SOL_MAX_AND_INDEPENDENT_REVIEW'
        Candidates = @(
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='max' }
        )
    }
}

$settings = Read-Settings -Path $SettingsPath
$route = $routeTable[$RiskClass]
$enabled = @()
foreach ($name in @('luna','terra','sol')) {
    if ([bool]$settings.models.$name) { $enabled += $name }
}

$assignment = $null
foreach ($candidate in @($route.Candidates)) {
    if ([bool]$settings.models.($candidate.Key)) {
        $assignment = $candidate
        break
    }
}

if ($null -eq $assignment) {
    $result = [pscustomobject]@{
        status = 'BLOCKED'
        reason = 'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR'
        risk_class = $RiskClass
        required_floor = $route.RequiredFloor
        preferred_model = $route.PreferredModel
        assigned_model = $null
        effort = $null
        reassigned = $false
        enabled_models = $enabled
        settings_path = $SettingsPath
    }
}
else {
    $result = [pscustomobject]@{
        status = 'ASSIGNED'
        reason = if ($assignment.Model -ceq $route.PreferredModel) { 'PREFERRED_MODEL_ENABLED' } else { 'PREFERRED_MODEL_DISABLED_REASSIGNED_TO_STRONGER_ENABLED_MODEL' }
        risk_class = $RiskClass
        required_floor = $route.RequiredFloor
        preferred_model = $route.PreferredModel
        assigned_model = $assignment.Model
        effort = $assignment.Effort
        reassigned = [bool]($assignment.Model -cne $route.PreferredModel)
        enabled_models = $enabled
        settings_path = $SettingsPath
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
}
else {
    $result
}
