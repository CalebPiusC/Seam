import CryptoKit
import Darwin
import Foundation

/// Metadata for a discovered Android device via ADB (USB or Wireless Debugging).
public struct AdbDeviceRecord: Sendable, Equatable, CustomStringConvertible {
    public let serial: String
    public let state: String
    public let model: String
    public let transportId: String

    public var isAuthorized: Bool {
        state == "device"
    }

    public var isWirelessAdb: Bool {
        serial.contains(":") || serial.contains("._adb-tls-connect._tcp")
    }

    public var description: String {
        "\(serial) [state=\(state), model=\(model), transport_id=\(transportId)]"
    }
}

/// Discovered Wi-Fi / Hotspot IPv4 endpoint reported by `seam-agent`.
public struct DiscoveredWifiEndpoint: Sendable, Equatable, CustomStringConvertible {
    public let interfaceName: String
    public let ipv4Address: String
    public let port: UInt16

    public var seamEndpoint: SeamEndpoint {
        .wifi(host: ipv4Address, tcpPort: port, udpPort: port)
    }

    public var description: String {
        "\(interfaceName)=\(ipv4Address):\(port)"
    }
}

/// Bootstraps `seam-agent --server` on an Android device (over USB or Wireless Debugging) as a
/// persistent detached background daemon (`nohup` + `setsid`), and discovers running wireless
/// `seam-agent` instances directly over Wi-Fi UDP even when no USB cable is connected.
public final class UsbBootstrapper: Sendable {
    public static let remoteJarPath   = "/data/local/tmp/seam-agent.jar"
    public static let remoteLogPath   = "/data/local/tmp/seam-agent.log"
    public static let remoteStampPath = "/data/local/tmp/seam-agent.stamp"

    private let adbPath: String
    private let localAgentJarPath: String

    public init(adbPath: String = "/opt/homebrew/bin/adb", localAgentJarPath: String) {
        if FileManager.default.isExecutableFile(atPath: adbPath) {
            self.adbPath = adbPath
        } else {
            self.adbPath = "adb"
        }
        self.localAgentJarPath = localAgentJarPath
    }

    /// Queries `adb devices -l` and returns all attached Android devices (USB and Wireless Debugging).
    public func listDevices() throws -> [AdbDeviceRecord] {
        let output = try runCommand([adbPath, "devices", "-l"])
        var devices = [AdbDeviceRecord]()

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") {
                continue
            }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 2 else { continue }

            let serial = tokens[0]
            let state = tokens[1]
            var model = "Android"
            var transportId = "0"

            for token in tokens.dropFirst(2) {
                if token.hasPrefix("model:") {
                    model = String(token.dropFirst("model:".count))
                } else if token.hasPrefix("transport_id:") {
                    transportId = String(token.dropFirst("transport_id:".count))
                }
            }
            devices.append(AdbDeviceRecord(
                serial: serial,
                state: state,
                model: model,
                transportId: transportId
            ))
        }
        return devices
    }

    /// Connects to an Android 11–15 Wireless Debugging endpoint (`<ip>:<port>`) over Wi-Fi.
    public func connectWirelessAdb(ipAndPort: String, pairingPort: String? = nil, pairingCode: String? = nil) throws -> String {
        if let pairingPort, !pairingPort.isEmpty, let pairingCode, !pairingCode.isEmpty {
            let hostOnly = ipAndPort.split(separator: ":").first.map(String.init) ?? ipAndPort
            let pairTarget = pairingPort.contains(":") ? pairingPort : "\(hostOnly):\(pairingPort)"
            _ = try runCommand([adbPath, "pair", pairTarget, pairingCode])
        }
        let out = try runCommand([adbPath, "connect", ipAndPort]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    /// Queries ADB's built-in mDNS discovery (`adb mdns services`) for advertised Android 11–15
    /// Wireless Debugging endpoints (`_adb-tls-connect._tcp`) and connects to them automatically.
    @discardableResult
    public func discoverAndConnectWirelessAdbMdns() -> [String] {
        guard let output = try? runCommand([adbPath, "mdns", "services"]) else {
            return []
        }
        let alreadyConnected = Set(((try? listDevices()) ?? []).map(\.serial))
        var connectedAddresses = [String]()

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.contains("_adb-tls-connect._tcp") else { continue }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let addr = tokens.last, addr.contains(":"), addr != "_adb-tls-connect._tcp" else {
                continue
            }
            if alreadyConnected.contains(addr) {
                connectedAddresses.append(addr)
                continue
            }
            if let res = try? runCommand([adbPath, "connect", addr]),
               res.contains("connected to") || res.contains("already connected") {
                connectedAddresses.append(addr)
                if let hostOnly = addr.split(separator: ":").first.map(String.init),
                   !hostOnly.isEmpty, !hostOnly.hasPrefix("[") {
                    Self.saveLastWifiIp(hostOnly)
                }
            }
        }
        return connectedAddresses
    }

    /// Attaches `adb forward tcp:0 localabstract:seam_uhid` to an already-running `seam-agent`
    /// daemon on the phone without terminating or restarting it.
    public func setupUsbForwardOnly(serial: String) throws -> SeamEndpoint {
        let portOutput = try runCommand([
            adbPath, "-s", serial,
            "forward", "tcp:0", "localabstract:\(SeamWireProtocol.usbAbstractSocketName)"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let forwardedPort = UInt16(portOutput), forwardedPort > 0 else {
            throw SeamTransportError.bootstrapFailed("Failed to parse forwarded TCP port: '\(portOutput)'")
        }
        return .usbLocalhost(port: forwardedPort, serial: serial)
    }

    /// Queries active Wi-Fi / Hotspot IPv4 endpoints directly from a running daemon's log if present.
    public func queryWifiEndpointsFromDaemonLog(serial: String) -> [DiscoveredWifiEndpoint] {
        guard let logContent = try? runCommand([adbPath, "-s", serial, "shell", "cat \(Self.remoteLogPath) 2>/dev/null || true"]) else {
            return []
        }
        return parseWifiEndpoints(fromLog: logContent)
    }

    /// Directly probes the local Wi-Fi network / Personal Hotspot via UDP (`SEAM_DISCOVER_V1`) to locate
    /// an already-running detached `seam-agent` daemon without needing a USB cable or active ADB!
    public func discoverRunningWirelessAgent(customHostIp: String? = nil) -> [DiscoveredWifiEndpoint] {
        var candidateIps = [String]()
        if let customHostIp, !customHostIp.isEmpty {
            candidateIps.append(customHostIp)
        }
        if let savedIp = Self.loadLastWifiIp(), !candidateIps.contains(savedIp) {
            candidateIps.append(savedIp)
        }
        // Check default gateway IP (on an Android Personal Hotspot like 10.11.67.190, the phone IS the gateway!)
        if let gw = queryMacDefaultGatewayIp(), !candidateIps.contains(gw) {
            candidateIps.append(gw)
        }
        candidateIps.append("255.255.255.255")

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var broadcastFlag: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastFlag, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 0, tv_usec: 350_000) // 350 ms probe window
        Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let probeBytes = Array("SEAM_DISCOVER_V1".utf8)
        let port = SeamWireProtocol.wifiDefaultPort

        for ip in candidateIps {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(ip)

            _ = probeBytes.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.sendto(fd, rawBuf.baseAddress, probeBytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var discovered = [DiscoveredWifiEndpoint]()
        var recvBuf = [UInt8](repeating: 0, count: 128)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = recvBuf.withUnsafeMutableBytes { rawBuf -> Int in
            withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.recvfrom(fd, rawBuf.baseAddress, 128, 0, sa, &senderLen)
                }
            }
        }

        if n > 0, let reply = String(bytes: recvBuf[0..<n], encoding: .utf8),
           reply.hasPrefix("SEAM_OFFER_V1") {
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = senderAddr.sin_addr
            if inet_ntop(AF_INET, &inAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                let senderIp = String(cString: ipBuf)
                Self.saveLastWifiIp(senderIp)
                discovered.append(DiscoveredWifiEndpoint(
                    interfaceName: "wifi",
                    ipv4Address: senderIp,
                    port: port
                ))
            }
        }
        return discovered
    }

    /// Bootstraps `seam-agent --server --detach` as a persistent `nohup` background daemon on the phone
    /// that survives USB cable unplugging and Wireless Debugging shutdowns.
    public func bootstrapSession(preferredSerial: String? = nil, detachDaemon: Bool = true) throws -> (
        device: AdbDeviceRecord,
        usbEndpoint: SeamEndpoint,
        wifiEndpoints: [DiscoveredWifiEndpoint],
        authenticator: SeamAuthenticator,
        agentProcess: Process?
    ) {
        let authenticator = SeamAuthenticator.loadOrCreatePersistentKey()
        let devices = try listDevices()
        guard !devices.isEmpty else {
            throw SeamTransportError.deviceNotFound("No Android device detected over ADB.")
        }

        let target: AdbDeviceRecord
        if let preferredSerial {
            guard let match = devices.first(where: { $0.serial == preferredSerial }) else {
                throw SeamTransportError.deviceNotFound("Device \(preferredSerial) not found.")
            }
            target = match
        } else {
            target = devices[0]
        }

        if target.state == "unauthorized" {
            throw SeamTransportError.deviceUnauthorized(
                "Device \(target.serial) (\(target.model)) is unauthorized. Tap 'Allow USB debugging' on the phone."
            )
        }
        guard target.isAuthorized else {
            throw SeamTransportError.bootstrapFailed("Device \(target.serial) is in state '\(target.state)'")
        }

        guard FileManager.default.fileExists(atPath: localAgentJarPath) else {
            throw SeamTransportError.bootstrapFailed("Local agent archive missing at \(localAgentJarPath). Run 'make build-agent'.")
        }

        // 1. Ensure on-screen touch keyboard (Gboard) is ALWAYS enabled on the phone
        _ = try? runCommand([adbPath, "-s", target.serial, "shell", "settings put secure show_ime_with_hard_keyboard 1"])

        // 2. Check if seam-agent is ALREADY running with the exact matching jar & auth key stamp.
        //    If so, reuse it seamlessly without interrupting active Wi-Fi connections!
        let expectedStamp = computeAgentStamp(jarPath: localAgentJarPath, authKeyHex: authenticator.secretKeyHex)
        let probeCmd = "((pgrep -f seam_agent >/dev/null 2>&1 || ps -A 2>/dev/null | grep -q '[s]eam_agent') && cat \(Self.remoteStampPath) 2>/dev/null) || true"
        let runningStamp = (try? runCommand([adbPath, "-s", target.serial, "shell", probeCmd]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let wifiEndpoints: [DiscoveredWifiEndpoint]
        if !expectedStamp.isEmpty && runningStamp == expectedStamp {
            let (ready, existingEndpoints) = waitForDaemonLogReady(serial: target.serial, timeoutSeconds: 0.5)
            if ready {
                wifiEndpoints = existingEndpoints
            } else {
                wifiEndpoints = try deployAndLaunchDetachedDaemon(serial: target.serial, authKeyHex: authenticator.secretKeyHex, stamp: expectedStamp)
            }
        } else {
            wifiEndpoints = try deployAndLaunchDetachedDaemon(serial: target.serial, authKeyHex: authenticator.secretKeyHex, stamp: expectedStamp)
        }

        if let firstWifi = wifiEndpoints.first {
            Self.saveLastWifiIp(firstWifi.ipv4Address)
        }

        // 3. Setup dynamic ADB port forward: tcp:0 -> localabstract:seam_uhid
        let usbEndpoint = try setupUsbForwardOnly(serial: target.serial)

        return (
            device: target,
            usbEndpoint: usbEndpoint,
            wifiEndpoints: wifiEndpoints,
            authenticator: authenticator,
            agentProcess: nil
        )
    }

    private func deployAndLaunchDetachedDaemon(
        serial: String,
        authKeyHex: String,
        stamp: String
    ) throws -> [DiscoveredWifiEndpoint] {
        _ = try? runCommand([adbPath, "-s", serial, "shell", "pkill -f seam_agent || true"])
        _ = try runCommand([adbPath, "-s", serial, "push", localAgentJarPath, Self.remoteJarPath])

        let launchScript = """
        rm -f \(Self.remoteLogPath); \
        printf '%s' '\(stamp)' > \(Self.remoteStampPath); \
        nohup sh -c 'ANDROID_NO_USE_FWMARK_CLIENT=1 CLASSPATH=\(Self.remoteJarPath) app_process /system/bin --nice-name=seam_agent com.seam.agent.Main --server --detach --auth-key=\(authKeyHex)' >\(Self.remoteLogPath) 2>&1 </dev/null &
        """
        _ = try runCommand([adbPath, "-s", serial, "shell", launchScript])

        let (ready, wifiEndpoints) = waitForDaemonLogReady(serial: serial, timeoutSeconds: 4.0)
        guard ready else {
            throw SeamTransportError.bootstrapFailed("Timed out waiting for detached seam-agent daemon on \(serial)")
        }
        return wifiEndpoints
    }

    private func computeAgentStamp(jarPath: String, authKeyHex: String) -> String {
        guard let jarData = try? Data(contentsOf: URL(fileURLWithPath: jarPath)) else {
            return ""
        }
        let jarDigest = SHA256.hash(data: jarData)
        let keyDigest = SHA256.hash(data: Data(authKeyHex.utf8))
        let jarHex = jarDigest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let keyHex = keyDigest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(jarHex):\(keyHex)"
    }

    public func bootstrapUsbSession(preferredSerial: String? = nil) throws -> (
        device: AdbDeviceRecord,
        endpoint: SeamEndpoint,
        authenticator: SeamAuthenticator,
        agentProcess: Process?
    ) {
        let res = try bootstrapSession(preferredSerial: preferredSerial)
        return (res.device, res.usbEndpoint, res.authenticator, res.agentProcess)
    }

    /// Removes local ADB port forwarding while leaving the detached `seam-agent` daemon running
    /// in the background on the phone so wireless Wi-Fi sessions continue working after USB unplug!
    public func teardownSession(serial: String, agentProcess: Process?, stopRemoteDaemon: Bool = false) {
        _ = try? runCommand([adbPath, "-s", serial, "forward", "--remove-all"])
        if let agentProcess, agentProcess.isRunning {
            agentProcess.terminate()
        }
        if stopRemoteDaemon {
            _ = try? runCommand([adbPath, "-s", serial, "shell", "pkill -INT -f seam_agent || true"])
        }
    }

    public func teardownUsbSession(serial: String, agentProcess: Process?) {
        teardownSession(serial: serial, agentProcess: agentProcess, stopRemoteDaemon: false)
    }

    private func waitForDaemonLogReady(
        serial: String,
        timeoutSeconds: TimeInterval
    ) -> (Bool, [DiscoveredWifiEndpoint]) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if let logContent = try? runCommand([adbPath, "-s", serial, "shell", "cat \(Self.remoteLogPath) 2>/dev/null || true"]),
               logContent.contains("SEAM_AGENT_READY") {
                return (true, parseWifiEndpoints(fromLog: logContent))
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
        return (false, [])
    }

    private func parseWifiEndpoints(fromLog logContent: String) -> [DiscoveredWifiEndpoint] {
        var endpoints = [DiscoveredWifiEndpoint]()
        for line in logContent.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("SEAM_WIFI_ENDPOINT:") {
                let parts = trimmed.split(separator: ":").map(String.init)
                if parts.count == 4, let port = UInt16(parts[3]) {
                    endpoints.append(DiscoveredWifiEndpoint(
                        interfaceName: parts[1],
                        ipv4Address: parts[2],
                        port: port
                    ))
                }
            }
        }
        return endpoints
    }

    private func queryMacDefaultGatewayIp() -> String? {
        guard let out = try? runCommand(["/usr/sbin/netstat", "-rn", "-f", "inet"]) else { return nil }
        for line in out.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if tokens.count >= 2 && tokens[0] == "default" {
                let gw = tokens[1]
                if gw.contains(".") && !gw.hasPrefix("127.") {
                    return gw
                }
            }
        }
        return nil
    }

    public static func saveLastWifiIp(_ ip: String) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".seam")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("last_wifi_ip")
        try? ip.write(to: file, atomically: true, encoding: .utf8)
    }

    public static func loadLastWifiIp() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".seam/last_wifi_ip")
        guard let ip = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else {
            return nil
        }
        return ip
    }

    private func runCommand(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            throw SeamTransportError.bootstrapFailed(
                "Command '\(args.joined(separator: " "))' exited with \(proc.terminationStatus): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return outStr
    }
}
