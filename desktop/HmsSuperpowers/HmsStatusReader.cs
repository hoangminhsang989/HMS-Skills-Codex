using System.Diagnostics;

namespace HmsSuperpowers;

internal sealed record HmsStatusSnapshot(
    bool RepoPresent,
    bool RepoClean,
    string Head,
    string Version,
    string GitState,
    string CodexState,
    string CompositeState,
    string PublicSkillState);

internal sealed class HmsStatusReader
{
    private readonly HmsPaths _paths;

    public HmsStatusReader(HmsPaths paths)
    {
        _paths = paths;
    }

    public async Task<HmsStatusSnapshot> ReadAsync(CancellationToken cancellationToken)
    {
        var repoPresent = Directory.Exists(_paths.RepoRoot) && !IsReparsePoint(_paths.RepoRoot);
        var gitExe = Path.Combine(_paths.SupportGitRoot, "cmd", "git.exe");
        var codexExe = Path.Combine(_paths.SupportCodexRoot, "codex.exe");

        var gitReady = IsRegularFile(gitExe);
        var codexReady = IsRegularFile(codexExe);
        var head = "-";
        var repoClean = false;

        if (repoPresent && gitReady)
        {
            var headResult = await RunProcessAsync(
                gitExe,
                _paths.RepoRoot,
                new[] { "-C", _paths.RepoRoot, "rev-parse", "HEAD" },
                cancellationToken).ConfigureAwait(false);

            if (headResult.ExitCode == 0)
            {
                var candidate = headResult.StandardOutput.Trim().ToLowerInvariant();
                if (candidate.Length == 40 && candidate.All(Uri.IsHexDigit))
                {
                    head = candidate;
                }
            }

            var statusResult = await RunProcessAsync(
                gitExe,
                _paths.RepoRoot,
                new[] { "-C", _paths.RepoRoot, "status", "--porcelain=v1", "--untracked-files=all" },
                cancellationToken).ConfigureAwait(false);

            repoClean = statusResult.ExitCode == 0 && string.IsNullOrWhiteSpace(statusResult.StandardOutput);
        }

        var versionPath = Path.Combine(_paths.RepoRoot, "VERSION");
        var version = IsRegularFile(versionPath)
            ? (await File.ReadAllTextAsync(versionPath, cancellationToken).ConfigureAwait(false)).Trim()
            : "-";

        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var compositeManifest = Path.Combine(userProfile, ".codex", "hms-composite", "manifest.json");
        var publicSkill = Path.Combine(userProfile, ".agents", "skills", "hms-superpowers", "SKILL.md");

        var gitState = gitReady ? "HMS MinGit: ready" : "HMS MinGit: missing";
        var codexState = codexReady ? "HMS Codex fallback: ready" : "HMS Codex fallback: missing";
        var compositeState = IsRegularFile(compositeManifest) ? "Composite: present" : "Composite: missing";
        var publicSkillState = IsRegularFile(publicSkill) ? "$hms-superpowers: present" : "$hms-superpowers: missing";

        return new HmsStatusSnapshot(
            repoPresent,
            repoClean,
            head,
            string.IsNullOrWhiteSpace(version) ? "-" : version,
            gitState,
            codexState,
            compositeState,
            publicSkillState);
    }

    private static bool IsRegularFile(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return false;
            }

            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch
        {
            return true;
        }
    }

    private static async Task<ProcessResult> RunProcessAsync(
        string executable,
        string workingDirectory,
        IEnumerable<string> arguments,
        CancellationToken cancellationToken)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            }
        };

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        if (!process.Start())
        {
            return new ProcessResult(-1, string.Empty, "Process did not start.");
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();

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
        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        return new ProcessResult(process.ExitCode, stdout, stderr);
    }

    private sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError);
}
