import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One place for every visionOS ↔ iOS/iPadOS ↔ tvOS difference, so the shared
/// views stay platform-neutral. visionOS keeps its original look; iPhone
/// (including the foldable iPhone Duo) and iPad get layouts driven by the
/// window width, so they follow fold/unfold, rotation and Split View live;
/// Apple TV is always the wide layout, driven by focus and a game controller.
enum Platform {
    static var isVision: Bool {
        #if os(visionOS)
        return true
        #else
        return false
        #endif
    }

    /// Apple TV. No touch, no web view, no Slider: focus engine + controller.
    static var isTV: Bool {
        #if os(tvOS)
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
    /// The iPhone, iPad and Apple TV apps are Remote Play only.
    static var supportsCapture: Bool { isVision }

    /// Apple TV has no touch screen: a game controller is required to play.
    static var requiresGameController: Bool { isTV }

    /// Home hero headline for this device.
    @MainActor
    static var heroHeadline: LocalizedStringKey {
        #if os(visionOS)
        return "Your PS5, streamed to Vision Pro"
        #elseif os(tvOS)
        return "Your PS5, streamed to Apple TV"
        #else
        return isPad ? "Your PS5, streamed to iPad" : "Your PS5, streamed to iPhone"
        #endif
    }

    /// Wi-Fi tip under the hero.
    @MainActor
    static var networkTip: LocalizedStringKey {
        #if os(visionOS)
        return "Best with the PS5 on Ethernet and Vision Pro on 5 GHz or 6 GHz Wi-Fi."
        #elseif os(tvOS)
        return "Best with the PS5 and Apple TV both on Ethernet, or Apple TV on 5 GHz or 6 GHz Wi-Fi."
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
    /// Glass on visionOS; a material card on iPhone and iPad; on Apple TV a
    /// slightly denser material so text stays readable from the couch.
    @ViewBuilder
    func adaptiveGlass<S: InsettableShape>(in shape: S) -> some View {
        #if os(visionOS)
        self.glassBackgroundEffect(in: shape)
        #elseif os(tvOS)
        self.background(.thinMaterial, in: shape)
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }

    /// Minimum window/sheet size. visionOS windows need it; on iPhone it would
    /// force sheets wider than the screen, and iPad and Apple TV size sheets
    /// themselves (tvOS sheets are full screen).
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
    /// tvOS does the same with a `GCEventViewController` around the video
    /// (`TVGameSurface`, controllerUserInteractionEnabled = false while
    /// streaming), so this modifier has nothing to add there.
    @ViewBuilder
    func streamOwnsGamepad(_ app: AppModel) -> some View {
        #if os(visionOS)
        self.handlesGameControllerEvents(matching: app.gamepadEventsForUI)
        #else
        self
        #endif
    }

    /// Full-screen video on iPhone/iPad: no status bar, home indicator dims.
    /// Apple TV: edge to edge (the picture ignores the overscan safe area).
    @ViewBuilder
    func immersivePlayerChrome() -> some View {
        #if os(iOS)
        self
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .ignoresSafeArea()
        #elseif os(tvOS)
        self.ignoresSafeArea()
        #else
        self
        #endif
    }

    /// `.scrollContentBackground(.hidden)` for Forms and Lists, so the brand
    /// backdrop shows through. tvOS has no such modifier (its Forms are
    /// already transparent), so it is a no-op there.
    @ViewBuilder
    func formBackgroundHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    /// `.textSelection(.enabled)` where text can be selected (not on tvOS).
    @ViewBuilder
    func selectableText() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }

    /// Rounded-border text fields (iOS/visionOS). tvOS has no such style;
    /// its focusable fields are already drawn as rounded plates.
    @ViewBuilder
    func roundedFieldStyle() -> some View {
        #if os(tvOS)
        self
        #else
        self.textFieldStyle(.roundedBorder)
        #endif
    }

    /// Plain buttons elsewhere; `.card` on tvOS, where a plain button gives
    /// almost no focus feedback.
    @ViewBuilder
    func plainOrCardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Buttons used as Form/List rows: plain elsewhere (the row is the
    /// button); on tvOS the default row style, which draws the focus plate.
    @ViewBuilder
    func formRowButtonStyle() -> some View {
        #if os(tvOS)
        self
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Borderless icon buttons/menus elsewhere; bordered on tvOS so they get
    /// a visible focus plate.
    @ViewBuilder
    func borderlessOrBorderedButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.bordered)
        #else
        self.buttonStyle(.borderless)
        #endif
    }
}

/// A `Slider` where one exists; on tvOS (no Slider) a − value + row that the
/// focus engine and the remote can drive, stepping by `step`.
struct AdaptiveSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float = 0.1
    /// Optional label for the current value on tvOS (e.g. "80%").
    var valueText: ((Float) -> String)? = nil

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 16) {
            Button {
                value = max(range.lowerBound, (value - step).roundedTo(step))
            } label: {
                Image(systemName: "minus")
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel(Text("Decrease"))

            Text(verbatim: valueText?(value) ?? String(format: "%.2f", value))
                .font(.callout.monospacedDigit())
                .frame(minWidth: 90)

            Button {
                value = min(range.upperBound, (value + step).roundedTo(step))
            } label: {
                Image(systemName: "plus")
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel(Text("Increase"))
        }
        #else
        Slider(value: $value, in: range)
        #endif
    }
}

private extension Float {
    /// Snaps to the step grid so repeated presses do not drift (0.30000001).
    func roundedTo(_ step: Float) -> Float {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}

/// Narrow (iPhone, iPhone Duo folded, narrow Split View) or wide (iPhone Duo
/// opened, iPad, visionOS window). Switches on measured width, never on the
/// device model.
struct LayoutClass: Equatable {
    let isCompact: Bool

    init(width: CGFloat) {
        #if os(visionOS) || os(tvOS)
        // Apple TV is always a big screen: never the compact layout.
        isCompact = false
        #else
        isCompact = width < 600
        #endif
    }

    var pagePadding: CGFloat { isCompact ? 16 : (Platform.isVision ? 48 : (Platform.isTV ? 64 : 28)) }
    var sectionSpacing: CGFloat { isCompact ? 24 : (Platform.isTV ? 56 : 36) }
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
