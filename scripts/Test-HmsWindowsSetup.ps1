[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('All','Lifecycle','Bootstrap','Desktop','Installer','Workflow')]
    [string]$Scope = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-TextContains {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )
    $text = [IO.File]::ReadAllText($Path)
    if ($text -notmatch $Pattern) { throw $Message }
}

function Assert-RequiredFiles {
    param([Parameter(Mandatory)][string[]]$RelativePaths)
    foreach ($relative in $RelativePaths) {
        $path = Join-Path $RepoRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Windows setup contract file is missing: $relative"
        }
    }
}

$lifecycleFiles = @(
    'HMS-Lifecycle.cmd',
    'scripts/Invoke-HmsLifecycleAction.ps1'
)
$bootstrapFiles = @(
    'installer/setup-tools.lock.json',
    'installer/Invoke-HmsSetupBootstrap.ps1'
)
$desktopFiles = @(
    'global.json',
    'desktop/HmsSuperpowers/HmsSuperpowers.csproj',
    'desktop/HmsSuperpowers/Program.cs',
    'desktop/HmsSuperpowers/HmsPaths.cs',
    'desktop/HmsSuperpowers/HmsStatusReader.cs',
    'desktop/HmsSuperpowers/HmsProcessRunner.cs',
    'desktop/HmsSuperpowers/MainForm.cs'
)
$installerFiles = @('installer/HMS-Superpowers.iss')
$workflowFiles = @('.github/workflows/validate-windows-setup-menu.yml')

if ($Scope -in @('All','Lifecycle')) {
    Assert-RequiredFiles -RelativePaths $lifecycleFiles

    $lifecycleCmdPath = Join-Path $RepoRoot 'HMS-Lifecycle.cmd'
    Assert-TextContains -Path $lifecycleCmdPath -Pattern 'rev-parse HEAD' -Message 'Lifecycle launcher must bind to canonical HMS HEAD.'
    Assert-TextContains -Path $lifecycleCmdPath -Pattern 'cat-file -t' -Message 'Lifecycle launcher must prove committed bootstrap blob type.'
    Assert-TextContains -Path $lifecycleCmdPath -Pattern 'blob ' -Message 'Lifecycle launcher must calculate Git blob identity for live bytes.'
    Assert-TextContains -Path $lifecycleCmdPath -Pattern '\[ScriptBlock\]::Create' -Message 'Lifecycle launcher must execute authenticated shim bytes in memory.'

    $lifecycleShimPath = Join-Path $RepoRoot 'scripts\Invoke-HmsLifecycleAction.ps1'
    Assert-TextContains -Path $lifecycleShimPath -Pattern "ValidateSet\('update','repair','uninstall'\)" -Message 'Lifecycle shim must restrict action tokens.'
    Assert-TextContains -Path $lifecycleShimPath -Pattern 'TrustedRepoRoot' -Message 'Lifecycle shim must receive trusted repository root.'
    Assert-TextContains -Path $lifecycleShimPath -Pattern 'TrustedHead' -Message 'Lifecycle shim must receive trusted HEAD.'
    Assert-TextContains -Path $lifecycleShimPath -Pattern 'TrustedBootstrapBlob' -Message 'Lifecycle shim must receive trusted bootstrap blob.'
    Assert-TextContains -Path $lifecycleShimPath -Pattern "cat-file'\s*,\s*'-t" -Message 'Lifecycle shim must prove target script object type.'
    Assert-TextContains -Path $lifecycleShimPath -Pattern '\[ScriptBlock\]::Create' -Message 'Lifecycle shim must execute authenticated target bytes in memory.'
    $lifecycleShimText = [IO.File]::ReadAllText($lifecycleShimPath)
    if ($lifecycleShimText -match '(?i)powershell(?:\.exe)?[^\r\n]*-File[^\r\n]*(install|update|uninstall)\.ps1') {
        throw 'Lifecycle shim must not execute mutable lifecycle scripts through powershell -File.'
    }

    if ($Scope -eq 'Lifecycle') {
        Write-Host 'PASS: HMS authenticated lifecycle launcher static contract is satisfied.'
        return
    }
}

if ($Scope -in @('All','Bootstrap')) {
    Assert-RequiredFiles -RelativePaths $bootstrapFiles

    $toolsLockPath = Join-Path $RepoRoot 'installer\setup-tools.lock.json'
    $toolsLock = Get-Content -LiteralPath $toolsLockPath -Raw | ConvertFrom-Json
    if ([int]$toolsLock.schema_version -ne 1) { throw 'setup-tools.lock.json schema_version must be 1.' }
    $expectedLock = [ordered]@{
        mingit_repository = 'git-for-windows/git'
        mingit_tag = 'v2.55.0.windows.5'
        mingit_asset = 'MinGit-2.55.0.5-64-bit.zip'
        mingit_sha256 = '56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e'
        codex_repository = 'openai/codex'
        codex_tag = 'rust-v0.152.1'
        codex_asset = 'codex-x86_64-pc-windows-msvc.exe.zip'
        codex_archive_sha256 = '11634c7da0aadf53dff3ec0bad9fd3715371afff189becac433270b21cf299c9'
        codex_exe_sha256 = '01b0fd4167393e004b9174c77ae5f8570486118e19dc4216cfc62a62a74b6ee6'
    }
    $actualLock = [ordered]@{
        mingit_repository = [string]$toolsLock.mingit.repository
        mingit_tag = [string]$toolsLock.mingit.tag
        mingit_asset = [string]$toolsLock.mingit.asset
        mingit_sha256 = ([string]$toolsLock.mingit.sha256).ToLowerInvariant()
        codex_repository = [string]$toolsLock.codex.repository
        codex_tag = [string]$toolsLock.codex.tag
        codex_asset = [string]$toolsLock.codex.asset
        codex_archive_sha256 = ([string]$toolsLock.codex.archive_sha256).ToLowerInvariant()
        codex_exe_sha256 = ([string]$toolsLock.codex.exe_sha256).ToLowerInvariant()
    }
    foreach ($key in $expectedLock.Keys) {
        if ($actualLock[$key] -cne $expectedLock[$key]) { throw "Unexpected setup tool lock value for $key." }
    }

    $bootstrapPath = Join-Path $RepoRoot 'installer\Invoke-HmsSetupBootstrap.ps1'
    Assert-TextContains -Path $bootstrapPath -Pattern 'Assert-HmsSha256' -Message 'Setup bootstrap must verify SHA-256.'
    Assert-TextContains -Path $bootstrapPath -Pattern 'Ensure-HmsMinGit' -Message 'Setup bootstrap must provision HMS-owned MinGit.'
    Assert-TextContains -Path $bootstrapPath -Pattern 'Resolve-HmsCodex' -Message 'Setup bootstrap must qualify or provision Codex.'
    Assert-TextContains -Path $bootstrapPath -Pattern 'Assert-HmsSafeDirectory' -Message 'Setup bootstrap must guard setup-owned directories.'
    $parseTokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        $first = $parseErrors[0]
        throw "Setup bootstrap PowerShell parse failed at line $($first.Extent.StartLineNumber), column $($first.Extent.StartColumnNumber): $($first.Message)"
    }
    $bootstrapText = [IO.File]::ReadAllText($bootstrapPath)
    if ($bootstrapText -match '(?i)/latest/' -or $bootstrapText -match '(?i)npm\s+install') {
        throw 'Setup bootstrap must not use runtime latest URLs or npm install.'
    }

    if ($Scope -eq 'Bootstrap') {
        Write-Host 'PASS: HMS setup bootstrap static contract is satisfied.'
        return
    }
}

if ($Scope -in @('All','Desktop')) {
    Assert-RequiredFiles -RelativePaths $desktopFiles

    $globalJsonPath = Join-Path $RepoRoot 'global.json'
    $globalJson = Get-Content -LiteralPath $globalJsonPath -Raw | ConvertFrom-Json
    if ([string]$globalJson.sdk.version -cne '10.0.400') { throw 'global.json must pin .NET SDK 10.0.400.' }
    if ([string]$globalJson.sdk.rollForward -cne 'disable') { throw 'global.json must disable SDK roll-forward.' }

    $projectPath = Join-Path $RepoRoot 'desktop\HmsSuperpowers\HmsSuperpowers.csproj'
    Assert-TextContains -Path $projectPath -Pattern '<TargetFramework>net10\.0-windows</TargetFramework>' -Message 'WinForms target framework must be net10.0-windows.'
    Assert-TextContains -Path $projectPath -Pattern '<UseWindowsForms>true</UseWindowsForms>' -Message 'WinForms project must enable UseWindowsForms.'
    Assert-TextContains -Path $projectPath -Pattern '<RuntimeIdentifier>win-x64</RuntimeIdentifier>' -Message 'WinForms project must pin win-x64.'
    Assert-TextContains -Path $projectPath -Pattern '<SelfContained>true</SelfContained>' -Message 'WinForms project must be self-contained.'
    Assert-TextContains -Path $projectPath -Pattern '<PublishSingleFile>true</PublishSingleFile>' -Message 'WinForms project must publish a single-file executable.'
    Assert-TextContains -Path $projectPath -Pattern '<PlatformTarget>x64</PlatformTarget>' -Message 'WinForms project must target x64.'

    $mainFormPath = Join-Path $RepoRoot 'desktop\HmsSuperpowers\MainForm.cs'
    $mainFormText = [IO.File]::ReadAllText($mainFormPath)
    foreach ($label in @('Quản lý Skills','Cài đặt Model','Update HMS','Repair / Rebuild','Kiểm tra hệ thống','Mở thư mục HMS','Uninstall')) {
        if (-not $mainFormText.Contains($label)) { throw "WinForms menu is missing approved action label: $label" }
    }

    if ($Scope -eq 'Desktop') {
        Write-Host 'PASS: HMS Windows menu static contract is satisfied.'
        return
    }
}

if ($Scope -in @('All','Installer')) {
    Assert-RequiredFiles -RelativePaths $installerFiles

    $innoPath = Join-Path $RepoRoot 'installer\HMS-Superpowers.iss'
    Assert-TextContains -Path $innoPath -Pattern 'PrivilegesRequired=lowest' -Message 'Setup must remain per-user without elevation.'
    Assert-TextContains -Path $innoPath -Pattern 'DefaultDirName=\{localappdata\}\\Programs\\HMS Superpowers' -Message 'Setup default app root must be per-user LocalAppData.'
    Assert-TextContains -Path $innoPath -Pattern 'AppVersion=0\.3\.0' -Message 'Setup AppVersion must be 0.3.0.'
    Assert-TextContains -Path $innoPath -Pattern 'OutputBaseFilename=HMS-Superpowers-Setup-v0\.3\.0' -Message 'Setup output filename mismatch.'
    Assert-TextContains -Path $innoPath -Pattern 'desktopicon' -Message 'Setup must define a Desktop shortcut task.'
    Assert-TextContains -Path $innoPath -Pattern 'HMS Superpowers' -Message 'Setup must define HMS Superpowers shortcuts.'

    if ($Scope -eq 'Installer') {
        Write-Host 'PASS: HMS Inno Setup static contract is satisfied.'
        return
    }
}

if ($Scope -in @('All','Workflow')) {
    Assert-RequiredFiles -RelativePaths $workflowFiles

    $workflowPath = Join-Path $RepoRoot '.github\workflows\validate-windows-setup-menu.yml'
    Assert-TextContains -Path $workflowPath -Pattern 'CANDIDATE_SHA' -Message 'Windows workflow must bind to exact candidate SHA.'
    Assert-TextContains -Path $workflowPath -Pattern '3d3c42e5aac5ba805825da76410c181273ba90b1' -Message 'Windows workflow must pin actions/checkout v7.0.1 commit.'
    Assert-TextContains -Path $workflowPath -Pattern '10\.0\.400' -Message 'Windows workflow must use .NET SDK 10.0.400.'
    Assert-TextContains -Path $workflowPath -Pattern '7\.1\.0' -Message 'Windows workflow must pin Inno Setup 7.1.0.'

    if ($Scope -eq 'Workflow') {
        Write-Host 'PASS: HMS Windows qualification workflow static contract is satisfied.'
        return
    }
}

Write-Host 'PASS: HMS Windows setup/menu static contract is satisfied.'
