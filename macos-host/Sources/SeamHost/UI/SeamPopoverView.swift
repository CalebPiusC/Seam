import SwiftUI

/// The single SEAM surface: a compact menu-bar popover.
struct SeamPopoverView: View {
    @ObservedObject var model: SeamAppViewModel
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ArrangementView(model: model)
            Text("Drag your phone to the side of your Mac where it sits.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.2), value: model.connectionState)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.isConnected ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .seamGlass(in: Circle())
                .symbolEffect(.pulse, isActive: model.connectionState == .searching)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .seamGlassButtonStyle()
            .buttonBorderShape(.circle)
            .help("Quit SEAM")
        }
    }

    private var statusSymbol: String {
        switch model.connectionState {
        case .searching: return "antenna.radiowaves.left.and.right"
        case .awaitingApproval: return "hand.raised"
        case .connected: return model.activeLink == .usbAdb ? "cable.connector" : "wifi"
        }
    }

    private var title: String {
        model.isConnected ? model.deviceName : "SEAM"
    }

    private var subtitle: String {
        switch model.connectionState {
        case .searching:
            return "Looking for your phone…"
        case .awaitingApproval:
            return "Tap Allow on your phone to continue"
        case .connected:
            if model.routingTarget == .android { return "Using your phone" }
            return model.activeLink == .usbAdb ? "Connected with USB" : "Connected over Wi-Fi"
        }
    }
}
