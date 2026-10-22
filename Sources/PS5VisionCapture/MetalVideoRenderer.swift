@preconcurrency import AVFoundation
import Metal
import MetalKit
#if !targetEnvironment(simulator)
import MetalFX
#endif
import MetalPerformanceShaders
import QuartzCore

/// GPU video renderer: converts captured NV12 frames to RGB (with color
/// correction and grading), optionally upscales to 4K (Lanczos or MetalFX),
/// optionally sharpens, then presents to a `CAMetalLayer`.
///
/// Replaces the previous `AVSampleBufferDisplayLayer` path so color and
/// resolution processing can happen in a single GPU pipeline with minimal
/// added latency.
final class MetalVideoRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let convertPipeline: MTLComputePipelineState
    private let sharpenPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let texturePool: MetalTexturePool

    private weak var layer: CAMetalLayer?

    // Reused intermediate textures, managed by the texture pool.
    private var rgbTexture: MTLTexture?      // converted, native resolution
    private var scaledTexture: MTLTexture?   // upscaled to target
    private var sharpTexture: MTLTexture?    // after sharpen

    // Upscalers, lazily built for the current input/output sizes.
    #if !targetEnvironment(simulator)
    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerInputSize = CGSize.zero
    private var scalerOutputSize = CGSize.zero
    #endif
    private var lanczos: MPSImageLanczosScale?
    private var lanczosLastUsed: TimeInterval = 0

    private static let metalFXAvailable: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #endif
    }()

    /// Live options snapshot, updated from the main actor.
    private let options = Locked<ColorParamsSnapshot>(.init())

    // Frame-rate measurement: lock-free atomic counters.
    private let frameCounter = AtomicCounter()
    private let lastSampleTime = AtomicValue<TimeInterval>(CACurrentMediaTime())
    private let lastPresentedSize = AtomicValue<CGSize>(.zero)

    /// When true, each processed frame is also copied into a persistent
    /// `theaterTexture` that the immersive scene can read on the main actor.
    /// This decouples RealityKit's `LowLevelTexture` (which is @MainActor) from
    /// the background render thread.
    let theaterEnabled = Locked<Bool>(false)
    private let theaterLock = NSLock()
    private var theaterTexture: MTLTexture?   // persistent copy of latest frame
    /// sRGB view of `theaterTexture`. RealityKit's screen texture is
    /// bgra8Unorm_srgb, and a blit requires identical pixel formats.
    private var theaterTextureSRGB: MTLTexture?
    private let theaterGeneration = AtomicValue<Int>(0)

    /// At most this many frames are on the GPU at once. When the GPU (or the
    /// display) falls behind, new frames are dropped instead of queuing up:
    /// a queue holds decoder pixel buffers and grows memory without bound.
    private let inFlight = DispatchSemaphore(value: 3)

    /// Timer for periodic texture pool cleanup.
    private var poolPurgeTimer: Timer?

    /// Performance statistics exposed for debugging (optional).
    private weak var statistics: RenderStatistics?

    /// Exposes the device so the theater can create its own command queue.
    var metalDevice: MTLDevice { device }

    /// Attach a statistics collector for debugging. Call from the main actor.
    @MainActor
    func attachStatistics(_ stats: RenderStatistics) {
        statistics = stats
    }

    /// The latest processed frame for the theater, plus a generation counter so
    /// the reader can skip redundant blits. Returns nil until the first frame.
    func latestTheaterFrame() -> (texture: MTLTexture, generation: Int)? {
        theaterLock.lock(); defer { theaterLock.unlock() }
        guard let view = theaterTextureSRGB ?? theaterTexture else { return nil }
        return (view, theaterGeneration.value)
    }

    /// Builds a renderer, throwing detailed errors if Metal or the shaders are
    /// unavailable. Replaces the old silent `nil` return.
    static func make() throws -> MetalVideoRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRendererError.deviceUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueCreationFailed
        }
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else {
            throw MetalRendererError.shaderLibraryNotFound
        }
        guard let convertFn = library.makeFunction(name: "convertYCbCrToRGB") else {
            throw MetalRendererError.shaderFunctionNotFound("convertYCbCrToRGB")
        }
        guard let sharpenFn = library.makeFunction(name: "sharpen") else {
            throw MetalRendererError.shaderFunctionNotFound("sharpen")
        }

        let convert: MTLComputePipelineState
        let sharpen: MTLComputePipelineState

        do {
            convert = try device.makeComputePipelineState(function: convertFn)
        } catch {
            throw MetalRendererError.pipelineCompilationFailed(function: "convertYCbCrToRGB", underlying: error)
        }

        do {
            sharpen = try device.makeComputePipelineState(function: sharpenFn)
        } catch {
            throw MetalRendererError.pipelineCompilationFailed(function: "sharpen", underlying: error)
        }

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw MetalRendererError.textureCacheCreationFailed
        }

        return MetalVideoRenderer(device: device, queue: queue,
                                  convert: convert, sharpen: sharpen, cache: cache)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue,
                 convert: MTLComputePipelineState, sharpen: MTLComputePipelineState,
                 cache: CVMetalTextureCache) {
        self.device = device
        self.queue = queue
        self.convertPipeline = convert
        self.sharpenPipeline = sharpen
        self.textureCache = cache
        self.texturePool = MetalTexturePool(device: device)
        super.init()
        startPoolPurgeTimer()
    }

    deinit {
        poolPurgeTimer?.invalidate()
        texturePool.flush()
    }

    /// Starts a timer to periodically purge idle textures from the pool.
    private func startPoolPurgeTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.texturePool.purgeIdleTextures()
            self.purgeIdleLanczos()
            CVMetalTextureCacheFlush(self.textureCache, 0)
            if !self.theaterEnabled.value { self.releaseTheaterTexture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poolPurgeTimer = timer
    }

    /// Snapshot of options passed from the main actor to the render thread.
    struct ColorParamsSnapshot {
        var color = ColorParams()
        var upscale: Int = 0        // 0 off, 1 lanczos, 2 metalfx
        var sharpen = false
        var sharpenAmount: Float = 0.5
        var targetWidth = 3840
        var targetHeight = 2160
    }

    // MARK: - Public API

    func attach(to layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // The shader writes SDR, sRGB-encoded values. Declare that contract to
        // Core Animation so the window follows the same color-managed path as
        // the RealityKit theater texture.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = false
        self.layer = layer
    }

    /// Called from the main actor whenever the user changes options.
    func updateOptions(_ snapshot: ColorParamsSnapshot) {
        options.value = snapshot
    }

    /// Whether MetalFX spatial scaling is usable on this device at runtime.
    static func metalFXSupported() -> Bool {
        metalFXAvailable
    }

    /// Frees everything that can be rebuilt on the next frame. Called on a
    /// system memory warning and when a session stops.
    func releaseCachedResources() {
        texturePool.flush()
        CVMetalTextureCacheFlush(textureCache, 0)
        releaseTheaterTexture()
        // The Lanczos kernel is released by the idle purge; touching it here
        // could race a frame still rendering on the decode thread.
    }

    private func releaseTheaterTexture() {
        theaterLock.lock()
        theaterTexture = nil
        theaterTextureSRGB = nil
        theaterLock.unlock()
    }

    func reset() {
        _ = frameCounter.reset()
        lastSampleTime.value = CACurrentMediaTime()
    }

    /// Measured frames-per-second since the previous call.
    func sampleMeasuredFrameRate() -> Double? {
        let now = CACurrentMediaTime()
        let last = lastSampleTime.value
        let elapsed = now - last
        guard elapsed >= 0.25 else { return nil }
        let count = frameCounter.reset()
        lastSampleTime.value = now
        return count > 0 ? Double(count) / elapsed : nil
    }

    /// The resolution of the last frame actually presented (post-upscale).
    func lastOutputSize() -> CGSize {
        lastPresentedSize.value
    }

    // MARK: - Capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCounter.increment()
        statistics?.recordFrame()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        render(pixelBuffer: pixelBuffer)
    }

    // MARK: - Decoded-stream input (Remote Play)

    /// Feeds an NV12 (420v) frame from a non-capture source, e.g. the Remote
    /// Play hardware decoder. Same pipeline, stats and theater path as UVC.
    /// Call from one thread at a time (only one source runs at once).
    func enqueue(pixelBuffer: CVPixelBuffer) {
        frameCounter.increment()
        statistics?.recordFrame()
        render(pixelBuffer: pixelBuffer)
    }
}

// MARK: - Rendering

private extension MetalVideoRenderer {
    func render(pixelBuffer: CVPixelBuffer) {
        let snapshot = options.value

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return }

        // Drop the frame if the GPU is still busy with three earlier ones.
        guard inFlight.wait(timeout: .now()) == .success else {
            statistics?.recordDroppedFrame()
            return
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard case let (luma, lumaRef)? = makeTexture(pixelBuffer, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
              case let (chroma, chromaRef)? = makeTexture(pixelBuffer, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm),
              let rgb = ensureTexture(&rgbTexture, width: srcW, height: srcH,
                                      usage: [.shaderRead, .shaderWrite]),
              let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        // The CVMetalTextures (and through them the pixel buffer) must stay
        // alive until the GPU has finished reading them.
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime((lumaRef, chromaRef, pixelBuffer)) {}
            semaphore.signal()
        }

        // 1. Convert NV12 -> RGB at native resolution (color correction here).

        var color = snapshot.color
        Self.applyBufferColorInfo(pixelBuffer, tenBit: tenBit, to: &color)
        encodeConvert(commandBuffer, luma: luma, chroma: chroma, out: rgb, params: &color)

        var processed = rgb
        let usingMetalFX = snapshot.upscale == 2 && Self.metalFXAvailable
        let wantsUpscale = snapshot.upscale != 0
            && (snapshot.targetWidth > srcW || snapshot.targetHeight > srcH)

        // 2. Sharpen at NATIVE resolution, before upscaling. Cheaper (fewer
        //    pixels) and it feeds cleaner detail into the scaler instead of
        //    amplifying scaler artefacts. Skipped under MetalFX, whose spatial
        //    reconstruction already sharpens — stacking our pass on top would
        //    over-ring the edges.
        if snapshot.sharpen && !usingMetalFX,
           let sharp = ensureTexture(&sharpTexture,
                                     width: rgb.width, height: rgb.height,
                                     usage: [.shaderRead, .shaderWrite]) {
            encodeSharpen(commandBuffer, input: rgb, out: sharp,
                          amount: snapshot.sharpenAmount)
            processed = sharp
        }

        // 3. Upscale (or pass through) to produce the final texture.
        if wantsUpscale {
            let outW = snapshot.targetWidth
            let outH = snapshot.targetHeight
            if let scaled = ensureTexture(&scaledTexture, width: outW, height: outH,
                                          usage: [.shaderRead, .shaderWrite, .renderTarget]) {
                var encodedWithMetalFX = false
                #if !targetEnvironment(simulator)
                if usingMetalFX,
                   let scaler = ensureSpatialScaler(inW: srcW, inH: srcH,
                                                    outW: outW, outH: outH) {
                    scaler.colorTexture = rgb   // MetalFX consumes the un-sharpened native frame
                    scaler.outputTexture = scaled
                    scaler.encode(commandBuffer: commandBuffer)
                    encodedWithMetalFX = true
                }
                #endif

                if !encodedWithMetalFX {
                    let mps = ensureLanczos()
                    mps.encode(commandBuffer: commandBuffer,
                               sourceTexture: processed, destinationTexture: scaled)
                }
                processed = scaled
            }
        }

        let size = CGSize(width: processed.width, height: processed.height)
        lastPresentedSize.value = size

        if let stats = statistics {
            let textures: [MTLTexture?] = [rgbTexture, sharpTexture, scaledTexture, theaterTexture]
            let bytes = textures.reduce(0) { $0 + (($1?.width ?? 0) * ($1?.height ?? 0) * 4) }
            stats.updateTextureMemory(bytes)
        }

        // Track upscaler state for statistics (lock only, no main-actor hop).
        statistics?.updateUpscalerState(metalFX: usingMetalFX, lanczos: !usingMetalFX && wantsUpscale)

        // GPU timing: measure command buffer execution time.
        let startTime = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { [weak self] _ in
            let elapsed = (CACurrentMediaTime() - startTime) * 1000  // milliseconds
            self?.statistics?.recordGPUTime(elapsed)
        }

        // If theater mode is active, copy the processed frame into a persistent
        // texture the immersive scene reads on the main actor (decoupled from
        // this background thread and from texture reuse).
        if theaterEnabled.value {
            copyToTheaterTexture(processed, commandBuffer: commandBuffer)
        }

        // Present to the CAMetalLayer if we have one (window mode). In theater
        // mode the window may be dismissed, so just commit.
        if let layer {
            present(processed, to: layer, commandBuffer: commandBuffer)
        } else {
            commandBuffer.commit()
        }
    }

    /// Blits the processed frame into a persistent private texture, guarded by
    /// a lock so the main-actor theater reader gets a stable copy.
    private func copyToTheaterTexture(_ source: MTLTexture, commandBuffer: MTLCommandBuffer) {
        theaterLock.lock()
        if theaterTexture == nil
            || theaterTexture?.width != source.width
            || theaterTexture?.height != source.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: source.width, height: source.height,
                mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            desc.storageMode = .private
            theaterTexture = device.makeTexture(descriptor: desc)
            theaterTextureSRGB = theaterTexture?.makeTextureView(pixelFormat: .bgra8Unorm_srgb)
        }
        let dest = theaterTexture
        theaterLock.unlock()

        guard let dest, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let w = min(source.width, dest.width)
        let h = min(source.height, dest.height)
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: dest, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        theaterGeneration.value += 1
    }

    /// The latest processed frame for the theater, plus a generation counter so
    /// the reader can skip redundant work. Returns nil until the first frame.
    /// Marked internal via a nonisolated wrapper below.
    func present(_ texture: MTLTexture, to layer: CAMetalLayer, commandBuffer: MTLCommandBuffer) {
        let size = CGSize(width: texture.width, height: texture.height)
        if layer.drawableSize != size {
            layer.drawableSize = size
        }
        guard let drawable = layer.nextDrawable(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            commandBuffer.commit()
            return
        }
        let w = min(texture.width, drawable.texture.width)
        let h = min(texture.height, drawable.texture.height)
        blit.copy(from: texture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: drawable.texture,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - GPU helpers

private extension MetalVideoRenderer {
    /// Decoded streams carry their colour description as buffer attachments
    /// (HDR: BT.2020 + PQ/HLG). Those override the manual capture settings;
    /// capture-card frames have none and keep the user's choice.
    static func applyBufferColorInfo(_ buffer: CVPixelBuffer, tenBit: Bool, to color: inout ColorParams) {
        color.tenBit = tenBit ? 1 : 0
        if tenBit {
            color.fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 1 : 0
        }
        color.transfer = 0
        if let tf = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String {
            if tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                color.transfer = 1
            } else if tf == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                color.transfer = 2
            }
        }
        if let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String,
           matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
            color.matrix = 2
        } else if color.transfer != 0 {
            color.matrix = 2      // HDR without a matrix tag is BT.2020 in practice
        }
    }

    func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int,
                     format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            format, width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (texture, cvTexture)
    }

    func ensureTexture(_ store: inout MTLTexture?, width: Int, height: Int,
                       usage: MTLTextureUsage) -> MTLTexture? {
        if let existing = store, existing.width == width, existing.height == height {
            return existing
        }
        // Return the old texture to the pool before getting a new one.
        if let old = store {
            texturePool.returnTexture(old)
        }
        let texture = texturePool.getTexture(width: width, height: height,
                                            pixelFormat: .bgra8Unorm, usage: usage)
        store = texture
        return texture
    }

    func encodeConvert(_ cb: MTLCommandBuffer, luma: MTLTexture, chroma: MTLTexture,
                       out: MTLTexture, params: inout ColorParams) {
        guard let encoder = cb.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(convertPipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(out, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        dispatch(encoder, pipeline: convertPipeline, width: out.width, height: out.height)
        encoder.endEncoding()
    }

    func encodeSharpen(_ cb: MTLCommandBuffer, input: MTLTexture, out: MTLTexture,
                       amount: Float) {
        guard let encoder = cb.makeComputeCommandEncoder() else { return }
        var a = amount
        encoder.setComputePipelineState(sharpenPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(out, index: 1)
        encoder.setBytes(&a, length: MemoryLayout<Float>.stride, index: 0)
        dispatch(encoder, pipeline: sharpenPipeline, width: out.width, height: out.height)
        encoder.endEncoding()
    }

    func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                  width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadgroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w,
                             height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
    }

    #if !targetEnvironment(simulator)
    func ensureSpatialScaler(inW: Int, inH: Int, outW: Int,
                             outH: Int) -> MTLFXSpatialScaler? {
        let inSize = CGSize(width: inW, height: inH)
        let outSize = CGSize(width: outW, height: outH)
        if let scaler = spatialScaler, scalerInputSize == inSize, scalerOutputSize == outSize {
            return scaler
        }
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inW
        desc.inputHeight = inH
        desc.outputWidth = outW
        desc.outputHeight = outH
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.colorProcessingMode = .perceptual
        let scaler = desc.makeSpatialScaler(device: device)
        spatialScaler = scaler
        scalerInputSize = inSize
        scalerOutputSize = outSize
        return scaler
    }
    #endif

    func ensureLanczos() -> MPSImageLanczosScale {
        lanczosLastUsed = CACurrentMediaTime()
        if let lanczos { return lanczos }
        let scaler = MPSImageLanczosScale(device: device)
        lanczos = scaler
        return scaler
    }

    /// Releases the Lanczos scaler if it hasn't been used recently. Called by
    /// the pool purge timer to free memory when MetalFX is active or capture
    /// is paused.
    func purgeIdleLanczos() {
        let now = CACurrentMediaTime()
        if lanczos != nil && now - lanczosLastUsed > 5.0 {
            lanczos = nil
        }
    }
}
