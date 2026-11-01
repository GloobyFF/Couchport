import SwiftUI

#if os(tvOS)

/// Apple TV version of `AddConsoleView`: a full-screen two-column page.
/// Left: how to get the PIN, plus the iCloud note. Right: PSN account,
/// discovered consoles, manual IP, PIN and the Pair button.
/// Uses exactly the same scanner / store / registration calls as the
/// iOS / visionOS sheet.
struct TVAddConsoleView: View {
    @ObservedObject var remote: RemotePlayManager
    @ObservedObject var store: ConsoleStore
    @Environment(\.dismiss) private var dismiss

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

    /// Focus targets: the first discovered console, otherwise the account button.
    private enum Field: Hashable {
        case account
        case accountField
        case console(String)
        case scan
    }
    @FocusState private var focus: Field?
    @State private var autoFocusedConsole = false

    var body: some View {
        TVPage(title: "Add Console", onClose: close) {
            instructions
        } trailing: {
            accountCard
            consolesCard
            addressCard
            pinCard
            pairSection
        }
        .defaultFocus($focus, found.first.map { Field.console($0.id) } ?? .account)
        .onAppear {
            if store.consoles.isEmpty && !scanning { toggleScan() }
            if focus == nil { focus = .account }
        }
        .onChange(of: found) { _, list in
            // Move to the first console once it shows up, unless the user
            // has already moved somewhere else.
            guard !autoFocusedConsole, let first = list.first,
                  focus == nil || focus == .account else { return }
            autoFocusedConsole = true
            focus = .console(first.id)
        }
        .onDisappear {
            stopScan()
            task?.cancel()
        }
    }

    // MARK: - Left column

    @ViewBuilder
    private var instructions: some View {
        TVStep(number: 1, text: "On the PS5 open Settings › System › Remote Play and turn on Enable Remote Play.")
        TVStep(number: 2, text: "On the PS5 open Settings › System › Remote Play › Link Device. The PIN is valid for about 5 minutes.")
        TVStep(number: 3, text: "Choose your console on the right, enter the PIN and select Pair.")

        Label {
            Text("Consoles and the PSN account you paired on your iPhone, iPad or Apple Vision Pro appear here automatically through iCloud. Open Couchport there once, signed in to the same Apple Account.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "icloud")
        }
        .font(TVMetrics.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }

    // MARK: - Right column

    private var accountCard: some View {
        TVCard {
            HStack(alignment: .center, spacing: 24) {
                Image(systemName: store.accountIDBase64 == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 48))
                    .foregroundStyle(store.accountIDBase64 == nil ? Color.orange : Color.green)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 6) {
                    Text("PSN Account")
                        .font(TVMetrics.sectionTitle)
                    if let id = store.accountIDBase64 {
                        Text(verbatim: String(id.prefix(4)) + "••••••••")
                            .font(TVMetrics.body.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use the account signed in on the console.")
                            .font(TVMetrics.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Full width on its own row, so the label never gets squeezed.
            Button {
                showManualID.toggle()
                if showManualID { focus = .accountField }
            } label: {
                Label("Enter account ID manually", systemImage: "keyboard")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .account)

            if showManualID {
                HStack(spacing: 24) {
                    TextField("Base64 account ID, e.g. AbCdEfGhIjk=", text: $manualAccountID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .accountField)
                        .frame(maxWidth: .infinity)
                    Button("Save ID") {
                        do {
                            try store.setAccountID(base64: manualAccountID)
                            errorText = nil
                            showManualID = false
                            focus = .account
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .fixedSize()
                    .disabled(manualAccountID.isEmpty)
                }
                Text("The account ID is the 8-byte PSN user ID in base64 (12 characters ending in '='). chiaki-ng on a computer fills it in after you sign in to PSN in its settings.")
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var consolesCard: some View {
        TVCard {
            Text("Console")
                .font(TVMetrics.sectionTitle)

            ForEach(found) { console in
                Button {
                    host = console.address
                    isPS5 = console.isPS5
                } label: {
                    HStack(spacing: 20) {
                        Image(systemName: "gamecontroller.fill")
                            .font(TVMetrics.body)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: console.name.isEmpty ? console.address : console.name)
                                .font(TVMetrics.body)
                                .lineLimit(1)
                            Text(verbatim: (console.isPS5 ? "PS5" : "PS4") + " · " + console.address)
                                .font(TVMetrics.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 16)
                        if host == console.address {
                            Image(systemName: "checkmark.circle.fill")
                                .font(TVMetrics.body)
                                .foregroundStyle(Brand.blue)
                        }
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.card)
                .focused($focus, equals: .console(console.id))
            }

            if scanning && found.isEmpty {
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Searching this network…")
                        .font(TVMetrics.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                toggleScan()
            } label: {
                Label(LocalizedStringKey(scanning ? "Stop Searching" : (found.isEmpty ? "Search This Network" : "Rescan")),
                      systemImage: scanning ? "stop.circle" : "arrow.clockwise")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .scan)
        }
        .focusSection()
    }

    private var addressCard: some View {
        TVCard {
            HStack(spacing: 24) {
                TextField("Console IP address, e.g. 192.168.1.20", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity)
                Picker("Console", selection: $isPS5) {
                    Text(verbatim: "PS5").tag(true)
                    Text(verbatim: "PS4").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            Text("PS5: Settings › Network › Connection Status shows the IP address.")
                .font(TVMetrics.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pinCard: some View {
        TVCard {
            Text("Link Code")
                .font(TVMetrics.sectionTitle)
            TextField("8-digit PIN", text: $pin)
                .keyboardType(.numberPad)
                .font(.system(size: 40, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(8))
                }
        }
    }

    @ViewBuilder
    private var pairSection: some View {
        if let errorText {
            Label {
                Text(errorText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(TVMetrics.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Button {
            pair()
        } label: {
            HStack(spacing: 16) {
                if pairing { ProgressView() }
                Text(LocalizedStringKey(pairing ? "Pairing…" : "Pair"))
                    .lineLimit(1)
            }
            .font(TVMetrics.sectionTitle)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.blue)
        .disabled(!canPair)
    }

    // MARK: - Actions (same as AddConsoleView)

    private var canPair: Bool {
        store.accountID != nil && !host.trimmingCharacters(in: .whitespaces).isEmpty && pin.count == 8 && !pairing
    }

    private func close() {
        stopScan()
        task?.cancel()
        dismiss()
    }

    /// Unicast sweep of the /24 plus chiaki's broadcast discovery; results merge.
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

#endif
