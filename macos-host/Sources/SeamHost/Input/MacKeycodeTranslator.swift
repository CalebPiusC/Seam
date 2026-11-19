import CoreGraphics
import Foundation

/// Translates macOS Quartz virtual keycodes (`CGKeyCode`, `<Carbon/HIToolbox/Events.h>`) and modifier flags
/// (`CGEventFlags`) into standard 8-byte USB HID Usage Page `0x07` 6-Key Rollover (6KRO) reports.
///
/// Includes ergonomic macOS-to-Android shortcut remapping: when `Command (⌘)` is held with standard editing
/// and browser keys (`A, B, C, F, I, K, L, N, P, R, S, T, U, V, W, X, Y, Z`), translates the modifier from
/// `Left GUI` to `Left Control`, and maps Mac navigation/deletion chords (`Cmd+Arrows`, `Opt+Arrows`,
/// `Opt/Cmd+Backspace`) to native Android line/document/word navigation without flashing stray `Meta` taps.
public final class MacKeycodeTranslator {
    private enum ShortcutModifierMode {
        case stripToShiftOnly
        case forceCtrlKeepShift
    }

    // USB HID Keyboard Modifier Bitmasks (Byte 0)
    public static let modLeftCtrl: UInt8   = 1 << 0 // 0x01
    public static let modLeftShift: UInt8  = 1 << 1 // 0x02
    public static let modLeftAlt: UInt8    = 1 << 2 // 0x04
    public static let modLeftMeta: UInt8   = 1 << 3 // 0x08
    public static let modRightCtrl: UInt8  = 1 << 4 // 0x10
    public static let modRightShift: UInt8 = 1 << 5 // 0x20
    public static let modRightAlt: UInt8   = 1 << 6 // 0x40
    public static let modRightMeta: UInt8  = 1 << 7 // 0x80

    private static let hidLeftArrow: UInt8  = 0x50
    private static let hidRightArrow: UInt8 = 0x4F
    private static let hidUpArrow: UInt8    = 0x52
    private static let hidDownArrow: UInt8  = 0x51
    private static let hidHome: UInt8       = 0x4A
    private static let hidEnd: UInt8        = 0x4D
    private static let hidBackspace: UInt8  = 0x2A

    private let lock = NSLock()
    private var pressedHidKeys: [UInt8] = []
    private var shortcutModesByUsage: [UInt8: ShortcutModifierMode] = [:]
    private var currentModifiers: UInt8 = 0
    public var remapCommandShortcutsToControl: Bool = true

    public init() {}

    /// Resets all tracked held keys and modifiers.
    public func reset() {
        lock.lock()
        pressedHidKeys.removeAll()
        shortcutModesByUsage.removeAll()
        currentModifiers = 0
        lock.unlock()
    }

    /// Processes a `kCGEventFlagsChanged` event and returns an updated `SeamOutboundFrame.keyReport`.
    public func handleFlagsChanged(flags: CGEventFlags) -> SeamOutboundFrame {
        lock.lock()
        defer { lock.unlock() }

        currentModifiers = computeEffectiveModifiers(from: flags)
        return buildKeyReportFrame()
    }

    /// Processes a `kCGEventKeyDown` or `kCGEventKeyUp` event and returns an updated `SeamOutboundFrame.keyReport`.
    public func handleKeyEvent(macKeyCode: UInt16, isKeyDown: Bool, flags: CGEventFlags) -> SeamOutboundFrame? {
        guard let baseHidUsage = Self.macToHidUsage[macKeyCode], baseHidUsage != 0 else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        if isKeyDown {
            let (hidUsage, shortcutMode) = resolveNavigationOrEditingTranslation(
                macKeyCode: macKeyCode,
                baseUsage: baseHidUsage,
                flags: flags
            )
            if let shortcutMode {
                shortcutModesByUsage[hidUsage] = shortcutMode
            } else {
                shortcutModesByUsage.removeValue(forKey: hidUsage)
            }
            if !pressedHidKeys.contains(hidUsage) {
                if pressedHidKeys.count >= 6 {
                    let evicted = pressedHidKeys.removeFirst()
                    shortcutModesByUsage.removeValue(forKey: evicted)
                }
                pressedHidKeys.append(hidUsage)
            }
        } else {
            let usagesToRelease = Self.releasableUsages(forMacKeyCode: macKeyCode, baseUsage: baseHidUsage)
            pressedHidKeys.removeAll(where: { usagesToRelease.contains($0) })
            for usage in usagesToRelease {
                shortcutModesByUsage.removeValue(forKey: usage)
            }
        }

        currentModifiers = computeEffectiveModifiers(from: flags)
        return buildKeyReportFrame()
    }

    private func resolveNavigationOrEditingTranslation(
        macKeyCode: UInt16,
        baseUsage: UInt8,
        flags: CGEventFlags
    ) -> (UInt8, ShortcutModifierMode?) {
        if flags.contains(.maskCommand) && remapCommandShortcutsToControl {
            switch macKeyCode {
            case 0x7B: return (Self.hidHome, .stripToShiftOnly)      // Cmd + Left  -> Home
            case 0x7C: return (Self.hidEnd, .stripToShiftOnly)       // Cmd + Right -> End
            case 0x7E: return (Self.hidHome, .forceCtrlKeepShift)    // Cmd + Up    -> Ctrl+Home
            case 0x7D: return (Self.hidEnd, .forceCtrlKeepShift)     // Cmd + Down  -> Ctrl+End
            case 0x33: return (Self.hidBackspace, .forceCtrlKeepShift) // Cmd + Backspace -> Ctrl+Backspace
            default: break
            }
        }

        if flags.contains(.maskAlternate) {
            switch macKeyCode {
            case 0x7B: return (Self.hidLeftArrow, .forceCtrlKeepShift)  // Opt + Left  -> Ctrl+Left
            case 0x7C: return (Self.hidRightArrow, .forceCtrlKeepShift) // Opt + Right -> Ctrl+Right
            case 0x33: return (Self.hidBackspace, .forceCtrlKeepShift)  // Opt + Backspace -> Ctrl+Backspace
            default: break
            }
        }

        return (baseUsage, nil)
    }

    private static func releasableUsages(forMacKeyCode macKeyCode: UInt16, baseUsage: UInt8) -> [UInt8] {
        switch macKeyCode {
        case 0x7B: return [baseUsage, hidHome]
        case 0x7C: return [baseUsage, hidEnd]
        case 0x7E: return [baseUsage, hidHome]
        case 0x7D: return [baseUsage, hidEnd]
        default:   return [baseUsage]
        }
    }

    private func computeEffectiveModifiers(from flags: CGEventFlags) -> UInt8 {
        if let activeMode = shortcutModesByUsage.values.first {
            var mod: UInt8 = flags.contains(.maskShift) ? Self.modLeftShift : 0
            if case .forceCtrlKeepShift = activeMode {
                mod |= Self.modLeftCtrl
            }
            return mod
        }
        return extractHidModifiers(from: flags, activeHidKeys: pressedHidKeys)
    }

    private func extractHidModifiers(from flags: CGEventFlags, activeHidKeys: [UInt8]) -> UInt8 {
        var mod: UInt8 = 0
        if flags.contains(.maskControl)   { mod |= Self.modLeftCtrl }
        if flags.contains(.maskShift)     { mod |= Self.modLeftShift }
        if flags.contains(.maskAlternate) { mod |= Self.modLeftAlt }

        if flags.contains(.maskCommand) {
            if remapCommandShortcutsToControl {
                if activeHidKeys.contains(where: Self.isCommandToCtrlRemappedUsage) {
                    mod |= Self.modLeftCtrl
                } else if !activeHidKeys.isEmpty {
                    mod |= Self.modLeftMeta
                }
            } else {
                mod |= Self.modLeftMeta
            }
        }
        return mod
    }

    private func buildKeyReportFrame() -> SeamOutboundFrame {
        let k0 = pressedHidKeys.count > 0 ? pressedHidKeys[0] : 0
        let k1 = pressedHidKeys.count > 1 ? pressedHidKeys[1] : 0
        let k2 = pressedHidKeys.count > 2 ? pressedHidKeys[2] : 0
        let k3 = pressedHidKeys.count > 3 ? pressedHidKeys[3] : 0
        let k4 = pressedHidKeys.count > 4 ? pressedHidKeys[4] : 0
        let k5 = pressedHidKeys.count > 5 ? pressedHidKeys[5] : 0
        return .keyReport(modifiers: currentModifiers, keys: (k0, k1, k2, k3, k4, k5))
    }

    /// Standard editing/browser shortcuts where macOS users press `Cmd+<Key>` expecting Android `Ctrl+<Key>`.
    private static func isCommandToCtrlRemappedUsage(_ usage: UInt8) -> Bool {
        switch usage {
        case 0x04, // A (Select All)
             0x05, // B (Bold)
             0x06, // C (Copy)
             0x09, // F (Find)
             0x0C, // I (Italic)
             0x0E, // K (Insert Link)
             0x0F, // L (Focus Address Bar)
             0x11, // N (New)
             0x13, // P (Print)
             0x15, // R (Reload)
             0x16, // S (Save)
             0x17, // T (New Tab)
             0x18, // U (Underline)
             0x19, // V (Paste)
             0x1A, // W (Close Tab)
             0x1B, // X (Cut)
             0x1C, // Y (Redo)
             0x1D: // Z (Undo)
            return true
        default:
            return false
        }
    }

    /// Constant O(1) mapping from macOS `CGKeyCode` (`0x00..0x7E`) to USB HID Usage Page `0x07`.
    public static let macToHidUsage: [UInt16: UInt8] = [
        0x00: 0x04, // A
        0x01: 0x16, // S
        0x02: 0x07, // D
        0x03: 0x09, // F
        0x04: 0x0B, // H
        0x05: 0x0A, // G
        0x06: 0x1D, // Z
        0x07: 0x1B, // X
        0x08: 0x06, // C
        0x09: 0x19, // V
        0x0B: 0x05, // B
        0x0C: 0x14, // Q
        0x0D: 0x1A, // W
        0x0E: 0x08, // E
        0x0F: 0x15, // R
        0x10: 0x1C, // Y
        0x11: 0x17, // T
        0x12: 0x1E, // 1
        0x13: 0x1F, // 2
        0x14: 0x20, // 3
        0x15: 0x21, // 4
        0x16: 0x23, // 6
        0x17: 0x22, // 5
        0x18: 0x2E, // =
        0x19: 0x26, // 9
        0x1A: 0x24, // 7
        0x1B: 0x2D, // -
        0x1C: 0x25, // 8
        0x1D: 0x27, // 0
        0x1E: 0x30, // ]
        0x1F: 0x12, // O
        0x20: 0x18, // U
        0x21: 0x2F, // [
        0x22: 0x0C, // I
        0x23: 0x13, // P
        0x24: 0x28, // Return / Enter
        0x25: 0x0F, // L
        0x26: 0x0D, // J
        0x27: 0x34, // '
        0x28: 0x0E, // K
        0x29: 0x33, // ;
        0x2A: 0x31, // \
        0x2B: 0x36, // ,
        0x2C: 0x38, // /
        0x2D: 0x11, // N
        0x2E: 0x10, // M
        0x2F: 0x37, // .
        0x30: 0x2B, // Tab
        0x31: 0x2C, // Space
        0x32: 0x35, // ` / ~
        0x33: 0x2A, // Backspace / Delete
        0x35: 0x29, // Escape
        0x7A: 0x3A, // F1
        0x78: 0x3B, // F2
        0x63: 0x3C, // F3
        0x76: 0x3D, // F4
        0x60: 0x3E, // F5
        0x61: 0x3F, // F6
        0x62: 0x40, // F7
        0x64: 0x41, // F8
        0x65: 0x42, // F9
        0x6D: 0x43, // F10
        0x67: 0x44, // F11
        0x6F: 0x45, // F12
        0x73: 0x4A, // Home
        0x74: 0x4B, // Page Up
        0x75: 0x4C, // Forward Delete
        0x77: 0x4D, // End
        0x79: 0x4E, // Page Down
        0x7B: 0x50, // Left Arrow
        0x7C: 0x4F, // Right Arrow
        0x7D: 0x51, // Down Arrow
        0x7E: 0x52  // Up Arrow
    ]
}
