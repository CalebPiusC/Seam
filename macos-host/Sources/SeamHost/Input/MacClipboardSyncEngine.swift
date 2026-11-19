import AppKit
import Foundation

/// Synchronizes `NSPasteboard.general` plain-text changes bidirectionally between macOS and
/// Android across the active SEAM transport with echo suppression.
public final class MacClipboardSyncEngine {
    private let multiplexer: SeamTransportMultiplexer
    private let lock = NSLock()
    private var pollTimer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var lastSyncedText: String = ""

    public init(multiplexer: SeamTransportMultiplexer) {
        self.multiplexer = multiplexer
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    deinit {
        stop()
    }

    /// Starts the `250 ms` local pasteboard observer timer on the main queue.
    public func start() {
        lock.lock()
        guard pollTimer == nil else {
            lock.unlock()
            return
        }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.syncLocalPasteboardToAndroidIfNeeded(force: false)
        }
        self.pollTimer = timer
        lock.unlock()
        timer.resume()
    }

    public func stop() {
        lock.lock()
        let timer = pollTimer
        pollTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    /// Reads `NSPasteboard.general` if `changeCount` changed (or `force == true`) and sends
    /// `OP_CLIPBOARD_SET` reliably to Android when non-empty text differs from the last sync.
    public func syncLocalPasteboardToAndroidIfNeeded(force: Bool = false) {
        let currentCount = NSPasteboard.general.changeCount

        lock.lock()
        guard force || currentCount != lastChangeCount else {
            lock.unlock()
            return
        }
        lastChangeCount = currentCount
        lock.unlock()

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }

        lock.lock()
        guard force || text != lastSyncedText else {
            lock.unlock()
            return
        }
        lastSyncedText = text
        lock.unlock()

        try? multiplexer.send(.clipboardSet(text: text), reliability: .reliableOrdered)
    }

    /// Applies clipboard text pushed from Android onto `NSPasteboard.general` without echoing it back.
    public func applyRemoteClipboardFromAndroid(_ text: String) {
        guard !text.isEmpty else { return }

        lock.lock()
        lastSyncedText = text
        lock.unlock()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        lock.lock()
        lastChangeCount = pasteboard.changeCount
        lock.unlock()
    }
}
