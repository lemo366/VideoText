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
    @State private var selectedModel = "small" // 选择模型
    @State private var progress: Double = 0.0 // 进度条的值
    @State private var modelPath: String?
    @State private var srtContent: String = "" // 存储 SRT 格式的内容

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
                        Text("small").tag("small")
                        Text("small.en").tag("small.en")
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
                        // 显示 SRT 格式的转录结果
                        ScrollView {
                            Text(srtContent)
                                .font(.system(.body, design: .monospaced)) // 使用等宽字体
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
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
            .frame(minWidth: 400)
        }
        .onAppear {
            if let url = selectedVideo {
                player = AVPlayer(url: url)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    // 简化数据模型，只保留需要的字段
    struct WhisperTranscription: Codable {
        let text: String
        let segments: [Segment]
        let language: String
        
        struct Segment: Codable {
            let start: Double
            let end: Double
            let text: String
            let words: [Word]
        }
        
        struct Word: Codable {
            let word: String
            let start: Double
            let end: Double
            let probability: Double
        }
    }

    // 修改生成 SRT 的函数
    func generateSRTFromJSON(jsonURL: URL) -> String {
        do {
            // 读取并解析 JSON 文件
            let jsonData = try Data(contentsOf: jsonURL)
            let transcription = try JSONDecoder().decode(WhisperTranscription.self, from: jsonData)
            
            var srtIndex = 1
            var srtContent = ""
            
            // 遍历所有段落
            for segment in transcription.segments {
                if !segment.words.isEmpty {
                    var currentSentence: [WhisperTranscription.Word] = []
                    var currentLength = 0
                    
                    // 处理每个单词
                    for word in segment.words {
                        currentSentence.append(word)
                        currentLength += word.word.trimmingCharacters(in: .whitespaces).count
                        
                        // 检查是否需要分割句子
                        let shouldSplit = word.word.contains(".") || 
                                        word.word.contains("?") || 
                                        word.word.contains("!") ||
                                        (currentLength > 100 && word.word.contains(","))
                        
                        if shouldSplit && !currentSentence.isEmpty {
                            // 添加 SRT 条目
                            let text = currentSentence.map { $0.word.trimmingCharacters(in: .whitespaces) }
                                .joined(separator: " ")
                            let startTime = formatTimeForSRT(seconds: currentSentence.first?.start ?? 0)
                            let endTime = formatTimeForSRT(seconds: currentSentence.last?.end ?? 0)
                            
                            srtContent += "\(srtIndex)\n\(startTime) --> \(endTime)\n\(text)\n\n"
                            srtIndex += 1
                            
                            // 重置当前句子
                            currentSentence = []
                            currentLength = 0
                        }
                    }
                    
                    // 处理剩余的单词
                    if !currentSentence.isEmpty {
                        let text = currentSentence.map { $0.word.trimmingCharacters(in: .whitespaces) }
                            .joined(separator: " ")
                        let startTime = formatTimeForSRT(seconds: currentSentence.first?.start ?? 0)
                        let endTime = formatTimeForSRT(seconds: currentSentence.last?.end ?? 0)
                        
                        srtContent += "\(srtIndex)\n\(startTime) --> \(endTime)\n\(text)\n\n"
                        srtIndex += 1
                    }
                } else {
                    // 如果没有单词时间戳，使用段落时间
                    srtContent += "\(srtIndex)\n"
                    srtContent += "\(formatTimeForSRT(seconds: segment.start)) --> \(formatTimeForSRT(seconds: segment.end))\n"
                    srtContent += "\(segment.text)\n\n"
                    srtIndex += 1
                }
            }
            
            return srtContent
            
        } catch {
            print("解析 JSON 文件失败: \(error)")
            print("详细错误信息: \(error.localizedDescription)")
            return ""
        }
    }

    // 修改保存 SRT 文件的函数
    func saveSRTFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "json")!]
        openPanel.allowsMultipleSelection = false
        
        openPanel.begin { result in
            if result == .OK, let jsonURL = openPanel.url {
                let srtContent = generateSRTFromJSON(jsonURL: jsonURL)
                
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [UTType(filenameExtension: "srt")!]
                savePanel.nameFieldStringValue = "transcription.srt"
                
                savePanel.begin { result in
                    if result == .OK, let url = savePanel.url {
                        do {
                            try srtContent.write(to: url, atomically: true, encoding: .utf8)
                            print("SRT 文件已保存到: \(url.path)")
                        } catch {
                            print("保存 SRT 文件失败: \(error)")
                        }
                    }
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
    
    // 首先定义一个用于写入 JSON 文件的函数
    func writeJSONFile(result: TranscriptionResult) -> Result<String, Error> {
        do {
            // 获取下载目录路径
            let downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let jsonURL = downloadsPath.appendingPathComponent("transcription_\(timestamp).json")
            
            // 创建 JSON 编码器
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted
            
            // 编码并写入文件
            let jsonData = try jsonEncoder.encode(result)
            try jsonData.write(to: jsonURL)
            
            return .success(jsonURL.absoluteString)
        } catch {
            return .failure(error)
        }
    }

    // 修改转录函数
    func transcribeAudio() async {
        isTranscribing = true
        
        Task(priority: .userInitiated) {
            do {
                // 设置转录选项
                let options = DecodingOptions(
                    verbose: true,
                    task: .transcribe,
                    language: transcriptionLanguage,
                    skipSpecialTokens: true,
                    withoutTimestamps: false,
                    wordTimestamps: true
                )

                // 初始化 WhisperKit
                let pipe = try await WhisperKit(
                    model: selectedModel,
                    verbose: true,
                    logLevel: .debug
                )
                
                // 转录音频
                let transcriptionResults = try await pipe.transcribe(
                    audioPath: extractAudio(from: selectedVideo!), 
                    decodeOptions: options
                )
                
                // 保存 JSON 文件并生成 SRT 内容
                for result in transcriptionResults {
                    let saveResult = writeJSONFile(result: result)
                    switch saveResult {
                    case .success(let path):
                        print("JSON 文件已保存到: \(path)")
                        // 生成 SRT 内容
                        if let url = URL(string: path) {
                            let srtText = generateSRTFromJSON(jsonURL: url)
                            DispatchQueue.main.async {
                                self.srtContent = srtText
                                self.transcriptionResults = srtText.components(separatedBy: "\n\n")
                            }
                        }
                    case .failure(let error):
                        print("保存 JSON 文件失败: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("转录错误: \(error.localizedDescription)")
            }
        }
        
        isTranscribing = false
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
        guard !keyword.isEmpty else { return transcriptionResults }
        return transcriptionResults.filter { segment in
            segment.lowercased().contains(keyword.lowercased())
        }
    }
}
