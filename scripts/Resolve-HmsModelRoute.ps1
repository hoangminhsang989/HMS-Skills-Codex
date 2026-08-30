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

    [Parameter(Mandatory)]
    [ValidateSet(
        'LUNA_LOW_RISK',
        'TERRA_MEDIUM_OR_STRONGER',
        'TERRA_HIGH_OR_STRONGER',
        'SOL_HIGH',
        'SOL_XHIGH',
        'SOL_MAX',
        'SOL_MAX_AND_INDEPENDENT_REVIEW'
    )]
    [string]$RequiredFloor,

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

function Assert-ExactSchemaVersionOne {
    param([Parameter(Mandatory)]$Value)
    $type = $Value.GetType()
    $isInteger = ($type -eq [int]) -or ($type -eq [long])
    if (-not $isInteger -or [long]$Value -ne 1) {
        throw "Unsupported model settings schema_version type/value: $($type.FullName) / $Value"
    }
}

function Read-Settings {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return Get-DefaultSettings }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Model settings path must be a regular file: $Path"
    }

    try { $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Model settings are invalid JSON: $($_.Exception.Message)" }

    if ($null -eq $settings.PSObject.Properties['schema_version']) { throw 'Model settings are missing schema_version.' }
    Assert-ExactSchemaVersionOne -Value $settings.schema_version
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

$floorRank = @{
    'LUNA_LOW_RISK' = 1
    'TERRA_MEDIUM_OR_STRONGER' = 2
    'TERRA_HIGH_OR_STRONGER' = 3
    'SOL_HIGH' = 4
    'SOL_XHIGH' = 5
    'SOL_MAX' = 6
    'SOL_MAX_AND_INDEPENDENT_REVIEW' = 6
}

$riskMinimumFloor = @{
    'FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL' = 'LUNA_LOW_RISK'
    'NORMAL_WORK' = 'TERRA_MEDIUM_OR_STRONGER'
    'MODERATE_DEBUG_OR_IMPLEMENTATION' = 'TERRA_HIGH_OR_STRONGER'
    'COMPLEX_WORK' = 'SOL_HIGH'
    'ARCHITECTURE_SECURITY_MIGRATION' = 'SOL_XHIGH'
    'CRITICAL_BLOCKER_RELEASE_GATE' = 'SOL_MAX'
    'FINAL_STAGE_REVIEW' = 'SOL_MAX_AND_INDEPENDENT_REVIEW'
}

$minimumFloor = [string]$riskMinimumFloor[$RiskClass]
if ([int]$floorRank[$RequiredFloor] -lt [int]$floorRank[$minimumFloor]) {
    throw "Required model floor '$RequiredFloor' is below risk-class minimum '$minimumFloor' for '$RiskClass'."
}
if ($RiskClass -ceq 'FINAL_STAGE_REVIEW' -and $RequiredFloor -cne 'SOL_MAX_AND_INDEPENDENT_REVIEW') {
    throw 'FINAL_STAGE_REVIEW requires SOL_MAX_AND_INDEPENDENT_REVIEW so the reviewer-independence requirement cannot be erased.'
}

$floorTable = @{
    'LUNA_LOW_RISK' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-luna'
        Candidates = @(
            [pscustomobject]@{ Key='luna'; Model='gpt-5.6-luna'; Effort='maximum-available-for-luna' },
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='medium' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'TERRA_MEDIUM_OR_STRONGER' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-terra'
        Candidates = @(
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='medium' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'TERRA_HIGH_OR_STRONGER' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-terra'
        Candidates = @(
            [pscustomobject]@{ Key='terra'; Model='gpt-5.6-terra'; Effort='high' },
            [pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' }
        )
    }
    'SOL_HIGH' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='high' })
    }
    'SOL_XHIGH' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='xhigh' })
    }
    'SOL_MAX' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='max' })
    }
    'SOL_MAX_AND_INDEPENDENT_REVIEW' = [pscustomobject]@{
        PreferredModel = 'gpt-5.6-sol'
        Candidates = @([pscustomobject]@{ Key='sol'; Model='gpt-5.6-sol'; Effort='max' })
    }
}

$settings = Read-Settings -Path $SettingsPath
$route = $floorTable[$RequiredFloor]
$enabled = @()
foreach ($name in @('luna','terra','sol')) {
    if ($settings.models.$name -isnot [bool]) { throw "Model setting '$name' must be boolean." }
    if ($settings.models.$name) { $enabled += $name }
}

$assignment = $null
foreach ($candidate in @($route.Candidates)) {
    if ($settings.models.($candidate.Key)) {
        $assignment = $candidate
        break
    }
}

if ($null -eq $assignment) {
    $result = [pscustomobject]@{
        status = 'BLOCKED'
        reason = 'NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR'
        risk_class = $RiskClass
        risk_minimum_floor = $minimumFloor
        required_floor = $RequiredFloor
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
        risk_minimum_floor = $minimumFloor
        required_floor = $RequiredFloor
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
