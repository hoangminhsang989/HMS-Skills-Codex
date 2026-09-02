using System.Diagnostics;

namespace HmsSuperpowers;

internal sealed record HmsProcessResult(int ExitCode, string Summary)
{
    public bool Succeeded => ExitCode == 0;
}

internal sealed class HmsProcessRunner
{
    private readonly HmsPaths _paths;

    public HmsProcessRunner(HmsPaths paths)
    {
        _paths = paths;
    }

    public Task<HmsProcessResult> RunLifecycleAsync(
        HmsLifecycleAction action,
        IProgress<string> progress,
        CancellationToken cancellationToken)
    {
        var token = action switch
        {
            HmsLifecycleAction.Update => "update",
            HmsLifecycleAction.Repair => "repair",
            HmsLifecycleAction.Uninstall => "uninstall",
            _ => throw new ArgumentOutOfRangeException(nameof(action))
        };

        return RunAuthenticatedLauncherAsync(_paths.LifecycleLauncher, token, progress, cancellationToken);
    }

    public Task<HmsProcessResult> RunManagerAsync(
        IProgress<string> progress,
        CancellationToken cancellationToken) =>
        RunAuthenticatedLauncherAsync(_paths.ManagerLauncher, null, progress, cancellationToken);

    public Task<HmsProcessResult> RunModelSettingsAsync(
        IProgress<string> progress,
        CancellationToken cancellationToken) =>
        RunAuthenticatedLauncherAsync(_paths.ModelSettingsLauncher, null, progress, cancellationToken);

    public void StartRegisteredUninstaller()
    {
        if (!IsRegularFile(_paths.RegisteredUninstaller))
        {
            throw new FileNotFoundException("The registered HMS Setup uninstaller is missing.", _paths.RegisteredUninstaller);
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = _paths.RegisteredUninstaller,
            WorkingDirectory = _paths.AppRoot,
            UseShellExecute = true
        });
    }

    private async Task<HmsProcessResult> RunAuthenticatedLauncherAsync(
        string launcher,
        string? action,
        IProgress<string> progress,
        CancellationToken cancellationToken)
    {
        if (!IsRegularFile(launcher))
        {
            throw new FileNotFoundException("Authenticated HMS launcher is missing or unsafe.", launcher);
        }

        if (launcher.IndexOfAny(['"', '\r', '\n']) >= 0)
        {
            throw new InvalidOperationException("Authenticated HMS launcher path contains unsafe command characters.");
        }

        var cmdExe = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        if (!IsRegularFile(cmdExe))
        {
            throw new FileNotFoundException("Trusted Windows cmd.exe is missing.", cmdExe);
        }

        var command = action is null
            ? $"\"\"{launcher}\"\""
            : $"\"\"{launcher}\" {action}\"";

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = cmdExe,
                Arguments = $"/d /q /v:off /s /c {command}",
                WorkingDirectory = _paths.RepoRoot,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            }
        };

        ConfigureChildEnvironment(process.StartInfo);

        if (!process.Start())
        {
            throw new InvalidOperationException("HMS launcher process did not start.");
        }

        var stdoutTask = DrainAsync(process.StandardOutput, progress, cancellationToken);
        var stderrTask = DrainAsync(process.StandardError, progress, cancellationToken);

        using var registration = cancellationToken.Register(() =>
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
            }
        });

        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);

        var summary = process.ExitCode == 0
            ? "HMS action completed successfully."
            : $"HMS action failed with exit code {process.ExitCode}.";
        progress.Report(summary);
        return new HmsProcessResult(process.ExitCode, summary);
    }

    private void ConfigureChildEnvironment(ProcessStartInfo startInfo)
    {
        var segments = new List<string>();
        var gitCmd = Path.Combine(_paths.SupportGitRoot, "cmd");
        if (Directory.Exists(gitCmd))
        {
            segments.Add(gitCmd);
        }

        if (Directory.Exists(_paths.SupportCodexRoot))
        {
            segments.Add(_paths.SupportCodexRoot);
        }

        var inheritedPath = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrWhiteSpace(inheritedPath))
        {
            segments.Add(inheritedPath);
        }

        startInfo.Environment["PATH"] = string.Join(Path.PathSeparator, segments);
    }

    private static async Task DrainAsync(
        StreamReader reader,
        IProgress<string> progress,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null)
            {
                break;
            }

            if (!string.IsNullOrWhiteSpace(line))
            {
                progress.Report(line);
            }
        }
    }

    private static bool IsRegularFile(string path)
    {
        try
        {
            return File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
        }
        catch
        {
            return false;
        }
    }
}
