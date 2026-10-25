import CoreHaptics
import Foundation
import GameController
#if os(iOS)
import CoreMotion
import UIKit
#endif

/// Reads the connected controller (DualSense, DualShock 4, Xbox, MFi) via
/// GameController and forwards PlayStation-mapped state to the session:
/// buttons, sticks, triggers, touchpad fingers and motion (gyro aiming).
/// Console feedback (haptics, rumble, adaptive triggers, light bar) goes back
/// to the controller through `ControllerFeedback`.
@MainActor
final class GamepadBridge: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var isDualSense = false
    /// A hardware controller is attached. The on-screen controller shows
    /// itself automatically when this is false (iPhone / iPad).
    @Published private(set) var hasPhysicalController = false

    /// Called with every state change.
    var onState: ((GamepadSnapshot) -> Void)?

    /// Send gyro/accelerometer to the console (motion aiming).
    var motionEnabled = true { didSet { configureMotion() } }

    #if os(iOS)
    /// Use the phone's own gyro when the controller has none (or there is
    /// no controller and the on-screen one is used).
    var phoneMotionEnabled = true { didSet { updatePhoneMotion() } }
    private let motionManager = CMMotionManager()
    private var phoneMotionRunning = false
    private var interfaceOrientation: UIInterfaceOrientation = .landscapeRight
    #endif

    /// Swap ✕/○ (confirm / cancel) and □/△ on the hardware controller.
    /// For controllers with a Nintendo-style layout, or games that use ○ to
    /// confirm. The on-screen controller is never swapped: what you see is
    /// what is sent.
    var swapConfirmCancel = false { didSet { if swapConfirmCancel != oldValue { onState?(output) } } }
    var swapSquareTriangle = false { didSet { if swapSquareTriangle != oldValue { onState?(output) } } }

    /// tvOS keeps the controller's Home (PS) button for the system, so on
    /// Apple TV holding L3 + R3 together for `psComboHold` seconds sends the
    /// PS button instead (L3/R3 are released to the console while it is held).
    var psButtonComboEnabled = Platform.isTV
    nonisolated static let psComboHold: Double = 0.5
    private var psComboTask: Task<Void, Never>?
    private var psComboActive = false

    let feedback = ControllerFeedback()

    private var observers: [NSObjectProtocol] = []
    private var current: GCController?
    private var last = GamepadSnapshot()          // hardware controller
    private var virtualPad = GamepadSnapshot()    // on-screen controller
    private var heartbeat: Timer?
    private var lastMotionSend: TimeInterval = 0

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attachBestController() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attachBestController() }
        })
        GCController.startWirelessControllerDiscovery {}
        attachBestController()

        // Re-send the state periodically: the console treats silence as idle
        // and a lost UDP packet would otherwise leave a stuck button.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onState?(self.output)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        #if os(iOS)
        updatePhoneMotion()
        #endif
    }

    func stop() {
        #if os(iOS)
        stopPhoneMotion()
        #endif
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        heartbeat?.invalidate()
        heartbeat = nil
        GCController.stopWirelessControllerDiscovery()
        detach(current)
        current = nil
        feedback.attach(nil)
        psComboTask?.cancel()
        psComboTask = nil
        psComboActive = false
        hasPhysicalController = false
        last = GamepadSnapshot()
        virtualPad = GamepadSnapshot()
        onState?(last)
    }

    // MARK: - Input

    /// Only real game controllers count. Anything a keyboard, mouse or
    /// remote (the Siri Remote included) exposes through GameController is
    /// ignored, so the on-screen controller isn't hidden by a non-controller
    /// device and the Siri Remote never drives the console.
    static func gamepads() -> [GCController] {
        let ignored: Set<String> = [GCProductCategoryKeyboard, GCProductCategoryMouse,
                                    GCProductCategorySiriRemote1stGen, GCProductCategorySiriRemote2ndGen,
                                    GCProductCategoryUniversalElectronicsRemote, GCProductCategoryCoalescedRemote]
        return GCController.controllers().filter {
            $0.extendedGamepad != nil && !ignored.contains($0.productCategory)
        }
    }

    private func attachBestController() {
        let pads = Self.gamepads()
        let next = pads.first { $0.extendedGamepad is GCDualSenseGamepad } ?? pads.first
        guard next !== current else { return }
        detach(current)
        current = next
        hasPhysicalController = next != nil
        controllerName = next?.vendorName
        isDualSense = next?.extendedGamepad is GCDualSenseGamepad
        feedback.attach(next)
        #if os(iOS)
        updatePhoneMotion()
        #endif
        guard let pad = next?.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            let snapshot = Self.snapshot(of: gamepad)
            Task { @MainActor in self?.merge(snapshot) }
        }
        configureMotion()
    }

    // MARK: - On-screen controller

    /// State from the touch controller. Merged with the hardware controller,
    /// so both can be used at once.
    func setVirtual(_ snapshot: GamepadSnapshot) {
        guard snapshot != virtualPad else { return }
        virtualPad = snapshot
        onState?(output)
    }

    /// Hardware OR touch: buttons are OR-ed, triggers take the larger value,
    /// a stick or touchpad finger from the touch controller wins while held.
    private var output: GamepadSnapshot {
        var s = last
        if psComboActive {
            s.buttons &= ~Self.l3r3
            s.buttons |= Self.psBit
        }
        if swapConfirmCancel { s.buttons = Self.swapBits(s.buttons, 0, 1) }     // Cross ↔ Circle
        if swapSquareTriangle { s.buttons = Self.swapBits(s.buttons, 2, 3) }    // Square ↔ Triangle
        let v = virtualPad
        s.buttons |= v.buttons
        s.l2 = max(s.l2, v.l2)
        s.r2 = max(s.r2, v.r2)
        if v.leftX != 0 || v.leftY != 0 { s.leftX = v.leftX; s.leftY = v.leftY }
        if v.rightX != 0 || v.rightY != 0 { s.rightX = v.rightX; s.rightY = v.rightY }
        if let t = v.touch0 { s.touch0 = t }
        if let t = v.touch1 { s.touch1 = t }
        return s
    }

    nonisolated static func swapBits(_ value: UInt32, _ a: UInt32, _ b: UInt32) -> UInt32 {
        let bitA = (value >> a) & 1, bitB = (value >> b) & 1
        guard bitA != bitB else { return value }
        return value ^ ((1 << a) | (1 << b))
    }

    private func detach(_ controller: GCController?) {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller?.motion?.valueChangedHandler = nil
        if let motion = controller?.motion, motion.sensorsRequireManualActivation {
            motion.sensorsActive = false
        }
    }

    /// Keeps the latest motion sample; buttons/sticks come from `merge`.
    private func merge(_ snapshot: GamepadSnapshot) {
        var next = snapshot
        next.gyro = last.gyro
        next.accel = last.accel
        updatePSCombo(next.buttons)
        guard next != last else { return }
        last = next
        onState?(output)
    }

    // MARK: - PS button combo (tvOS)

    nonisolated static let l3r3: UInt32 = (1 << 10) | (1 << 11)
    nonisolated static let psBit: UInt32 = 1 << 15

    /// Starts the hold timer when L3 and R3 are both down; releasing either
    /// ends the PS press (the button change itself is sent by `merge`).
    private func updatePSCombo(_ buttons: UInt32) {
        guard psButtonComboEnabled, buttons & Self.l3r3 == Self.l3r3 else {
            psComboTask?.cancel()
            psComboTask = nil
            psComboActive = false
            return
        }
        guard psComboTask == nil, !psComboActive else { return }
        psComboTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.psComboHold))
            guard !Task.isCancelled, let self else { return }
            self.psComboTask = nil
            self.psComboActive = true
            self.onState?(self.output)
        }
    }

    private func configureMotion() {
        #if os(iOS)
        updatePhoneMotion()
        #endif
        guard let motion = current?.motion else { return }
        guard motionEnabled else {
            motion.valueChangedHandler = nil
            if motion.sensorsRequireManualActivation { motion.sensorsActive = false }
            last.gyro = nil
            last.accel = nil
            return
        }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        motion.valueChangedHandler = { [weak self] m in
            let sample = Self.motionSample(m)
            Task { @MainActor in self?.applyMotion(sample) }
        }
    }

    #if os(iOS)
    // MARK: - Phone motion

    /// Runs only during a stream (between start and stop), with motion on,
    /// and when the attached controller has no motion sensors of its own.
    private func updatePhoneMotion() {
        let want = heartbeat != nil && motionEnabled && phoneMotionEnabled
            && current?.motion == nil && motionManager.isDeviceMotionAvailable
        if want, !phoneMotionRunning {
            phoneMotionRunning = true
            refreshInterfaceOrientation()
            observers.append(NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshInterfaceOrientation() }
                })
            motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                guard let m else { return }
                MainActor.assumeIsolated {
                    guard let self, self.phoneMotionRunning else { return }
                    self.applyMotion(Self.phoneMotionSample(m, orientation: self.interfaceOrientation))
                }
            }
        } else if !want, phoneMotionRunning {
            stopPhoneMotion()
        }
    }

    private func stopPhoneMotion() {
        guard phoneMotionRunning else { return }
        phoneMotionRunning = false
        motionManager.stopDeviceMotionUpdates()
        if current?.motion == nil {
            last.gyro = nil
            last.accel = nil
        }
    }

    private func refreshInterfaceOrientation() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        if let o = scene?.effectiveGeometry.interfaceOrientation, o != .unknown {
            interfaceOrientation = o
        }
    }

    /// The phone is held like a controller: screen facing the player.
    /// PlayStation frame: +X = screen right, +Y = out of the screen (the
    /// controller's top face), +Z = toward the player, i.e. against the
    /// screen's "up". Device axes are mapped per interface orientation.
    /// Accelerometer: the console expects the reaction force (+Y at rest).
    nonisolated static func phoneMotionSample(_ m: CMDeviceMotion,
                                              orientation: UIInterfaceOrientation) -> (gyro: SIMD3<Float>, accel: SIMD3<Float>) {
        func frame(_ v: SIMD3<Double>) -> SIMD3<Float> {
            let right, up: Double
            switch orientation {
            case .landscapeRight: right = -v.y; up = v.x      // home indicator on the right
            case .landscapeLeft: right = v.y; up = -v.x
            case .portraitUpsideDown: right = -v.x; up = -v.y
            default: right = v.x; up = v.y
            }
            return SIMD3(Float(right), Float(v.z), Float(-up))
        }
        let r = m.rotationRate
        let g = m.gravity, a = m.userAcceleration
        let gyro = frame(SIMD3(r.x, r.y, r.z))
        let accel = frame(SIMD3(-(g.x + a.x), -(g.y + a.y), -(g.z + a.z)))
        return (gyro, accel)
    }
    #endif

    /// Motion arrives at up to ~250 Hz; the console samples at ~100 Hz.
    private func applyMotion(_ sample: (gyro: SIMD3<Float>, accel: SIMD3<Float>)) {
        last.gyro = sample.gyro
        last.accel = sample.accel
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMotionSend >= 1.0 / 120.0 else { return }
        lastMotionSend = now
        onState?(output)
    }

    /// GameController's controller frame is Z-up; PlayStation's is Y-up with
    /// +Z toward the player: PS(x, y, z) = GC(x, z, -y). GameController's
    /// acceleration points along gravity, the console expects the reaction
    /// force, hence the negation.
    nonisolated private static func motionSample(_ m: GCMotion) -> (gyro: SIMD3<Float>, accel: SIMD3<Float>) {
        let rr = m.rotationRate
        let ax, ay, az: Double
        if m.hasGravityAndUserAcceleration {
            ax = -(m.gravity.x + m.userAcceleration.x)
            ay = -(m.gravity.y + m.userAcceleration.y)
            az = -(m.gravity.z + m.userAcceleration.z)
        } else {
            ax = -m.acceleration.x
            ay = -m.acceleration.y
            az = -m.acceleration.z
        }
        return (SIMD3(Float(rr.x), Float(rr.z), Float(-rr.y)),
                SIMD3(Float(ax), Float(az), Float(-ay)))
    }

    nonisolated private static func snapshot(of pad: GCExtendedGamepad) -> GamepadSnapshot {
        var s = GamepadSnapshot()
        func set(_ pressed: Bool, _ bit: UInt32) { if pressed { s.buttons |= bit } }

        set(pad.buttonA.isPressed, 1 << 0)          // Cross
        set(pad.buttonB.isPressed, 1 << 1)          // Circle
        set(pad.buttonX.isPressed, 1 << 2)          // Square
        set(pad.buttonY.isPressed, 1 << 3)          // Triangle
        set(pad.dpad.left.isPressed, 1 << 4)
        set(pad.dpad.right.isPressed, 1 << 5)
        set(pad.dpad.up.isPressed, 1 << 6)
        set(pad.dpad.down.isPressed, 1 << 7)
        set(pad.leftShoulder.isPressed, 1 << 8)
        set(pad.rightShoulder.isPressed, 1 << 9)
        set(pad.leftThumbstickButton?.isPressed ?? false, 1 << 10)
        set(pad.rightThumbstickButton?.isPressed ?? false, 1 << 11)
        set(pad.buttonMenu.isPressed, 1 << 12)                 // Options
        set(pad.buttonOptions?.isPressed ?? false, 1 << 13)    // Create / Share
        if let ds = pad as? GCDualSenseGamepad {
            set(ds.touchpadButton.isPressed, 1 << 14)
            // GameController reports finger presence unreliably through
            // isTouched; a non-centred axis also means a finger is down.
            let p = ds.touchpadPrimary, q = ds.touchpadSecondary
            if ds.touchpadButton.isTouched || p.xAxis.value != 0 || p.yAxis.value != 0 {
                s.touch0 = touchPoint(p)
            }
            if q.xAxis.value != 0 || q.yAxis.value != 0 {
                s.touch1 = touchPoint(q)
            }
        } else if let ds4 = pad as? GCDualShockGamepad {
            set(ds4.touchpadButton.isPressed, 1 << 14)
            if let p = ds4.touchpadPrimary,
               ds4.touchpadButton.isTouched || p.xAxis.value != 0 || p.yAxis.value != 0 {
                s.touch0 = touchPoint(p)
            }
            if let q = ds4.touchpadSecondary,
               q.xAxis.value != 0 || q.yAxis.value != 0 {
                s.touch1 = touchPoint(q)
            }
        }
        set(pad.buttonHome?.isPressed ?? false, 1 << 15)       // PS (if the OS lets it through)

        s.l2 = UInt8(clamping: Int((pad.leftTrigger.value * 255).rounded()))
        s.r2 = UInt8(clamping: Int((pad.rightTrigger.value * 255).rounded()))
        // GameController: +y is up. PlayStation: +y is down.
        s.leftX = axis(pad.leftThumbstick.xAxis.value)
        s.leftY = axis(-pad.leftThumbstick.yAxis.value)
        s.rightX = axis(pad.rightThumbstick.xAxis.value)
        s.rightY = axis(-pad.rightThumbstick.yAxis.value)
        return s
    }

    /// Touchpad axes are -1...1 (y up); PS touch space is 1920 x 942 (y down).
    nonisolated private static func touchPoint(_ pad: GCControllerDirectionPad) -> SIMD2<UInt16> {
        let x = Int(((max(-1, min(1, pad.xAxis.value)) + 1) / 2 * 1919).rounded())
        let y = Int(((1 - max(-1, min(1, pad.yAxis.value))) / 2 * 941).rounded())
        return SIMD2(UInt16(clamping: x), UInt16(clamping: y))
    }

    nonisolated private static func axis(_ v: Float) -> Int16 {
        Int16(clamping: Int((max(-1, min(1, v)) * 32767).rounded()))
    }

    // MARK: - Feedback passthrough (kept for existing callers)

    func rumble(left: UInt8, right: UInt8) {
        feedback.rumble(left: left, right: right)
    }
}

/// Whether a real game controller is connected, for the "Connect a game
/// controller" prompt on Apple TV. Runs independently of a stream.
@MainActor
final class ControllerPresence: ObservableObject {
    static let shared = ControllerPresence()
    @Published private(set) var isConnected = false
    @Published private(set) var name: String?
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let pad = GamepadBridge.gamepads().first
        isConnected = pad != nil
        name = pad?.vendorName
    }
}

/// Plays what the console sends back to the controller. Thread-safe: every
/// call hops to one serial queue, so the haptics callback (a library thread)
/// never touches the main actor.
final class ControllerFeedback: @unchecked Sendable {
    /// User settings, read on the feedback queue.
    var hapticsEnabled = true
    var hapticsStrength: Float = 1
    var adaptiveTriggersEnabled = true

    private let queue = DispatchQueue(label: "RemotePlay.controllerFeedback", qos: .userInteractive)
    private var controller: GCController?
    private var channels: [HapticChannel] = []     // left, right (or one combined)
    private var rumbleChannel: HapticChannel?
    private var hapticsFrameCount = 0
    private var hapticsAccumulator = [Float](repeating: 0, count: 2)
    private var hapticsSharpAcc = [Float](repeating: 0, count: 2)

    func attach(_ controller: GCController?) {
        queue.async { [self] in
            resetTriggers()
            channels.forEach { $0.stop() }
            channels = []
            rumbleChannel?.stop()
            rumbleChannel = nil
            self.controller = controller
        }
    }

    // MARK: Haptics (PS5 haptic audio, 3 kHz stereo)

    /// Converts each 10 ms block of haptic audio into intensity and sharpness
    /// for the left and right actuators and updates two continuous haptic
    /// players. Updates go out every 20 ms, the rate CoreHaptics handles well.
    func haptics(_ pcm: UnsafeBufferPointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        // Measure on the calling thread (the buffer is only valid here).
        var peak: (Float, Float) = (0, 0)
        var crossings: (Int, Int) = (0, 0)
        var prev: (Int16, Int16) = (0, 0)
        for i in 0..<frames {
            let l = pcm[i * 2], r = pcm[i * 2 + 1]
            peak.0 = max(peak.0, Float(abs(Int32(l))) / 32767)
            peak.1 = max(peak.1, Float(abs(Int32(r))) / 32767)
            if (l >= 0) != (prev.0 >= 0) { crossings.0 += 1 }
            if (r >= 0) != (prev.1 >= 0) { crossings.1 += 1 }
            prev = (l, r)
        }
        // Zero crossings per sample: more crossings = higher frequency = sharper.
        let sharpL = min(1, Float(crossings.0) / Float(frames) * 1.5)
        let sharpR = min(1, Float(crossings.1) / Float(frames) * 1.5)
        let peakL = peak.0, peakR = peak.1
        queue.async { [self] in
            guard hapticsEnabled else { return }
            hapticsAccumulator[0] = max(hapticsAccumulator[0], peakL)
            hapticsAccumulator[1] = max(hapticsAccumulator[1], peakR)
            hapticsSharpAcc[0] = max(hapticsSharpAcc[0], sharpL)
            hapticsSharpAcc[1] = max(hapticsSharpAcc[1], sharpR)
            hapticsFrameCount += 1
            guard hapticsFrameCount >= 2 else { return }
            hapticsFrameCount = 0
            ensureChannels()
            if channels.count == 2 {
                channels[0].set(intensity: hapticsAccumulator[0] * hapticsStrength, sharpness: hapticsSharpAcc[0])
                channels[1].set(intensity: hapticsAccumulator[1] * hapticsStrength, sharpness: hapticsSharpAcc[1])
            } else if let only = channels.first {
                only.set(intensity: max(hapticsAccumulator[0], hapticsAccumulator[1]) * hapticsStrength,
                         sharpness: max(hapticsSharpAcc[0], hapticsSharpAcc[1]))
            }
            hapticsAccumulator = [0, 0]
            hapticsSharpAcc = [0, 0]
        }
    }

    private func ensureChannels() {
        guard channels.isEmpty, let haptics = controller?.haptics else { return }
        let localities = haptics.supportedLocalities
        if localities.contains(.leftHandle), localities.contains(.rightHandle) {
            channels = [HapticChannel(haptics: haptics, locality: .leftHandle),
                        HapticChannel(haptics: haptics, locality: .rightHandle)].compactMap { $0 }
        }
        if channels.count != 2 {
            channels = [HapticChannel(haptics: haptics, locality: .default)].compactMap { $0 }
        }
    }

    // MARK: Rumble (PS4, or PS5 when haptic audio is off)

    func rumble(left: UInt8, right: UInt8) {
        queue.async { [self] in
            guard hapticsEnabled else { return }
            if rumbleChannel == nil, let haptics = controller?.haptics {
                rumbleChannel = HapticChannel(haptics: haptics, locality: .default)
            }
            let intensity = Float(max(left, right)) / 255 * hapticsStrength
            let sharpness = Float(right) / 255 * 0.8 + 0.1   // high-frequency motor -> sharper
            rumbleChannel?.set(intensity: intensity, sharpness: sharpness)
        }
    }

    // MARK: Adaptive triggers

    func triggerEffects(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) {
        queue.async { [self] in
            guard adaptiveTriggersEnabled,
                  let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
            AdaptiveTriggerTranslator.apply(ds.leftTrigger, type: typeLeft, params: left)
            AdaptiveTriggerTranslator.apply(ds.rightTrigger, type: typeRight, params: right)
        }
    }

    func resetTriggers() {
        guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        ds.leftTrigger.setModeOff()
        ds.rightTrigger.setModeOff()
    }

    func setAdaptiveTriggersEnabled(_ enabled: Bool) {
        queue.async { [self] in
            adaptiveTriggersEnabled = enabled
            if !enabled { resetTriggers() }
        }
    }

    // MARK: Light bar

    func lightBar(red: UInt8, green: UInt8, blue: UInt8) {
        queue.async { [self] in
            controller?.light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255,
                                               blue: Float(blue) / 255)
        }
    }

    /// Stops all effects (session ended).
    func reset() {
        queue.async { [self] in
            channels.forEach { $0.set(intensity: 0, sharpness: 0.5) }
            rumbleChannel?.set(intensity: 0, sharpness: 0.5)
            resetTriggers()
        }
    }
}

/// One continuous, looping haptic player whose intensity and sharpness are
/// steered with dynamic parameters. Recreated if the engine stops.
private final class HapticChannel {
    private let engine: CHHapticEngine
    private var player: CHHapticAdvancedPatternPlayer?
    private var lastIntensity: Float = -1

    init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality) {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        self.engine = engine
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        engine.stoppedHandler = { [weak self] _ in self?.player = nil }
        engine.resetHandler = { [weak self] in self?.player = nil }
    }

    func set(intensity: Float, sharpness: Float) {
        let i = max(0, min(1, intensity))
        if i < 0.02 {
            // Silence: drop the player instead of streaming zeros.
            if lastIntensity > 0 {
                try? player?.sendParameters([
                    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)
                ], atTime: CHHapticTimeImmediate)
            }
            lastIntensity = 0
            return
        }
        do {
            if player == nil {
                try engine.start()
                let event = CHHapticEvent(eventType: .hapticContinuous,
                                          parameters: [
                                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                                          ],
                                          relativeTime: 0, duration: 30)
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let p = try engine.makeAdvancedPlayer(with: pattern)
                p.loopEnabled = true
                try p.start(atTime: CHHapticTimeImmediate)
                player = p
            }
            try player?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: i, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                         value: max(0, min(1, sharpness)), relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
            lastIntensity = i
        } catch {
            player = nil
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine.stop()
    }
}

/// Maps the console's raw DualSense trigger-effect bytes (mode + 10 params,
/// the layout of the DS5 HID output report) onto GameController's semantic
/// `GCDualSenseAdaptiveTrigger` modes. Modes Apple's API cannot express are
/// approximated by the nearest one, unknown modes switch the trigger off.
enum AdaptiveTriggerTranslator {
    static func apply(_ trigger: GCDualSenseAdaptiveTrigger, type: UInt8, params p: [UInt8]) {
        func b(_ i: Int) -> UInt8 { i < p.count ? p[i] : 0 }
        func n(_ v: UInt8) -> Float { Float(v) / 255 }

        switch type {
        case 0x01:  // simple feedback: start, strength
            let strength = n(b(1))
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeFeedbackWithStartPosition(n(b(0)), resistiveStrength: strength)
        case 0x02:  // simple weapon: start, end, strength
            let start = n(b(0))
            let end = max(n(b(1)), min(1, start + 0.1))
            let strength = n(b(2))
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case 0x06:  // simple vibration: start, amplitude, frequency
            let amplitude = n(b(1))
            guard amplitude > 0 else { trigger.setModeOff(); return }
            trigger.setModeVibrationWithStartPosition(n(b(0)), amplitude: amplitude,
                                                      frequency: max(0.05, n(b(2))))
        case 0x21:  // zoned feedback: 10-bit zone mask + 3-bit strengths
            guard let span = zones(p) else { trigger.setModeOff(); return }
            let strength = packedMax(p, from: 2)
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeFeedbackWithStartPosition(span.start, resistiveStrength: strength)
        case 0x22, 0x25:  // bow / weapon: start..end zones + strength
            guard let span = zones(p) else { trigger.setModeOff(); return }
            let strength = Float(b(2) & 0x7) / 7
            guard strength > 0 else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(span.start, endPosition: max(span.end, min(1, span.start + 0.1)),
                                                   resistiveStrength: strength)
        case 0x23, 0x26, 0x27:  // galloping / vibration / machine
            guard let span = zones(p) else { trigger.setModeOff(); return }
            let amplitude = packedMax(p, from: 2)
            guard amplitude > 0 else { trigger.setModeOff(); return }
            let freq = b(8) != 0 ? b(8) : b(9)
            trigger.setModeVibrationWithStartPosition(span.start, amplitude: amplitude,
                                                      frequency: max(0.08, n(freq)))
        default:    // 0x00 / 0x05 off, or a mode we cannot express
            trigger.setModeOff()
        }
    }

    /// First and last active zone of a 10-bit mask, as 0...1 positions.
    private static func zones(_ p: [UInt8]) -> (start: Float, end: Float)? {
        let mask = UInt16(p.count > 0 ? p[0] : 0) | (UInt16(p.count > 1 ? p[1] : 0) << 8)
        guard mask & 0x3FF != 0 else { return nil }
        let active = (0..<10).filter { mask & (1 << $0) != 0 }
        return (Float(active.first!) / 9, Float(active.last!) / 9)
    }

    /// Largest of the packed 3-bit zone values, as 0...1.
    private static func packedMax(_ p: [UInt8], from first: Int) -> Float {
        var acc: UInt32 = 0, bits: UInt32 = 0, best: UInt32 = 0
        for i in first..<min(p.count, first + 4) {
            acc |= UInt32(p[i]) << bits
            bits += 8
            while bits >= 3 {
                best = max(best, acc & 0x7)
                acc >>= 3
                bits -= 3
            }
        }
        return Float(best) / 7
    }
}
