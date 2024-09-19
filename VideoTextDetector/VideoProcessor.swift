import Foundation
import Vision
import AVFoundation
import AppKit

class VideoProcessor: ObservableObject {
    @Published var detectedFrames: [DetectedFrame] = []
    @Published var isProcessing = false
    
    func processVideo(url: URL, recognitionLevel: VNRequestTextRecognitionLevel, recognitionLanguage: String) {
        // 视频处理: processVideo 方法现在能够逐帧处理视频,提取图像并进行文本检测。
        isProcessing = true
        // 进度跟踪: 添加了 isProcessing 属性来跟踪处理状态。
        detectedFrames.removeAll()
        
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 逐帧处理视频
            for time in stride(from: 0.0, to: duration, by: 2.0) {
                let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { continue }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                
                self.detectText(in: image, timestamp: time, recognitionLevel: recognitionLevel, recognitionLanguage: recognitionLanguage) { detectedText in
                    DispatchQueue.main.async {
                        // 并行处理
                        let frame = DetectedFrame(image: image, timestamp: time, detectedText: detectedText)
                        self.detectedFrames.append(frame)   
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.isProcessing = false
            }
        }
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
