import Foundation
import simd

/// Color matrix used to convert YCbCr to RGB.
enum ColorMatrix: String, CaseIterable, Identifiable {
    case bt709 = "BT.709"
    case bt601 = "BT.601"
    var id: String { rawValue }
    var rawIndex: UInt32 { self == .bt601 ? 1 : 0 }
}

/// Signal range of the captured YCbCr data.
enum ColorRange: String, CaseIterable, Identifiable {
    case video = "Video (limited)"
    case full = "Full"
    var id: String { rawValue }
    var rawIndex: UInt32 { self == .full ? 1 : 0 }
}

/// Upscaling algorithm applied before presenting.
enum UpscaleMode: String, CaseIterable, Identifiable {
    case off = "Off (native)"
    case lanczos = "Lanczos"
    case metalFX = "MetalFX Spatial"
    var id: String { rawValue }
}

/// One-tap creative grading presets. `custom` uses the manual sliders.
enum GradePreset: String, CaseIterable, Identifiable {
    case original = "Original"
    case vivid = "Vivid"
    case soft = "Soft"
    case gaming = "Gaming"
    case custom = "Custom"
    var id: String { rawValue }

    /// (exposure, contrast, saturation, gamma). `nil` for custom.
    var grade: (Float, Float, Float, Float)? {
        switch self {
        case .original: return (0.0, 1.0, 1.0, 1.0)
        case .vivid:    return (0.05, 1.12, 1.25, 1.0)
        case .soft:     return (0.0, 0.95, 0.9, 1.05)
        case .gaming:   return (0.03, 1.2, 1.15, 0.95)
        case .custom:   return nil
        }
    }
}

/// GPU-facing color parameters. Layout must match `ColorParams` in Shaders.metal.
struct ColorParams {
    var matrix: UInt32 = 0
    var fullRange: UInt32 = 0
    var exposure: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var gamma: Float = 1
    var flipH: UInt32 = 0
    var flipV: UInt32 = 0
    var transfer: UInt32 = 0     // 0 SDR, 1 PQ, 2 HLG (set per frame from the buffer)
    var tenBit: UInt32 = 0       // set per frame from the pixel format
    var hdrWhite: Float = 203    // ITU-R BT.2408 reference white
    var hdrPeak: Float = 1000
}

/// How the captured video is presented.
enum DisplayMode: String, CaseIterable, Identifiable {
    case window = "Window"
    case theater = "Theater"      // immersive curved screen
    var id: String { rawValue }
}

/// All live-tunable rendering settings, observed by the UI and read by the
/// renderer each frame. All values persist across launches via UserDefaults.
@MainActor
final class RenderOptions: ObservableObject {
    @Published var displayMode: DisplayMode = .window { didSet { save() } }

    // Theater screen placement (metres). Read by TheaterScene each frame.
    @Published var theaterWidth: Float = 5.0 { didSet { save() } }
    @Published var theaterDistance: Float = 4.0 { didSet { save() } }
    @Published var theaterHeight: Float = 1.3 { didSet { save() } }
    @Published var theaterCurvature: Float = 0.35 { didSet { save() } }
    /// Rotation around the screen's horizontal axis, in degrees. Positive
    /// values bring the top edge toward the viewer.
    @Published var theaterTilt: Float = 0 { didSet { save() } }
    /// Darkens the room around the theater screen (0 = passthrough, 1 = black).
    @Published var theaterDim: Float = 0.6 { didSet { save() } }

    // Manual image flips, applied at the YCbCr→RGB stage so both the window
    // and theater paths stay consistent. A safety net for capture cards that
    // deliver mirrored/inverted frames.
    @Published var flipHorizontal = false { didSet { save() } }
    @Published var flipVertical = false { didSet { save() } }

    @Published var colorMatrix: ColorMatrix = .bt709 { didSet { save() } }
    @Published var colorRange: ColorRange = .video { didSet { save() } }
    @Published var upscale: UpscaleMode = .off { didSet { save() } }
    @Published var sharpenEnabled = false { didSet { save() } }
    @Published var sharpenAmount: Float = 0.5 { didSet { save() } }

    @Published var preset: GradePreset = .gaming {
        didSet { applyPresetIfNeeded(); save() }
    }
    @Published var exposure: Float = 0 { didSet { save() } }
    @Published var contrast: Float = 1 { didSet { save() } }
    @Published var saturation: Float = 1 { didSet { save() } }
    @Published var gamma: Float = 1 { didSet { save() } }

    /// Target size for upscaling (fixed 4K, the app's stated goal).
    let targetWidth = 3840
    let targetHeight = 2160

    /// Set true while loading persisted values so `didSet` doesn't re-save.
    private var isLoading = false

    init() {
        load()
    }

    private func applyPresetIfNeeded() {
        guard let g = preset.grade else { return }
        exposure = g.0
        contrast = g.1
        saturation = g.2
        gamma = g.3
    }

    /// Snapshots the current color settings for the shader.
    func colorParams() -> ColorParams {
        ColorParams(
            matrix: colorMatrix.rawIndex,
            fullRange: colorRange.rawIndex,
            exposure: exposure,
            contrast: contrast,
            saturation: saturation,
            gamma: gamma,
            flipH: flipHorizontal ? 1 : 0,
            flipV: flipVertical ? 1 : 0
        )
    }

    // MARK: - Persistence

    private func save() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(displayMode.rawValue, forKey: "displayMode")
        d.set(theaterWidth, forKey: "theaterWidth")
        d.set(theaterDistance, forKey: "theaterDistance")
        d.set(theaterHeight, forKey: "theaterHeight")
        d.set(theaterCurvature, forKey: "theaterCurvature")
        d.set(theaterTilt, forKey: "theaterTilt")
        d.set(theaterDim, forKey: "theaterDim")
        d.set(flipHorizontal, forKey: "flipHorizontal")
        d.set(flipVertical, forKey: "flipVertical")
        d.set(colorMatrix.rawValue, forKey: "colorMatrix")
        d.set(colorRange.rawValue, forKey: "colorRange")
        d.set(upscale.rawValue, forKey: "upscale")
        d.set(sharpenEnabled, forKey: "sharpenEnabled")
        d.set(sharpenAmount, forKey: "sharpenAmount")
        d.set(preset.rawValue, forKey: "preset")
        d.set(exposure, forKey: "exposure")
        d.set(contrast, forKey: "contrast")
        d.set(saturation, forKey: "saturation")
        d.set(gamma, forKey: "gamma")
    }

    private func load() {
        let d = UserDefaults.standard
        // No saved settings yet → keep defaults (Gaming preset applied below).
        guard d.object(forKey: "preset") != nil else {
            applyPresetIfNeeded()
            return
        }
        isLoading = true
        // displayMode is deliberately not restored: every launch starts in the
        // window on Home, never straight into the immersive theater.
        theaterWidth = d.float(forKey: "theaterWidth")
        theaterDistance = d.float(forKey: "theaterDistance")
        theaterHeight = d.float(forKey: "theaterHeight")
        theaterCurvature = d.float(forKey: "theaterCurvature")
        theaterTilt = d.float(forKey: "theaterTilt")
        if d.object(forKey: "theaterDim") != nil { theaterDim = d.float(forKey: "theaterDim") }
        flipHorizontal = d.bool(forKey: "flipHorizontal")
        flipVertical = d.bool(forKey: "flipVertical")
        if let v = d.string(forKey: "colorMatrix"), let m = ColorMatrix(rawValue: v) { colorMatrix = m }
        if let v = d.string(forKey: "colorRange"), let m = ColorRange(rawValue: v) { colorRange = m }
        if let v = d.string(forKey: "upscale"), let m = UpscaleMode(rawValue: v) { upscale = m }
        sharpenEnabled = d.bool(forKey: "sharpenEnabled")
        sharpenAmount = d.float(forKey: "sharpenAmount")
        if let v = d.string(forKey: "preset"), let m = GradePreset(rawValue: v) { preset = m }
        exposure = d.float(forKey: "exposure")
        contrast = d.float(forKey: "contrast")
        saturation = d.float(forKey: "saturation")
        gamma = d.float(forKey: "gamma")
        isLoading = false
    }
}
