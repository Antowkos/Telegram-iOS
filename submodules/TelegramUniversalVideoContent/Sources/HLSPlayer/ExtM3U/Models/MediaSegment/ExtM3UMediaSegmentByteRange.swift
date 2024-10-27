//
//  ExtM3UMediaSegmentByteRange.swift
//  _LocalDebugOptions
//
//  Created by Anton Kovalev on 15.10.2024.
//

import Foundation

struct ExtM3UMediaSegmentByteRange: ExtM3UMediaSegment {

    struct ByteRange {
        let start: Int
        let end: Int
    }

    let id = UUID().uuidString
    let uri: String
    let duration: TimeInterval
    var startTime: TimeInterval
    let byteRange: ByteRange
    let resolution: ExtM3UPlaylistInfo.Resolution
}
