import SwiftUI

@main
struct PS5VisionCaptureApp: App {
    @StateObject private var app = AppModel()

    init() {
        // Remote Play sockets can be closed by the console mid-write (e.g. a
        // rejected pairing PIN). Ignore SIGPIPE so send() returns EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        #if os(visionOS)
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.capture)
        }
        .defaultSize(width: 1280, height: 760)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        ImmersiveSpace(id: "theater") {
            ImmersiveTheaterView()
                .environmentObject(app)
                .environmentObject(app.capture)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed, .progressive, .full)
        .restorationBehavior(.disabled)
        #else
        // iPhone, iPhone Duo and iPad: one window that follows size changes
        // (fold/unfold, rotation, Split View) without restarting the stream.
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.capture)
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
