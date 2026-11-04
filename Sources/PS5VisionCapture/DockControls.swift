import SwiftUI

/// Shared player-control style: a circular icon with a short caption under
/// it, used by the visionOS theater dock, the visionOS window ornament and the
/// iPhone / iPad floating panel.
enum DockItemSize {
    case regular   // visionOS (theater dock, window ornament)
    case compact   // iPhone / iPad panel

    var circle: CGFloat { self == .regular ? 72 : 54 }
    var icon: CGFloat { self == .regular ? 28 : 21 }
    var minWidth: CGFloat { self == .regular ? 92 : 64 }
    var caption: Font { self == .regular ? .callout.weight(.medium) : .caption.weight(.medium) }
}

/// Visual of one dock item. Wrap it in a Button / Menu label, or attach a
/// gesture (move handle).
struct DockItem: View {
    let title: LocalizedStringKey
    var icon: String = ""
    var isOn = false
    /// Solid fill (Stop = red). Overrides the on/off colours.
    var fill: Color? = nil
    /// Neutral "PS" text glyph instead of an SF Symbol (no Sony logo).
    var psGlyph = false
    var size: DockItemSize = .regular
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: size == .regular ? 8 : 6) {
            glyph
                .font(.system(size: size.icon, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size.circle, height: size.circle)
                .background(Circle().fill(background))
                .overlay(Circle().strokeBorder(.white.opacity(isOn ? 0.55 : 0.12), lineWidth: 1.5))
                #if !os(tvOS)
                .contentShape(.hoverEffect, Circle())
                .hoverEffect()
                #endif
            Text(title)
                .font(size.caption)
                .foregroundStyle(isOn ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(size == .regular ? 1 : 2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: size == .regular, vertical: true)
        }
        .frame(minWidth: size.minWidth)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? Text("On") : Text(verbatim: ""))
    }

    @ViewBuilder private var glyph: some View {
        if psGlyph {
            Text(verbatim: "PS")
                .font(.system(size: size.icon * 0.86, weight: .heavy, design: .rounded))
        } else {
            Image(systemName: icon)
        }
    }

    private var background: Color {
        if let fill { return fill }
        return isOn ? Brand.blue : .white.opacity(0.10)
    }
}

struct DockButton: View {
    let title: LocalizedStringKey
    var icon: String = ""
    var isOn = false
    var fill: Color? = nil
    var psGlyph = false
    var size: DockItemSize = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DockItem(title: title, icon: icon, isOn: isOn, fill: fill,
                     psGlyph: psGlyph, size: size)
        }
        .buttonStyle(.plain)
    }
}

/// Thin vertical separator between dock groups.
struct DockDivider: View {
    var height: CGFloat = 56
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.18))
            .frame(width: 2, height: height)
            .padding(.horizontal, 8)
            .padding(.top, height * 0.18)
            .allowsHitTesting(false)
    }
}
