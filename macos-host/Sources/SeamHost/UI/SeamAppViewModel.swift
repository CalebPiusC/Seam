import AppKit
import Combine
import Foundation

/// Fully automatic session controller: discovers the phone over USB or Wi-Fi, keeps both links alive,
/// starts edge crossing on its own, and publishes the minimal state the menu-bar UI needs.
@MainActor
public final class SeamAppViewModel: ObservableObject, SeamTransportDelegate, QuartzEdgeEngineDelegate {
    public enum ConnectionState: Equatable {
        case searching
        case awaitingApproval
        case connected
    }

    public enum DraggedDevice: Equatable {
        case phone, mac
    }

    @Published public private(set) var connectionState: ConnectionState = .searching
    @Published public var draggedDevice: DraggedDevice? = nil
    @Published public var dragTranslation: CGSize = .zero
    @Published public private(set) var deviceName: String = "Phone"
    @Published public private(set) var activeLink: TransportKind?
    @Published public private(set) var routingTarget: CursorRoutingTarget = .macOS
    @Published public private(set) var hasAccessibilityPermission: Bool =
        QuartzEdgeEngine.checkAccessibilityPermission(promptIfNeeded: false)
    @Published public private(set) var phoneAspectRatio: CGFloat = 720.0 / 1600.0
    @Published public private(set) var cursorNormX: Double = 0.5
    @Published public private(set) var cursorNormY: Double = 0.5

    /// Which side of the Mac the phone sits on. Set by dragging the phone in the arrangement view.
    @Published public var phoneEdge: SeamWireProtocol.ScreenEdge {
        didSet {
            edgeEngine.activeMacBoundaryEdge = phoneEdge
            UserDefaults.standard.set(Int(phoneEdge.rawValue), forKey: Self.phoneEdgeDefaultsKey)
        }
    }

    public var isConnected: Bool { connectionState == .connected }

    /// Invoked whenever state that affects the menu-bar icon changes.
    public var onStatusChange: (() -> Void)?

    public let multiplexer = SeamTransportMultiplexer()
    public lazy var edgeEngine = QuartzEdgeEngine(multiplexer: multiplexer)
    public lazy var clipboardSyncEngine = MacClipboardSyncEngine(multiplexer: multiplexer)

    private static let phoneEdgeDefaultsKey = "seam.phoneEdge"

    private let bootstrapper: UsbBootstrapper
    private var agentProcess: Process?
    private var activeSerial: String?
    private var usbTransport: UsbAdbTransport?
    private var wifiTransport: WifiHybridTransport?
    private var lastKnownWifiIp: String = UsbBootstrapper.loadLastWifiIp() ?? ""
    private var isBootstrapping = false
    private var isEdgeCrossingActive = false

    private var autoPilotTimer: DispatchSourceTimer?
    private var isTickRunning = false
    private var tickCounter = 0

    public init(bootstrapper: UsbBootstrapper) {
        self.bootstrapper = bootstrapper
        let stored = UserDefaults.standard.object(forKey: Self.phoneEdgeDefaultsKey) as? Int
        self.phoneEdge = stored.flatMap { SeamWireProtocol.ScreenEdge(rawValue: UInt8($0)) } ?? .right

        multiplexer.delegate = self
        edgeEngine.delegate = self
        edgeEngine.activeMacBoundaryEdge = phoneEdge
        edgeEngine.clipboardSyncEngine = clipboardSyncEngine
        clipboardSyncEngine.start()
        startAutoPilot()
    }

    public func openAccessibilitySettings() {
        hasAccessibilityPermission = QuartzEdgeEngine.checkAccessibilityPermission(promptIfNeeded: true)
        if !hasAccessibilityPermission,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func shutdown() {
        stopEdgeCrossing()
        multiplexer.disconnectAll(reason: "SEAM quit")
        if let serial = activeSerial {
            bootstrapper.teardownSession(serial: serial, agentProcess: agentProcess, stopRemoteDaemon: false)
        }
    }

    // MARK: - Auto-Pilot

    private func startAutoPilot() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(1500))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.runAutoPilotTick() }
        }
        autoPilotTimer = timer
        timer.resume()
    }

    private func runAutoPilotTick() {
        refreshAccessibilityPermission()
        guard !isBootstrapping, !isTickRunning else { return }
        isTickRunning = true
        tickCounter &+= 1

        let tick = tickCounter
        let connected = isConnected
        let hasUsb = usbTransport != nil
        let hasWifi = wifiTransport != nil
        let serial = activeSerial
        let wifiHint = lastKnownWifiIp
        let boot = bootstrapper
        let mux = multiplexer

        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { Task { @MainActor [weak self] in self?.isTickRunning = false } }

            if !connected {
                // 1. A detached agent already listening on Wi-Fi (cable-free reconnect)
                if let target = boot.discoverRunningWirelessAgent(customHostIp: wifiHint).first {
                    let wifi = WifiHybridTransport()
                    if (try? mux.addAndConnectTransport(
                        wifi, endpoint: target.seamEndpoint,
                        authenticator: SeamAuthenticator.loadOrCreatePersistentKey(),
                        makePrimary: true
                    )) != nil {
                        Task { @MainActor [weak self] in
                            self?.wifiTransport = wifi
                            self?.rememberWifi(target.ipv4Address)
                            self?.markConnected(name: nil)
                        }
                        return
                    }
                }

                // 2. ADB over USB or Wireless Debugging (mDNS probed every ~4.5 s)
                var devices = (try? boot.listDevices()) ?? []
                if devices.isEmpty && tick % 3 == 1, !boot.discoverAndConnectWirelessAdbMdns().isEmpty {
                    devices = (try? boot.listDevices()) ?? []
                }
                if devices.contains(where: { $0.state == "unauthorized" }) {
                    Task { @MainActor [weak self] in self?.setState(.awaitingApproval) }
                    return
                }
                if devices.contains(where: \.isAuthorized) {
                    Task { @MainActor [weak self] in self?.bootstrapOverAdb() }
                } else {
                    Task { @MainActor [weak self] in self?.setState(.searching) }
                }
                return
            }

            // Connected over Wi-Fi only: upgrade to USB as soon as a cable appears
            if !hasUsb,
               let usbDevice = ((try? boot.listDevices()) ?? []).first(where: { !$0.isWirelessAdb && $0.isAuthorized }),
               let endpoint = try? boot.setupUsbForwardOnly(serial: usbDevice.serial) {
                let usb = UsbAdbTransport()
                if (try? mux.addAndConnectTransport(
                    usb, endpoint: endpoint,
                    authenticator: SeamAuthenticator.loadOrCreatePersistentKey(),
                    makePrimary: true
                )) != nil {
                    Task { @MainActor [weak self] in
                        self?.usbTransport = usb
                        self?.activeSerial = usbDevice.serial
                        self?.markConnected(name: usbDevice.model)
                    }
                    return
                }
            }

            // Connected over USB only: attach Wi-Fi as a hot standby when it becomes reachable
            if !hasWifi && tick % 3 == 0 {
                var target = boot.discoverRunningWirelessAgent(customHostIp: wifiHint).first
                if target == nil, let serial {
                    target = boot.queryWifiEndpointsFromDaemonLog(serial: serial).first
                }
                if let target {
                    let wifi = WifiHybridTransport()
                    if (try? mux.addAndConnectTransport(
                        wifi, endpoint: target.seamEndpoint,
                        authenticator: SeamAuthenticator.loadOrCreatePersistentKey(),
                        makePrimary: false
                    )) != nil {
                        Task { @MainActor [weak self] in
                            self?.wifiTransport = wifi
                            self?.rememberWifi(target.ipv4Address)
                            self?.refreshActiveLink()
                        }
                    }
                }
            }
        }
    }

    private func bootstrapOverAdb() {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        let boot = bootstrapper
        let mux = multiplexer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let (device, usbEndpoint, wifiEndpoints, auth, proc) = try boot.bootstrapSession(detachDaemon: true)
                let usb = UsbAdbTransport()
                try mux.addAndConnectTransport(usb, endpoint: usbEndpoint, authenticator: auth,
                                               makePrimary: !device.isWirelessAdb)

                var wifi: WifiHybridTransport?
                if let target = wifiEndpoints.first {
                    let candidate = WifiHybridTransport()
                    if (try? mux.addAndConnectTransport(candidate, endpoint: target.seamEndpoint,
                                                        authenticator: auth,
                                                        makePrimary: device.isWirelessAdb)) != nil {
                        wifi = candidate
                    }
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.agentProcess = proc
                    self.activeSerial = device.serial
                    self.usbTransport = usb
                    self.wifiTransport = wifi
                    if let ip = wifiEndpoints.first?.ipv4Address, wifi != nil { self.rememberWifi(ip) }
                    self.isBootstrapping = false
                    self.markConnected(name: device.model)
                }
            } catch {
                Task { @MainActor [weak self] in self?.isBootstrapping = false }
            }
        }
    }

    // MARK: - State helpers

    private func markConnected(name: String?) {
        if let name { deviceName = name.replacingOccurrences(of: "_", with: " ") }
        setState(.connected)
        refreshActiveLink()
        clipboardSyncEngine.syncLocalPasteboardToAndroidIfNeeded(force: true)
        startEdgeCrossingIfNeeded()
    }

    private func setState(_ state: ConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        onStatusChange?()
    }

    private func refreshActiveLink() {
        let kind = multiplexer.activePrimaryKind
        if activeLink != kind {
            activeLink = kind
            onStatusChange?()
        }
    }

    private func rememberWifi(_ ip: String) {
        lastKnownWifiIp = ip
        UsbBootstrapper.saveLastWifiIp(ip)
    }

    private func refreshAccessibilityPermission() {
        let granted = QuartzEdgeEngine.checkAccessibilityPermission(promptIfNeeded: false)
        guard granted != hasAccessibilityPermission else { return }
        hasAccessibilityPermission = granted
        // Upgrade to the global event tap automatically once permission is granted.
        if granted, isEdgeCrossingActive, !edgeEngine.isUsingEventTap, routingTarget == .macOS {
            stopEdgeCrossing()
            startEdgeCrossingIfNeeded()
        }
    }

    private func startEdgeCrossingIfNeeded() {
        guard isConnected, !isEdgeCrossingActive else { return }
        edgeEngine.activeMacBoundaryEdge = phoneEdge
        if (try? edgeEngine.start()) != nil {
            isEdgeCrossingActive = true
        }
    }

    private func stopEdgeCrossing() {
        guard isEdgeCrossingActive else { return }
        edgeEngine.stop()
        isEdgeCrossingActive = false
        routingTarget = .macOS
    }

    // MARK: - SeamTransportDelegate

    nonisolated public func transport(_ transport: any SeamTransport, didChangeState state: TransportState) {
        guard case .closed = state else { return }
        let kind = transport.kind
        Task { @MainActor [weak self] in
            guard let self else { return }
            if kind == .usbAdb { self.usbTransport = nil } else { self.wifiTransport = nil }
            self.refreshActiveLink()
            if self.multiplexer.activePrimaryKind == nil {
                if self.routingTarget == .android { self.edgeEngine.forceReturnToMacOS() }
                self.stopEdgeCrossing()
                self.setState(.searching)
            }
        }
    }

    nonisolated public func transport(_ transport: any SeamTransport, didReceiveFrame frame: SeamInboundFrame) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch frame {
            case let .displayInfo(info):
                self.edgeEngine.updateAndroidDisplay(info)
                let rotated = info.rotationDegrees == 90 || info.rotationDegrees == 270
                let w = CGFloat(max(1, info.widthPx)), h = CGFloat(max(1, info.heightPx))
                self.phoneAspectRatio = rotated ? max(w, h) / min(w, h) : w / h
            case let .edgeReturn(event):
                self.edgeEngine.handleAndroidEdgeReturn(event)
            case let .clipboardEvent(text):
                self.clipboardSyncEngine.applyRemoteClipboardFromAndroid(text)
            case .pong:
                break
            }
        }
    }

    nonisolated public func transport(_ transport: any SeamTransport, didMeasureRttMicroseconds rttUs: UInt64) {}

    // MARK: - QuartzEdgeEngineDelegate

    nonisolated public func edgeEngine(_ engine: QuartzEdgeEngine, didSwitchTarget target: CursorRoutingTarget) {
        Task { @MainActor [weak self] in
            guard let self, self.routingTarget != target else { return }
            self.routingTarget = target
            self.onStatusChange?()
        }
    }

    nonisolated public func edgeEngine(
        _ engine: QuartzEdgeEngine,
        didUpdateNormalizedPosition normX: Double,
        normY: Double,
        target: CursorRoutingTarget
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cursorNormX = normX
            self.cursorNormY = normY
        }
    }
}
