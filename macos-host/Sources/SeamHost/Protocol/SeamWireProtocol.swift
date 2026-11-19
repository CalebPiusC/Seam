import Foundation

/// `SEAM-Wire v1` binary framing specification shared between macOS and Android across USB and Wi-Fi.
public enum SeamWireProtocol {
    public static let magic: [UInt8] = [0x53, 0x45, 0x41, 0x4D] // "SEAM"
    public static let protocolVersion: UInt8 = 0x01
    public static let usbAbstractSocketName = "seam_uhid"
    public static let wifiDefaultPort: UInt16 = 27186
    public static let maxClipboardBytes: Int = 256 * 1024

    // Transport types
    public static let transportUsb: UInt8  = 0x01
    public static let transportWifi: UInt8 = 0x02

    // Handshake statuses
    public static let authStatusOk: UInt8     = 0x01
    public static let authStatusFailed: UInt8 = 0xFF

    // Screen boundary edges
    public enum ScreenEdge: UInt8, Sendable, CustomStringConvertible {
        case left   = 0x00
        case right  = 0x01
        case top    = 0x02
        case bottom = 0x03

        public var description: String {
            switch self {
            case .left:   return "LEFT"
            case .right:  return "RIGHT"
            case .top:    return "TOP"
            case .bottom: return "BOTTOM"
            }
        }
    }

    // Host -> Android opcodes
    public static let opMouseReport: UInt8  = 0x01
    public static let opKeyReport: UInt8    = 0x02
    public static let opCursorEnter: UInt8  = 0x03
    public static let opCursorLeave: UInt8  = 0x04
    public static let opClipboardSet: UInt8 = 0x05
    public static let opPing: UInt8         = 0x06

    // Android -> Host opcodes
    public static let opDisplayInfo: UInt8    = 0x81
    public static let opEdgeReturn: UInt8     = 0x82
    public static let opClipboardEvent: UInt8 = 0x83
    public static let opPong: UInt8           = 0x84

    /// Normalizes a pixel coordinate (`0 ..< dimensionPx`) into `0 ... 65535`.
    public static func normalizeCoordinate(pixel: Int, dimensionPx: Int) -> UInt16 {
        guard dimensionPx > 1 else { return 0 }
        let clamped = max(0, min(dimensionPx - 1, pixel))
        let scaled = (Double(clamped) / Double(dimensionPx - 1)) * 65535.0
        return UInt16(max(0, min(65535, Int(scaled.rounded()))))
    }

    /// Converts a normalized `0 ... 65535` coordinate back into `0 ..< dimensionPx`.
    public static func denormalizeCoordinate(norm: UInt16, dimensionPx: Int) -> Int {
        guard dimensionPx > 1 else { return 0 }
        let scaled = (Double(norm) / 65535.0) * Double(dimensionPx - 1)
        return Int(scaled.rounded())
    }

    /// Reads and decodes a length-prefixed UTF-8 clipboard payload (`uint32_le length + utf8`).
    public static func readClipboardText(readExact: (Int) throws -> [UInt8]) throws -> String {
        let lenBytes = try readExact(4)
        let length = Int(UInt32(lenBytes[0])
            | (UInt32(lenBytes[1]) << 8)
            | (UInt32(lenBytes[2]) << 16)
            | (UInt32(lenBytes[3]) << 24))
        guard length >= 0 && length <= maxClipboardBytes else {
            throw SeamTransportError.ioError("Invalid clipboard payload length: \(length)")
        }
        guard length > 0 else { return "" }
        let payload = try readExact(length)
        return String(decoding: payload, as: UTF8.self)
    }
}

/// Outbound frames sent from `seam-host` (macOS) to `seam-agent` (Android).
public enum SeamOutboundFrame: Sendable {
    case mouseReport(buttons: UInt8, dx: Int16, dy: Int16, vWheel: Int8, hWheel: Int8)
    case keyReport(modifiers: UInt8, keys: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8))
    case cursorEnter(edge: SeamWireProtocol.ScreenEdge, normX: UInt16, normY: UInt16, flags: UInt8)
    case cursorLeave(reason: UInt8)
    case clipboardSet(text: String)
    case ping(timestampUs: UInt64)

    /// Serializes the frame into its compact little-endian `SEAM-Wire v1` byte array.
    public func serialize() -> [UInt8] {
        switch self {
        case let .mouseReport(buttons, dx, dy, vWheel, hWheel):
            let uDx = UInt16(bitPattern: dx)
            let uDy = UInt16(bitPattern: dy)
            return [
                SeamWireProtocol.opMouseReport,
                buttons & 0x1F,
                UInt8(uDx & 0xFF),
                UInt8((uDx >> 8) & 0xFF),
                UInt8(uDy & 0xFF),
                UInt8((uDy >> 8) & 0xFF),
                UInt8(bitPattern: vWheel),
                UInt8(bitPattern: hWheel)
            ]

        case let .keyReport(modifiers, keys):
            return [
                SeamWireProtocol.opKeyReport,
                modifiers,
                0x00,
                keys.0, keys.1, keys.2, keys.3, keys.4, keys.5
            ]

        case let .cursorEnter(edge, normX, normY, flags):
            return [
                SeamWireProtocol.opCursorEnter,
                edge.rawValue,
                UInt8(normX & 0xFF),
                UInt8((normX >> 8) & 0xFF),
                UInt8(normY & 0xFF),
                UInt8((normY >> 8) & 0xFF),
                flags
            ]

        case let .cursorLeave(reason):
            return [
                SeamWireProtocol.opCursorLeave,
                reason
            ]

        case let .clipboardSet(text):
            var utf8 = Array(text.utf8)
            if utf8.count > SeamWireProtocol.maxClipboardBytes {
                var end = SeamWireProtocol.maxClipboardBytes
                while end > 0 && (utf8[end] & 0xC0) == 0x80 {
                    end -= 1
                }
                utf8 = Array(utf8.prefix(end))
            }
            let len = UInt32(utf8.count)
            var bytes = [UInt8]()
            bytes.reserveCapacity(5 + utf8.count)
            bytes.append(SeamWireProtocol.opClipboardSet)
            bytes.append(UInt8(len & 0xFF))
            bytes.append(UInt8((len >> 8) & 0xFF))
            bytes.append(UInt8((len >> 16) & 0xFF))
            bytes.append(UInt8((len >> 24) & 0xFF))
            bytes.append(contentsOf: utf8)
            return bytes

        case let .ping(timestampUs):
            var bytes = [UInt8](repeating: 0, count: 9)
            bytes[0] = SeamWireProtocol.opPing
            for i in 0..<8 {
                bytes[1 + i] = UInt8((timestampUs >> (i * 8)) & 0xFF)
            }
            return bytes
        }
    }
}

/// Telemetry and control frames received by `seam-host` (macOS) from `seam-agent` (Android).
public struct AndroidDisplayInfo: Sendable, Equatable, CustomStringConvertible {
    public let widthPx: Int
    public let heightPx: Int
    public let densityDpi: Int
    public let rotation: Int
    public let refreshRateHz: Int
    public let flags: UInt16

    public var rotationDegrees: Int {
        switch rotation {
        case 1:  return 90
        case 2:  return 180
        case 3:  return 270
        default: return 0
        }
    }

    public var description: String {
        "\(widthPx)x\(heightPx) px @ \(densityDpi) dpi, rotation=\(rotationDegrees)°, \(refreshRateHz) Hz"
    }
}

public struct AndroidEdgeReturnEvent: Sendable, Equatable, CustomStringConvertible {
    public let edge: SeamWireProtocol.ScreenEdge
    public let normX: UInt16
    public let normY: UInt16
    public let velocity: UInt8

    public var normalizedYRatio: Double {
        Double(normY) / 65535.0
    }

    public var description: String {
        String(format: "EdgeReturn[edge=%@, normX=%u, normY=%u (%.1f%%), velocity=%u]",
               edge.description, normX, normY, normalizedYRatio * 100.0, velocity)
    }
}

public enum SeamInboundFrame: Sendable {
    case displayInfo(AndroidDisplayInfo)
    case edgeReturn(AndroidEdgeReturnEvent)
    case clipboardEvent(text: String)
    case pong(timestampUs: UInt64)
}
