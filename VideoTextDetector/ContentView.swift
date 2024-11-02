import SwiftUI
import WhisperKit
import AVFoundation
import Vision
import CoreML
import AVKit
import Translation

@available(macOS 15.0, *)
struct ContentView: View {
    @State private var whisperKit: WhisperKit?
    @State private var selectedVideo: URL?
    @State private var recognitionLevel: VNRequestTextRecognitionLevel = .fast
    @State private var recognitionLanguage: String = "en-US" // 默认选择英文
    @State private var transcriptionLanguage: String = "en"
    @State private var isTranscribing = false
    // @State private var transcriptionText: String = ""
    @State private var searchKeyword = ""
    @State private var detectedFrames: [DetectedFrame] = [] // 存储所有检测到的帧
    @State private var transcriptionResults: [String] = [] // 存储转录结果
    @State private var player: AVPlayer?
    @State private var selectedSegment = 0 // 控制显示的分段
    @State private var selectedModel = "small.en" // 选择模型
    @State private var progress: Double = 0.0 // 进度条的值
    @State private var modelPath: String?
    @State private var srtContent: String = "" // 存储 SRT 格式的内容
    @State private var editableSegments: [EditableSegment] = []// 确保定义
    @State private var selectedSegmentId: UUID?
    @State private var cursorPosition: Int?
    @State private var editHistory = EditHistory()
    @State private var draggedSegmentId: UUID?
    @State private var clipStartTime: String = "00:00:00"
    @State private var clipEndTime: String = "00:00:00"
    @FocusState private var startTimeFocused: Bool
    @FocusState private var endTimeFocused: Bool
    @State private var showTranslation = false
    @State private var configuration: TranslationSession.Configuration?

    @StateObject private var videoProcessor = VideoProcessor()

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

                    // 视频片段选择器
                    HStack(spacing: 16) {                        
                        HStack(spacing: 8) {
                            Text("开始")
                            TextField("00:00:00", text: $clipStartTime)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 80)
                                .onChange(of: clipStartTime) { _ in
                                    updatePlayerTime(from: clipStartTime)
                                }
                            
                            Text("结束")
                            TextField("00:00:00", text: $clipEndTime)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 80)
                                .onChange(of: clipEndTime) { _ in
                                    updatePlayerTime(from: clipEndTime)
                                }
                            
                            Button(action: {
                                exportVideoClip()
                            }) {
                                Label("导出片段", systemImage: "square.and.arrow.up")
                                    .labelStyle(TitleAndIconLabelStyle())
                            }
                            .disabled(selectedVideo == nil)
                        }
                    }
                    .padding(.horizontal)

                    // 可选：添加提示文本
                    // if recognitionLevel != .accurate {
                    //     Text("选择准确模式以启用语言选择")
                    //         .font(.caption)
                    //         .foregroundColor(.secondary)
                    //         .padding(.horizontal)
                    // }
                        
                    // 识别级别选择
                    Picker("识别级别", selection: $recognitionLevel) {
                        Text("速度").tag(VNRequestTextRecognitionLevel.fast)
                        Text("准确").tag(VNRequestTextRecognitionLevel.accurate)
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    HStack {
                        // 别语言选择
                        Picker("识别语言", selection: $recognitionLanguage) {
                            Text("英语").tag("en-US")
                            Text("中文").tag("zh-Hans")
                        }
                        .pickerStyle(MenuPickerStyle())
                        .disabled(recognitionLevel != .accurate)  // 只有在准确模式下才能选择语言
                        .opacity(recognitionLevel == .accurate ? 1.0 : 0.5)  // 视觉反馈
                    }

                    // 选择模型
                    Picker("选择模型", selection: $selectedModel) {
                        Text("small.en").tag("small.en")
                        Text("small").tag("small")
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    HStack {
                        // 识别语言选择
                        Picker("转录语言", selection: $transcriptionLanguage) {
                            Text("英语").tag("en")
                            Text("中文").tag("zh")
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                    
                    // 转录按钮
                    Button("转录音频") {
                        Task {
                            await transcribeAudio()
                        }
                    }
                    .padding()    
                }
                .frame(width: geometry.size.width * 0.3, height: geometry.size.height) // 右侧列占 60% 宽度，填满高度
                
                // 右侧内容
                VStack(spacing: 10) {
                    // 分段控件
                    Picker("", selection: $selectedSegment) {
                        Text("视频结果").tag(0)
                        Text("转录结果").tag(1)
                        Text("翻译结果").tag(2)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding()

                    // 主要内容区域
                    if selectedSegment == 0 {
                        VStack(alignment: .leading, spacing: 0) {
                            // 搜索结果统计
                            if !searchKeyword.isEmpty {
                                Text("找到 \(filteredSegments.count) 个匹配结果")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            }

                            if videoProcessor.isProcessing {
                                VStack {
                                    ProgressView("正在处理视频... \(videoProcessor.progress)%")
                                        .padding()
                                    Text("处理时间可能较长，请耐心等待...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    // 添加进度条
                                    ProgressView(value: Double(videoProcessor.progress), total: 100)
                                        .padding(.horizontal)
                                        .padding(.top, 5)
                                }
                            }
                            
                            Text("检测到 \(videoProcessor.textSegments.count) 个文本段落")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            // 卡片网格
                            ScrollView {
                                LazyVGrid(columns: [
                                    GridItem(.flexible(), spacing: 24),
                                    GridItem(.flexible(), spacing: 24),
                                    GridItem(.flexible(), spacing: 24)
                                ], spacing: 24) {
                                    ForEach(filteredSegments.filter { !$0.text.isEmpty }) { segment in
                                        let cardWidth = (geometry.size.width * 0.7 - 96 - 48) / 3 // 调整卡片宽度计算
                                        // 96 = 左右边距(24 * 2 = 48) + 列间距(24 * 2 = 48)
                                        // 48 = 额外的安全间距
                                        
                                        VStack(alignment: .leading, spacing: 8) {
                                            // 时间戳和文本信息
                                            HStack {
                                                Text("\(formatTime(seconds: segment.startTime)) - \(formatTime(seconds: segment.endTime))")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.gray.opacity(0.1))
                                                    .cornerRadius(4)
                                                
                                                Spacer()
                                            }
                                            
                                            // 文本内容（带高亮）
                                            Text(highlightText(segment.text, keyword: searchKeyword))
                                                .font(.body)
                                                .padding(.horizontal, 8)
                                                .lineLimit(3)
                                                .frame(height: 40)
                                            
                                            // 帧图片预览
                                            if let firstFrame = segment.frames.first {
                                                Image(nsImage: firstFrame.image)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(height: 100)
                                                    .cornerRadius(4)
                                                    .shadow(radius: 2)
                                            }
                                        }
                                        .frame(width: cardWidth - 8, height: 180)// 固定卡片大小
                                        .padding(8)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(8)
                                        .shadow(radius: 1)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if let player = player {
                                                let targetTime = CMTime(seconds: segment.startTime, preferredTimescale: 600)
                                                player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                                                // player.play()
                                            }
                                        }
                                        .onHover { isHovered in
                                            if isHovered {
                                                NSCursor.pointingHand.push()
                                            } else {
                                                NSCursor.pop()
                                            }
                                        }
                                    }
                                }
                                .padding(24)
                            }
                        }
                    } else if selectedSegment == 1  {
                        VStack {
                            // 只保留导出按钮
                            HStack {
                                Spacer()
                                Menu{
                                    Button("导出 SRT") {
                                        exportToSRT()
                                    }
                                    Button("导出 JSON") {
                                        exportToJSON()
                                    }
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("导出")
                                        .imageScale(.small)
                                }
                                .controlSize(.small)
                            }
                            
                            // 字幕列表
                            List {
                                ForEach(editableSegments.indices, id: \.self) { index in
                                    SegmentView(
                                        segment: editableSegments[index],
                                        isSelected: editableSegments[index].id == selectedSegmentId,
                                        isLastSegment: index == editableSegments.count - 1, // 判断是否是最后一个段落
                                        cursorPosition: .constant(nil), // 这里可以根据需要调整
                                        onSelect: { selectSegment(editableSegments[index].id) },
                                        onSplit: { wordIndex in
                                            splitSegmentAtIndex(wordIndex, in: index)  // 传递当前段落的索引
                                        },
                                        onMerge: {
                                            mergeSegments(at: index)  // 传递当前段落的索引
                                        },
                                        onTimeClick: { time in
                                            // 跳转到视频时间点
                                            player?.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
                                        }
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }else if selectedSegment == 2 {
                        VStack {
                            HStack {
                                Spacer() // 填充空白区域，将按钮推到右侧
                                Button("翻译") {
                                    if configuration == nil {
                                        configuration = TranslationSession.Configuration(source: .init(identifier: "en-US"), target: .init(identifier: "zh-Hans"))
                                    }
                                }
                                .buttonStyle(.bordered)

                                Button(action:{
                                    exportSubtitles()
                                }){
                                    // 按钮的内容
                                    Image(systemName: "square.and.arrow.up")
                                        .imageScale(.small)
                                    Text("导出双语字幕")            
                                }
                            }
                            // 翻译结果列表
                            List {
                                ForEach(editableSegments.indices, id: \.self) { index in
                                    let segment = editableSegments[index]
                                    VStack(alignment: .leading) {
                                        Text(segment.text) // 显示原始文本
                                        if let translatedText = segment.translatedText {
                                            Text(translatedText) // 显示翻译结果
                                                .foregroundColor(.gray)
                                        }
                                    }
                                }
                            }
                            .translationTask(configuration) { session in
                                let requests = editableSegments.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
                                
                                if let responses = try? await session.translations(from: requests) {
                                    responses.forEach { response in
                                        updateTranslation(response: response)
                                    }
                                }
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                    Spacer() // 添加这个将搜索框推到底部
                    
                    // 搜索框始终显示在底部
                    if selectedSegment == 0 { // 只在视频结果标签页显示搜索框
                        Divider() // 添加分隔线
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            TextField("输入关键字搜索视频文本...", text: $searchKeyword)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                        }
                        .padding()
                    }
                }
                .frame(width: geometry.size.width * 0.7, height: geometry.size.height) // 右侧列占 60% 宽度，填满高度
            }
        }
        .onAppear {
            if let url = selectedVideo {
                player = AVPlayer(url: url)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
    }

    // 简化数据模型，只保留需要字段
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

    private func updateTranslation(response: TranslationSession.Response) {
        guard let index = editableSegments.firstIndex(where: { $0.id.uuidString == response.clientIdentifier }) else {
            return
        }
        editableSegments[index].translatedText = response.targetText // 更新翻译结果
    }

    private func exportSubtitles() {
        var srtContent = ""
        for (index, segment) in editableSegments.enumerated() {
            srtContent += "\(index + 1)\n"
            srtContent += "\(formatTimeForSRT(seconds: segment.startTime)) --> \(formatTimeForSRT(seconds: segment.endTime))\n"
            srtContent += "\(segment.text)\n"
            if let translatedText = segment.translatedText {
                srtContent += "\(translatedText)\n\n"
            }
        }

        // 保存到文件
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.text]
        savePanel.nameFieldStringValue = "dualsubtitles.srt"
        
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                do {
                    try srtContent.write(to: url, atomically: true, encoding: .utf8)
                    print("双语字幕已保存到: \(url.path)")
                } catch {
                    print("存字幕文件失败: \(error)")
                }
            }
        }
    }

    // ���改生成 SRT 的函数
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
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    // 首先定义一个用于写入 JSON 文件的函数
    func writeJSONFile(result: TranscriptionResult, to url: URL) -> Result<String, Error> {
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
                
                // 保存 JSON 文件并处理转录结果
                for result in transcriptionResults {
                    // 使用 FileManager 获取临时目录
                    let tempDirectory = FileManager.default.temporaryDirectory
                    let tempFileURL = tempDirectory.appendingPathComponent("transcriptionResult_\(UUID().uuidString).json")
    
                    let saveResult = writeJSONFile(result: result, to: tempFileURL)
                    switch saveResult {
                    case .success(let path):
                        print("JSON 文已保存到临时目录: \(path)")
                        // 将转录结果转换为可编辑段落
                        if let url = URL(string: path) {
                            createEditableSegmentsFromJSON(url)
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
        let secs = Int(seconds) % 60
        let milliseconds = Int((seconds - Double(Int(seconds))) * 1000)
        
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
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
        return outputURL.path // 返回出路径
    }
    
    func searchTranscriptionResults(keyword: String) -> [String] {
        guard !keyword.isEmpty else { return transcriptionResults }
        return transcriptionResults.filter { segment in
            segment.lowercased().contains(keyword.lowercased())
        }
    }

    func selectSegment(_ id: UUID) {
        selectedSegmentId = id
        cursorPosition = nil
    }
    
    func mergeSegments() {
        saveState() // 保存当前状态
        guard let currentIndex = editableSegments.firstIndex(where: { $0.id == selectedSegmentId }),
              currentIndex < editableSegments.count - 1 else { return }
        
        var mergedSegment = editableSegments[currentIndex]
        let nextSegment = editableSegments[currentIndex + 1]
        
        mergedSegment.words.append(contentsOf: nextSegment.words)
        
        editableSegments.remove(at: currentIndex + 1)
        editableSegments[currentIndex] = mergedSegment
    }
    
    func splitSegmentAtCursor() {
        saveState() // 存当前状态
        guard let currentIndex = editableSegments.firstIndex(where: { $0.id == selectedSegmentId }),
              let cursor = cursorPosition else { return }
        
        let segment = editableSegments[currentIndex]
        let text = segment.text
        
        // 在光标位分割文本
        let index = text.index(text.startIndex, offsetBy: cursor)
        let firstPart = String(text[..<index])
        let secondPart = String(text[index...])
        
        // 创建新的段落
        let firstSegment = EditableSegment(words: [
            EditableWord(
                word: firstPart.trimmingCharacters(in: .whitespaces),
                start: segment.startTime,
                end: segment.startTime + (segment.endTime - segment.startTime) / 2,
                probability: 1.0
            )
        ])
        
        let secondSegment = EditableSegment(words: [
            EditableWord(
                word: secondPart.trimmingCharacters(in: .whitespaces),
                start: segment.startTime + (segment.endTime - segment.startTime) / 2,
                end: segment.endTime,
                probability: 1.0
            )
        ])
        
        // 更新段落列表
        editableSegments.remove(at: currentIndex)
        editableSegments.insert(contentsOf: [firstSegment, secondSegment], at: currentIndex)
        
        // 更新选中状态
        selectedSegmentId = firstSegment.id
        cursorPosition = nil
    }

    // 从 JSON 创建可编辑段落
    func createEditableSegmentsFromJSON(_ jsonURL: URL) {
        do {
            let jsonData = try Data(contentsOf: jsonURL)
            let transcription = try JSONDecoder().decode(WhisperTranscription.self, from: jsonData)
            
            // 在主线程更新 UI
            DispatchQueue.main.async {
                self.editableSegments = transcription.segments.map { segment in
                    EditableSegment(words: segment.words.map { word in
                        EditableWord(
                            word: word.word,
                            start: word.start,
                            end: word.end,
                            probability: word.probability
                        )
                    })
                }
                print("已加载 \(self.editableSegments.count) 个字幕段落")
            }
        } catch {
            print("解析 JSON 文件失败: \(error)")
            print("详细错误信息: \(error.localizedDescription)")
        }
    }

    func saveState() {
        let currentState = EditHistory.State(
            segments: editableSegments,
            selectedId: selectedSegmentId
        )
        editHistory.push(currentState)
    }
    
    func undo() {
        guard let previousState = editHistory.undo() else { return }
        editableSegments = previousState.segments
        selectedSegmentId = previousState.selectedId
    }
    
    func redo() {
        guard let nextState = editHistory.redo() else { return }
        editableSegments = nextState.segments
        selectedSegmentId = nextState.selectedId
    }

    func exportToSRT() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "srt")!]
        savePanel.nameFieldStringValue = "subtitle.srt"
        
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                let srtContent = generateSRTContent()
                do {
                    try srtContent.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("保存 SRT 文件失败: \(error)")
                }
            }
        }
    }
    
    func generateSRTContent() -> String {
        var srtContent = ""
        for (index, segment) in editableSegments.enumerated() {
            srtContent += "\(index + 1)\n"
            srtContent += "\(formatTimeForSRT(seconds: segment.startTime)) --> \(formatTimeForSRT(seconds: segment.endTime))\n"
            
            // 处理原始文本，确保单词之间只有一个空格，并去除首尾空格
            let originalText = segment.text
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces) // 去除首尾空格
                srtContent += "\(originalText)\n\n"
            }
        return srtContent
    }
    
    func exportToJSON() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "json")!]
        savePanel.nameFieldStringValue = "subtitle.json"
        
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                let jsonContent = generateJSONContent()
                do {
                    let jsonData = try JSONEncoder().encode(jsonContent)
                    try jsonData.write(to: url)
                } catch {
                    print("保存 JSON 文件失败: \(error)")
                }
            }
        }
    }
    
    func generateJSONContent() -> WhisperTranscription {
        // 将编辑后的段落转换回 WhisperTranscription 格式
        let segments = editableSegments.map { segment in
            WhisperTranscription.Segment(
                start: segment.startTime,
                end: segment.endTime,
                text: segment.text,
                words: segment.words.map { word in
                    WhisperTranscription.Word(
                        word: word.word,
                        start: word.start,
                        end: word.end,
                        probability: word.probability
                    )
                }
            )
        }
        
        return WhisperTranscription(
            text: editableSegments.map { $0.text }.joined(separator: " "),
            segments: segments,
            language: "en" // 或其他语言代码
        )
    }

    // 更新段落文本
    func updateSegmentText(_ segmentId: UUID, newText: String) {
        saveState() // 保存当前状态用于撤销
        
        if let index = editableSegments.firstIndex(where: { $0.id == segmentId }) {
            var segment = editableSegments[index]
            segment.updateText(newText)
            editableSegments[index] = segment
        }
    }

    // 添加辅助函数
    func timeStringToSeconds(_ timeString: String) -> Double? {
        let components = timeString.split(separator: ":").map { String($0) }
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    func secondsToTimeString(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    func exportVideoClip() {
        guard let url = selectedVideo else { return }
        
        let startTime = timeStringToSeconds(clipStartTime) ?? 0
        let endTime = timeStringToSeconds(clipEndTime) ?? 0
        
        let asset = AVAsset(url: url)
        let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("exported_clip.mov")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        
        // 设置时间范围
        exportSession.timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600),
                                               duration: CMTime(seconds: endTime - startTime, preferredTimescale: 600))
        
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                print("视频片段导出成功: \(outputURL.path)")
                // 可以在里添加保存到文件逻辑
            case .failed:
                print("视频段导出失败: \(exportSession.error?.localizedDescription ?? "未知错误")")
            default:
                print("视频片段导出状态: \(exportSession.status)")
            }
        }
    }

    // 更新播放器时间
    func updatePlayerTime(from timeString: String) {
        if let time = timeStringToSeconds(timeString) {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) // 精确跳转
        }
    }

    // 分割段落逻辑
    func splitSegmentAtIndex(_ wordIndex: Int, in segmentIndex: Int) {
        guard segmentIndex >= 0 && segmentIndex < editableSegments.count else { return }
        
        let segment = editableSegments[segmentIndex]
        let words = segment.words
        
        // 确保索引在有效范围内
        guard wordIndex > 0 && wordIndex < words.count else { return } // 确保 wordIndex 大于 0
        
        // 找到光标位置对应的单词索引
        let splitWords = Array(words[0..<wordIndex])  // 包含当前单词前的所有单词
        let remainingWords = Array(words[wordIndex...])  // 包含当前单词及其后面的所有单词
        
        // 创建新的段落
        let newSegment = EditableSegment(words: remainingWords)
        
        // 更新段落列表
        editableSegments[segmentIndex] = EditableSegment(words: splitWords)  // 更新当前段落
        editableSegments.insert(newSegment, at: segmentIndex + 1)  // 插入新段落
        
        // 更新选中状态
        selectedSegmentId = newSegment.id  // 选中新的段落
    }

    // 合并段落的逻辑
    func mergeSegments(at index: Int) {
        guard index >= 0 && index < editableSegments.count - 1 else { return }
        
        let currentSegment = editableSegments[index]
        let nextSegment = editableSegments[index + 1]
        
        // 合并两个段落的单词
        let mergedWords = currentSegment.words + nextSegment.words
        let mergedSegment = EditableSegment(words: mergedWords)
        
        // 更新段落列表
        editableSegments[index] = mergedSegment
        editableSegments.remove(at: index + 1)  // 移除下一个段落
        
        // 更新选中状态
        selectedSegmentId = mergedSegment.id  // 选中合并后的段落
    }

    // 修改高亮文本的函数
    func highlightText(_ text: String, keyword: String) -> AttributedString {
        guard !keyword.isEmpty else {
            return AttributedString(text)
        }
        
        var attributedString = AttributedString(text)
        
        do {
            // 创建正则表达式
            let regex = try NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: keyword),
                options: .caseInsensitive
            )
            
            // 获取所有匹配
            let matches = regex.matches(
                in: text,
                range: NSRange(location: 0, length: text.count)
            )
            
            // 处理每个匹配
            for match in matches {
                if let range = Range(match.range, in: text) {
                    // 直接在原始的 AttributedString 上设置属性
                    let lowerBound = text.distance(from: text.startIndex, to: range.lowerBound)
                    let upperBound = text.distance(from: text.startIndex, to: range.upperBound)
                    let attributedRange = attributedString.range(of: text[range])
                    
                    if let attributedRange = attributedRange {
                        attributedString[attributedRange].backgroundColor = .yellow
                        attributedString[attributedRange].foregroundColor = .black
                    }
                }
            }
        } catch {
            print("正则表达式错误: \(error)")
        }
        
        return attributedString
    }

    // 添加过滤逻辑
    var filteredSegments: [TextSegment] {
        if searchKeyword.isEmpty {
            return videoProcessor.textSegments
        }
        return videoProcessor.textSegments.filter { segment in
            segment.text.localizedCaseInsensitiveContains(searchKeyword)
        }
    }
}

struct EditableWord: Identifiable {
    let id = UUID()
    let word: String
    let start: Double
    let end: Double
    let probability: Double
}

struct EditableSegment: Identifiable {
    let id: UUID
    var words: [EditableWord]
    
    var text: String {
        words.map { $0.word }.joined(separator: " ")
    }
    
    var startTime: Double {
        words.first?.start ?? 0
    }
    
    var endTime: Double {
        words.last?.end ?? 0
    }

    var translatedText: String? // 新增属性用存储翻译结果
    
    // 添加初始化方法
    init(id: UUID = UUID(), words: [EditableWord]) {
        self.id = id
        self.words = words
    }
    
    // 添加更新文本的方法
    mutating func updateText(_ newText: String) {
        let newWords = newText.split(separator: " ").map { word -> EditableWord in
            EditableWord(
                word: String(word),
                start: words.first?.start ?? 0,
                end: words.last?.end ?? 0,
                probability: 1.0
            )
        }
        words = newWords
    }
}

struct SegmentView: View {  
    let segment: EditableSegment
    let isSelected: Bool
    let isLastSegment: Bool // 新增参数
    @Binding var cursorPosition: Int?
    let onSelect: () -> Void
    let onSplit: (Int) -> Void  // 分割回调
    let onMerge: () -> Void  // 合并回调
    let onTimeClick: (Double) -> Void  // 时间戳点击回调
    
    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            // 左侧内容
            VStack(alignment: .leading, spacing: 6) {
                // 合并按钮
                if !isLastSegment { // 使用 isLastSegment
                    Button("合并") {
                        onMerge()  // 调用合并回调
                    }
                    .frame(width: 50) // 设置按钮宽度
                    .buttonStyle(BorderlessButtonStyle())
                    .foregroundColor(.white) // 设置按钮文本颜色白色
                    .background(Color.red.opacity(0.3)) // 设置按钮背景颜色
                    .cornerRadius(5) // 设置圆角  
                }
            }
            .padding(.top, 50) // 在左侧内容顶部添加间距
            .frame(width: 80) // 设置左侧内容宽度
            
            // 右侧内容
            VStack(alignment: .leading, spacing: 2) {
                // 可点击的时间戳
                Button(action: {
                    onTimeClick(segment.startTime)  // 点击时间戳跳转到开始时间
                }) {
                    Text("\(TimeFormatter.formatSRT(seconds: segment.startTime)) --> \(TimeFormatter.formatSRT(seconds: segment.endTime))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8) // 增加内边距以扩大点击区域
                        .background(Color.gray.opacity(0.1)) // 添加背色表示可点击
                        .cornerRadius(2)
                }
                .buttonStyle(PlainButtonStyle()) // 使用 PlainButtonStyle 以确保指针变为手指头形状
                
                // 可点击的段落区域
                HStack(spacing: 4) {
                    ForEach(segment.words, id: \.id) { word in
                        Text(word.word)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                            .onTapGesture {
                                onSelect()
                                // 触发分割，传递当前单词的索引
                                let index = segment.words.firstIndex(where: { $0.id == word.id })!
                                onSplit(index)  // 传递单词索引
                            }
                    }
                }
                .padding(8)
                .background(isSelected ? Color.gray.opacity(0.1) : Color.clear)
                .cornerRadius(4)
                .onTapGesture {
                    onSelect()  // 点击段落区域选择该段落
                }    
            }
            .frame(maxWidth: .infinity, alignment: .leading) // 右侧内容占满剩余空间
        }
        .padding(.vertical, 4) // 落上下间距
        .padding(.horizontal, 10) // 段落左右间距
    }
}

struct EditHistory {
    private(set) var undoStack: [State] = []
    private(set) var redoStack: [State] = []
    
    struct State {
        let segments: [EditableSegment]
        let selectedId: UUID?
    }
    
    mutating func push(_ state: State) {
        undoStack.append(state)
        redoStack.removeAll() // 清除做栈
    }
    
    mutating func undo() -> State? {
        guard let current = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return undoStack.last
    }
    
    mutating func redo() -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(next)
        return next
    }
}

struct SegmentDropDelegate: DropDelegate {
    let item: EditableSegment
    @Binding var items: [EditableSegment]
    @Binding var draggedItem: UUID?
    
    func performDrop(info: DropInfo) -> Bool {
        guard let draggedItem = draggedItem else { return false }
        let fromIndex = items.firstIndex { $0.id == draggedItem }
        let toIndex = items.firstIndex { $0.id == item.id }
        
        if let fromIndex = fromIndex, let toIndex = toIndex {
            withAnimation {
                let item = items.remove(at: fromIndex)
                items.insert(item, at: toIndex)
            }
        }
        
        return true
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

// 添加一个时间格式化工具类
struct TimeFormatter {
    static func formatSRT(seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let milliseconds = Int((seconds - Double(Int(seconds))) * 1000)
        
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }
    
    static func formatSimple(seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
