#if os(iOS)
import SwiftUI

/// iPhone / iPad / iPhone Duo player controls: one floating button the user
/// can drag anywhere (it snaps to the nearest side edge and remembers its
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

                    menu
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
                    // Snap to the closer side so it never sits mid-picture.
                    posX = x < 0.5 ? 0 : 1
                    posY = clamp(y, 0, 1)
                    drag = .zero
                    isDragging = false
                }
            }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), max(lo, hi)) }

    private func close() { expanded = false }

    private func run(_ action: () -> Void) {
        action()
        close()
    }

    // MARK: Menu

    private var menu: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(app.sourceTitle, systemImage: app.sourceIcon)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let left = app.freeSecondsLeft { FreeTimeChip(secondsLeft: left) }
                Button { close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            Text(verbatim: "\(app.formatText) · \(app.rateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                if app.activeSource == .remote {
                    tile("PS Button", "button.programmable") { run { app.remote.pressPSButton() } }
                    tile("Stream", "dial.medium") { run { onOpen(.stream) } }
                }
                tile("Enhance", "wand.and.stars") { run { onOpen(.enhance) } }
                tile("Performance Stats", "chart.xyaxis.line") { run { onOpen(.stats) } }
                if app.activeSource == .remote && settings.pictureInPicture {
                    tile("Picture in Picture", "pip.enter") {
                        run { NotificationCenter.default.post(name: .couchportStartPictureInPicture, object: nil) }
                    }
                }
                if app.activeSource == .remote {
                    toggleTile("Tabletop Reflection", "square.bottomhalf.filled", isOn: settings.tabletopReflection) {
                        settings.tabletopReflection.toggle()
                    }
                    if settings.tabletopReflection {
                        toggleTile("Water Ripples", "water.waves", isOn: settings.waterRipples) {
                            settings.waterRipples.toggle()
                        }
                    }
                    tile("Rest Mode", "moon.zzz") { run { app.remote.putConsoleToSleep() } }
                }
            }

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

            Button(role: .destructive) {
                run { app.stopAndGoHome() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(18)
        // Plain system glass inside the card's outline: no pattern.
        .modifier(SystemGlassCard(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .padding(12)
    }

    private func tile(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .frame(height: 28)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(.horizontal, 4)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggleTile(_ title: LocalizedStringKey, _ icon: String, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .frame(height: 28)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(.horizontal, 4)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? Brand.blue.opacity(0.85) : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}
/// System Liquid Glass (deployment target is iOS 26).
private struct SystemGlassCard: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.glassEffect(.regular, in: shape)
    }
}
#endif
