#if os(visionOS)
import RealityKit
import SwiftUI
import Metal
import Combine
import QuartzCore
import simd

/// Immersive theater: a large curved screen showing the live capture.
///
/// Frame delivery is a pull model on the main actor (RealityKit update tick):
/// the renderer publishes the latest color frame; this scene blits it into a
/// `LowLevelTexture` used by the screen material.
@MainActor
final class TheaterScene {
    let root = Entity()

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

    init(renderer: MetalVideoRenderer, options: RenderOptions) {
        self.renderer = renderer
        self.options = options
        self.device = renderer.metalDevice
        self.commandQueue = device.makeCommandQueue()
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
    }

    func deactivate() {
        renderer.theaterEnabled.value = false
        updateSubscription?.cancel()
        updateSubscription = nil
        root.children.removeAll()
        surround.removeFromParent()
        surroundModel = nil
        surround.children.removeAll()
        lastDim = -1
        screen = nil
        colorTexture = nil
        textureResource = nil
        currentSize = .init(0, 0)
        lastGeneration = -1
    }

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

    /// Called once per RealityKit frame on the main actor.
    private func pullFrame() {
        updateSurround()
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
        }
        commandBuffer.commit()

        // Apply live screen placement and tilt. Positive X rotation brings the
        // top edge toward the viewer, useful when watching while reclined.
        screen?.position = SIMD3(0, options.theaterHeight, -options.theaterDistance)
        screen?.orientation = simd_quatf(
            angle: options.theaterTilt * (Float.pi / 180),
            axis: SIMD3<Float>(1, 0, 0)
        )
        applyScreenGeometryIfNeeded()
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
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = SIMD3(0, options.theaterHeight, -options.theaterDistance)
        entity.orientation = simd_quatf(
            angle: options.theaterTilt * (Float.pi / 180),
            axis: SIMD3<Float>(1, 0, 0)
        )
        // No Y-axis rotation: the mesh is built in the XY plane with its front
        // face (+Z normal) already toward the viewer, and the material is
        // double-sided (faceCulling = .none). A 180° Y rotation here would mirror
        // the image left-to-right, which is exactly the bug we want to avoid.
        entity.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
        root.addChild(entity)
        screen = entity
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
