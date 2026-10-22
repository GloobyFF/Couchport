#if os(iOS)
import SwiftUI
import UIKit

/// How the player is arranged on iPhone, iPhone Duo and iPad.
///
/// Decided from the space the window actually has and, on iPhone Duo, from
/// the fold as the system reports it (never from the device model or a
/// guessed "half of the screen"):
///
/// | Situation                                          | Arrangement |
/// |----------------------------------------------------|-------------|
/// | Duo half-folded, fold across the screen (tabletop, | video above the fold, controller below it |
/// |   or held like a laptop / an upright book)          |             |
/// | Portrait: any iPhone, Duo closed, Duo open upright, | video on top, controller panel underneath |
/// |   narrow Split View                                  |             |
/// | Landscape: phone sideways, Duo open flat, iPad      | full-screen video, translucent controller over it |
/// | Duo half-folded like a book (fold top to bottom)    | full-screen video; the two controller halves sit either side of the fold |
/// | Hardware controller connected (Automatic mode)      | video only, centred |
enum PlayerArrangement: Equatable {
    case videoOnly
    case overlay
    /// `videoBottom`: where the video area ends; `controlsTop`: where the
    /// controller area starts (equal unless a fold band separates them).
    case stacked(videoBottom: CGFloat, controlsTop: CGFloat)

    static func resolve(size: CGSize, fold: FoldBand?, touch: Bool) -> PlayerArrangement {
        guard touch else { return .videoOnly }
        if let fold, fold.isHorizontal, fold.minY > size.height * 0.2, fold.maxY < size.height * 0.85 {
            return .stacked(videoBottom: fold.minY, controlsTop: fold.maxY)
        }
        if size.height > size.width * 1.1 {
            // Video as wide as the screen, at most 55 % of the height.
            let video = min(size.width * 9 / 16, size.height * 0.55)
            return .stacked(videoBottom: video, controlsTop: video)
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
    let video: Video
    /// Status overlay drawn on the video area.
    let videoOverlay: Overlay

    @StateObject private var holder = PadHolder()

    init(settings: RemotePlaySettings, gamepad: GamepadBridge, isRemote: Bool,
         @ViewBuilder video: () -> Video, @ViewBuilder videoOverlay: () -> Overlay) {
        self.settings = settings
        self.gamepad = gamepad
        self.isRemote = isRemote
        self.video = video()
        self.videoOverlay = videoOverlay()
    }

    private var touchEnabled: Bool {
        guard isRemote else { return false }
        switch settings.touchControls {
        case .on: return true
        case .off: return false
        case .automatic: return !gamepad.hasPhysicalController
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fold = FoldBand.read(proxy)
            let arrangement = PlayerArrangement.resolve(size: size, fold: fold, touch: touchEnabled)
            let pad = holder.pad(for: gamepad, haptics: settings.touchHaptics)

            ZStack(alignment: .top) {
                Color.black

                switch arrangement {
                case .videoOnly:
                    videoArea
                        .frame(width: size.width, height: size.height)

                case .overlay:
                    videoArea
                        .frame(width: size.width, height: size.height)
                    // Book pose (fold top to bottom): nothing in the centre
                        // column, so no control sits on the crease.
                    TouchControllerView(pad: pad, style: .overlay, opacity: settings.touchOpacity,
                                        avoidCenter: fold.map { !$0.isHorizontal } ?? false)
                        .frame(width: size.width, height: size.height)

                case .stacked(let videoBottom, let controlsTop):
                    VStack(spacing: 0) {
                        videoArea
                            .frame(width: size.width, height: videoBottom)
                        // The fold band itself: nothing interactive on the crease.
                        Color.black.frame(height: max(0, controlsTop - videoBottom))
                        TouchControllerView(pad: pad, style: .panel)
                            .frame(width: size.width, height: max(0, size.height - controlsTop))
                            .background(Brand.night)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: arrangement)
        }
        .ignoresSafeArea(.container, edges: .all)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            holder.current?.releaseAll()
        }
        .onChange(of: touchEnabled) { _, on in if !on { holder.current?.releaseAll() } }
    }

    private var videoArea: some View {
        video
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { videoOverlay }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
