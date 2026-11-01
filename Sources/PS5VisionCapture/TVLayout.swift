import SwiftUI
#if os(tvOS)
import CoreImage.CIFilterBuiltins
#endif

// MARK: - Presentation that fits every platform

extension View {
    /// `.sheet` on visionOS / iOS. On Apple TV a sheet is a narrow phone-sized
    /// card, so it becomes a full-screen page instead (Menu closes it).
    @ViewBuilder
    func adaptiveSheet<Sheet: View>(isPresented: Binding<Bool>,
                                    @ViewBuilder content: @escaping () -> Sheet) -> some View {
        #if os(tvOS)
        self.fullScreenCover(isPresented: isPresented) {
            content().tvPageBackground()
        }
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    /// Item-driven variant of `adaptiveSheet(isPresented:)`.
    @ViewBuilder
    func adaptiveSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>,
                                                        @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        #if os(tvOS)
        self.fullScreenCover(item: item) { value in
            content(value).tvPageBackground()
        }
        #else
        self.sheet(item: item, content: content)
        #endif
    }

    /// The brand backdrop behind a full-screen TV page.
    @ViewBuilder
    func tvPageBackground() -> some View {
        #if os(tvOS)
        self.background { HomeBackground().ignoresSafeArea() }
        #else
        self
        #endif
    }
}

#if os(tvOS)

// MARK: - TV metrics

/// 10-foot design numbers for Apple TV (1920×1080 points). Content always stays
/// inside the system safe area (≈60 pt top/bottom, 80 pt sides), which SwiftUI
/// applies as long as content never ignores it.
enum TVMetrics {
    static let columnSpacing: CGFloat = 80
    static let sectionSpacing: CGFloat = 48
    static let cardCorner: CGFloat = 28
    static let leftColumnWidth: CGFloat = 640
    static let pageTitle: Font = .system(size: 64, weight: .bold)
    static let sectionTitle: Font = .system(size: 38, weight: .semibold)
    static let body: Font = .system(size: 29)
    static let caption: Font = .system(size: 23)
}

// MARK: - Full-screen page

/// A full-screen Apple TV page: title at the top left, then a left column
/// (explanation) and a right column (actions), each its own focus section so
/// the remote moves cleanly between them. Menu dismisses the page.
struct TVPage<Leading: View, Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var leadingWidth: CGFloat = TVMetrics.leftColumnWidth
    var onClose: (() -> Void)? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(TVMetrics.pageTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let subtitle {
                        Text(subtitle)
                            .font(TVMetrics.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 40)
                Button {
                    close()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
            .focusSection()

            HStack(alignment: .top, spacing: TVMetrics.columnSpacing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) { leading }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: leadingWidth)
                .focusSection()

                ScrollView {
                    VStack(alignment: .leading, spacing: 32) { trailing }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24) // room for the focus lift
                }
                .frame(maxWidth: .infinity)
                .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { close() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

/// A rounded translucent card used for groups on TV pages.
struct TVCard<Content: View>: View {
    var padding: CGFloat = 36
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TVMetrics.cardCorner, style: .continuous))
    }
}

/// A numbered explanatory step for the left column of a TV page.
struct TVStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(verbatim: "\(number)")
                .font(.system(size: 26, weight: .bold).monospacedDigit())
                .frame(width: 52, height: 52)
                .background(Brand.blue.opacity(0.85), in: Circle())
            Text(text)
                .font(TVMetrics.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - QR code

/// A crisp QR code for a URL, so people can open links (source code, terms)
/// on their phone: Apple TV has no browser.
struct TVQRCode: View {
    let text: String
    var size: CGFloat = 240

    var body: some View {
        Group {
            if let image = Self.render(text) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

#endif
