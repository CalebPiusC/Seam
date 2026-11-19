import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Active routing target of the user's physical mouse and keyboard.
public enum CursorRoutingTarget: Sendable, Equatable, CustomStringConvertible {
    case macOS
    case android

    public var description: String {
        switch self {
        case .macOS:   return "macOS (Local)"
        case .android: return "Android (Remote)"
        }
    }
}

/// Observer notified when the cursor crosses between macOS and Android or moves on either display.
public protocol QuartzEdgeEngineDelegate: AnyObject {
    func edgeEngine(_ engine: QuartzEdgeEngine, didSwitchTarget target: CursorRoutingTarget)
    func edgeEngine(_ engine: QuartzEdgeEngine, didUpdateNormalizedPosition normX: Double, normY: Double, target: CursorRoutingTarget)
}

/// Borderless transparent capture shield window used when macOS Accessibility (`CGEventTap`)
/// is unavailable (e.g. immediately after an ad-hoc rebuild invalidates the TCC CDHash).
private final class CaptureShieldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}

/// Global macOS Spatial Screen-Edge Crossing & Input Capture Engine.
///
/// Dual-Mode Capture Architecture:
/// 1. **Primary Mode (`CGEventTapCreate`):** Intercepts global HID events at `.cghidEventTap` without
///    deactivating the user's foreground macOS application.
/// 2. **Zero-TCC AppKit Fallback Mode (`CaptureShieldWindow` + `120 Hz` Edge Poll + Local Event Monitor):**
///    If `CGEventTapCreate` returns `nil` (for instance, when an ad-hoc rebuild changes the app signature),
///    seamlessly monitors screen-edge crossings at 120 Hz and presents an invisible capture shield window
///    to stream mouse deltas, clicks, two-finger scrolling, and keyboard input to Android—requiring
///    zero manual TCC re-toggling!
public final class QuartzEdgeEngine {
    public let multiplexer: SeamTransportMultiplexer
    public let cursorController = BackgroundCursorController()
    public let keyTranslator = MacKeycodeTranslator()
    public weak var delegate: (any QuartzEdgeEngineDelegate)?
    public var clipboardSyncEngine: MacClipboardSyncEngine?

    /// Which edge of the MacBook screen the Android phone sits beside (default: `.right`).
    public var activeMacBoundaryEdge: SeamWireProtocol.ScreenEdge = .right

    /// PPI velocity gain multiplier ($\alpha = \text{PPI}_{\text{android}} / \text{PPI}_{\text{mac, logical}}$).
    public var pointerVelocityGain: Double = 1.85

    public private(set) var currentTarget: CursorRoutingTarget = .macOS
    public private(set) var androidDisplay: AndroidDisplayInfo = AndroidDisplayInfo(
        widthPx: 720, heightPx: 1600, densityDpi: 320, rotation: 0, refreshRateHz: 60, flags: 0
    )

    public var isUsingEventTap: Bool {
        eventTapPort != nil
    }

    // macOS display bounds and cursor tracking
    private var macBounds: CGRect
    private var macCursorParkPoint: CGPoint
    private var outwardMacPushAccumulator: Double = 0.0
    private var heldMacMouseButtons: UInt8 = 0
    private var lastReturnToMacTimestampUs: UInt64 = 0
    private var lastEntryToAndroidTimestampUs: UInt64 = 0
    private var skipInitialRemoteDeltas: Int = 0
    private var lastUiPositionUpdateUs: UInt64 = 0
    private var prevPollLocation: CGPoint?

    // Sub-pixel residual accumulators for smooth low-speed tracking and trackpad scrolling
    private var residualDx: Double = 0.0
    private var residualDy: Double = 0.0
    private var residualVScroll: Double = 0.0
    private var residualHScroll: Double = 0.0

    // Estimated normalized position on Android (0.0 ... 1.0) for live UI visualization
    private var estAndroidNormX: Double = 0.5
    private var estAndroidNormY: Double = 0.5

    // Primary CGEventTap state
    fileprivate var eventTapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // 120 Hz boundary poll & Zero-TCC AppKit Capture Shield fallback state
    private var boundaryPollTimer: DispatchSourceTimer?
    private var shieldWindow: CaptureShieldPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var didHideNSCursor: Bool = false
    private var isStarted: Bool = false

    public init(multiplexer: SeamTransportMultiplexer) {
        self.multiplexer = multiplexer
        self.macBounds = CGDisplayBounds(CGMainDisplayID())
        self.macCursorParkPoint = CGPoint(x: macBounds.maxX - 1, y: macBounds.midY)
    }

    /// Checks whether macOS TCC Accessibility permission is granted (`AXIsProcessTrustedWithOptions`).
    public static func checkAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func updateAndroidDisplay(_ info: AndroidDisplayInfo) {
        self.androidDisplay = info
    }

    /// Installs the `CGEventTap` (if Accessibility is trusted) AND starts the 120 Hz Zero-TCC
    /// edge monitor & fallback capture engine. Never fails or blocks when TCC is unavailable.
    public func start() throws {
        stop()

        macBounds = CGDisplayBounds(CGMainDisplayID())
        outwardMacPushAccumulator = 0.0
        prevPollLocation = nil
        isStarted = true

        // 1. Attempt primary CGEventTapCreate without forcing an OS blocking error
        var mask: CGEventMask = 0
        let trackedEvents: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
            .keyDown, .keyUp, .flagsChanged
        ]
        for ev in trackedEvents {
            mask |= (1 << ev.rawValue)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: quartzEventTapCallback,
            userInfo: selfPtr
        ) {
            self.eventTapPort = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            self.eventTapPort = nil
            // 2. Start 120 Hz boundary polling fallback only when CGEventTap is unavailable
            startBoundaryPollTimer()
        }
    }

    public func stop() {
        isStarted = false
        boundaryPollTimer?.cancel()
        boundaryPollTimer = nil

        if currentTarget == .android {
            returnToMacOS(normX: 32768, normY: 32768)
        } else {
            teardownCaptureShield()
        }

        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTapPort = nil
    }

    /// Invoked when `seam-agent` sends an `EDGE_RETURN (0x82)` frame indicating the Android cursor
    /// crossed the return edge of the phone screen back toward the MacBook.
    public func handleAndroidEdgeReturn(_ event: AndroidEdgeReturnEvent) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleAndroidEdgeReturn(event)
            }
            return
        }
        guard currentTarget == .android else { return }
        returnToMacOS(normX: event.normX, normY: event.normY)
    }

    /// Force-returns cursor control to macOS (e.g., via panic hotkey or UI button).
    public func forceReturnToMacOS() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.forceReturnToMacOS()
            }
            return
        }
        let normY = UInt16(max(0, min(65535, Int((estAndroidNormY * 65535.0).rounded()))))
        let normX = UInt16(max(0, min(65535, Int((estAndroidNormX * 65535.0).rounded()))))
        try? multiplexer.send(.cursorLeave(reason: 1), reliability: .reliableOrdered)
        returnToMacOS(normX: normX, normY: normY)
    }

    // MARK: - 120 Hz Screen Boundary Poll (Zero-TCC Edge Detection)

    private func startBoundaryPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.handleBoundaryPollTick()
        }
        self.boundaryPollTimer = timer
        timer.resume()
    }

    private func handleBoundaryPollTick() {
        guard isStarted, currentTarget == .macOS, eventTapPort == nil else { return }

        macBounds = CGDisplayBounds(CGMainDisplayID())
        let cocoaLoc = NSEvent.mouseLocation
        let quartzLoc = CGPoint(x: cocoaLoc.x, y: macBounds.height - cocoaLoc.y)

        let macNormX = max(0.0, min(1.0, Double(quartzLoc.x - macBounds.minX) / Double(max(1.0, macBounds.width))))
        let macNormY = max(0.0, min(1.0, Double(quartzLoc.y - macBounds.minY) / Double(max(1.0, macBounds.height))))
        emitThrottledPositionUpdate(normX: macNormX, normY: macNormY, target: .macOS, force: false)

        let pollDx = prevPollLocation.map { Double(quartzLoc.x - $0.x) } ?? 0.0
        let pollDy = prevPollLocation.map { Double(quartzLoc.y - $0.y) } ?? 0.0
        prevPollLocation = quartzLoc

        evaluateBoundaryCrossing(loc: quartzLoc, rawDx: pollDx, rawDy: pollDy, isPollingTick: true)
    }

    /// Evaluates whether the cursor at `loc` should cross onto Android.
    /// Returns `true` if transition occurred.
    @discardableResult
    private func evaluateBoundaryCrossing(loc: CGPoint, rawDx: Double, rawDy: Double, isPollingTick: Bool) -> Bool {
        // Respect 180 ms cooldown after returning from Android so the cursor doesn't immediately bounce back
        if MonotonicClock.nowMicroseconds() &- lastReturnToMacTimestampUs < 180_000 {
            outwardMacPushAccumulator = 0.0
            return false
        }

        // Exclude top 24 pt (macOS Menu Bar) and 16 pt corners (Hot Corners)
        let inSafeVerticalBand = (loc.y > macBounds.minY + 24.0) && (loc.y < macBounds.maxY - 16.0)
        let inSafeHorizontalBand = (loc.x > macBounds.minX + 16.0) && (loc.x < macBounds.maxX - 16.0)

        var inEdgeZone = false
        var inSafeBand = false
        var distanceFromEdge = Double.greatestFiniteMagnitude
        var outwardDelta = 0.0

        switch activeMacBoundaryEdge {
        case .right:
            distanceFromEdge = Double(macBounds.maxX - loc.x)
            inSafeBand = inSafeVerticalBand
            inEdgeZone = distanceFromEdge <= 3.0
            if rawDx > 0 { outwardDelta = rawDx }
        case .left:
            distanceFromEdge = Double(loc.x - macBounds.minX)
            inSafeBand = inSafeVerticalBand
            inEdgeZone = distanceFromEdge <= 3.0
            if rawDx < 0 { outwardDelta = -rawDx }
        case .bottom:
            distanceFromEdge = Double(macBounds.maxY - loc.y)
            inSafeBand = inSafeHorizontalBand
            inEdgeZone = distanceFromEdge <= 3.0
            if rawDy > 0 { outwardDelta = rawDy }
        case .top:
            distanceFromEdge = Double(loc.y - macBounds.minY)
            inSafeBand = inSafeHorizontalBand
            inEdgeZone = distanceFromEdge <= 3.0
            if rawDy < 0 { outwardDelta = -rawDy }
        }

        if inEdgeZone && inSafeBand {
            if outwardDelta > 0 {
                outwardMacPushAccumulator += outwardDelta
            } else if isPollingTick {
                // Edge-dwelling push accumulation when Cocoa clamps mouseLocation at the wall
                outwardMacPushAccumulator += 0.55
            }
            if outwardMacPushAccumulator >= 2.0 {
                transitionToAndroid(macExitPoint: loc)
                return true
            }
        } else if distanceFromEdge > 10.0 || !inSafeBand {
            outwardMacPushAccumulator = 0.0
        }
        return false
    }

    // MARK: - Transition Lifecycle (macOS <-> Android)

    private func transitionToAndroid(macExitPoint: CGPoint) {
        guard currentTarget == .macOS else { return }
        macBounds = CGDisplayBounds(CGMainDisplayID())

        let ratioX = max(0.0, min(1.0, Double(macExitPoint.x - macBounds.minX) / Double(max(1.0, macBounds.width))))
        let ratioY = max(0.0, min(1.0, Double(macExitPoint.y - macBounds.minY) / Double(max(1.0, macBounds.height))))

        let androidEntryEdge: SeamWireProtocol.ScreenEdge
        let entryNormX: UInt16
        let entryNormY: UInt16

        switch activeMacBoundaryEdge {
        case .right:
            androidEntryEdge = .left
            entryNormX = 360
            entryNormY = UInt16((ratioY * 65535.0).rounded())
            estAndroidNormX = 0.01
            estAndroidNormY = ratioY
        case .left:
            androidEntryEdge = .right
            entryNormX = 65175
            entryNormY = UInt16((ratioY * 65535.0).rounded())
            estAndroidNormX = 0.99
            estAndroidNormY = ratioY
        case .bottom:
            androidEntryEdge = .top
            entryNormX = UInt16((ratioX * 65535.0).rounded())
            entryNormY = 360
            estAndroidNormX = ratioX
            estAndroidNormY = 0.01
        case .top:
            androidEntryEdge = .bottom
            entryNormX = UInt16((ratioX * 65535.0).rounded())
            entryNormY = 65175
            estAndroidNormX = ratioX
            estAndroidNormY = 0.99
        }

        do {
            try multiplexer.send(
                .cursorEnter(edge: androidEntryEdge, normX: entryNormX, normY: entryNormY, flags: 0),
                reliability: .reliableOrdered
            )
        } catch {
            return
        }

        macCursorParkPoint = macExitPoint
        residualDx = 0
        residualDy = 0
        residualVScroll = 0
        residualHScroll = 0
        outwardMacPushAccumulator = 0
        lastEntryToAndroidTimestampUs = MonotonicClock.nowMicroseconds()
        skipInitialRemoteDeltas = 2
        keyTranslator.reset()
        clipboardSyncEngine?.syncLocalPasteboardToAndroidIfNeeded()

        currentTarget = .android

        if eventTapPort != nil {
            cursorController.captureAndHideMacCursor(parkPoint: macCursorParkPoint)
        } else {
            activateCaptureShieldFallback(parkPoint: macCursorParkPoint)
        }

        delegate?.edgeEngine(self, didSwitchTarget: .android)
        emitThrottledPositionUpdate(normX: estAndroidNormX, normY: estAndroidNormY, target: .android, force: true)
    }

    private func returnToMacOS(normX: UInt16, normY: UInt16) {
        macBounds = CGDisplayBounds(CGMainDisplayID())
        let ratioX = Double(normX) / 65535.0
        let ratioY = Double(normY) / 65535.0

        let returnPoint: CGPoint
        switch activeMacBoundaryEdge {
        case .right:
            returnPoint = CGPoint(
                x: macBounds.maxX - 6.0,
                y: macBounds.minY + CGFloat(ratioY) * macBounds.height
            )
        case .left:
            returnPoint = CGPoint(
                x: macBounds.minX + 6.0,
                y: macBounds.minY + CGFloat(ratioY) * macBounds.height
            )
        case .bottom:
            returnPoint = CGPoint(
                x: macBounds.minX + CGFloat(ratioX) * macBounds.width,
                y: macBounds.maxY - 6.0
            )
        case .top:
            returnPoint = CGPoint(
                x: macBounds.minX + CGFloat(ratioX) * macBounds.width,
                y: macBounds.minY + 26.0
            )
        }

        lastReturnToMacTimestampUs = MonotonicClock.nowMicroseconds()
        currentTarget = .macOS
        heldMacMouseButtons = 0
        outwardMacPushAccumulator = 0
        prevPollLocation = returnPoint
        keyTranslator.reset()

        teardownCaptureShield()
        cursorController.releaseAndRestoreMacCursor(returnPoint: returnPoint)

        let macNormX = Double(returnPoint.x - macBounds.minX) / Double(max(1.0, macBounds.width))
        let macNormY = Double(returnPoint.y - macBounds.minY) / Double(max(1.0, macBounds.height))
        delegate?.edgeEngine(self, didSwitchTarget: .macOS)
        emitThrottledPositionUpdate(normX: macNormX, normY: macNormY, target: .macOS, force: true)
    }

    // MARK: - Zero-TCC AppKit Capture Shield Fallback

    private func activateCaptureShieldFallback(parkPoint: CGPoint) {
        let totalCocoaFrame = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        let frame = totalCocoaFrame.isEmpty
            ? CGRect(x: 0, y: 0, width: macBounds.width, height: macBounds.height)
            : totalCocoaFrame

        let win: CaptureShieldPanel
        if let existing = shieldWindow {
            win = existing
        } else {
            let created = CaptureShieldPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isFloatingPanel = true
            created.hidesOnDeactivate = false
            created.backgroundColor = NSColor.black.withAlphaComponent(0.005)
            created.isOpaque = false
            created.hasShadow = false
            created.ignoresMouseEvents = false
            created.acceptsMouseMovedEvents = true
            created.level = .popUpMenu
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            created.isReleasedWhenClosed = false
            self.shieldWindow = created
            win = created
        }

        win.setFrame(frame, display: false)
        win.orderFrontRegardless()
        win.makeKey()

        cursorController.captureAndHideMacCursor(parkPoint: parkPoint)
        if !didHideNSCursor {
            NSCursor.hide()
            didHideNSCursor = true
        }

        if localEventMonitor == nil {
            let localEventMask: NSEvent.EventTypeMask = [
                .mouseMoved,
                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                .scrollWheel,
                .keyDown, .keyUp, .flagsChanged
            ]
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: localEventMask) { [weak self] event in
                guard let self else { return event }
                return self.handleFallbackAppKitEvent(event)
            }
        }

        if globalEventMonitor == nil {
            let globalEventMask: NSEvent.EventTypeMask = [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .scrollWheel,
                .keyDown, .keyUp, .flagsChanged
            ]
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalEventMask) { [weak self] event in
                guard let self else { return }
                _ = self.handleFallbackAppKitEvent(event)
            }
        }
    }

    private func teardownCaptureShield() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        shieldWindow?.orderOut(nil)
        if didHideNSCursor {
            NSCursor.unhide()
            didHideNSCursor = false
        }
    }

    private func handleFallbackAppKitEvent(_ event: NSEvent) -> NSEvent? {
        guard currentTarget == .android else { return event }

        let cgFlags = cgEventFlags(from: event.modifierFlags)

        switch event.type {
        case .keyDown:
            let keyCode = UInt16(event.keyCode)
            let isCtrlOptCmdEsc = (keyCode == 0x35) &&
                cgFlags.contains(.maskControl) &&
                cgFlags.contains(.maskAlternate) &&
                cgFlags.contains(.maskCommand)
            let isCtrlOptQ = (keyCode == 0x0C) &&
                cgFlags.contains(.maskControl) &&
                cgFlags.contains(.maskAlternate)
            if isCtrlOptCmdEsc || isCtrlOptQ {
                forceReturnToMacOS()
                return nil
            }
            syncClipboardIfPasteShortcut(keyCode: keyCode, flags: cgFlags)
            if let frame = keyTranslator.handleKeyEvent(macKeyCode: keyCode, isKeyDown: true, flags: cgFlags) {
                try? multiplexer.send(frame, reliability: .reliableOrdered)
            }
            return nil

        case .keyUp:
            if let frame = keyTranslator.handleKeyEvent(macKeyCode: UInt16(event.keyCode), isKeyDown: false, flags: cgFlags) {
                try? multiplexer.send(frame, reliability: .reliableOrdered)
            }
            return nil

        case .flagsChanged:
            let frame = keyTranslator.handleFlagsChanged(flags: cgFlags)
            try? multiplexer.send(frame, reliability: .reliableOrdered)
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            forwardRelativeMouseDelta(rawDx: Double(event.deltaX), rawDy: Double(event.deltaY))
            return nil

        case .leftMouseDown:
            heldMacMouseButtons |= 0x01
            sendReliableButtonReport()
            return nil

        case .leftMouseUp:
            heldMacMouseButtons &= ~0x01
            sendReliableButtonReport()
            return nil

        case .rightMouseDown:
            heldMacMouseButtons |= 0x02
            sendReliableButtonReport()
            return nil

        case .rightMouseUp:
            heldMacMouseButtons &= ~0x02
            sendReliableButtonReport()
            return nil

        case .otherMouseDown:
            if event.buttonNumber == 2 { heldMacMouseButtons |= 0x04 }
            else if event.buttonNumber == 3 { heldMacMouseButtons |= 0x08 }
            else if event.buttonNumber == 4 { heldMacMouseButtons |= 0x10 }
            sendReliableButtonReport()
            return nil

        case .otherMouseUp:
            if event.buttonNumber == 2 { heldMacMouseButtons &= ~0x04 }
            else if event.buttonNumber == 3 { heldMacMouseButtons &= ~0x08 }
            else if event.buttonNumber == 4 { heldMacMouseButtons &= ~0x10 }
            sendReliableButtonReport()
            return nil

        case .scrollWheel:
            forwardScroll(
                isContinuous: event.hasPreciseScrollingDeltas,
                ptY: Double(event.scrollingDeltaY),
                ptX: Double(event.scrollingDeltaX)
            )
            return nil

        default:
            return nil
        }
    }

    private func cgEventFlags(from cocoaFlags: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags = CGEventFlags()
        if cocoaFlags.contains(.control) { flags.insert(.maskControl) }
        if cocoaFlags.contains(.shift)   { flags.insert(.maskShift) }
        if cocoaFlags.contains(.option)  { flags.insert(.maskAlternate) }
        if cocoaFlags.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    // MARK: - Primary CGEventTap Handler

    fileprivate func handleQuartzEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTapPort {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let isCtrlOptCmdEsc = (keyCode == 0x35) &&
                flags.contains(.maskControl) &&
                flags.contains(.maskAlternate) &&
                flags.contains(.maskCommand)
            let isCtrlOptQ = (keyCode == 0x0C) &&
                flags.contains(.maskControl) &&
                flags.contains(.maskAlternate)

            if isCtrlOptCmdEsc || isCtrlOptQ {
                if currentTarget == .android {
                    forceReturnToMacOS()
                    return nil
                }
            }
        }

        if currentTarget == .macOS {
            if type == .mouseMoved {
                let loc = event.location
                let rawDx = Double(event.getIntegerValueField(.mouseEventDeltaX))
                let rawDy = Double(event.getIntegerValueField(.mouseEventDeltaY))

                let macNormX = max(0.0, min(1.0, Double(loc.x - macBounds.minX) / Double(max(1.0, macBounds.width))))
                let macNormY = max(0.0, min(1.0, Double(loc.y - macBounds.minY) / Double(max(1.0, macBounds.height))))
                emitThrottledPositionUpdate(normX: macNormX, normY: macNormY, target: .macOS, force: false)

                if evaluateBoundaryCrossing(loc: loc, rawDx: rawDx, rawDy: rawDy, isPollingTick: false) {
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let rawDx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let rawDy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            forwardRelativeMouseDelta(rawDx: rawDx, rawDy: rawDy)
            return nil

        case .leftMouseDown:
            heldMacMouseButtons |= 0x01
            sendReliableButtonReport()
            return nil

        case .leftMouseUp:
            heldMacMouseButtons &= ~0x01
            sendReliableButtonReport()
            return nil

        case .rightMouseDown:
            heldMacMouseButtons |= 0x02
            sendReliableButtonReport()
            return nil

        case .rightMouseUp:
            heldMacMouseButtons &= ~0x02
            sendReliableButtonReport()
            return nil

        case .otherMouseDown:
            let btnNum = event.getIntegerValueField(.mouseEventButtonNumber)
            if btnNum == 2 { heldMacMouseButtons |= 0x04 }
            else if btnNum == 3 { heldMacMouseButtons |= 0x08 }
            else if btnNum == 4 { heldMacMouseButtons |= 0x10 }
            sendReliableButtonReport()
            return nil

        case .otherMouseUp:
            let btnNum = event.getIntegerValueField(.mouseEventButtonNumber)
            if btnNum == 2 { heldMacMouseButtons &= ~0x04 }
            else if btnNum == 3 { heldMacMouseButtons &= ~0x08 }
            else if btnNum == 4 { heldMacMouseButtons &= ~0x10 }
            sendReliableButtonReport()
            return nil

        case .scrollWheel:
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let ptY = isContinuous
                ? event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                : event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let ptX = isContinuous
                ? event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
                : event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            forwardScroll(isContinuous: isContinuous, ptY: ptY, ptX: ptX)
            return nil

        case .keyDown, .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown {
                syncClipboardIfPasteShortcut(keyCode: keyCode, flags: event.flags)
            }
            if let frame = keyTranslator.handleKeyEvent(
                macKeyCode: keyCode,
                isKeyDown: type == .keyDown,
                flags: event.flags
            ) {
                try? multiplexer.send(frame, reliability: .reliableOrdered)
            }
            return nil

        case .flagsChanged:
            let frame = keyTranslator.handleFlagsChanged(flags: event.flags)
            try? multiplexer.send(frame, reliability: .reliableOrdered)
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Shared Input Packet Emission

    private func syncClipboardIfPasteShortcut(keyCode: UInt16, flags: CGEventFlags) {
        guard keyCode == 0x09, flags.contains(.maskCommand) || flags.contains(.maskControl) else {
            return
        }
        clipboardSyncEngine?.syncLocalPasteboardToAndroidIfNeeded()
    }

    private func emitThrottledPositionUpdate(normX: Double, normY: Double, target: CursorRoutingTarget, force: Bool) {
        let nowUs = MonotonicClock.nowMicroseconds()
        guard force || (nowUs &- lastUiPositionUpdateUs >= 50_000) else { return }
        lastUiPositionUpdateUs = nowUs
        delegate?.edgeEngine(self, didUpdateNormalizedPosition: normX, normY: normY, target: target)
    }

    private func forwardRelativeMouseDelta(rawDx: Double, rawDy: Double) {
        if skipInitialRemoteDeltas > 0 {
            skipInitialRemoteDeltas -= 1
            if abs(rawDx) > 80.0 || abs(rawDy) > 80.0 {
                return
            }
        }

        var clampedDx = rawDx
        var clampedDy = rawDy
        if MonotonicClock.nowMicroseconds() &- lastEntryToAndroidTimestampUs < 160_000 {
            switch activeMacBoundaryEdge {
            case .right:
                clampedDx = max(0.0, clampedDx)
            case .left:
                clampedDx = min(0.0, clampedDx)
            case .bottom:
                clampedDy = max(0.0, clampedDy)
            case .top:
                clampedDy = min(0.0, clampedDy)
            }
        }

        let scaledX = clampedDx * pointerVelocityGain + residualDx
        let scaledY = clampedDy * pointerVelocityGain + residualDy
        let outDx = Int(scaledX.rounded(.towardZero))
        let outDy = Int(scaledY.rounded(.towardZero))
        residualDx = scaledX - Double(outDx)
        residualDy = scaledY - Double(outDy)

        if outDx != 0 || outDy != 0 {
            estAndroidNormX = max(0.0, min(1.0, estAndroidNormX + Double(outDx) / Double(max(1, androidDisplay.widthPx))))
            estAndroidNormY = max(0.0, min(1.0, estAndroidNormY + Double(outDy) / Double(max(1, androidDisplay.heightPx))))
            emitThrottledPositionUpdate(normX: estAndroidNormX, normY: estAndroidNormY, target: .android, force: false)

            do {
                try multiplexer.send(
                    .mouseReport(
                        buttons: heldMacMouseButtons,
                        dx: Int16(clamping: outDx),
                        dy: Int16(clamping: outDy),
                        vWheel: 0,
                        hWheel: 0
                    ),
                    reliability: .unreliableSequenced
                )
            } catch {
                forceReturnToMacOS()
            }
        }
    }

    private func forwardScroll(isContinuous: Bool, ptY: Double, ptX: Double) {
        if ptY * residualVScroll < 0 { residualVScroll = 0 }
        if ptX * residualHScroll < 0 { residualHScroll = 0 }

        let factor = isContinuous ? (1.0 / 1.5) : 16.0
        residualVScroll += ptY * factor
        residualHScroll += ptX * factor

        let vTick = Int(residualVScroll.rounded(.towardZero))
        let hTick = Int(residualHScroll.rounded(.towardZero))
        residualVScroll -= Double(vTick)
        residualHScroll -= Double(hTick)

        if vTick != 0 || hTick != 0 {
            try? multiplexer.send(
                .mouseReport(
                    buttons: heldMacMouseButtons,
                    dx: 0,
                    dy: 0,
                    vWheel: Int8(clamping: vTick),
                    hWheel: Int8(clamping: hTick)
                ),
                reliability: .unreliableSequenced
            )
        }
    }

    private func sendReliableButtonReport() {
        do {
            try multiplexer.send(
                .mouseReport(buttons: heldMacMouseButtons, dx: 0, dy: 0, vWheel: 0, hWheel: 0),
                reliability: .reliableOrdered
            )
        } catch {
            forceReturnToMacOS()
        }
    }
}

private func quartzEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let engine = Unmanaged<QuartzEdgeEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handleQuartzEvent(type: type, event: event)
}
