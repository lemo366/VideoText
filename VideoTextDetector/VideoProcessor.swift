import Foundation
import Vision
import AVFoundation
import AppKit

struct TextSegment: Identifiable {
    let id = UUID()
    let text: String
    let startTime: Double
    let endTime: Double
    let frames: [DetectedFrame]
    let textBounds: CGRect
}

class VideoProcessor: ObservableObject {
    @Published var detectedFrames: [DetectedFrame] = []
    @Published var textSegments: [TextSegment] = []
    @Published var isProcessing = false
    @Published var progress: Int = 0
    
    func processVideo(url: URL, recognitionLevel: VNRequestTextRecognitionLevel, recognitionLanguage: String) async throws -> [DetectedFrame] {
        await MainActor.run {
            self.isProcessing = true
            self.textSegments = []
            self.progress = 0
        }
        
        var detectedFrames: [DetectedFrame] = []
        var currentSegments: [String: (startTime: Double, frames: [DetectedFrame], textBounds: CGRect)] = [:]
        
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        print("视频总时长: \(durationSeconds)秒")
        
        // 每秒采样的帧数
        let frameRate: Double = 2  // 可以根据需要调整，比如每秒2帧
        let totalFrames = Int(durationSeconds * frameRate)
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        // 遍历整个视频时长
        for frameIndex in 0..<totalFrames {
            let timeInSeconds = Double(frameIndex) / frameRate
            let time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
            
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                
                // 执行文本检测
                if let (detectedText, textBounds) = try await detectText(in: nsImage, recognitionLevel: recognitionLevel, recognitionLanguage: recognitionLanguage) {
                    let frame = DetectedFrame(
                        image: nsImage,
                        detectedText: detectedText,
                        timestamp: timeInSeconds,
                        textBounds: textBounds
                    )
                    detectedFrames.append(frame)
                    updateTextSegments(frame: frame, currentSegments: &currentSegments)
                    
                    // 打印进度
                    if frameIndex % 10 == 0 {
                        print("处理进度: \(Int((Double(frameIndex) / Double(totalFrames)) * 100))%")
                    }
                }
            } catch {
                print("处理第 \(frameIndex) 帧时出错: \(error)")
                continue
            }
            
            // 更新进度
            let currentProgress = Int((Double(frameIndex) / Double(totalFrames)) * 100)
            await MainActor.run {
                self.progress = currentProgress
            }
        }
        
        // 处理完成后更新文本段
        var newSegments: [TextSegment] = []
        for (text, segmentInfo) in currentSegments {
            // 移除时间戳后缀（如果存在）
            let cleanText = text.split(separator: "_").first.map(String.init) ?? text
            
            let textSegment = TextSegment(
                text: cleanText,
                startTime: segmentInfo.startTime,
                endTime: segmentInfo.frames.last?.timestamp ?? segmentInfo.startTime,
                frames: segmentInfo.frames,
                textBounds: segmentInfo.textBounds
            )
            newSegments.append(textSegment)
            print("添加文本段: \(cleanText), 开始时间: \(segmentInfo.startTime), 结束时间: \(segmentInfo.frames.last?.timestamp ?? segmentInfo.startTime), 帧数: \(segmentInfo.frames.count)")
        }
        
        // 按时间排序
        newSegments.sort { $0.startTime < $1.startTime }
        
        await MainActor.run {
            self.textSegments = newSegments
            self.isProcessing = false
            print("视频处理完成，共检测到 \(newSegments.count) 个文本段落")
        }
        
        return detectedFrames
    }
    
    private func detectText(in image: NSImage, recognitionLevel: VNRequestTextRecognitionLevel, recognitionLanguage: String) async throws -> (String, CGRect)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                
                var detectedText = ""
                var unionRect = CGRect.zero
                var isFirst = true
                
                for observation in observations {
                    if let candidate = observation.topCandidates(1).first {
                        if !isFirst {
                            detectedText += " "
                        }
                        detectedText += candidate.string
                        
                        // 转换边界框坐标
                        let boundingBox = observation.boundingBox
                        let convertedRect = CGRect(
                            x: boundingBox.origin.x * CGFloat(cgImage.width),
                            y: (1 - boundingBox.origin.y - boundingBox.height) * CGFloat(cgImage.height),
                            width: boundingBox.width * CGFloat(cgImage.width),
                            height: boundingBox.height * CGFloat(cgImage.height)
                        )
                        
                        if isFirst {
                            unionRect = convertedRect
                        } else {
                            unionRect = unionRect.union(convertedRect)
                        }
                        
                        isFirst = false
                    }
                }
                
                if !detectedText.isEmpty {
                    continuation.resume(returning: (detectedText, unionRect))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            
            request.recognitionLevel = recognitionLevel
            request.recognitionLanguages = [recognitionLanguage]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // 添加新方法用于更新文本段
    private func updateTextSegments(frame: DetectedFrame, currentSegments: inout [String: (startTime: Double, frames: [DetectedFrame], textBounds: CGRect)]) {
        guard !frame.detectedText.isEmpty else { return }
        
        if let existingSegment = currentSegments[frame.detectedText] {
            // 如果与最后一帧的时间间隔小于2秒，则添加到当前段
            if frame.timestamp - existingSegment.frames.last!.timestamp < 2.0 {
                // 添加新帧到现有段落
                currentSegments[frame.detectedText]?.frames.append(frame)
                // 更新文本边界为所有帧的并集
                currentSegments[frame.detectedText]?.textBounds = existingSegment.textBounds.union(frame.textBounds)
            } else {
                // 如果时间间隔太大，创建新的段落（使用不同的键来区分）
                let newKey = "\(frame.detectedText)_\(frame.timestamp)"
                currentSegments[newKey] = (startTime: frame.timestamp, frames: [frame], textBounds: frame.textBounds)
            }
        } else {
            // 创建新段落
            currentSegments[frame.detectedText] = (startTime: frame.timestamp, frames: [frame], textBounds: frame.textBounds)
        }
    }
    
    // 更新搜索方法以支持文本段
    func searchKeyword(_ keyword: String) -> [TextSegment] {
        return textSegments.filter { $0.text.lowercased().contains(keyword.lowercased()) }
    }
}

struct DetectedFrame: Identifiable {
    let id = UUID()
    let image: NSImage
    let detectedText: String
    let timestamp: Double
    let textBounds: CGRect
}
