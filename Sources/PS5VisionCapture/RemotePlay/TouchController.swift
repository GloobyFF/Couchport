#if os(iOS)
import SwiftUI
import UIKit

// MARK: - State

/// The on-screen controller's live state. Every control writes into one
/// snapshot, which is merged with any hardware controller by GamepadBridge.
@MainActor
final class VirtualPad: ObservableObject {
    private weak var bridge: GamepadBridge?
    private var snapshot = GamepadSnapshot()
    private let impact = UIImpactFeedbackGenerator(style: .light)
    var hapticsEnabled = true

    init(bridge: GamepadBridge) {
        self.bridge = bridge
        impact.prepare()
    }

    /// PlayStation button bits, matching GamepadBridge.snapshot(of:).
    enum Button: UInt32 {
        case cross = 1, circle = 2, square = 4, triangle = 8
        case left = 16, right = 32, up = 64, down = 128
        case l1 = 256, r1 = 512, l3 = 1024, r3 = 2048
        case options = 4096, create = 8192, touchpad = 16384, ps = 32768
    }

    func set(_ button: Button, _ pressed: Bool) {
        let before = snapshot.buttons
        if pressed { snapshot.buttons |= button.rawValue } else { snapshot.buttons &= ~button.rawValue }
        guard before != snapshot.buttons else { return }
        if pressed && hapticsEnabled { impact.impactOccurred(intensity: 0.7) }
        push()
    }

    func setTrigger(left: Bool, pressed: Bool) {
        let value: UInt8 = pressed ? 255 : 0
        if left {
            guard snapshot.l2 != value else { return }
            snapshot.l2 = value
        } else {
            guard snapshot.r2 != value else { return }
            snapshot.r2 = value
        }
        if pressed && hapticsEnabled { impact.impactOccurred(intensity: 0.7) }
        push()
    }

    /// x, y in -1...1, y down (PlayStation convention).
    func setStick(left: Bool, x: CGFloat, y: CGFloat) {
        let ax = Int16(clamping: Int((max(-1, min(1, x)) * 32767).rounded()))
        let ay = Int16(clamping: Int((max(-1, min(1, y)) * 32767).rounded()))
        if left { snapshot.leftX = ax; snapshot.leftY = ay } else { snapshot.rightX = ax; snapshot.rightY = ay }
        push()
    }

    /// Touchpad finger in unit coordinates (0...1, y down); nil lifts it.
    func setTouch(_ point: CGPoint?) {
        if let point {
            let x = UInt16(clamping: Int((max(0, min(1, point.x)) * 1919).rounded()))
            let y = UInt16(clamping: Int((max(0, min(1, point.y)) * 941).rounded()))
            snapshot.touch0 = SIMD2(x, y)
        } else {
            snapshot.touch0 = nil
        }
        push()
    }

    /// Releases everything (controller hidden, session ending, app inactive).
    func releaseAll() {
        snapshot = GamepadSnapshot()
        push()
    }

    private func push() { bridge?.setVirtual(snapshot) }
}

// MARK: - Layout

/// Where the on-screen controller sits.
enum TouchControllerStyle {
    /// Translucent, over the video (landscape, iPhone Duo opened flat).
    case overlay
    /// Its own area under the video (portrait, iPhone Duo folded or in
    /// tabletop pose with the controls on the lower half).
    case panel
}

/// The full on-screen DualSense-style controller. Sizes come from the space
/// it is given, so it works on a 466-pt-wide outer display, a phone in
/// landscape, the iPhone Duo's inner display and an iPad.
struct TouchControllerView: View {
    @ObservedObject var pad: VirtualPad
    let style: TouchControllerStyle
    var opacity: Double = 0.6
    /// Leave the centre column empty (iPhone Duo book pose: the fold runs
    /// down the middle). System buttons move under the shoulder buttons.
    var avoidCenter = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let u = unit(for: size)
            ZStack {
                switch style {
                case .overlay: overlayLayout(size: size, u: u)
                case .panel: panelLayout(size: size, u: u)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .opacity(style == .overlay ? opacity : 1)
        .onDisappear { pad.releaseAll() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("On-Screen Controller"))
    }

    /// Base size: a face button is about one unit.
    private func unit(for size: CGSize) -> CGFloat {
        let short = min(size.width, size.height)
        switch style {
        case .overlay: return max(40, min(64, short / 6.2))
        case .panel: return max(40, min(70, min(size.width / 8.5, size.height / 5.2)))
        }
    }

    // Landscape: shoulders in the top corners, sticks and buttons at the
    // bottom corners, system buttons bottom centre. The middle stays clear
    // for the picture.
    @ViewBuilder
    private func overlayLayout(size: CGSize, u: CGFloat) -> some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: u * 0.25) {
                    shoulderColumn(left: true, u: u)
                    if avoidCenter {
                        HStack(spacing: u * 0.3) {
                            PadButton(pad: pad, button: .create, label: .symbol("square.and.arrow.up"), u: u * 0.7, shape: .capsule)
                            touchpad(u: u * 0.6)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: u * 0.25) {
                    shoulderColumn(left: false, u: u)
                    if avoidCenter {
                        HStack(spacing: u * 0.3) {
                            PadButton(pad: pad, button: .ps, label: .text("PS"), u: u * 0.7, shape: .circle)
                            PadButton(pad: pad, button: .options, label: .symbol("line.3.horizontal"), u: u * 0.7, shape: .capsule)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: u * 0.4) {
                VStack(spacing: u * 0.35) {
                    DPad(pad: pad, u: u)
                    StickControl(pad: pad, left: true, u: u)
                }
                Spacer(minLength: 0)
                if !avoidCenter {
                    systemRow(u: u * 0.85)
                        .padding(.bottom, u * 0.2)
                    Spacer(minLength: 0)
                }
                VStack(spacing: u * 0.35) {
                    FaceButtons(pad: pad, u: u)
                    StickControl(pad: pad, left: false, u: u)
                }
            }
        }
        .padding(.horizontal, u * 0.45)
        .padding(.vertical, u * 0.3)
    }

    // Under the video: a controller-shaped panel, both thumbs low.
    @ViewBuilder
    private func panelLayout(size: CGSize, u: CGFloat) -> some View {
        VStack(spacing: u * 0.3) {
            HStack {
                HStack(spacing: u * 0.25) {
                    TriggerButton(pad: pad, left: true, u: u)
                    PadButton(pad: pad, button: .l1, label: .text("L1"), u: u, shape: .capsule)
                }
                Spacer()
                touchpad(u: u)
                Spacer()
                HStack(spacing: u * 0.25) {
                    PadButton(pad: pad, button: .r1, label: .text("R1"), u: u, shape: .capsule)
                    TriggerButton(pad: pad, left: false, u: u)
                }
            }
            HStack(alignment: .center) {
                DPad(pad: pad, u: u)
                Spacer(minLength: 0)
                VStack(spacing: u * 0.3) {
                    HStack(spacing: u * 0.5) {
                        PadButton(pad: pad, button: .create, label: .symbol("square.and.arrow.up"), u: u * 0.7, shape: .capsule)
                        PadButton(pad: pad, button: .options, label: .symbol("line.3.horizontal"), u: u * 0.7, shape: .capsule)
                    }
                    PadButton(pad: pad, button: .ps, label: .text("PS"), u: u * 0.8, shape: .circle)
                }
                Spacer(minLength: 0)
                FaceButtons(pad: pad, u: u)
            }
            HStack {
                Spacer()
                StickControl(pad: pad, left: true, u: u)
                Spacer()
                Spacer()
                StickControl(pad: pad, left: false, u: u)
                Spacer()
            }
        }
        .padding(.horizontal, u * 0.35)
        .padding(.vertical, u * 0.3)
    }

    private func shoulderColumn(left: Bool, u: CGFloat) -> some View {
        VStack(spacing: u * 0.2) {
            TriggerButton(pad: pad, left: left, u: u)
            PadButton(pad: pad, button: left ? .l1 : .r1, label: .text(left ? "L1" : "R1"), u: u, shape: .capsule)
        }
    }

    private func systemRow(u: CGFloat) -> some View {
        VStack(spacing: u * 0.3) {
            touchpad(u: u)
            HStack(spacing: u * 0.4) {
                PadButton(pad: pad, button: .create, label: .symbol("square.and.arrow.up"), u: u * 0.75, shape: .capsule)
                PadButton(pad: pad, button: .ps, label: .text("PS"), u: u * 0.8, shape: .circle)
                PadButton(pad: pad, button: .options, label: .symbol("line.3.horizontal"), u: u * 0.75, shape: .capsule)
            }
        }
    }

    private func touchpad(u: CGFloat) -> some View {
        TouchpadControl(pad: pad)
            .frame(width: u * 3.2, height: u * 1.1)
    }
}

// MARK: - Controls

private enum ButtonLabel {
    case text(String)
    case symbol(String)
}

private enum ButtonShape { case circle, capsule }

/// Press-and-hold button. A zero-distance drag gives press and release, and
/// separate views take separate fingers, so several can be held at once.
private struct PadButton: View {
    @ObservedObject var pad: VirtualPad
    let button: VirtualPad.Button
    let label: ButtonLabel
    let u: CGFloat
    var shape: ButtonShape = .circle
    @State private var pressed = false

    var body: some View {
        content
            .font(.system(size: u * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: shape == .circle ? u : u * 1.45, height: shape == .circle ? u : u * 0.7)
            .background(background)
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.92 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { pressed = true; pad.set(button, true) }
                }
                .onEnded { _ in
                    pressed = false
                    pad.set(button, false)
                })
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var content: some View {
        switch label {
        case .text(let s): Text(verbatim: s)
        case .symbol(let name): Image(systemName: name)
        }
    }

    @ViewBuilder private var background: some View {
        let fill = Color.white.opacity(pressed ? 0.45 : 0.16)
        switch shape {
        case .circle:
            Circle().fill(fill).overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        case .capsule:
            Capsule().fill(fill).overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
    }
}

/// L2 / R2 as full presses (touch has no analogue pressure).
private struct TriggerButton: View {
    @ObservedObject var pad: VirtualPad
    let left: Bool
    let u: CGFloat
    @State private var pressed = false

    var body: some View {
        Text(verbatim: left ? "L2" : "R2")
            .font(.system(size: u * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: u * 1.45, height: u * 0.8)
            .background(RoundedRectangle(cornerRadius: u * 0.25, style: .continuous)
                .fill(Color.white.opacity(pressed ? 0.45 : 0.16))
                .overlay(RoundedRectangle(cornerRadius: u * 0.25, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { pressed = true; pad.setTrigger(left: left, pressed: true) }
                }
                .onEnded { _ in
                    pressed = false
                    pad.setTrigger(left: left, pressed: false)
                })
    }
}

/// The four face buttons in a diamond. Generic geometric glyphs only.
private struct FaceButtons: View {
    @ObservedObject var pad: VirtualPad
    let u: CGFloat

    var body: some View {
        let gap = u * 0.08
        VStack(spacing: gap) {
            PadButton(pad: pad, button: .triangle, label: .symbol("triangle"), u: u)
            HStack(spacing: u + gap * 2) {
                PadButton(pad: pad, button: .square, label: .symbol("square"), u: u)
                PadButton(pad: pad, button: .circle, label: .symbol("circle"), u: u)
            }
            PadButton(pad: pad, button: .cross, label: .symbol("xmark"), u: u)
        }
    }
}

/// D-pad: one view, so sliding a thumb between directions works, including
/// diagonals.
private struct DPad: View {
    @ObservedObject var pad: VirtualPad
    let u: CGFloat
    @State private var active: Set<VirtualPad.Button> = []

    private struct Arrow {
        let button: VirtualPad.Button
        let symbol: String
        let dx: CGFloat
        let dy: CGFloat
    }

    private static let arrows: [Arrow] = [
        Arrow(button: .up, symbol: "arrowtriangle.up.fill", dx: 0, dy: -1),
        Arrow(button: .down, symbol: "arrowtriangle.down.fill", dx: 0, dy: 1),
        Arrow(button: .left, symbol: "arrowtriangle.left.fill", dx: -1, dy: 0),
        Arrow(button: .right, symbol: "arrowtriangle.right.fill", dx: 1, dy: 0),
    ]

    var body: some View {
        let side = u * 2.9
        ZStack {
            ForEach(Self.arrows, id: \.button) { item in
                Image(systemName: item.symbol)
                    .font(.system(size: u * 0.34))
                    .foregroundStyle(.white)
                    .frame(width: u * 0.95, height: u * 0.95)
                    .background(RoundedRectangle(cornerRadius: u * 0.18, style: .continuous)
                        .fill(Color.white.opacity(active.contains(item.button) ? 0.45 : 0.16)))
                    .offset(x: item.dx * u * 0.95, y: item.dy * u * 0.95)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in update(value.location, side: side) }
            .onEnded { _ in update(nil, side: side) })
    }

    private func update(_ point: CGPoint?, side: CGFloat) {
        var next: Set<VirtualPad.Button> = []
        if let point {
            let dx = (point.x - side / 2) / (side / 2)
            let dy = (point.y - side / 2) / (side / 2)
            let dead: CGFloat = 0.25
            if dx < -dead { next.insert(.left) }
            if dx > dead { next.insert(.right) }
            if dy < -dead { next.insert(.up) }
            if dy > dead { next.insert(.down) }
        }
        for b in active.subtracting(next) { pad.set(b, false) }
        for b in next.subtracting(active) { pad.set(b, true) }
        active = next
    }
}

/// Analogue stick. Drag from anywhere in the base; a quick double tap
/// clicks the stick (L3 / R3).
private struct StickControl: View {
    @ObservedObject var pad: VirtualPad
    let left: Bool
    let u: CGFloat
    @State private var knob: CGSize = .zero
    @State private var lastTap = Date.distantPast
    @State private var clicked = false

    var body: some View {
        let radius = u * 1.15
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.10))
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            Circle()
                .fill(Color.white.opacity(clicked ? 0.6 : 0.35))
                .frame(width: u * 1.0, height: u * 1.0)
                .offset(knob)
            Text(verbatim: left ? "L3" : "R3")
                .font(.system(size: u * 0.22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .offset(knob)
                .allowsHitTesting(false)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if knob == .zero && value.translation == .zero { beginTouch() }
                let v = CGSize(width: value.location.x - radius, height: value.location.y - radius)
                let len = max(1, hypot(v.width, v.height))
                let limit = radius - u * 0.5
                let scale = min(1, limit / len)
                knob = CGSize(width: v.width * scale, height: v.height * scale)
                pad.setStick(left: left, x: knob.width / limit, y: knob.height / limit)
            }
            .onEnded { _ in
                knob = .zero
                pad.setStick(left: left, x: 0, y: 0)
                if clicked {
                    clicked = false
                    pad.set(left ? .l3 : .r3, false)
                }
            })
    }

    /// Two touches within 0.3 s hold L3/R3 for the second touch.
    private func beginTouch() {
        let now = Date()
        if now.timeIntervalSince(lastTap) < 0.3 {
            clicked = true
            pad.set(left ? .l3 : .r3, true)
        }
        lastTap = now
    }
}

/// Touchpad strip: drag to move a finger on the console's touchpad, tap to
/// click it.
private struct TouchpadControl: View {
    @ObservedObject var pad: VirtualPad
    @State private var start: Date?
    @State private var moved = false

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(start == nil ? 0.10 : 0.25))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .overlay(Image(systemName: "hand.point.up.left")
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if start == nil { start = Date(); moved = false }
                        if hypot(value.translation.width, value.translation.height) > 8 { moved = true }
                        pad.setTouch(CGPoint(x: value.location.x / max(1, proxy.size.width),
                                             y: value.location.y / max(1, proxy.size.height)))
                    }
                    .onEnded { _ in
                        let tap = !moved && (start.map { Date().timeIntervalSince($0) < 0.25 } ?? false)
                        start = nil
                        pad.setTouch(nil)
                        if tap {
                            pad.set(.touchpad, true)
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(80))
                                pad.set(.touchpad, false)
                            }
                        }
                    })
        }
    }
}
#endif
