//
//  HLSAssetReader.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 23.10.2024.
//

import Foundation
import AVFoundation

final class HLSAssetReader {

    typealias CompletionHandler = () -> Void
    typealias TimeUpdateHandler = (CMTime) -> Void
    typealias AboutToEndHandler = () -> Void

    var rate: Float = 1
    var aboutToEndHandler: AboutToEndHandler?
    private var didInformAboutToEnd: Bool = false

    private var completionHandler: CompletionHandler?
    private var timeUpdateHandler: TimeUpdateHandler?

    private var currentAssetReader: AVAssetReader?
    private var currentVideoOutput: AVAssetReaderTrackOutput?

    private var startTime: CFTimeInterval = 0
    private var isReading: Bool = false

    private var totalDurationOfPlayableSegment: CMTime?
    private var framesToPlay: Int = 0

    private lazy var currentVideoOutputTime: CMTime = CMTime(
        seconds: 0,
        preferredTimescale: CMTimeScale(floor((currentVideoOutput?.track.nominalFrameRate ?? 0) * rate))
    )

    init(timeUpdateHandler: TimeUpdateHandler? = nil) {
        self.timeUpdateHandler = timeUpdateHandler
    }

    func prepareForReading(from fileURL: URL, at time: TimeInterval?) throws {
        let asset = AVURLAsset(url: fileURL)
        currentAssetReader = try AVAssetReader(asset: asset)
        var nominalFrameRate: Float?

        if let track = asset.tracks(withMediaType: .video).first {
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [String(kCVPixelBufferPixelFormatTypeKey):
                                    NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            )
            nominalFrameRate = track.nominalFrameRate
            totalDurationOfPlayableSegment = track.asset?.duration
            currentAssetReader?.add(output)
            currentVideoOutput = output
        }

        if let time,
           let nominalFrameRate {
            let startFromTime = CMTime(
                value: CMTimeValue(floor(Float(time) * nominalFrameRate * rate)),
                timescale: CMTimeScale(floor(nominalFrameRate * rate))
            )
            currentAssetReader?.timeRange = CMTimeRange(start: startFromTime, end: .positiveInfinity)
            if let totalDurationOfPlayableSegment {
                self.totalDurationOfPlayableSegment = totalDurationOfPlayableSegment - startFromTime
            }
        }

        framesToPlay = Int((totalDurationOfPlayableSegment?.seconds ?? 0) * Double(nominalFrameRate ?? 0))
        print("HLSPLayer: initial frames to play: \(framesToPlay) for \(totalDurationOfPlayableSegment?.seconds ?? 0) seconds with \(nominalFrameRate ?? 0) fps")
    }

    func startReading(completion: CompletionHandler? = nil) {
        didInformAboutToEnd = false
        completionHandler = completion
        currentAssetReader?.startReading()
        startTime = CACurrentMediaTime()
        currentVideoOutputTime = .zero
        isReading = true
    }

    func pause() {
        isReading = false
    }

    func stop() {
        isReading = false
        currentAssetReader = nil
        currentVideoOutput = nil
    }

    func resume() {
        isReading = true
        startTime = CACurrentMediaTime() - currentVideoOutputTime.seconds
    }

    // MARK: - Video

    func videoSampleBufferTime(forHostTime hostTimeInSeconds: CFTimeInterval) -> CMTime {
        let seconds = hostTimeInSeconds - startTime
        let frameRate = (currentVideoOutput?.track.nominalFrameRate ?? 0)
        return CMTime(seconds: seconds, preferredTimescale: CMTimeScale(floor(frameRate * rate)))
    }

    func videoSampleBuffer(for presentationTime: CMTime) -> CMSampleBuffer? {
        guard isReading else {
            return nil
        }

        defer {
            framesToPlay -= 1

            print("HLSPLayer: left \(framesToPlay) frames to play")

            currentVideoOutputTime = presentationTime
            let outputTime = CMTime(
                value: presentationTime.value,
                timescale: CMTimeScale(floor(Float(presentationTime.timescale) / rate))
            )
            timeUpdateHandler?(outputTime)
            if let totalDuration = totalDurationOfPlayableSegment {
                let correctedTotalDuration = timeAffectedByCurrentRate(totalDuration)
                let elapsedTime = (correctedTotalDuration - presentationTime).seconds

                if !didInformAboutToEnd,
                   elapsedTime < (1.5 / Double(rate)) {
                    aboutToEndHandler?()
                    didInformAboutToEnd = true
                }

                if framesToPlay == 0 {
                    completionHandler?()
                }
            }
        }

        return currentVideoOutput?.copyNextSampleBuffer()
    }

    func hasNewPixelBuffer(for presentationTime: CMTime) -> Bool {
        isReading &&
        currentAssetReader?.status == .reading &&
        (currentVideoOutputTime < presentationTime ||
         (currentVideoOutputTime.value == 0 && presentationTime.value == 0))
    }

    // MARK: - Private

    private func timeAffectedByCurrentRate(_ time: CMTime) -> CMTime {
        CMTime(
            value: time.value,
            timescale: CMTimeScale(floor(Float(time.timescale) * rate))
        )
    }
}
