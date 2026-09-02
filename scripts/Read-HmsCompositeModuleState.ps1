[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Composite manifest not found: $ManifestPath"
}

$item = Get-Item -LiteralPath $ManifestPath -Force -ErrorAction Stop
if ($item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Composite manifest path must be a regular file: $ManifestPath"
}

try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
}
catch {
    throw "Composite manifest is invalid JSON: $($_.Exception.Message)"
}

$schemaProperty = $manifest.PSObject.Properties['schema_version']
if ($null -eq $schemaProperty) { throw 'Composite manifest is missing schema_version.' }
$schemaValue = $schemaProperty.Value
$schemaType = $schemaValue.GetType()
if ((($schemaType -ne [int]) -and ($schemaType -ne [long])) -or [long]$schemaValue -ne 1) {
    throw "Unsupported composite manifest schema_version type/value: $($schemaType.FullName) / $schemaValue"
}
if ([string]$manifest.managed_by -cne 'HMS-Skills-Codex') { throw 'Composite manifest ownership mismatch.' }
if ([string]$manifest.artifact -cne 'hms-superpowers-composite') { throw 'Composite manifest artifact mismatch.' }
if ($null -eq $manifest.PSObject.Properties['modules'] -or $null -eq $manifest.modules) {
    throw 'Composite manifest is missing modules.'
}

$state = [ordered]@{}
foreach ($key in @('hms','superpowers','taste','impeccable')) {
    $property = $manifest.modules.PSObject.Properties[$key]
    if ($null -eq $property) { throw "Composite manifest is missing module state '$key'." }
    if ($property.Value -isnot [bool]) { throw "Composite manifest module '$key' must be boolean." }
    $state[$key] = $property.Value
}

[pscustomobject]$state
