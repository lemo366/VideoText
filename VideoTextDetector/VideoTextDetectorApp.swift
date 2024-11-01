//
//  VideoTextDetectorApp.swift
//  VideoTextDetector
//
//  Created by lhr on 9/19/24.
//

import SwiftUI

@main
struct VideoTextDetectorApp: App {
    var body: some Scene {
        WindowGroup {
            if #available(macOS 15.0, *) {
                ContentView()
            } else {
                // Fallback on earlier versions
            }
        }
    }
}
