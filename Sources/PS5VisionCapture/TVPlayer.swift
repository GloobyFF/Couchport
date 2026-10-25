#if os(tvOS)
import GameController
import SwiftUI
import UIKit

/// Apple TV video surface: the Metal video view inside a
/// `GCEventViewController`.
///
/// While `ownsController` is true (streaming, no panel or alert open),
/// `controllerUserInteractionEnabled` is false: every controller input goes
/// to GameController only (and from there to the console), never to the tvOS
/// focus engine, and Menu does not leave the app. The Siri Remote is read
/// through GameController too in that state, so its Menu and Play/Pause
/// buttons still open the controls panel. When the panel or an alert is up,
/// normal focus navigation comes back.
struct TVGameSurface: UIViewControllerRepresentable {
    let renderer: MetalVideoRenderer
    /// The console owns the controller (true while streaming with no UI up).
    var ownsController: Bool
    /// The surface takes focus (false while the controls panel is open, so
    /// focus moves to the panel).
    var focusable: Bool
    /// Siri Remote / controller Menu (Back) button.
    var onMenu: () -> Void
    /// Siri Remote Play/Pause button.
    var onPlayPause: () -> Void

    func makeCoordinator() -> SiriRemoteCommands { SiriRemoteCommands() }

    func makeUIViewController(context: Context) -> TVGameViewController {
        let controller = TVGameViewController()
        renderer.attach(to: controller.surface.metalLayer)
        context.coordinator.start()
        apply(to: controller, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: TVGameViewController, context: Context) {
        renderer.attach(to: controller.surface.metalLayer)
        apply(to: controller, coordinator: context.coordinator)
    }

    static func dismantleUIViewController(_ controller: TVGameViewController, coordinator: SiriRemoteCommands) {
        coordinator.stop()
        controller.controllerUserInteractionEnabled = true
    }

    private func apply(to controller: TVGameViewController, coordinator: SiriRemoteCommands) {
        // UIKit press path (controller interaction on): Menu / Play-Pause.
        controller.onMenu = onMenu
        controller.onPlayPause = onPlayPause
        // GameController path (controller owned by the stream).
        coordinator.isActive = ownsController
        coordinator.onMenu = onMenu
        coordinator.onPlayPause = onPlayPause
        if controller.controllerUserInteractionEnabled == ownsController {
            controller.controllerUserInteractionEnabled = !ownsController
        }
        controller.setSurfaceFocusable(focusable)
    }
}

/// `GCEventViewController` whose root view is the Metal video layer.
final class TVGameViewController: GCEventViewController {
    let surface = TVSurfaceView()
    var onMenu: (() -> Void)?
    var onPlayPause: (() -> Void)?

    override func loadView() {
        view = surface
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [surface] }

    func setSurfaceFocusable(_ focusable: Bool) {
        guard surface.isFocusable != focusable else { return }
        surface.isFocusable = focusable
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    // Only reached while controller interaction is enabled (otherwise the
    // presses go to GameController). Unhandled presses go up the chain.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .menu:
                onMenu?()
                handled = true
            case .playPause:
                onPlayPause?()
                handled = true
            default:
                break
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Swallow the matching "began" so Menu never falls through to the
        // system (which would leave the app mid-stream).
        let ours = presses.contains { $0.type == .menu || $0.type == .playPause }
        if !ours { super.pressesBegan(presses, with: event) }
    }
}

/// Full-screen Metal view that can hold focus (so the remote's presses reach
/// `TVGameViewController`). No focus effect: it is the picture.
final class TVSurfaceView: MetalLayerView {
    var isFocusable = true
    override var canBecomeFocused: Bool { isFocusable }
}

/// Reads the Siri Remote's Menu and Play/Pause buttons through GameController
/// while the stream owns the controllers (they never reach UIKit then).
/// Game controllers are left alone: their buttons all go to the console.
@MainActor
final class SiriRemoteCommands {
    var isActive = false
    var onMenu: (() -> Void)?
    var onPlayPause: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.attach() }
            })
        attach()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        for remote in Self.remotes() {
            remote.microGamepad?.buttonMenu.pressedChangedHandler = nil
            remote.microGamepad?.buttonX.pressedChangedHandler = nil
        }
    }

    /// Remotes: a micro gamepad profile and no extended gamepad.
    private static func remotes() -> [GCController] {
        GCController.controllers().filter { $0.microGamepad != nil && $0.extendedGamepad == nil }
    }

    private func attach() {
        for remote in Self.remotes() {
            guard let pad = remote.microGamepad else { continue }
            // Menu (Back) on release, like UIKit.
            pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                guard !pressed else { return }
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.onMenu?()
                }
            }
            // buttonX is Play/Pause on the Siri Remote.
            pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                guard !pressed else { return }
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.onPlayPause?()
                }
            }
        }
    }
}

/// Shown on Home and over the player when no game controller is connected.
struct ConnectControllerPrompt: View {
    var compact = false

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: compact ? 30 : 44, weight: .semibold))
                .foregroundStyle(Brand.blue.mix(with: .white, by: 0.4))
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect a game controller")
                    .font(compact ? .headline : .title3.weight(.bold))
                Text("Apple TV needs a game controller to play. Pair one in Settings › Remotes and Devices › Bluetooth: hold the Create and PS buttons on a DualSense, or Share and PS on a DualShock 4, until the light flashes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 20 : 28)
        .frame(maxWidth: 1100, alignment: .leading)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
#endif
