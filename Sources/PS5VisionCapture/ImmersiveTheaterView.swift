#if os(visionOS)
import SwiftUI
import RealityKit
import GameController

/// Immersive theater with a large, movable control bar below the screen.
struct ImmersiveTheaterView: View {
    @EnvironmentObject private var captureManager: CaptureManager
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var purchases = PurchaseManager.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var theater: TheaterScene?
    @State private var controlsPosition = Self.defaultControlsPosition
    @State private var isExiting = false

    // The attachment reserves vertical layout space above the toolbar for its
    // inline panel. This centre position keeps the visible toolbar at ~0.45 m.
    private static let defaultControlsPosition = SIMD3<Float>(0, 0.72, -1.25)

    var body: some View {
        RealityView { content, attachments in
            let scene = TheaterScene(renderer: captureManager.metalRenderer,
                                     options: captureManager.renderOptions)
            content.add(scene.root)
            scene.activate(content: content)
            theater = scene

            if let controls = attachments.entity(for: "controls") {
                controls.name = "controls"
                // Fixed in space (no billboard): the bar stays where it was
                // placed instead of turning with the head.
                controls.position = controlsPosition
                // Lean the top back 30° so the bar, which sits below eye
                // level, faces up toward the viewer.
                controls.orientation = simd_quatf(angle: -.pi / 6, axis: [1, 0, 0])
                content.add(controls)
            }
        } update: { _, attachments in
            attachments.entity(for: "controls")?.position = controlsPosition
        } attachments: {
            Attachment(id: "controls") {
                FloatingTheaterControls(
                    app: app,
                    captureManager: captureManager,
                    renderOptions: captureManager.renderOptions,
                    position: $controlsPosition,
                    defaultPosition: Self.defaultControlsPosition,
                    onExit: exitTheater
                )
                .gamepadInputOnly()
            }
        }
        .gamepadInputOnly()
        .upperLimbVisibility(app.theaterHideHands ? .hidden : .visible)
        .onAppear {
            captureManager.immersiveOpen = true
        }
        // The paywall lives in the main window: leave the theater to show it
        // (free time ran out, or a Pro row was tapped here).
        .onChange(of: purchases.paywallRequest != nil) { _, requested in
            if requested { Task { await exitTheater() } }
        }
        .onDisappear {
            theater?.deactivate()
            theater = nil
            captureManager.immersiveOpen = false
            if captureManager.renderOptions.displayMode == .theater {
                captureManager.renderOptions.displayMode = .window
                openWindow(id: "main")
            }
        }
    }

    @MainActor
    private func exitTheater() async {
        guard !isExiting else { return }
        isExiting = true
        captureManager.renderOptions.displayMode = .window
        openWindow(id: "main")
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(250))
        await dismissImmersiveSpace()
        isExiting = false
    }
}

private enum TheaterPanel {
    case screen
    case enhance
    case resolution
    case stream
    case stats
    case more
}

/// A rounded dock of icon buttons with captions. Settings are rendered in an inline
/// panel above it because window popovers do not have a reliable presentation
/// anchor inside a RealityView attachment.
private struct FloatingTheaterControls: View {
    @ObservedObject var app: AppModel
    @ObservedObject var captureManager: CaptureManager
    @ObservedObject var renderOptions: RenderOptions
    @Binding var position: SIMD3<Float>
    let defaultPosition: SIMD3<Float>
    let onExit: () async -> Void

    @State private var expanded = true
    @State private var activePanel: TheaterPanel?
    @State private var lastInteraction = Date()
    @State private var dragStartPosition: SIMD3<Float>?

    private let collapseDelay: TimeInterval = 12

    var body: some View {
        Group {
            if expanded {
                expandedControls
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            } else {
                collapsedButton
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .simultaneousGesture(TapGesture().onEnded { markInteraction() })
        .onChange(of: app.freeTimeWarning) { _, warn in
            guard warn else { return }
            markInteraction()
            withAnimation(.easeInOut(duration: 0.2)) {
                activePanel = nil
                expanded = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard expanded, activePanel == nil, dragStartPosition == nil else { continue }
                if Date().timeIntervalSince(lastInteraction) >= collapseDelay {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded = false
                    }
                }
            }
        }
    }

    /// Keep the panel inside the attachment's real layout bounds. Content that
    /// is merely offset outside those bounds can render but fail spatial taps.
    private var expandedControls: some View {
        VStack(spacing: 32) {
            Group {
                if app.freeTimeWarning {
                    FreeTimeWarningCard(
                        onContinue: { app.freeTimeWarning = false },
                        onUpgrade: {
                            app.freeTimeWarning = false
                            PurchaseManager.shared.requestPaywall(.browse)
                        })
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if let activePanel {
                    panel(for: activePanel)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    Color.clear
                        .frame(width: 920, height: 700)
                        .allowsHitTesting(false)
                }
            }

            expandedBar
        }
        .frame(width: 2064, height: 900, alignment: .bottom)
    }

    /// Rounded dock: circular icon buttons with a short caption under each,
    /// grouped by thin dividers. Sizes itself to its content.
    private var expandedBar: some View {
        HStack(alignment: .top, spacing: 6) {
            statusSummary
                .padding(.trailing, 10)

            dockDivider

            DockButton(title: "Screen", icon: "rectangle.on.rectangle",
                              isOn: activePanel == .screen) { toggle(.screen) }
            DockButton(title: "Enhance", icon: "wand.and.stars",
                              isOn: activePanel == .enhance) { toggle(.enhance) }
            if app.activeSource == .capture && !captureManager.availableFormats.isEmpty {
                DockButton(title: "Resolution", icon: "slider.horizontal.3",
                                  isOn: activePanel == .resolution) { toggle(.resolution) }
            }
            if app.activeSource == .remote {
                DockButton(title: "Stream", icon: "dial.medium",
                                  isOn: activePanel == .stream) { toggle(.stream) }
            }
            DockButton(title: "Stats", icon: "chart.xyaxis.line",
                              isOn: activePanel == .stats) { toggle(.stats) }
            DockButton(title: "Hide Hands", icon: "hand.raised.slash",
                              isOn: app.theaterHideHands) {
                markInteraction()
                app.theaterHideHands.toggle()
            }
            .help("Hiding hands uses full immersion and hides your surroundings. Turn this off to restore passthrough.")
            DockButton(title: "More", icon: "ellipsis",
                              isOn: activePanel == .more) { toggle(.more) }

            dockDivider

            if app.activeSource == .remote {
                DockButton(title: "PS", psGlyph: true) {
                    markInteraction()
                    app.remote.pressPSButton()
                }
                .disabled(app.remote.state != .streaming)
                .accessibilityLabel(Text("PS Button"))
                .help("Hold L3 + R3 for the PS button")
            }

            // Stop = end the stream and go Home. Exit Theater keeps the
            // stream and returns to the window.
            DockButton(title: LocalizedStringKey(app.isRunning ? "Stop" : "Start"),
                              icon: app.isRunning ? "stop.fill" : "play.fill",
                              fill: app.isRunning ? .red : Brand.blue) {
                markInteraction()
                if app.isRunning {
                    app.stopAndGoHome()
                    Task { await onExit() }
                } else {
                    app.toggleRunning()
                }
            }
            DockButton(title: "Exit Theater", icon: "macwindow") {
                Task { await onExit() }
            }
            .help("Back to the window; the stream keeps running")

            dockDivider

            moveHandle
            DockButton(title: "Collapse", icon: "chevron.down") {
                activePanel = nil
                withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
            }
            .help("Collapse Controls")
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .fixedSize()
        .brandPanel(in: RoundedRectangle(cornerRadius: 56, style: .continuous))
    }

    private var dockDivider: some View { DockDivider() }

    private var statusSummary: some View {
        HStack(spacing: 14) {
            Image(systemName: app.sourceIcon)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 64, height: 64)
                .background(Circle().fill(Brand.blue.opacity(0.35)))
            VStack(alignment: .leading, spacing: 4) {
                Text(app.sourceTitle)
                    .font(.headline)
                    .lineLimit(1)
                if let left = app.freeSecondsLeft {
                    FreeTimeChip(secondsLeft: left)
                }
                Text(app.formatText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(app.rateText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 230, alignment: .leading)
        .padding(.top, 4)
    }

    private func toggle(_ panel: TheaterPanel) {
        markInteraction()
        withAnimation(.easeInOut(duration: 0.2)) {
            activePanel = activePanel == panel ? nil : panel
        }
    }

    private var moveHandle: some View {
        DockItem(title: "Move", icon: "arrow.up.and.down.and.arrow.left.and.right")
            .help("Move Controls")
            .gesture(
                DragGesture()
                    .onChanged { value in
                        markInteraction()
                        let start = dragStartPosition ?? position
                        if dragStartPosition == nil { dragStartPosition = start }
                        let scale: Float = 1.0 / 1360.0
                        position.x = min(2.5, max(-2.5,
                            start.x + Float(value.translation.width) * scale))
                        position.y = min(2.5, max(0.15,
                            start.y - Float(value.translation.height) * scale))
                    }
                    .onEnded { _ in
                        dragStartPosition = nil
                        markInteraction()
                    }
            )
    }

    private var collapsedButton: some View {
        Button {
            markInteraction()
            withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 36, weight: .semibold))
                .frame(width: 96, height: 96)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .help("Show Theater Controls")
        .brandPanel(in: Circle())
        .frame(width: 2064, height: 900, alignment: .bottom)
    }

    @ViewBuilder
    private func panel(for panel: TheaterPanel) -> some View {
        switch panel {
        case .screen:
            InlineTheaterPanel(title: "Screen", onClose: closePanel) {
                Form {
                    TheaterScreenSection(renderOptions: renderOptions)
                }
            }
        case .enhance:
            InlineTheaterPanel(title: "Enhance", onClose: closePanel) {
                Form {
                    OptionSections(captureManager: captureManager,
                                   renderOptions: renderOptions)
                }
            }
        case .resolution:
            InlineTheaterPanel(title: "Resolution", onClose: closePanel) {
                ImmersiveResolutionList(captureManager: captureManager,
                                        onInteraction: markInteraction)
            }
        case .stream:
            InlineTheaterPanel(title: "Stream Settings", onClose: closePanel) {
                Form {
                    RemoteSettingsSections(
                        settings: app.remote.settings,
                        onApplyNow: app.remote.state == .streaming
                            ? { closePanel(); app.remote.reconnect() } : nil,
                        compact: true)
                }
            }
        case .stats:
            InlineTheaterPanel(title: "Performance Stats", onClose: closePanel) {
                Form {
                    StatsSections(statistics: captureManager.statistics)
                }
            }
        case .more:
            InlineTheaterPanel(title: "More", onClose: closePanel) {
                MoreTheaterControls(
                    app: app,
                    captureManager: captureManager,
                    position: $position,
                    defaultPosition: defaultPosition,
                    onInteraction: markInteraction
                )
            }
        }
    }

    private func closePanel() {
        markInteraction()
        withAnimation(.easeInOut(duration: 0.2)) { activePanel = nil }
    }

    private func markInteraction() {
        lastInteraction = Date()
    }

}

/// Shown above the theater bar one minute before a free session ends.
private struct FreeTimeWarningCard: View {
    let onContinue: () -> Void
    let onUpgrade: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "timer")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Free play ends in 1 minute")
                .font(.largeTitle.weight(.semibold))
            Text("You get 10 minutes of free play each day. Unlock Pro to keep playing without a limit.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 20) {
                Button(action: onContinue) {
                    Text("Keep Playing").frame(minWidth: 220)
                }
                .buttonStyle(.bordered)
                Button(action: onUpgrade) {
                    Label("Unlock Pro", systemImage: "crown.fill").frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.blue)
            }
            .controlSize(.extraLarge)
        }
        .padding(48)
        .frame(width: 920, height: 700)
        .brandPanel(in: RoundedRectangle(cornerRadius: 48, style: .continuous))
    }
}

private struct InlineTheaterPanel<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            Divider()

            content
                .scrollContentBackground(.hidden)
        }
        .font(.title3)
        .controlSize(.large)
        .frame(width: 920, height: 700)
        .brandPanel(in: RoundedRectangle(cornerRadius: 48, style: .continuous))
    }
}

private struct ImmersiveResolutionList: View {
    @ObservedObject var captureManager: CaptureManager
    let onInteraction: () -> Void

    var body: some View {
        List {
            Section {
                selectionButton("Auto (recommended)", index: nil)
                ForEach(captureManager.availableFormats) { option in
                    selectionButton(option.label, index: option.id)
                }
            } footer: {
                Text("Formats reported by the selected capture card. Some cards may scale the HDMI input internally.")
            }
        }
        .listStyle(.plain)
    }

    private func selectionButton(_ title: String, index: Int?) -> some View {
        Button {
            captureManager.selectFormat(index)
            onInteraction()
        } label: {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer()
                if captureManager.selectedFormatIndex == index {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

private struct MoreTheaterControls: View {
    @ObservedObject var app: AppModel
    @ObservedObject var captureManager: CaptureManager
    @Binding var position: SIMD3<Float>
    let defaultPosition: SIMD3<Float>
    let onInteraction: () -> Void

    var body: some View {
        Form {
            Section("Control Position") {
                HStack {
                    Text("Distance")
                    Slider(value: distanceBinding, in: 0.8...3.0)
                    Text(String(format: "%.1fm", -position.z))
                        .font(.body.monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
                Button {
                    position = defaultPosition
                    onInteraction()
                } label: {
                    Label("Reset Control Position", systemImage: "scope")
                }
            }

            Section {
                if app.activeSource == .remote {
                    Button(role: .destructive) {
                        app.remote.putConsoleToSleep()
                        onInteraction()
                    } label: {
                        Label("Put Console in Rest Mode", systemImage: "moon.zzz")
                    }
                } else {
                    Button {
                        captureManager.refreshDevices()
                        onInteraction()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var distanceBinding: Binding<Float> {
        Binding(
            get: { -position.z },
            set: {
                position.z = -$0
                onInteraction()
            }
        )
    }
}
#endif
