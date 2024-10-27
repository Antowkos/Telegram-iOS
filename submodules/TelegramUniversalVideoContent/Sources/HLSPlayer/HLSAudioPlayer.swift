//
//  HLSAudioPlayer.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 24.10.2024.
//

import AVFoundation
import AudioToolbox

final class HLSAudioPlayer {

    let playerNode = AVAudioPlayerNode()
    var rate: Float = 1 {
        didSet {
            speedControlNode.rate = rate
        }
    }

    private let audioEngine = AVAudioEngine()
    private let speedControlNode = AVAudioUnitTimePitch()

    private var sampleRate: Double = 0

    init() {
        do {
            audioEngine.attach(playerNode)
            audioEngine.attach(speedControlNode)
            audioEngine.connect(playerNode, to: speedControlNode, format: nil)
            audioEngine.connect(speedControlNode, to: audioEngine.mainMixerNode, format: nil)
            try audioEngine.start()
            play()
        }
        catch {
            print(error)
        }
    }

    func schedule(_ buffers: [AVAudioPCMBuffer]) {
        buffers.forEach({ schedule($0) })
    }

    func pause() {
        playerNode.pause()
    }

    func play() {
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
    }

    // MARK: - Private

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        sampleRate = buffer.format.sampleRate
        playerNode.scheduleBuffer(buffer)
    }
}
