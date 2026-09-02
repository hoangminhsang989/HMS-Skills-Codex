namespace HmsSuperpowers;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

        var paths = HmsPaths.ForCurrentUser();
        var statusReader = new HmsStatusReader(paths);
        var processRunner = new HmsProcessRunner(paths);
        Application.Run(new MainForm(paths, statusReader, processRunner));
    }
}
