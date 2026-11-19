import CryptoKit
import Foundation

/// Mutual HMAC-SHA256 challenge-response authenticator for SEAM transports (USB and Wi-Fi).
public struct SeamAuthenticator: Sendable {
    public static let nonceSize = 32
    public static let hmacSize  = 32
    public static let udpTagSize = 16
    public static let udpPacketSize = 42
    public static let udpMagic: UInt8 = 0x55 // 'U'

    private static let clientDomain = Array("SEAM-CLIENT-AUTH-v1".utf8)
    private static let serverDomain = Array("SEAM-SERVER-AUTH-v1".utf8)
    private static let udpDomain    = Array("SEAM-UDP-AUTH-v1".utf8)

    public let secretKey: [UInt8]
    public let secretKeyHex: String

    public init(secretKey: [UInt8]) {
        precondition(secretKey.count >= 16, "Authentication key must be at least 16 bytes")
        self.secretKey = secretKey
        self.secretKeyHex = secretKey.map { String(format: "%02x", $0) }.joined()
    }

    /// Generates or loads a persistent 256-bit (32-byte) pairing key stored at `~/.seam/auth_key`
    /// so that a detached `seam-agent` daemon running on the phone can be reconnected over pure Wi-Fi
    /// even after the USB cable is unplugged or the macOS app is restarted.
    public static func loadOrCreatePersistentKey() -> SeamAuthenticator {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let seamDir = home.appendingPathComponent(".seam")
        let keyFile = seamDir.appendingPathComponent("auth_key")

        if let hex = try? String(contentsOf: keyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = parseHexKey(hex),
           parsed.count == 32 {
            return SeamAuthenticator(secretKey: parsed)
        }

        let generated = generateRandomKey()
        try? fm.createDirectory(at: seamDir, withIntermediateDirectories: true)
        try? generated.secretKeyHex.write(to: keyFile, atomically: true, encoding: .utf8)
        return generated
    }

    public static func parseHexKey(_ hex: String) -> [UInt8]? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var idx = clean.startIndex
        for _ in 0..<32 {
            let nextIdx = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<nextIdx], radix: 16) else { return nil }
            bytes.append(b)
            idx = nextIdx
        }
        return bytes
    }

    /// Generates a cryptographically random 256-bit (32-byte) authentication key.
    public static func generateRandomKey() -> SeamAuthenticator {
        var key = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<32 {
            key[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return SeamAuthenticator(secretKey: key)
    }

    /// Executes the client side of the 3-step mutual HMAC-SHA256 handshake over a blocking byte stream.
    ///
    /// - Parameters:
    ///   - readExact: Closure that reads an exact number of bytes from the transport socket.
    ///   - writeAll: Closure that writes all bytes to the transport socket.
    /// - Returns: The authenticated 64-bit `sessionId` assigned by `seam-agent`.
    public func authenticateClientStream(
        readExact: (Int) throws -> [UInt8],
        writeAll: ([UInt8]) throws -> Void
    ) throws -> UInt64 {
        // 1. Read 38-byte Server Challenge: "SEAM"(4B) || version(1B) || transport(1B) || serverNonce(32B)
        let challenge = try readExact(38)
        guard Array(challenge[0..<4]) == SeamWireProtocol.magic else {
            throw SeamTransportError.authenticationFailed("Invalid server protocol magic")
        }
        let version = challenge[4]
        guard version == SeamWireProtocol.protocolVersion else {
            throw SeamTransportError.authenticationFailed("Unsupported protocol version: \(version)")
        }
        let serverNonce = Array(challenge[6..<38])

        // 2. Generate 32-byte Client Nonce and compute Client HMAC-SHA256
        var clientNonce = [UInt8](repeating: 0, count: Self.nonceSize)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<Self.nonceSize {
            clientNonce[i] = UInt8.random(in: 0...255, using: &rng)
        }

        let clientHmac = computeHmac(
            domain: Self.clientDomain,
            firstNonce: serverNonce,
            secondNonce: clientNonce,
            extra: nil
        )

        // Send 68-byte Client Response: "SEAM"(4B) || clientNonce(32B) || clientHmac(32B)
        var response = [UInt8]()
        response.reserveCapacity(68)
        response.append(contentsOf: SeamWireProtocol.magic)
        response.append(contentsOf: clientNonce)
        response.append(contentsOf: clientHmac)
        try writeAll(response)

        // 3. Read 41-byte Server Ack: status(1B) || sessionId(8B, le) || serverHmac(32B)
        let ack = try readExact(41)
        let status = ack[0]
        guard status == SeamWireProtocol.authStatusOk else {
            throw SeamTransportError.authenticationFailed("Server rejected client HMAC (status=0x\(String(format: "%02X", status)))")
        }

        let sessionIdBytes = Array(ack[1..<9])
        let serverHmac = Array(ack[9..<41])

        // Verify Server HMAC to achieve full mutual authentication
        let expectedServerHmac = computeHmac(
            domain: Self.serverDomain,
            firstNonce: clientNonce,
            secondNonce: serverNonce,
            extra: sessionIdBytes
        )
        guard constantTimeEquals(serverHmac, expectedServerHmac) else {
            throw SeamTransportError.authenticationFailed("Server HMAC verification failed")
        }

        var sessionId: UInt64 = 0
        for i in 0..<8 {
            sessionId |= UInt64(sessionIdBytes[i]) << (i * 8)
        }
        return sessionId
    }

    /// Builds and signs a 42-byte UDP fast-path datagram (`bytes[0..<26]` header/payload + `bytes[26..<42]` HMAC-SHA256 tag).
    public func buildSignedUdpDatagram(
        sessionId: UInt64,
        sequence: UInt64,
        opcode: UInt8,
        payload8: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: Self.udpPacketSize)
        pkt[0] = Self.udpMagic
        for i in 0..<8 {
            pkt[1 + i] = UInt8((sessionId >> (i * 8)) & 0xFF)
            pkt[9 + i] = UInt8((sequence >> (i * 8)) & 0xFF)
        }
        pkt[17] = opcode
        pkt[18] = payload8.0
        pkt[19] = payload8.1
        pkt[20] = payload8.2
        pkt[21] = payload8.3
        pkt[22] = payload8.4
        pkt[23] = payload8.5
        pkt[24] = payload8.6
        pkt[25] = payload8.7

        let key = SymmetricKey(data: secretKey)
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Self.udpDomain)
        hmac.update(data: pkt[0..<26])
        let digest = Array(hmac.finalize())
        for i in 0..<Self.udpTagSize {
            pkt[26 + i] = digest[i]
        }
        return pkt
    }

    /// Verifies the 16-byte truncated HMAC-SHA256 tag on an incoming 42-byte UDP datagram.
    public func verifyUdpDatagram(_ pkt: [UInt8]) -> Bool {
        guard pkt.count == Self.udpPacketSize, pkt[0] == Self.udpMagic else {
            return false
        }
        let key = SymmetricKey(data: secretKey)
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Self.udpDomain)
        hmac.update(data: pkt[0..<26])
        let digest = Array(hmac.finalize())

        var diff: UInt8 = 0
        for i in 0..<Self.udpTagSize {
            diff |= digest[i] ^ pkt[26 + i]
        }
        return diff == 0
    }

    private func computeHmac(
        domain: [UInt8],
        firstNonce: [UInt8],
        secondNonce: [UInt8],
        extra: [UInt8]?
    ) -> [UInt8] {
        let key = SymmetricKey(data: secretKey)
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: domain)
        hmac.update(data: firstNonce)
        hmac.update(data: secondNonce)
        if let extra {
            hmac.update(data: extra)
        }
        return Array(hmac.finalize())
    }

    private func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
