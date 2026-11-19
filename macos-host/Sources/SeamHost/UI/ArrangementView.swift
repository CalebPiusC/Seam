import SwiftUI

/// Displays-style arrangement: drag either device around the other to match where they physically sit.
struct ArrangementView: View {
    @ObservedObject var model: SeamAppViewModel

    private let macSize = CGSize(width: 132, height: 84)
    private let gap: CGFloat = 8
    private let canvasHeight: CGFloat = 196

    private func phoneSize(for edge: SeamWireProtocol.ScreenEdge) -> CGSize {
        let longSide: CGFloat = 74
        let shortSide = max(
            32,
            min(42, longSide * min(model.phoneAspectRatio, 1.0 / max(0.35, model.phoneAspectRatio)))
        )
        switch edge {
        case .left, .right:
            return CGSize(width: shortSide, height: longSide)
        case .top, .bottom:
            return CGSize(width: longSide, height: shortSide)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let layout = layout(for: model.phoneEdge)
            let candidate = model.draggedDevice.map { snapEdge(for: layout, dragging: $0) }
            let previewEdge = candidate ?? model.phoneEdge
            let isMacDragged = model.draggedDevice == .mac
            let isPhoneDragged = model.draggedDevice == .phone
            let macOffset = isMacDragged ? model.dragTranslation : .zero
            let phoneOffset = isPhoneDragged ? model.dragTranslation : .zero

            SeamGlassGroup(spacing: 14) {
                ZStack {
                    macTile(highlightEdge: candidate)
                        .scaleEffect(isMacDragged ? 1.06 : 1)
                        .shadow(color: .black.opacity(isMacDragged ? 0.25 : 0), radius: 10, y: 4)
                        .zIndex(isMacDragged ? 1 : 0)
                        .position(
                            x: center.x + layout.mac.x + macOffset.width,
                            y: center.y + layout.mac.y + macOffset.height
                        )
                        .gesture(dragGesture(for: .mac, layout: layout))

                    phoneTile(for: previewEdge)
                        .scaleEffect(isPhoneDragged ? 1.06 : 1)
                        .shadow(color: .black.opacity(isPhoneDragged ? 0.25 : 0), radius: 10, y: 4)
                        .zIndex(isPhoneDragged ? 1 : 0)
                        .position(
                            x: center.x + layout.phone.x + phoneOffset.width,
                            y: center.y + layout.phone.y + phoneOffset.height
                        )
                        .gesture(dragGesture(for: .phone, layout: layout))
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: previewEdge)
                }
            }
        }
        .frame(height: canvasHeight)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.phoneEdge)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.routingTarget)
    }

    // MARK: - Tiles

    private func macTile(highlightEdge: SeamWireProtocol.ScreenEdge?) -> some View {
        let active = model.routingTarget == .macOS
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            VStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22, weight: .regular))
                Text("This Mac")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(active ? .primary : .secondary)

            if active { cursorDot }
        }
        .frame(width: macSize.width, height: macSize.height)
        .seamGlass(in: shape, tint: active ? .accentColor.opacity(0.35) : nil, interactive: true)
        .contentShape(shape)
        .help("Drag to rearrange relative to your phone")
        .overlay(alignment: alignment(for: highlightEdge)) {
            if let edge = highlightEdge {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: edge == .left || edge == .right ? 3 : macSize.width * 0.55,
                        height: edge == .left || edge == .right ? macSize.height * 0.55 : 3
                    )
                    .padding(2)
                    .transition(.opacity)
            }
        }
    }

    private func phoneTile(for edge: SeamWireProtocol.ScreenEdge) -> some View {
        let active = model.routingTarget == .android
        let isHorizontal = edge == .top || edge == .bottom
        let size = phoneSize(for: edge)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            Image(systemName: "smartphone")
                .font(.system(size: 15, weight: .regular))
                .rotationEffect(.degrees(isHorizontal ? -90 : 0))
                .foregroundStyle(active ? .primary : .secondary)
            if active { cursorDot }
        }
        .frame(width: size.width, height: size.height)
        .seamGlass(in: shape, tint: active ? .accentColor.opacity(0.35) : nil, interactive: true)
        .opacity(model.isConnected ? 1 : 0.5)
        .contentShape(shape)
        .help("Drag to the side of your Mac where your phone sits")
    }

    private var cursorDot: some View {
        GeometryReader { geo in
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
                .shadow(color: .black.opacity(0.35), radius: 2)
                .position(
                    x: min(max(4, geo.size.width * model.cursorNormX), geo.size.width - 4),
                    y: min(max(4, geo.size.height * model.cursorNormY), geo.size.height - 4)
                )
                .animation(.linear(duration: 0.05), value: model.cursorNormX)
                .animation(.linear(duration: 0.05), value: model.cursorNormY)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dragging

    private func dragGesture(for device: SeamAppViewModel.DraggedDevice, layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if model.draggedDevice != device {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        model.draggedDevice = device
                    }
                }
                model.dragTranslation = value.translation
            }
            .onEnded { _ in
                let edge = snapEdge(for: layout, dragging: device)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    model.phoneEdge = edge
                    model.dragTranslation = .zero
                    model.draggedDevice = nil
                }
            }
    }

    /// Picks the Mac edge closest to the phone's dragged position, normalized by tile size.
    private func snapEdge(for layout: Layout, dragging device: SeamAppViewModel.DraggedDevice) -> SeamWireProtocol.ScreenEdge {
        let relX: CGFloat
        let relY: CGFloat
        switch device {
        case .phone:
            relX = (layout.phone.x + model.dragTranslation.width) - layout.mac.x
            relY = (layout.phone.y + model.dragTranslation.height) - layout.mac.y
        case .mac:
            relX = layout.phone.x - (layout.mac.x + model.dragTranslation.width)
            relY = layout.phone.y - (layout.mac.y + model.dragTranslation.height)
        }
        let reachX = macSize.width / 2 + phoneSize(for: .right).width / 2
        let reachY = macSize.height / 2 + phoneSize(for: .bottom).height / 2
        if abs(relX) / reachX >= abs(relY) / reachY {
            return relX >= 0 ? .right : .left
        }
        return relY >= 0 ? .bottom : .top
    }

    // MARK: - Layout

    private struct Layout {
        let mac: CGPoint
        let phone: CGPoint
    }

    /// Centers the Mac + phone group in the canvas with the phone attached to `edge`.
    private func layout(for edge: SeamWireProtocol.ScreenEdge) -> Layout {
        let pSize = phoneSize(for: edge)
        switch edge {
        case .right, .left:
            let total = macSize.width + gap + pSize.width
            let macX = -total / 2 + macSize.width / 2
            let phoneX = total / 2 - pSize.width / 2
            return edge == .right
                ? Layout(mac: CGPoint(x: macX, y: 0), phone: CGPoint(x: phoneX, y: 0))
                : Layout(mac: CGPoint(x: -macX, y: 0), phone: CGPoint(x: -phoneX, y: 0))
        case .bottom, .top:
            let total = macSize.height + gap + pSize.height
            let macY = -total / 2 + macSize.height / 2
            let phoneY = total / 2 - pSize.height / 2
            return edge == .bottom
                ? Layout(mac: CGPoint(x: 0, y: macY), phone: CGPoint(x: 0, y: phoneY))
                : Layout(mac: CGPoint(x: 0, y: -macY), phone: CGPoint(x: 0, y: -phoneY))
        }
    }

    private func alignment(for edge: SeamWireProtocol.ScreenEdge?) -> Alignment {
        switch edge {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case .none: return .center
        }
    }
}
