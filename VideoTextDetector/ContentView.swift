import SwiftUI
import AVFoundation
import AVKit
import CoreMedia
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var videoProcessor = VideoProcessor()
    @State private var selectedVideo: URL?
    @State private var searchKeyword = ""
    @State private var searchResults: [DetectedFrame] = []
    @State private var player: AVPlayer?
    
    func formatTime(seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        let calendar = Calendar.current
        
        let hours = calendar.component(.hour, from: date)
        let minutes = calendar.component(.minute, from: date)
        let secs = calendar.component(.second, from: date)
        let ms = Int((seconds * 1000).truncatingRemainder(dividingBy: 1000))
        
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, ms)
    }
    
    var body: some View {
        HStack {
            // 左侧视频播放器
            VStack {
                // 选择视频按钮
                Button("选择视频") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType.movie]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK {
                        selectedVideo = panel.url
                        player = AVPlayer(url: selectedVideo!)
                        // player?.play() // 选择视频后立即播放
                        videoProcessor.processVideo(url: selectedVideo!)
                    }
                }
                .padding()
                .disabled(videoProcessor.isProcessing) // 禁用按钮
                
                if videoProcessor.isProcessing {
                    ProgressView("正在处理视频...")
                        .padding()
                } else {
                    if let url = selectedVideo {
                        VideoPlayer(url: url, player: player ?? AVPlayer(url: url))
                            .frame(height: 400)
                    } else {
                        Text("请先选择视频")
                            .frame(height: 400)
                    }
                }
            }
            .frame(width: 400) // 设置左侧视频区域宽度
            
            // 右侧搜索和结果
            VStack {
                HStack {
                    // 搜索框
                    TextField("搜索关键词", text: $searchKeyword)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                        .disabled(videoProcessor.isProcessing) // 禁用搜索框
                    
                    // 搜索按钮
                    Button("搜索") {
                        searchResults = videoProcessor.searchKeyword(searchKeyword)
                    }
                    .padding()
                    .disabled(videoProcessor.isProcessing) // 禁用按钮
                }
                
                // 搜索结果列表
                List(searchResults) { frame in
                    HStack {
                        Image(nsImage: frame.image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 100)
                        VStack(alignment: .leading) {
                            Text("时间戳: \(formatTime(seconds: frame.timestamp))")
                            Text("检测到的文本: \(frame.detectedText)")
                        }
                    }
                    .onTapGesture {
                        if let player = player {
                            let targetTime = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
                            player.seek(to: targetTime) { finished in
                                // if finished {
                                //     player.play()//自动播放
                                // }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity) // 右侧区域自适应宽度
        }
        .padding()
        .onAppear {
            if let url = selectedVideo {
                player = AVPlayer(url: url)
            }
        }
    }
}