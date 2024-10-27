//
//  ExtM3UPlaylistInfo.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 12.10.2024.
//

import Foundation

struct ExtM3UPlaylistInfo {

    enum Resolution {
        case unsupported
        case r240
        case r360
        case r480
        case r720
        case r1080
    }

    let bandwidth: Double
    let resolution: Resolution
    let urlString: String
}
