#if os(tvOS)
import SwiftUI

/// Apple TV Home: a landscape 10-foot launcher that fits 1920×1080 inside the
/// safe area. Left column: brand, headline, tip, Pair, controller prompt.
/// Right: Pro / Stream Settings, then a horizontal shelf of console cards.
/// Rename / Forget live in each card's context menu (hold Select).
struct TVHomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var capture: CaptureManager
    @ObservedObject var remote: RemotePlayManager
    @ObservedObject var store: ConsoleStore
    @ObservedObject private var purchases = PurchaseManager.shared
    @ObservedObject private var controllers = ControllerPresence.shared

    @State private var showAddConsole = false
    @State private var showRemoteSettings = false
    @State private var consoleToForget: PSConsole?
    @State private var consoleToRename: PSConsole?
    @State private var renameText = ""

    private enum Target: Hashable {
        case console(PSConsole.ID)
        case pair
        case addCard
    }
    @FocusState private var focus: Target?

    private static let cardWidth: CGFloat = 430
    private static let cardHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: TVMetrics.columnSpacing) {
                leftColumn
                    .frame(width: TVMetrics.leftColumnWidth)
                    .focusSection()

                VStack(alignment: .leading, spacing: 28) {
                    topRow
                        .focusSection()
                    shelfSection
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            legalNotice
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Content stays inside the system safe area; only the backdrop bleeds.
        .background { HomeBackground() }
        .defaultFocus($focus, initialFocus)
        .onAppear { if focus == nil { focus = initialFocus } }
        .task {
            if Platform.supportsCapture { await capture.prepare() }
            remote.startWatchingConsoles()
        }
        .onDisappear { remote.stopWatchingConsoles() }
        .onChange(of: store.consoles.count) { _, _ in remote.startWatchingConsoles() }
        .adaptiveSheet(isPresented: $showAddConsole) {
            AddConsoleView(remote: remote, store: store)
        }
        .adaptiveSheet(isPresented: $showRemoteSettings) {
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

    private var initialFocus: Target {
        if let first = sortedConsoles.first, remote.isAvailable { return .console(first.id) }
        return .pair
    }

    private var forgetBinding: Binding<Bool> {
        Binding(get: { consoleToForget != nil }, set: { if !$0 { consoleToForget = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { consoleToRename != nil }, set: { if !$0 { consoleToRename = nil } })
    }

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

    // MARK: - Left column

    private var leftColumn: some View {
        // Scrolls only if a very large text size would otherwise clip.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 22) {
                    ShapeMark(size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couchport")
                            .font(.system(size: 52, weight: .bold))
                        Text("Sit back. Step in.")
                            .font(TVMetrics.body)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("REMOTE PLAY")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Brand.blue.mix(with: .white, by: 0.45))
                    Text(Platform.heroHeadline)
                        .font(.system(size: 46, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    statusLine
                }

                Button {
                    showAddConsole = true
                } label: {
                    Label("Pair a Console", systemImage: "link")
                        .font(.system(size: 31, weight: .semibold))
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.blue)
                .disabled(!remote.isAvailable)
                .focused($focus, equals: .pair)

                if !controllers.isConnected {
                    ConnectControllerPrompt(compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12) // room for the focus lift
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var statusLine: some View {
        if !remote.isAvailable {
            Label("Remote Play library not built. Run Tools/build_libchiaki_visionos.sh, then rebuild.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(TVMetrics.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .failed(let message) = remote.state {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(TVMetrics.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(Platform.networkTip)
                .font(TVMetrics.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(spacing: 24) {
            Spacer(minLength: 0)
            Button {
                purchases.requestPaywall(.browse)
            } label: {
                Label(LocalizedStringKey(purchases.isPro ? "Couchport Pro" : "Unlock Pro"),
                      systemImage: purchases.isPro ? "checkmark.seal.fill" : "crown.fill")
            }
            .buttonStyle(.bordered)
            .tint(purchases.isPro ? nil : Brand.blue)

            Button {
                showRemoteSettings = true
            } label: {
                Label("Stream Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(.bordered)
        }
        .lineLimit(1)
    }

    // MARK: - Console shelf

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("My Consoles")
                    .font(TVMetrics.sectionTitle)
                if !store.consoles.isEmpty {
                    Text(verbatim: "\(store.consoles.count)")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)

            if !store.consoles.isEmpty {
                Text("Ready consoles first. Hold a console for more options.")
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) {
                    if store.consoles.isEmpty {
                        firstConsoleCard
                    } else {
                        ForEach(sortedConsoles) { console in
                            consoleCard(console)
                        }
                        addConsoleCard
                    }
                }
                // Room for the card focus lift and shadow.
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func consoleCard(_ console: PSConsole) -> some View {
        let status = remote.consoleStatus[console.id] ?? .unknown
        return Button {
            app.play(console)
        } label: {
            TVConsoleCardLabel(
                console: console,
                status: status,
                runningApp: remote.runningApp[console.id],
                isLastPlayed: store.consoles.count > 1 && console.id == store.preferredConsole?.id
            )
            .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        }
        .buttonStyle(.card)
        .disabled(!remote.isAvailable)
        .focused($focus, equals: .console(console.id))
        .contextMenu {
            Button { remote.wake(console) } label: { Label("Wake Console", systemImage: "power") }
            Button {
                renameText = console.nickname
                consoleToRename = console
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { consoleToForget = console } label: {
                Label("Forget Console", systemImage: "trash")
            }
        }
    }

    private var addConsoleCard: some View {
        Button {
            showAddConsole = true
        } label: {
            VStack(spacing: 20) {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .semibold))
                    .frame(width: 96, height: 96)
                    .background(Brand.blue.opacity(0.35), in: Circle())
                Text("Add Console")
                    .font(.system(size: 34, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(28)
            .frame(width: 320, height: Self.cardHeight)
        }
        .buttonStyle(.card)
        .disabled(!remote.isAvailable)
        .focused($focus, equals: .addCard)
    }

    private var firstConsoleCard: some View {
        Button {
            showAddConsole = true
        } label: {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .semibold))
                    .frame(width: 96, height: 96)
                    .background(Brand.blue.opacity(0.35), in: Circle())
                Text("Pair Your First Console")
                    .font(.system(size: 40, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the PS5: Settings › System › Remote Play › Link Device")
                    .font(TVMetrics.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(40)
            .frame(width: 760, height: Self.cardHeight, alignment: .topLeading)
        }
        .buttonStyle(.card)
        .disabled(!remote.isAvailable)
        .focused($focus, equals: .addCard)
    }

    // MARK: - Legal

    private var legalNotice: some View {
        Text("Independent app, not affiliated with Sony Interactive Entertainment or Apple.")
            .font(.system(size: 20))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
    }
}

/// The face of a console card on the TV shelf: what the console rows show
/// elsewhere (name, address, state, running game, last played) plus the action
/// Select performs.
private struct TVConsoleCardLabel: View {
    let console: PSConsole
    let status: RemotePlayManager.ConsoleStatus
    let runningApp: String?
    let isLastPlayed: Bool

    private var needsWake: Bool { status == .standby || status == .offline }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [Brand.blue, Brand.deepBlue],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 80, height: 80)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 10) {
                        StatusDot(status: status)
                        Text(status.label)
                            .font(.system(size: 23, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())

                    if isLastPlayed {
                        Text("Last Played")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: console.nickname)
                    .font(.system(size: 36, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: "\(console.isPS5 ? "PS5" : "PS4") · \(console.host)")
                    .font(.system(size: 23).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let runningApp {
                    Label(runningApp, systemImage: "gamecontroller.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let played = console.lastPlayedAt {
                    Label {
                        Text(played, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.system(size: 23))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Label(LocalizedStringKey(needsWake ? "Wake and Play" : "Play"),
                  systemImage: needsWake ? "power" : "play.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Brand.blue, in: Capsule())
        }
        .padding(28)
        .overlay {
            if status == .ready {
                RoundedRectangle(cornerRadius: TVMetrics.cardCorner, style: .continuous)
                    .strokeBorder(Brand.blue.opacity(0.7), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}
#endif
