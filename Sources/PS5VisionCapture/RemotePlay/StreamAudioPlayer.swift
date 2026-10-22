import AVFAudio
import Foundation
import os

/// Plays the console's decoded PCM through an adaptive jitter buffer.
///
/// Remote Play audio arrives as ~10 ms Opus frames, and over Wi-Fi it comes in
/// bursts. The buffer starts playback only after `startThreshold`, rebuffers
/// after an underrun, fades in and out around gaps so they don't click, and
/// drops old audio only when latency runs past `maxLatency`.
///
/// All AVAudioSession / AVAudioEngine work runs on `audioQueue`, never on the
/// main thread (activating a session there can stall the UI).
final class StreamAudioPlayer {
    private let audioQueue = DispatchQueue(label: "RemotePlay.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sessionActive = false

    private struct Ring {
        var buffer: [Float] = []
        var read = 0
        var write = 0
        var count = 0
        var channels = 2
        var primed = false
        var fadeIn = false          // apply a fade-in ramp on the next render
        // Thresholds in samples (frames × channels).
        var startThreshold = 0
        var maxLatency = 0
        var trimTarget = 0
        // Adaptive start threshold: grows after underruns, shrinks when stable.
        var underruns = 0
        var stableRenders = 0
        var baseStart = 0
        var maxStart = 0
    }
    private let ring = OSAllocatedUnfairLock(initialState: Ring())

    var volume: Float = 1 {
        didSet {
            let v = volume
            audioQueue.async { [engine] in engine.mainMixerNode.outputVolume = v }
        }
    }

    /// Called from the library thread when the stream's format is known.
    func configure(channels: Int, sampleRate: Int) {
        audioQueue.async { [self] in
            teardownEngine()
            let ch = max(1, channels)
            let rate = Double(sampleRate)
            let perMs = rate / 1000.0 * Double(ch)
            ring.withLockUnchecked {
                var r = Ring(buffer: [Float](repeating: 0, count: Int(rate) * ch * 2))  // 2 s
                r.channels = ch
                r.baseStart = Int(perMs * 60)       // 60 ms before first sound
                r.maxStart = Int(perMs * 160)       // up to 160 ms on a bad network
                r.startThreshold = r.baseStart
                r.maxLatency = Int(perMs * 300)     // past 300 ms ...
                r.trimTarget = Int(perMs * 150)     // ... drop back to 150 ms
                $0 = r
            }
            startEngine(channels: ch, sampleRate: rate)
        }
    }

    /// Interleaved Int16 from the library thread.
    func enqueue(_ pcm: UnsafeBufferPointer<Int16>) {
        ring.withLockUnchecked { r in
            let cap = r.buffer.count
            guard cap > 0 else { return }
            for s in pcm {
                r.buffer[r.write] = Float(s) * (1.0 / 32768.0)
                r.write = (r.write + 1) % cap
                if r.count < cap { r.count += 1 } else { r.read = (r.read + 1) % cap }
            }
            if r.count > r.maxLatency {
                // Drop whole frames only, so channels stay aligned.
                var drop = r.count - r.trimTarget
                drop -= drop % r.channels
                r.read = (r.read + drop) % cap
                r.count -= drop
                r.fadeIn = true
            }
            if !r.primed && r.count >= r.startThreshold {
                r.primed = true
                r.fadeIn = true
            }
        }
    }

    func stop() {
        audioQueue.async { [self] in
            teardownEngine()
            ring.withLockUnchecked { $0 = Ring() }
            if sessionActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            }
        }
    }

    // MARK: - Engine (audioQueue only)

    private func teardownEngine() {
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
    }

    private func startEngine(channels: Int, sampleRate: Double) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setPreferredSampleRate(sampleRate)
            // 10 ms hardware buffer: low latency without starving the render thread.
            try? session.setPreferredIOBufferDuration(0.010)
            if !sessionActive {
                try session.setActive(true)
                sessionActive = true
            }
        } catch {
            print("[RemotePlay] audio session error: \(error)")
            return
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else { return }
        let node = AVAudioSourceNode(format: format) { [ring] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            ring.withLockUnchecked { r in
                let cap = r.buffer.count
                let ch = r.channels
                let outCh = min(ch, buffers.count)
                let available = (r.primed && cap > 0) ? r.count / ch : 0
                let n = min(frames, available)
                let underrun = r.primed && n < frames
                let fadeIn = r.fadeIn && n > 0
                let rampLen = max(1, min(n, 96))   // ~2 ms at 48 kHz

                for c in 0..<outCh {
                    guard let out = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<frames {
                        guard f < n else { out[f] = 0; continue }
                        var v = r.buffer[(r.read + f * ch + c) % cap]
                        if fadeIn && f < rampLen { v *= Float(f) / Float(rampLen) }
                        if underrun && f >= n - rampLen { v *= Float(n - f) / Float(rampLen) }
                        out[f] = v
                    }
                }
                // Silence any extra output channels.
                if buffers.count > outCh {
                    for c in outCh..<buffers.count {
                        buffers[c].mData?.initializeMemory(as: Float.self, repeating: 0, count: frames)
                    }
                }

                if n > 0 {
                    r.read = (r.read + n * ch) % cap
                    r.count -= n * ch
                    r.fadeIn = false
                }

                if underrun {
                    // Rebuffer, and wait a little longer next time.
                    r.primed = false
                    r.underruns += 1
                    r.stableRenders = 0
                    r.startThreshold = min(r.maxStart, r.startThreshold + r.baseStart / 2)
                } else if r.primed {
                    // ~10 s without an underrun: ease the threshold back down.
                    r.stableRenders += 1
                    if r.stableRenders > 1000 {
                        r.stableRenders = 0
                        r.startThreshold = max(r.baseStart, r.startThreshold - r.baseStart / 4)
                    }
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        sourceNode = node
        do {
            try engine.start()
        } catch {
            print("[RemotePlay] audio engine error: \(error)")
            engine.detach(node)
            sourceNode = nil
        }
    }
}
