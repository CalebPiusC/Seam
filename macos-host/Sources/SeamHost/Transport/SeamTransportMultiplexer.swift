import Foundation

/// Multiplexes First-Class USB (`UsbAdbTransport`) and First-Class Wi-Fi (`WifiHybridTransport`)
/// sessions simultaneously, supporting instant (`< 5 ms`) live switching and automatic hot-standby failover
/// without resetting the Android `/dev/uhid` mouse cursor or keyboard.
public final class SeamTransportMultiplexer: SeamTransportDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [TransportKind: any SeamTransport] = [:]
    public private(set) var activePrimaryKind: TransportKind?
    public weak var delegate: (any SeamTransportDelegate)?

    public init() {}

    /// Registers and connects a transport (USB or Wi-Fi). If no primary transport is currently active,
    /// or if `makePrimary` is true, promotes it to `ACTIVE_PRIMARY`.
    public func addAndConnectTransport(
        _ transport: any SeamTransport,
        endpoint: SeamEndpoint,
        authenticator: SeamAuthenticator,
        makePrimary: Bool
    ) throws {
        transport.delegate = self
        try transport.connect(endpoint: endpoint, authenticator: authenticator)

        lock.lock()
        transports[transport.kind] = transport
        if activePrimaryKind == nil || makePrimary {
            activePrimaryKind = transport.kind
        }
        let currentPrimary = activePrimaryKind
        lock.unlock()

        if currentPrimary == transport.kind {
            print("[Host-Multiplexer] Active Primary Transport -> \(transport.kind)")
        } else {
            print("[Host-Multiplexer] Registered Hot-Standby Transport -> \(transport.kind)")
        }
    }

    /// Atomically switches the active primary transport between `.usbAdb` and `.wifiHybrid` in `< 1 ms`.
    @discardableResult
    public func switchActiveTransport(to targetKind: TransportKind) throws -> any SeamTransport {
        lock.lock()
        defer { lock.unlock() }

        guard let target = transports[targetKind], case .ready = target.state else {
            throw SeamTransportError.ioError("Target transport \(targetKind) is not in Ready state")
        }
        let previous = activePrimaryKind
        activePrimaryKind = targetKind
        if previous != targetKind {
            print("[Host-Multiplexer] Switched ACTIVE_PRIMARY: \(previous?.description ?? "None") -> \(targetKind)")
        }
        return target
    }

    /// Sends an outbound `SEAM-Wire v1` frame over the `ACTIVE_PRIMARY` transport, automatically
    /// failing over to any ready `HOT_STANDBY` transport if the primary link drops mid-frame!
    public func send(_ frame: SeamOutboundFrame, reliability: SendReliability = .reliableOrdered) throws {
        lock.lock()
        guard let primaryKind = activePrimaryKind, let primary = transports[primaryKind] else {
            lock.unlock()
            throw SeamTransportError.ioError("No active primary transport available")
        }
        lock.unlock()

        do {
            try primary.send(frame, reliability: reliability)
        } catch {
            // Primary link failed mid-use! Immediately attempt zero-downtime hot-standby failover
            if let fallback = promoteStandbyTransport(failedKind: primaryKind) {
                try fallback.send(frame, reliability: reliability)
            } else {
                throw error
            }
        }
    }

    /// Disconnects a specific transport (e.g., simulating or handling a USB cable pull) and automatically
    /// promotes the standby transport if available.
    public func disconnectTransport(_ kind: TransportKind, reason: String) {
        lock.lock()
        let target = transports.removeValue(forKey: kind)
        lock.unlock()

        target?.disconnect(reason: reason)
        _ = promoteStandbyTransport(failedKind: kind)
    }

    public func disconnectAll(reason: String = "Multiplexer shutdown") {
        lock.lock()
        let all = Array(transports.values)
        transports.removeAll()
        activePrimaryKind = nil
        lock.unlock()

        for t in all {
            t.disconnect(reason: reason)
        }
    }

    @discardableResult
    private func promoteStandbyTransport(failedKind: TransportKind) -> (any SeamTransport)? {
        lock.lock()
        defer { lock.unlock() }

        for (kind, candidate) in transports where kind != failedKind {
            if case .ready = candidate.state {
                activePrimaryKind = kind
                print("[Host-Multiplexer] Hot-Failover: \(failedKind) dropped -> promoted \(kind) to ACTIVE_PRIMARY!")
                return candidate
            }
        }
        if activePrimaryKind == failedKind {
            activePrimaryKind = nil
        }
        return nil
    }

    // MARK: - SeamTransportDelegate

    public func transport(_ transport: any SeamTransport, didChangeState state: TransportState) {
        if case .closed = state {
            _ = promoteStandbyTransport(failedKind: transport.kind)
        }
        delegate?.transport(transport, didChangeState: state)
    }

    public func transport(_ transport: any SeamTransport, didReceiveFrame frame: SeamInboundFrame) {
        delegate?.transport(transport, didReceiveFrame: frame)
    }

    public func transport(_ transport: any SeamTransport, didMeasureRttMicroseconds rttUs: UInt64) {
        delegate?.transport(transport, didMeasureRttMicroseconds: rttUs)
    }
}
