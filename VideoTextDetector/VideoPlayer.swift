import SwiftUI
import AVKit

struct VideoPlayer: NSViewRepresentable {
    var url: URL
    var player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
