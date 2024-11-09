import SwiftUI
import AVKit

struct AudioPlayer: View {
    var url: URL
    var player: AVPlayer
    var segments: [EditableSegment]
    var currentTime: Double
    
    var body: some View {
        VStack(spacing: 0) {
            // 字幕显示区域
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(segments) { segment in
                            VStack(alignment: .center, spacing: 8) {
                                // 普通对话文本用紫色显示
                                Text(segment.text)
                                    .foregroundColor(isCurrentSegment(segment) ? Color.blue : Color.white)
                                    .font(.title2)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(segment.id)
                        }
                    }
                }
                .onChange(of: currentTime) { _ in
                    if let currentSegment = getCurrentSegment() {
                        withAnimation {
                            proxy.scrollTo(currentSegment.id, anchor: .center)
                        }
                    }
                }
            }
            .background(Color.black)
            .frame(maxWidth: .infinity)
            
            // 简化的播放控制器
            AVPlayerControllerRepresented(player: player)
                .frame(height: 36)
        }
    }
    
    private func isCurrentSegment(_ segment: EditableSegment) -> Bool {
        return currentTime >= segment.startTime && currentTime <= segment.endTime
    }
    
    private func getCurrentSegment() -> EditableSegment? {
        return segments.first { segment in
            currentTime >= segment.startTime && currentTime <= segment.endTime
        }
    }
}

struct AVPlayerControllerRepresented: NSViewRepresentable {
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