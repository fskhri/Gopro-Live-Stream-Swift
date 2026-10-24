import AVFoundation
import GoProKit
import SwiftUI
import UIKit

/// Puts the preview player's display layer on screen.
///
/// Observes `player.displayLayer` and updates the underlying view whenever
/// the layer is recreated after entering foreground or recovering from failure.
struct PreviewSurface: UIViewRepresentable {
    @ObservedObject var player: GoProPreviewPlayer

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.backgroundColor = .black
        view.setDisplayLayer(player.displayLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {
        uiView.setDisplayLayer(player.displayLayer)
    }
}

/// Hosts a display layer and swaps it when recreated.
final class PreviewLayerView: UIView {
    private weak var currentLayer: AVSampleBufferDisplayLayer?

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        guard currentLayer !== layer else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = bounds
            CATransaction.commit()
            return
        }
        currentLayer?.removeFromSuperlayer()
        currentLayer = layer
        self.layer.addSublayer(layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentLayer?.frame = bounds
        CATransaction.commit()
    }
}
