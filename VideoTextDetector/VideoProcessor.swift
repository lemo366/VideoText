import Foundation
import Vision
import AVFoundation
import AppKit

class VideoProcessor: ObservableObject {
    @Published var detectedFrames: [DetectedFrame] = []
    @Published var isProcessing = false
    
    func processVideo(url: URL, recognitionLevel: VNRequestTextRecognitionLevel, recognitionLanguage: String) async throws -> [DetectedFrame] {
        var detectedFrames: [DetectedFrame] = []
        
        // 处理视频的逻辑
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        for time in stride(from: 0.0, to: duration, by: 1.0) {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { continue }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            
            // 检测文本
            let detectedText = await withCheckedContinuation { continuation in
                detectText(in: image, timestamp: time, recognitionLevel: recognitionLevel, recognitionLanguage: recognitionLanguage) { text in
                    continuation.resume(returning: text)
                }
            }
            
            let frame = DetectedFrame(image: image, timestamp: time, detectedText: detectedText)
            detectedFrames.append(frame)
        }

        return detectedFrames // 返回检测到的帧
    }
    
    private func detectText(in image: NSImage, timestamp: Double,recognitionLevel: VNRequestTextRecognitionLevel, recognitionLanguage: String, completion: @escaping (String) -> Void) {
        // 文本检测: detectText 方法使用 Vision 框架进行文本检测,并将检测结果传递给 completion 闭包。
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion("")
            return
        }
        
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion("")
                return
            }
            let detectedText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            completion(detectedText)
        }
        
        request.recognitionLevel = recognitionLevel // 使用用户选择的识别级别
        request.recognitionLanguages = [recognitionLanguage] // 使用用户选择的识别语言
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }
    
    func searchKeyword(_ keyword: String) -> [DetectedFrame] {
        return detectedFrames.filter { $0.detectedText.lowercased().contains(keyword.lowercased()) }
    }
}

struct DetectedFrame: Identifiable {
    let id = UUID()
    let image: NSImage
    let timestamp: Double
    let detectedText: String
}
