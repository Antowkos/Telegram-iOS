//
//  HLSBuffer.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 24.10.2024.
//

import Foundation
import AVFoundation

final class HLSBuffer {

    private(set) var prefferedDuration: TimeInterval = 20
    private(set) var minimalDuration: TimeInterval = 5
    private(set) var actualDuration: TimeInterval = 0
    private(set) var bufferizedTillTime: TimeInterval = 0

    var initiallyBecomeReadyToPlayHandler: (() -> Void)?
    var bufferizedTimeIncreasedHandler: (() -> Void)?

    var bufferItemsCount: Int {
        bufferItems.count
    }

    private var didNotifyBecomeReadyToPlay: Bool = false

    private var bufferItems: [HLSBufferItem] = []
    private var currentBufferItemIndex: Int = 0

    var shouldBeFilled: Bool {
        actualDuration < prefferedDuration
    }

    var isReadyToPlay: Bool {
        actualDuration >= minimalDuration
    }

    func register(
        segment: ExtM3UMediaSegment,
        bandwidth: Double,
        fileURL: URL,
        audioBuffers: [AVAudioPCMBuffer],
        isLast: Bool
    ) {
        actualDuration += segment.duration
        bufferItems.append(HLSBufferItem(
            segment: segment,
            bandwidth: bandwidth,
            fileURL: fileURL,
            audioBuffers: audioBuffers,
            isLast: isLast
        ))
        bufferizedTillTime = segment.startTime + segment.duration

        if bufferizedTillTime >= minimalDuration,
           !didNotifyBecomeReadyToPlay {
            didNotifyBecomeReadyToPlay = true
            initiallyBecomeReadyToPlayHandler?()
        }

        bufferizedTimeIncreasedHandler?()
    }

    func nextBufferItem() -> HLSBufferItem? {
        guard currentBufferItemIndex < bufferItems.count else {
            return nil
        }

        let item = bufferItems[currentBufferItemIndex]
        currentBufferItemIndex += 1
        actualDuration -= item.segment.duration
        return item
    }

    func nextBufferItemForAudioPreparations() -> HLSBufferItem? {
        guard currentBufferItemIndex < bufferItems.count else {
            return nil
        }

        let item = bufferItems[currentBufferItemIndex]
        return item
    }

    func resetCurrentBufferItemIndex() {
        currentBufferItemIndex = 0
    }

    func flush() {
        bufferItems.removeAll()
        currentBufferItemIndex = 0
        actualDuration = 0
        bufferizedTillTime = 0
        didNotifyBecomeReadyToPlay = false
    }

    func updateBufferizedTillTime(_ time: TimeInterval) {
        bufferizedTillTime = time
    }
}
