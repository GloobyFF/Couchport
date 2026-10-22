import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One place for every visionOS ↔ iOS/iPadOS difference, so the shared views
/// stay platform-neutral. visionOS keeps its original look; iPhone (including
/// the foldable iPhone Duo) and iPad get layouts driven by the window width,
/// so they follow fold/unfold, rotation and Split View live.
enum Platform {
    static var isVision: Bool {
        #if os(visionOS)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    static var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    /// The immersive curved-screen theater exists only on visionOS.
    static var supportsTheater: Bool { isVision }

    /// UVC capture cards (Developer Strap) are a Vision Pro feature only.
    /// The iPhone and iPad app is Remote Play only.
    static var supportsCapture: Bool { isVision }

    /// Home hero headline for this device.
    @MainActor
    static var heroHeadline: LocalizedStringKey {
        #if os(visionOS)
        return "Your PS5, streamed to Vision Pro"
        #else
        return isPad ? "Your PS5, streamed to iPad" : "Your PS5, streamed to iPhone"
        #endif
    }

    /// Wi-Fi tip under the hero.
    @MainActor
    static var networkTip: LocalizedStringKey {
        #if os(visionOS)
        return "Best with the PS5 on Ethernet and Vision Pro on 5 GHz or 6 GHz Wi-Fi."
        #else
        return "Best with the PS5 on Ethernet and this device on 5 GHz or 6 GHz Wi-Fi."
        #endif
    }
}

extension Font {
    /// Big hero titles. `.extraLargeTitle2` is visionOS-only.
    static var heroTitle: Font {
        #if os(visionOS)
        return .extraLargeTitle2
        #else
        return .largeTitle.weight(.bold)
        #endif
    }
}

extension View {
    /// Glass on visionOS; a material card on iPhone and iPad.
    @ViewBuilder
    func adaptiveGlass<S: Shape>(in shape: S) -> some View {
        #if os(visionOS)
        self.glassBackgroundEffect(in: shape)
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }

    /// Minimum window/sheet size. visionOS windows need it; on iPhone it would
    /// force sheets wider than the screen, and iPad sizes sheets itself.
    @ViewBuilder
    func visionMinFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(visionOS)
        self.frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }

    /// While streaming, controller input belongs to the console, not our UI.
    /// visionOS drives UI focus from a gamepad, so it is routed away there.
    @ViewBuilder
    func streamOwnsGamepad(_ app: AppModel) -> some View {
        #if os(visionOS)
        self.handlesGameControllerEvents(matching: app.gamepadEventsForUI)
        #else
        self
        #endif
    }

    /// Full-screen video on iPhone/iPad: no status bar, home indicator dims.
    @ViewBuilder
    func immersivePlayerChrome() -> some View {
        #if os(iOS)
        self
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .ignoresSafeArea()
        #else
        self
        #endif
    }
}

/// Narrow (iPhone, iPhone Duo folded, narrow Split View) or wide (iPhone Duo
/// opened, iPad, visionOS window). Switches on measured width, never on the
/// device model.
struct LayoutClass: Equatable {
    let isCompact: Bool

    init(width: CGFloat) {
        #if os(visionOS)
        isCompact = false
        #else
        isCompact = width < 600
        #endif
    }

    var pagePadding: CGFloat { isCompact ? 16 : (Platform.isVision ? 48 : 28) }
    var sectionSpacing: CGFloat { isCompact ? 24 : 36 }
}

private struct LayoutClassKey: EnvironmentKey {
    static let defaultValue = LayoutClass(width: 1000)
}

extension EnvironmentValues {
    var layoutClass: LayoutClass {
        get { self[LayoutClassKey.self] }
        set { self[LayoutClassKey.self] = newValue }
    }
}

/// Measures its width and publishes the `LayoutClass` to descendants.
struct MeasuredLayout<Content: View>: View {
    @ViewBuilder var content: (LayoutClass) -> Content
    @State private var width: CGFloat = 1000

    var body: some View {
        let layout = LayoutClass(width: width)
        content(layout)
            .environment(\.layoutClass, layout)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
