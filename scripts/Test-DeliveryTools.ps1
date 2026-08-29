[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = [System.Collections.Generic.List[string]]::new()
$lockPath = Join-Path $RepoRoot 'delivery-tools.lock.json'

if (-not (Test-Path -LiteralPath $lockPath)) {
    $errors.Add('Missing delivery-tools.lock.json')
}
else {
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        $cg = $lock.codegraph
        $tld = $lock.three_level_delivery

        if ($null -eq $cg) { $errors.Add('Missing codegraph entry in delivery-tools.lock.json') }
        else {
            if ([string]$cg.repository -cne 'https://github.com/colbymchenry/codegraph') { $errors.Add("Unexpected CodeGraph repository: $($cg.repository)") }
            if ([string]$cg.version -cne '1.6.0') { $errors.Add("Unexpected CodeGraph version: $($cg.version)") }
            if ([string]$cg.tag -cne 'v1.6.0') { $errors.Add("Unexpected CodeGraph tag: $($cg.tag)") }
            if ([string]$cg.commit -cne 'dfccdf62547fcd76d343344d823a0e1998d3a89f') { $errors.Add("Unexpected CodeGraph commit: $($cg.commit)") }
            if ([string]$cg.mcp_server -cne 'codegraph') { $errors.Add("Unexpected CodeGraph MCP server name: $($cg.mcp_server)") }
            if ([string]$cg.windows_assets.x64.name -cne 'codegraph-win32-x64.zip') { $errors.Add('Unexpected CodeGraph x64 asset name.') }
            if ([string]$cg.windows_assets.x64.sha256 -cne 'cd76c3c3391f2d40abef12b142151950b6d77abc2d8429e648f89eaa90f5b68a') { $errors.Add('Unexpected CodeGraph x64 asset SHA-256.') }
            if ([string]$cg.windows_assets.arm64.name -cne 'codegraph-win32-arm64.zip') { $errors.Add('Unexpected CodeGraph arm64 asset name.') }
            if ([string]$cg.windows_assets.arm64.sha256 -cne '3ca980010bd718a6b5e75be1145806ae6491afb1a59a2cec6cee4bf5c39f1b3a') { $errors.Add('Unexpected CodeGraph arm64 asset SHA-256.') }
        }

        if ($null -eq $tld) { $errors.Add('Missing three_level_delivery entry in delivery-tools.lock.json') }
        else {
            if ([string]$tld.repository -cne 'https://github.com/nguyenduytamgithub/three-level-delivery.git') { $errors.Add("Unexpected Three-Level Delivery repository: $($tld.repository)") }
            if ([string]$tld.version -cne '0.1.4') { $errors.Add("Unexpected Three-Level Delivery version: $($tld.version)") }
            if ([string]$tld.tag -cne 'v0.1.4') { $errors.Add("Unexpected Three-Level Delivery tag: $($tld.tag)") }
            if ([string]$tld.commit -cne '667d15066784dd192e34efdff432ad47ae2298a9') { $errors.Add("Unexpected Three-Level Delivery commit: $($tld.commit)") }
            if ([string]$tld.skill_path -cne 'three-level-delivery') { $errors.Add("Unexpected Three-Level Delivery skill path: $($tld.skill_path)") }
            if ([string]$tld.skill_name -cne 'three-level-delivery') { $errors.Add("Unexpected Three-Level Delivery skill name: $($tld.skill_name)") }
        }
    }
    catch {
        $errors.Add("Invalid delivery-tools.lock.json: $($_.Exception.Message)")
    }
}

foreach ($skillName in @('codegraph-context', 'three-level-delivery')) {
    $skillPath = Join-Path $RepoRoot "skills\$skillName\SKILL.md"
    if (-not (Test-Path -LiteralPath $skillPath)) {
        $errors.Add("Required delivery integration skill missing: skills/$skillName/SKILL.md")
        continue
    }
    $text = Get-Content -LiteralPath $skillPath -Raw
    $frontmatter = [regex]::Match($text, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n')
    if (-not $frontmatter.Success) {
        $errors.Add("Missing frontmatter in delivery integration skill: $skillName")
        continue
    }
    $nameMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^name:\s*([a-z0-9-]+)\s*$')
    if (-not $nameMatch.Success -or $nameMatch.Groups[1].Value -cne $skillName) {
        $errors.Add("Delivery integration skill name mismatch: $skillName")
    }
}

$syncScript = Join-Path $RepoRoot 'scripts\Sync-DeliveryTools.ps1'
if (-not (Test-Path -LiteralPath $syncScript)) {
    $errors.Add('Required PowerShell script missing: scripts/Sync-DeliveryTools.ps1')
}
else {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($syncScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in @($parseErrors)) {
        $errors.Add(("PowerShell parser error in {0} at line {1}, column {2}: {3}" -f $syncScript, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message))
    }
}

if ($errors.Count -gt 0) {
    throw ("Delivery-tool validation failed:`n - " + ($errors -join "`n - "))
}

Write-Host 'PASS: validated CodeGraph v1.6.0 release identity/assets, Three-Level Delivery v0.1.4 source identity, adapter skills, and delivery sync script syntax.'
