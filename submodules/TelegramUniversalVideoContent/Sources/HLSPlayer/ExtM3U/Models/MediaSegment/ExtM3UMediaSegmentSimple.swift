//
//  ExtM3UMediaSegmentSimple.swift
//  _LocalDebugOptions
//
//  Created by Anton Kovalev on 15.10.2024.
//

import Foundation

struct ExtM3UMediaSegmentSimple: ExtM3UMediaSegment {
    let id = UUID().uuidString
    let uri: String
    let duration: TimeInterval
    var startTime: TimeInterval
    let resolution: ExtM3UPlaylistInfo.Resolution
}
