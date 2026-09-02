namespace HmsSuperpowers;

internal enum HmsLifecycleAction
{
    Update,
    Repair,
    Uninstall
}

internal sealed record HmsPaths(
    string RepoRoot,
    string AppRoot,
    string SupportGitRoot,
    string SupportCodexRoot,
    string LifecycleLauncher)
{
    public string ManagerLauncher => Path.Combine(RepoRoot, "HMS-Superpowers-Manager.cmd");
    public string ModelSettingsLauncher => Path.Combine(RepoRoot, "HMS-Model-Settings.cmd");
    public string RegisteredUninstaller => Path.Combine(AppRoot, "unins000.exe");

    public static HmsPaths ForCurrentUser()
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        if (string.IsNullOrWhiteSpace(userProfile))
        {
            throw new InvalidOperationException("Unable to resolve the current user profile.");
        }

        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("Unable to resolve LocalAppData for the current user.");
        }

        var repoRoot = Path.GetFullPath(Path.Combine(userProfile, ".codex", "hms-skills-codex"));
        var appRoot = Path.GetFullPath(Path.Combine(localAppData, "Programs", "HMS Superpowers"));
        var supportRoot = Path.Combine(appRoot, "support");

        return new HmsPaths(
            repoRoot,
            appRoot,
            Path.Combine(supportRoot, "git"),
            Path.Combine(supportRoot, "codex"),
            Path.Combine(repoRoot, "HMS-Lifecycle.cmd"));
    }
}
