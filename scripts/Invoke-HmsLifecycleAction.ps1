[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('update','repair','uninstall')]
    [string]$Action,
    [Parameter(Mandatory)]
    [string]$TrustedRepoRoot,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$TrustedHead,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$TrustedBootstrapBlob
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HmsGitBlobSha1 {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + [string]$Bytes.Length + [char]0))
    $sha = [Security.Cryptography.SHA1]::Create()
    $memory = New-Object IO.MemoryStream
    try {
        $memory.Write($header,0,$header.Length)
        if ($Bytes.Length -gt 0) { $memory.Write($Bytes,0,$Bytes.Length) }
        $memory.Position = 0
        return (($sha.ComputeHash($memory) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $memory.Dispose()
        $sha.Dispose()
    }
}

function Read-HmsExactFileBytes {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Trusted lifecycle path is not a file: $Path" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Trusted lifecycle path is a reparse point: $Path"
    }

    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt [int]::MaxValue) { throw "Trusted lifecycle file is too large: $Path" }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($count -le 0) { throw "Trusted lifecycle file ended before snapshot completion: $Path" }
            $offset += $count
        }
        return $bytes
    }
    finally {
        $stream.Dispose()
    }
}

$repoRoot = [IO.Path]::GetFullPath($TrustedRepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { throw "Trusted HMS repository root is missing: $repoRoot" }
$repoItem = Get-Item -LiteralPath $repoRoot -Force
if (($repoItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Trusted HMS repository root must not be a reparse point.' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) { throw "Trusted HMS repository has no Git metadata: $repoRoot" }

$gitCommand = @((Get-Command git.exe -CommandType Application -ErrorAction Stop))[0]
$script:GitExe = [string]$gitCommand.Source
if ([string]::IsNullOrWhiteSpace($script:GitExe) -or -not (Test-Path -LiteralPath $script:GitExe -PathType Leaf)) {
    throw 'Lifecycle shim could not resolve git.exe to an executable file.'
}

function Invoke-HmsGitText {
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$FailureMessage)

    $output = @(& $script:GitExe @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw $FailureMessage }
    return (($output -join "`n").Trim())
}

$currentHead = (Invoke-HmsGitText -Arguments @('-C',$repoRoot,'rev-parse','HEAD') -FailureMessage 'Lifecycle shim could not re-resolve HMS HEAD.').ToLowerInvariant()
if ($currentHead -notmatch '^[0-9a-f]{40}$' -or $currentHead -cne $TrustedHead.ToLowerInvariant()) {
    throw "Lifecycle trusted-HEAD handoff mismatch. Expected $TrustedHead, found $currentHead."
}

$bootstrapSpec = $TrustedHead.ToLowerInvariant() + ':scripts/Invoke-HmsLifecycleAction.ps1'
$resolvedBootstrap = (Invoke-HmsGitText -Arguments @('-C',$repoRoot,'rev-parse',$bootstrapSpec) -FailureMessage 'Lifecycle shim could not re-resolve its committed bootstrap blob.').ToLowerInvariant()
if ($resolvedBootstrap -notmatch '^[0-9a-f]{40}$' -or $resolvedBootstrap -cne $TrustedBootstrapBlob.ToLowerInvariant()) {
    throw "Lifecycle bootstrap-blob handoff mismatch. Expected $TrustedBootstrapBlob, found $resolvedBootstrap."
}
$bootstrapType = (Invoke-HmsGitText -Arguments @('-C',$repoRoot,'cat-file','-t',$resolvedBootstrap) -FailureMessage 'Lifecycle shim could not inspect its committed bootstrap object.').ToLowerInvariant()
if ($bootstrapType -cne 'blob') { throw 'Lifecycle shim bootstrap authority is not a committed blob.' }

function Get-HmsTrustedScriptBlock {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('install.ps1','update.ps1','uninstall.ps1')]
        [string]$RelativePath
    )

    $spec = $TrustedHead.ToLowerInvariant() + ':' + $RelativePath
    $expected = (Invoke-HmsGitText -Arguments @('-C',$repoRoot,'rev-parse',$spec) -FailureMessage "Unable to resolve committed lifecycle script: $RelativePath").ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{40}$') { throw "Committed lifecycle script identity is not canonical: $RelativePath" }

    $type = (Invoke-HmsGitText -Arguments @('-C',$repoRoot,'cat-file','-t',$expected) -FailureMessage "Unable to inspect committed lifecycle object: $RelativePath").ToLowerInvariant()
    if ($type -cne 'blob') { throw "Expected a committed blob for lifecycle script: $RelativePath" }

    $livePath = Join-Path $repoRoot $RelativePath
    $bytes = Read-HmsExactFileBytes -Path $livePath
    $actual = Get-HmsGitBlobSha1 -Bytes $bytes
    if ($actual -cne $expected) {
        throw "Lifecycle action rejected uncommitted bytes for $RelativePath. Expected $expected, found $actual."
    }

    $source = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($bytes)
    return [ScriptBlock]::Create($source)
}

$relativeTarget = switch ($Action) {
    'update' { 'update.ps1' }
    'repair' { 'install.ps1' }
    'uninstall' { 'uninstall.ps1' }
    default { throw "Unsupported lifecycle action: $Action" }
}

$targetScript = Get-HmsTrustedScriptBlock -RelativePath $relativeTarget
& $targetScript -InstallRoot $repoRoot
