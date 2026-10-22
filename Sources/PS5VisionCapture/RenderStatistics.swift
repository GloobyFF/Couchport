import Foundation
import Metal
import os.lock

/// Performance statistics for the renderer and the Remote Play stream.
///
/// The render and decode threads only touch a lock-protected accumulator
/// (no per-frame `Task` hops to the main actor, which used to pile up when
/// the main thread was busy). A 1 Hz timer on the main actor publishes the
/// rolled-up values for the Stats panel.
@MainActor
final class RenderStatistics: ObservableObject {
    // Renderer
    @Published private(set) var averageGPUTime: Double = 0  // milliseconds
    @Published private(set) var droppedFrameCount: Int = 0
    @Published private(set) var totalFrameCount: Int = 0
    @Published private(set) var textureMemoryMB: Double = 0
    @Published private(set) var isMetalFXActive: Bool = false
    @Published private(set) var isLanczosActive: Bool = false

    // Process
    @Published private(set) var memoryFootprintMB: Double = 0
    @Published private(set) var memoryWarnings: Int = 0

    // Remote Play stream (zero while capturing from a UVC device)
    @Published private(set) var streamBitrateMbps: Double = 0
    @Published private(set) var averageDecodeTime: Double = 0      // ms
    @Published private(set) var frameJitter: Double = 0            // ms, std dev of frame interval
    @Published private(set) var framesLost: Int = 0
    @Published private(set) var decodeErrors: Int = 0
    @Published private(set) var keyframeRequests: Int = 0
    @Published private(set) var isStreamActive = false
    // Reported by the console / protocol layer
    @Published private(set) var consoleBitrateMbps: Double = 0
    @Published private(set) var rttMs: Double = 0
    @Published private(set) var packetLoss: Double = 0        // 0...1

    private let acc = Accumulator()
    private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Recording (any thread)

    nonisolated func recordGPUTime(_ milliseconds: Double) {
        acc.with { $0.gpuSum += milliseconds; $0.gpuCount += 1 }
    }

    nonisolated func recordDroppedFrame() {
        acc.with { $0.dropped += 1 }
    }

    nonisolated func recordFrame() {
        acc.with { $0.frames += 1 }
    }

    nonisolated func updateUpscalerState(metalFX: Bool, lanczos: Bool) {
        acc.with { $0.metalFX = metalFX; $0.lanczos = lanczos }
    }

    nonisolated func updateTextureMemory(_ bytes: Int) {
        acc.with { $0.textureBytes = bytes }
    }

    /// One received access unit: its size, how long the hardware decode took,
    /// the frames the network lost before it, and whether it decoded.
    nonisolated func recordStreamFrame(bytes: Int, decodeMs: Double, lost: Int, decoded: Bool) {
        let now = CACurrentMediaTimeShim()
        acc.with { a in
            a.streamBytes += bytes
            a.decodeSum += decodeMs
            a.decodeCount += 1
            a.lost += max(0, lost)
            if !decoded { a.decodeErrors += 1 }
            if a.lastArrival > 0 {
                let interval = (now - a.lastArrival) * 1000
                a.intervalSum += interval
                a.intervalSqSum += interval * interval
                a.intervalCount += 1
            }
            a.lastArrival = now
            a.streamActive = true
        }
    }

    nonisolated func recordKeyframeRequest() {
        acc.with { $0.keyframeRequests += 1 }
    }

    nonisolated func recordMemoryWarning() {
        acc.with { $0.memoryWarnings += 1 }
    }

    nonisolated func endStream() {
        acc.with { a in
            a.streamActive = false
            a.lastArrival = 0
        }
    }

    // MARK: - Publishing

    private func publish() {
        let a = acc.drain()
        if a.gpuCount > 0 { averageGPUTime = a.gpuSum / Double(a.gpuCount) }
        totalFrameCount += a.frames
        droppedFrameCount += a.dropped
        textureMemoryMB = Double(a.textureBytes) / (1024 * 1024)
        isMetalFXActive = a.metalFX
        isLanczosActive = a.lanczos
        memoryWarnings += a.memoryWarnings
        memoryFootprintMB = Self.footprintMB()

        isStreamActive = a.streamActive
        if a.streamActive {
            streamBitrateMbps = Double(a.streamBytes) * 8 / 1_000_000
            if a.decodeCount > 0 { averageDecodeTime = a.decodeSum / Double(a.decodeCount) }
            if a.intervalCount > 1 {
                let n = Double(a.intervalCount)
                let mean = a.intervalSum / n
                frameJitter = max(0, a.intervalSqSum / n - mean * mean).squareRoot()
            }
        } else {
            consoleBitrateMbps = 0
            rttMs = 0
            packetLoss = 0
            streamBitrateMbps = 0
            averageDecodeTime = 0
            frameJitter = 0
        }
        framesLost += a.lost
        decodeErrors += a.decodeErrors
        keyframeRequests += a.keyframeRequests
    }

    func updateConsoleMetrics(bitrateMbps: Double, rttMs: Double, packetLoss: Double) {
        consoleBitrateMbps = bitrateMbps
        self.rttMs = rttMs
        self.packetLoss = packetLoss
    }

    func reset() {
        _ = acc.drain()
        droppedFrameCount = 0
        totalFrameCount = 0
        averageGPUTime = 0
        framesLost = 0
        decodeErrors = 0
        keyframeRequests = 0
    }

    var droppedFrameRate: Double {
        guard totalFrameCount > 0 else { return 0 }
        return Double(droppedFrameCount) / Double(totalFrameCount) * 100
    }

    /// Physical memory footprint of the process, the number jetsam judges.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }
}

/// Lock-protected counters shared by the render, decode and main threads.
private final class Accumulator: @unchecked Sendable {
    struct Values {
        var gpuSum = 0.0, gpuCount = 0
        var frames = 0, dropped = 0
        var textureBytes = 0
        var metalFX = false, lanczos = false
        var memoryWarnings = 0
        var streamBytes = 0
        var decodeSum = 0.0, decodeCount = 0
        var lost = 0, decodeErrors = 0, keyframeRequests = 0
        var intervalSum = 0.0, intervalSqSum = 0.0, intervalCount = 0
        var lastArrival = 0.0
        var streamActive = false
    }

    private var values = Values()
    private var lock = os_unfair_lock()

    func with(_ body: (inout Values) -> Void) {
        os_unfair_lock_lock(&lock)
        body(&values)
        os_unfair_lock_unlock(&lock)
    }

    /// Returns the values and clears the per-interval sums. State that
    /// persists across intervals (flags, texture bytes, last arrival) stays.
    func drain() -> Values {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let out = values
        var next = Values()
        next.textureBytes = values.textureBytes
        next.metalFX = values.metalFX
        next.lanczos = values.lanczos
        next.lastArrival = values.lastArrival
        next.streamActive = values.streamActive
        values = next
        return out
    }
}

/// `CACurrentMediaTime` without importing QuartzCore into every caller.
@inline(__always)
private func CACurrentMediaTimeShim() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
