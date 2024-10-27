//
//  M3U8Parser.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 12.10.2024.
//

import Foundation

enum ExtM3UParser {

    enum Error: Swift.Error {
        case invalidData
        case emptyFile
        case invalidLine
        case invalidFormat
    }

    private enum Constants {
        static let extM3UMarker: String = "#EXTM3U"
        static let streamInfo: String = "#EXT-X-STREAM-INF:"
        static let bandwidth: String = "BANDWIDTH"
        static let resolution: String = "RESOLUTION"
        static let mediaInitializationByteRange: String = "BYTERANGE"
        static let uri: String = "URI"

        static let mediaDuration: String = "#EXTINF:"
        static let byteRange: String = "#EXT-X-BYTERANGE:"
        static let map: String = "#EXT-X-MAP:"
    }

    static func parseManifest(from data: Data) throws -> ExtM3UManifest {
        guard let string = String(data: data, encoding: .utf8) else {
            throw Error.invalidData
        }

        let lines = string.components(separatedBy: .newlines)

        guard !lines.isEmpty else {
            throw Error.emptyFile
        }

        var shouldSkipLine = false
        var playlists: [ExtM3UPlaylistInfo] = []
        for (index, line) in lines.enumerated() {
            if shouldSkipLine {
                shouldSkipLine = false
                continue
            }

            if index == 0 {
                if !line.hasPrefix(Constants.extM3UMarker) {
                    throw Error.invalidFormat
                }
            }
            else {
                if line.hasPrefix(Constants.streamInfo) {
                    let nextIndex = index + 1
                    guard nextIndex < lines.count else {
                        throw Error.invalidFormat
                    }
                    playlists.append(try parseStreamInfo(from: line, withURLString: lines[nextIndex]))
                    shouldSkipLine = true
                }
            }
        }

        return ExtM3UManifest(playlistInfos: playlists)
    }

    static func parsePlaylist(
        from data: Data,
        for resolution: ExtM3UPlaylistInfo.Resolution,
        bandwidth: Double
    ) throws -> ExtM3UPlaylist {
        guard let string = String(data: data, encoding: .utf8) else {
            throw Error.invalidData
        }

        let lines = string.components(separatedBy: .newlines)

        guard !lines.isEmpty else {
            throw Error.emptyFile
        }

        var segments: [ExtM3UMediaSegment] = []
        var mediaInitializationByteRange: ExtM3UMediaSegmentByteRange.ByteRange?
        var mediaInitializationURI: String?

        var shouldSkipLinesCount = 0
        var currentSegmentStartTime: TimeInterval = 0
        for (index, line) in lines.enumerated() {
            if shouldSkipLinesCount > 0 {
                shouldSkipLinesCount -= 1
                continue
            }

            if index == 0 {
                if !line.hasPrefix(Constants.extM3UMarker) {
                    throw Error.invalidFormat
                }
            }
            else {
                if line.hasPrefix(Constants.map) {
                    let lineComponents = line.replacingOccurrences(
                        of: Constants.map,
                        with: ""
                    ).split(separator: ",")
                    for line in lineComponents {
                        if line.hasPrefix(Constants.uri) {
                            let subComponents = try parseDividedByEqualSign(String(line))
                            mediaInitializationURI = subComponents[1].replacingOccurrences(of: "\"", with: "")
                        }
                        else if line.hasPrefix(Constants.mediaInitializationByteRange) {
                            let subComponents = try parseDividedByEqualSign(String(line))
                            mediaInitializationByteRange = try parseByteRange(subComponents[1])
                        }
                    }
                }
                else if line.hasPrefix(Constants.mediaDuration) {
                    let nextIndex = index + 1
                    guard nextIndex < lines.count else {
                        throw Error.invalidFormat
                    }

                    let durationString = line.replacingOccurrences(
                        of: Constants.mediaDuration, with: ""
                    )
                    guard let duration = TimeInterval(durationString) else {
                        throw Error.invalidFormat
                    }

                    let nextLine = lines[nextIndex]
                    if nextLine.hasPrefix(Constants.byteRange) {
                        let range = try parseByteRange(nextLine.replacingOccurrences(
                            of: Constants.byteRange,
                            with: ""
                        ))

                        let nextNextIndex = index + 2
                        guard nextNextIndex < lines.count else {
                            throw Error.invalidFormat
                        }
                        let uri = lines[nextNextIndex]

                        segments.append(ExtM3UMediaSegmentByteRange(
                            uri: uri,
                            duration: duration,
                            startTime: currentSegmentStartTime,
                            byteRange: range,
                            resolution: resolution
                        ))
                        shouldSkipLinesCount += 2
                        currentSegmentStartTime += duration
                    }
                    else {
                        segments.append(ExtM3UMediaSegmentSimple(
                            uri: nextLine,
                            duration: duration,
                            startTime: currentSegmentStartTime,
                            resolution: resolution
                        ))
                        shouldSkipLinesCount += 1
                        currentSegmentStartTime += duration
                    }
                }
            }
        }

        // The media initialization data at the range is not enough.
        // This is a workaround to use correct range for the media initialization data.
        if let segment = segments.first as? ExtM3UMediaSegmentByteRange,
           mediaInitializationByteRange != nil {
            mediaInitializationByteRange = ExtM3UMediaSegmentByteRange.ByteRange(
                start: mediaInitializationByteRange?.start ?? 0,
                end: segment.byteRange.start - 1
            )
        }

        return ExtM3UPlaylist(
            resolution: resolution,
            bandwidth: bandwidth,
            mediaInitializationByteRange: mediaInitializationByteRange,
            mediaInitializationFileURI: mediaInitializationURI,
            mediaSegments: segments
        )
    }

    // MARK: - Private

    private static func parseStreamInfo(from line: String, withURLString urlString: String) throws -> ExtM3UPlaylistInfo {
        let streamInfo = line.replacingOccurrences(
            of: Constants.streamInfo,
            with: ""
        ).components(
            separatedBy: ","
        )

        var bandwidth: Double = 0
        var resolution: ExtM3UPlaylistInfo.Resolution = .unsupported

        for info in streamInfo {
            let parts = info.split(separator: "=")
            guard parts.count == 2 else {
                throw Error.invalidFormat
            }

            if parts[0] == Constants.bandwidth {
                if let value = Double(String(parts[1]).onlyDigits) {
                    bandwidth = value
                }
                else {
                    throw Error.invalidFormat
                }
            }
            else if parts[0] == Constants.resolution {
                let parts = parts[1].split(separator: "x")
                guard parts.count == 2 else {
                    throw Error.invalidFormat
                }
                switch parts[1] {
                case "1080":
                    resolution = .r1080
                case "720":
                    resolution = .r720
                case "480":
                    resolution = .r480
                case "360":
                    resolution = .r360
                case "240":
                    resolution = .r240
                default:
                    resolution = .unsupported
                }
            }
        }

        return ExtM3UPlaylistInfo(bandwidth: bandwidth, resolution: resolution, urlString: urlString)
    }

    private static func parseByteRange(_ string: String) throws -> ExtM3UMediaSegmentByteRange.ByteRange {
        let lineComponents = string.split(separator: "@")
        guard lineComponents.count == 2,
              let start = Int(String(lineComponents[1]).onlyDigits),
              let length = Int(String(lineComponents[0]).onlyDigits)
        else {
            throw Error.invalidFormat
        }
        return ExtM3UMediaSegmentByteRange.ByteRange(start: start, end: start + length)
    }

    private static func parseDividedByEqualSign(_ string: String) throws -> [String] {
        let lineComponents = string.split(separator: "=")
        guard lineComponents.count == 2 else {
            throw Error.invalidFormat
        }
        return lineComponents.map { String($0) }
    }
}

extension String {
    var onlyDigits: String {
        return self.filter(\.isNumber)
    }
}
