using System.Diagnostics;
using System.Drawing;

namespace HmsSuperpowers;

internal sealed class MainForm : Form
{
    private const int MaxLogCharacters = 24_000;

    private readonly HmsPaths _paths;
    private readonly HmsStatusReader _statusReader;
    private readonly HmsProcessRunner _processRunner;
    private readonly CancellationTokenSource _lifetimeCts = new();
    private readonly Label _statusLabel = new();
    private readonly TextBox _logBox = new();
    private readonly List<Button> _conflictingButtons = new();
    private bool _actionRunning;

    public MainForm(HmsPaths paths, HmsStatusReader statusReader, HmsProcessRunner processRunner)
    {
        _paths = paths;
        _statusReader = statusReader;
        _processRunner = processRunner;

        Text = "HMS Superpowers";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(760, 520);
        Size = new Size(820, 580);
        Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);

        BuildLayout();
        Shown += async (_, _) => await RefreshStatusAsync();
        FormClosed += (_, _) =>
        {
            _lifetimeCts.Cancel();
            _lifetimeCts.Dispose();
        };
    }

    private void BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(14),
            ColumnCount = 1,
            RowCount = 5
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var title = new Label
        {
            AutoSize = true,
            Text = "HMS Superpowers",
            Font = new Font(Font, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 6)
        };

        _statusLabel.AutoSize = true;
        _statusLabel.Text = "Đang kiểm tra trạng thái HMS...";
        _statusLabel.Margin = new Padding(0, 0, 0, 12);

        var actions = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 2,
            RowCount = 4,
            Margin = new Padding(0, 0, 0, 12)
        };
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));

        AddActionButton(actions, "Quản lý Skills", 0, 0, async () =>
            await RunExclusiveAsync((progress, token) => _processRunner.RunManagerAsync(progress, token)));
        AddActionButton(actions, "Cài đặt Model", 1, 0, async () =>
            await RunExclusiveAsync((progress, token) => _processRunner.RunModelSettingsAsync(progress, token)));
        AddActionButton(actions, "Update HMS", 0, 1, async () =>
            await RunLifecycleAsync(HmsLifecycleAction.Update));
        AddActionButton(actions, "Repair / Rebuild", 1, 1, async () =>
            await RunLifecycleAsync(HmsLifecycleAction.Repair));
        AddActionButton(actions, "Kiểm tra hệ thống", 0, 2, RefreshStatusAsync, conflictsWithMutation: false);
        AddActionButton(actions, "Mở thư mục HMS", 1, 2, OpenHmsFolder, conflictsWithMutation: false);
        AddActionButton(actions, "Uninstall", 0, 3, UninstallAsync);

        _logBox.Dock = DockStyle.Fill;
        _logBox.Multiline = true;
        _logBox.ReadOnly = true;
        _logBox.ScrollBars = ScrollBars.Vertical;
        _logBox.WordWrap = true;
        _logBox.BackColor = SystemColors.Window;

        var footer = new Label
        {
            AutoSize = true,
            Text = "PowerShell lifecycle hiện hữu vẫn là authority; GUI chỉ điều phối outer launchers đã xác thực.",
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 8, 0, 0)
        };

        root.Controls.Add(title, 0, 0);
        root.Controls.Add(_statusLabel, 0, 1);
        root.Controls.Add(actions, 0, 2);
        root.Controls.Add(_logBox, 0, 3);
        root.Controls.Add(footer, 0, 4);

        Controls.Add(root);
    }

    private void AddActionButton(
        TableLayoutPanel panel,
        string text,
        int column,
        int row,
        Func<Task> action,
        bool conflictsWithMutation = true)
    {
        var button = new Button
        {
            Text = text,
            Dock = DockStyle.Fill,
            Height = 38,
            Margin = new Padding(4)
        };
        button.Click += async (_, _) =>
        {
            try
            {
                await action();
            }
            catch (OperationCanceledException)
            {
                AppendLog("Action canceled.");
            }
            catch (Exception ex)
            {
                AppendLog("ERROR: " + ex.Message);
                MessageBox.Show(this, ex.Message, "HMS Superpowers", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        };

        panel.Controls.Add(button, column, row);
        if (conflictsWithMutation)
        {
            _conflictingButtons.Add(button);
        }
    }

    private async Task RunLifecycleAsync(HmsLifecycleAction action)
    {
        await RunExclusiveAsync((progress, token) => _processRunner.RunLifecycleAsync(action, progress, token));
    }

    private async Task RunExclusiveAsync(
        Func<IProgress<string>, CancellationToken, Task<HmsProcessResult>> operation)
    {
        if (_actionRunning)
        {
            return;
        }

        _actionRunning = true;
        SetConflictingButtonsEnabled(false);
        var progress = new Progress<string>(AppendLog);

        try
        {
            var result = await operation(progress, _lifetimeCts.Token);
            AppendLog(result.Summary);
            await RefreshStatusAsync();
        }
        finally
        {
            _actionRunning = false;
            SetConflictingButtonsEnabled(true);
        }
    }

    private Task UninstallAsync()
    {
        var choice = MessageBox.Show(
            this,
            "Gỡ HMS public discovery và ứng dụng HMS Superpowers? Source/state HMS được giữ lại theo chế độ uninstall mặc định.",
            "Xác nhận Uninstall",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);

        if (choice != DialogResult.Yes)
        {
            return Task.CompletedTask;
        }

        _processRunner.StartRegisteredUninstaller();
        Close();
        return Task.CompletedTask;
    }

    private async Task RefreshStatusAsync()
    {
        var snapshot = await _statusReader.ReadAsync(_lifetimeCts.Token);
        _statusLabel.Text = string.Join(
            Environment.NewLine,
            $"Repo: {(snapshot.RepoPresent ? "present" : "missing")} | Clean: {(snapshot.RepoClean ? "yes" : "no/unknown")} | Version: {snapshot.Version}",
            $"HEAD: {snapshot.Head}",
            $"{snapshot.GitState} | {snapshot.CodexState}",
            $"{snapshot.CompositeState} | {snapshot.PublicSkillState}");

        AppendLog("System status refreshed.");
    }

    private Task OpenHmsFolder()
    {
        if (!Directory.Exists(_paths.RepoRoot))
        {
            throw new DirectoryNotFoundException("HMS source directory is missing: " + _paths.RepoRoot);
        }

        var windowsRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var explorer = Path.Combine(windowsRoot, "explorer.exe");
        if (!File.Exists(explorer))
        {
            throw new FileNotFoundException("Windows Explorer is missing.", explorer);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = explorer,
            UseShellExecute = false
        };
        startInfo.ArgumentList.Add(_paths.RepoRoot);
        Process.Start(startInfo);
        return Task.CompletedTask;
    }

    private void SetConflictingButtonsEnabled(bool enabled)
    {
        foreach (var button in _conflictingButtons)
        {
            button.Enabled = enabled;
        }
    }

    private void AppendLog(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return;
        }

        var line = $"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}";
        var combined = _logBox.Text + line;
        if (combined.Length > MaxLogCharacters)
        {
            combined = combined[^MaxLogCharacters..];
        }

        _logBox.Text = combined;
        _logBox.SelectionStart = _logBox.TextLength;
        _logBox.ScrollToCaret();
    }
}
