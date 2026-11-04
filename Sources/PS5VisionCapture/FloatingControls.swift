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
    #if os(tvOS)
    /// Apple TV: the focused tile (focus starts on the first one).
    @FocusState private var focusedTile: String?
    #endif

    private var isTV: Bool { Platform.isTV }
    private var columns: Int { 4 }

    private func run(_ action: () -> Void) {
        action()
        onClose()
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
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

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
                      alignment: .center, spacing: 14) {
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
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.red, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        // Plain system glass inside the card's outline: no pattern.
        .modifier(SystemGlassCard(cornerRadius: 34))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            .allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .padding(12)
        #endif
    }

    // Same look as the visionOS dock: a circular icon with a caption below.
    private func tile(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        DockButton(title: title, icon: icon, psGlyph: icon == "button.programmable",
                   size: .compact, action: action)
    }

    private func toggleTile(_ title: LocalizedStringKey, _ icon: String, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        DockButton(title: title, icon: icon, isOn: isOn, size: .compact, action: action)
    }
}
#if os(tvOS)
// MARK: - Apple TV layout

/// One tile of the TV panel.
private struct TVPanelTile: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void
}

extension PlayerControlsPanel {
    /// Large card tiles in a centred grid; focus starts on the first tile.
    var tvBody: some View {
        let tiles = tvTiles
        let columnCount = min(max(tiles.count, 1), 5)
        return VStack(spacing: 40) {
            VStack(spacing: 10) {
                HStack(spacing: 24) {
                    Label(app.sourceTitle, systemImage: app.sourceIcon)
                        .font(TVMetrics.sectionTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let left = app.freeSecondsLeft { FreeTimeChip(secondsLeft: left) }
                }
                Text(verbatim: "\(app.formatText) · \(app.rateText)")
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVPanelMetrics.tileWidth),
                                                         spacing: TVPanelMetrics.spacing),
                                     count: columnCount),
                      spacing: TVPanelMetrics.spacing) {
                ForEach(tiles) { tile in
                    Button {
                        run(tile.action)
                    } label: {
                        tvTileLabel(tile.title, tile.icon)
                    }
                    .buttonStyle(.card)
                    .focused($focusedTile, equals: tile.id)
                }
            }
            .focusSection()

            VStack(spacing: 8) {
                if showPSComboHint && app.activeSource == .remote {
                    Label("Hold L3 + R3 for the PS button", systemImage: "button.programmable")
                        .font(TVMetrics.body.weight(.semibold))
                }
                Text("Detected controller: \(app.remote.gamepad.controllerName ?? String(localized: "None"))")
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
                Text("Press Menu to return to the game.")
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 1400)

            Button(role: .destructive) {
                run { app.stopAndGoHome() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(TVMetrics.body.weight(.semibold))
                    .frame(minWidth: 300)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .focusSection()
        }
        .padding(56)
        .modifier(SystemGlassCard(cornerRadius: 48))
        .overlay(RoundedRectangle(cornerRadius: 48, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            .allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .defaultFocus($focusedTile, tiles.first?.id)
        .onAppear {
            let first = tiles.first?.id
            // Once the tiles are in the hierarchy, so the focus engine takes it.
            Task { @MainActor in focusedTile = first }
        }
    }

    private var tvTiles: [TVPanelTile] {
        var tiles: [TVPanelTile] = []
        if app.activeSource == .remote {
            tiles.append(TVPanelTile(id: "ps", title: "PS Button", icon: "button.programmable") { app.remote.pressPSButton() })
            tiles.append(TVPanelTile(id: "stream", title: "Stream", icon: "dial.medium") { onOpen(.stream) })
        }
        tiles.append(TVPanelTile(id: "enhance", title: "Enhance", icon: "wand.and.stars") { onOpen(.enhance) })
        tiles.append(TVPanelTile(id: "stats", title: "Performance Stats", icon: "chart.xyaxis.line") { onOpen(.stats) })
        if app.activeSource == .remote {
            tiles.append(TVPanelTile(id: "rest", title: "Rest Mode", icon: "moon.zzz") { app.remote.putConsoleToSleep() })
        }
        return tiles
    }

    private func tvTileLabel(_ title: LocalizedStringKey, _ icon: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 56, weight: .medium))
                .frame(height: 64)
            Text(title)
                .font(TVMetrics.body.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .frame(width: TVPanelMetrics.tileWidth, height: TVPanelMetrics.tileHeight)
    }
}

private enum TVPanelMetrics {
    static let tileWidth: CGFloat = 280
    static let tileHeight: CGFloat = 210
    static let spacing: CGFloat = 40
}
#endif

/// System Liquid Glass (deployment target is iOS 26 / tvOS 26).
private struct SystemGlassCard: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.glassEffect(.regular, in: shape)
    }
}
#endif
