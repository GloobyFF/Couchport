import Combine
import CoreVideo
import Foundation

/// User-tunable stream settings, persisted.
@MainActor
final class RemotePlaySettings: ObservableObject {
    @Published var resolution: Int { didSet { save() } }     // 720 / 1080
    @Published var fps: Int { didSet { save() } }            // 30 / 60
    @Published var useHEVC: Bool { didSet { save() } }
    @Published var bitrateKbps: Int { didSet { save() } }    // 0 = automatic
    @Published var volume: Float { didSet { save() } }
    @Published var hdr: Bool { didSet { save() } }                   // HEVC Main10 PQ
    @Published var haptics: Bool { didSet { save() } }               // DualSense haptics / rumble
    @Published var hapticsStrength: Float { didSet { save() } }      // 0...1.5
    @Published var adaptiveTriggers: Bool { didSet { save() } }
    @Published var motion: Bool { didSet { save() } }                // gyro aiming

    private let d = UserDefaults.standard

    init() {
        resolution = d.object(forKey: "rp.resolution") as? Int ?? 1080
        fps = d.object(forKey: "rp.fps") as? Int ?? 60
        useHEVC = d.object(forKey: "rp.hevc") as? Bool ?? true
        bitrateKbps = d.object(forKey: "rp.bitrate") as? Int ?? 0
        volume = d.object(forKey: "rp.volume") as? Float ?? 1
        hdr = d.object(forKey: "rp.hdr") as? Bool ?? false
        haptics = d.object(forKey: "rp.haptics") as? Bool ?? true
        hapticsStrength = d.object(forKey: "rp.hapticsStrength") as? Float ?? 1
        adaptiveTriggers = d.object(forKey: "rp.triggers") as? Bool ?? true
        motion = d.object(forKey: "rp.motion") as? Bool ?? true
    }

    private func save() {
        d.set(resolution, forKey: "rp.resolution")
        d.set(fps, forKey: "rp.fps")
        d.set(useHEVC, forKey: "rp.hevc")
        d.set(bitrateKbps, forKey: "rp.bitrate")
        d.set(volume, forKey: "rp.volume")
        d.set(hdr, forKey: "rp.hdr")
        d.set(haptics, forKey: "rp.haptics")
        d.set(hapticsStrength, forKey: "rp.hapticsStrength")
        d.set(adaptiveTriggers, forKey: "rp.triggers")
        d.set(motion, forKey: "rp.motion")
    }
}

/// Drives one Remote Play session: wake → connect → decode video into the
/// shared Metal renderer, play audio, forward the controller.
@MainActor
final class RemotePlayManager: ObservableObject {
    enum State: Equatable {
        case idle
        case waking
        case connecting
        case streaming
        case failed(String)

        var isActive: Bool {
            switch self {
            case .waking, .connecting, .streaming: return true
            default: return false
            }
        }
    }

    enum ConsoleStatus: Equatable { case ready, standby, offline, unknown }

    @Published private(set) var state: State = .idle
    @Published private(set) var activeConsole: PSConsole?
    @Published private(set) var statusMessage = ""
    @Published private(set) var formatDescription = "—"
    @Published private(set) var measuredFrameRate = "— fps"
    @Published private(set) var consoleStatus: [UUID: ConsoleStatus] = [:]
    @Published private(set) var runningApp: [UUID: String] = [:]
    /// Set when a console with a login passcode asks for it.
    @Published var pinRequest: PinRequest?

    struct PinRequest: Identifiable, Equatable {
        let id = UUID()
        let incorrect: Bool
    }

    let settings = RemotePlaySettings()
    let gamepad = GamepadBridge()

    private let renderer: MetalVideoRenderer
    private let store: ConsoleStore
    private var core: RemoteSessionCore?
    private var decoder: StreamVideoDecoder?
    private let audio = StreamAudioPlayer()
    private var statusWatchers: [UUID: DiscoveryWatcher] = [:]
    private var lastSeen: [UUID: Date] = [:]
    private var statsTimer: Timer?
    private var volumeCancellable: AnyCancellable?
    private var feedbackCancellables: [AnyCancellable] = []
    private var reconnectAttemptsLeft = 0
    /// When the last session was closed. The console keeps the old session
    /// for a few seconds and rejects a new one as "in use" meanwhile.
    private var lastSessionEnd: Date?
    private let statistics: RenderStatistics?
    /// Uptime (s) of the last decoded frame; written on the decode thread.
    private let lastFrameAt = AtomicValue<Double>(0)
    private var lastKeyframeRequest: Double = 0
    private var stallRecoveries = 0

    /// No picture for this long: ask the console for a keyframe (once a second).
    private let keyframeAfterStall: Double = 1.0
    /// Still no picture after this long: reconnect the session automatically.
    private let reconnectAfterStall: Double = 8.0

    init(renderer: MetalVideoRenderer, store: ConsoleStore, statistics: RenderStatistics? = nil) {
        self.renderer = renderer
        self.store = store
        self.statistics = statistics
        volumeCancellable = settings.$volume.sink { [audio] in audio.volume = $0 }
        let feedback = gamepad.feedback
        feedbackCancellables = [
            settings.$haptics.sink { feedback.hapticsEnabled = $0; if !$0 { feedback.reset() } },
            settings.$hapticsStrength.sink { feedback.hapticsStrength = $0 },
            settings.$adaptiveTriggers.sink { feedback.setAdaptiveTriggersEnabled($0) },
            settings.$motion.sink { [gamepad] in gamepad.motionEnabled = $0 }
        ]
    }

    var isAvailable: Bool { RemotePlayLibrary.isAvailable }

    // MARK: - Console status (Home screen)

    /// Polls each saved console so Home can show Ready / Rest mode / Offline.
    ///
    /// chiaki's discovery service reports only when its host list CHANGES
    /// (host appears, its state or name changes, or it stops answering for
    /// ~1.5 s), not on every ping. So a callback with the host is the state
    /// until the next callback; an empty list means it went away. A console
    /// that never answers within a few seconds of starting is offline.
    func startWatchingConsoles() {
        guard isAvailable else { return }
        for console in store.consoles where statusWatchers[console.id] == nil {
            let watcher = DiscoveryWatcher()
            let id = console.id
            if consoleStatus[id] == nil || consoleStatus[id] == .offline {
                consoleStatus[id] = .unknown
            }
            watcher.onUpdate = { [weak self, weak watcher] hosts in
                guard let self, let watcher, self.statusWatchers[id] === watcher else { return }
                self.lastSeen[id] = Date()
                if let host = hosts.first {
                    switch host.state {
                    case .ready: self.consoleStatus[id] = .ready
                    case .standby: self.consoleStatus[id] = .standby
                    case .unknown: self.consoleStatus[id] = .unknown
                    }
                    self.runningApp[id] = host.runningApp.isEmpty ? nil : host.runningApp
                } else {
                    self.consoleStatus[id] = .offline
                    self.runningApp[id] = nil
                }
            }
            watcher.start(unicastHost: console.host)
            statusWatchers[id] = watcher
            let startedAt = Date()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.statusWatchers[id] === watcher else { return }
                if (self.lastSeen[id] ?? .distantPast) < startedAt {
                    self.consoleStatus[id] = .offline
                }
            }
        }
        // Drop watchers of consoles that were forgotten.
        for id in statusWatchers.keys where !store.consoles.contains(where: { $0.id == id }) {
            statusWatchers[id]?.stop()
            statusWatchers[id] = nil
        }
    }

    func stopWatchingConsoles() {
        statusWatchers.values.forEach { $0.stop() }
        statusWatchers.removeAll()
    }

    func forget(_ console: PSConsole) {
        statusWatchers[console.id]?.stop()
        statusWatchers[console.id] = nil
        consoleStatus[console.id] = nil
        store.remove(console)
    }

    func wake(_ console: PSConsole) {
        guard let secrets = store.secrets(for: console) else { return }
        _ = RemotePlayLibrary.wake(host: console.host, registKey: secrets.registKey, isPS5: console.isPS5)
    }

    // MARK: - Session

    func start(_ console: PSConsole) {
        guard !state.isActive else { return }
        guard isAvailable else { fail(RemotePlayError.libraryMissing.localizedDescription); return }
        guard let secrets = store.secrets(for: console) else {
            fail(String(localized: "Pairing data for this console is missing. Remove it and pair again.")); return
        }
        guard let accountID = store.accountID else {
            fail(String(localized: "Sign in to PSN first (Add Console).")); return
        }
        activeConsole = console
        stopWatchingConsoles()

        Task {
            if consoleStatus[console.id] == .standby || consoleStatus[console.id] == .offline {
                state = .waking
                statusMessage = String(localized: "Waking \(console.nickname)…")
                _ = RemotePlayLibrary.wake(host: console.host, registKey: secrets.registKey, isPS5: console.isPS5)
                let ready = await waitUntilReady(console, timeout: 40)
                guard state == .waking else { return }   // cancelled
                if !ready {
                    fail(String(localized: "\(console.nickname) did not wake up. Enable \"Stay Connected to the Internet\" and \"Enable Turning On PS5 from Network\" in the console's power-saving settings."))
                    return
                }
            }
            if let end = lastSessionEnd {
                let wait = 4 - Date().timeIntervalSince(end)
                if wait > 0 {
                    state = .connecting
                    statusMessage = String(localized: "Connecting to \(console.nickname)…")
                    try? await Task.sleep(for: .seconds(wait))
                    guard state == .connecting, activeConsole?.id == console.id else { return }
                }
            }
            // One automatic retry if the console still reports the old session.
            reconnectAttemptsLeft = 1
            connect(console, secrets: secrets, accountID: accountID)
        }
    }

    private func connect(_ console: PSConsole, secrets: (registKey: Data, morning: Data), accountID: Data) {
        state = .connecting
        statusMessage = String(localized: "Connecting to \(console.nickname)…")

        // The free tier is enforced here too, whatever the saved settings say.
        let pro = PurchaseManager.shared.isPro
        let config = RemoteSessionConfiguration(
            host: console.host, isPS5: console.isPS5,
            registKey: secrets.registKey, morning: secrets.morning, accountID: accountID,
            resolution: pro ? settings.resolution : min(settings.resolution, FreeTier.maxResolution),
            fps: settings.fps,
            useHEVC: console.isPS5 && settings.useHEVC,
            hdr: pro && console.isPS5 && settings.useHEVC && settings.hdr,
            bitrateKbps: UInt32(pro ? settings.bitrateKbps : FreeTier.clampBitrate(settings.bitrateKbps)),
            haptics: settings.haptics)

        let decoder = StreamVideoDecoder(codec: config.useHEVC ? .hevc : .h264, tenBit: config.hdr)
        let renderer = self.renderer
        let lastFrameAt = self.lastFrameAt
        lastFrameAt.value = Self.now()
        decoder.onFrame = { pixelBuffer in
            lastFrameAt.value = Self.now()
            renderer.enqueue(pixelBuffer: pixelBuffer)
        }
        self.decoder = decoder

        let core = RemoteSessionCore()
        let audio = self.audio
        let token = ObjectIdentifier(core)
        let statistics = self.statistics
        let keyframeGate = KeyframeGate()
        core.onVideo = { buf, lost, _ in
            let start = Self.now()
            let decoded = decoder.decode(accessUnit: buf)
            statistics?.recordStreamFrame(bytes: buf.count, decodeMs: (Self.now() - start) * 1000,
                                          lost: Int(lost), decoded: decoded)
            // Returning false makes the console send a keyframe. While the
            // decoder waits for one, every frame fails; asking on each of
            // them floods the console, so ask at most every 500 ms.
            if decoded { return true }
            guard keyframeGate.allow(now: start) else { return true }
            statistics?.recordKeyframeRequest()
            return false
        }
        core.onAudioFormat = { channels, rate in audio.configure(channels: channels, sampleRate: rate) }
        core.onAudio = { pcm, _ in audio.enqueue(pcm) }
        let feedback = gamepad.feedback
        core.onHaptics = { pcm, frames in feedback.haptics(pcm, frames: frames) }
        core.onEvent = { [weak self] event in
            Task { @MainActor in
                // Ignore late events from a session we already closed (e.g.
                // the old session's quit arriving after a reconnect).
                guard let self, let current = self.core, ObjectIdentifier(current) == token else { return }
                self.handle(event)
            }
        }
        core.onLog = { level, message in
            #if DEBUG
            if level <= 2 { print("[RemotePlay] \(message)") }
            #endif
        }

        self.core = core
        do {
            try core.start(config)
        } catch {
            self.core = nil
            fail(error.localizedDescription)
            return
        }

        gamepad.onState = { [weak core] state in core?.send(state) }
        gamepad.start()
    }

    func stop() {
        reconnectAttemptsLeft = 0
        let wasActive = state.isActive
        state = .idle
        teardown()
        statusMessage = wasActive ? String(localized: "Disconnected.") : statusMessage
        activeConsole = nil
        startWatchingConsoles()
    }

    /// Restarts the session with the current settings. The console refuses a
    /// new session ("InvalidSessionId") while it is still closing the old
    /// one, so wait a few seconds, then retry once more if needed.
    func reconnect() {
        guard state == .streaming, let console = activeConsole,
              let secrets = store.secrets(for: console), let accountID = store.accountID else { return }
        teardown()
        state = .connecting
        statusMessage = String(localized: "Reconnecting to \(console.nickname)…")
        reconnectAttemptsLeft = 2
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard state == .connecting, activeConsole?.id == console.id else { return }
            connect(console, secrets: secrets, accountID: accountID)
        }
    }

    func submitLoginPin(_ pin: String) {
        core?.submitLoginPin(pin)
        pinRequest = nil
    }

    func pressPSButton() { core?.goHome() }
    func putConsoleToSleep() { core?.putConsoleToSleep() }

    private func handle(_ event: RemoteSessionEvent) {
        switch event {
        case .connected:
            reconnectAttemptsLeft = 0
            lastFrameAt.value = Self.now()
            state = .streaming
            let name = activeConsole?.nickname ?? String(localized: "Console")
            statusMessage = String(localized: "Streaming from \(name)")
            startStats()
        case .quit(_, let isError, let text):
            teardown()
            if isError, reconnectAttemptsLeft > 0, let console = activeConsole,
               let secrets = store.secrets(for: console), let accountID = store.accountID {
                reconnectAttemptsLeft -= 1
                state = .connecting
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    guard state == .connecting, activeConsole?.id == console.id else { return }
                    connect(console, secrets: secrets, accountID: accountID)
                }
                return
            }
            reconnectAttemptsLeft = 0
            activeConsole = nil
            if isError {
                fail(text.isEmpty ? "The session ended." : text)
            } else {
                state = .idle
                statusMessage = String(localized: "Session ended.")
            }
            startWatchingConsoles()
        case .loginPinRequested(let incorrect):
            pinRequest = PinRequest(incorrect: incorrect)
        case .rumble(let left, let right):
            gamepad.rumble(left: left, right: right)
        case .triggerEffects(let typeLeft, let left, let typeRight, let right):
            gamepad.feedback.triggerEffects(typeLeft: typeLeft, left: left, typeRight: typeRight, right: right)
        case .lightBar(let r, let g, let b):
            gamepad.feedback.lightBar(red: r, green: g, blue: b)
        case .nickname:
            break
        }
    }

    private func teardown() {
        if core != nil { lastSessionEnd = Date() }
        gamepad.feedback.reset()
        gamepad.stop()
        gamepad.onState = nil
        core?.close()
        core = nil
        decoder = nil      // the closing session still holds it until joined
        audio.stop()
        stopStats()
        statistics?.endStream()
        renderer.reset()
        renderer.releaseCachedResources()
        pinRequest = nil
    }

    private func fail(_ message: String) {
        state = .failed(message)
        statusMessage = message
    }

    private func waitUntilReady(_ console: PSConsole, timeout: TimeInterval) async -> Bool {
        let watcher = DiscoveryWatcher()
        var ready = false
        watcher.onUpdate = { hosts in if hosts.first?.state == .ready { ready = true } }
        watcher.start(unicastHost: console.host)
        defer { watcher.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && state == .waking {
            if ready { return true }
            try? await Task.sleep(for: .milliseconds(500))
            if Int(Date().timeIntervalSince1970) % 5 == 0, let s = store.secrets(for: console) {
                _ = RemotePlayLibrary.wake(host: console.host, registKey: s.registKey, isPS5: console.isPS5)
            }
        }
        return ready
    }

    // MARK: - Stats

    private func startStats() {
        stopStats()
        measuredFrameRate = String(localized: "measuring…")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let fps = self.renderer.sampleMeasuredFrameRate() {
                    self.measuredFrameRate = String(format: "%.0f fps", fps)
                }
                self.checkForStall()
                if let m = self.core?.metrics() {
                    self.statistics?.updateConsoleMetrics(bitrateMbps: m.bitrateMbps, rttMs: m.rttMs,
                                                          packetLoss: m.packetLoss)
                }
                if let d = self.decoder?.dimensions, d.width > 0 {
                    var codec = (self.activeConsole?.isPS5 ?? false) && self.settings.useHEVC ? "HEVC" : "H.264"
                    if codec == "HEVC" && self.settings.hdr { codec += " HDR" }
                    self.formatDescription = "\(d.width)×\(d.height) · \(codec)"
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    /// Recovers from a frozen picture (Wi-Fi loss, decoder reset after the
    /// app was backgrounded): first asks for a keyframe, then reconnects.
    private func checkForStall() {
        guard state == .streaming, pinRequest == nil, let core else { return }
        let now = Self.now()
        let stalled = now - lastFrameAt.value
        if stalled < keyframeAfterStall {
            stallRecoveries = 0          // picture is flowing again
        } else if stalled >= reconnectAfterStall {
            guard stallRecoveries < 2 else { return }   // give up; the user can Stop
            stallRecoveries += 1
            print(String(format: "[RemotePlay] no video for %.1f s, reconnecting", stalled))
            reconnect()
        } else if stalled >= keyframeAfterStall, now - lastKeyframeRequest >= 1 {
            lastKeyframeRequest = now
            statistics?.recordKeyframeRequest()
            core.requestKeyframe()
        }
    }

    nonisolated static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        measuredFrameRate = "— fps"
        formatDescription = "—"
    }
}

/// Rate-limits keyframe requests from the decode thread.
private final class KeyframeGate: @unchecked Sendable {
    private var last: Double = 0
    private let lock = NSLock()

    func allow(now: Double, interval: Double = 0.5) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}
