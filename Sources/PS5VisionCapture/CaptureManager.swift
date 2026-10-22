@preconcurrency import AVFoundation
import Combine
import SwiftUI

/// A user-selectable capture format, describing one entry in the device's
/// `formats` array.
struct VideoFormatOption: Identifiable, Hashable {
    let id: Int          // index into the device's `formats` array
    let width: Int
    let height: Int
    let maxFrameRate: Double

    var label: String {
        "\(width)×\(height) @ \(Int(maxFrameRate.rounded())) fps"
    }
}

@MainActor
final class CaptureManager: ObservableObject {
    enum Status {
        case idle
        case requestingAccess
        case running
        case failed

        var title: String {
            switch self {
            case .idle:
                return "No Video"
            case .requestingAccess:
                return "Requesting Access"
            case .running:
                return "Running"
            case .failed:
                return "Capture Unavailable"
            }
        }
    }

    // Accessed from `sessionQueue`, off the main actor, so mark nonisolated.
    nonisolated let session = AVCaptureSession()
    nonisolated let metalRenderer: MetalVideoRenderer

    /// Live-tunable color / upscale settings shared with the renderer and UI.
    let renderOptions = RenderOptions()
    /// True if MetalFX spatial upscaling is usable on this device.
    let metalFXSupported = MetalVideoRenderer.metalFXSupported()
    /// Performance statistics for debugging (optional, exposed in UI).
    let statistics = RenderStatistics()
    /// HDMI audio from the capture card's separate USB Audio Class device,
    /// if it exposes one (visionOS has no capture-session audio path).
    let audioMonitor = AudioMonitor()

    /// True while the immersive theater space is actually presented. Shared on
    /// the capture manager (not a view's local @State) so it survives the main
    /// window being dismissed and recreated during a mode switch, and stays the
    /// single source of truth even if the space is closed by a system gesture.
    @Published var immersiveOpen = false

    @Published private(set) var status: Status = .idle
    @Published private(set) var statusMessage = String(localized: "Connect a 4K60 UVC HDMI capture card through the Developer Strap.")
    @Published private(set) var selectedDeviceName = String(localized: "No capture device")
    @Published private(set) var isRunning = false
    /// Active video resolution + the format's declared max frame rate,
    /// e.g. "3840×2160 · up to 60 fps".
    @Published private(set) var formatDescription = "—"
    /// Measured frame rate from frames actually delivered by the capture card.
    @Published private(set) var measuredFrameRate = "— fps"
    /// Presented output resolution after upscaling, e.g. "→ 3840×2160".
    @Published private(set) var outputDescription = "—"
    /// All capture formats the selected device exposes, for manual selection.
    @Published private(set) var availableFormats: [VideoFormatOption] = []
    /// Currently chosen format index, or `nil` for automatic selection.
    @Published private(set) var selectedFormatIndex: Int?

    private var optionsCancellable: AnyCancellable?

    private var frameRateTimer: Timer?
    /// User-chosen format index that overrides automatic selection; `nil` = auto.
    /// Mirrored into `formatOverride` for lock-free reads off the main actor.
    private var manualFormatIndex: Int? {
        didSet { formatOverride.value = manualFormatIndex }
    }
    /// Thread-safe mirror of `manualFormatIndex`, read from `sessionQueue`.
    nonisolated private let formatOverride = Locked<Int?>(nil)

    /// Preferred capture resolution/frame rate. The manager picks the closest
    /// supported format at or below this, favouring 3840×2160 @ 60 fps.
    nonisolated private let preferredWidth = 3840
    nonisolated private let preferredHeight = 2160
    nonisolated private let preferredFrameRate = 60.0

    nonisolated private let sessionQueue = DispatchQueue(label: "PS5VisionCapture.session")
    private var selectedDevice: AVCaptureDevice?
    /// KVO token that keeps `isRunning` in sync with the session's real state,
    /// which can flip to true slightly after `startRunning()` returns.
    private var runningObservation: NSKeyValueObservation?
    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        do {
            metalRenderer = try MetalVideoRenderer.make()
        } catch {
            // Fatal: the app cannot function without Metal. Show a clear error
            // to the user instead of crashing silently.
            fatalError("Metal renderer initialization failed: \(error.localizedDescription). " +
                      "Recovery: \((error as? MetalRendererError)?.recoverySuggestion ?? "Restart the device.")")
        }
        metalRenderer.attachStatistics(statistics)
        // Under memory pressure drop every cache the renderer can rebuild
        // (texture pool, theater copy, CV texture cache).
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [metalRenderer, statistics] _ in
            metalRenderer.releaseCachedResources()
            statistics.recordMemoryWarning()
            print(String(format: "[Memory] warning — footprint %.0f MB, caches released",
                         RenderStatistics.footprintMB()))
        }
        pushRenderOptions()
        // Published property streams emit after the new value is installed.
        // Observing objectWillChange here could send the previous value to the
        // renderer, making a control look selected without changing the image.
        let renderChanges: [AnyPublisher<Void, Never>] = [
            renderOptions.$flipHorizontal.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$flipVertical.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$colorMatrix.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$colorRange.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$upscale.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$sharpenEnabled.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$sharpenAmount.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$exposure.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$contrast.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$saturation.map { _ in () }.eraseToAnyPublisher(),
            renderOptions.$gamma.map { _ in () }.eraseToAnyPublisher()
        ]
        optionsCancellable = Publishers.MergeMany(renderChanges)
            .sink { [weak self] in self?.pushRenderOptions() }
    }

    /// Sends the current options to the renderer as a Sendable snapshot.
    private func pushRenderOptions() {
        let upscaleIndex: Int
        switch renderOptions.upscale {
        case .off: upscaleIndex = 0
        case .lanczos: upscaleIndex = 1
        case .metalFX: upscaleIndex = 2
        }
        var snapshot = MetalVideoRenderer.ColorParamsSnapshot()
        snapshot.color = renderOptions.colorParams()
        snapshot.upscale = upscaleIndex
        snapshot.sharpen = renderOptions.sharpenEnabled
        snapshot.sharpenAmount = renderOptions.sharpenAmount
        snapshot.targetWidth = renderOptions.targetWidth
        snapshot.targetHeight = renderOptions.targetHeight
        metalRenderer.updateOptions(snapshot)
    }

    func requestAccessAndStart() async {
        status = .requestingAccess
        statusMessage = String(localized: "Waiting for camera permission.")

        let videoGranted = await AVCaptureDevice.requestAccess(for: .video)
        guard videoGranted else {
            status = .failed
            statusMessage = String(localized: "Camera permission was denied. Enable it in Settings.")
            return
        }

        refreshDevices()
        start()
    }

    /// Asks for camera permission and scans for capture cards without
    /// starting the stream (Home screen).
    func prepare() async {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            status = .failed
            statusMessage = String(localized: "Camera permission was denied. Enable it in Settings.")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        refreshDevices()
    }

    /// True when a UVC device is plugged in (Home screen badge).
    var hasDevice: Bool { selectedDevice != nil }

    func refreshDevices() {
        let devices = Self.discoverExternalVideoDevices()
        selectedDevice = devices.first

        if let selectedDevice {
            selectedDeviceName = selectedDevice.localizedName
            statusMessage = String(localized: "Selected \(selectedDevice.localizedName). Press Start if preview is not running.")
            availableFormats = Self.formatOptions(for: selectedDevice)
        } else {
            selectedDeviceName = String(localized: "No capture device")
            status = .idle
            statusMessage = String(localized: "No UVC capture device found. Check Developer Strap, USB-C cable, capture card power, and PS5 HDCP.")
            availableFormats = []
            manualFormatIndex = nil
            selectedFormatIndex = nil
        }
    }

    /// Builds the user-facing format list from a device's `formats` array.
    /// Indices match the device array so a selection maps back directly.
    private static func formatOptions(for device: AVCaptureDevice) -> [VideoFormatOption] {
        // Collapse formats that differ only by pixel encoding (V/F range, YUY2,
        // etc.) into one entry per resolution+fps. The video/full range choice
        // is handled separately by the Color Range option in the shader.
        var seen = Set<String>()
        var options: [VideoFormatOption] = []
        for (index, format) in device.formats.enumerated() {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let key = "\(dims.width)x\(dims.height)@\(Int(fps.rounded()))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            options.append(VideoFormatOption(
                id: index,
                width: Int(dims.width),
                height: Int(dims.height),
                maxFrameRate: fps
            ))
        }
        return options
    }

    /// Selects a format manually (`nil` restores automatic selection) and
    /// re-applies it live if capture is running.
    func selectFormat(_ index: Int?) {
        manualFormatIndex = index
        selectedFormatIndex = index
        guard isRunning else { return }
        // Reconfigure on the session queue without tearing the session down.
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInputDevice() else { return }
            self.session.beginConfiguration()
            if let format = self.resolveFormat(for: device) {
                try? self.applyFormat(format, to: device)
            }
            self.session.commitConfiguration()
            self.publishFormatDescription(for: device)
        }
    }

    /// The device backing the session's current video input, if any.
    nonisolated private func currentInputDevice() -> AVCaptureDevice? {
        session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) }?
            .device
    }

    func toggleRunning() {
        isRunning ? stop() : start()
    }

    func start() {
        guard let selectedDevice else {
            refreshDevices()
            return
        }

        status = .requestingAccess
        statusMessage = String(localized: "Starting capture from \(selectedDevice.localizedName).")

        // Observe the session's real running state instead of reading it once
        // right after startRunning(), which can still be false at that point.
        observeRunningState()

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.configureSession(device: selectedDevice)
                self.session.startRunning()
            } catch {
                Task { @MainActor in
                    self.handleRunning(false)
                    self.status = .failed
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    /// Starts KVO on `session.isRunning` and reacts to each transition.
    private func observeRunningState() {
        runningObservation?.invalidate()
        runningObservation = session.observe(\.isRunning, options: [.initial, .new]) { [weak self] session, _ in
            let running = session.isRunning
            Task { @MainActor in self?.handleRunning(running) }
        }
    }

    /// Reflects the session's running state into UI and frame-rate monitoring.
    private func handleRunning(_ running: Bool) {
        isRunning = running
        if running {
            status = .running
            statusMessage = String(localized: "Preview is running. If the image is black, disable source HDCP/HDR/120Hz/VRR and retry.")
            startFrameRateMonitoring()
            statistics.reset()
            audioMonitor.start()
        } else if status != .failed {
            status = .idle
        }
    }

    func stop() {
        runningObservation?.invalidate()
        runningObservation = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            Task { @MainActor in
                self.audioMonitor.stop()
                self.metalRenderer.reset()
                self.stopFrameRateMonitoring()
                self.isRunning = false
                self.status = .idle
                self.statusMessage = String(localized: "Capture stopped.")
            }
        }
    }

    /// Polls the renderer for the real delivered frame rate once per second.
    private func startFrameRateMonitoring() {
        frameRateTimer?.invalidate()
        measuredFrameRate = String(localized: "measuring…")
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let fps = self.metalRenderer.sampleMeasuredFrameRate() {
                    self.measuredFrameRate = String(format: "%.0f fps", fps)
                }
                let size = self.metalRenderer.lastOutputSize()
                if size.width > 0 {
                    self.outputDescription = "→ \(Int(size.width))×\(Int(size.height))"
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameRateTimer = timer
    }

    private func stopFrameRateMonitoring() {
        frameRateTimer?.invalidate()
        frameRateTimer = nil
        measuredFrameRate = "— fps"
    }

    nonisolated private func configureSession(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // Video input.
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        // Select the video format: honour a manual choice, else auto (4K60).
        if let chosenFormat = resolveFormat(for: device) {
            try applyFormat(chosenFormat, to: device)
        }
        publishFormatDescription(for: device)

        // Video output.
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(metalRenderer, queue: sessionQueue)

        guard session.canAddOutput(videoOutput) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        // No audio: the visionOS capture audio path is API_UNAVAILABLE, so PS5
        // HDMI audio cannot be routed through AVCaptureSession here.
    }

    /// Returns the format to apply: the user's manual choice when valid,
    /// otherwise the automatic gaming pick.
    nonisolated private func resolveFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        if let index = formatOverride.value, device.formats.indices.contains(index) {
            return device.formats[index]
        }
        return selectBestFormat(for: device)
    }

    /// Chooses a capture format for gaming: correct aspect ratio first, then
    /// frame rate, then resolution.
    ///
    /// Some cards expose packed/anamorphic formats such as 1920×2160 (8:9),
    /// which stuff a 1080p signal into a non-16:9 buffer and show up stretched.
    /// Those are rejected up front. Among 16:9 formats, frame rate dominates
    /// (a high resolution at a low frame rate is unusable for gaming), and
    /// resolution is the final tie-breaker, never oversized past 4K.
    nonisolated private func selectBestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let targetAspect = 16.0 / 9.0
        // Common broadcast/console resolutions; prefer these over odd sizes.
        let standardHeights: Set<Int> = [720, 1080, 1440, 2160]
        var best: AVCaptureDevice.Format?
        var bestScore = -Double.greatestFiniteMagnitude

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let width = Int(dims.width)
            let height = Int(dims.height)
            guard width > 0, height > 0 else { continue }

            let aspect = Double(width) / Double(height)
            // Reject formats that aren't ~16:9 (e.g. anamorphic 1920×2160).
            guard abs(aspect - targetAspect) < 0.05 else { continue }

            let maxFrameRate = format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate).max() ?? 0

            // Frame rate dominates so no resolution gain outranks losing frames.
            let fpsScore = min(maxFrameRate, preferredFrameRate) * 1_000_000

            // Strongly prefer standard resolutions over odd 16:9 sizes like
            // 2048×1152, so the card isn't asked to rescale a standard input.
            let standardBonus = standardHeights.contains(height) ? 100_000.0 : 0

            // Resolution is the final tie-breaker. Clamp to the target area and
            // penalise going over the preferred dimensions.
            let area = Double(min(width, preferredWidth) * min(height, preferredHeight))
            let overshoot = Double(max(0, width - preferredWidth) + max(0, height - preferredHeight))

            let score = fpsScore + standardBonus + area / 100_000 - overshoot

            if score > bestScore {
                bestScore = score
                best = format
            }
        }
        // If nothing is 16:9 (unusual card), leave the device's current format
        // untouched rather than forcing a distorted one.
        return best
    }

    nonisolated private func applyFormat(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format

        // Lock frame duration to the preferred rate if the format supports it,
        // so we get a steady 60 fps rather than a variable rate.
        let supportsPreferredRate = format.videoSupportedFrameRateRanges.contains {
            $0.maxFrameRate >= preferredFrameRate && $0.minFrameRate <= preferredFrameRate
        }
        if supportsPreferredRate {
            let duration = CMTime(value: 1, timescale: CMTimeScale(preferredFrameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    nonisolated private func publishFormatDescription(for device: AVCaptureDevice) {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = device.activeFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate).max() ?? 0
        let text = "\(dims.width)×\(dims.height) · up to \(Int(fps.rounded())) fps"
        Task { @MainActor in self.formatDescription = text }
    }

    private static func discoverExternalVideoDevices() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .external
        ]

        #if os(visionOS)
        deviceTypes.append(.builtInWideAngleCamera)
        #endif

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        return discoverySession.devices.filter { device in
            device.deviceType == .external || device.localizedName.localizedCaseInsensitiveContains("capture")
        }
    }
}

private enum CaptureError: LocalizedError {
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return String(localized: "The selected UVC device cannot be added to the capture session.")
        case .cannotAddOutput:
            return String(localized: "The capture video output cannot be added to the session.")
        }
    }
}
