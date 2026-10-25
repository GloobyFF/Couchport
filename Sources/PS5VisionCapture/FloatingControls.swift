#if os(iOS) || os(tvOS)
import SwiftUI

#if os(iOS)
/// iPhone / iPad / iPhone Duo player controls: one floating button the user
/// can drag anywhere (it snaps to the nearest of the four edges and remembers its
/// spot). Tapping it opens a panel of large, labelled actions. Same in every
/// pose, so nothing pops over the picture or the water reflection.
struct FloatingPlayerControls: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: RemotePlaySettings
    let onOpen: (PlayerPanel) -> Void

    /// Normalised position (0...1) inside the player, persisted.
    @AppStorage("rp.fab.x") private var posX: Double = 1.0
    @AppStorage("rp.fab.y") private var posY: Double = 0.18
    @State private var drag: CGSize = .zero
    @State private var isDragging = false
    @State private var expanded = false

    private let buttonSize: CGFloat = 54
    private let edgeInset: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let area = geo.size
            ZStack(alignment: .topLeading) {
                if expanded {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .transition(.opacity)

                    PlayerControlsPanel(app: app, settings: settings, onOpen: onOpen, onClose: close)
                        .frame(maxWidth: min(area.width - 24, 440))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                floatingButton
                    .position(buttonCenter(in: area))
                    .gesture(dragGesture(in: area))
                    .opacity(expanded ? 0 : (isDragging ? 1 : 0.85))
                    .allowsHitTesting(!expanded)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
    }

    // MARK: Button

    private var floatingButton: some View {
        ZStack(alignment: .topTrailing) {
            // Our own round app mark.
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: buttonSize, height: buttonSize)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)

            if let left = app.freeSecondsLeft {
                Text(FreeTimeChip.format(left))
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((left <= Int(FreeTier.warningLead) ? Color.orange : Brand.blue), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: 10, y: -6)
            }
        }
        .contentShape(Circle())
        .onTapGesture { expanded = true }
        .accessibilityLabel(Text("Controls"))
        .accessibilityAddTraits(.isButton)
    }

    private func buttonCenter(in area: CGSize) -> CGPoint {
        let half = buttonSize / 2 + edgeInset
        let x = clamp(posX * area.width + drag.width, half, area.width - half)
        let y = clamp(posY * area.height + drag.height, half, area.height - half)
        return CGPoint(x: x, y: y)
    }

    private func dragGesture(in area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                isDragging = true
                drag = value.translation
            }
            .onEnded { value in
                guard area.width > 0, area.height > 0 else { return }
                let y = posY + value.translation.height / area.height
                let x = posX + value.translation.width / area.width
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    // Snap to the nearest of the four edges (top centre
                    // included) so it never sits mid-picture; it slides
                    // freely along that edge.
                    let cx = clamp(x, 0, 1), cy = clamp(y, 0, 1)
                    let dLeft = cx * area.width, dRight = (1 - cx) * area.width
                    let dTop = cy * area.height, dBottom = (1 - cy) * area.height
                    switch min(dLeft, dRight, dTop, dBottom) {
                    case dLeft: posX = 0; posY = cy
                    case dRight: posX = 1; posY = cy
                    case dTop: posX = cx; posY = 0
                    default: posX = cx; posY = 1
                    }
                    drag = .zero
                    isDragging = false
                }
            }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), max(lo, hi)) }

    private func close() { expanded = false }
}
#endif

/// The player's controls as one panel of large, labelled tiles. iPhone / iPad
/// open it from the floating button; Apple TV opens it with the Siri Remote's
/// Menu or Play/Pause button, where every tile is a focusable card button.
struct PlayerControlsPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: RemotePlaySettings
    let onOpen: (PlayerPanel) -> Void
    let onClose: () -> Void
    /// Apple TV: show the L3 + R3 hint (shown until the panel was seen once).
    var showPSComboHint = false

    private var isTV: Bool { Platform.isTV }
    private var tileHeight: CGFloat { isTV ? 150 : 84 }
    private var iconSize: CGFloat { isTV ? 38 : 24 }
    private var columns: Int { isTV ? 4 : 3 }

    private func run(_ action: () -> Void) {
        action()
        onClose()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isTV ? 24 : 14) {
            HStack(spacing: 10) {
                Label(app.sourceTitle, systemImage: app.sourceIcon)
                    .font(isTV ? .title3.weight(.semibold) : .headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let left = app.freeSecondsLeft { FreeTimeChip(secondsLeft: left) }
                #if os(iOS)
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
                #endif
            }
            Text(verbatim: "\(app.formatText) · \(app.rateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isTV ? 24 : 10), count: columns),
                      spacing: isTV ? 24 : 10) {
                if app.activeSource == .remote {
                    tile("PS Button", "button.programmable") { run { app.remote.pressPSButton() } }
                    tile("Stream", "dial.medium") { run { onOpen(.stream) } }
                }
                tile("Enhance", "wand.and.stars") { run { onOpen(.enhance) } }
                tile("Performance Stats", "chart.xyaxis.line") { run { onOpen(.stats) } }
                #if os(iOS)
                if app.activeSource == .remote && settings.pictureInPicture {
                    tile("Picture in Picture", "pip.enter") {
                        run { NotificationCenter.default.post(name: .couchportStartPictureInPicture, object: nil) }
                    }
                }
                if app.activeSource == .remote {
                    toggleTile("Reflection", "square.bottomhalf.filled", isOn: settings.tabletopReflection) {
                        settings.tabletopReflection.toggle()
                    }
                    if settings.tabletopReflection {
                        toggleTile("Water Ripples", "water.waves", isOn: settings.waterRipples) {
                            settings.waterRipples.toggle()
                        }
                    }
                }
                #endif
                if app.activeSource == .remote {
                    tile("Rest Mode", "moon.zzz") { run { app.remote.putConsoleToSleep() } }
                }
            }

            #if os(iOS)
            if app.activeSource == .remote {
                VStack(alignment: .leading, spacing: 6) {
                    Label("On-Screen Controller", systemImage: "gamecontroller")
                        .font(.subheadline.weight(.semibold))
                    Picker("On-Screen Controller", selection: $settings.touchControls) {
                        ForEach(TouchControlsMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Detected controller: \(app.remote.gamepad.controllerName ?? String(localized: "None"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #else
            VStack(alignment: .leading, spacing: 8) {
                if showPSComboHint && app.activeSource == .remote {
                    Label("Hold L3 + R3 for the PS button", systemImage: "button.programmable")
                        .font(.callout.weight(.semibold))
                }
                Text("Detected controller: \(app.remote.gamepad.controllerName ?? String(localized: "None"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Press Menu to return to the game.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Button(role: .destructive) {
                run { app.stopAndGoHome() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: isTV ? 60 : 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(isTV ? 40 : 18)
        // Plain system glass inside the card's outline: no pattern.
        .modifier(SystemGlassCard(cornerRadius: isTV ? 40 : 26))
        .overlay(RoundedRectangle(cornerRadius: isTV ? 40 : 26, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            .allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .padding(12)
    }

    private func tileLabel(_ title: LocalizedStringKey, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .frame(height: iconSize + 4)
            Text(title)
                .font(isTV ? .callout.weight(.medium) : .footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: tileHeight)
        .padding(.horizontal, 4)
    }

    private func tile(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tileLabel(title, icon)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .plainOrCardButtonStyle()
    }

    private func toggleTile(_ title: LocalizedStringKey, _ icon: String, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tileLabel(title, icon)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Brand.blue.opacity(0.85) : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .plainOrCardButtonStyle()
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}
/// System Liquid Glass (deployment target is iOS 26 / tvOS 26).
private struct SystemGlassCard: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.glassEffect(.regular, in: shape)
    }
}
#endif
