import Foundation
import Network
import Observation
import os

/// Where the network is and where the push socket is, in one observable object.
///
/// Two jobs, both small. It watches `NWPathMonitor` so SwiftUI can show an
/// honest "offline" state instead of a spinner that never resolves, and it pokes
/// `BayeuxClient` the moment a path comes back so a reconnect does not sit out a
/// backoff that was sized for a network which has since returned.
///
/// It deliberately does **not** consume `BayeuxClient.events`: that stream has one
/// consumer, and it belongs to the sync layer. The sync layer forwards what the UI
/// needs by calling `observe(_:)` as it processes each event.
@Observable
final class RealtimeMonitor {
    nonisolated enum Reachability: Sendable, Hashable {
        /// Before the first path update. Not the same as offline, and showing it
        /// as offline is how apps flash a false error on launch.
        case unknown
        case offline
        case online

        var isOnline: Bool { self == .online }
    }

    private(set) var reachability: Reachability = .unknown
    /// Cellular or a personal hotspot: worth deferring big catch-up reads on.
    private(set) var isExpensive = false
    /// Low Data Mode.
    private(set) var isConstrained = false
    private(set) var interface: NWInterface.InterfaceType?

    /// Mirrors the push socket, as last reported through `observe(_:)`.
    private(set) var connection: RealtimeConnectionState = .idle
    /// When the socket last came back, and how long the hole was. Useful for a
    /// "catching up" banner and for deciding how loudly to reconcile.
    private(set) var lastResumeAt: Date?
    private(set) var lastGap: TimeInterval?

    var isOnline: Bool { reachability.isOnline }

    /// Reachability transitions for consumers that are not SwiftUI. The sync layer
    /// can await this instead of polling the observable.
    nonisolated let reachabilityChanges: AsyncStream<Reachability>

    private let changes: AsyncStream<Reachability>.Continuation
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sh.dunkirk.GroupMeNot.path")
    private let log = Logger(subsystem: "sh.dunkirk.GroupMeNot", category: "reachability")
    @ObservationIgnored private var client: BayeuxClient?
    @ObservationIgnored private var started = false

    init() {
        let (stream, continuation) = AsyncStream<Reachability>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        self.reachabilityChanges = stream
        self.changes = continuation
    }

    /// Begin watching. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        // The handler runs on `queue`, so pull out plain values rather than hop
        // an `NWPath` across isolation domains.
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let candidates: [NWInterface.InterfaceType] =
                [.wifi, .cellular, .wiredEthernet, .loopback, .other]
            let interface = candidates.first { path.usesInterfaceType($0) }
            Task { @MainActor [weak self] in
                self?.apply(online: satisfied, expensive: expensive,
                            constrained: constrained, interface: interface)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    /// Nudge this client whenever the network comes back.
    func attach(to client: BayeuxClient) {
        self.client = client
    }

    /// Feed the UI from the realtime event stream. Call this for every event the
    /// sync layer pulls off `BayeuxClient.events`; it ignores what it does not use.
    func observe(_ event: RealtimeEvent) {
        switch event {
        case .connectionStateDidChange(let state):
            connection = state
        case .connectionDidResume(let gap):
            connection = .connected
            lastResumeAt = Date()
            lastGap = gap
        case .connectionDidDrop, .subscriptionDidFail, .push:
            break
        }
    }

    private func apply(online: Bool, expensive: Bool, constrained: Bool,
                       interface: NWInterface.InterfaceType?) {
        isExpensive = expensive
        isConstrained = constrained
        self.interface = interface

        let next: Reachability = online ? .online : .offline
        guard next != reachability else { return }
        let cameBack = next == .online
        reachability = next
        changes.yield(next)
        log.info("network \(String(describing: next), privacy: .public)")

        if cameBack, let client {
            Task { await client.networkDidBecomeAvailable() }
        }
    }
}
