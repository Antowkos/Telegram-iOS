//
//  BandwidthMeasurement.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 22.10.2024.
//

import Foundation

struct BandwidthMeasurement {
    var startTime = Date()
    var finishTime = Date()
    var bytes: Int = 0
}
