#if os(visionOS)
import RealityKit
import SwiftUI
import UIKit
import Metal
import Combine
import QuartzCore
import simd
import ARKit

/// Immersive theater: a large curved screen showing the live capture.
///
/// Frame delivery is a pull model on the main actor (RealityKit update tick):
/// the renderer publishes the latest color frame; this scene blits it into a
/// `LowLevelTexture` used by the screen material.
@MainActor
final class TheaterScene {
    let root = Entity()
    /// Name of the screen entity, so gestures can find it (touchpad).
    static let screenName = "theaterScreen"

    private let renderer: MetalVideoRenderer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?

    private var colorTexture: LowLevelTexture?
    private var textureResource: TextureResource?
    private var screen: ModelEntity?
    private var currentSize = SIMD2<Int>(0, 0)
    private var lastGeneration = -1
    private var updateSubscription: EventSubscription?

    private let options: RenderOptions
    /// Inside-out black sphere around the viewer; its opacity dims the room.
    private let surround = Entity()
    private var surroundModel: ModelEntity?
    private var lastDim: Float = -1
    /// Draw order: the dim sphere first, then the (blended) screen.
    private let sortGroup = ModelSortGroup(depthPass: nil)

    // MARK: Floor reflection

    /// Planar floor reflection: the same mesh mirrored about the floor,
    /// textured with a blurred, rippled copy of the picture (see the
    /// `theaterReflection` kernel) and faded out away from the screen.
    private var reflection: ModelEntity?
    private var reflectionTexture: LowLevelTexture?
    private let reflectionPipeline: MTLComputePipelineState?
    private var screenHeightMeters: Float = 0
    private let epoch = CACurrentMediaTime()
    /// Ripple drops: x, y (reflection UV), start time, amplitude.
    private var drops: [SIMD4<Float>] = []
    private var pressTimes: [CFTimeInterval] = []
    private var lastPresses: Int?
    private var waves: Float = 0
    /// Total controller button presses so far (rising edges); drives ripples.
    var buttonPresses: (@MainActor () -> Int)?
    /// Water ripples on the reflection (user setting).
    var ripplesEnabled: @MainActor () -> Bool = { true }

    // MARK: Recline

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    /// Head position the reclined screen orbits around. Captured when the
    /// recline starts and on Recenter.
    private var reclinePivot: SIMD3<Float>?
    private var recenterRequested = false
    /// Seated eye height the screen's Height setting is measured against
    /// when reclined.
    private static let seatedEye: Float = 1.2

    /// The control dock, placed per frame so it follows the recline.
    weak var controls: Entity?
    var controlsBase = SIMD3<Float>(0, 0.72, -1.25)

    // MARK: Touchpad cursor

    private var touchCursor: ModelEntity?

    init(renderer: MetalVideoRenderer, options: RenderOptions) {
        self.renderer = renderer
        self.options = options
        self.device = renderer.metalDevice
        self.commandQueue = device.makeCommandQueue()
        if let fn = (try? device.makeDefaultLibrary(bundle: .main))?.makeFunction(name: "theaterReflection") {
            reflectionPipeline = try? device.makeComputePipelineState(function: fn)
        } else {
            reflectionPipeline = nil
        }
    }

    /// Starts pulling frames by subscribing to per-frame updates on the
    /// RealityView content. Idempotent.
    func activate(content: RealityViewContent) {
        guard updateSubscription == nil else { return }
        renderer.theaterEnabled.value = true
        buildSurround()
        content.add(surround)
        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.pullFrame()
        }
        if WorldTrackingProvider.isSupported {
            let session = arSession, provider = worldTracking
            Task { try? await session.run([provider]) }
        }
    }

    func deactivate() {
        renderer.theaterEnabled.value = false
        updateSubscription?.cancel()
        updateSubscription = nil
        arSession.stop()
        root.children.removeAll()
        surround.removeFromParent()
        surroundModel = nil
        surround.children.removeAll()
        lastDim = -1
        screen = nil
        reflection = nil
        reflectionTexture = nil
        touchCursor = nil
        colorTexture = nil
        textureResource = nil
        currentSize = .init(0, 0)
        lastGeneration = -1
    }

    /// Re-centres the reclined screen on where the head is now.
    func recenter() { recenterRequested = true }

    private func buildSurround() {
        guard surroundModel == nil else { return }
        var material = UnlitMaterial(color: .black)
        material.faceCulling = .front          // we are inside the sphere
        let sphere = ModelEntity(mesh: .generateSphere(radius: 40), materials: [material])
        sphere.components.set(OpacityComponent(opacity: 0))
        sphere.components.set(ModelSortGroupComponent(group: sortGroup, order: 0))
        surround.addChild(sphere)
        surroundModel = sphere
        updateSurround()
    }

    private func updateSurround() {
        let dim = max(0, min(1, options.theaterDim))
        guard dim != lastDim, let sphere = surroundModel else { return }
        lastDim = dim
        sphere.isEnabled = dim > 0.01
        sphere.components.set(OpacityComponent(opacity: dim))
    }

    private var reclineRadians: Float { max(0, min(85, options.theaterRecline)) * (Float.pi / 180) }
    private var isReclined: Bool { options.theaterRecline > 0.5 }
    private var reflectionWanted: Bool { options.theaterReflection && options.theaterRecline < 10 }

    /// Called once per RealityKit frame on the main actor.
    private func pullFrame() {
        updateSurround()
        updatePlacement()
        guard let frame = renderer.latestTheaterFrame() else { return }

        guard ensureScreen(width: frame.texture.width, height: frame.texture.height),
              let llt = colorTexture,
              let commandBuffer = commandQueue?.makeCommandBuffer() else {
            return
        }

        if frame.generation != lastGeneration {
            lastGeneration = frame.generation
            let dest = llt.replace(using: commandBuffer)
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                defer {
                    // Mipmaps: without them a 1080p/4K texture shrunk onto a
                    // distant screen shimmers and aliases on fine detail.
                    // The reflection blur samples them too.
                    if dest.mipmapLevelCount > 1 { blit.generateMipmaps(for: dest) }
                    blit.endEncoding()
                }
                let w = min(frame.texture.width, dest.width)
                let h = min(frame.texture.height, dest.height)
                blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: w, height: h, depth: 1),
                          to: dest, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            if reflection?.isEnabled == true {
                encodeReflection(from: dest, commandBuffer: commandBuffer)
            }
        }
        commandBuffer.commit()
        applyScreenGeometryIfNeeded()
    }

    // MARK: Placement (seated or reclined)

    /// Seated (recline 0): exactly the old placement, from the floor origin.
    /// Reclined: the seated offset from the eye is rotated up around the
    /// head by the recline angle, so the screen arcs overhead and faces down
    /// toward someone lying back. The dock follows the same rotation.
    private func updatePlacement() {
        let tiltQ = simd_quatf(angle: options.theaterTilt * (Float.pi / 180), axis: [1, 0, 0])
        let dockLean = simd_quatf(angle: -.pi / 6, axis: [1, 0, 0])
        if isReclined {
            if reclinePivot == nil || recenterRequested {
                if let head = headPosition() {
                    reclinePivot = head
                    recenterRequested = false
                } else if reclinePivot == nil {
                    reclinePivot = SIMD3(0, Self.seatedEye, 0)
                }
            }
            let pivot = reclinePivot ?? SIMD3(0, Self.seatedEye, 0)
            let r = simd_quatf(angle: reclineRadians, axis: [1, 0, 0])
            let seated = SIMD3<Float>(0, options.theaterHeight - Self.seatedEye, -options.theaterDistance)
            screen?.position = pivot + r.act(seated)
            screen?.orientation = r * tiltQ
            if let controls {
                controls.position = pivot + r.act(controlsBase - SIMD3(0, Self.seatedEye, 0))
                controls.orientation = r * dockLean
            }
        } else {
            reclinePivot = nil
            recenterRequested = false
            screen?.position = SIMD3(0, options.theaterHeight, -options.theaterDistance)
            screen?.orientation = tiltQ
            if let controls {
                controls.position = controlsBase
                controls.orientation = dockLean
            }
        }
        updateReflection()
    }

    private func headPosition() -> SIMD3<Float>? {
        guard worldTracking.state == .running,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return nil
        }
        let c = anchor.originFromAnchorTransform.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    // MARK: Reflection

    /// Mirror across the floor plane y = f: S·R(t) = R(-t)·S with
    /// S = diag(1,-1,1), so the reflection is the screen at 2f - height,
    /// tilted by -t, scaled -1 in Y. Being real geometry it stays correct as
    /// the head moves. The floor is the real one (y = 0) unless the screen
    /// reaches below it; then it drops to just under the screen's bottom
    /// edge so the reflection never vanishes at large sizes.
    private func updateReflection() {
        guard let reflection else { return }
        let show = reflectionWanted && !isReclined
        if reflection.isEnabled != show { reflection.isEnabled = show }
        guard show else { return }
        let tilt = options.theaterTilt * (Float.pi / 180)
        let halfExtent = screenHeightMeters / 2 * abs(cos(tilt))
        let bottom = options.theaterHeight - halfExtent
        let floor = min(0, bottom - 0.02)
        reflection.position = SIMD3(0, 2 * floor - options.theaterHeight, -options.theaterDistance)
        reflection.orientation = simd_quatf(angle: -tilt, axis: [1, 0, 0])
        reflection.scale = SIMD3(1, -1, 1)
    }

    /// Blurred (more with distance from the screen), rippled copy of the
    /// frame into the reflection texture. Ripples come from controller
    /// presses: each press drops a ring, and the faster you press the
    /// stronger and busier the water gets.
    private func encodeReflection(from source: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let pipeline = reflectionPipeline, let rt = reflectionTexture,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let now = CACurrentMediaTime()
        let time = Float(now - epoch)
        let ripples = ripplesEnabled()

        let presses = buttonPresses?() ?? 0
        if let last = lastPresses, presses > last, ripples {
            let fresh = min(presses - last, 3)
            for _ in 0..<fresh { pressTimes.append(now) }
            let activity = Float(pressTimes.filter { now - $0 < 2 }.count)
            let amp = 0.35 + min(activity / 8, 1) * 0.65
            for _ in 0..<fresh {
                drops.append(SIMD4(Float.random(in: 0.12...0.88), Float.random(in: 0.62...0.97), time, amp))
            }
        }
        lastPresses = presses
        pressTimes.removeAll { now - $0 > 2 }
        drops.removeAll { time - $0.z > 2.5 }
        if drops.count > 8 { drops.removeFirst(drops.count - 8) }
        let activity = Float(pressTimes.count)
        let target: Float = ripples ? 0.12 + min(activity / 10, 1) * 0.88 : 0
        waves += (target - waves) * 0.05

        let out = rt.replace(using: commandBuffer)
        var params = [SIMD4<Float>](repeating: .zero, count: 10)
        let maxLod = Float(max(0, source.mipmapLevelCount - 1))
        params[0] = SIMD4(time, waves, Float(out.width) / Float(max(out.height, 1)), min(maxLod, 6.5))
        params[1] = SIMD4(Float(ripples ? min(drops.count, 8) : 0), 0, 0, 0)
        if ripples { for (i, d) in drops.prefix(8).enumerated() { params[2 + i] = d } }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(out, index: 1)
        encoder.setBytes(params, length: MemoryLayout<SIMD4<Float>>.stride * params.count, index: 0)
        let tw = pipeline.threadExecutionWidth
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(
            MTLSize(width: (out.width + tw - 1) / tw, height: (out.height + th - 1) / th, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
    }

    // MARK: Touchpad

    /// Touchpad position (0...1, y down) for a point in the screen entity's
    /// local space; nil when it is off the picture.
    func touchpadPoint(local p: SIMD3<Float>) -> CGPoint? {
        guard currentSize.x > 0, screenHeightMeters > 0 else { return nil }
        let w = options.theaterWidth
        let u = p.x / w + 0.5
        let v = 0.5 - p.y / screenHeightMeters
        guard u >= -0.02, u <= 1.02, v >= -0.02, v <= 1.02 else { return nil }
        return CGPoint(x: Double(max(0, min(1, u))), y: Double(max(0, min(1, v))))
    }

    /// Small glowing dot under the finger; nil hides it.
    func showTouchCursor(atLocal p: SIMD3<Float>?) {
        guard let screen else { return }
        guard let p else { touchCursor?.isEnabled = false; return }
        if touchCursor == nil {
            var m = UnlitMaterial(color: .white)
            m.blending = .transparent(opacity: 0.85)
            let dot = ModelEntity(mesh: .generateSphere(radius: 1), materials: [m])
            dot.components.set(ModelSortGroupComponent(group: sortGroup, order: 2))
            screen.addChild(dot)
            touchCursor = dot
        }
        let w = options.theaterWidth
        let u = p.x / w + 0.5
        let z = options.theaterCurvature * pow((u - 0.5) * 2, 2) * w * 0.15
        touchCursor?.scale = SIMD3(repeating: max(0.012, w * 0.006))
        touchCursor?.position = SIMD3(p.x, p.y, z + 0.01)
        touchCursor?.isEnabled = true
    }

    /// Lets gestures hit the screen (touchpad); refreshed with the mesh.
    private func updateCollision(mesh: MeshResource, width: Float, height: Float) {
        guard let screen else { return }
        let depth = max(0.02, options.theaterCurvature * width * 0.15)
        let box = ShapeResource.generateBox(width: width, height: height, depth: depth)
            .offsetBy(translation: [0, 0, depth / 2])
        screen.components.set(CollisionComponent(shapes: [box], isStatic: true))
        screen.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        // The exact curved surface, once generated, for accurate hits.
        Task { @MainActor [weak screen] in
            guard let shape = try? await ShapeResource.generateStaticMesh(from: mesh) else { return }
            screen?.components.set(CollisionComponent(shapes: [shape], isStatic: true))
        }
    }

    /// Rebuilds the curved mesh when width/curvature changes.
    private var lastWidth: Float = -1
    private var lastCurvature: Float = -1
    private func applyScreenGeometryIfNeeded() {
        guard currentSize.x > 0 else { return }
        if lastWidth == options.theaterWidth && lastCurvature == options.theaterCurvature {
            return
        }
        lastWidth = options.theaterWidth
        lastCurvature = options.theaterCurvature
        let aspect = Float(currentSize.x) / Float(max(currentSize.y, 1))
        let w = options.theaterWidth
        let mesh = Self.curvedScreenMesh(width: w, height: w / aspect,
                                         curvature: options.theaterCurvature)
        screen?.model?.mesh = mesh
        reflection?.model?.mesh = mesh
        screenHeightMeters = w / aspect
        updateCollision(mesh: mesh, width: w, height: w / aspect)
        updateReflection()
    }

    /// Creates the screen (color texture + curved mesh + material) once we
    /// know the capture resolution.
    private func ensureScreen(width: Int, height: Int) -> Bool {
        if currentSize == SIMD2(width, height), screen != nil { return true }
        currentSize = SIMD2(width, height)
        lastWidth = -1; lastCurvature = -1

        // The renderer writes gamma (sRGB-curve) encoded pixels. Tag the theater
        // texture as sRGB so RealityKit's colour-managed pipeline decodes on
        // sample and re-encodes on output — the same sRGB contract declared by
        // the window's CAMetalLayer, without washing out or darkening midtones
        // by treating gamma-encoded values as linear.
        var texDesc = LowLevelTexture.Descriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
            textureUsage: [.shaderRead, .shaderWrite, .renderTarget])
        texDesc.mipmapLevelCount = Int(log2(Double(max(width, height)))) + 1
        guard let llt = try? LowLevelTexture(descriptor: texDesc),
              let res = try? TextureResource(from: llt) else {
            return false
        }
        colorTexture = llt
        textureResource = res

        // The video shader has already mapped the frame to SDR. RealityKit's
        // default unlit material tone-maps again, shifting brightness relative
        // to the direct CAMetalLayer window path.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(res))
        material.faceCulling = .none
        // Rounded corners with a soft (anti-aliased) edge. The hard polygon
        // edge of a plain rectangle is what showed up as jagged lines.
        let aspectRatio = Float(width) / Float(max(height, 1))
        if let mask = Self.edgeMask(aspect: aspectRatio) {
            material.blending = .transparent(opacity: .init(scale: 1, texture: .init(mask)))
        }

        let aspect = Float(width) / Float(max(height, 1))
        let w = options.theaterWidth
        let mesh = Self.curvedScreenMesh(width: w, height: w / aspect,
                                         curvature: options.theaterCurvature)

        root.children.removeAll()
        touchCursor = nil
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = Self.screenName
        // No Y-axis rotation: the mesh is built in the XY plane with its front
        // face (+Z normal) already toward the viewer, and the material is
        // double-sided (faceCulling = .none). A 180° Y rotation here would mirror
        // the image left-to-right, which is exactly the bug we want to avoid.
        entity.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
        root.addChild(entity)
        screen = entity
        screenHeightMeters = w / aspect

        // Reflection texture: half resolution, linear float (written by the
        // compute kernel). Falls back to the picture itself without the kernel.
        var mirrorTexture: TextureResource = res
        if reflectionPipeline != nil {
            let rd = LowLevelTexture.Descriptor(
                pixelFormat: .rgba16Float, width: max(16, width / 2), height: max(16, height / 2),
                textureUsage: [.shaderRead, .shaderWrite])
            if let rllt = try? LowLevelTexture(descriptor: rd), let rres = try? TextureResource(from: rllt) {
                reflectionTexture = rllt
                mirrorTexture = rres
            }
        }
        var mirror = UnlitMaterial(applyPostProcessToneMap: false)
        mirror.color = .init(tint: UIColor(white: 0.6, alpha: 1), texture: .init(mirrorTexture))
        mirror.faceCulling = .none
        if let fade = Self.reflectionMask(aspect: aspectRatio) {
            mirror.blending = .transparent(opacity: .init(scale: 0.5, texture: .init(fade)))
        } else {
            mirror.blending = .transparent(opacity: .init(floatLiteral: 0.2))
        }
        let mirrored = ModelEntity(mesh: mesh, materials: [mirror])
        mirrored.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
        mirrored.isEnabled = false
        root.addChild(mirrored)
        reflection = mirrored
        updateCollision(mesh: mesh, width: w, height: w / aspect)
        updatePlacement()
        return true
    }

    /// Alpha mask: a rounded rectangle whose edge fades over ~3 texels, sampled
    /// with the screen's UVs (mipmapped by RealityKit, so it stays smooth at
    /// any distance). RGB = A = coverage, whichever channel is read.
    private static var maskCache: [Int: TextureResource] = [:]
    static func edgeMask(aspect: Float) -> TextureResource? {
        let w = 2048
        let h = max(16, Int((Float(w) / max(aspect, 0.1)).rounded()))
        if let cached = maskCache[h] { return cached }
        let radius = Float(h) * 0.03          // ~3 % of the height
        let feather: Float = 3
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let hw = Float(w) / 2, hh = Float(h) / 2
        for y in 0..<h {
            let py = abs(Float(y) + 0.5 - hh)
            for x in 0..<w {
                let px = abs(Float(x) + 0.5 - hw)
                // Signed distance to a rounded rectangle inset by half the feather.
                let qx = px - (hw - feather / 2 - radius)
                let qy = py - (hh - feather / 2 - radius)
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                let sd = outside + min(max(qx, qy), 0) - radius
                let a = UInt8(max(0, min(1, 0.5 - sd / feather)) * 255)
                let i = (y * w + x) * 4
                pixels[i] = a; pixels[i + 1] = a; pixels[i + 2] = a; pixels[i + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent),
              let texture = try? TextureResource(image: image, options: .init(semantic: .raw)) else {
            return nil
        }
        maskCache[h] = texture
        return texture
    }

    /// Reflection mask: the rounded-corner edge mask times a fade that is
    /// strongest at the screen's bottom edge (texture bottom rows, uv.y = 0)
    /// and fading gradually to nothing at the top, like a glossy floor.
    private static var reflectionMaskCache: [Int: TextureResource] = [:]
    static func reflectionMask(aspect: Float) -> TextureResource? {
        let w = 512
        let h = max(16, Int((Float(w) / max(aspect, 0.1)).rounded()))
        if let cached = reflectionMaskCache[h] { return cached }
        let radius = Float(h) * 0.03
        let feather: Float = 1.5
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let hw = Float(w) / 2, hh = Float(h) / 2
        for y in 0..<h {
            let py = abs(Float(y) + 0.5 - hh)
            // 0 at the bottom edge, 1 at the top: a long, gradual fade
            // over the whole height (no hard cut halfway).
            let fromBottom = 1 - (Float(y) + 0.5) / Float(h)
            let fade = pow(max(0, 1 - fromBottom), 1.8)
            for x in 0..<w {
                let px = abs(Float(x) + 0.5 - hw)
                let qx = px - (hw - feather / 2 - radius)
                let qy = py - (hh - feather / 2 - radius)
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                let sd = outside + min(max(qx, qy), 0) - radius
                let edge = max(0, min(1, 0.5 - sd / feather))
                let a = UInt8(edge * fade * 255)
                let i = (y * w + x) * 4
                pixels[i] = a; pixels[i + 1] = a; pixels[i + 2] = a; pixels[i + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent),
              let texture = try? TextureResource(image: image, options: .init(semantic: .raw)) else {
            return nil
        }
        reflectionMaskCache[h] = texture
        return texture
    }

    /// A gently curved screen mesh (grid displaced along Z at the edges).
    static func curvedScreenMesh(width: Float, height: Float,
                                 curvature: Float) -> MeshResource {
        let cols = 48, rows = 2
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for r in 0...rows {
            let v = Float(r) / Float(rows)
            let y = (0.5 - v) * height
            for c in 0...cols {
                let u = Float(c) / Float(cols)
                let x = (u - 0.5) * width
                // Positive z curves the screen edges toward the viewer (concave).
                // Previously this was negated to compensate for the 180° Y rotation
                // that has since been removed.
                let z = curvature * pow((u - 0.5) * 2.0, 2) * width * 0.15
                positions.append(SIMD3(x, y, z))
                // Flip v so the image isn't upside-down on the screen.
                uvs.append(SIMD2(u, 1.0 - v))
            }
        }
        let stride = cols + 1
        for r in 0..<rows {
            for c in 0..<cols {
                let a = UInt32(r * stride + c)
                let b = UInt32(r * stride + c + 1)
                let d = UInt32((r + 1) * stride + c)
                let e = UInt32((r + 1) * stride + c + 1)
                indices += [a, d, b, b, d, e]
            }
        }
        var desc = MeshDescriptor(name: "curvedScreen")
        desc.positions = MeshBuffer(positions)
        desc.textureCoordinates = MeshBuffer(uvs)
        desc.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [desc]))
            ?? MeshResource.generatePlane(width: width, height: height)
    }
}
#endif
