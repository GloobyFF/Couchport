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
    /// Controller key (PS, touchpad click): a distinct violet gradient so the
    /// keys that go to the console stand apart from app controls.
    var controllerKey = false
    var size: DockItemSize = .regular
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: size == .regular ? 8 : 6) {
            glyph
                .font(.system(size: size.icon, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size.circle, height: size.circle)
                .background(Circle().fill(background))
                .overlay(Circle().strokeBorder(.white.opacity(isOn || controllerKey ? 0.45 : 0.12), lineWidth: 1.5))
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

    static let controllerKeyGradient = LinearGradient(
        colors: [Color(red: 0.44, green: 0.36, blue: 1.0), Color(red: 0.84, green: 0.38, blue: 0.84)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private var background: AnyShapeStyle {
        if controllerKey { return AnyShapeStyle(Self.controllerKeyGradient) }
        if let fill { return AnyShapeStyle(fill) }
        return AnyShapeStyle(isOn ? Brand.blue : Color.white.opacity(0.10))
    }
}

struct DockButton: View {
    let title: LocalizedStringKey
    var icon: String = ""
    var isOn = false
    var fill: Color? = nil
    var psGlyph = false
    var controllerKey = false
    var size: DockItemSize = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DockItem(title: title, icon: icon, isOn: isOn, fill: fill,
                     psGlyph: psGlyph, controllerKey: controllerKey, size: size)
        }
        .buttonStyle(.plain)
    }
}

/// The keys that go straight to the console, kept together: PS and the
/// touchpad click, split by a thin divider inside one tinted pill.
struct DockControllerKeys: View {
    var size: DockItemSize = .regular
    let enabled: Bool
    let onPS: () -> Void
    let onTouchpad: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            DockButton(title: "PS", psGlyph: true, controllerKey: true, size: size, action: onPS)
                .accessibilityLabel(Text("PS Button"))
            DockDivider(height: size.circle * 0.8)
            DockButton(title: "Touchpad", icon: "hand.tap.fill", controllerKey: true,
                       size: size, action: onTouchpad)
                .accessibilityLabel(Text("Touchpad Button"))
        }
        .padding(.horizontal, size == .regular ? 10 : 6)
        .padding(.vertical, size == .regular ? 8 : 6)
        .background(RoundedRectangle(cornerRadius: size == .regular ? 30 : 22, style: .continuous)
            .fill(Color(red: 0.62, green: 0.42, blue: 1.0).opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: size == .regular ? 30 : 22, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .disabled(!enabled)
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
