#if os(tvOS)
import StoreKit
import SwiftUI

/// Legal links shown on the Apple TV paywall. Apple TV has no browser, so each
/// opens a page with the address and a QR code for a phone.
private enum TVLegalLink: String, Identifiable, CaseIterable {
    case terms, privacy
    var id: String { rawValue }

    /// PaywallView has no legal links of its own; Terms points at Apple's
    /// standard licensed-application EULA. Privacy has no URL in the repo yet:
    /// set it here and its button appears.
    var url: URL? {
        switch self {
        case .terms: return URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
        case .privacy: return nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .terms: return "Terms of Use"
        case .privacy: return "Privacy Policy"
        }
    }

    var icon: String {
        switch self {
        case .terms: return "doc.text"
        case .privacy: return "hand.raised"
        }
    }

    static var available: [TVLegalLink] { allCases.filter { $0.url != nil } }
}

/// The Couchport Pro purchase page on Apple TV: what Pro adds on the left,
/// price and Buy on the right. Same store calls as `PaywallView`.
struct TVPaywallView: View {
    let reason: PaywallReason
    @ObservedObject private var store = PurchaseManager.shared
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @State private var legal: TVLegalLink?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case buy, restore, legal(TVLegalLink)
    }

    var body: some View {
        TVPage(title: "Couchport Pro", subtitle: headline, leadingWidth: 1000) {
            features
            platforms
        } trailing: {
            actions
        }
        .defaultFocus($focus, .buy)
        .onAppear { if !store.isPro { focus = .buy } }
        .task { await store.loadProduct() }
        .onChange(of: store.isPro) { _, pro in
            if pro {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    dismiss()
                }
            }
        }
        .adaptiveSheet(item: $legal) { link in
            TVLegalLinkPage(link: link)
        }
    }

    private var headline: LocalizedStringKey {
        if store.isPro { return "Pro is unlocked. Thank you for supporting Couchport!" }
        switch reason {
        case .timeUp: return "Today's free 10 minutes are used up. Come back tomorrow, or unlock Pro to play without limits."
        case .capture: return "The capture card mode is part of Couchport Pro."
        case .feature: return "This setting is part of Couchport Pro."
        case .browse: return "One purchase. Yours forever, with no subscription."
        }
    }

    // MARK: Left column

    private var features: some View {
        TVCard {
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 16) {
                GridRow {
                    Text(verbatim: "")
                    Text("Free")
                        .foregroundStyle(.secondary)
                    Text(verbatim: "Pro")
                        .foregroundStyle(Brand.blue.mix(with: .white, by: 0.4))
                }
                .font(TVMetrics.caption.weight(.bold))
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Play time", icon: "timer", free: Text("10 min per day"), pro: Text("Unlimited"))
                row("Resolution", icon: "sparkles.tv", free: Text(verbatim: "720p"), pro: Text(verbatim: "1080p"))
                row("Bitrate", icon: "dial.medium", free: Text(verbatim: "10–20 Mbps"), pro: Text("Auto, 5–50 Mbps"))
                row("HDR (10-bit)", icon: "sun.max.fill", free: nil, pro: nil)
                row("Picture Enhancement", icon: "wand.and.stars", free: nil, pro: nil)
                // Pro is one universal purchase, so the Vision Pro capture
                // mode is listed here too, as on every platform.
                row("Developer Strap Capture Card (Vision Pro only)", icon: "cable.connector.horizontal", free: nil, pro: nil)
            }
        }
    }

    /// A comparison row. `nil` cells show ✕ for Free and ✓ for Pro.
    private func row(_ title: LocalizedStringKey, icon: String, free: Text?, pro: Text?) -> some View {
        GridRow {
            Label(title, systemImage: icon)
                .font(TVMetrics.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let free { free } else { Image(systemName: "xmark") }
            }
            .foregroundStyle(.secondary)
            Group {
                if let pro { pro } else { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
        }
        .font(TVMetrics.caption)
    }

    /// "One purchase. Every device." Product names as plain text.
    private var platforms: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("One purchase. Every device.")
                .font(TVMetrics.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 14) {
                platformChip("Apple Vision Pro", available: true)
                platformChip("iPhone Duo", available: true)
                platformChip("iPhone", available: true)
                platformChip("iPad", available: true)
                platformChip("Apple TV", available: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func platformChip(_ name: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(available ? Color.green : Color.secondary)
            Text(verbatim: name)
                .font(TVMetrics.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            if !available {
                Text("Coming later")
                    .font(TVMetrics.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(available ? Brand.blue.opacity(0.28) : Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(available ? Brand.blue.opacity(0.7) : Color.white.opacity(0.2), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Right column

    @ViewBuilder
    private var actions: some View {
        TVCard {
            HStack(spacing: 24) {
                Image("AppMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .shadow(color: Brand.blue.opacity(0.5), radius: 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    if let product = store.product {
                        Text(verbatim: product.displayPrice)
                            .font(.system(size: 64, weight: .bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    } else if !store.isPro {
                        ProgressView()
                    }
                    Text("One purchase. Yours forever, with no subscription.")
                        .font(TVMetrics.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if store.isPro {
            Label("Pro Unlocked", systemImage: "checkmark.seal.fill")
                .font(TVMetrics.sectionTitle)
                .foregroundStyle(.green)
        } else {
            Button {
                Task { await store.buy(with: purchase) }
            } label: {
                Group {
                    if store.isBusy {
                        ProgressView()
                    } else if let product = store.product {
                        Text("Unlock Pro · \(product.displayPrice)")
                    } else {
                        Text("Unlock Pro")
                    }
                }
                .font(TVMetrics.sectionTitle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.blue)
            .disabled(store.isBusy)
            .focused($focus, equals: .buy)

            Button {
                Task { await store.restore() }
            } label: {
                Text("Restore Purchases")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isBusy)
            .focused($focus, equals: .restore)
        }

        // Covers "waiting for approval" (pending), unverified and errors.
        if let message = store.message {
            Text(message)
                .font(TVMetrics.body)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("A one-time purchase that unlocks Pro on Apple Vision Pro, iPhone Duo, iPhone, iPad and Apple TV. Family Sharing and restore work with the same Apple Account.")
            .font(TVMetrics.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if !TVLegalLink.available.isEmpty {
            HStack(spacing: 24) {
                ForEach(TVLegalLink.available) { link in
                    Button {
                        legal = link
                    } label: {
                        Label(link.title, systemImage: link.icon)
                            .font(TVMetrics.caption)
                    }
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .legal(link))
                }
            }
            .focusSection()
        }
    }
}

/// A small full-screen page with a legal link's address and QR code.
private struct TVLegalLinkPage: View {
    let link: TVLegalLink
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 36) {
            Text(link.title)
                .font(TVMetrics.pageTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let url = link.url {
                TVQRCode(text: url.absoluteString, size: 320)
                Text("Scan with your phone to open this page.")
                    .font(TVMetrics.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: url.absoluteString)
                    .font(TVMetrics.caption.monospaced())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 1400)
            }
            Button("Close") { dismiss() }
                .focused($closeFocused)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { closeFocused = true }
        .onExitCommand { dismiss() }
    }
}
#endif
