import SwiftUI

/// Launcher. Remote Play is the main feature, with the paired consoles as its
/// sub-section; the capture card is an extra way to play, shown below.
struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var capture: CaptureManager
    @ObservedObject var remote: RemotePlayManager
    @ObservedObject var store: ConsoleStore
    @ObservedObject private var purchases = PurchaseManager.shared

    @State private var showAddConsole = false
    @State private var showRemoteSettings = false
    @State private var consoleToForget: PSConsole?
    @State private var consoleToRename: PSConsole?
    @State private var renameText = ""
    @State private var showAbout = false
    @State private var layout = LayoutClass(width: 1000)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                header
                remoteHero
                consolesSection
                if Platform.supportsCapture {
                    accessorySection
                }
                legalNotice
            }
            .padding(.horizontal, layout.pagePadding)
            .padding(.vertical, layout.isCompact ? 20 : 40)
            .frame(maxWidth: Platform.isVision ? nil : 1200)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layout = LayoutClass(width: $0) }
        .environment(\.layoutClass, layout)
        .background { HomeBackground() }
        .sheet(isPresented: $showAbout) { AboutView() }
        .task {
            await capture.prepare()
            remote.startWatchingConsoles()
        }
        .onDisappear { remote.stopWatchingConsoles() }
        .onChange(of: store.consoles.count) { _, _ in remote.startWatchingConsoles() }
        .sheet(isPresented: $showAddConsole) {
            AddConsoleView(remote: remote, store: store)
        }
        .sheet(isPresented: $showRemoteSettings) {
            PanelSheet(title: "Stream Settings") {
                RemoteSettingsView(settings: remote.settings, onUpgrade: {
                    showRemoteSettings = false
                    purchases.requestPaywallAfterSheet()
                })
            }
        }
        .confirmationDialog("Forget this console?", isPresented: forgetBinding, presenting: consoleToForget) { console in
            Button("Forget \(console.nickname)", role: .destructive) { remote.forget(console) }
        } message: { _ in
            Text("You will need the PIN from the console to pair again.")
        }
        .alert("Rename Console", isPresented: renameBinding, presenting: consoleToRename) { console in
            TextField("Name", text: $renameText)
            Button("Save") { store.rename(console, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var forgetBinding: Binding<Bool> {
        Binding(get: { consoleToForget != nil }, set: { if !$0 { consoleToForget = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { consoleToRename != nil }, set: { if !$0 { consoleToRename = nil } })
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: layout.isCompact ? 12 : 18) {
            ShapeMark(size: layout.isCompact ? 52 : 76)
            VStack(alignment: .leading, spacing: 4) {
                Text("Couchport")
                    .font(layout.isCompact ? .title.weight(.bold) : .heroTitle)
                Text("Sit back. Step in.")
                    .font(layout.isCompact ? .subheadline : .title3)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Button {
                purchases.requestPaywall(.browse)
            } label: {
                Label(LocalizedStringKey(purchases.isPro ? "Couchport Pro" : "Unlock Pro"),
                      systemImage: purchases.isPro ? "checkmark.seal.fill" : "crown.fill")
                    .font(.title3)
                    .padding(6)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(purchases.isPro ? nil : Brand.blue)
            .help(LocalizedStringKey(purchases.isPro ? "Couchport Pro" : "Unlock Pro"))

            Button {
                showRemoteSettings = true
            } label: {
                Label("Stream Settings", systemImage: "gearshape.fill")
                    .font(.title3)
                    .padding(6)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Stream Settings")

            Button {
                showAbout = true
            } label: {
                Label("About", systemImage: "info.circle.fill")
                    .font(.title3)
                    .padding(6)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("About")
        }
    }

    // MARK: - Legal

    /// Independent-app notice. Brand names are used only to describe compatibility.
    private var legalNotice: some View {
        VStack(spacing: 8) {
            Button("About Couchport, Licenses & Source Code") { showAbout = true }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        Text("Couchport is an independent app and is not affiliated with, endorsed by, or sponsored by Sony Interactive Entertainment, Microsoft, or Apple. PlayStation, PS5, and PS4 are trademarks of Sony Interactive Entertainment Inc. Other names are trademarks of their respective owners and are used only to describe compatibility.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Remote Play hero

    /// Width / height of the RemoteHero asset (2400×857).
    private static let heroAspect: CGFloat = 2400.0 / 857.0

    @ViewBuilder
    private var remoteHero: some View {
        if layout.isCompact {
            compactHero
        } else {
            wideHero
        }
    }

    private var heroChips: some View {
        FlowLayout(spacing: 8) {
            Chip("Wireless", icon: "wifi")
            Chip("Up to 1080p60", icon: "sparkles.tv")
            Chip("With sound", icon: "speaker.wave.2.fill")
            if Platform.isVision {
                Chip("No strap needed", icon: "checkmark.seal.fill")
            }
        }
    }

    /// iPhone / iPhone Duo folded / narrow Split View: art on top, text below.
    private var compactHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("RemoteHero")
                .resizable()
                .aspectRatio(Self.heroAspect, contentMode: .fit)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                Text("REMOTE PLAY")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Brand.blue.mix(with: .white, by: 0.45))
                Text(Platform.heroHeadline)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                heroChips
                heroStatus
                VStack(spacing: 10) {
                    heroPrimaryButton
                        .frame(maxWidth: .infinity)
                    Button {
                        showAddConsole = true
                    } label: {
                        Label("Add Console", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!remote.isAvailable)
                }
                .controlSize(.large)
            }
            .padding(20)
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Brand.blue.opacity(0.35), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    private var wideHero: some View {
        ZStack(alignment: .leading) {
            // The art is made at exactly heroAspect, so the card shows all of
            // it with no cropping. Not hit-testable: decoration only.
            Image("RemoteHero")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            LinearGradient(colors: [Brand.night.opacity(0.7), Brand.night.opacity(0.2), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 18) {
                Text("REMOTE PLAY")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Brand.blue.mix(with: .white, by: 0.45))

                Text(Platform.heroHeadline)
                    .font(.heroTitle)
                    .fixedSize(horizontal: false, vertical: true)

                heroChips

                heroStatus

                HStack(spacing: 14) {
                    heroPrimaryButton
                    Button {
                        showAddConsole = true
                    } label: {
                        Label("Add Console", systemImage: "plus")
                    }
                    .disabled(!remote.isAvailable)
                }
                .controlSize(.extraLarge)
            }
            .padding(Platform.isVision ? 40 : 28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Platform.isVision ? 0 : 340)
        .aspectRatio(Self.heroAspect, contentMode: .fit)
        .background(Color(red: 0.03, green: 0.05, blue: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .strokeBorder(Brand.blue.opacity(0.35), lineWidth: 1.5)
        }
        .shadow(color: Brand.blue.opacity(0.35), radius: 30, y: 10)
    }

    @ViewBuilder
    private var heroStatus: some View {
        if !remote.isAvailable {
            Label("Remote Play library not built. Run Tools/build_libchiaki_visionos.sh, then rebuild.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if case .failed(let message) = remote.state {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(3)
        } else if let console = store.preferredConsole {
            let status = remote.consoleStatus[console.id] ?? .unknown
            HStack(spacing: 8) {
                StatusDot(status: status)
                Text(console.nickname).font(.callout.weight(.semibold))
                Text(status.label).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text(Platform.networkTip)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var heroPrimaryButton: some View {
        if let console = store.preferredConsole {
            let status = remote.consoleStatus[console.id] ?? .unknown
            Button {
                app.play(console)
            } label: {
                Label(LocalizedStringKey(status == .standby || status == .offline ? "Wake and Play" : "Play"),
                      systemImage: status == .standby || status == .offline ? "power" : "play.fill")
                    .frame(minWidth: 170)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.blue)
            .disabled(!remote.isAvailable)
        } else {
            Button {
                showAddConsole = true
            } label: {
                Label("Pair a Console", systemImage: "link")
                    .frame(minWidth: 170)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.blue)
            .disabled(!remote.isAvailable)
        }
    }

    // MARK: - Consoles (sub-section of Remote Play)

    private var sortedConsoles: [PSConsole] {
        func rank(_ c: PSConsole) -> Int {
            switch remote.consoleStatus[c.id] ?? .unknown {
            case .ready: return 0
            case .standby: return 1
            case .unknown: return 2
            case .offline: return 3
            }
        }
        return store.consoles.sorted {
            let (a, b) = (rank($0), rank($1))
            if a != b { return a < b }
            return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
        }
    }

    private var consolesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("My Consoles")
                    .font(layout.isCompact ? .title2.weight(.semibold) : .title.weight(.semibold))
                Text(verbatim: "\(store.consoles.count)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.consoles.count > 1 && !layout.isCompact {
                    Text("Ready consoles first. Hold a console for more options.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.isCompact ? 260 : 320, maximum: 420), spacing: 22, alignment: .top)],
                      alignment: .leading, spacing: 22) {
                ForEach(sortedConsoles) { console in
                    ConsoleTile(
                        console: console,
                        status: remote.consoleStatus[console.id] ?? .unknown,
                        runningApp: remote.runningApp[console.id],
                        isLastPlayed: store.consoles.count > 1 && console.id == store.preferredConsole?.id,
                        enabled: remote.isAvailable,
                        onPlay: { app.play(console) },
                        onWake: { remote.wake(console) },
                        onRename: {
                            renameText = console.nickname
                            consoleToRename = console
                        },
                        onForget: { consoleToForget = console }
                    )
                }
                AddConsoleTile(isFirst: store.consoles.isEmpty) { showAddConsole = true }
                    .disabled(!remote.isAvailable)
            }
        }
    }

    // MARK: - Capture card (extra)

    private var accessorySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("More Ways to Play")
                .font(layout.isCompact ? .title2.weight(.semibold) : .title.weight(.semibold))

            HStack(spacing: 0) {
                // Shown whole (fit), on the art's own background colour.
                // The art shows the Developer Strap, so visionOS only.
                if Platform.isVision {
                Image("StrapSetup")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 460)
                    .frame(maxHeight: .infinity)
                    .background(Color(red: 25.0/255, green: 32.0/255, blue: 51.0/255))
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Vision Pro with the Developer Strap, a capture card and a game console"))
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "cable.connector.horizontal")
                            .font(.title2.weight(.semibold))
                        Text("Capture Card (UVC)")
                            .font(.title2.weight(.semibold))
                        if !purchases.isPro { ProBadge() }
                    }

                    Text("Connect any HDMI device: PlayStation, Xbox, Switch, PC or camera, through a UVC capture card. Wired, lowest latency, up to 4K60.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if Platform.isVision {
                        Label("Requires the Apple Vision Pro Developer Strap", systemImage: "exclamationmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.yellow)
                    } else {
                        Label("Plug the capture card into the iPad's USB-C port", systemImage: "cable.connector")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.yellow)
                    }

                    HStack(spacing: 8) {
                        Circle().fill(capture.hasDevice ? Color.green : Color.secondary).frame(width: 9, height: 9)
                        if capture.hasDevice {
                            Text(verbatim: capture.selectedDeviceName).font(.callout).lineLimit(1)
                        } else {
                            Text("No capture card connected").font(.callout)
                        }
                    }

                    Text("Turn off HDCP on the PS5 (Settings › System › HDMI).")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        if purchases.isPro {
                            Button {
                                app.playCapture()
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .frame(minWidth: 120)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!capture.hasDevice)
                        } else {
                            Button {
                                purchases.requestPaywall(.capture)
                            } label: {
                                Label("Unlock with Pro", systemImage: "lock.fill")
                                    .frame(minWidth: 120)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.blue)
                        }

                        Button {
                            capture.refreshDevices()
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        .help("Rescan for capture cards")
                    }
                    .controlSize(.large)
                }
                .padding(layout.isCompact ? 20 : 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Platform.isVision ? 300 : 0)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
    }
}

// MARK: - Components

private extension RemotePlayManager.ConsoleStatus {
    var label: LocalizedStringKey {
        switch self {
        case .ready: return "Ready"
        case .standby: return "Rest Mode"
        case .offline: return "Offline"
        case .unknown: return "Checking…"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .standby: return .orange
        case .offline: return .gray
        case .unknown: return .secondary
        }
    }
}

private struct HomeBackground: View {
    var body: some View {
        BrandBackdrop(patternOpacity: 0.9)
            .ignoresSafeArea()
    }
}

/// The four face-button shapes as a small brand mark.
/// The Couchport app icon (flattened 3-layer stack), shown in the Home header.
private struct ShapeMark: View {
    var size: CGFloat = 76
    var body: some View {
        Image("AppMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}

private struct Chip: View {
    let title: LocalizedStringKey
    let icon: String

    init(_ title: LocalizedStringKey, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct StatusDot: View {
    let status: RemotePlayManager.ConsoleStatus
    var body: some View {
        Circle().fill(status.color).frame(width: 10, height: 10)
            .shadow(color: status == .ready ? .green.opacity(0.8) : .clear, radius: 4)
    }
}

private struct ConsoleTile: View {
    let console: PSConsole
    let status: RemotePlayManager.ConsoleStatus
    let runningApp: String?
    let isLastPlayed: Bool
    let enabled: Bool
    let onPlay: () -> Void
    let onWake: () -> Void
    let onRename: () -> Void
    let onForget: () -> Void

    private var needsWake: Bool { status == .standby || status == .offline }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Brand.blue, Brand.deepBlue],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusDot(status: status)
                        Text(status.label).font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())

                    if isLastPlayed {
                        Text("Last Played")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Menu {
                    Button(action: onWake) { Label("Wake Console", systemImage: "power") }
                    Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive, action: onForget) { Label("Forget Console", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .help("More")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: console.nickname)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: "\(console.isPS5 ? "PS5" : "PS4") · \(console.host)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Group {
                    if let runningApp {
                        Label(runningApp, systemImage: "gamecontroller.fill")
                    } else {
                        Label { Text(verbatim: " ") } icon: { Image(systemName: "gamecontroller.fill") }
                            .hidden()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Button(action: onPlay) {
                Label(LocalizedStringKey(needsWake ? "Wake and Play" : "Play"),
                      systemImage: needsWake ? "power" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.blue)
            .controlSize(.large)
            .disabled(!enabled)
        }
        .padding(22)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            if status == .ready {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Brand.blue.opacity(0.6), lineWidth: 1.5)
            }
        }
        .contextMenu {
            Button(action: onWake) { Label("Wake Console", systemImage: "power") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive, action: onForget) { Label("Forget Console", systemImage: "trash") }
        }
    }
}

private struct AddConsoleTile: View {
    let isFirst: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(Brand.blue.opacity(0.35), in: Circle())
                Text(LocalizedStringKey(isFirst ? "Pair Your First Console" : "Add Console"))
                    .font(.title3.weight(.semibold))
                Text("On the PS5: Settings › System › Remote Play › Link Device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 250)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .foregroundStyle(.white.opacity(0.35))
        }
        .hoverEffect()
    }
}

/// Wraps chips onto new lines when the row is too narrow (iPhone, iPhone Duo
/// folded); a single row elsewhere.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap: CGFloat = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
