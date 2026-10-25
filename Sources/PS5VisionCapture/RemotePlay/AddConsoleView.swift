import SwiftUI

/// Pair a console: PSN account → console address → 8-digit PIN.
struct AddConsoleView: View {
    @ObservedObject var remote: RemotePlayManager
    @ObservedObject var store: ConsoleStore
    @Environment(\.dismiss) private var dismiss

    @State private var showPSNLogin = false
    @State private var manualAccountID = ""
    @State private var showManualID = false
    @State private var host = ""
    @State private var pin = ""
    @State private var isPS5 = true
    @State private var pairing = false
    @State private var errorText: String?
    @State private var task: RegistrationTask?

    @State private var scanner = DiscoveryWatcher()
    @State private var lanScanner = LANScanner()
    @State private var found: [DiscoveredConsole] = []
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accountRow
                    consoleGroup
                    pinGroup

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        pair()
                    } label: {
                        HStack {
                            if pairing { ProgressView().padding(.trailing, 6) }
                            Text(LocalizedStringKey(pairing ? "Pairing…" : "Pair"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.blue)
                    .controlSize(.extraLarge)
                    .disabled(!canPair)
                }
                .padding(Platform.isTV ? 60 : 32)
            }
            .navigationTitle("Add Console")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            #if !os(tvOS)
            // Sony's sign-in page needs WebKit, which tvOS does not have.
            .sheet(isPresented: $showPSNLogin) {
                PSNLoginSheet { id in
                    try? store.setAccountID(base64: id)
                }
            }
            #endif
            .onAppear {
                if store.consoles.isEmpty && !scanning { toggleScan() }
            }
            .onDisappear {
                stopScan()
                task?.cancel()
            }
        }
        .brandWindowBackground()
        .visionMinFrame(width: 600, height: 640)
    }

    // MARK: - Pieces

    /// The PSN account. iPhone, iPad and Vision Pro sign in with Sony's web
    /// page; Apple TV has no web view, so it gets the account from iCloud
    /// (paired on another device) or by typing the base64 account ID.
    @ViewBuilder
    private var accountRow: some View {
        #if os(tvOS)
        tvAccountRow
        #else
        webAccountRow
        #endif
    }

    #if os(tvOS)
    private var tvAccountRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                Image(systemName: store.accountIDBase64 == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(store.accountIDBase64 == nil ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PSN Account").font(.headline)
                    if let id = store.accountIDBase64 {
                        Text(verbatim: String(id.prefix(4)) + "••••••••")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use the account signed in on the console.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    showManualID.toggle()
                } label: {
                    Label("Enter account ID manually", systemImage: "keyboard")
                }
            }

            Label("Consoles and the PSN account you paired on your iPhone, iPad or Apple Vision Pro appear here automatically through iCloud. Open Couchport there once, signed in to the same Apple Account.",
                  systemImage: "icloud")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showManualID || store.accountIDBase64 == nil {
                HStack(spacing: 16) {
                    TextField("Base64 account ID, e.g. AbCdEfGhIjk=", text: $manualAccountID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save ID") {
                        do {
                            try store.setAccountID(base64: manualAccountID)
                            errorText = nil
                            showManualID = false
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(manualAccountID.isEmpty)
                }
                Text("The account ID is the 8-byte PSN user ID in base64 (12 characters ending in '='). chiaki-ng on a computer fills it in after you sign in to PSN in its settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(Brand.groupFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    #endif

    /// One compact line: the PSN account, with sign-in / manual entry tucked away.
    private var webAccountRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: store.accountIDBase64 == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(store.accountIDBase64 == nil ? Color.orange : Color.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("PSN Account").font(.headline)
                    if let id = store.accountIDBase64 {
                        Text(verbatim: String(id.prefix(4)) + "••••••••")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use the account signed in on the console.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if store.accountIDBase64 == nil {
                    Button("Sign In") { showPSNLogin = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.blue)
                }
                Menu {
                    Button {
                        showPSNLogin = true
                    } label: {
                        Label(LocalizedStringKey(store.accountIDBase64 == nil ? "Sign in with PlayStation Network" : "Sign in Again"),
                              systemImage: "person.crop.circle")
                    }
                    Button {
                        showManualID.toggle()
                    } label: {
                        Label("Enter account ID manually", systemImage: "keyboard")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                }
                .borderlessOrBorderedButtonStyle()
                .help("More")
            }

            if showManualID {
                HStack {
                    TextField("Base64 account ID, e.g. AbCdEfGhIjk=", text: $manualAccountID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .roundedFieldStyle()
                    Button("Save ID") {
                        do {
                            try store.setAccountID(base64: manualAccountID)
                            errorText = nil
                            showManualID = false
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(manualAccountID.isEmpty)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Brand.groupFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var consoleGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button {
                    toggleScan()
                } label: {
                    Label(LocalizedStringKey(scanning ? "Stop Searching" : "Search This Network"),
                          systemImage: scanning ? "stop.circle" : "magnifyingglass")
                        .font(.callout)
                }
                .borderlessOrBorderedButtonStyle()
            }

            ForEach(found) { console in
                Button {
                    host = console.address
                    isPS5 = console.isPS5
                } label: {
                    HStack {
                        Image(systemName: "gamecontroller.fill")
                        Text(verbatim: console.name.isEmpty ? console.address : console.name)
                        Text(verbatim: console.address).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if host == console.address {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.blue)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, Platform.isTV ? 16 : 0)
                }
                .plainOrCardButtonStyle()
            }

            HStack(spacing: 12) {
                TextField("Console IP address, e.g. 192.168.1.20", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .roundedFieldStyle()
                Picker("Console", selection: $isPS5) {
                    Text(verbatim: "PS5").tag(true)
                    Text(verbatim: "PS4").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            if scanning && found.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching this network…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("PS5: Settings › Network › Connection Status shows the IP address.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Brand.groupFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var pinGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link Code").font(.headline)
            TextField("8-digit PIN", text: $pin)
                .keyboardType(.numberPad)
                .font(.title.monospacedDigit())
                .multilineTextAlignment(.center)
                .roundedFieldStyle()
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(8))
                }
            Text("On the PS5 open Settings › System › Remote Play › Link Device. The PIN is valid for about 5 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(Brand.groupFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Actions

    private var canPair: Bool {
        store.accountID != nil && !host.trimmingCharacters(in: .whitespaces).isEmpty && pin.count == 8 && !pairing
    }

    /// Unicast sweep of the /24 (works without the multicast entitlement)
    /// plus chiaki's broadcast discovery (works only with it); results merge.
    private func toggleScan() {
        if scanning {
            stopScan()
            return
        }
        found = []
        let merge: ([DiscoveredConsole]) -> Void = { list in
            var byAddress = Dictionary(found.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
            for console in list { byAddress[console.address] = console }
            found = byAddress.values.sorted { $0.address < $1.address }
            if host.isEmpty, let first = found.first {
                host = first.address
                isPS5 = first.isPS5
            }
        }
        scanner.onUpdate = merge
        scanner.start(unicastHost: nil)
        lanScanner.onUpdate = merge
        lanScanner.onFinish = { stopScan() }
        lanScanner.start(duration: 5)
        scanning = true
    }

    private func stopScan() {
        scanner.stop()
        lanScanner.stop()
        scanning = false
    }

    private func pair() {
        guard let accountID = store.accountID, let pinValue = UInt32(pin) else { return }
        let address = host.trimmingCharacters(in: .whitespaces)
        errorText = nil
        pairing = true
        stopScan()

        let task = RegistrationTask()
        task.onLog = { print("[Pairing] \($0)") }
        self.task = task
        task.start(host: address, isPS5: isPS5, accountID: accountID, pin: pinValue) { result in
            pairing = false
            self.task = nil
            switch result {
            case .success(let keys):
                _ = store.add(host: address, keys: keys)
                remote.startWatchingConsoles()
                dismiss()
            case .failure(let error):
                if !(error is CancellationError) {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

/// Stream quality settings. They take effect when a session starts; while
/// streaming, "Apply Now" reconnects with the new settings.
struct RemoteSettingsView: View {
    @ObservedObject var settings: RemotePlaySettings
    var onApplyNow: (() -> Void)? = nil
    /// Opens the paywall. Inside a sheet, pass a closure that closes the
    /// sheet first; nil asks the main window directly.
    var onUpgrade: (() -> Void)? = nil
    @State private var showAbout = false

    var body: some View {
        Form {
            RemoteSettingsSections(settings: settings, onApplyNow: onApplyNow, onUpgrade: onUpgrade)

            // The app's only entry to licenses and source code (AGPL notices):
            // a menu item, like the About row of any settings screen.
            Section {
                Button {
                    showAbout = true
                } label: {
                    LabeledContent("About Couchport", value: AppInfo.versionString)
                        .contentShape(Rectangle())
                }
                .formRowButtonStyle()
            }
        }
        .sheet(isPresented: $showAbout) { AboutView() }
    }
}

/// The settings as Form sections, so they can sit inside another Form
/// (theater panels). `compact` uses segmented pickers only: menu pickers
/// do not present reliably inside a RealityView attachment.
struct RemoteSettingsSections: View {
    @ObservedObject var settings: RemotePlaySettings
    var onApplyNow: (() -> Void)? = nil
    var compact = false
    var onUpgrade: (() -> Void)? = nil
    @ObservedObject private var store = PurchaseManager.shared

    static let bitrates: [Int] = [0, 5_000, 10_000, 15_000, 20_000, 30_000, 40_000, 50_000]

    private var bitrates: [Int] { store.isPro ? Self.bitrates : FreeTier.bitrates }

    var body: some View {
        Section {
            if !store.isPro {
                ProUpsellRow(title: "Unlock 1080p, HDR and every bitrate with Pro", onUpgrade: onUpgrade)
            }
            Picker("Resolution", selection: $settings.resolution) {
                Text("720p").tag(720)
                if store.isPro {
                    Text("1080p").tag(1080)
                }
            }
            .pickerStyle(.segmented)
            Picker("Frame Rate", selection: $settings.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)
            Toggle("HEVC (PS5 only)", isOn: $settings.useHEVC)
            Toggle(isOn: $settings.hdr) {
                HStack(spacing: 8) {
                    Text("HDR (10-bit)")
                    if !store.isPro { ProBadge() }
                }
            }
            .disabled(!settings.useHEVC || !store.isPro)
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bitrate")
                    Picker("Bitrate", selection: $settings.bitrateKbps) {
                        ForEach(bitrates, id: \.self) { kbps in
                            (kbps == 0 ? Text("Auto") : Text(verbatim: "\(kbps / 1000)")).tag(kbps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                Picker("Bitrate", selection: $settings.bitrateKbps) {
                    ForEach(bitrates, id: \.self) { kbps in
                        if kbps == 0 {
                            Text("Automatic").tag(kbps)
                        } else {
                            Text(verbatim: "\(kbps / 1000) Mbps").tag(kbps)
                        }
                    }
                }
            }
            if let onApplyNow {
                Button {
                    onApplyNow()
                } label: {
                    Label("Apply Now (Reconnect)", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text("Video")
        } footer: {
            Text("HDR needs HEVC and an HDR game; the picture is tone-mapped for the headset. 1080p is the highest resolution PS5 Remote Play sends. Above 30 Mbps is experimental: it needs a wired PS5 and strong 5 GHz or 6 GHz Wi-Fi, otherwise frames drop. HEVC looks better at the same bitrate.")
        }

        Section("Audio") {
            HStack {
                Image(systemName: "speaker.fill")
                AdaptiveSlider(value: $settings.volume, range: 0...1, step: 0.1,
                               valueText: { "\(Int(($0 * 100).rounded()))%" })
                Image(systemName: "speaker.wave.3.fill")
            }
        }

        Section {
            Toggle("Haptic Feedback", isOn: $settings.haptics)
            if settings.haptics {
                HStack {
                    Text("Strength")
                    AdaptiveSlider(value: $settings.hapticsStrength, range: 0.2...1.5, step: 0.1,
                                   valueText: { "\(Int(($0 * 100).rounded()))%" })
                    if !Platform.isTV {
                        Text(verbatim: "\(Int((settings.hapticsStrength * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Toggle("Adaptive Triggers", isOn: $settings.adaptiveTriggers)
            Toggle("Motion Controls (Gyro)", isOn: $settings.motion)
            Toggle("Swap ✕ and ○ (Confirm / Cancel)", isOn: $settings.swapConfirmCancel)
            Toggle("Swap □ and △", isOn: $settings.swapSquareTriangle)
        } header: {
            Text("Controller")
        } footer: {
            Text("DualSense haptics, adaptive triggers and the light bar follow the game. The touchpad is sent as touch input. Haptics and HDR apply on the next connection.")
                + Text(verbatim: " ")
                + Text("The button swaps apply right away to a connected controller, for example one with a Nintendo-style layout or a game that confirms with ○. The on-screen controller is never swapped.")
        }

        #if os(iOS)
        Section {
            Picker("Show", selection: $settings.touchControls) {
                ForEach(TouchControlsMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                }
            }
            HStack {
                Text("Opacity")
                Slider(value: $settings.touchOpacity, in: 0.2...1)
                Text(verbatim: "\(Int((settings.touchOpacity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            Toggle("Vibrate on Press", isOn: $settings.touchHaptics)
        } header: {
            Text("On-Screen Controller")
        } footer: {
            Text("Automatic shows the touch controller only when no game controller is connected. In portrait, and on iPhone Duo in tabletop pose, it sits under the picture; in landscape it floats over it. Double-tap a stick for L3 or R3. Drag on the touchpad strip to swipe, tap it to click.")
                + Text(verbatim: " ")
                + Text("With a controller that has no touchpad, Automatic shows just a touchpad.")
        }

        Section {
            Toggle("Picture in Picture", isOn: $settings.pictureInPicture)
            Toggle("Phone Motion (Gyro)", isOn: $settings.phoneMotion)
                .disabled(!settings.motion)
            Toggle("Reflection", isOn: $settings.tabletopReflection)
            Toggle("Water Ripples", isOn: $settings.waterRipples)
                .disabled(!settings.tabletopReflection)
        } header: {
            Text("iPhone & iPad")
        } footer: {
            Text("Picture in Picture keeps the game in a small window when you leave the app. Phone Motion uses the phone's gyro for aiming when your controller has none. Reflection turns the space under the picture into water that mirrors the game, in portrait and on iPhone Duo in tabletop pose. Tap it to make ripples.")
        }
        #endif
    }
}
