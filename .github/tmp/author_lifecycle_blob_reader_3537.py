from pathlib import Path

root = Path.cwd()

old_bootstrap = r'''    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = "cat-file blob $expected"
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw 'Could not start git cat-file for lifecycle trust bootstrap.' }
    $memory = New-Object IO.MemoryStream
    try {
        $proc.StandardOutput.BaseStream.CopyTo($memory)
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "Lifecycle trust bootstrap git cat-file failed: $stderr" }
        $bytes = $memory.ToArray()
    }
    finally { $memory.Dispose(); $proc.Dispose() }
'''

new_bootstrap = r'''    $gitExe = @((Get-Command git.exe -CommandType Application -ErrorAction Stop))[0].Source
    $cmdExe = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ('hms-lifecycle-blob-' + [guid]::NewGuid().ToString('N') + '.bin')
    $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ('hms-lifecycle-blob-' + [guid]::NewGuid().ToString('N') + '.err')
    foreach ($commandPath in @($gitExe,$cmdExe,$RepoRoot,$stdoutPath,$stderrPath)) {
        if ([string]::IsNullOrWhiteSpace($commandPath) -or $commandPath -match '["%\r\n]') {
            throw "Lifecycle trust bootstrap command path is unsafe for exact cmd.exe redirection: $commandPath"
        }
    }
    if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) { throw "Resolved git.exe does not exist: $gitExe" }
    if (-not (Test-Path -LiteralPath $cmdExe -PathType Leaf)) { throw "Trusted cmd.exe does not exist: $cmdExe" }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cmdExe
    $psi.Arguments = ('/d /q /v:off /s /c ""{0}" -C "{1}" cat-file blob {2} > "{3}" 2> "{4}""' -f $gitExe,$RepoRoot,$expected,$stdoutPath,$stderrPath)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { throw 'Could not start trusted cmd.exe for lifecycle trust bootstrap.' }
        if (-not $proc.WaitForExit(10000)) {
            try { $proc.Kill() } catch {}
            throw 'Lifecycle trust bootstrap git cat-file timed out after 10 seconds.'
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [IO.File]::ReadAllText($stderrPath) } else { '' }
        if ($proc.ExitCode -ne 0) { throw "Lifecycle trust bootstrap git cat-file failed: $stderr" }
        if (-not (Test-Path -LiteralPath $stdoutPath -PathType Leaf)) { throw 'Lifecycle trust bootstrap output file was not created.' }
        if (-not [string]::IsNullOrEmpty($stderr)) { throw "Lifecycle trust bootstrap git cat-file produced unexpected stderr: $stderr" }
        $bytes = [IO.File]::ReadAllBytes($stdoutPath)
    }
    finally {
        $proc.Dispose()
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
'''

old_helper = r'''    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = "cat-file blob $expected"
    $psi.WorkingDirectory = $RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw "$Label could not start git cat-file." }
    $memory = New-Object IO.MemoryStream
    try {
        $proc.StandardOutput.BaseStream.CopyTo($memory)
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "$Label git cat-file failed: $stderr" }
        $bytes = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $proc.Dispose()
    }
'''

new_helper = r'''    $gitExe = @((Get-Command git.exe -CommandType Application -ErrorAction Stop))[0].Source
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
'''


def replace_exact(path: Path, old: str, new: str, label: str) -> None:
    raw = path.read_bytes()
    text = raw.decode('utf-8')
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected exactly one old block, found {count}')
    path.write_bytes(text.replace(old, new, 1).encode('utf-8'))


replace_exact(root / 'install.ps1', old_bootstrap, new_bootstrap, 'install bootstrap')
replace_exact(root / 'update.ps1', old_bootstrap, new_bootstrap, 'update bootstrap')
replace_exact(root / 'scripts' / 'Initialize-HmsLifecycleTrust.ps1', old_helper, new_helper, 'committed blob helper')
print('PATCH_3_OF_3_EXACT_BLOCKS=PASS')
