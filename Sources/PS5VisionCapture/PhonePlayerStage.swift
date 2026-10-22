#if os(iOS)
import SwiftUI
import UIKit

/// What the touch area shows.
enum TouchContent: Equatable {
    case none
    /// The full on-screen controller.
    case controller
    /// Only the touchpad (plus Create / PS / Options).
    case touchpad
}

/// How the player is arranged on iPhone, iPhone Duo and iPad.
///
/// Decided from the space the window actually has and, on iPhone Duo, from
/// the fold as the system reports it (never from the device model or a
/// guessed "half of the screen"):
///
/// | Situation                                          | Arrangement |
/// |----------------------------------------------------|-------------|
/// | Duo half-folded, fold across the screen (tabletop)  | video above the fold, reflection + controller or big touchpad below |
/// | Portrait: any iPhone, Duo closed, Duo open upright  | video on top, controller (or touchpad) panel underneath |
/// | Landscape: phone sideways, Duo open flat, iPad      | full-screen video, translucent controller (or touchpad strip) over it |
/// | Duo half-folded like a book (fold top to bottom)    | full-screen video; controller halves either side of the fold |
/// | DualSense connected, not tabletop (Automatic)       | video only, centred |
enum PlayerArrangement: Equatable {
    case videoOnly
    case overlay
    /// `videoBottom`: where the video area ends; `controlsTop`: where the
    /// lower area starts (equal unless a fold band separates them).
    /// `tabletop`: the split is the iPhone Duo fold.
    case stacked(videoBottom: CGFloat, controlsTop: CGFloat, tabletop: Bool)

    static func resolve(size: CGSize, fold: FoldBand?, content: TouchContent, reflection: Bool) -> PlayerArrangement {
        if let fold, fold.isHorizontal, fold.minY > size.height * 0.2, fold.maxY < size.height * 0.85,
           content != .none || reflection {
            return .stacked(videoBottom: fold.minY, controlsTop: fold.maxY, tabletop: true)
        }
        guard content != .none else { return .videoOnly }
        if size.height > size.width * 1.1 {
            // Video as wide as the screen, at most 55 % of the height.
            let video = min(size.width * 9 / 16, size.height * 0.55)
            return .stacked(videoBottom: video, controlsTop: video, tabletop: false)
        }
        return .overlay
    }
}

/// The active fold of an iPhone Duo, in the reading view's coordinates.
struct FoldBand: Equatable {
    var frame: CGRect
    var isHorizontal: Bool { frame.width > frame.height }
    var minY: CGFloat { frame.minY }
    var maxY: CGFloat { frame.maxY }

    /// Reads the fold from the iOS 27.1 reserved-region API. It is only
    /// active while the device is partly folded; flat or closed, and on every
    /// other device, this returns nil. Built with an SDK older than 27.1
    /// (no `DUO_SDK` flag) it always returns nil and the layout falls back to
    /// width and height alone.
    static func read(_ proxy: GeometryProxy) -> FoldBand? {
        #if DUO_SDK
        if #available(iOS 27.1, *) {
            let regions = proxy.reservedRegions(kind: .division)
            if let region = regions.first(where: { $0.isActive }) {
                return FoldBand(frame: region.frame)
            }
        }
        #endif
        return nil
    }
}

/// The iOS player surface: video, optional on-screen controller, and the
/// floating control bar, arranged by `PlayerArrangement`. Re-evaluated on
/// every size or fold change, so folding, unfolding, rotating and Split View
/// rearrange it live while the stream keeps running.
struct PhonePlayerStage<Video: View, Overlay: View>: View {
    @ObservedObject var settings: RemotePlaySettings
    @ObservedObject var gamepad: GamepadBridge
    /// Remote Play (true) or capture card (false: no touch controller).
    let isRemote: Bool
    let renderer: MetalVideoRenderer
    let video: Video
    /// Status overlay drawn on the video area.
    let videoOverlay: Overlay

    @StateObject private var holder = PadHolder()
    @StateObject private var pip = PlayerPictureInPicture()
    /// 0...1, from the hinge angle on iPhone Duo (1 elsewhere).
    @State private var reflectionStrength: Double = 1

    init(settings: RemotePlaySettings, gamepad: GamepadBridge, isRemote: Bool,
         renderer: MetalVideoRenderer,
         @ViewBuilder video: () -> Video, @ViewBuilder videoOverlay: () -> Overlay) {
        self.settings = settings
        self.gamepad = gamepad
        self.isRemote = isRemote
        self.renderer = renderer
        self.video = video()
        self.videoOverlay = videoOverlay()
    }

    /// What to show for the current mode and controller, outside tabletop.
    private var content: TouchContent {
        guard isRemote else { return .none }
        switch settings.touchControls {
        case .on: return .controller
        case .off: return .none
        case .touchpad: return .touchpad
        case .automatic:
            if !gamepad.hasPhysicalController { return .controller }
            // A controller without a touchpad still needs one for many games.
            return gamepad.isDualSense ? .none : .touchpad
        }
    }

    /// Tabletop lower half follows the same rule: no controller = the full
    /// on-screen controller; a controller without a touchpad = a compact
    /// touchpad; DualSense = the reflection alone.
    private func tabletopContent() -> TouchContent { content }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fold = FoldBand.read(proxy)
            let reflection = settings.tabletopReflection
            let arrangement = PlayerArrangement.resolve(size: size, fold: fold,
                                                        content: fold?.isHorizontal == true ? tabletopContent() : content,
                                                        reflection: reflection)
            let pad = holder.pad(for: gamepad, haptics: settings.touchHaptics)

            ZStack(alignment: .top) {
                Color.black

                switch arrangement {
                case .videoOnly:
                    videoArea(alignment: .center)
                        .frame(width: size.width, height: size.height)

                case .overlay:
                    videoArea(alignment: .center)
                        .frame(width: size.width, height: size.height)
                    // Book pose (fold top to bottom): nothing in the centre
                    // column, so no control sits on the crease.
                    TouchControllerView(pad: pad, style: content == .touchpad ? .touchpadStrip : .overlay,
                                        opacity: settings.touchOpacity,
                                        avoidCenter: fold.map { !$0.isHorizontal } ?? false)
                        .frame(width: size.width, height: size.height)

                case .stacked(let videoBottom, let controlsTop, let tabletop):
                    let lower = tabletop ? tabletopContent() : content
                    let videoWidth = min(size.width, videoBottom * 16 / 9)
                    VStack(spacing: 0) {
                        // On the table the picture sits on the fold, so its
                        // reflection starts right under it.
                        videoArea(alignment: tabletop ? .bottom : .center)
                            .frame(width: size.width, height: videoBottom)
                        // The fold band itself: nothing interactive on the crease.
                        Color.black.frame(height: max(0, controlsTop - videoBottom))
                        ZStack(alignment: .top) {
                            if tabletop && reflection {
                                ReflectionView(renderer: renderer, width: videoWidth,
                                               strength: reflectionStrength)
                            } else {
                                Brand.night
                            }
                            switch lower {
                            case .controller: TouchControllerView(pad: pad, style: .panel)
                            case .touchpad:
                                // Compact, at the bottom: the reflection
                                // stays visible above it.
                                TouchControllerView(pad: pad, style: .touchpad)
                                    .frame(maxWidth: min(size.width, 520),
                                           maxHeight: min(240, max(0, size.height - controlsTop) * 0.55))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            case .none: Color.clear
                            }
                        }
                        .frame(width: size.width, height: max(0, size.height - controlsTop))
                        .clipped()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: arrangement)
        }
        .ignoresSafeArea(.container, edges: .all)
        .modifier(HingeReflectionModifier(strength: $reflectionStrength))
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            holder.current?.releaseAll()
            pip.tearDown()
        }
        .onChange(of: content) { _, new in if new == .none { holder.current?.releaseAll() } }
        .onChange(of: settings.pictureInPicture) { _, on in if !on { pip.tearDown() } }
    }

    private func videoArea(alignment: Alignment) -> some View {
        ZStack {
            // Picture in Picture takes its picture from this layer, which
            // must be in the window; the Metal view covers it.
            if isRemote && settings.pictureInPicture {
                PiPLayerView { layer in
                    pip.configure(layer: layer, renderer: renderer, enabled: true)
                }
            }
            video
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay { videoOverlay }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

/// The picture mirrored on the iPhone Duo's lower half in tabletop pose,
/// as if reflected on a glossy table: flipped, blurred, fading out.
/// Drawn by the app (no system API provides it); a second output of the
/// same Metal renderer, so it costs one extra blit per frame.
private struct ReflectionView: View {
    let renderer: MetalVideoRenderer
    let width: CGFloat
    let strength: Double

    var body: some View {
        ZStack(alignment: .top) {
            Brand.night
            MirrorVideoView(renderer: renderer)
                .frame(width: width, height: width * 9 / 16)
                .scaleEffect(x: 1, y: -1)
                .overlay(Rectangle().fill(.ultraThinMaterial))
                .mask(LinearGradient(colors: [.white.opacity(0.55 * strength), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

/// Fades the reflection with the fold angle on iPhone Duo: strongest around
/// a classic tabletop angle, gone as the screen approaches flat. The hinge
/// is only used for this effect, never for layout (Apple's guidance).
private struct HingeReflectionModifier: ViewModifier {
    @Binding var strength: Double

    func body(content: Content) -> some View {
        #if DUO_SDK
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                guard let hinge = new.hinge else { strength = 1; return }
                let degrees = hinge.angle.degrees
                // ~90–120° reads as a table; fade out toward 170° (flat).
                strength = max(0, min(1, (170 - degrees) / 50))
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Keeps one VirtualPad per stage and refreshes its haptics setting.
@MainActor
private final class PadHolder: ObservableObject {
    private(set) var current: VirtualPad?

    func pad(for bridge: GamepadBridge, haptics: Bool) -> VirtualPad {
        let pad = current ?? VirtualPad(bridge: bridge)
        pad.hapticsEnabled = haptics
        current = pad
        return pad
    }
}
#endif
