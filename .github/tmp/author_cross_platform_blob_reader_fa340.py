from pathlib import Path

ROOT = Path.cwd()
START = "    $gitExe = @((Get-Command git.exe -CommandType Application -ErrorAction Stop))[0].Source\n"
END = "\n    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + [string]$bytes.Length + [char]0))"


def indent_block(text: str, spaces: int) -> str:
    prefix = ' ' * spaces
    return ''.join(prefix + line if line.strip() else line for line in text.splitlines(True))


def non_windows_block(label_expr: str) -> str:
    if label_expr == 'bootstrap':
        start_error = "Lifecycle trust bootstrap could not start git cat-file."
        timeout_error = "Lifecycle trust bootstrap git cat-file timed out after 10 seconds."
        failed_prefix = "Lifecycle trust bootstrap git cat-file failed"
        stderr_prefix = "Lifecycle trust bootstrap git cat-file produced unexpected stderr"
    else:
        start_error = "$Label could not start git cat-file."
        timeout_error = "$Label git cat-file timed out after 10 seconds."
        failed_prefix = "$Label git cat-file failed"
        stderr_prefix = "$Label git cat-file produced unexpected stderr"
    return f'''        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop
        $gitPath = [string]$gitCommand.Source
        if ([string]::IsNullOrWhiteSpace($gitPath) -or -not (Test-Path -LiteralPath $gitPath -PathType Leaf)) {{ throw "Resolved git executable does not exist: $gitPath" }}
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $gitPath
        $psi.Arguments = "cat-file blob $expected"
        $psi.WorkingDirectory = $RepoRoot
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi
        $memory = New-Object IO.MemoryStream
        try {{
            if (-not $proc.Start()) {{ throw '{start_error}' }}
            $copyTask = $proc.StandardOutput.BaseStream.CopyToAsync($memory)
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(10000)) {{
                try {{ $proc.Kill() }} catch {{}}
                try {{ $proc.WaitForExit() }} catch {{}}
                throw '{timeout_error}'
            }}
            $copyTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            if ($proc.ExitCode -ne 0) {{ throw "{failed_prefix}: $stderr" }}
            if (-not [string]::IsNullOrEmpty($stderr)) {{ throw "{stderr_prefix}: $stderr" }}
            $bytes = $memory.ToArray()
        }}
        finally {{
            $memory.Dispose()
            $proc.Dispose()
        }}
'''


def patch(path: Path, mode: str) -> None:
    text = path.read_bytes().decode('utf-8').replace('\r\n', '\n')
    if text.count(START) != 1:
        raise RuntimeError(f'{path}: expected one Windows blob-reader start, found {text.count(START)}')
    start = text.index(START)
    if text[start:].count(END) != 1:
        raise RuntimeError(f'{path}: expected one SHA-1 boundary after reader')
    end = text.index(END, start)
    win = text[start:end]
    required = [
        "Join-Path ([Environment]::SystemDirectory) 'cmd.exe'",
        '$proc.WaitForExit(10000)',
        '[IO.File]::ReadAllBytes($stdoutPath)',
        "'/d /q /v:off /s /c",
        'Remove-Item -LiteralPath $stdoutPath',
        'Remove-Item -LiteralPath $stderrPath'
    ]
    missing = [item for item in required if item not in win]
    if missing:
        raise RuntimeError(f'{path}: Windows remediation contract mismatch: {missing}')
    replacement = (
        "    $isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT\n"
        "    if ($isWindowsPlatform) {\n"
        + indent_block(win, 4)
        + "    }\n"
        + "    else {\n"
        + non_windows_block(mode)
        + "    }\n"
    )
    path.write_bytes((text[:start] + replacement + text[end:]).encode('utf-8'))


patch(ROOT / 'install.ps1', 'bootstrap')
patch(ROOT / 'update.ps1', 'bootstrap')
patch(ROOT / 'scripts' / 'Initialize-HmsLifecycleTrust.ps1', 'helper')
print('PATCH_CROSS_PLATFORM_3_OF_3=PASS')
