import AppKit
import PasswallCore
import SwiftUI
import UniformTypeIdentifiers

struct TransferView: View {
    @Bindable var store: AppStore
    let enablesFileDrop: Bool
    @State private var isDropTargeted = false

    init(store: AppStore, enablesFileDrop: Bool = true) {
        self.store = store
        self.enablesFileDrop = enablesFileDrop
    }

    @ViewBuilder
    var body: some View {
        if enablesFileDrop {
            content.onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $isDropTargeted,
                perform: acceptDrop
            )
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = store.fileTransferError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 22)
                .frame(minHeight: 40)
                .accessibilityLabel("\(store.text("File transfer failed")): \(error)")
                Divider()
            }
            if store.fileTransferHistory.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(store.text("No transfers"))
                        .font(.title3.weight(.semibold))
                    Text(store.text("Send files or drop them here."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.fileTransferHistory.entries) { entry in
                            TransferHistoryRow(store: store, entry: entry)
                                .padding(.horizontal, 22)
                            Divider()
                                .padding(.leading, 70)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.passwallAccent, lineWidth: 2)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.text("Receive to"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.fileTransferDestination.path(percentEncoded: false))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button {
                chooseDefaultDestination()
            } label: {
                Image(systemName: "folder")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .help(store.text("Choose receive folder"))
            .accessibilityLabel(store.text("Choose receive folder"))

            Spacer(minLength: 16)

            if !store.fileTransferHistory.entries.isEmpty {
                Button {
                    store.clearFileTransferHistory()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .disabled(store.hasActiveFileTransfer)
                .help(store.text("Clear history"))
                .accessibilityLabel(store.text("Clear history"))
            }

            Button {
                chooseFiles()
            } label: {
                Label(store.text("Send files"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canSend)
            .help(store.canSend ? store.text("Send files or folders") : store.text("Connect to Windows first"))
        }
        .padding(.horizontal, 22)
        .frame(height: 72)
        .background(.bar)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = store.text("Send")
        panel.begin { response in
            guard response == .OK else { return }
            store.sendFiles(panel.urls)
        }
    }

    private func chooseDefaultDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.fileTransferDestination
        panel.prompt = store.text("Choose")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.fileTransferDestination = url
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard store.canSend, !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await fileURL(from: provider), url.isFileURL {
                    urls.append(url)
                }
            }
            store.sendFiles(urls)
        }
        return true
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct TransferHistoryRow: View {
    @Bindable var store: AppStore
    let entry: FileTransferHistoryEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(entry.status.color)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Label(store.text(entry.status.titleKey), systemImage: entry.status.symbol)
                        .font(.caption)
                        .foregroundStyle(entry.status.color)
                }
                HStack(spacing: 7) {
                    Text(store.text(entry.direction == .upload ? "Send" : "Receive"))
                    Text("·")
                    Text(entry.deviceName)
                    if entry.totalBytes > 0 {
                        Text("·")
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(entry.totalBytes),
                            countStyle: .file
                        ))
                    }
                    Text("·")
                    Text(entry.startedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if store.activeFileTransferID == entry.transferID,
                   entry.totalBytes > 0,
                   entry.status == .transferring || entry.status == .verifying {
                    ProgressView(
                        value: Double(min(store.fileTransferProgress, entry.totalBytes)),
                        total: Double(entry.totalBytes)
                    )
                    .accessibilityLabel(store.text("Transfer progress"))
                }
            }

            Spacer(minLength: 12)

            if entry.status.isActive {
                rowButton("xmark", help: "Cancel") { store.cancelFiles(entry.transferID) }
            } else if store.canRetryFiles(entry.transferID) {
                rowButton("arrow.clockwise", help: "Retry") { store.retryFiles(entry.transferID) }
            }
            if entry.status == .completed, store.canRevealFiles(entry.transferID) {
                rowButton("magnifyingglass", help: "Reveal in Finder") {
                    store.revealFiles(entry.transferID)
                }
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func rowButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(store.text(help))
        .accessibilityLabel(store.text(help))
    }
}

struct IncomingFilesView: View {
    @Bindable var store: AppStore
    let offer: TransferOffer
    @State private var destination: URL
    @State private var saveAsDefault = false
    @State private var errorMessage: String?

    init(store: AppStore, offer: TransferOffer) {
        self.store = store
        self.offer = offer
        _destination = State(initialValue: store.fileTransferDestination)
    }

    private var sourceName: String {
        store.fileTransferHistory.entries.first {
            $0.transferID == offer.transferID
        }?.deviceName ?? store.text("Windows PC")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(store.text("Incoming files"), systemImage: "tray.and.arrow.down.fill")
                .font(.title2.weight(.semibold))

            HStack {
                Text(store.text("From"))
                Text(sourceName)
                    .fontWeight(.medium)
                Text("·")
                Text("\(offer.manifest?.entries.count ?? 0) \(store.text("items"))")
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: Int64(offer.totalBytes), countStyle: .file))
            }
            .foregroundStyle(.secondary)

            if let entries = offer.manifest?.entries {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries.prefix(6), id: \.path) { entry in
                        Label(entry.path, systemImage: entry.kind == .directory ? "folder" : "doc")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if entries.count > 6 {
                        Text("+\(entries.count - 6) \(store.text("more"))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.text("Save to"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(destination.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    chooseDestination()
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .help(store.text("Choose receive folder"))
                .accessibilityLabel(store.text("Choose receive folder"))
            }

            Toggle(store.text("Use as default receive folder"), isOn: $saveAsDefault)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(store.text("Reject"), role: .cancel) {
                    store.rejectIncomingFiles(offer.transferID)
                }
                Button(store.text("Accept")) {
                    do {
                        if saveAsDefault { store.fileTransferDestination = destination }
                        try store.acceptIncomingFiles(offer.transferID, to: destination)
                    } catch {
                        errorMessage = store.fileTransferMessage(error)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = store.text("Choose")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            destination = url
        }
    }
}

private extension FileTransferStatus {
    var titleKey: String {
        switch self {
        case .queued: "Queued"
        case .awaitingApproval: "Awaiting approval"
        case .transferring: "Transferring"
        case .verifying: "Verifying"
        case .completed: "Completed"
        case .rejected: "Rejected"
        case .canceled: "Canceled"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .awaitingApproval: "person.badge.clock"
        case .transferring: "arrow.left.arrow.right"
        case .verifying: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .rejected, .canceled: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        case .rejected, .canceled: .secondary
        case .queued, .awaitingApproval, .transferring, .verifying: .passwallAccent
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .awaitingApproval, .transferring, .verifying: true
        case .completed, .rejected, .canceled, .failed: false
        }
    }
}
