import AppKit
import CoreGraphics
import Foundation

// Private WindowServer SPI used by software KVMs (Deskflow, Input Leap, Synergy) to allow
// hiding the macOS cursor while another macOS application remains the active foreground window.
@_silgen_name("_CGSDefaultConnection")
private func CGSDefaultConnection() -> Int32

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(
    _ cid: Int32,
    _ targetCid: Int32,
    _ key: CFString,
    _ value: CFTypeRef
) -> CGError

/// Controls macOS physical mouse-to-cursor association (`CGAssociateMouseAndMouseCursorPosition`),
/// instant warp positioning (`CGWarpMouseCursorPosition`), and background cursor visibility.
public final class BackgroundCursorController {
    private let lock = NSLock()
    private var isCursorDecoupled = false
    private var isCursorHidden = false
    private let eventSource: CGEventSource?

    public init() {
        self.eventSource = CGEventSource(stateID: .combinedSessionState)
        // Disable the default 250 ms hardware event suppression delay after calling CGWarpMouseCursorPosition
        self.eventSource?.localEventsSuppressionInterval = 0.0
        enableBackgroundCursorSetting()
    }

    private func enableBackgroundCursorSetting() {
        let cid = CGSDefaultConnection()
        _ = CGSSetConnectionProperty(
            cid,
            cid,
            "SetsCursorInBackground" as CFString,
            kCFBooleanTrue
        )
    }

    /// Decouples physical mouse movement from the macOS cursor position and hides the macOS cursor graphic.
    public func captureAndHideMacCursor(parkPoint: CGPoint) {
        lock.lock()
        defer { lock.unlock() }

        enableBackgroundCursorSetting()

        if !isCursorDecoupled {
            CGAssociateMouseAndMouseCursorPosition(0) // false
            isCursorDecoupled = true
        }
        if !isCursorHidden {
            CGDisplayHideCursor(CGMainDisplayID())
            isCursorHidden = true
        }
    }

    /// Warps the macOS cursor to `returnPoint`, re-associates physical mouse tracking, and unhides the cursor.
    public func releaseAndRestoreMacCursor(returnPoint: CGPoint) {
        lock.lock()
        defer { lock.unlock() }

        CGWarpMouseCursorPosition(returnPoint)

        if isCursorDecoupled {
            CGAssociateMouseAndMouseCursorPosition(1) // true
            isCursorDecoupled = false
        }

        if isCursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            isCursorHidden = false
        }
    }
}
