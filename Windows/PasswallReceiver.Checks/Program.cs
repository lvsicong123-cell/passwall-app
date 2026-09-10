using PasswallReceiver.Core;
using PasswallReceiver.Interop;
using System.Diagnostics;
using System.Runtime.InteropServices;
using static PasswallReceiver.Interop.NativeInput;

if (args.Contains("--move-benchmark"))
{
    const int iterations = 20_000;
    var input = new Input
    {
        type = InputMouse,
        data = new InputUnion
        {
            mouse = new MouseInput { flags = MouseMove }
        }
    };

    static double Measure(int iterations, Action action)
    {
        for (var index = 0; index < 1_000; index++) action();
        var watch = Stopwatch.StartNew();
        for (var index = 0; index < iterations; index++) action();
        watch.Stop();
        return watch.Elapsed.TotalMilliseconds;
    }

    var sendOnly = Measure(iterations, () =>
        SendInput(1, [input], Marshal.SizeOf<Input>()));
    var sendAndRead = Measure(iterations, () =>
    {
        SendInput(1, [input], Marshal.SizeOf<Input>());
        GetCursorPos(out _);
    });

    Console.WriteLine($"SendInput only: {sendOnly:F2} ms total, {sendOnly * 1_000 / iterations:F2} us/move");
    Console.WriteLine($"SendInput + GetCursorPos: {sendAndRead:F2} ms total, {sendAndRead * 1_000 / iterations:F2} us/move");
    return;
}

var checks = 0;

void Check(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
    checks++;
}

void CheckThrows<TError>(Action action, string message) where TError : Exception
{
    try
    {
        action();
    }
    catch (TError)
    {
        checks++;
        return;
    }
    throw new InvalidOperationException(message);
}

var bounds = new VirtualDesktopBounds(0, 0, 2560, 1440);
var detector = new RemoteReturnDetector();
detector.Activate(DesktopEdge.Left, 28);

Check(detector.Update(0, 720, bounds, -12, 0) is null, "Return fired before the pressure threshold");
var fraction = detector.Update(0, 720, bounds, -16, 0);
Check(fraction is not null, "Return did not fire at the pressure threshold");
Check(Math.Abs(fraction!.Value - (720.0 / 1439.0)) < 0.000_001, "Return fraction was not normalized");
Check(!detector.IsActive, "Detector remained active after returning control");

detector.Activate(DesktopEdge.Left, 28);
Check(detector.Update(0, 720, bounds, -20, 0) is null, "Return fired too early before reset check");
Check(detector.Update(1, 720, bounds, 2, 0) is null, "Inward movement unexpectedly returned control");
Check(detector.Update(0, 720, bounds, -10, 0) is null, "Inward movement did not reset pressure");

Check(RemoteReturnDetector.ReturnEdgeFor("top") == DesktopEdge.Bottom, "Top placement mapped to the wrong return edge");
Check(RemoteReturnDetector.ReturnEdgeFor("right") == DesktopEdge.Left, "Right placement mapped to the wrong return edge");
Check(RemoteReturnDetector.ReturnEdgeFor("bottom") == DesktopEdge.Top, "Bottom placement mapped to the wrong return edge");
Check(RemoteReturnDetector.ReturnEdgeFor("left") == DesktopEdge.Right, "Left placement mapped to the wrong return edge");

var directionalCases = new[]
{
    (DesktopEdge.Top, 1280, 0, 0.0, -1.0),
    (DesktopEdge.Right, 2559, 720, 1.0, 0.0),
    (DesktopEdge.Bottom, 1280, 1439, 0.0, 1.0),
    (DesktopEdge.Left, 0, 720, -1.0, 0.0)
};
foreach (var (edge, x, y, dx, dy) in directionalCases)
{
    detector.Activate(edge, 1);
    Check(detector.Update(x, y, bounds, dx, dy) is not null, $"{edge} return direction did not cross");
}

Check(ProtocolContract.Version == 3, "Receiver protocol contract is not version 3");
var manifestDigest = new string('a', 64);
var exactEntries = Enumerable.Range(0, ProtocolContract.MaximumBatchEntries)
    .Select(index => new
    {
        path = $"item-{index}",
        kind = "file",
        byteCount = 0UL,
        sha256 = manifestDigest
    }).ToArray();
using (var exactEntriesDocument = System.Text.Json.JsonDocument.Parse(
    System.Text.Json.JsonSerializer.Serialize(new { entries = exactEntries })))
{
    Check(FileTransferManifest.Parse(exactEntriesDocument.RootElement).Entries.Count ==
        ProtocolContract.MaximumBatchEntries, "File manifest rejected the exact entry limit");
}
using (var excessEntriesDocument = System.Text.Json.JsonDocument.Parse(
    System.Text.Json.JsonSerializer.Serialize(new
    {
        entries = exactEntries.Append(new
        {
            path = "overflow",
            kind = "file",
            byteCount = 0UL,
            sha256 = manifestDigest
        })
    })))
{
    CheckThrows<InvalidDataException>(
        () => FileTransferManifest.Parse(excessEntriesDocument.RootElement),
        "File manifest accepted more than the entry limit");
}
using (var exactBytesDocument = System.Text.Json.JsonDocument.Parse($$"""
    {"entries":[{"path":"exact","kind":"file","byteCount":{{ProtocolContract.MaximumBatchBytes}},"sha256":"{{manifestDigest}}"}]}
    """))
{
    Check(FileTransferManifest.Parse(exactBytesDocument.RootElement).TotalBytes ==
        ProtocolContract.MaximumBatchBytes, "File manifest rejected the exact byte limit");
}
using (var excessBytesDocument = System.Text.Json.JsonDocument.Parse($$"""
    {"entries":[{"path":"overflow","kind":"file","byteCount":{{ProtocolContract.MaximumBatchBytes + 1}},"sha256":"{{manifestDigest}}"}]}
    """))
{
    CheckThrows<InvalidDataException>(
        () => FileTransferManifest.Parse(excessBytesDocument.RootElement),
        "File manifest accepted more than the byte limit");
}
using (var manifestDocument = System.Text.Json.JsonDocument.Parse("""
    {"entries":[{"path":"reports","kind":"directory","byteCount":0},{"path":"reports/summary.txt","kind":"file","byteCount":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    """))
{
    var manifest = FileTransferManifest.Parse(manifestDocument.RootElement);
    Check(manifest.TotalBytes == 42 && manifest.Entries.Count == 2,
        "File manifest did not retain its bounded relative entries");
}
using (var unsafeManifest = System.Text.Json.JsonDocument.Parse("""
    {"entries":[{"path":"../escape","kind":"file","byteCount":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    """))
{
    CheckThrows<InvalidDataException>(
        () => FileTransferManifest.Parse(unsafeManifest.RootElement),
        "File manifest accepted traversal path");
}
using (var portableManifestDocument = System.Text.Json.JsonDocument.Parse("""
    {"entries":[{"path":"bad:name.txt","kind":"file","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},{"path":"bad?name.txt","kind":"file","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}
    """))
{
    var portable = FileTransferManifest.Parse(portableManifestDocument.RootElement);
    Check(portable.Entries[0].LocalPath != portable.Entries[1].LocalPath &&
        portable.Entries.All(entry => !entry.LocalPath.Contains(':') && !entry.LocalPath.Contains('?')),
        "Windows portable-name mapping retained invalid or conflicting names");
}
using (var nestedPortableDocument = System.Text.Json.JsonDocument.Parse("""
    {"entries":[{"path":"bad:name","kind":"directory","byteCount":0},{"path":"bad?name","kind":"directory","byteCount":0},{"path":"bad?name/child.txt","kind":"file","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}
    """))
{
    var nested = FileTransferManifest.Parse(nestedPortableDocument.RootElement);
    Check(nested.Entries[2].LocalPath.StartsWith(nested.Entries[1].LocalPath + '/', StringComparison.Ordinal),
        "Windows portable-name mapping detached a child from its renamed directory");
}
using (var conflictingManifest = System.Text.Json.JsonDocument.Parse("""
    {"entries":[{"path":"file","kind":"file","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},{"path":"file/child","kind":"file","byteCount":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}
    """))
{
    CheckThrows<InvalidDataException>(() => FileTransferManifest.Parse(conflictingManifest.RootElement),
        "File manifest accepted a file as another entry's parent");
}
var stagingRoot = Path.Combine(Path.GetTempPath(), $"PasswallFileTransferChecks-{Guid.NewGuid():D}");
try
{
    Directory.CreateDirectory(stagingRoot);
    Check(FileTransferStaging.HasEnoughSpace(5, 5) &&
        !FileTransferStaging.HasEnoughSpace(4, 5),
        "File staging disk-space boundary changed");
    var oversized = Path.Combine(stagingRoot, "oversized.bin");
    File.WriteAllBytes(oversized, [0]);
    using (var locked = new FileStream(oversized, FileMode.Open, FileAccess.Read, FileShare.None))
    {
        CheckThrows<InvalidDataException>(
            () => FileTransferBatch.Build([oversized], maximumBatchBytes: 0),
            "Oversized file contents were opened before the declared size was rejected");
    }
    var privatePath = @"C:\Users\TestUser\Downloads\secret.txt";
    Check(ReceiverLog.Describe("File transfer cleanup failed", new IOException(privatePath)) ==
        "File transfer cleanup failed: IOException",
        "Receiver error logging exposed exception details");
    var wideDirectory = Path.Combine(stagingRoot, "wide");
    Directory.CreateDirectory(wideDirectory);
    for (var index = 0; index < ProtocolContract.MaximumBatchEntries; index++)
    {
        Directory.CreateDirectory(Path.Combine(wideDirectory, $"item-{index}"));
    }
    CheckThrows<InvalidDataException>(
        () => FileTransferBatch.Build([wideDirectory]),
        "Outgoing discovery materialized more than the batch entry limit");
    var outgoing = Path.Combine(stagingRoot, "outgoing");
    Directory.CreateDirectory(outgoing);
    File.WriteAllText(Path.Combine(outgoing, "one.txt"), "hello");
    var outgoingBatch = FileTransferBatch.Build([outgoing]);
    using (var outgoingStream = outgoingBatch.OpenRead())
    using (var outgoingBody = new MemoryStream())
    {
        outgoingStream.CopyTo(outgoingBody);
        Check(outgoingBatch.Manifest.TotalBytes == 5 &&
            System.Text.Encoding.UTF8.GetString(outgoingBody.ToArray()) == "hello",
            "Windows file batch did not stream its declared source");
    }
    File.WriteAllText(Path.Combine(outgoing, "one.txt"), "newer");
    CheckThrows<InvalidDataException>(() =>
    {
        using var staleStream = outgoingBatch.OpenRead();
        staleStream.CopyTo(Stream.Null);
    }, "Windows file retry reused a changed source without rebuilding");
    outgoingBatch = FileTransferBatch.Build([outgoing]);
    using (var retryStream = outgoingBatch.OpenRead())
    using (var retryBody = new MemoryStream())
    {
        retryStream.CopyTo(retryBody);
        Check(System.Text.Encoding.UTF8.GetString(retryBody.ToArray()) == "newer",
            "Windows file retry did not restart from the current source");
    }
    var downloadID = Guid.NewGuid();
    var downloadRegistry = new BulkTransferRegistry();
    downloadRegistry.RegisterFileDownload(downloadID, outgoingBatch);
    Check(downloadRegistry.FileTransfers() is
        [{ TransferID: var queuedID, Status: FileTransferStatus.AwaitingApproval }] &&
        queuedID == downloadID,
        "Windows file download did not expose its awaiting-approval state");
    var offerControls = downloadRegistry.DrainOutgoingControls();
    Check(offerControls.Count == 1 && offerControls[0] is
        { Type: "transfer_offer", TransferID: var offeredID, Manifest: not null } &&
        offeredID == downloadID,
        "Windows file download did not enqueue its manifest offer");
    downloadRegistry.PeerAcceptedFileTransfer(downloadID);
    downloadRegistry.ReportFileProgress(downloadID, 3);
    Check(downloadRegistry.FileTransfers() is
        [{ Status: FileTransferStatus.Transferring, TransferredBytes: 3 }],
        "Windows file download did not expose peer approval and progress");
    using (var downloadClaim = downloadRegistry.Claim(new TrustedSessionBinding(
        TrustedSessionRole.Bulk,
        downloadID,
        TransferDirection.Download)))
    {
        Check(downloadClaim.Source?.CanRead == true && downloadClaim.TotalBytes == 5,
            "Windows file download did not retain its bounded source");
    }
    downloadRegistry.ResolveFileTransfer(downloadID, FileTransferStatus.Completed);
    Check(downloadRegistry.FileTransfers() is [{ Status: FileTransferStatus.Completed }],
        "Windows file download did not expose completion");
    downloadRegistry.PeerAcceptedFileTransfer(downloadID);
    downloadRegistry.ReportFileProgress(downloadID, 4);
    downloadRegistry.MarkFileVerifying(downloadID);
    downloadRegistry.FailFileTransfer(downloadID, "late_failure", notifyPeer: true);
    downloadRegistry.ResolveFileTransfer(downloadID, FileTransferStatus.Canceled);
    Check(downloadRegistry.FileTransfers() is
            [{ Status: FileTransferStatus.Completed, TransferredBytes: 5 }] &&
        downloadRegistry.DrainOutgoingControls().Count == 0,
        "Late transfer activity changed or notified after a terminal result");
    using var stagingManifestDocument = System.Text.Json.JsonDocument.Parse("""
        {"entries":[{"path":"报告","kind":"directory","byteCount":0},{"path":"报告/summary.txt","kind":"file","byteCount":5,"sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}]}
        """);
    using var staging = new FileTransferStaging(
        stagingRoot,
        Guid.NewGuid(),
        FileTransferManifest.Parse(stagingManifestDocument.RootElement));
    staging.Append("hello"u8);
    var committed = staging.Finish();
    Check(File.ReadAllText(Path.Combine(committed, "报告", "summary.txt")) == "hello",
        "File staging did not commit its verified content");

    using var invalidManifestDocument = System.Text.Json.JsonDocument.Parse("""
        {"entries":[{"path":"bad.txt","kind":"file","byteCount":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
        """);
    using var invalidStaging = new FileTransferStaging(
        stagingRoot,
        Guid.NewGuid(),
        FileTransferManifest.Parse(invalidManifestDocument.RootElement));
    CheckThrows<InvalidDataException>(
        () => invalidStaging.Append("x"u8),
        "File staging accepted an invalid digest");
    Check(!Directory.Exists(invalidStaging.PartialDirectory),
        "File staging retained a digest-mismatch partial directory");

    var approvedID = Guid.NewGuid();
    var approvedRegistry = new BulkTransferRegistry();
    var approvedManifest = FileTransferManifest.Parse(stagingManifestDocument.RootElement);
    approvedRegistry.Register(approvedID, TransferDirection.Upload, 5, approvedManifest);
    approvedRegistry.AcceptFileUpload(approvedID, stagingRoot);
    var acceptControls = approvedRegistry.DrainOutgoingControls();
    Check(acceptControls.Count == 1 && acceptControls[0] ==
        new FileTransferControl("transfer_accept", approvedID),
        "File approval did not enqueue transfer_accept");
    using (var approvedClaim = approvedRegistry.Claim(new TrustedSessionBinding(
        TrustedSessionRole.Bulk,
        approvedID,
        TransferDirection.Upload)))
    {
        approvedClaim.Destination!.Write("hello"u8);
        await approvedClaim.CompleteAsync(CancellationToken.None);
    }
    var completeControls = approvedRegistry.DrainOutgoingControls();
    Check(completeControls.Count == 1 && completeControls[0] ==
        new FileTransferControl("transfer_complete", approvedID),
        "Committed file upload did not enqueue transfer_complete");
    Check(approvedRegistry.FileTransfers() is
        [{ Status: FileTransferStatus.Completed, ResultPath: not null }],
        "Committed file upload did not expose its receive location");
    Check(Directory.EnumerateDirectories(stagingRoot, "Passwall-*").Any(),
        "Approved file upload did not commit through the bulk registry");

    var canceledID = Guid.NewGuid();
    var canceledRegistry = new BulkTransferRegistry();
    canceledRegistry.Register(canceledID, TransferDirection.Upload, 5, approvedManifest);
    canceledRegistry.AcceptFileUpload(canceledID, stagingRoot);
    var canceledPartial = Path.Combine(stagingRoot, $".passwall-{canceledID:D}.partial");
    Check(Directory.Exists(canceledPartial), "Approved file upload did not create staging");
    canceledRegistry.Cancel(canceledID);
    Check(!Directory.Exists(canceledPartial), "Canceled file upload retained partial content");

    var lifecycleRegistry = new BulkTransferRegistry();
    var pendingFileID = Guid.NewGuid();
    var pendingImageID = Guid.NewGuid();
    lifecycleRegistry.Register(pendingFileID, TransferDirection.Upload, 5, approvedManifest);
    lifecycleRegistry.Register(pendingImageID, TransferDirection.Upload, 1);
    lifecycleRegistry.Accept(pendingImageID);
    lifecycleRegistry.CancelImages();
    Check(lifecycleRegistry.PendingFileUploads() is [{ TransferID: var listedID }] &&
        listedID == pendingFileID, "Disabling clipboard canceled an independent file offer");
    lifecycleRegistry.RejectFileUpload(pendingFileID);
    var rejectControls = lifecycleRegistry.DrainOutgoingControls();
    Check(rejectControls is [{ Type: "transfer_reject", TransferID: var rejectedID,
        Code: "user_rejected" }] && rejectedID == pendingFileID,
        "File rejection did not enqueue its explicit result");

    var localCancelRegistry = new BulkTransferRegistry();
    var localCancelID = Guid.NewGuid();
    localCancelRegistry.RegisterFileDownload(localCancelID, outgoingBatch);
    _ = localCancelRegistry.DrainOutgoingControls();
    localCancelRegistry.CancelFileTransfer(localCancelID);
    Check(localCancelRegistry.DrainOutgoingControls() is
        [{ Type: "transfer_cancel", TransferID: var localCanceledID }] &&
        localCanceledID == localCancelID,
        "Local file cancellation did not notify its peer");
    var abandonedPartial = Path.Combine(stagingRoot, $".passwall-{Guid.NewGuid():D}.partial");
    var lookalikePartial = Path.Combine(stagingRoot, ".passwall-not-a-transfer.partial");
    Directory.CreateDirectory(abandonedPartial);
    Directory.CreateDirectory(lookalikePartial);
    FileTransferStaging.RemoveAbandonedPartials(stagingRoot);
    Check(!Directory.Exists(abandonedPartial), "Abandoned file staging survived cleanup");
    Check(Directory.Exists(lookalikePartial), "Cleanup removed a non-transfer directory");

    var history = new FileTransferHistoryStore();
    for (var index = 0; index <= FileTransferHistoryStore.MaximumCount; index++)
    {
        history.Record(new FileTransferHistoryEntry(
            Guid.NewGuid(), $"batch-{index}", TransferDirection.Upload, (ulong)index,
            "Mac", DateTimeOffset.UnixEpoch.AddSeconds(index), FileTransferStatus.Queued));
    }
    Check(history.Entries.Count == FileTransferHistoryStore.MaximumCount &&
        history.Entries[0].Name == "batch-100", "File transfer history was not bounded");
    history.Update(history.Entries[0].TransferID, FileTransferStatus.Failed);
    Check(history.Entries[0].Status == FileTransferStatus.Failed,
        "File transfer history did not update its result");
    history.Clear();
    Check(history.Entries.Count == 0, "File transfer history did not clear");

    var preferencesPath = Path.Combine(stagingRoot, "receiver-settings.json");
    new ReceiverPreferences(
        stagingRoot,
        ReceiverLanguage.SimplifiedChinese,
        [new FileTransferHistoryEntry(
            Guid.NewGuid(), "unfinished", TransferDirection.Upload, 5, "Mac",
            DateTimeOffset.UtcNow, FileTransferStatus.Transferring,
            [new FileTransferNameMapping("bad:name.txt", "bad_name.txt")])]).Save(preferencesPath);
    var restoredPreferences = ReceiverPreferences.Load(preferencesPath);
    Check(restoredPreferences.Language == ReceiverLanguage.SimplifiedChinese &&
        restoredPreferences.ReceiveDirectory == stagingRoot &&
        restoredPreferences.History is
            [{ Status: FileTransferStatus.Failed, NameMappings: [{ Original: "bad:name.txt", Local: "bad_name.txt" }] }],
        "Windows receiver settings did not restore language, destination, interrupted history, and name mappings");
}
finally
{
    if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true);
}
var messageGuard = new SessionMessageGuard();
messageGuard.Accept(version: 3, sessionID: "session-a", sequence: 5);
messageGuard.Accept(version: 3, sessionID: "session-a", sequence: 6);
Check(messageGuard.LastAcceptedSequence == 6, "Sequence guard did not retain the newest sequence");
CheckThrows<InvalidDataException>(
    () => messageGuard.Accept(version: 3, sessionID: "session-a", sequence: 6),
    "Sequence guard accepted a duplicate message");
CheckThrows<InvalidDataException>(
    () => messageGuard.Accept(version: 3, sessionID: "session-a", sequence: 4),
    "Sequence guard accepted a stale message");
CheckThrows<InvalidDataException>(
    () => messageGuard.Accept(version: 3, sessionID: "session-b", sequence: 7),
    "Sequence guard accepted a different session on the same connection");
CheckThrows<InvalidDataException>(
    () => new SessionMessageGuard().Accept(version: 99, sessionID: "session-a", sequence: 1),
    "Sequence guard accepted an unsupported protocol version");
CheckThrows<InvalidDataException>(
    () => new SessionMessageGuard().Accept(version: 1, sessionID: "session-a", sequence: 1),
    "Sequence guard accepted protocol version 1");
Check(InputInjector.HidUsageToScanCode(0x2D) == 0x0C, "Zoom-out key mapped to the wrong scan code");
Check(InputInjector.HidUsageToScanCode(0x2E) == 0x0D, "Zoom-in key mapped to the wrong scan code");
Check(InputInjector.HidUsageToScanCode(0x1E) == 0x02, "Number-row key mapped to the wrong scan code");
Check(InputInjector.HidUsageToScanCode(0x2A) == 0x0E, "Backspace mapped to the wrong scan code");
Check(InputInjector.HidUsageToScanCode(0x38) == 0x35, "Slash mapped to the wrong scan code");
Check(InputInjector.HidUsageToScanCode(0x45) == 0x58, "F12 mapped to the wrong scan code");
Check(InputInjector.HidUsageToScanCode(0x4D) == 0x4F, "End mapped to the wrong scan code");
Check(InputInjector.IsExtendedHidUsage(0xE3), "Windows key was not marked extended");
Check(InputInjector.IsExtendedHidUsage(0x50), "Arrow key was not marked extended");
Check(InputInjector.IsExtendedHidUsage(0x4D), "End key was not marked extended");
Check(InputInjector.Scale(8, 0.5) == 4, "Minimum input gain was not applied");
Check(InputInjector.Scale(8, 4) == 16, "Input gain was not clamped");
Check(InputInjector.Scale(8, double.NaN) == 8, "Invalid input gain did not fall back");
double calibrationResidual = 0;
Check(
    InputInjector.Quantize(0.5, ref calibrationResidual) == 0 &&
    InputInjector.Quantize(0.5, ref calibrationResidual) == 1,
    "Sub-pixel calibrated movement was not retained");
using var blockedInputReports = new MemoryStream();
var sendResults = new Queue<bool>(
    [false, true, false, true, true, true, false, true, true,
        true, false, true, true]);
using (var reporter = new InputStateReporter(blockedInputReports, leaveOpen: true))
{
    var resilientInjector = new InputInjector(
        reporter,
        _ => sendResults.Dequeue());
    resilientInjector.Key(0x04, true);
    Check(
        ReportedInput().ScanCodes.Count == 0,
        "Blocked key-down remained in watchdog state");
    resilientInjector.Key(0x04, true);
    resilientInjector.Key(0x04, true);
    Check(
        ReportedInput().ScanCodes.SetEquals([0x1E]),
        "Blocked key repeat cleared a held key from watchdog state");
    resilientInjector.Move(1, 1, 1);
    resilientInjector.Key(0x04, true);
    resilientInjector.Key(0x04, false);
    resilientInjector.Move(1, 1, 1);
    resilientInjector.Button("left", true);
    resilientInjector.Button("left", true);
    Check(
        ReportedInput().Buttons.SetEquals(["left"]),
        "Blocked button repeat cleared a held button from watchdog state");
    resilientInjector.Move(1, 1, 1);
}
Check(
    sendResults.Count == 0 &&
        ReportedInput() is { ScanCodes.Count: 0, Buttons.Count: 0 },
    "Blocked input tore down delivery or lost held-key recovery state");

var recoverySends = new Queue<bool>([false, true, true]);
var recoveryInjector = new InputInjector(sendInput: _ => recoverySends.Dequeue());
// Inspect the real detector without moving the desktop cursor in this check.
var recoveryDetector = (RemoteReturnDetector)typeof(InputInjector)
    .GetField("returnDetector", System.Reflection.BindingFlags.Instance |
        System.Reflection.BindingFlags.NonPublic)!.GetValue(recoveryInjector)!;
recoveryDetector.Activate(DesktopEdge.Left, 5);
recoveryInjector.Key(0x04, true);
recoveryInjector.Key(0x04, true);
Check(
    recoveryDetector.Update(0, 50, new VirtualDesktopBounds(0, 0, 100, 100), -5, 0)
        is not null,
    "Blocked-input recovery disabled edge return");
recoveryDetector.Activate(DesktopEdge.Left, 5);
recoveryInjector.ReleaseAll();
Check(
    !recoveryDetector.IsActive && recoverySends.Count == 0,
    "Explicit release-all did not clear remote-control state");

HeldInputSnapshot ReportedInput()
{
    var accumulator = new InputStateAccumulator();
    foreach (var record in System.Text.Encoding.UTF8.GetString(blockedInputReports.ToArray())
        .Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
        accumulator.Apply(record.TrimEnd('\r'));
    }
    return accumulator.Snapshot();
}
Check(
    KeyboardScanCode.Value(KeyboardScanCode.Encode(0x5B, isExtended: true)) == 0x5B,
    "Extended scan-code encoding changed the physical scan code");
var navigationTracker = new HorizontalNavigationTracker();
Check(
    navigationTracker.Update(10, 1, "began").Consumed,
    "Browser navigation did not claim a horizontal gesture");
Check(
    navigationTracker.Update(26, 1, "changed").Action == HorizontalNavigationAction.Back,
    "Browser navigation did not trigger Back at the threshold");
navigationTracker.Reset();
Check(
    !navigationTracker.Update(0, 8, "began").Consumed,
    "Browser navigation claimed vertical scrolling");

checks += await ReceiverSessionChecks.RunAsync();
checks += await BulkProtocolChecks.RunAsync();
checks += await WatchdogChecks.RunAsync();
checks += DiscoveryContractChecks.Run();
checks += ClipboardChecks.Run();
checks += await TlsIdentityChecks.RunAsync();

Console.WriteLine($"{checks} receiver safety checks passed");
