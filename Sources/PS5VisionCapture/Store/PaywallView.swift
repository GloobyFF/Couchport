import StoreKit
import SwiftUI

/// The Couchport Pro purchase sheet.
struct PaywallView: View {
    let reason: PaywallReason
    @ObservedObject private var store = PurchaseManager.shared
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    header
                    comparison
                    actions
                }
                .padding(.horizontal, Platform.isVision ? 40 : 20)
                .padding(.vertical, 28)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .brandWindowBackground()
        .visionMinFrame(width: 620, height: 720)
        .task { await store.loadProduct() }
        .onChange(of: store.isPro) { _, pro in
            if pro {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    dismiss()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .shadow(color: Brand.blue.opacity(0.5), radius: 16)
                .accessibilityHidden(true)

            Text("Couchport Pro")
                .font(.heroTitle)

            Text(headline)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: LocalizedStringKey {
        if store.isPro { return "Pro is unlocked. Thank you for supporting Couchport!" }
        switch reason {
        case .timeUp: return "Your free 10 minutes are up. Unlock Pro to play without limits."
        case .capture: return "The capture card mode is part of Couchport Pro."
        case .feature: return "This setting is part of Couchport Pro."
        case .browse: return "One purchase. Yours forever, with no subscription."
        }
    }

    private var comparison: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
            GridRow {
                Text(verbatim: "")
                Text("Free").font(.headline).foregroundStyle(.secondary)
                Text(verbatim: "Pro").font(.headline).foregroundStyle(Brand.blue.mix(with: .white, by: 0.4))
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("Play time", icon: "timer", free: Text("10 min per session"), pro: Text("Unlimited"))
            row("Resolution", icon: "sparkles.tv", free: Text(verbatim: "720p"), pro: Text(verbatim: "1080p"))
            row("Bitrate", icon: "dial.medium", free: Text(verbatim: "10–20 Mbps"), pro: Text("Auto, 5–50 Mbps"))
            row("HDR (10-bit)", icon: "sun.max.fill", free: nil, pro: nil)
            row("Picture Enhancement", icon: "wand.and.stars", free: nil, pro: nil)
            row("Capture Card (Developer Strap)", icon: "cable.connector.horizontal", free: nil, pro: nil)
        }
        .padding(24)
        .brandPanel(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// A comparison row. `nil` cells show ✕ for Free and ✓ for Pro.
    private func row(_ title: LocalizedStringKey, icon: String, free: Text?, pro: Text?) -> some View {
        GridRow {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
            Group {
                if let free { free } else { Image(systemName: "xmark").foregroundStyle(.secondary) }
            }
            .foregroundStyle(.secondary)
            Group {
                if let pro { pro } else { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            if store.isPro {
                Label("Pro Unlocked", systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold))
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
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.blue)
                .controlSize(.extraLarge)
                .disabled(store.isBusy)

                Button("Restore Purchases") {
                    Task { await store.restore() }
                }
                .disabled(store.isBusy)
            }

            if let message = store.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Text("A one-time purchase. Family Sharing and restore work with the same Apple Account.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Small "PRO" capsule shown next to locked features.
struct ProBadge: View {
    var body: some View {
        Text(verbatim: "PRO")
            .font(.caption2.weight(.heavy))
            .tracking(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Brand.blue, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel(Text("Pro feature"))
    }
}

/// A Form row that explains a lock and opens the paywall.
struct ProUpsellRow: View {
    let title: LocalizedStringKey
    var onUpgrade: (() -> Void)?

    var body: some View {
        Button {
            if let onUpgrade { onUpgrade() } else { PurchaseManager.shared.requestPaywall(.feature) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Brand.blue.mix(with: .white, by: 0.4))
                Text(title)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                ProBadge()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Remaining free time as a small capsule, e.g. "Free · 7:32".
struct FreeTimeChip: View {
    let secondsLeft: Int

    var body: some View {
        Label {
            Text("Free · \(Self.format(secondsLeft))")
                .monospacedDigit()
        } icon: {
            Image(systemName: "timer")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background((secondsLeft <= Int(FreeTier.warningLead) ? Color.orange : Brand.blue).opacity(0.85),
                    in: Capsule())
        .foregroundStyle(.white)
    }

    static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}
