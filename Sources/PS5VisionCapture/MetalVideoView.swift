import SwiftUI
import QuartzCore

/// SwiftUI wrapper around a `CAMetalLayer`-backed view driven by
/// `MetalVideoRenderer`.
struct MetalVideoView: UIViewRepresentable {
    let renderer: MetalVideoRenderer

    func makeUIView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        renderer.attach(to: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MetalLayerView, context: Context) {
        renderer.attach(to: uiView.metalLayer)
    }
}

final class MetalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.contentsGravity = .resizeAspect
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
