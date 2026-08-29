[CmdletBinding()]
param(
    [switch]$EnsureCodeGraphConfig,
    [switch]$EnableCodeGraphIfNew,
    [switch]$RemoveCodeGraphConfig,
    [switch]$SkipCodeGraph,
    [switch]$SkipThreeLevelDelivery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockPath = Join-Path $RepoRoot 'delivery-tools.lock.json'
$CodeGraphRoot = Join-Path $env:USERPROFILE '.codex\codegraph'
$ThreeLevelRoot = Join-Path $env:USERPROFILE '.codex\three-level-delivery'
$CodeGraphManifest = Join-Path $CodeGraphRoot 'hms-codegraph-install.json'
$ManagedBy = 'HMS-Skills-Codex'

function ConvertTo-NormalizedRemote {
    param([Parameter(Mandatory)][string]$Remote)
    $value = $Remote.Trim().TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    return $value.ToLowerInvariant()
}

function Read-ValidatedDeliveryLock {
    if (-not (Test-Path -LiteralPath $LockPath)) { throw "Delivery tools lock file not found: $LockPath" }
    try { $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json }
    catch { throw "Delivery tools lock file is invalid JSON: $($_.Exception.Message)" }

    $cg = $lock.codegraph
    $tld = $lock.three_level_delivery
    if ($null -eq $cg -or $null -eq $tld) { throw 'delivery-tools.lock.json must contain codegraph and three_level_delivery.' }

    if ([string]$cg.repository -cne 'https://github.com/colbymchenry/codegraph') { throw "Unexpected CodeGraph repository in lock: $($cg.repository)" }
    if ([string]$cg.version -cne '1.6.0' -or [string]$cg.tag -cne 'v1.6.0') { throw 'Unexpected CodeGraph version/tag in lock.' }
    if ([string]$cg.commit -cne 'dfccdf62547fcd76d343344d823a0e1998d3a89f') { throw "Unexpected CodeGraph commit in lock: $($cg.commit)" }
    if ([string]$cg.mcp_server -cne 'codegraph') { throw "Unexpected CodeGraph MCP name in lock: $($cg.mcp_server)" }
    foreach ($arch in @('x64', 'arm64')) {
        $asset = $cg.windows_assets.$arch
        if ($null -eq $asset) { throw "Missing CodeGraph Windows asset for $arch" }
        if ([string]$asset.sha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid CodeGraph SHA-256 for $arch" }
    }

    if ([string]$tld.repository -cne 'https://github.com/nguyenduytamgithub/three-level-delivery.git') { throw "Unexpected Three-Level Delivery repository in lock: $($tld.repository)" }
    if ([string]$tld.version -cne '0.1.4' -or [string]$tld.tag -cne 'v0.1.4') { throw 'Unexpected Three-Level Delivery version/tag in lock.' }
    if ([string]$tld.commit -cne '667d15066784dd192e34efdff432ad47ae2298a9') { throw "Unexpected Three-Level Delivery commit in lock: $($tld.commit)" }
    if ([string]$tld.skill_path -cne 'three-level-delivery' -or [string]$tld.skill_name -cne 'three-level-delivery') { throw 'Unexpected Three-Level Delivery skill contract in lock.' }
    return $lock
}

function Assert-ExpectedOrigin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRemote
    )
    $origin = & git -C $Path remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw "git remote get-url origin failed for $Path" }
    if ((ConvertTo-NormalizedRemote $origin) -ne (ConvertTo-NormalizedRemote $ExpectedRemote)) {
        throw "Unexpected Git origin for $Path. Expected '$ExpectedRemote', found '$($origin.Trim())'."
    }
}

function Sync-ThreeLevelDeliverySource {
    param([Parameter(Mandatory)]$Spec)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git.exe is required for Three-Level Delivery source pinning.' }
    if (Test-Path -LiteralPath $ThreeLevelRoot) {
        if (-not (Test-Path -LiteralPath (Join-Path $ThreeLevelRoot '.git'))) { throw "Refusing to overwrite existing non-Git Three-Level Delivery path: $ThreeLevelRoot" }
        Assert-ExpectedOrigin -Path $ThreeLevelRoot -ExpectedRemote ([string]$Spec.repository)
        $dirty = & git -C $ThreeLevelRoot status --porcelain
        if ($LASTEXITCODE -ne 0) { throw "git status failed for $ThreeLevelRoot" }
        if ($dirty) { throw "Refusing to reconcile dirty Three-Level Delivery source: $ThreeLevelRoot" }
    }
    else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ThreeLevelRoot) | Out-Null
        & git clone ([string]$Spec.repository) $ThreeLevelRoot
        if ($LASTEXITCODE -ne 0) { throw 'Three-Level Delivery clone failed.' }
        Assert-ExpectedOrigin -Path $ThreeLevelRoot -ExpectedRemote ([string]$Spec.repository)
    }

    & git -C $ThreeLevelRoot fetch --tags --prune ([string]$Spec.repository)
    if ($LASTEXITCODE -ne 0) { throw 'Three-Level Delivery fetch failed.' }
    & git -C $ThreeLevelRoot cat-file -e "$([string]$Spec.commit)^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Pinned Three-Level Delivery commit is unavailable: $($Spec.commit)" }
    $tagCommit = (& git -C $ThreeLevelRoot rev-list -n 1 ([string]$Spec.tag)).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $tagCommit -ne [string]$Spec.commit) { throw "Three-Level Delivery tag/commit mismatch. Expected $($Spec.tag) -> $($Spec.commit), found $tagCommit" }
    & git -C $ThreeLevelRoot checkout --detach ([string]$Spec.commit)
    if ($LASTEXITCODE -ne 0) { throw 'Three-Level Delivery pinned checkout failed.' }
    $head = (& git -C $ThreeLevelRoot rev-parse HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $head -ne [string]$Spec.commit) { throw "Three-Level Delivery HEAD mismatch. Expected $($Spec.commit), found $head" }

    $skillFile = Join-Path (Join-Path $ThreeLevelRoot ([string]$Spec.skill_path)) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile)) { throw "Three-Level Delivery canonical SKILL.md is missing: $skillFile" }
    $text = Get-Content -LiteralPath $skillFile -Raw
    $frontmatter = [regex]::Match($text, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n')
    if (-not $frontmatter.Success) { throw 'Three-Level Delivery canonical skill frontmatter is missing.' }
    $fm = $frontmatter.Groups[1].Value
    $name = [regex]::Match($fm, '(?m)^name:\s*([^\r\n]+?)\s*$')
    $version = [regex]::Match($fm, '(?m)^\s*version:\s*["'']?([^"''\r\n]+)["'']?\s*$')
    $repository = [regex]::Match($fm, '(?m)^\s*repository:\s*["'']?([^"''\r\n]+)["'']?\s*$')
    if (-not $name.Success -or $name.Groups[1].Value.Trim() -cne [string]$Spec.skill_name) { throw 'Three-Level Delivery canonical skill name mismatch.' }
    if (-not $version.Success -or $version.Groups[1].Value.Trim() -cne [string]$Spec.version) { throw 'Three-Level Delivery canonical skill version mismatch.' }
    if (-not $repository.Success -or (ConvertTo-NormalizedRemote $repository.Groups[1].Value.Trim()) -ne (ConvertTo-NormalizedRemote ([string]$Spec.repository))) { throw 'Three-Level Delivery canonical repository metadata mismatch.' }

    $dirtyAfter = & git -C $ThreeLevelRoot status --porcelain
    if ($LASTEXITCODE -ne 0 -or $dirtyAfter) { throw 'Three-Level Delivery source is not clean after pin qualification.' }
    Write-Host "Three-Level Delivery pin: $head"
}

function Get-CodeGraphArchitecture {
    $raw = $null
    try { $raw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }
    catch { $raw = [string]$env:PROCESSOR_ARCHITECTURE }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Unable to determine Windows architecture for CodeGraph.' }
    switch -Regex ($raw.ToLowerInvariant()) {
        'arm64' { return 'arm64' }
        'amd64|x64' { return 'x64' }
        default { throw "Unsupported Windows architecture for pinned CodeGraph bundle: $raw" }
    }
}

function Read-ManagedCodeGraphManifest {
    if (-not (Test-Path -LiteralPath $CodeGraphRoot)) { return $null }
    if (-not (Test-Path -LiteralPath $CodeGraphManifest)) {
        throw "Refusing to overwrite existing CodeGraph path not owned by HMS Skills Codex: $CodeGraphRoot"
    }
    try { $manifest = Get-Content -LiteralPath $CodeGraphManifest -Raw | ConvertFrom-Json }
    catch { throw "Managed CodeGraph manifest is invalid JSON: $($_.Exception.Message)" }
    if ([string]$manifest.managed_by -cne $ManagedBy) { throw "Unexpected CodeGraph installation owner at $CodeGraphRoot" }
    return $manifest
}

function Assert-CodeGraphVersion {
    param(
        [Parameter(Mandatory)][string]$CommandPath,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    if (-not (Test-Path -LiteralPath $CommandPath)) { throw "CodeGraph launcher missing: $CommandPath" }
    $output = (& $CommandPath --version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "CodeGraph --version failed: $output" }
    if ($output -notmatch [regex]::Escape($ExpectedVersion)) { throw "Unexpected CodeGraph version output. Expected $ExpectedVersion, found: $output" }
}

function Sync-CodeGraphBundle {
    param([Parameter(Mandatory)]$Spec)

    if ($env:OS -ne 'Windows_NT') { throw 'The HMS pinned CodeGraph bundle installer currently supports Windows only.' }
    $existingManifest = Read-ManagedCodeGraphManifest
    $wasInstalled = $null -ne $existingManifest
    $arch = Get-CodeGraphArchitecture
    $asset = $Spec.windows_assets.$arch
    $assetName = [string]$asset.name
    $expectedSha = [string]$asset.sha256
    $current = Join-Path $CodeGraphRoot 'current'
    $command = Join-Path $current 'bin\codegraph.cmd'

    $alreadyExact = $false
    if ($wasInstalled -and (Test-Path -LiteralPath $command)) {
        if ([string]$existingManifest.version -ceq [string]$Spec.version -and
            [string]$existingManifest.tag -ceq [string]$Spec.tag -and
            [string]$existingManifest.commit -ceq [string]$Spec.commit -and
            [string]$existingManifest.asset -ceq $assetName -and
            [string]$existingManifest.sha256 -ceq $expectedSha) {
            Assert-CodeGraphVersion -CommandPath $command -ExpectedVersion ([string]$Spec.version)
            $alreadyExact = $true
        }
    }

    if (-not $alreadyExact) {
        $temp = Join-Path $env:TEMP ("hms-codegraph-" + [guid]::NewGuid().ToString('N'))
        $zip = Join-Path $temp $assetName
        $extract = Join-Path $temp 'extract'
        $candidate = $extract
        $backup = $null
        try {
            New-Item -ItemType Directory -Force -Path $extract | Out-Null
            $url = "https://github.com/colbymchenry/codegraph/releases/download/$([string]$Spec.tag)/$assetName"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
            $actualSha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualSha -ne $expectedSha) { throw "CodeGraph release asset SHA-256 mismatch. Expected $expectedSha, found $actualSha" }
            Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

            $inner = Join-Path $extract ("codegraph-win32-" + $arch)
            if (Test-Path -LiteralPath $inner) {
                $flat = Join-Path $temp 'flat'
                New-Item -ItemType Directory -Force -Path $flat | Out-Null
                Get-ChildItem -LiteralPath $inner -Force | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $flat -Force }
                $candidate = $flat
            }
            $candidateCommand = Join-Path $candidate 'bin\codegraph.cmd'
            Assert-CodeGraphVersion -CommandPath $candidateCommand -ExpectedVersion ([string]$Spec.version)

            New-Item -ItemType Directory -Force -Path $CodeGraphRoot | Out-Null
            if (Test-Path -LiteralPath $current) {
                $backup = Join-Path $CodeGraphRoot ("backup-" + [guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $current -Destination $backup
            }
            try {
                Move-Item -LiteralPath $candidate -Destination $current
                Assert-CodeGraphVersion -CommandPath $command -ExpectedVersion ([string]$Spec.version)
                $manifest = [ordered]@{
                    managed_by = $ManagedBy
                    version = [string]$Spec.version
                    tag = [string]$Spec.tag
                    commit = [string]$Spec.commit
                    asset = $assetName
                    sha256 = $expectedSha
                }
                $manifestTemp = "$CodeGraphManifest.tmp"
                $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
                Move-Item -LiteralPath $manifestTemp -Destination $CodeGraphManifest -Force
                if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Recurse -Force }
            }
            catch {
                $installError = $_
                if (Test-Path -LiteralPath $current) { Remove-Item -LiteralPath $current -Recurse -Force }
                if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $current }
                throw $installError
            }
        }
        finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
        }
    }

    return [pscustomobject]@{ WasInstalled = $wasInstalled; Command = $command }
}

function Get-CodexMcpEntry {
    param([Parameter(Mandatory)][string]$Name)
    $codex = Get-Command codex -ErrorAction Stop
    $jsonText = (& $codex.Source mcp list --json 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "codex mcp list --json failed; refusing MCP config mutation: $jsonText" }
    try { $decoded = $jsonText | ConvertFrom-Json }
    catch { throw "codex mcp list returned invalid JSON: $($_.Exception.Message)" }
    $matches = @(@($decoded) | Where-Object { [string]$_.name -ceq $Name })
    if ($matches.Count -gt 1) { throw "Codex reported duplicate MCP server entries named '$Name'." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Test-ExpectedCodeGraphMcpEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$CommandPath
    )
    if ([string]$Entry.transport.type -cne 'stdio') { return $false }
    $configured = [string]$Entry.transport.command
    try {
        if ([IO.Path]::GetFullPath($configured).TrimEnd('\') -ine [IO.Path]::GetFullPath($CommandPath).TrimEnd('\')) { return $false }
    }
    catch { return $false }
    $args = @($Entry.transport.args)
    if ($args.Count -ne 2 -or [string]$args[0] -cne 'serve' -or [string]$args[1] -cne '--mcp') { return $false }
    return $true
}

function Ensure-CodeGraphMcpConfig {
    param([Parameter(Mandatory)][string]$CommandPath)
    $entry = Get-CodexMcpEntry -Name 'codegraph'
    if ($null -ne $entry) {
        if (-not (Test-ExpectedCodeGraphMcpEntry -Entry $entry -CommandPath $CommandPath)) {
            throw 'Existing Codex MCP server named codegraph is not the HMS-managed pinned CodeGraph command. Refusing to overwrite it.'
        }
        Write-Host 'CodeGraph MCP config already matches the HMS-managed absolute command.'
        return
    }

    $codex = Get-Command codex -ErrorAction Stop
    $output = (& $codex.Source mcp add codegraph -- $CommandPath serve --mcp 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "codex mcp add codegraph failed: $output" }
    $after = Get-CodexMcpEntry -Name 'codegraph'
    if ($null -eq $after -or -not (Test-ExpectedCodeGraphMcpEntry -Entry $after -CommandPath $CommandPath)) {
        throw 'Codex did not preserve the exact HMS-managed CodeGraph MCP command after registration.'
    }
    Write-Host 'CodeGraph MCP config registered through the official Codex CLI.'
}

function Remove-CodeGraphMcpConfig {
    param([Parameter(Mandatory)][string]$CommandPath)
    $entry = Get-CodexMcpEntry -Name 'codegraph'
    if ($null -eq $entry) { return }
    if (-not (Test-ExpectedCodeGraphMcpEntry -Entry $entry -CommandPath $CommandPath)) {
        throw 'Existing Codex MCP server named codegraph is not the HMS-managed pinned command. Refusing to remove it.'
    }
    $codex = Get-Command codex -ErrorAction Stop
    $output = (& $codex.Source mcp remove codegraph 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "codex mcp remove codegraph failed: $output" }
    if ($null -ne (Get-CodexMcpEntry -Name 'codegraph')) { throw 'CodeGraph MCP config remained after Codex reported removal.' }
    Write-Host 'HMS-managed CodeGraph MCP config removed.'
}

$lock = Read-ValidatedDeliveryLock

if ($RemoveCodeGraphConfig) {
    if ($SkipCodeGraph) { throw '-RemoveCodeGraphConfig cannot be combined with -SkipCodeGraph.' }
    $manifest = Read-ManagedCodeGraphManifest
    if ($null -eq $manifest) {
        if ($null -ne (Get-CodexMcpEntry -Name 'codegraph')) { throw 'CodeGraph MCP config exists but the HMS-managed bundle is absent; ownership cannot be proven.' }
        return
    }
    $managedCommand = Join-Path $CodeGraphRoot 'current\bin\codegraph.cmd'
    Assert-CodeGraphVersion -CommandPath $managedCommand -ExpectedVersion ([string]$lock.codegraph.version)
    Remove-CodeGraphMcpConfig -CommandPath $managedCommand
    return
}

if (-not $SkipCodeGraph) {
    $cgState = Sync-CodeGraphBundle -Spec $lock.codegraph
    if ($EnsureCodeGraphConfig -or ($EnableCodeGraphIfNew -and -not $cgState.WasInstalled)) {
        Ensure-CodeGraphMcpConfig -CommandPath $cgState.Command
    }
    else {
        $existingEntry = Get-CodexMcpEntry -Name 'codegraph'
        if ($null -ne $existingEntry -and -not (Test-ExpectedCodeGraphMcpEntry -Entry $existingEntry -CommandPath $cgState.Command)) {
            throw 'Existing CodeGraph MCP config conflicts with the HMS-managed pinned installation.'
        }
    }
    Write-Host "CodeGraph pin: $([string]$lock.codegraph.tag) / $([string]$lock.codegraph.commit)"
}

if (-not $SkipThreeLevelDelivery) {
    Sync-ThreeLevelDeliverySource -Spec $lock.three_level_delivery
}

Write-Host 'Pinned delivery tools reconciliation PASS.'
