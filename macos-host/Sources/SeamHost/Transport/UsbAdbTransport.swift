import Darwin
import Foundation

/// First-Class USB Transport (`UsbAdbTransport`) running `SEAM-Wire v1` over an ADB-forwarded
/// local socket tunnel (`127.0.0.1:<port>` -> `localabstract:seam_uhid`) with `TCP_NODELAY`.
public final class UsbAdbTransport: SeamTransport, @unchecked Sendable {
    public let kind: TransportKind = .usbAdb
    public private(set) var state: TransportState = .idle
    public private(set) var lastRttMicroseconds: UInt64 = 0
    public weak var delegate: (any SeamTransportDelegate)?

    private var socketFd: Int32 = -1
    private let writeLock = NSLock()
    private var readerThread: Thread?
    private var heartbeatTimer: DispatchSourceTimer?
    private var running = false

    public init() {}

    public func connect(endpoint: SeamEndpoint, authenticator: SeamAuthenticator) throws {
        guard case let .usbLocalhost(port, _) = endpoint else {
            throw SeamTransportError.socketConnectionFailed("UsbAdbTransport requires a .usbLocalhost endpoint")
        }

        updateState(.connecting)

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw SeamTransportError.socketConnectionFailed("socket() failed (errno=\(errno))")
        }

        // Disable Nagle's algorithm (TCP_NODELAY = 1) for sub-millisecond frame flush
        var flag: Int32 = 1
        Darwin.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))

        // Prevent SIGPIPE on socket close
        var noSigPipe: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult < 0 {
            let err = errno
            Darwin.close(fd)
            throw SeamTransportError.socketConnectionFailed("connect(127.0.0.1:\(port)) failed (errno=\(err))")
        }

        self.socketFd = fd
        updateState(.authenticating)

        do {
            let sessionId = try authenticator.authenticateClientStream(
                readExact: { count in try self.readExact(fd: fd, count: count) },
                writeAll: { bytes in try self.writeAll(fd: fd, bytes: bytes) }
            )
            self.running = true
            updateState(.ready(sessionId: sessionId))
            startReaderThread(fd: fd)
            startHeartbeatTimer()
        } catch {
            Darwin.close(fd)
            self.socketFd = -1
            updateState(.closed(reason: "\(error)"))
            throw error
        }
    }

    public func send(_ frame: SeamOutboundFrame, reliability: SendReliability = .reliableOrdered) throws {
        let bytes = frame.serialize()
        writeLock.lock()
        defer { writeLock.unlock() }

        guard running, socketFd >= 0 else {
            throw SeamTransportError.ioError("UsbAdbTransport is not connected")
        }
        try writeAll(fd: socketFd, bytes: bytes)
    }

    public func sendPing() throws {
        let nowUs = MonotonicClock.nowMicroseconds()
        try send(.ping(timestampUs: nowUs), reliability: .reliableOrdered)
    }

    public func disconnect(reason: String = "Client disconnected") {
        writeLock.lock()
        let wasRunning = running
        running = false
        let fd = socketFd
        socketFd = -1
        let timer = heartbeatTimer
        heartbeatTimer = nil
        writeLock.unlock()

        timer?.cancel()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        if wasRunning {
            updateState(.closed(reason: reason))
        }
    }

    private func startReaderThread(fd: Int32) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.readerLoop(fd: fd)
        }
        thread.name = "com.seam.usb-reader"
        thread.qualityOfService = .userInteractive
        self.readerThread = thread
        thread.start()
    }

    private func startHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            try? self.sendPing()
        }
        self.heartbeatTimer = timer
        timer.resume()
    }

    private func readerLoop(fd: Int32) {
        while running {
            do {
                let opcodeBytes = try readExact(fd: fd, count: 1)
                let opcode = opcodeBytes[0]

                switch opcode {
                case SeamWireProtocol.opDisplayInfo:
                    let payload = try readExact(fd: fd, count: 10)
                    let width  = Int(UInt16(payload[0]) | (UInt16(payload[1]) << 8))
                    let height = Int(UInt16(payload[2]) | (UInt16(payload[3]) << 8))
                    let dpi    = Int(UInt16(payload[4]) | (UInt16(payload[5]) << 8))
                    let rot    = Int(payload[6])
                    let hz     = Int(payload[7])
                    let flags  = UInt16(payload[8]) | (UInt16(payload[9]) << 8)
                    let info = AndroidDisplayInfo(
                        widthPx: width,
                        heightPx: height,
                        densityDpi: dpi,
                        rotation: rot,
                        refreshRateHz: hz,
                        flags: flags
                    )
                    delegate?.transport(self, didReceiveFrame: .displayInfo(info))

                case SeamWireProtocol.opEdgeReturn:
                    let payload = try readExact(fd: fd, count: 6)
                    let edge = SeamWireProtocol.ScreenEdge(rawValue: payload[0]) ?? .left
                    let normX = UInt16(payload[1]) | (UInt16(payload[2]) << 8)
                    let normY = UInt16(payload[3]) | (UInt16(payload[4]) << 8)
                    let velocity = payload[5]
                    let event = AndroidEdgeReturnEvent(
                        edge: edge,
                        normX: normX,
                        normY: normY,
                        velocity: velocity
                    )
                    delegate?.transport(self, didReceiveFrame: .edgeReturn(event))

                case SeamWireProtocol.opClipboardEvent:
                    let text = try SeamWireProtocol.readClipboardText { count in
                        try readExact(fd: fd, count: count)
                    }
                    delegate?.transport(self, didReceiveFrame: .clipboardEvent(text: text))

                case SeamWireProtocol.opPong:
                    let payload = try readExact(fd: fd, count: 8)
                    var sentTimestampUs: UInt64 = 0
                    for i in 0..<8 {
                        sentTimestampUs |= UInt64(payload[i]) << (i * 8)
                    }
                    let nowUs = MonotonicClock.nowMicroseconds()
                    if nowUs >= sentTimestampUs {
                        let rttUs = nowUs - sentTimestampUs
                        self.lastRttMicroseconds = rttUs
                        delegate?.transport(self, didMeasureRttMicroseconds: rttUs)
                    }
                    delegate?.transport(self, didReceiveFrame: .pong(timestampUs: sentTimestampUs))

                default:
                    throw SeamTransportError.ioError(String(format: "Unknown inbound opcode 0x%02X", opcode))
                }
            } catch {
                if running {
                    disconnect(reason: "\(error)")
                }
                break
            }
        }
    }

    private func readExact(fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if n == 0 {
                throw SeamTransportError.ioError("Remote peer closed socket (EOF)")
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw SeamTransportError.ioError("read() failed (errno=\(errno))")
            }
            offset += n
        }
        return buffer
    }

    private func writeAll(fd: Int32, bytes: [UInt8]) throws {
        var offset = 0
        let count = bytes.count
        while offset < count {
            let n = bytes.withUnsafeBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), count - offset)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR {
                    continue
                }
                throw SeamTransportError.ioError("write() failed (errno=\(errno))")
            }
            offset += n
        }
    }

    private func updateState(_ newState: TransportState) {
        self.state = newState
        delegate?.transport(self, didChangeState: newState)
    }
}
