import Foundation

/// Identifies the physical transport backing a SEAM connection.
public enum TransportKind: UInt8, Sendable, CustomStringConvertible {
    case usbAdb     = 0x01
    case wifiHybrid = 0x02

    public var description: String {
        switch self {
        case .usbAdb:     return "USB-ADB"
        case .wifiHybrid: return "Wi-Fi-Hybrid"
        }
    }
}

/// Delivery semantics requested for an outbound `SEAM-Wire v1` frame.
public enum SendReliability: UInt8, Sendable {
    /// Guaranteed in-order delivery (used for clicks, keys, cursor enter/leave, control).
    case reliableOrdered     = 0x01
    /// Lowest-latency delivery without Head-of-Line blocking (used for pure mouse motion deltas).
    case unreliableSequenced = 0x02
}

/// Connection lifecycle state of a `SeamTransport`.
public enum TransportState: Sendable, Equatable, CustomStringConvertible {
    case idle
    case connecting
    case authenticating
    case ready(sessionId: UInt64)
    case closed(reason: String)

    public var description: String {
        switch self {
        case .idle:                   return "Idle"
        case .connecting:             return "Connecting"
        case .authenticating:         return "Authenticating"
        case let .ready(sessionId):   return String(format: "Ready(session=0x%016llX)", sessionId)
        case let .closed(reason):     return "Closed(\(reason))"
        }
    }
}

/// Errors thrown during transport discovery, bootstrapping, authentication, or I/O.
public enum SeamTransportError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case deviceUnauthorized(String)
    case bootstrapFailed(String)
    case socketConnectionFailed(String)
    case authenticationFailed(String)
    case ioError(String)

    public var description: String {
        switch self {
        case let .deviceNotFound(msg):         return "DeviceNotFound: \(msg)"
        case let .deviceUnauthorized(msg):     return "DeviceUnauthorized: \(msg)"
        case let .bootstrapFailed(msg):        return "BootstrapFailed: \(msg)"
        case let .socketConnectionFailed(msg): return "SocketConnectionFailed: \(msg)"
        case let .authenticationFailed(msg):   return "AuthenticationFailed: \(msg)"
        case let .ioError(msg):                return "IOError: \(msg)"
        }
    }
}

/// Endpoint descriptor for connecting a `SeamTransport`.
public enum SeamEndpoint: Sendable, Equatable {
    case usbLocalhost(port: UInt16, serial: String)
    case wifi(host: String, tcpPort: UInt16, udpPort: UInt16)
}

/// Callback delegate notified of transport state transitions, incoming frames, and RTT measurements.
public protocol SeamTransportDelegate: AnyObject {
    func transport(_ transport: any SeamTransport, didChangeState state: TransportState)
    func transport(_ transport: any SeamTransport, didReceiveFrame frame: SeamInboundFrame)
    func transport(_ transport: any SeamTransport, didMeasureRttMicroseconds rttUs: UInt64)
}

/// Shared transport interface implemented by both `UsbAdbTransport` and `WifiHybridTransport`.
public protocol SeamTransport: AnyObject {
    var kind: TransportKind { get }
    var state: TransportState { get }
    var lastRttMicroseconds: UInt64 { get }
    var delegate: (any SeamTransportDelegate)? { get set }

    /// Connects to the remote endpoint and executes the mutual HMAC-SHA256 authentication handshake.
    func connect(endpoint: SeamEndpoint, authenticator: SeamAuthenticator) throws

    /// Sends an outbound `SEAM-Wire v1` frame over the transport.
    func send(_ frame: SeamOutboundFrame, reliability: SendReliability) throws

    /// Sends a heartbeat `PING` frame with the current monotonic microsecond timestamp.
    func sendPing() throws

    /// Closes the transport cleanly.
    func disconnect(reason: String)
}

/// Monotonic microsecond clock helper for high-precision RTT measurement.
public enum MonotonicClock {
    public static func nowMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }
}
