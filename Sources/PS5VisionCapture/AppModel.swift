import Combine
import SwiftUI
import GameController

/// Top-level state: which source is playing and a single, source-agnostic
/// surface for the player, theater and control panels.
@MainActor
final class AppModel: ObservableObject {
    enum Source: Equatable {
        case capture
        case remote
    }

    /// nil = Home screen.
    @Published var activeSource: Source?

    /// Gamepad events that bypass UIKit focus. During Remote Play every
    /// controller input goes to the console, never to our buttons.
    #if os(visionOS)
    var gamepadEventsForUI: GCUIEventTypes {
        activeSource == .remote ? .gamepad : []
    }
    #endif

    let capture: CaptureManager
    let consoles: ConsoleStore
    let remote: RemotePlayManager
    let purchases = PurchaseManager.shared

    // MARK: Free tier

    /// Seconds of free play left in this session; nil for Pro or when idle.
    @Published private(set) var freeSecondsLeft: Int?
    /// Shows the "free time almost up" prompt.
    @Published var freeTimeWarning = false
    private var freeElapsed: TimeInterval = 0
    private var freeWarned = false
    private var freeTimer: Task<Void, Never>?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let capture = CaptureManager()
        let consoles = ConsoleStore()
        self.capture = capture
        self.consoles = consoles
        self.remote = RemotePlayManager(renderer: capture.metalRenderer, store: consoles,
                                        statistics: capture.statistics)

        // Re-render views that read through AppModel when either side changes.
        capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        remote.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        consoles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        purchases.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        // Once StoreKit confirms there is no Pro purchase, pull every
        // setting back inside the free tier. Pro removes the session limit.
        purchases.$isPro
            .combineLatest(purchases.$hasCheckedEntitlements)
            .receive(on: RunLoop.main)
            .sink { [weak self] isPro, checked in
                guard let self else { return }
                if isPro {
                    self.stopFreeTimer()
                    self.freeSecondsLeft = nil
                    self.freeTimeWarning = false
                } else if checked {
                    self.applyFreeTierLimits()
                    self.updateFreeTimer()
                }
            }
            .store(in: &cancellables)

        // A Remote Play session that ends on its own returns to Home.
        remote.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.updateFreeTimer(state: state)
                guard self.activeSource == .remote else { return }
                if case .idle = state { self.activeSource = nil }
            }
            .store(in: &cancellables)
    }

    // MARK: - Free tier

    /// Resets anything a free user cannot use: 1080p, HDR, bitrates outside
    /// 10–20 Mbps, upscaling, sharpening and colour presets.
    func applyFreeTierLimits() {
        let s = remote.settings
        if s.resolution > FreeTier.maxResolution { s.resolution = FreeTier.maxResolution }
        let kbps = FreeTier.clampBitrate(s.bitrateKbps)
        if s.bitrateKbps != kbps { s.bitrateKbps = kbps }
        if s.hdr { s.hdr = false }

        let r = renderOptions
        if r.upscale != .off { r.upscale = .off }
        if r.sharpenEnabled { r.sharpenEnabled = false }
        if r.preset != .original { r.preset = .original }
    }

    /// Runs the free-session clock only while a Remote Play stream is live.
    /// Connecting, waking and reconnecting do not count.
    private func updateFreeTimer(state: RemotePlayManager.State? = nil) {
        let state = state ?? remote.state
        let counting = !purchases.isPro && activeSource == .remote && state == .streaming
        if counting {
            guard freeTimer == nil else { return }
            freeTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.tickFreeTimer()
                }
            }
        } else {
            stopFreeTimer()
        }
    }

    private func tickFreeTimer() {
        freeElapsed += 1
        let left = max(0, FreeTier.sessionLimit - freeElapsed)
        freeSecondsLeft = Int(left)
        if left <= FreeTier.warningLead && !freeWarned {
            freeWarned = true
            freeTimeWarning = true
        }
        if left <= 0 { endFreeSession() }
    }

    private func stopFreeTimer() {
        freeTimer?.cancel()
        freeTimer = nil
    }

    private func resetFreeSession() {
        stopFreeTimer()
        freeElapsed = 0
        freeWarned = false
        freeTimeWarning = false
        freeSecondsLeft = purchases.isPro ? nil : Int(FreeTier.sessionLimit)
    }

    /// Free time is up: stop the stream, go Home and offer Pro.
    private func endFreeSession() {
        stopFreeTimer()
        freeTimeWarning = false
        stopAndGoHome()
        purchases.requestPaywall(.timeUp)
    }

    var renderOptions: RenderOptions { capture.renderOptions }

    // MARK: - Source-agnostic surface

    var sourceTitle: String {
        switch activeSource {
        case .capture: return capture.selectedDeviceName
        case .remote: return remote.activeConsole?.nickname ?? String(localized: "Console")
        case nil: return "Couchport"
        }
    }

    var sourceIcon: String {
        activeSource == .remote ? "wifi" : "cable.connector"
    }

    var formatText: String {
        activeSource == .remote ? remote.formatDescription : capture.formatDescription
    }

    var rateText: String {
        activeSource == .remote ? remote.measuredFrameRate : capture.measuredFrameRate
    }

    var audioText: String {
        switch activeSource {
        case .remote: return remote.state == .streaming ? String(localized: "Stream audio") : "—"
        case .capture: return capture.audioMonitor.isMonitoring ? capture.audioMonitor.inputName : String(localized: "No audio")
        case nil: return "—"
        }
    }

    var statusMessage: String {
        activeSource == .remote ? remote.statusMessage : capture.statusMessage
    }

    var isRunning: Bool {
        switch activeSource {
        case .capture: return capture.isRunning
        case .remote: return remote.state.isActive
        case nil: return false
        }
    }

    /// Shows the "No Video" overlay over the player.
    var showsIdleOverlay: Bool {
        switch activeSource {
        case .capture: return capture.status == .idle || capture.status == .failed
        case .remote: return remote.state != .streaming
        case nil: return true
        }
    }

    var overlayTitle: String {
        switch activeSource {
        case .remote:
            switch remote.state {
            case .waking: return "Waking Console"
            case .connecting: return "Connecting"
            case .failed: return "Connection Failed"
            default: return "No Video"
            }
        default:
            return capture.status.title
        }
    }

    // MARK: - Actions

    func playCapture() {
        guard purchases.isPro else {
            purchases.requestPaywall(.capture)
            return
        }
        if remote.state.isActive { remote.stop() }
        activeSource = .capture
        Task { await capture.requestAccessAndStart() }
    }

    func play(_ console: PSConsole) {
        if capture.isRunning { capture.stop() }
        consoles.markPlayed(console)
        resetFreeSession()
        activeSource = .remote
        remote.start(console)
    }

    /// Stop the stream and go back to Home.
    func stopAndGoHome() {
        switch activeSource {
        case .capture: capture.stop()
        case .remote: remote.stop()
        case nil: break
        }
        activeSource = nil
        stopFreeTimer()
        freeSecondsLeft = nil
        freeTimeWarning = false
    }

    /// The theater's Start/Stop button: stop goes home, start resumes.
    func toggleRunning() {
        switch activeSource {
        case .capture:
            capture.toggleRunning()
        case .remote:
            if remote.state.isActive {
                remote.stop()
            } else if let console = remote.activeConsole ?? consoles.consoles.first {
                remote.start(console)
            }
        case nil:
            break
        }
    }
}
