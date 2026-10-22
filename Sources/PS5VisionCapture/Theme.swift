import SwiftUI

/// PlayStation-style brand colours shared by every screen.
enum Brand {
    static let blue = Color(red: 0.0, green: 0.44, blue: 0.82)        // #0070D1
    static let deepBlue = Color(red: 0.04, green: 0.12, blue: 0.36)   // #0B1E5B
    static let night = Color(red: 0.02, green: 0.05, blue: 0.15)
    /// Fill for a group of controls sitting on the blue backdrop.
    static let groupFill = Color.white.opacity(0.07)
}

/// Blue gradient with the △ ○ ✕ □ pattern. Decoration only (never hit-testable).
struct BrandBackdrop: View {
    var patternOpacity: Double = 0.45
    var opacity: Double = 1

    var body: some View {
        ZStack {
            LinearGradient(colors: [Brand.deepBlue, Brand.night],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image("HomePattern")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(patternOpacity)
            LinearGradient(colors: [.clear, Brand.night.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        }
        .opacity(opacity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Glass panel tinted with the brand backdrop, for floating controls and
    /// panels (ornaments, the immersive toolbar, inline panels).
    func brandPanel<S: InsettableShape>(in shape: S, patternOpacity: Double = 0.35) -> some View {
        self
            .background {
                BrandBackdrop(patternOpacity: patternOpacity, opacity: 0.88)
                    .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(Brand.blue.opacity(0.45), lineWidth: 1.2)
                    .allowsHitTesting(false)
            }
            .adaptiveGlass(in: shape)
    }

    /// Full-window brand background for sheets and window content. Forms
    /// inside need `.scrollContentBackground(.hidden)` to show it.
    func brandWindowBackground() -> some View {
        self.background { BrandBackdrop().ignoresSafeArea() }
    }
}

/// Sheet chrome with a Done button and the blue backdrop.
struct PanelSheet<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .scrollContentBackground(.hidden)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .brandWindowBackground()
        .visionMinFrame(width: 480, height: 560)
    }
}
