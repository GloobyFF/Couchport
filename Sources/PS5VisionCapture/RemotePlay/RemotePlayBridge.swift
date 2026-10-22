import Foundation
#if canImport(VPChiaki)
import VPChiaki
#endif

/// Swift face of the Remote Play protocol layer (ChiakiShim/vp_chiaki.h).
///
/// Everything above this file is protocol-agnostic. Phase 2 swaps the
/// implementation (clean-room Swift) behind these same types.
enum RemotePlayLibrary {
    /// False when the app was built without Frameworks/VPChiaki.xcframework.
    static var isAvailable: Bool {
        #if canImport(VPChiaki)
        return true
        #else
        return false
        #endif
    }

    private static let initOnce: Bool = {
        // A socket the console closed must return EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        #if canImport(VPChiaki)
        return vp_lib_init() == 0
        #else
        return false
        #endif
    }()

    @discardableResult
    static func initialize() -> Bool { initOnce }

    static func errorString(_ code: Int32) -> String {
        #if canImport(VPChiaki)
        return String(cString: vp_error_string(code))
        #else
        return "Remote Play library not built (error \(code))"
        #endif
    }

    /// Sends the PlayStation wake-up packet for a console in rest mode.
    static func wake(host: String, registKey: Data, isPS5: Bool) -> Bool {
        #if canImport(VPChiaki)
        initialize()
        guard registKey.count == 16 else { return false }
        return registKey.withUnsafeBytes { raw in
            vp_wakeup(host, raw.bindMemory(to: UInt8.self).baseAddress, isPS5) == 0
        }
        #else
        return false
        #endif
    }
}

enum RemotePlayError: LocalizedError {
    case libraryMissing
    case native(String)

    var errorDescription: String? {
        switch self {
        case .libraryMissing:
            return String(localized: "Remote Play is not built into this app. Run Tools/build_libchiaki_visionos.sh and rebuild.")
        case .native(let message):
            return message
        }
    }
}

// MARK: - Session

struct RemoteSessionConfiguration {
    var host: String
    var isPS5: Bool
    var registKey: Data      // 16 bytes
    var morning: Data        // 16 bytes
    var accountID: Data      // 8 bytes
    var resolution: Int      // 720 / 1080
    var fps: Int             // 30 / 60
    var useHEVC: Bool
    var hdr: Bool = false    // HEVC Main10 + PQ (PS5, HEVC only)
    var bitrateKbps: UInt32  // 0 = default
    var haptics: Bool = true // DualSense haptics audio stream (PS5)
}

struct GamepadSnapshot: Equatable {
    var buttons: UInt32 = 0
    var l2: UInt8 = 0
    var r2: UInt8 = 0
    var leftX: Int16 = 0, leftY: Int16 = 0
    var rightX: Int16 = 0, rightY: Int16 = 0
    /// Touchpad fingers in PS space (x 0...1919, y 0...941); nil = not touching.
    var touch0: SIMD2<UInt16>?
    var touch1: SIMD2<UInt16>?
    /// Motion in the PlayStation frame: rad/s and g. nil = no motion data.
    var gyro: SIMD3<Float>?
    var accel: SIMD3<Float>?
}

/// Console-side stream metrics read from the protocol layer.
struct RemoteStreamMetrics {
    var bitrateMbps: Double
    var rttMs: Double
    var packetLoss: Double
}

enum RemoteSessionEvent {
    case connected
    case quit(reason: Int, isError: Bool, text: String)
    case loginPinRequested(incorrect: Bool)
    case rumble(left: UInt8, right: UInt8)
    case nickname(String)
    /// DualSense adaptive-trigger effect: DS5 mode byte + 10 parameter bytes per side.
    case triggerEffects(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8])
    case lightBar(red: UInt8, green: UInt8, blue: UInt8)
}

/// Owns one native session. Callbacks fire on library threads; consumers hop
/// to their own queues. Keep a strong reference until `close()` completes.
final class RemoteSessionCore {
    var onEvent: ((RemoteSessionEvent) -> Void)?
    /// Annex-B access unit. Return false to request a keyframe.
    var onVideo: ((UnsafeBufferPointer<UInt8>, Int32, Bool) -> Bool)?
    var onAudioFormat: ((Int, Int) -> Void)?
    /// Interleaved Int16 PCM, frame count per channel.
    var onAudio: ((UnsafeBufferPointer<Int16>, Int) -> Void)?
    var onLog: ((Int, String) -> Void)?
    /// DualSense haptics: interleaved stereo Int16 at 3 kHz, frame count.
    var onHaptics: ((UnsafeBufferPointer<Int16>, Int) -> Void)?

    #if canImport(VPChiaki)
    private var handle: OpaquePointer?
    private var retainedSelf: Unmanaged<RemoteSessionCore>?
    #endif
    private var audioChannels = 2
    private let closeQueue = DispatchQueue(label: "RemotePlay.session.close")

    init() {}

    func start(_ config: RemoteSessionConfiguration) throws {
        #if canImport(VPChiaki)
        RemotePlayLibrary.initialize()
        var c = VPSessionConfig()
        c.ps5 = config.isPS5
        copy(config.registKey, into: &c.regist_key)
        copy(config.morning, into: &c.morning)
        copy(config.accountID, into: &c.psn_account_id)
        c.resolution = Int32(config.resolution)
        c.fps = Int32(config.fps)
        c.codec = config.useHEVC ? (config.hdr ? VP_CODEC_H265_HDR : VP_CODEC_H265) : VP_CODEC_H264
        c.bitrate_kbps = config.bitrateKbps

        c.event_cb = { eventPtr, user in
            guard let eventPtr, let user else { return }
            let core = Unmanaged<RemoteSessionCore>.fromOpaque(user).takeUnretainedValue()
            core.dispatch(eventPtr.pointee)
        }
        c.video_cb = { buf, size, lost, recovered, user in
            guard let buf, let user else { return true }
            let core = Unmanaged<RemoteSessionCore>.fromOpaque(user).takeUnretainedValue()
            return core.onVideo?(UnsafeBufferPointer(start: buf, count: size), lost, recovered) ?? true
        }
        c.audio_format_cb = { channels, rate, user in
            guard let user else { return }
            let core = Unmanaged<RemoteSessionCore>.fromOpaque(user).takeUnretainedValue()
            core.audioChannels = Int(channels)
            core.onAudioFormat?(Int(channels), Int(rate))
        }
        c.audio_frame_cb = { pcm, frames, user in
            guard let pcm, let user else { return }
            let core = Unmanaged<RemoteSessionCore>.fromOpaque(user).takeUnretainedValue()
            let count = frames * core.audioChannels
            core.onAudio?(UnsafeBufferPointer(start: pcm, count: count), frames)
        }
        c.log_cb = { level, message, user in
            guard let message, let user else { return }
            let core = Unmanaged<RemoteSessionCore>.fromOpaque(user).takeUnretainedValue()
            core.onLog?(Int(level), String(cString: message))
        }

        if config.haptics {
            c.haptics_cb = { pcm, frames, user in
                guard let pcm, let user else { return }
                let core = Unmanaged<RemoteSessionCore>.fromOpaque(user).takeUnretainedValue()
                core.onHaptics?(UnsafeBufferPointer(start: pcm, count: frames * 2), frames)
            }
        }

        let retained = Unmanaged.passRetained(self)
        c.user = retained.toOpaque()

        var error: Int32 = 0
        let created: OpaquePointer? = config.host.withCString { host in
            c.host = host       // the shim copies the string
            return vp_session_create(&c, &error)
        }
        guard let created else {
            retained.release()
            throw RemotePlayError.native(RemotePlayLibrary.errorString(error))
        }
        let startErr = vp_session_start(created)
        guard startErr == 0 else {
            vp_session_destroy(created)
            retained.release()
            throw RemotePlayError.native(RemotePlayLibrary.errorString(startErr))
        }
        handle = created
        retainedSelf = retained
        #else
        throw RemotePlayError.libraryMissing
        #endif
    }

    func send(_ pad: GamepadSnapshot) {
        #if canImport(VPChiaki)
        guard let handle else { return }
        var s = VPControllerState()
        s.buttons = pad.buttons
        s.l2 = pad.l2
        s.r2 = pad.r2
        s.left_x = pad.leftX
        s.left_y = pad.leftY
        s.right_x = pad.rightX
        s.right_y = pad.rightY
        s.touch_down = (pad.touch0 != nil, pad.touch1 != nil)
        s.touch_x = (pad.touch0?.x ?? 0, pad.touch1?.x ?? 0)
        s.touch_y = (pad.touch0?.y ?? 0, pad.touch1?.y ?? 0)
        if let g = pad.gyro, let a = pad.accel {
            s.has_motion = true
            s.gyro = (g.x, g.y, g.z)
            s.accel = (a.x, a.y, a.z)
        }
        _ = vp_session_set_controller(handle, &s)
        #endif
    }

    func submitLoginPin(_ pin: String) {
        #if canImport(VPChiaki)
        guard let handle else { return }
        _ = vp_session_set_login_pin(handle, pin)
        #endif
    }

    func metrics() -> RemoteStreamMetrics? {
        #if canImport(VPChiaki)
        guard let handle else { return nil }
        var st = VPStreamStats()
        guard vp_session_get_stats(handle, &st) == 0 else { return nil }
        return RemoteStreamMetrics(bitrateMbps: st.bitrate_mbps, rttMs: st.rtt_ms, packetLoss: st.packet_loss)
        #else
        return nil
        #endif
    }

    func requestKeyframe() {
        #if canImport(VPChiaki)
        guard let handle else { return }
        _ = vp_session_request_idr(handle)
        #endif
    }

    func goHome() {
        #if canImport(VPChiaki)
        guard let handle else { return }
        _ = vp_session_go_home(handle)
        #endif
    }

    func putConsoleToSleep() {
        #if canImport(VPChiaki)
        guard let handle else { return }
        _ = vp_session_sleep_console(handle)
        #endif
    }

    /// Stops and frees the session off the main thread (join blocks).
    func close(completion: (() -> Void)? = nil) {
        #if canImport(VPChiaki)
        guard let handle else { completion?(); return }
        let retained = retainedSelf
        self.handle = nil
        self.retainedSelf = nil
        vp_session_stop(handle)
        closeQueue.async {
            vp_session_destroy(handle)   // no callbacks after this returns
            retained?.release()
            DispatchQueue.main.async { completion?() }
        }
        #else
        completion?()
        #endif
    }

    #if canImport(VPChiaki)
    private func dispatch(_ e: VPEvent) {
        let event: RemoteSessionEvent
        switch e.type {
        case VP_EVENT_CONNECTED:
            event = .connected
        case VP_EVENT_QUIT:
            let text = e.quit_text.map { String(cString: $0) } ?? ""
            event = .quit(reason: Int(e.quit_reason), isError: e.quit_is_error, text: text)
        case VP_EVENT_LOGIN_PIN_REQUEST:
            event = .loginPinRequested(incorrect: e.pin_incorrect)
        case VP_EVENT_RUMBLE:
            event = .rumble(left: e.rumble_left, right: e.rumble_right)
        case VP_EVENT_NICKNAME:
            event = .nickname(e.nickname.map { String(cString: $0) } ?? "")
        case VP_EVENT_TRIGGER_EFFECTS:
            event = .triggerEffects(typeLeft: e.trigger_type_left,
                                    left: withUnsafeBytes(of: e.trigger_left) { Array($0) },
                                    typeRight: e.trigger_type_right,
                                    right: withUnsafeBytes(of: e.trigger_right) { Array($0) })
        case VP_EVENT_LED_COLOR:
            event = .lightBar(red: e.led_rgb.0, green: e.led_rgb.1, blue: e.led_rgb.2)
        default:
            return
        }
        onEvent?(event)
    }

    private func copy<T>(_ data: Data, into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { dst in
            let n = min(dst.count, data.count)
            data.prefix(n).withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<n]))
            }
        }
    }
    #endif
}

// MARK: - Registration

struct RegisteredConsoleKeys {
    var isPS5: Bool
    var nickname: String
    var registKey: Data
    var morning: Data
    var mac: Data
}

/// One pairing attempt with the 8-digit PIN shown on the console.
final class RegistrationTask {
    private let closeQueue = DispatchQueue(label: "RemotePlay.regist.close")
    #if canImport(VPChiaki)
    private var handle: OpaquePointer?
    private var retainedSelf: Unmanaged<RegistrationTask>?
    #endif
    private var completion: ((Result<RegisteredConsoleKeys, Error>) -> Void)?
    var onLog: ((String) -> Void)?

    func start(host: String, isPS5: Bool, accountID: Data, pin: UInt32,
               completion: @escaping (Result<RegisteredConsoleKeys, Error>) -> Void) {
        #if canImport(VPChiaki)
        RemotePlayLibrary.initialize()
        self.completion = completion
        let retained = Unmanaged.passRetained(self)
        var error: Int32 = 0
        let created: OpaquePointer? = accountID.withUnsafeBytes { raw in
            vp_regist_start(host, isPS5, false,
                            raw.bindMemory(to: UInt8.self).baseAddress, pin,
                            { result, hostPtr, user in
                                guard let user else { return }
                                let task = Unmanaged<RegistrationTask>.fromOpaque(user).takeUnretainedValue()
                                task.finish(result: result, host: hostPtr?.pointee)
                            },
                            { _, message, user in
                                guard let message, let user else { return }
                                let task = Unmanaged<RegistrationTask>.fromOpaque(user).takeUnretainedValue()
                                task.onLog?(String(cString: message))
                            },
                            retained.toOpaque(), &error)
        }
        guard let created else {
            retained.release()
            completion(.failure(RemotePlayError.native(RemotePlayLibrary.errorString(error))))
            self.completion = nil
            return
        }
        handle = created
        retainedSelf = retained
        #else
        completion(.failure(RemotePlayError.libraryMissing))
        #endif
    }

    func cancel() { tearDown() }

    #if canImport(VPChiaki)
    private func finish(result: VPRegistResult, host: VPRegisteredHost?) {
        let outcome: Result<RegisteredConsoleKeys, Error>
        if result == VP_REGIST_SUCCESS, var h = host {
            let nickname = withUnsafeBytes(of: &h.nickname) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: bytes.baseAddress!)
            }
            outcome = .success(RegisteredConsoleKeys(
                isPS5: h.ps5,
                nickname: nickname,
                registKey: withUnsafeBytes(of: h.regist_key) { Data($0) },
                morning: withUnsafeBytes(of: h.morning) { Data($0) },
                mac: withUnsafeBytes(of: h.mac) { Data($0) }))
        } else if result == VP_REGIST_CANCELED {
            outcome = .failure(CancellationError())
        } else {
            outcome = .failure(RemotePlayError.native(
                String(localized: "Pairing failed. Check the PIN, that the console is on the same network, and that the PSN account matches the one signed in on the PS5.")))
        }
        DispatchQueue.main.async {
            let completion = self.completion
            self.completion = nil
            self.tearDown()
            completion?(outcome)
        }
    }
    #endif

    /// Never call from inside a library callback (joins the worker thread).
    private func tearDown() {
        #if canImport(VPChiaki)
        guard let handle else { return }
        let retained = retainedSelf
        self.handle = nil
        self.retainedSelf = nil
        closeQueue.async {
            vp_regist_destroy(handle)
            retained?.release()
        }
        #endif
    }
}

// MARK: - Discovery

struct DiscoveredConsole: Identifiable, Hashable {
    enum State { case ready, standby, unknown }
    var id: String { hostID.isEmpty ? address : hostID }
    var address: String
    var name: String
    var hostID: String
    var runningApp: String
    var isPS5: Bool
    var state: State
}

/// Pings one console (unicast) or the whole LAN (broadcast, needs the
/// multicast entitlement) twice a second.
final class DiscoveryWatcher {
    var onUpdate: (([DiscoveredConsole]) -> Void)?
    #if canImport(VPChiaki)
    private var handle: OpaquePointer?
    private var retainedSelf: Unmanaged<DiscoveryWatcher>?
    #endif
    private let closeQueue = DispatchQueue(label: "RemotePlay.discovery.close")

    func start(unicastHost: String?) {
        #if canImport(VPChiaki)
        RemotePlayLibrary.initialize()
        stop()
        let retained = Unmanaged.passRetained(self)
        let cb: VPDiscoveryCallback = { hosts, count, user in
            guard let user else { return }
            let watcher = Unmanaged<DiscoveryWatcher>.fromOpaque(user).takeUnretainedValue()
            var list: [DiscoveredConsole] = []
            if let hosts {
                for i in 0..<count {
                    let h = hosts[i]
                    let state: DiscoveredConsole.State
                    switch h.state {
                    case VP_HOST_READY: state = .ready
                    case VP_HOST_STANDBY: state = .standby
                    default: state = .unknown
                    }
                    list.append(DiscoveredConsole(address: DiscoveryWatcher.cstr(h.host_addr),
                                                  name: DiscoveryWatcher.cstr(h.host_name),
                                                  hostID: DiscoveryWatcher.cstr(h.host_id),
                                                  runningApp: DiscoveryWatcher.cstr(h.running_app_name),
                                                  isPS5: h.ps5, state: state))
                }
            }
            DispatchQueue.main.async { watcher.onUpdate?(list) }
        }
        let created: OpaquePointer?
        if let unicastHost {
            created = unicastHost.withCString { vp_discovery_start($0, cb, nil, retained.toOpaque()) }
        } else {
            created = vp_discovery_start(nil, cb, nil, retained.toOpaque())
        }
        guard let created else { retained.release(); return }
        handle = created
        retainedSelf = retained
        #endif
    }

    func stop() {
        #if canImport(VPChiaki)
        guard let handle else { return }
        let retained = retainedSelf
        self.handle = nil
        self.retainedSelf = nil
        closeQueue.async {
            vp_discovery_destroy(handle)
            retained?.release()
        }
        #endif
    }

    static func cstr(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }
}
