import Foundation
import Network
import Observation

/// Lightweight connectivity signal for the Locations screen's offline state (PRD states table:
/// "search is disabled with a short message" when offline; "saved list still renders from
/// cache"). Uses Apple's `Network` framework only to observe reachability — never makes a
/// network call itself.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isConnected = true

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.levelup.clearsky.networkmonitor"))
    }

    deinit {
        monitor.cancel()
    }
}
