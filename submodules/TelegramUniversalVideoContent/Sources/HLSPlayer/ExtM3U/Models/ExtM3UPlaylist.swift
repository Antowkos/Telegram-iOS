//
//  ExtM3UPlaylist.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 13.10.2024.
//

import Foundation

struct ExtM3UPlaylist {
    let resolution: ExtM3UPlaylistInfo.Resolution
    let bandwidth: Double
    let mediaInitializationByteRange: ExtM3UMediaSegmentByteRange.ByteRange?
    let mediaInitializationFileURI: String?
    let mediaSegments: [ExtM3UMediaSegment]
}
