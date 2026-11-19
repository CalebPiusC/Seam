import Darwin
import Foundation

/// First-Class Wi-Fi Hybrid Transport (`WifiHybridTransport`):
/// - **Reliable TCP Stream (`TCP_NODELAY = 1`, `IPTOS_LOWDELAY`):** Mutual HMAC-SHA256 handshake,
///   keyboard events, mouse button clicks, cursor enter/leave, and `DISPLAY_INFO` / `EDGE_RETURN` telemetry.
/// - **Authenticated UDP Fast-Path (`DSCP EF = 0x2E`, 42-byte signed datagrams):** Pure mouse movement
///   deltas (`SendReliability.unreliableSequenced`) and UDP RTT probes with zero TCP Head-of-Line blocking.
public final class WifiHybridTransport: SeamTransport, @unchecked Sendable {
    public let kind: TransportKind = .wifiHybrid
    public private(set) var state: TransportState = .idle
    public private(set) var lastRttMicroseconds: UInt64 = 0
    public private(set) var lastUdpRttMicroseconds: UInt64 = 0
    public weak var delegate: (any SeamTransportDelegate)?

    private var tcpFd: Int32 = -1
    private var udpFd: Int32 = -1
    private var sessionId: UInt64 = 0
    private var udpSequence: UInt64 = 0
    private var authenticator: SeamAuthenticator?

    private let writeLock = NSLock()
    private var tcpReaderThread: Thread?
    private var udpReaderThread: Thread?
    private var heartbeatTimer: DispatchSourceTimer?
    private var running = false

    public init() {}

    public func connect(endpoint: SeamEndpoint, authenticator: SeamAuthenticator) throws {
        guard case let .wifi(host, tcpPort, udpPort) = endpoint else {
            throw SeamTransportError.socketConnectionFailed("WifiHybridTransport requires a .wifi endpoint")
        }

        self.authenticator = authenticator
        updateState(.connecting)

        // 1. Open and connect TCP control socket
        let tFd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard tFd >= 0 else {
            throw SeamTransportError.socketConnectionFailed("TCP socket() failed (errno=\(errno))")
        }

        var nodelay: Int32 = 1
        Darwin.setsockopt(tFd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        var lowDelayTos: Int32 = 0x10 // IPTOS_LOWDELAY
        Darwin.setsockopt(tFd, IPPROTO_IP, IP_TOS, &lowDelayTos, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        Darwin.setsockopt(tFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var tcpAddr = sockaddr_in()
        tcpAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        tcpAddr.sin_family = sa_family_t(AF_INET)
        tcpAddr.sin_port = tcpPort.bigEndian
        tcpAddr.sin_addr.s_addr = inet_addr(host)

        // Non-blocking connect with a 1.2 s timeout so probing offline LAN IPs never stalls
        let origFlags = Darwin.fcntl(tFd, F_GETFL, 0)
        _ = Darwin.fcntl(tFd, F_SETFL, origFlags | O_NONBLOCK)

        let tcpRes = withUnsafePointer(to: &tcpAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(tFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if tcpRes < 0 {
            if errno != EINPROGRESS {
                let err = errno
                Darwin.close(tFd)
                throw SeamTransportError.socketConnectionFailed("TCP connect(\(host):\(tcpPort)) failed (errno=\(err))")
            }
            var pfd = pollfd(fd: tFd, events: Int16(POLLOUT), revents: 0)
            let pollRes = Darwin.poll(&pfd, 1, 1200)
            if pollRes <= 0 {
                Darwin.close(tFd)
                throw SeamTransportError.socketConnectionFailed("TCP connect(\(host):\(tcpPort)) timed out")
            }
            var soErr: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            Darwin.getsockopt(tFd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
            if soErr != 0 {
                Darwin.close(tFd)
                throw SeamTransportError.socketConnectionFailed("TCP connect(\(host):\(tcpPort)) failed (errno=\(soErr))")
            }
        }
        _ = Darwin.fcntl(tFd, F_SETFL, origFlags)

        // 2. Open and connect UDP fast-path socket
        let uFd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if uFd >= 0 {
            var efTos: Int32 = 0x2E // DSCP EF (Voice/Interactive WMM queue)
            Darwin.setsockopt(uFd, IPPROTO_IP, IP_TOS, &efTos, socklen_t(MemoryLayout<Int32>.size))
            Darwin.setsockopt(uFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var udpAddr = sockaddr_in()
            udpAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            udpAddr.sin_family = sa_family_t(AF_INET)
            udpAddr.sin_port = udpPort.bigEndian
            udpAddr.sin_addr.s_addr = inet_addr(host)

            let udpRes = withUnsafePointer(to: &udpAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(uFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if udpRes == 0 {
                self.udpFd = uFd
            } else {
                Darwin.close(uFd)
            }
        }

        self.tcpFd = tFd
        updateState(.authenticating)

        do {
            let assignedSessionId = try authenticator.authenticateClientStream(
                readExact: { count in try self.readExact(fd: tFd, count: count) },
                writeAll: { bytes in try self.writeAll(fd: tFd, bytes: bytes) }
            )
            self.sessionId = assignedSessionId
            self.udpSequence = 0
            self.running = true
            updateState(.ready(sessionId: assignedSessionId))

            startTcpReaderThread(fd: tFd)
            if self.udpFd >= 0 {
                startUdpReaderThread(fd: self.udpFd)
            }
            startHeartbeatTimer()
        } catch {
            Darwin.close(tFd)
            if self.udpFd >= 0 {
                Darwin.close(self.udpFd)
                self.udpFd = -1
            }
            self.tcpFd = -1
            updateState(.closed(reason: "\(error)"))
            throw error
        }
    }

    public func send(_ frame: SeamOutboundFrame, reliability: SendReliability = .reliableOrdered) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard running, tcpFd >= 0 else {
            throw SeamTransportError.ioError("WifiHybridTransport is not connected")
        }

        // Route pure mouse motion deltas over the 42-byte HMAC-SHA256 authenticated UDP fast-path
        if reliability == .unreliableSequenced,
           udpFd >= 0,
           let auth = authenticator,
           case let .mouseReport(buttons, dx, dy, vWheel, hWheel) = frame {
            udpSequence &+= 1
            let uDx = UInt16(bitPattern: dx)
            let uDy = UInt16(bitPattern: dy)
            let pkt = auth.buildSignedUdpDatagram(
                sessionId: sessionId,
                sequence: udpSequence,
                opcode: SeamWireProtocol.opMouseReport,
                payload8: (
                    buttons & 0x1F,
                    UInt8(uDx & 0xFF),
                    UInt8((uDx >> 8) & 0xFF),
                    UInt8(uDy & 0xFF),
                    UInt8((uDy >> 8) & 0xFF),
                    UInt8(bitPattern: vWheel),
                    UInt8(bitPattern: hWheel),
                    0x00
                )
            )
            let sent = pkt.withUnsafeBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.send(udpFd, base, pkt.count, 0)
            }
            if sent == pkt.count {
                return
            }
            // If UDP send fails for any reason, transparently fall through to TCP
        }

        let bytes = frame.serialize()
        try writeAll(fd: tcpFd, bytes: bytes)
    }

    public func sendPing() throws {
        let nowUs = MonotonicClock.nowMicroseconds()
        try send(.ping(timestampUs: nowUs), reliability: .reliableOrdered)
    }

    /// Sends an authenticated 42-byte UDP fast-path `PING` datagram to benchmark UDP RTT.
    public func sendUdpPing() throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard running, udpFd >= 0, let auth = authenticator else {
            throw SeamTransportError.ioError("UDP fast-path is not connected")
        }
        udpSequence &+= 1
        let nowUs = MonotonicClock.nowMicroseconds()
        let pkt = auth.buildSignedUdpDatagram(
            sessionId: sessionId,
            sequence: udpSequence,
            opcode: SeamWireProtocol.opPing,
            payload8: (
                UInt8(nowUs & 0xFF),
                UInt8((nowUs >> 8) & 0xFF),
                UInt8((nowUs >> 16) & 0xFF),
                UInt8((nowUs >> 24) & 0xFF),
                UInt8((nowUs >> 32) & 0xFF),
                UInt8((nowUs >> 40) & 0xFF),
                UInt8((nowUs >> 48) & 0xFF),
                UInt8((nowUs >> 56) & 0xFF)
            )
        )
        _ = pkt.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            return Darwin.send(udpFd, base, pkt.count, 0)
        }
    }

    public func disconnect(reason: String = "Client disconnected") {
        writeLock.lock()
        let wasRunning = running
        running = false
        let tFd = tcpFd
        let uFd = udpFd
        tcpFd = -1
        udpFd = -1
        let timer = heartbeatTimer
        heartbeatTimer = nil
        writeLock.unlock()

        timer?.cancel()
        if tFd >= 0 {
            Darwin.shutdown(tFd, SHUT_RDWR)
            Darwin.close(tFd)
        }
        if uFd >= 0 {
            Darwin.close(uFd)
        }
        if wasRunning {
            updateState(.closed(reason: reason))
        }
    }

    private func startTcpReaderThread(fd: Int32) {
        let thread = Thread { [weak self] in
            self?.tcpReaderLoop(fd: fd)
        }
        thread.name = "com.seam.wifi-tcp-reader"
        thread.qualityOfService = .userInteractive
        self.tcpReaderThread = thread
        thread.start()
    }

    private func startUdpReaderThread(fd: Int32) {
        let thread = Thread { [weak self] in
            self?.udpReaderLoop(fd: fd)
        }
        thread.name = "com.seam.wifi-udp-reader"
        thread.qualityOfService = .userInteractive
        self.udpReaderThread = thread
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

    private func tcpReaderLoop(fd: Int32) {
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
                    throw SeamTransportError.ioError(String(format: "Unknown Wi-Fi TCP opcode 0x%02X", opcode))
                }
            } catch {
                if running {
                    disconnect(reason: "\(error)")
                }
                break
            }
        }
    }

    private func udpReaderLoop(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 64)
        while running {
            let n = buf.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.recv(fd, base, 64, 0)
            }
            if n <= 0 {
                if !running { break }
                continue
            }
            guard n == SeamAuthenticator.udpPacketSize,
                  let auth = authenticator,
                  auth.verifyUdpDatagram(Array(buf[0..<SeamAuthenticator.udpPacketSize])) else {
                continue
            }
            let opcode = buf[17]
            if opcode == SeamWireProtocol.opPong {
                var sentTimestampUs: UInt64 = 0
                for i in 0..<8 {
                    sentTimestampUs |= UInt64(buf[18 + i]) << (i * 8)
                }
                let nowUs = MonotonicClock.nowMicroseconds()
                if nowUs >= sentTimestampUs {
                    let rttUs = nowUs - sentTimestampUs
                    self.lastUdpRttMicroseconds = rttUs
                    self.lastRttMicroseconds = rttUs
                    delegate?.transport(self, didMeasureRttMicroseconds: rttUs)
                }
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
                throw SeamTransportError.ioError("Remote peer closed Wi-Fi TCP socket (EOF)")
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SeamTransportError.ioError("Wi-Fi TCP read() failed (errno=\(errno))")
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
                if n < 0 && errno == EINTR { continue }
                throw SeamTransportError.ioError("Wi-Fi TCP write() failed (errno=\(errno))")
            }
            offset += n
        }
    }

    private func updateState(_ newState: TransportState) {
        self.state = newState
        delegate?.transport(self, didChangeState: newState)
    }
}
