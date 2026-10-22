#if os(iOS)
import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted by the player's control bar to start Picture in Picture.
    static let couchportStartPictureInPicture = Notification.Name("couchport.startPictureInPicture")
}

/// Hands decoded Remote Play frames to the Picture in Picture layer.
///
/// The Metal renderer draws the picture in the app; Picture in Picture needs
/// an `AVSampleBufferDisplayLayer`, so while one is attached every decoded
/// frame is also wrapped (no copy) and shown there. Called from the decoder
/// thread.
final class PiPFrameSink: @unchecked Sendable {
    static let shared = PiPFrameSink()

    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?
    private var format: CMVideoFormatDescription?

    func attach(_ layer: AVSampleBufferDisplayLayer?) {
        lock.lock()
        self.layer = layer
        format = nil
        lock.unlock()
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let layer else { return }

        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pixelBuffer) {
            var desc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &desc)
            format = desc
        }
        guard let format else { return }

        // Live stream: no timeline, show each frame as soon as it arrives.
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sample)
        }
    }
}

/// Picture in Picture for the iPhone and iPad player.
///
/// Starts on its own when the user leaves the app during a stream (if the
/// setting is on), or from the control bar. While the app is in the
/// background the Metal view stops presenting, and the stream keeps running
/// (the app has the audio background mode, which Picture in Picture needs).
@MainActor
final class PlayerPictureInPicture: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private weak var renderer: MetalVideoRenderer?
    private weak var boundLayer: AVSampleBufferDisplayLayer?

    func configure(layer: AVSampleBufferDisplayLayer, renderer: MetalVideoRenderer, enabled: Bool) {
        self.renderer = renderer
        guard enabled, AVPictureInPictureController.isPictureInPictureSupported() else {
            tearDown()
            return
        }
        // The layout can rebuild the video view (rotation, folding): follow
        // the new layer.
        if controller != nil, boundLayer === layer { return }
        if controller != nil { tearDown() }
        boundLayer = layer

        PiPFrameSink.shared.attach(layer)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer,
                                                                 playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.requiresLinearPlayback = true     // live: no seeking, no pause button semantics
        controller = pip

        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.renderer?.presentationEnabled.value = false }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.renderer?.presentationEnabled.value = true }
            },
            center.addObserver(forName: .couchportStartPictureInPicture, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.start() }
            },
        ]
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        possibleObservation?.invalidate()
        possibleObservation = nil
        if let controller, controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        controller = nil
        boundLayer = nil
        PiPFrameSink.shared.attach(nil)
        renderer?.presentationEnabled.value = true
        // tearDown can run while SwiftUI is updating a view (configure from
        // a layer callback, onDisappear); publish on the next turn.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isActive { self.isActive = false }
            if self.isPossible { self.isPossible = false }
        }
    }
}

extension PlayerPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The player is still on screen underneath; nothing to rebuild.
        completionHandler(true)
    }
}

extension PlayerPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // A live stream: an unbounded range shows the "live" indicator.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// The layer Picture in Picture takes its picture from. It sits behind the
/// Metal video view with the same frame (PiP needs it in the window).
struct PiPLayerView: UIViewRepresentable {
    let onLayer: (AVSampleBufferDisplayLayer) -> Void

    func makeUIView(context: Context) -> PiPLayerHostView {
        let view = PiPLayerHostView()
        onLayer(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: PiPLayerHostView, context: Context) {}
}

final class PiPLayerHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Second copy of the video for the iPhone Duo tabletop reflection.
/// The renderer draws the water at half the view's resolution.
struct MirrorVideoView: UIViewRepresentable {
    let renderer: MetalVideoRenderer

    func makeUIView(context: Context) -> MirrorLayerView {
        let view = MirrorLayerView()
        view.isUserInteractionEnabled = false
        let renderer = renderer
        view.onLayout = { size in renderer.mirrorPixelSize.value = size }
        renderer.attachMirror(view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MirrorLayerView, context: Context) {}
}

final class MirrorLayerView: MetalLayerView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.contentsGravity = .resize
        let scale = (window?.screen.scale ?? 3) / 2
        onLayout?(CGSize(width: (bounds.width * scale).rounded(),
                         height: (bounds.height * scale).rounded()))
    }
}
#endif
