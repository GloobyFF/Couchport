import SwiftUI
import GameController

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        RootView(app: app, renderOptions: app.renderOptions)
    }
}

/// Routes between Home, the player, and the compact theater panel, and keeps
/// the immersive space in sync with the display mode.
private struct RootView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var renderOptions: RenderOptions
    @ObservedObject private var purchases = PurchaseManager.shared

    #if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    var body: some View {
        Group {
            if Platform.supportsTheater && renderOptions.displayMode == .theater {
                TheaterControlPanel(app: app, renderOptions: renderOptions)
            } else if app.activeSource == nil {
                HomeView(app: app, capture: app.capture, remote: app.remote, store: app.consoles)
                    .transition(.opacity)
            } else {
                PlayerView(app: app, renderOptions: renderOptions)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.activeSource)
        // While streaming, the controller belongs to the PS5: route gamepad
        // events to GameController only, so they never move focus or press
        // buttons in our UI. Home and capture mode keep normal navigation.
        .streamOwnsGamepad(app)
        .onChange(of: renderOptions.displayMode) { _, mode in
            Task { await applyDisplayMode(mode) }
        }
        // The Couchport Pro sheet, requested from anywhere in the app.
        .sheet(item: $purchases.paywallRequest) { reason in
            PaywallView(reason: reason)
        }
    }

    private func applyDisplayMode(_ mode: DisplayMode) async {
        #if os(visionOS)
        switch mode {
        case .theater:
            guard !app.capture.immersiveOpen else { return }
            switch await openImmersiveSpace(id: "theater") {
            case .opened:
                dismissWindow(id: "main")
            default:
                renderOptions.displayMode = .window
            }
        case .window:
            if app.capture.immersiveOpen {
                await dismissImmersiveSpace()
            }
        }
        #else
        // No immersive theater on iPhone/iPad: always the window player.
        if mode == .theater { renderOptions.displayMode = .window }
        #endif
    }
}

// MARK: - Player

private struct PlayerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var renderOptions: RenderOptions
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var passcode = ""
    /// Panels are sheets owned by the player, not popovers on the ornament:
    /// a popover anchored in an auto-hiding ornament is torn down when the
    /// ornament hides, its binding stays true, and the button stops working.
    @State private var panel: PlayerPanel?

    @ViewBuilder
    private var playerSurface: some View {
        #if os(iOS)
        // iPhone / iPhone Duo / iPad: video plus the on-screen controller,
        // arranged for the current width, height and fold.
        PhonePlayerStage(settings: app.remote.settings, gamepad: app.remote.gamepad,
                         isRemote: app.activeSource == .remote,
                         renderer: app.capture.metalRenderer) {
            MetalVideoView(renderer: app.capture.metalRenderer)
        } videoOverlay: {
            if app.showsIdleOverlay {
                StatusOverlay(title: app.overlayTitle, message: app.statusMessage)
            }
        }
        #else
        ZStack {
            Color.black.ignoresSafeArea()

            MetalVideoView(renderer: app.capture.metalRenderer)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if app.showsIdleOverlay {
                        StatusOverlay(title: app.overlayTitle, message: app.statusMessage)
                    }
                }
        }
        #endif
    }

    var body: some View {
        playerSurface
        .contentShape(Rectangle())
        .onTapGesture { showControls(!controlsVisible) }
        #if os(visionOS)
        .ornament(visibility: controlsVisible ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottom),
                  contentAlignment: .top) {
            PlayerControlBar(app: app, renderOptions: renderOptions,
                             onInteraction: { showControls(true) },
                             onOpen: { open($0) })
                .padding(.top, 24)
                .streamOwnsGamepad(app)
        }
        #else
        // iPhone / iPhone Duo / iPad: one draggable floating button in every
        // pose; its panel holds all the controls (no bar over the picture).
        .overlay {
            FloatingPlayerControls(app: app, settings: app.remote.settings,
                                   onOpen: { open($0) })
        }
        .immersivePlayerChrome()
        #endif
        .onAppear { showControls(true) }
        .onChange(of: app.isRunning) { _, running in if running { showControls(true) } }
        .onChange(of: panel) { _, value in if value == nil { showControls(true) } }
        .sheet(item: $panel) { panel in
            panelView(panel)
                .streamOwnsGamepad(app)
        }
        .onChange(of: app.freeTimeWarning) { _, warn in if warn { panel = nil } }
        .alert("Free play ends in 1 minute", isPresented: $app.freeTimeWarning) {
            Button("Keep Playing", role: .cancel) {}
            Button("Unlock Pro") { PurchaseManager.shared.requestPaywall(.browse) }
        } message: {
            Text("Free sessions last 10 minutes. Unlock Pro to keep playing without a limit.")
        }
        .alert("Console Passcode", isPresented: pinBinding) {
            SecureField("Passcode", text: $passcode)
                .keyboardType(.numberPad)
            Button("OK") {
                app.remote.submitLoginPin(passcode)
                passcode = ""
            }
            Button("Cancel", role: .cancel) { app.stopAndGoHome() }
        } message: {
            Text(app.remote.pinRequest?.incorrect == true
                 ? "Wrong passcode. Enter the 4-digit login passcode of the PS5 user."
                 : "This PS5 user has a login passcode. Enter it to continue.")
        }
    }

    private func open(_ value: PlayerPanel) {
        hideTask?.cancel()
        panel = value
    }

    @ViewBuilder
    private func panelView(_ panel: PlayerPanel) -> some View {
        switch panel {
        case .enhance:
            PanelSheet(title: "Enhance") {
                Form {
                    OptionSections(captureManager: app.capture, renderOptions: renderOptions,
                                   onUpgrade: closePanelForPaywall)
                }
            }
        case .resolution:
            PanelSheet(title: "Resolution") {
                ResolutionPicker(captureManager: app.capture)
            }
        case .stream:
            PanelSheet(title: "Stream Settings") {
                RemoteSettingsView(settings: app.remote.settings,
                                   onApplyNow: app.remote.state == .streaming
                                       ? { self.panel = nil; app.remote.reconnect() } : nil,
                                   onUpgrade: closePanelForPaywall)
            }
        case .stats:
            DebugStatsPanel(statistics: app.capture.statistics)
        }
    }

    private func closePanelForPaywall() {
        panel = nil
        PurchaseManager.shared.requestPaywallAfterSheet()
    }

    private var pinBinding: Binding<Bool> {
        Binding(get: { app.remote.pinRequest != nil },
                set: { if !$0 { app.remote.pinRequest = nil } })
    }

    /// Controls fade out 5 s after the last interaction while video plays.
    private func showControls(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = visible }
        hideTask?.cancel()
        guard visible else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, app.isRunning, !app.showsIdleOverlay, panel == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

private struct PlayerControlBar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var renderOptions: RenderOptions
    let onInteraction: () -> Void
    let onOpen: (PlayerPanel) -> Void
    @State private var width: CGFloat = 1000

    /// Narrow screens (iPhone, iPhone Duo folded): icons only, no stats text.
    private var compact: Bool { !Platform.isVision && width < 700 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar
            ScrollView(.horizontal, showsIndicators: false) { bar }
        }
        .frame(maxWidth: Platform.isVision ? nil : .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var bar: some View {
        HStack(spacing: compact ? 10 : 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label(app.sourceTitle, systemImage: app.sourceIcon)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    if let left = app.freeSecondsLeft {
                        FreeTimeChip(secondsLeft: left)
                    }
                    if !compact {
                        Text(app.formatText)
                        Text(app.rateText)
                        Label(app.audioText, systemImage: "speaker.wave.2")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: compact ? 0 : 260, alignment: .leading)
            .frame(maxWidth: compact ? 150 : nil, alignment: .leading)

            Divider().frame(height: 36)

            if Platform.supportsTheater {
                Button {
                    onInteraction()
                    renderOptions.displayMode = .theater
                } label: {
                    Label("Theater", systemImage: "mountain.2.fill")
                }
            }

            Button {
                onOpen(.enhance)
            } label: {
                Label("Enhance", systemImage: "wand.and.stars")
            }

            if app.activeSource == .capture {
                if !app.capture.availableFormats.isEmpty {
                    Button {
                        onOpen(.resolution)
                    } label: {
                        Label("Resolution", systemImage: "slider.horizontal.3")
                    }
                }
            } else {
                Button {
                    onInteraction()
                    app.remote.pressPSButton()
                } label: {
                    Label("PS", systemImage: "button.programmable")
                }
                .help("PS button")

                Button {
                    onOpen(.stream)
                } label: {
                    Label("Stream", systemImage: "dial.medium")
                }
            }

            Menu {
                Button {
                    onOpen(.stats)
                } label: {
                    Label("Performance Stats", systemImage: "chart.xyaxis.line")
                }
                if app.activeSource == .capture {
                    Button {
                        app.capture.refreshDevices()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    Button {
                        app.capture.audioMonitor.toggle()
                    } label: {
                        Label(LocalizedStringKey(app.capture.audioMonitor.isMonitoring ? "Mute Capture Audio" : "Play Capture Audio"),
                              systemImage: "speaker.wave.2")
                    }
                } else {
                    #if os(iOS)
                    if app.remote.settings.pictureInPicture {
                        Button {
                            NotificationCenter.default.post(name: .couchportStartPictureInPicture, object: nil)
                        } label: {
                            Label("Picture in Picture", systemImage: "pip.enter")
                        }
                    }
                    Toggle(isOn: Binding(get: { app.remote.settings.tabletopReflection },
                                         set: { app.remote.settings.tabletopReflection = $0 })) {
                        Label("Tabletop Reflection", systemImage: "square.bottomhalf.filled")
                    }
                    // Shows what the app detected, to explain Automatic mode.
                    Text("Detected controller: \(app.remote.gamepad.controllerName ?? String(localized: "None"))")
                    Picker(selection: touchModeBinding) {
                        ForEach(TouchControlsMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    } label: {
                        Label("On-Screen Controller", systemImage: "gamecontroller")
                    }
                    #endif
                    Button(role: .destructive) {
                        app.remote.putConsoleToSleep()
                    } label: {
                        Label("Put Console in Rest Mode", systemImage: "moon.zzz")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }

            Button {
                app.stopAndGoHome()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .labelStyle(AdaptiveLabelStyle(iconOnly: compact))
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.vertical, compact ? 10 : 14)
        .brandPanel(in: Capsule())
    }
}

#if os(iOS)
private extension PlayerControlBar {
    var touchModeBinding: Binding<TouchControlsMode> {
        Binding(get: { app.remote.settings.touchControls },
                set: { app.remote.settings.touchControls = $0 })
    }
}
#endif

enum PlayerPanel: String, Identifiable {
    case enhance, resolution, stream, stats
    var id: String { rawValue }
}

// MARK: - Theater window panel

/// Compact control panel shown in the window while the video plays on the
/// immersive theater screen.
private struct TheaterControlPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var renderOptions: RenderOptions

    var body: some View {
        NavigationStack {
            Form {
                Section("Now Playing") {
                    LabeledContent("Source", value: app.sourceTitle)
                    LabeledContent("Format", value: app.formatText)
                    LabeledContent("Rate", value: app.rateText)
                    LabeledContent("Audio", value: app.audioText)
                }

                Section("Playback") {
                    Button {
                        renderOptions.displayMode = .window
                    } label: {
                        Label("Exit Theater", systemImage: "macwindow")
                    }
                    if app.activeSource == .remote {
                        Button {
                            app.remote.pressPSButton()
                        } label: {
                            Label("PS Button", systemImage: "button.programmable")
                        }
                    }
                    Button(role: .destructive) {
                        renderOptions.displayMode = .window
                        app.stopAndGoHome()
                    } label: {
                        Label("Stop and Return Home", systemImage: "stop.fill")
                    }
                }

                TheaterScreenSection(renderOptions: renderOptions)

                if app.activeSource == .remote {
                    RemoteSettingsSections(
                        settings: app.remote.settings,
                        onApplyNow: app.remote.state == .streaming ? { app.remote.reconnect() } : nil)
                }

                OptionSections(captureManager: app.capture, renderOptions: renderOptions)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Theater")
        }
        .brandWindowBackground()
    }
}

/// Title and icon on wide screens, icon only on narrow ones.
private struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            IconOnlyLabelStyle().makeBody(configuration: configuration)
        } else {
            TitleAndIconLabelStyle().makeBody(configuration: configuration)
        }
    }
}
