#if os(visionOS)
import Combine
import GameController
import SwiftUI
import UIKit

/// A stable UIKit ancestor of the entire window, including Home. The policy
/// does not change when streaming starts/stops or when controls appear.
struct VisionAppRoot: UIViewControllerRepresentable {
    let app: AppModel

    func makeUIViewController(context: Context) -> VisionAppViewController {
        VisionAppViewController(app: app, environment: context.environment)
    }

    func updateUIViewController(_ controller: VisionAppViewController, context: Context) {
        // Preserve scene actions (open/dismiss theater/windows), scenePhase,
        // locale and accessibility settings across the UIKit hosting boundary.
        // Never request focus during SwiftUI's update cycle.
        controller.updateContent(app: app, environment: context.environment)
    }
}

final class VisionAppViewController: GCEventViewController {
    private let host: UIHostingController<AnyView>
    private let gamepadInteraction = GCEventInteraction()

    init(app: AppModel, environment: EnvironmentValues) {
        host = UIHostingController(rootView: Self.content(app: app, environment: environment))
        super.init(nibName: nil, bundle: nil)
        controllerUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func content(app: AppModel, environment: EnvironmentValues) -> AnyView {
        AnyView(ContentView()
            .environmentObject(app)
            .environmentObject(app.capture)
            .gamepadInputOnly()
            .environment(\.self, environment))
    }

    func updateContent(app: AppModel, environment: EnvironmentValues) {
        host.rootView = Self.content(app: app, environment: environment)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Establish the controller responder once on presentation, never
        // from updateUIViewController or a per-frame focus request.
        becomeFirstResponder()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        gamepadInteraction.handledEventTypes = .gamepad
        gamepadInteraction.receivesEventsInView = false
        view.addInteraction(gamepadInteraction)
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

/// One owner for gesture preferences, including controllers connected before
/// a stream and hot-plugged controllers. Never installs input callbacks: those
/// remain owned by GamepadBridge and cannot be overwritten by UI policy.
@MainActor
final class VisionGamepadUIPolicy {
    private var subscriptions: Set<AnyCancellable> = []
    private var saved: [ObjectIdentifier: [(GCControllerElement, GCControllerElement.SystemGestureState)]] = [:]
    private var isForeground = true

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            center.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }.store(in: &subscriptions)
        }
        center.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            Task { @MainActor in
                self?.isForeground = false
                self?.refresh()
            }
        }.store(in: &subscriptions)
        center.publisher(for: UIApplication.willEnterForegroundNotification).sink { [weak self] _ in
            Task { @MainActor in
                self?.isForeground = true
                self?.refresh()
            }
        }.store(in: &subscriptions)
        isForeground = UIApplication.shared.applicationState != .background
        refresh()
    }

    private func refresh() {
        let controllers = isForeground ? GamepadBridge.gamepads() : []
        let connected = Set(controllers.map { ObjectIdentifier($0) })
        for id in Array(saved.keys) where !connected.contains(id) {
            for (element, preference) in saved.removeValue(forKey: id) ?? [] {
                element.preferredSystemGestureState = preference
            }
        }
        for controller in controllers {
            let id = ObjectIdentifier(controller)
            guard saved[id] == nil else { continue }
            // Only system-bound elements support this request. Do not try to
            // register system handlers on axes or other unrelated elements.
            let elements = controller.physicalInputProfile.allElements.filter { $0.isBoundToSystemGesture }
            saved[id] = elements.map { ($0, $0.preferredSystemGestureState) }
            for element in elements { element.preferredSystemGestureState = .disabled }
        }
    }
}
#endif
