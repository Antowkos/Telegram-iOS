//
//  HLSVideoOutput.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 23.10.2024.
//

import Foundation
import AVFoundation

final class HLSVideoOutput {

    var assetReadear: HLSAssetReader?

    func videoSampleBufferTime(forHostTime hostTimeInSeconds: CFTimeInterval) -> CMTime {
        guard let assetReadear else {
            assertionFailure("You must add output to player first")
            return .zero
        }
        return assetReadear.videoSampleBufferTime(forHostTime: hostTimeInSeconds)
    }

    func videoSampleBuffer(for presentationTime: CMTime) -> CMSampleBuffer? {
        guard let assetReadear else {
            assertionFailure("You must add output to player first")
            return nil
        }
        return assetReadear.videoSampleBuffer(for: presentationTime)
    }

    func hasNewPixelBuffer(for presentationTime: CMTime) -> Bool {
        guard let assetReadear else {
            assertionFailure("You must add output to player first")
            return false
        }
        return assetReadear.hasNewPixelBuffer(for: presentationTime)
    }
}
