import AVFAudio
import Foundation

/// Best-effort monitor for HDMI audio exposed by a UVC capture card.
///
/// The visionOS `AVCaptureSession` audio path is `API_UNAVAILABLE(visionos)`,
/// so capture-card audio cannot be routed there. However, most HDMI capture
/// cards enumerate as *two* USB devices: a UVC video class and a separate USB
/// Audio Class (UAC) device. That audio device is reachable through the
/// completely independent `AVAudioSession` / `AVAudioEngine` stack, which is
/// available on visionOS.
///
/// This routes the selected USB audio input straight to the main mixer for
/// live monitoring. It runs on its own timebase, independent of the video
/// renderer, so slight A/V drift is possible — acceptable for personal testing.
@MainActor
final class AudioMonitor: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var inputName = String(localized: "No audio input")
    @Published private(set) var isMonitoring = false
    @Published var volume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private var isConfigured = false

    /// Starts live monitoring **only** if the capture card exposes a USB audio
    /// input. If no USB audio device is present, monitoring is not started —
    /// we must never fall back to the Vision Pro's built-in microphone, which
    /// would play room noise instead of PS5 audio. Never throws into the video
    /// path.
    func start() {
        guard !isMonitoring else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            let usbInput = try locateUSBAudioInput(in: session)

            guard let usbInput else {
                // No capture-card audio. Report the reason and stay silent.
                let names = (session.availableInputs ?? [])
                    .map(\.portType.rawValue)
                    .joined(separator: ", ")
                isAvailable = false
                isMonitoring = false
                inputName = names.isEmpty
                    ? String(localized: "No capture-card audio (no USB audio input found)")
                    : String(localized: "No USB audio; ignoring built-in inputs (\(names))")
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }

            try session.setPreferredInput(usbInput)
            try session.setActive(true)
            inputName = usbInput.portName
            isAvailable = true

            try configureEngineIfNeeded()
            if !engine.isRunning {
                try engine.start()
            }
            engine.mainMixerNode.outputVolume = volume
            isMonitoring = true
        } catch {
            isMonitoring = false
            isAvailable = false
            inputName = String(localized: "Audio unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.pause()
        isMonitoring = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func toggle() {
        isMonitoring ? stop() : start()
    }

    /// Configures the shared audio session for low-latency I/O and returns the
    /// capture card's USB audio input if one is enumerated, else `nil`.
    private func locateUSBAudioInput(in session: AVAudioSession) throws -> AVAudioSessionPortDescription? {
        #if os(tvOS)
        // Capture is a Vision Pro feature; tvOS has no .defaultToSpeaker.
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .mixWithOthers]
        #else
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        #endif
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        // Small buffer keeps monitoring latency low; ignore if the OS clamps it.
        try? session.setPreferredIOBufferDuration(0.005)
        // Activate briefly so availableInputs is populated with attached USB gear.
        try session.setActive(true)

        return session.availableInputs?.first { $0.portType == .usbAudio }
    }

    private func configureEngineIfNeeded() throws {
        guard !isConfigured else { return }
        let input = engine.inputNode
        let mixer = engine.mainMixerNode
        // Use the input's own hardware format to avoid a sample-rate mismatch.
        let format = input.inputFormat(forBus: 0)
        engine.connect(input, to: mixer, format: format)
        engine.prepare()
        isConfigured = true
    }
}
