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
                .handlesGameControllerEvents(matching: app.gamepadEventsForUI)
            }
        }
        .handlesGameControllerEvents(matching: app.gamepadEventsForUI)
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

/// A two-times-size window-style toolbar. Settings are rendered in an inline
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
        .frame(width: 1904, height: 900, alignment: .bottom)
    }

    private var expandedBar: some View {
        HStack(spacing: 18) {
            statusSummary

            Spacer(minLength: 12)

            toolbarButton("Screen", icon: "rectangle.on.rectangle", panel: .screen,
                          minWidth: 190)
            toolbarButton("Enhance", icon: "wand.and.stars", panel: .enhance,
                          minWidth: 210)

            if app.activeSource == .capture && !captureManager.availableFormats.isEmpty {
                toolbarButton("Resolution", icon: "slider.horizontal.3", panel: .resolution,
                              minWidth: 230)
            }

            if app.activeSource == .remote {
                toolbarButton("Stream", icon: "dial.medium", panel: .stream,
                              minWidth: 190)
            }

            toolbarButton("Stats", icon: "chart.xyaxis.line", panel: .stats,
                          minWidth: 160)

            toolbarButton("More", icon: "ellipsis.circle", panel: .more,
                          minWidth: 170)

            // Stop = end the stream and go Home. Exit Theater (right) keeps
            // the stream and returns to the window.
            Button {
                markInteraction()
                if app.isRunning {
                    app.stopAndGoHome()
                    Task { await onExit() }
                } else {
                    app.toggleRunning()
                }
            } label: {
                Label {
                    Text(LocalizedStringKey(app.isRunning ? "Stop" : "Start"))
                } icon: {
                    Image(systemName: app.isRunning ? "stop.fill" : "play.fill")
                }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isRunning ? .red : Brand.blue)

            moveHandle

            Button {
                activePanel = nil
                withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
            .help("Collapse Controls")

            Button {
                Task { await onExit() }
            } label: {
                Label("Exit Theater", systemImage: "macwindow")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.bordered)
            .help("Back to the window; the stream keeps running")
        }
        .font(.title3)
        .controlSize(.large)
        .frame(width: 1840, height: 168)
        .padding(.horizontal, 32)
        .brandPanel(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(app.sourceTitle, systemImage: app.sourceIcon)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 18) {
                if let left = app.freeSecondsLeft {
                    FreeTimeChip(secondsLeft: left)
                }
                Label(app.formatText,
                      systemImage: "rectangle.on.rectangle")
                Label(app.rateText,
                      systemImage: "speedometer")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(width: 360, alignment: .leading)
    }

    private func toolbarButton(_ title: String, icon: String, panel: TheaterPanel,
                               minWidth: CGFloat) -> some View {
        Button {
            markInteraction()
            withAnimation(.easeInOut(duration: 0.2)) {
                activePanel = activePanel == panel ? nil : panel
            }
        } label: {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: icon)
            }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minWidth)
        }
        .buttonStyle(.borderedProminent)
    }

    private var moveHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 30, weight: .semibold))
            .frame(width: 72, height: 72)
            .contentShape(Rectangle())
            .hoverEffect()
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
                .font(.system(size: 50, weight: .semibold))
                .frame(width: 128, height: 112)
        }
        .buttonStyle(.plain)
        .help("Show Theater Controls")
        .brandPanel(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(width: 1904, height: 900, alignment: .bottom)
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
        .brandPanel(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
        .brandPanel(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                    Button {
                        app.remote.pressPSButton()
                        onInteraction()
                    } label: {
                        Label("PS Button", systemImage: "button.programmable")
                    }
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
