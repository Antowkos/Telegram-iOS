//
//  HLSBufferItem.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 24.10.2024.
//

import Foundation
import AVFoundation

struct HLSBufferItem {
    let segment: ExtM3UMediaSegment
    let bandwidth: Double
    let fileURL: URL
    let audioBuffers: [AVAudioPCMBuffer]
    let isLast: Bool
}
