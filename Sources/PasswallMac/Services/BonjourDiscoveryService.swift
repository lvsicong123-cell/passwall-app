import Foundation
import Network
import OSLog
import PasswallCore

struct DiscoveredWindowsDevice: Identifiable, Equatable, Sendable {
    let name: String
    let type: String
    let domain: String
    let metadata: PasswallDiscoveryMetadata

    var id: String {
        "\(name)|\(type)|\(domain)".lowercased()
    }
}

enum BonjourDiscoveryState: Equatable {
    case stopped
    case searching
    case ready
    case waiting(String)
    case failed(String)
}

@MainActor
final class BonjourDiscoveryService {
    var onDevicesChanged: (([DiscoveredWindowsDevice]) -> Void)?
    var onStateChanged: ((BonjourDiscoveryState) -> Void)?

    private var browser: NWBrowser?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "com.passwall.discovery", qos: .utility)
    private let logger = Logger(subsystem: "com.passwall.mac", category: "discovery")

    func start() {
        guard browser == nil else { return }

        let generation = UUID()
        self.generation = generation
        onStateChanged?(.searching)

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: PasswallDiscoveryContract.serviceType,
                domain: PasswallDiscoveryContract.domain
            ),
            using: .tcp
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.logger.info("Bonjour browser state: \(String(describing: state), privacy: .public)")
                switch state {
                case .setup:
                    self.onStateChanged?(.searching)
                case .ready:
                    self.onStateChanged?(.ready)
                case let .waiting(error):
                    self.onStateChanged?(.waiting(error.localizedDescription))
                case let .failed(error):
                    self.browser = nil
                    self.onDevicesChanged?([])
                    self.onStateChanged?(.failed(error.localizedDescription))
                case .cancelled:
                    self.browser = nil
                    self.onStateChanged?(.stopped)
                @unknown default:
                    self.onStateChanged?(.failed("Unknown discovery state"))
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = Self.devices(from: results)
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.logger.info(
                    "Bonjour results: \(results.count, privacy: .public), accepted: \(devices.count, privacy: .public)"
                )
                self.onDevicesChanged?(devices)
            }
        }
        browser.start(queue: queue)
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
        onDevicesChanged?([])
        onStateChanged?(.stopped)
    }

    nonisolated private static func devices(
        from results: Set<NWBrowser.Result>
    ) -> [DiscoveredWindowsDevice] {
        var unique: [String: DiscoveredWindowsDevice] = [:]

        for result in results {
            guard
                case let .service(name, type, domain, _) = result.endpoint,
                case let .bonjour(txtRecord) = result.metadata,
                let metadata = PasswallDiscoveryMetadata(txtRecord: txtRecord.dictionary)
            else {
                continue
            }

            let device = DiscoveredWindowsDevice(
                name: name,
                type: type,
                domain: domain,
                metadata: metadata
            )
            unique[device.id] = device
        }

        return unique.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
