import Foundation
import Vision
import AVFoundation
import AppKit

class VideoProcessor: ObservableObject {
    @Published var detectedFrames: [DetectedFrame] = []
    @Published var isProcessing = false
    private var frameCache: [Double: DetectedFrame] = [:] // 缓存字典

    func processVideo(url: URL) {
        isProcessing = true
        detectedFrames.removeAll()
        
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            for time in stride(from: 0.0, to: duration, by: 2.0) {
                if let cachedFrame = self.frameCache[time] {
                    // 如果缓存中有该帧，直接使用
                    DispatchQueue.main.async {
                        self.detectedFrames.append(cachedFrame)
                    }
                    continue
                }
                
                let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { continue }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                
                self.detectText(in: image, timestamp: time) { detectedText in
                    let frame = DetectedFrame(image: image, timestamp: time, detectedText: detectedText)
                    self.frameCache[time] = frame // 缓存该帧
                    DispatchQueue.main.async {
                        self.detectedFrames.append(frame)
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.isProcessing = false
            }
        }
    }
    
    private func detectText(in image: NSImage, timestamp: Double, completion: @escaping (String) -> Void) {
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
        
        request.recognitionLevel = .accurate
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }
    
    func searchKeyword(_ keyword: String) -> [DetectedFrame] {
        var uniqueFrames: Set<DetectedFrame> = []
        let results = detectedFrames.filter { $0.detectedText.lowercased().contains(keyword.lowercased()) }
        
        for frame in results {
            uniqueFrames.insert(frame) // 使用集合确保唯一性
        }
        
        return Array(uniqueFrames)
    }
}

struct DetectedFrame: Identifiable {
    let id = UUID()
    let image: NSImage
    let timestamp: Double
    let detectedText: String
}
