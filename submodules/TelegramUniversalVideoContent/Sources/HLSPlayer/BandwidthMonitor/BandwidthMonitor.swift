//
//  BandwidthMonitor.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 22.10.2024.
//

import Foundation

final class BandwidthMonitor {

    typealias BandwidthChangeHandler = (Double) -> Void

    private var bandwidthChangeHandler: BandwidthChangeHandler
    private var lastMeasurement: BandwidthMeasurement?

    private var lowEWMAAlpha: Double = 0.2
    private var highEWMAAlpha: Double = 0.8

    init(_ handler: @escaping BandwidthChangeHandler) {
        self.bandwidthChangeHandler = handler
    }

    func update(with measurement: BandwidthMeasurement) {
        guard let lastMeasurement else {
            self.lastMeasurement = measurement
            return
        }

        guard measurement.startTime > lastMeasurement.startTime else {
            return
        }

        let bandwidth = calculateEWMABandwidth(new: measurement, old: lastMeasurement)
        self.lastMeasurement = measurement
        bandwidthChangeHandler(bandwidth)
    }

    private func calculateEWMABandwidth(new: BandwidthMeasurement, old: BandwidthMeasurement) -> Double {
        let newBandwidth = calculateBandwidth(for: new)
        let oldBandwidth = calculateBandwidth(for: old)
        let lowEWMA = lowEWMAAlpha * newBandwidth + (1 - lowEWMAAlpha) * oldBandwidth
        let highEWMA = highEWMAAlpha * newBandwidth + (1 - highEWMAAlpha) * oldBandwidth
        return min(lowEWMA, highEWMA)
    }

    private func calculateBandwidth(for measurement: BandwidthMeasurement) -> Double {
        let time = measurement.finishTime.timeIntervalSince(measurement.startTime)
        let bits = measurement.bytes * 8
        return Double(bits) / time
    }
}
