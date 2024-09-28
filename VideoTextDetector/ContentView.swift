import SwiftUI
import WhisperKit
import AVFoundation
import Vision
import CoreML

struct ContentView: View {
    @State private var whisperKit: WhisperKit?
    @State private var selectedVideo: URL?
    @State private var recognitionLevel: VNRequestTextRecognitionLevel = .fast
    @State private var recognitionLanguage: String = "en-US"
    @State private var transcriptionLanguage: String = "en"
    @State private var isTranscribing = false
    @State private var transcriptionText: String = ""
    @State private var searchKeyword = ""
    @State private var detectedFrames: [DetectedFrame] = [] // 存储所有检测到的帧
    @State private var transcriptionResults: [String] = [] // 存储转录结果
    @State private var player: AVPlayer?
    @State private var selectedSegment = 0 // 控制显示的分段
    @State private var selectedModel = "base" // 选择模型
    @State private var progress: Double = 0.0 // 进度条的值
    @State private var modelPath: String?

    private var videoProcessor = VideoProcessor()

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                // 左侧内容
                VStack(spacing: 10) {
                    // 视频播放器
                    if let url = selectedVideo {
                        VideoPlayer(url: url, player: player ?? AVPlayer(url: url))
                            .frame(height: geometry.size.height * 0.6)
                    } else {
                        Text("请先选择视频")
                            .frame(height: geometry.size.height * 0.6)
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.2))
                    }
                    
                    // 选择视频按钮
                    HStack {
                        Button("选择视频") {
                            selectVideo()
                        }
                    }

                    HStack {
                        // 识别级别选择
                        Picker("识别级别", selection: $recognitionLevel) {
                            Text("快速").tag(VNRequestTextRecognitionLevel.fast)
                            Text("准确").tag(VNRequestTextRecognitionLevel.accurate)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    
                    HStack {
                        // 识别语言选择
                        Picker("识别语言", selection: $recognitionLanguage) {
                            Text("英语").tag("en-US")
                            Text("中文").tag("zh-CN")
                        }
                        .pickerStyle(MenuPickerStyle())
                    }

                    // 进度条
                    // if isTranscribing {
                    //     ProgressView("正在处理视频...", value: progress, total: 100)
                    //         .padding()
                    // }
                    
                    // 选择模型
                    Picker("选择模型", selection: $selectedModel) {
                        Text("base").tag("base")
                        Text("base.en").tag("base.en")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    // 转录按钮
                    Button("转录音频") {
                        Task {
                            await transcribeAudio()
                        }
                    }
                    .padding()
                }
                .padding(10)
                .frame(width: 400) // 左侧区域宽度
                
                // 右侧内容
                VStack(spacing: 10) {
                    // 分段控件
                    Picker("选择显示内容", selection: $selectedSegment) {
                        Text("视频结果").tag(0)
                        Text("转录结果").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding()

                    // 根据选择显示视频结果或转录结果
                    if selectedSegment == 0 {
                        // 显示所有检测到的文本结果
                        List(detectedFrames.filter { !$0.detectedText.isEmpty }) { frame in
                            HStack {
                                Image(nsImage: frame.image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 100)
                                VStack(alignment: .leading) {
                                    Text("时间: \(formatTime(seconds: frame.timestamp))")
                                    Text("文本: \(frame.detectedText)")
                                }
                            }
                            .onTapGesture {
                                if let player = player {
                                    let targetTime = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
                                    player.seek(to: targetTime) // 跳转到指定时间
                                }
                            }
                        }
                    } else {
                        // 显示转录结果
                        List(transcriptionResults, id: \.self) { result in
                            Text(result)
                        }
                    }

                    HStack {
                        // 识别语言选择
                        Picker("转录语言", selection: $transcriptionLanguage) {
                            Text("英语").tag("en")
                            Text("中文").tag("zh")
                        }
                        .pickerStyle(MenuPickerStyle())
                    }

                    // 进度条
                    // if isTranscribing {
                    //     ProgressView("正在转录...", value: progress, total: 100)
                    //         .padding()
                    // }

                    // 搜索框和搜索按钮
                    HStack {
                        TextField("搜索关键词", text: $searchKeyword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding()
                        
                        Button("搜索") {
                            // 过滤搜索结果
                            if selectedSegment == 0 {
                                // 搜索视频结果
                                detectedFrames = videoProcessor.searchKeyword(searchKeyword)
                            } else {
                                // 高亮显示转录结果中搜索的关键字
                                transcriptionResults = searchTranscriptionResults(keyword: searchKeyword)
                            }
                        }
                    }

                    // 保存 SRT 文件
                    Button("导出 SRT 字幕") {
                        saveSRTFile()
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity) // 右侧区域自适应宽度
            }
            .padding(10)
            .frame(minWidth: 300)
        }
        .onAppear {
            if let url = selectedVideo {
                player = AVPlayer(url: url)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    func saveSRTFile() {
        // 实现保存 SRT 文件的逻辑
        let srtContent = transcriptionResults.joined(separator: "\n\n") // 将转录结果合并为 SRT 格式
        let savePanel = NSSavePanel()
        savePanel.allowedFileTypes = ["srt"]
        savePanel.nameFieldStringValue = "transcription.srt"
        
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                do {
                    try srtContent.write(to: url, atomically: true, encoding: .utf8)
                    print("SRT 文件已保存到: \(url.path)")
                } catch {
                    print("保存 SRT 文件时出错: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie]
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            guard let selectedVideoURL = panel.url else { return }
            selectedVideo = selectedVideoURL
            player = AVPlayer(url: selectedVideo!)

            // 使用 async/await 处理视频处理
            Task(priority: .userInitiated) { // 设置优先级为 userInitiated
                do {
                    // 处理视频并获取检测到的帧
                    detectedFrames = try await videoProcessor.processVideo(url: selectedVideo!, recognitionLevel: recognitionLevel, recognitionLanguage: recognitionLanguage)
                } catch {
                    print("处理视频失败: \(error)")
                }
            }
        }
    }
    
    func formatTime(seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "mm:ss"
        return formatter.string(from: date)
    }
    
    func transcribeAudio() async {
        isTranscribing = true // 开始转录时设置为 true
        
        Task(priority: .userInitiated) {
            do {
                // 定义模型文件夹的URL
//                let modelFolder = "/Users/lhr/VideoText/Models/whisperkit-coreml/openai_whisper-base"
                
                // 创建计算选项
//                let computeOptions = ModelComputeOptions(
//                    audioEncoderCompute: .cpuAndGPU, // 使用CPU和GPU
//                    textDecoderCompute: .cpuAndGPU
//                )
                
                // 设置转录选项以获取时间戳
                let options = DecodingOptions(
                    verbose: true,
                    task: .transcribe,
                    language: "\(transcriptionLanguage)", // 设置语言
                    skipSpecialTokens: true, // 跳过特殊标记
                    withoutTimestamps: false,// 不禁用时间戳
                    wordTimestamps: true // 启用单词时间戳
                )

                // 初始化WhisperKit实例，传入自定义参数
                let pipe = try await WhisperKit(
                    model:"\(selectedModel)",
//                    modelFolder: modelFolder,
//                    computeOptions: computeOptions,
                    verbose: true,
                    logLevel: .debug
                )
                
                
                // 转录音频文件
                let transcriptionResluts = try await pipe.transcribe(
                    audioPath: extractAudio(from: selectedVideo!), 
                    decodeOptions: options)

        
                for transcriptionReslut in transcriptionResluts {
                    for segment in transcriptionReslut.segments {
                        let startTime = segment.start
                        let endTime = segment.end
                        let text = segment.text
                        
                        // 格式化时间为 SRT 格式
                        let formattedStartTime = formatTimeForSRT(seconds: Double(startTime))
                        let formattedEndTime = formatTimeForSRT(seconds: Double(endTime))
                        
                        // 生成 SRT 格式的字符串
                        let srtEntry = "\(formattedStartTime) --> \(formattedEndTime)\n\(text)"
                        
                        // 将 SRT 条目添加到结果数组
                        transcriptionResults.append(srtEntry)
                    }
                }
            } catch {
                print("初始化或转录时出错: \(error.localizedDescription)")
            }
        }
      
        
        isTranscribing = false // 转录完成后设置为 false
    }
    
    func formatTimeForSRT(seconds: Double) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    let secondsInt = Int(seconds) % 60
    let milliseconds = Int((seconds - Double(Int(seconds))) * 1000)
    
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secondsInt, milliseconds)
}

    func extractAudio(from videoURL: URL) throws -> String {
        // 提取音频的逻辑
        let asset = AVAsset(url: videoURL)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "com.example.VideoTextDetector", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话"])
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        // 使用 DispatchGroup 等待导出完成
        let group = DispatchGroup()
        group.enter()

        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                print("音频导出成功: \(outputURL.path)")
                // 更新进度
                DispatchQueue.main.async {
                    progress = 100.0 // 假设导出完成时进度为100%
                }
            case .failed:
                print("音频导出失败: \(exportSession.error?.localizedDescription ?? "未知错误")")
            default:
                print("音频导出状态: \(exportSession.status)")
            }
            group.leave()
        }
        
        group.wait() // 等待导出完成
        return outputURL.path // 返回输出路径
    }
    
    func searchTranscriptionResults(keyword: String) -> [String] {
        // 过滤转录结果
        return transcriptionResults.filter { $0.lowercased().contains(keyword.lowercased()) }
    }
}
