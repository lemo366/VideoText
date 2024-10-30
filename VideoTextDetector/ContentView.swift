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
    @State private var editableSegments: [EditableSegment] = []
    @State private var selectedSegmentId: UUID?
    @State private var cursorPosition: Int?
    @State private var editHistory = EditHistory()
    @State private var draggedSegmentId: UUID?

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
                            Text("速").tag(VNRequestTextRecognitionLevel.fast)
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
                                .keyboardShortcut("e", modifiers: .command)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            
                            // 字幕列表
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(editableSegments) { segment in
                                        SegmentView(
                                            segment: segment,
                                            isSelected: segment.id == selectedSegmentId,
                                            cursorPosition: $cursorPosition,
                                            onSelect: { selectSegment(segment.id) },
                                            onSplit: { position in
                                                cursorPosition = position
                                                splitSegmentAtCursor()
                                            },
                                            onTimeClick: { time in
                                                // 跳转到视频时间点
                                                player?.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
                                            }
                                        )
                                    }
                                }
                                .padding()
                            }
                            // 隐藏的快捷键按钮
                            Group {
                                Button("合并") {
                                    if selectedSegmentId != nil {
                                        mergeSegments()
                                    }
                                }
                                .keyboardShortcut("m", modifiers: .command)
                                
                                Button("分割") {
                                    if selectedSegmentId != nil && cursorPosition != nil {
                                        splitSegmentAtCursor()
                                    }
                                }
                                .keyboardShortcut("s", modifiers: .command)
                                
                                Button("撤销") {
                                    if !editHistory.undoStack.isEmpty {
                                        undo()
                                    }
                                }
                                .keyboardShortcut("z", modifiers: .command)
                                
                                Button("重做") {
                                    if !editHistory.redoStack.isEmpty {
                                        redo()
                                    }
                                }
                                .keyboardShortcut("z", modifiers: [.command, .shift])
                            }
                            .hidden() // 隐藏按钮但保持功能
                        }
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
                    // Button("导出 SRT 字幕") {
                    //     saveSRTFile()
                    // }
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
    // func saveSRTFile() {
    //     let openPanel = NSOpenPanel()
    //     openPanel.allowedContentTypes = [UTType(filenameExtension: "json")!]
    //     openPanel.allowsMultipleSelection = false
        
    //     openPanel.begin { result in
    //         if result == .OK, let jsonURL = openPanel.url {
    //             let srtContent = generateSRTFromJSON(jsonURL: jsonURL)
                
    //             let savePanel = NSSavePanel()
    //             savePanel.allowedContentTypes = [UTType(filenameExtension: "srt")!]
    //             savePanel.nameFieldStringValue = "transcription.srt"
                
    //             savePanel.begin { result in
    //                 if result == .OK, let url = savePanel.url {
    //                     do {
    //                         try srtContent.write(to: url, atomically: true, encoding: .utf8)
    //                         print("SRT 文件已保存到: \(url.path)")
    //                     } catch {
    //                         print("保存 SRT 文件失败: \(error)")
    //                     }
    //                 }
    //             }
    //         }
    //     }
    // }
    
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
                
                // 保存 JSON 文件并处理转录结果
                for result in transcriptionResults {
                    let saveResult = writeJSONFile(result: result)
                    switch saveResult {
                    case .success(let path):
                        print("JSON 文件已保存到: \(path)")
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
        return outputURL.path // 返回输出路径
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
        saveState() // ��存当前状态
        guard let currentIndex = editableSegments.firstIndex(where: { $0.id == selectedSegmentId }),
              let cursor = cursorPosition else { return }
        
        let segment = editableSegments[currentIndex]
        let text = segment.text
        
        // 在光标位置分割文本
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
            srtContent += "\(segment.text)\n\n"
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
    @Binding var cursorPosition: Int?
    let onSelect: () -> Void
    let onSplit: (Int) -> Void
    let onTimeClick: (Double) -> Void  // 添加时间戳点击回调
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 可点击的时间戳
            Text("\(TimeFormatter.formatSRT(seconds: segment.startTime)) --> \(TimeFormatter.formatSRT(seconds: segment.endTime))")
                .font(.caption)
                .foregroundColor(.secondary)
                .onTapGesture {
                    onTimeClick(segment.startTime)  // 点击时间戳跳转到开始时间
                }
                .background(Color.gray.opacity(0.1))  // 添加背景色表示可点击
                .cornerRadius(2)
            
            // 单词级别的显示和交互（保持分割功能）
            HStack(spacing: 4) {
                ForEach(segment.words, id: \.id) { word in
                    Text(word.word)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                        .onTapGesture {
                            onSelect()
                            let index = segment.words.firstIndex(where: { $0.id == word.id })!
                            let position = index > 0 ? segment.words[..<index]
                                .map { $0.word.count + 1 }
                                .reduce(0, +) : 0
                            onSplit(position)
                        }
                }
            }
            .padding(8)
            .background(isSelected ? Color.gray.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
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
        redoStack.removeAll() // 清除重做栈
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
