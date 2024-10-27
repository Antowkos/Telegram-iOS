//
//  ExtMediaSegment.swift
//  _LocalDebugOptions
//
//  Created by Anton Kovalev on 15.10.2024.
//

import Foundation

protocol ExtM3UMediaSegment {
    var id: String { get }
    var uri: String { get }
    var duration: TimeInterval { get }
    var startTime: TimeInterval { get }
    var resolution: ExtM3UPlaylistInfo.Resolution { get }
}
