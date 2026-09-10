using System.Diagnostics;
using PasswallReceiver.Core;

namespace PasswallReceiver;

internal sealed class ReceiverWindow : Form
{
    private readonly BulkTransferRegistry transfers;
    private readonly string settingsPath;
    private readonly string logPath;
    private readonly Func<bool> isConnected;
    private readonly FileTransferHistoryStore history = new();
    private readonly List<PendingSend> outgoingQueue = [];
    private readonly Dictionary<Guid, IReadOnlyList<string>> retrySources = [];
    private readonly Dictionary<Guid, FileTransferActivity> activities = [];
    private readonly HashSet<Guid> promptedOffers = [];
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 300 };
    private readonly TabControl tabs = new() { Dock = DockStyle.Fill };
    private readonly TabPage transferPage = new();
    private readonly TabPage devicesPage = new();
    private readonly TabPage settingsPage = new();
    private readonly TabPage aboutPage = new();
    private readonly TextBox transferDestination = new() { ReadOnly = true, Dock = DockStyle.Fill };
    private readonly TextBox settingsDestination = new() { ReadOnly = true, Dock = DockStyle.Fill };
    private readonly ListView transferList = new()
    {
        Dock = DockStyle.Fill,
        View = View.Details,
        FullRowSelect = true,
        HideSelection = false
    };
    private readonly Label emptyTransfers = new() { AutoSize = true };
    private readonly Label deviceTitle = new() { AutoSize = true };
    private readonly Label deviceStatus = new() { AutoSize = true };
    private readonly Label deviceDetail = new() { AutoSize = true, MaximumSize = new Size(620, 0) };
    private readonly Label receiveToLabel = new() { AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly Label settingsReceiveToLabel = new() { AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly Label languageLabel = new() { AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly Label logPathLabel = new() { AutoSize = true };
    private readonly Label aboutText = new() { AutoSize = true, MaximumSize = new Size(620, 0) };
    private readonly ComboBox language = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly Button chooseTransferDestination = new() { Text = "...", AutoSize = true };
    private readonly Button chooseSettingsDestination = new() { Text = "...", AutoSize = true };
    private readonly Button sendFiles = new() { AutoSize = true };
    private readonly Button sendFolder = new() { AutoSize = true };
    private readonly Button clearHistory = new() { AutoSize = true };
    private readonly Button cancelTransfer = new() { AutoSize = true };
    private readonly Button retryTransfer = new() { AutoSize = true };
    private readonly Button revealTransfer = new() { AutoSize = true };
    private readonly Button openLogs = new() { AutoSize = true };
    private readonly ToolTip tips = new();
    private ReceiverPreferences preferences;
    private ReceiverStrings strings;
    private bool allowClose;
    private bool applyingLanguage;
    private string lastActivitySignature = "";

    public ReceiverWindow(
        BulkTransferRegistry transfers,
        string dataDirectory,
        string logPath,
        Func<bool> isConnected)
    {
        this.transfers = transfers;
        this.logPath = logPath;
        this.isConnected = isConnected;
        settingsPath = Path.Combine(dataDirectory, "receiver-settings.json");
        preferences = ReceiverPreferences.Load(settingsPath);
        strings = new ReceiverStrings(preferences.Language);
        foreach (var entry in preferences.History.Reverse()) history.Record(entry);

        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(860, 570);
        MinimumSize = new Size(700, 460);
        StartPosition = FormStartPosition.CenterScreen;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

        BuildTransferPage();
        BuildDevicesPage();
        BuildSettingsPage();
        BuildAboutPage();
        tabs.TabPages.AddRange([transferPage, devicesPage, settingsPage, aboutPage]);
        Controls.Add(tabs);

        transferList.SelectedIndexChanged += (_, _) => UpdateActionButtons();
        transferList.DoubleClick += (_, _) => RevealSelectedTransfer();
        chooseTransferDestination.Click += (_, _) => ChooseReceiveDirectory();
        chooseSettingsDestination.Click += (_, _) => ChooseReceiveDirectory();
        sendFiles.Click += async (_, _) => await ChooseFilesAsync();
        sendFolder.Click += async (_, _) => await ChooseFolderAsync();
        clearHistory.Click += (_, _) => ClearHistory();
        cancelTransfer.Click += (_, _) => CancelSelectedTransfer();
        retryTransfer.Click += async (_, _) => await RetrySelectedTransferAsync();
        revealTransfer.Click += (_, _) => RevealSelectedTransfer();
        openLogs.Click += (_, _) => OpenLogs();
        language.SelectedIndexChanged += (_, _) => ChangeLanguage();
        FormClosing += HideInsteadOfClose;
        EnableFileDrop(this);
        EnableFileDrop(transferPage);
        EnableFileDrop(transferList);
        refreshTimer.Tick += (_, _) => RefreshState();
        refreshTimer.Start();

        ApplyStrings();
        RefreshState();
    }

    public event Action? LanguageChanged;

    public ReceiverLanguage Language => preferences.Language;
    public bool HasActiveTransfers => outgoingQueue.Count > 0 || transfers.HasActiveFileTransfers();

    public void ShowTransferCenter()
    {
        tabs.SelectedTab = transferPage;
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
    }

    public void RefreshConnection()
    {
        UpdateDeviceState();
        StartNextOutgoing();
    }

    public void PromptIncoming(FileTransferOffer offer)
    {
        if (!promptedOffers.Add(offer.TransferID)) return;
        ShowTransferCenter();
        using var dialog = new IncomingTransferDialog(
            strings,
            offer,
            preferences.ReceiveDirectory);
        var result = dialog.ShowDialog(this);
        try
        {
            if (result == DialogResult.OK)
            {
                transfers.AcceptFileUpload(offer.TransferID, dialog.SelectedDirectory);
                if (dialog.SaveAsDefault)
                {
                    preferences = preferences with { ReceiveDirectory = dialog.SelectedDirectory };
                    UpdateDestinationText();
                    SavePreferences();
                }
            }
            else if (transfers.PendingFileUploads().Any(item => item.TransferID == offer.TransferID))
            {
                transfers.RejectFileUpload(
                    offer.TransferID,
                    result == DialogResult.Abort ? "approval_timeout" : "user_rejected");
            }
        }
        catch (InvalidDataException)
        {
            MessageBox.Show(
                this,
                strings["This transfer can no longer be approved."],
                strings["Passwall Receiver"],
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (transfers.PendingFileUploads().Any(item => item.TransferID == offer.TransferID))
            {
                transfers.RejectFileUpload(
                    offer.TransferID,
                    "destination_error",
                    FileTransferStatus.Failed);
            }
            MessageBox.Show(
                this,
                error.Message,
                strings["Receiver error"],
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        RefreshState();
    }

    public void CloseForExit()
    {
        allowClose = true;
        foreach (var pending in outgoingQueue)
        {
            history.Update(pending.TransferID, FileTransferStatus.Canceled);
        }
        outgoingQueue.Clear();
        SavePreferences();
        refreshTimer.Stop();
        Close();
    }

    private void BuildTransferPage()
    {
        transferPage.Padding = new Padding(16);
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var toolbar = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 6,
            Padding = new Padding(0, 0, 0, 12)
        };
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        toolbar.Controls.Add(receiveToLabel, 0, 0);
        toolbar.Controls.Add(transferDestination, 1, 0);
        toolbar.Controls.Add(chooseTransferDestination, 2, 0);
        toolbar.Controls.Add(sendFiles, 3, 0);
        toolbar.Controls.Add(sendFolder, 4, 0);
        toolbar.Controls.Add(clearHistory, 5, 0);

        transferList.Columns.Add("Name", 250);
        transferList.Columns.Add("Direction", 85);
        transferList.Columns.Add("Status", 125);
        transferList.Columns.Add("Size", 95);
        transferList.Columns.Add("Progress", 85);
        transferList.Columns.Add("Started", 135);

        var emptyPanel = new Panel { Dock = DockStyle.Fill };
        emptyTransfers.Location = new Point(12, 12);
        emptyPanel.Controls.Add(emptyTransfers);
        emptyPanel.Controls.Add(transferList);

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            AutoSize = true,
            FlowDirection = FlowDirection.RightToLeft,
            Padding = new Padding(0, 12, 0, 0)
        };
        actions.Controls.Add(revealTransfer);
        actions.Controls.Add(retryTransfer);
        actions.Controls.Add(cancelTransfer);

        layout.Controls.Add(toolbar, 0, 0);
        layout.Controls.Add(emptyPanel, 0, 1);
        layout.Controls.Add(actions, 0, 2);
        transferPage.Controls.Add(layout);
    }

    private void BuildDevicesPage()
    {
        devicesPage.Padding = new Padding(28);
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false
        };
        deviceTitle.Font = new Font(Font, FontStyle.Bold);
        deviceStatus.Margin = new Padding(0, 10, 0, 16);
        panel.Controls.Add(deviceTitle);
        panel.Controls.Add(deviceStatus);
        panel.Controls.Add(deviceDetail);
        devicesPage.Controls.Add(panel);
    }

    private void BuildSettingsPage()
    {
        settingsPage.Padding = new Padding(28);
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 3,
            RowCount = 2
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.Controls.Add(settingsReceiveToLabel, 0, 0);
        layout.Controls.Add(settingsDestination, 1, 0);
        layout.Controls.Add(chooseSettingsDestination, 2, 0);
        layout.Controls.Add(languageLabel, 0, 1);
        layout.Controls.Add(language, 1, 1);
        settingsPage.Controls.Add(layout);
    }

    private void BuildAboutPage()
    {
        aboutPage.Padding = new Padding(28);
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false
        };
        logPathLabel.Margin = new Padding(0, 16, 0, 8);
        openLogs.Margin = new Padding(0, 0, 0, 20);
        panel.Controls.Add(aboutText);
        panel.Controls.Add(logPathLabel);
        panel.Controls.Add(openLogs);
        aboutPage.Controls.Add(panel);
    }

    private async Task ChooseFilesAsync()
    {
        using var dialog = new OpenFileDialog
        {
            Multiselect = true,
            CheckFileExists = true,
            Title = strings["Send files"]
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            await QueueSendAsync(dialog.FileNames);
        }
    }

    private void EnableFileDrop(Control control)
    {
        control.AllowDrop = true;
        control.DragEnter += (_, eventArgs) =>
        {
            eventArgs.Effect = eventArgs.Data?.GetDataPresent(DataFormats.FileDrop) == true
                ? DragDropEffects.Copy : DragDropEffects.None;
        };
        control.DragDrop += async (_, eventArgs) =>
        {
            if (eventArgs.Data?.GetData(DataFormats.FileDrop) is string[] paths)
            {
                await QueueSendAsync(paths);
            }
        };
    }

    private async Task ChooseFolderAsync()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = strings["Send folder"],
            UseDescriptionForTitle = true,
            ShowNewFolderButton = false
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            await QueueSendAsync([dialog.SelectedPath]);
        }
    }

    private async Task QueueSendAsync(IReadOnlyList<string> paths)
    {
        if (!isConnected() || paths.Count == 0) return;
        var transferID = Guid.NewGuid();
        var name = paths.Count == 1
            ? Path.GetFileName(paths[0])
            : $"{Path.GetFileName(paths[0])} +{paths.Count - 1}";
        var pending = new PendingSend(transferID, name, paths);
        outgoingQueue.Add(pending);
        retrySources[transferID] = paths;
        history.Record(new FileTransferHistoryEntry(
            transferID,
            name,
            TransferDirection.Download,
            0,
            "Mac",
            DateTimeOffset.Now,
            FileTransferStatus.Queued));
        RefreshTransferList();
        SavePreferences();
        try
        {
            pending.Batch = await Task.Run(() => FileTransferBatch.Build(paths));
            if (allowClose) return;
            StartNextOutgoing();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            InvalidDataException or ArgumentException or NotSupportedException or
            System.Security.SecurityException)
        {
            if (allowClose) return;
            outgoingQueue.Remove(pending);
            history.Update(transferID, FileTransferStatus.Failed);
            SavePreferences();
            RefreshTransferList();
            MessageBox.Show(
                this,
                $"{strings["The selected files could not be prepared."]}\n\n{error.Message}",
                strings["File selection failed"],
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            StartNextOutgoing();
        }
    }

    private void StartNextOutgoing()
    {
        var activeOutgoing = transfers.FileTransfers().Any(transfer =>
            transfer.Direction == TransferDirection.Download && IsActive(transfer.Status));
        if (!isConnected() || activeOutgoing || outgoingQueue.Count == 0 ||
            outgoingQueue[0].Batch is not { } batch)
        {
            return;
        }
        var pending = outgoingQueue[0];
        outgoingQueue.RemoveAt(0);
        transfers.RegisterFileDownload(pending.TransferID, batch);
        history.Record(new FileTransferHistoryEntry(
            pending.TransferID,
            pending.Name,
            TransferDirection.Download,
            batch.Manifest.TotalBytes,
            "Mac",
            DateTimeOffset.Now,
            FileTransferStatus.AwaitingApproval));
        SavePreferences();
        RefreshState();
    }

    private void ChooseReceiveDirectory()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = strings["Choose receive folder"],
            UseDescriptionForTitle = true,
            SelectedPath = preferences.ReceiveDirectory
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        preferences = preferences with { ReceiveDirectory = dialog.SelectedPath };
        UpdateDestinationText();
        SavePreferences();
    }

    private void RefreshState()
    {
        var current = transfers.FileTransfers();
        var signature = string.Join('|', current.Select(item =>
            $"{item.TransferID:N}:{item.Status}:{item.TransferredBytes}:{item.ResultPath}:{item.ErrorCode}"));
        if (signature != lastActivitySignature)
        {
            lastActivitySignature = signature;
            activities.Clear();
            foreach (var activity in current)
            {
                activities[activity.TransferID] = activity;
                var existing = history.Entries.FirstOrDefault(entry =>
                    entry.TransferID == activity.TransferID);
                if (existing is null)
                {
                    history.Record(new FileTransferHistoryEntry(
                        activity.TransferID,
                        TransferName(activity.Manifest),
                        activity.Direction,
                        activity.TotalBytes,
                        "Mac",
                        activity.StartedAt,
                        activity.Status,
                        NameMappings(activity.Manifest)));
                }
                else
                {
                    history.Update(activity.TransferID, activity.Status);
                }
            }
            SavePreferences();
            RefreshTransferList();
            StartNextOutgoing();
        }
        UpdateDeviceState();
    }

    private void RefreshTransferList()
    {
        var selected = SelectedTransferID();
        transferList.BeginUpdate();
        transferList.Items.Clear();
        foreach (var entry in history.Entries)
        {
            activities.TryGetValue(entry.TransferID, out var activity);
            var progress = activity is null || entry.TotalBytes == 0
                ? ""
                : $"{(double)activity.TransferredBytes / entry.TotalBytes:P0}";
            var item = new ListViewItem(entry.Name) { Tag = entry.TransferID };
            item.SubItems.Add(strings[entry.Direction == TransferDirection.Download ? "Send" : "Receive"]);
            item.SubItems.Add(StatusText(entry.Status));
            item.SubItems.Add(FormatBytes(entry.TotalBytes));
            item.SubItems.Add(progress);
            item.SubItems.Add(entry.StartedAt.LocalDateTime.ToString("g"));
            transferList.Items.Add(item);
            if (selected == entry.TransferID) item.Selected = true;
        }
        transferList.EndUpdate();
        transferList.Visible = history.Entries.Count > 0;
        emptyTransfers.Visible = history.Entries.Count == 0;
        clearHistory.Enabled = history.Entries.Count > 0 && !HasActiveTransfers;
        UpdateActionButtons();
    }

    private void UpdateActionButtons()
    {
        var transferID = SelectedTransferID();
        var entry = transferID is null ? null : history.Entries.FirstOrDefault(item =>
            item.TransferID == transferID);
        var queued = transferID is not null && outgoingQueue.Any(item => item.TransferID == transferID);
        cancelTransfer.Enabled = queued || entry is not null && IsActive(entry.Status);
        retryTransfer.Enabled = isConnected() && transferID is not null &&
            retrySources.ContainsKey(transferID.Value) &&
            entry is not null && !IsActive(entry.Status);
        revealTransfer.Enabled = entry?.Status == FileTransferStatus.Completed &&
            (entry.Direction == TransferDirection.Download && retrySources.ContainsKey(entry.TransferID) ||
             activities.GetValueOrDefault(entry.TransferID)?.ResultPath is not null);
    }

    private void CancelSelectedTransfer()
    {
        if (SelectedTransferID() is not { } transferID) return;
        var queued = outgoingQueue.FirstOrDefault(item => item.TransferID == transferID);
        if (queued is not null)
        {
            outgoingQueue.Remove(queued);
            history.Update(transferID, FileTransferStatus.Canceled);
        }
        else
        {
            transfers.CancelFileTransfer(transferID);
        }
        SavePreferences();
        RefreshState();
    }

    private async Task RetrySelectedTransferAsync()
    {
        if (SelectedTransferID() is not { } transferID ||
            !retrySources.TryGetValue(transferID, out var paths)) return;
        await QueueSendAsync(paths);
    }

    private void RevealSelectedTransfer()
    {
        if (SelectedTransferID() is not { } transferID) return;
        string? path = activities.GetValueOrDefault(transferID)?.ResultPath;
        if (path is null && retrySources.TryGetValue(transferID, out var sources))
        {
            path = sources[0];
        }
        if (path is null || !File.Exists(path) && !Directory.Exists(path)) return;
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,\"{path}\"",
            UseShellExecute = true
        });
    }

    private void ClearHistory()
    {
        if (HasActiveTransfers) return;
        transfers.ClearFinishedFileTransfers();
        history.Clear();
        retrySources.Clear();
        activities.Clear();
        SavePreferences();
        RefreshTransferList();
    }

    private void ChangeLanguage()
    {
        if (applyingLanguage || language.SelectedItem is not LanguageChoice choice) return;
        preferences = preferences with { Language = choice.Value };
        strings = new ReceiverStrings(preferences.Language);
        ApplyStrings();
        SavePreferences();
        LanguageChanged?.Invoke();
    }

    private void ApplyStrings()
    {
        Text = strings["Passwall Receiver"];
        transferPage.Text = strings["Transfer"];
        devicesPage.Text = strings["Devices"];
        settingsPage.Text = strings["Settings"];
        aboutPage.Text = strings["Logs / About"];
        receiveToLabel.Text = strings["Receive to"];
        settingsReceiveToLabel.Text = strings["Receive to"];
        languageLabel.Text = strings["Language"];
        sendFiles.Text = strings["Send files"];
        sendFolder.Text = strings["Send folder"];
        clearHistory.Text = strings["Clear history"];
        cancelTransfer.Text = strings["Cancel"];
        retryTransfer.Text = strings["Retry"];
        revealTransfer.Text = strings["Show in Explorer"];
        emptyTransfers.Text = strings["No transfers yet"];
        transferList.Columns[0].Text = strings["Name"];
        transferList.Columns[1].Text = strings["Direction"];
        transferList.Columns[2].Text = strings["Status"];
        transferList.Columns[3].Text = strings["Size"];
        transferList.Columns[4].Text = strings["Progress"];
        transferList.Columns[5].Text = strings["Started"];
        deviceTitle.Text = strings["Mac controller"];
        deviceDetail.Text = strings["Trusted pairing is stored in Windows Credential Manager."];
        openLogs.Text = strings["Open logs"];
        logPathLabel.Text = $"{strings["Log file"]}: {logPath}";
        aboutText.Text = $"Passwall Receiver {Application.ProductVersion}\n\n" +
            $"{strings["Local-network input, clipboard, and file sharing."]}\n" +
            $"{strings["Protocol"]}: {ProtocolContract.Version}\n\n" +
            strings["Close keeps Passwall running in the tray."];
        tips.SetToolTip(chooseTransferDestination, strings["Choose receive folder"]);
        tips.SetToolTip(chooseSettingsDestination, strings["Choose receive folder"]);
        chooseTransferDestination.AccessibleName = strings["Choose receive folder"];
        chooseSettingsDestination.AccessibleName = strings["Choose receive folder"];
        sendFiles.AccessibleName = strings["Send files"];
        sendFolder.AccessibleName = strings["Send folder"];
        clearHistory.AccessibleName = strings["Clear history"];
        cancelTransfer.AccessibleName = strings["Cancel"];
        retryTransfer.AccessibleName = strings["Retry"];
        revealTransfer.AccessibleName = strings["Show in Explorer"];
        transferList.AccessibleName = strings["Transfer"];
        applyingLanguage = true;
        language.Items.Clear();
        language.Items.AddRange([
            new LanguageChoice(strings["Follow system"], ReceiverLanguage.System),
            new LanguageChoice(strings["English"], ReceiverLanguage.English),
            new LanguageChoice(strings["Simplified Chinese"], ReceiverLanguage.SimplifiedChinese)
        ]);
        language.SelectedIndex = (int)preferences.Language;
        applyingLanguage = false;
        UpdateDestinationText();
        UpdateDeviceState();
        RefreshTransferList();
    }

    private void UpdateDestinationText()
    {
        transferDestination.Text = preferences.ReceiveDirectory;
        settingsDestination.Text = preferences.ReceiveDirectory;
    }

    private void UpdateDeviceState()
    {
        deviceStatus.Text = strings[isConnected() ? "Connected securely" : "Not connected"];
        deviceStatus.ForeColor = isConnected() ? Color.FromArgb(25, 120, 65) : SystemColors.GrayText;
        sendFiles.Enabled = isConnected();
        sendFolder.Enabled = isConnected();
    }

    private void SavePreferences()
    {
        try
        {
            preferences = preferences with { History = history.Entries.ToArray() };
            preferences.Save(settingsPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Debug.WriteLine(ReceiverLog.Describe("Could not save receiver settings", error));
        }
    }

    private void OpenLogs()
    {
        if (!File.Exists(logPath)) File.WriteAllText(logPath, string.Empty);
        Process.Start(new ProcessStartInfo
        {
            FileName = "notepad.exe",
            Arguments = $"\"{logPath}\"",
            UseShellExecute = true
        });
    }

    private Guid? SelectedTransferID() => transferList.SelectedItems.Count == 1 &&
        transferList.SelectedItems[0].Tag is Guid transferID ? transferID : null;

    private string StatusText(FileTransferStatus status) => strings[status switch
    {
        FileTransferStatus.Queued => "Queued",
        FileTransferStatus.AwaitingApproval => "Awaiting approval",
        FileTransferStatus.Transferring => "Transferring",
        FileTransferStatus.Verifying => "Verifying",
        FileTransferStatus.Completed => "Completed",
        FileTransferStatus.Rejected => "Rejected",
        FileTransferStatus.Canceled => "Canceled",
        _ => "Failed"
    }];

    private static bool IsActive(FileTransferStatus status) => status is
        FileTransferStatus.Queued or FileTransferStatus.AwaitingApproval or
        FileTransferStatus.Transferring or FileTransferStatus.Verifying;

    private static string TransferName(FileTransferManifest manifest)
    {
        var topLevel = manifest.Entries
            .Where(entry => !entry.Path.Contains('/'))
            .Select(entry => entry.Path)
            .ToArray();
        var names = topLevel.Length > 0 ? topLevel : [manifest.Entries[0].Path];
        return names.Length == 1 ? names[0] : $"{names[0]} +{names.Length - 1}";
    }

    private static IReadOnlyList<FileTransferNameMapping>? NameMappings(FileTransferManifest manifest)
    {
        var mappings = manifest.Entries
            .Where(entry => entry.Path != entry.LocalPath)
            .Select(entry => new FileTransferNameMapping(entry.Path, entry.LocalPath))
            .ToArray();
        return mappings.Length == 0 ? null : mappings;
    }

    private static string FormatBytes(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit == 0 ? $"{bytes} B" : $"{value:0.#} {units[unit]}";
    }

    private void HideInsteadOfClose(object? sender, FormClosingEventArgs eventArgs)
    {
        if (allowClose || eventArgs.CloseReason == CloseReason.WindowsShutDown) return;
        eventArgs.Cancel = true;
        Hide();
    }

    private sealed class PendingSend(Guid transferID, string name, IReadOnlyList<string> paths)
    {
        public Guid TransferID { get; } = transferID;
        public string Name { get; } = name;
        public IReadOnlyList<string> Paths { get; } = paths;
        public FileTransferBatch? Batch { get; set; }
    }

    private sealed record LanguageChoice(string Name, ReceiverLanguage Value)
    {
        public override string ToString() => Name;
    }
}

internal sealed class IncomingTransferDialog : Form
{
    private readonly TextBox destination = new() { ReadOnly = true, Dock = DockStyle.Fill };
    private readonly CheckBox saveDefault = new() { AutoSize = true };
    private readonly System.Windows.Forms.Timer expiryTimer = new() { Interval = 500 };

    public IncomingTransferDialog(
        ReceiverStrings strings,
        FileTransferOffer offer,
        string defaultDirectory)
    {
        SelectedDirectory = defaultDirectory;
        Text = strings["Incoming files"];
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(560, 390);
        MinimumSize = new Size(480, 340);
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = false;
        MinimizeBox = false;

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(20),
            ColumnCount = 1,
            RowCount = 5
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var summary = new Label
        {
            AutoSize = true,
            Text = $"{strings["From Mac"]}  |  {offer.Manifest.Entries.Count} {strings["items"]}  |  {FormatSize(offer.TotalBytes)}",
            Font = new Font(Font, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 14)
        };
        var entries = new ListBox { Dock = DockStyle.Fill };
        foreach (var entry in offer.Manifest.Entries.Take(100))
        {
            entries.Items.Add(entry.Path == entry.LocalPath
                ? entry.Path
                : $"{entry.Path} -> {entry.LocalPath}");
        }
        if (offer.Manifest.Entries.Count > 100)
        {
            entries.Items.Add($"+{offer.Manifest.Entries.Count - 100} {strings["More"]}");
        }

        var destinationRow = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 3,
            Margin = new Padding(0, 14, 0, 8)
        };
        destinationRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        destinationRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        destinationRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        destination.Text = defaultDirectory;
        var choose = new Button { Text = "...", AutoSize = true };
        choose.Click += (_, _) => ChooseDirectory(strings);
        destinationRow.Controls.Add(new Label
        {
            Text = strings["Save to"],
            AutoSize = true,
            Anchor = AnchorStyles.Left
        }, 0, 0);
        destinationRow.Controls.Add(destination, 1, 0);
        destinationRow.Controls.Add(choose, 2, 0);

        saveDefault.Text = strings["Use as default receive folder"];
        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            AutoSize = true,
            FlowDirection = FlowDirection.RightToLeft,
            Margin = new Padding(0, 14, 0, 0)
        };
        var accept = new Button { Text = strings["Accept"], DialogResult = DialogResult.OK, AutoSize = true };
        var reject = new Button { Text = strings["Reject"], DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(accept);
        buttons.Controls.Add(reject);
        AcceptButton = accept;
        CancelButton = reject;

        layout.Controls.Add(summary, 0, 0);
        layout.Controls.Add(entries, 0, 1);
        layout.Controls.Add(destinationRow, 0, 2);
        layout.Controls.Add(saveDefault, 0, 3);
        layout.Controls.Add(buttons, 0, 4);
        Controls.Add(layout);

        expiryTimer.Tick += (_, _) =>
        {
            if (DateTimeOffset.UtcNow < offer.ExpiresAt) return;
            DialogResult = DialogResult.Abort;
            Close();
        };
        expiryTimer.Start();
        FormClosed += (_, _) => expiryTimer.Dispose();
    }

    public string SelectedDirectory { get; private set; }
    public bool SaveAsDefault => saveDefault.Checked;

    private void ChooseDirectory(ReceiverStrings strings)
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = strings["Choose receive folder"],
            UseDescriptionForTitle = true,
            SelectedPath = SelectedDirectory
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        SelectedDirectory = dialog.SelectedPath;
        destination.Text = SelectedDirectory;
    }

    private static string FormatSize(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit == 0 ? $"{bytes} B" : $"{value:0.#} {units[unit]}";
    }
}
