# Authenticated committed-object helpers for install/update lifecycle execution.
# This file is never trusted by pathname: install.ps1/update.ps1 first load its exact
# committed blob from a captured HMS HEAD, verify the Git object identity, then dot-source
# the resulting in-memory ScriptBlock.

function Get-HmsCommittedBlobSnapshot {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )

    $headValue = $Head.Trim().ToLowerInvariant()
    if ($headValue -notmatch '^[0-9a-f]{40}$') { throw "$Label trusted HEAD is invalid: $Head" }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\\') -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "$Label committed relative path is unsafe: $RelativePath"
    }
    $gitPath = $RelativePath.Replace('\','/')
    $expected = ((& git -C $RepoRoot rev-parse "$headValue`:$gitPath" 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $expected -notmatch '^[0-9a-f]{40}$') { throw "$Label committed blob is unavailable: $gitPath" }
    $type = ((& git -C $RepoRoot cat-file -t $expected 2>$null) -join '').Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $type -cne 'blob') { throw "$Label committed object is not a blob: $gitPath" }

    $isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    if ($isWindowsPlatform) {
        $gitExe = @((Get-Command git.exe -CommandType Application -ErrorAction Stop))[0].Source
        $cmdExe = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ('hms-committed-blob-' + [guid]::NewGuid().ToString('N') + '.bin')
        $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ('hms-committed-blob-' + [guid]::NewGuid().ToString('N') + '.err')
        foreach ($commandPath in @($gitExe,$cmdExe,$RepoRoot,$stdoutPath,$stderrPath)) {
            if ([string]::IsNullOrWhiteSpace($commandPath) -or $commandPath -match '["%\r\n]') {
                throw "$Label command path is unsafe for exact cmd.exe redirection: $commandPath"
            }
        }
        if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) { throw "$Label resolved git.exe does not exist: $gitExe" }
        if (-not (Test-Path -LiteralPath $cmdExe -PathType Leaf)) { throw "$Label trusted cmd.exe does not exist: $cmdExe" }

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $cmdExe
        $psi.Arguments = ('/d /q /v:off /s /c ""{0}" -C "{1}" cat-file blob {2} > "{3}" 2> "{4}""' -f $gitExe,$RepoRoot,$expected,$stdoutPath,$stderrPath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi
        try {
            if (-not $proc.Start()) { throw "$Label could not start trusted cmd.exe for git cat-file." }
            if (-not $proc.WaitForExit(10000)) {
                try { $proc.Kill() } catch {}
                throw "$Label git cat-file timed out after 10 seconds."
            }
            $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [IO.File]::ReadAllText($stderrPath) } else { '' }
            if ($proc.ExitCode -ne 0) { throw "$Label git cat-file failed: $stderr" }
            if (-not (Test-Path -LiteralPath $stdoutPath -PathType Leaf)) { throw "$Label git cat-file output file was not created." }
            if (-not [string]::IsNullOrEmpty($stderr)) { throw "$Label git cat-file produced unexpected stderr: $stderr" }
            $bytes = [IO.File]::ReadAllBytes($stdoutPath)
        }
        finally {
            $proc.Dispose()
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        $gitCommand = @((Get-Command git -CommandType Application -ErrorAction Stop))[0]
        $gitExecutablePath = [string]$gitCommand.Source
        if ([string]::IsNullOrWhiteSpace($gitExecutablePath) -or -not (Test-Path -LiteralPath $gitExecutablePath -PathType Leaf)) { throw "Resolved git executable does not exist: $gitExecutablePath" }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $gitExecutablePath
        $psi.Arguments = "cat-file blob $expected"
        $psi.WorkingDirectory = $RepoRoot
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi
        $memory = New-Object IO.MemoryStream
        try {
            if (-not $proc.Start()) { throw '$Label could not start git cat-file.' }
            $copyTask = $proc.StandardOutput.BaseStream.CopyToAsync($memory)
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(10000)) {
                try { $proc.Kill() } catch {}
                try { $proc.WaitForExit() } catch {}
                throw '$Label git cat-file timed out after 10 seconds.'
            }
            $null = $copyTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            if ($proc.ExitCode -ne 0) { throw "$Label git cat-file failed: $stderr" }
            if (-not [string]::IsNullOrEmpty($stderr)) { throw "$Label git cat-file produced unexpected stderr: $stderr" }
            $bytes = $memory.ToArray()
        }
        finally {
            $memory.Dispose()
            $proc.Dispose()
        }
    }

    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + [string]$bytes.Length + [char]0))
    $sha1 = [Security.Cryptography.SHA1]::Create()
    $hashStream = New-Object IO.MemoryStream
    try {
        $hashStream.Write($header,0,$header.Length)
        if ($bytes.Length -gt 0) { $hashStream.Write($bytes,0,$bytes.Length) }
        $hashStream.Position = 0
        $actual = (($sha1.ComputeHash($hashStream) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $hashStream.Dispose()
        $sha1.Dispose()
    }
    if ($actual -cne $expected) { throw "$Label committed-byte identity mismatch. Expected $expected, found $actual." }
    return [pscustomobject]@{ Sha=$expected; Bytes=[byte[]]$bytes; RelativePath=$gitPath }
}

function Get-HmsCommittedUtf8Text {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $snapshot = Get-HmsCommittedBlobSnapshot -RepoRoot $RepoRoot -Head $Head -RelativePath $RelativePath -Label $Label
    try { $text = (New-Object Text.UTF8Encoding($false,$true)).GetString([byte[]]$snapshot.Bytes) }
    catch { throw "$Label committed bytes are not strict UTF-8: $($_.Exception.Message)" }
    return [pscustomobject]@{ Sha=[string]$snapshot.Sha; Text=$text; RelativePath=[string]$snapshot.RelativePath }
}

function Get-HmsCommittedScriptSnapshot {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $text = Get-HmsCommittedUtf8Text -RepoRoot $RepoRoot -Head $Head -RelativePath $RelativePath -Label $Label
    try { $script = [ScriptBlock]::Create([string]$text.Text) }
    catch { throw "$Label committed PowerShell could not be parsed: $($_.Exception.Message)" }
    return [pscustomobject]@{ Sha=[string]$text.Sha; ScriptBlock=$script; RelativePath=[string]$text.RelativePath }
}

function Get-HmsCommittedLifecycleScriptSnapshot {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$ScriptRelativePath,
        [Parameter(Mandatory)][string]$LockRelativePath,
        [Parameter(Mandatory)][string]$Label
    )

    $scriptText = Get-HmsCommittedUtf8Text -RepoRoot $RepoRoot -Head $Head -RelativePath $ScriptRelativePath -Label $Label
    $lockText = Get-HmsCommittedUtf8Text -RepoRoot $RepoRoot -Head $Head -RelativePath $LockRelativePath -Label "$Label lock"
    $source = [string]$scriptText.Text

    $rootLiteral = '$RepoRoot = Split-Path -Parent $PSScriptRoot'
    $rootMatches = [regex]::Matches($source,[regex]::Escape($rootLiteral)).Count
    if ($rootMatches -ne 1) { throw "$Label trusted transform expected exactly one repository-root bootstrap, found $rootMatches." }
    $source = $source.Replace($rootLiteral,'$RepoRoot = $HmsTrustedRepoRoot')

    if ($ScriptRelativePath.Replace('\','/') -ceq 'scripts/Sync-UiSkills.ps1') {
        $lockExistenceLiteral = 'if (-not (Test-Path -LiteralPath $LockPath)) { throw "UI skills lock file not found: $LockPath" }'
    }
    elseif ($ScriptRelativePath.Replace('\','/') -ceq 'scripts/Sync-DeliveryTools.ps1') {
        $lockExistenceLiteral = 'if (-not (Test-Path -LiteralPath $LockPath)) { throw "Delivery tools lock file not found: $LockPath" }'
    }
    else {
        throw "$Label trusted lifecycle transform is not authorized for script: $ScriptRelativePath"
    }
    $existenceMatches = [regex]::Matches($source,[regex]::Escape($lockExistenceLiteral)).Count
    if ($existenceMatches -ne 1) { throw "$Label trusted transform expected exactly one live lock existence check, found $existenceMatches." }
    $source = $source.Replace($lockExistenceLiteral,'if ([string]::IsNullOrWhiteSpace($HmsTrustedLockJson)) { throw "Trusted committed lock JSON is empty." }')

    $lockLiteral = 'try { $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json }'
    $lockMatches = [regex]::Matches($source,[regex]::Escape($lockLiteral)).Count
    if ($lockMatches -ne 1) { throw "$Label trusted transform expected exactly one live lock read, found $lockMatches." }
    $source = $source.Replace($lockLiteral,'try { $lock = $HmsTrustedLockJson | ConvertFrom-Json }')

    # Bind the only transformed trust values into a private closure so the helper never falls back
    # to caller-supplied/live pathname state. The executable source remains exact committed source
    # except for three mechanically asserted substitutions: repo root, lock existence, lock bytes.
    $HmsTrustedRepoRoot = $RepoRoot
    $HmsTrustedLockJson = [string]$lockText.Text
    try { $script = [ScriptBlock]::Create($source).GetNewClosure() }
    catch { throw "$Label trusted transformed PowerShell could not be parsed: $($_.Exception.Message)" }
    return [pscustomobject]@{
        Sha=[string]$scriptText.Sha
        LockSha=[string]$lockText.Sha
        ScriptBlock=$script
        RelativePath=[string]$scriptText.RelativePath
    }
}
