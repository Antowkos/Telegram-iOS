//
//  HLSPlayer.swift
//  TelegramUniversalVideoContent
//
//  Created by Anton Kovalev on 09.10.2024.
//

import Foundation
import Network
import AVFoundation

final class HLSPlayer {

    private(set) var currentTime: CMTime = .zero

    private(set) var playbackState: PlaybackState = .idle {
        didSet {
            let isPlaying = playbackState == .playing ||
                            playbackState == .waitingForBuffer
            isPlayingStatusHandler?(isPlaying)
        }
    }
    var volume: Float {
        get {
            audioPlayer.playerNode.volume
        }
        set {
            audioPlayer.playerNode.volume = newValue
        }
    }

    var rate: Float = 1 {
        didSet {
            audioPlayer.rate = rate
            assetReader.rate = rate
        }
    }

    var prefferedQuality: Quality = .auto
    var currentQuality: Quality {
        guard let currentSegment else {
            return .auto
        }
        return Quality(resolution: currentSegment.resolution)
    }
    var availableQualities: [Quality] {
        guard playlists.count > 0 else {
            return [.auto]
        }

        var qualities: [Quality] = []
        for playlist in playlists {
            qualities.append(Quality(resolution: playlist.resolution))
        }
        return qualities
    }

    var isPlayingStatusHandler: ((Bool) -> Void)?
    var isBufferingStatusHandler: ((Bool) -> Void)?
    var timeUpdatedHandler: ((TimeInterval) -> Void)?
    var playingCompletedHandler: (() -> Void)?

    private lazy var bandwidthMonitor = BandwidthMonitor { [weak self] bandwidth in
        self?.bandwidthUpdated(bandwidth)
    }
    private var bandwidth: Double = 0

    private let playerDispatchQueue = DispatchQueue(
        label: "com.telegram.universal.video.content.hls.player",
        qos: .background
    )
    private let playlistsDispatchGroup = DispatchGroup()
    private let playlistsDispatchLock = NSRecursiveLock()

    private let urlSession = URLSession(configuration: .default)
    private var urlSessionDataTasks: [URLSessionDataTask] = []
    private var urlSessionDownloadTasks: [URLSessionDownloadTask] = []

    private var baseURL: URL?
    private var currentItemName: String = ""

    private var playlists: [ExtM3UPlaylist] = []

    private lazy var assetReader = HLSAssetReader { [weak self] time in
        self?.timeUpdated(time)
    }
    private var videoOutputs: [HLSVideoOutput] = []
    private var buffer = HLSBuffer()
    private var isBuffering: Bool = false

    private var playedTime: CMTime = .zero

    private var shouldStartReadingAssetAtTime: TimeInterval?
    private var shouldStartPlayingAudioAtTime: TimeInterval?
    private var needToPeformAudioPreparationsAfterNewBuffering: Bool = false

    private var shouldSeekAfterMetaDataLoaded: Bool = false
    private var shouldResumePlayingAfterInterruption: Bool = false

    private var currentSegment: ExtM3UMediaSegment?

    private var isFullyBuffered: Bool {
        if let playlist = try? findBestPlaylist(forBandwidth: bandwidth),
           buffer.bufferItemsCount == playlist.mediaSegments.count {
            return true
        }
        return false
    }

    private lazy var audioPlayer = HLSAudioPlayer()

    // MARK: - Life cycle

    init() {
        subscribeToAudioSessionNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        urlSessionDataTasks.forEach { $0.cancel() }
        urlSessionDownloadTasks.forEach { $0.cancel() }
        do {
            try FileManager.default.removeItem(at: try currentItemFolderURL())
        }
        catch {
            print("HLSPLAYER: Failed to remove folder \(currentItemName)")
            print("HLSPLAYER: \(error)")
        }
    }

    // MARK: - Public

    func prepareToPlay(videoAt url: ExtM3UURL) {
        buffer.initiallyBecomeReadyToPlayHandler = { [weak self] in
            if self?.playbackState == .playing {
                self?.performAudioPreparations()
                self?.startActualPlayingIfNeededAndPossible()
            }
        }

        buffer.bufferizedTimeIncreasedHandler = { [weak self] in
            if self?.playbackState == .waitingForBuffer,
               self?.buffer.isReadyToPlay == true {
                self?.playbackState = .playing
                self?.performAudioPreparations()
                self?.startActualPlayingIfNeededAndPossible()
            }
        }

        currentItemName = url.value.lastPathComponent + UUID().uuidString
        downloadManifest(from: url) { [weak self] manifest in
            self?.handle(manifest) { manifest in
                guard let self else {
                    return
                }
                if self.shouldSeekAfterMetaDataLoaded {
                    self.seek(to: self.currentTime)
                    self.shouldSeekAfterMetaDataLoaded = false
                }
                else {
                    self.startFillingBufferIfNeeded()
                }
            }
        }
        isBufferingStatusHandler?(true)
    }

    func add(_ videoOutput: HLSVideoOutput) {
        videoOutputs.append(videoOutput)
        videoOutput.assetReadear = assetReader
        assetReader.aboutToEndHandler = { [weak self] in
            print("HLSPLAYER: did informed about to end asset reading")
            self?.performAudioPreparations()
        }
    }

    func play() {
        playbackState = .playing
        audioPlayer.play()
        assetReader.resume()
        if playbackState == .idle {
            performAudioPreparations()
            startActualPlayingIfNeededAndPossible()
        }
    }

    func pause() {
        playbackState = .paused
        audioPlayer.pause()
        assetReader.pause()
    }

    func seek(to time: CMTime) {
        let seconds = TimeInterval(time.seconds)

        print("HLSPLAYER: --------------------------------------")
        print("HLSPLAYER: Should seek to \(seconds)")
        playedTime = .zero
        timeUpdated(time)
        if let playlist = try? findBestPlaylist(forBandwidth: bandwidth) {
            assetReader.stop()
            audioPlayer.stop()
            urlSessionDownloadTasks.forEach({ $0.cancel() })
            buffer.flush()
            isBuffering = false
            needToPeformAudioPreparationsAfterNewBuffering = false

            var possibleSegment = playlist.mediaSegments[0]
            var secondsDiff: Double = .greatestFiniteMagnitude

            for segment in playlist.mediaSegments {
                let diff = segment.startTime + segment.duration - seconds
                if segment.startTime < seconds,
                   diff > 0 {
                    if diff < secondsDiff {
                        possibleSegment = segment
                        secondsDiff = diff
                    }
                }
            }

            print("HLSPLAYER: Found segment with start time \(possibleSegment.startTime)")

            currentTime = CMTime(
                value: CMTimeValue(currentTime.timescale * CMTimeScale(seconds)),
                timescale: currentTime.timescale
            )

            shouldStartReadingAssetAtTime = seconds - possibleSegment.startTime
            shouldStartPlayingAudioAtTime = seconds - possibleSegment.startTime

            buffer.updateBufferizedTillTime(possibleSegment.startTime)
            playbackState = .waitingForBuffer
            isBufferingStatusHandler?(true)
            startFillingBufferIfNeeded()
        }
        else {
            shouldSeekAfterMetaDataLoaded = true
        }
    }

    // MARK: - AudioSession

    private func subscribeToAudioSessionNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            if playbackState == .playing {
                pause()
                shouldResumePlayingAfterInterruption = true
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume),
               shouldResumePlayingAfterInterruption {
                play()
                shouldResumePlayingAfterInterruption = false
            }
        default:
            break
        }
    }

    // MARK: - Playback

    private func timeUpdated(_ time: CMTime) {
        print("HLSPLAYER: Time updated: \(time.seconds)")
        if time == .zero {
            playedTime = currentTime
        }
        currentTime = playedTime + time
        startFillingBufferIfNeeded()
        timeUpdatedHandler?(currentTime.seconds)
    }

    // MARK: - Media handling

    private func performAudioPreparations() {
        guard let bufferItem = buffer.nextBufferItemForAudioPreparations() else {
            print("HLSPLAYER: Failed to perform audio preparations for next segment")
            needToPeformAudioPreparationsAfterNewBuffering = true
            return
        }
        print("HLSPLAYER: Perform audio preparations for segment at \(bufferItem.segment.startTime)")
        audioPlayer.schedule(bufferItem.audioBuffers)
    }

    private func startActualPlayingIfNeededAndPossible() {
        guard playbackState == .playing,
              buffer.isReadyToPlay else {
            return
        }
        startReadingNextBufferItem()
        audioPlayer.play()
    }

    private func startReadingNextBufferItem() {
        print("HLSPLAYER: Should start reading next buffer")
        guard let bufferItem = buffer.nextBufferItem() else {
            if isFullyBuffered {
                playingCompletedHandler?()
            }
            else {
                isBufferingStatusHandler?(true)
                playbackState = .waitingForBuffer
            }
            return
        }
        isBufferingStatusHandler?(false)
        print("HLSPLAYER: Start reading next buffer at time \(bufferItem.segment.startTime)")
        startReadingFile(from: bufferItem, atTime: bufferItem.segment.startTime)
    }

    private func bandwidthUpdated(_ bandwidth: Double) {
        self.bandwidth = bandwidth
        print("HLSPLAYER: BANDWIDTH UPDATED")
        print(bandwidth)
    }

    private func startReadingFile(from bufferItem: HLSBufferItem, atTime time: TimeInterval) {
        do {
            currentSegment = bufferItem.segment
            try assetReader.prepareForReading(from: bufferItem.fileURL, at: shouldStartReadingAssetAtTime)
            shouldStartReadingAssetAtTime = nil
            assetReader.startReading { [weak self] in
                if bufferItem.isLast {
                    self?.playingCompletedHandler?()
                    self?.seek(to: .zero)
                    self?.isBufferingStatusHandler?(false)
                    self?.playbackState = .idle
                }
                else {
                    self?.startReadingNextBufferItem()
                }
            }
            playbackState = .playing
        }
        catch {
            print("HLSPLAYER: \(error)")
        }
    }

    // MARK: - Data

    private func startFillingBufferIfNeeded() {
        guard !isBuffering else {
            return
        }

        isBuffering = true
        fillInBufferIfNeeded()
    }

    private func fillInBufferIfNeeded() {
        if buffer.shouldBeFilled {
            print("HLSPLAYER: Buffer might be filled")
            downloadVideoPart(atTime: buffer.bufferizedTillTime)
        }
        else {
            isBuffering = false
        }
    }

    private func downloadVideoPart(atTime time: TimeInterval) {
        do {
            let playlist = try findBestPlaylist(forBandwidth: bandwidth)
            let bandwidth = playlist.bandwidth
            print("HLSPLAYER: Will try to download video part for segment at time \(time)")
            if let segment = playlist.mediaSegments.first(where: { $0.startTime == time }) {
                downloadVideoPart(for: segment, from: playlist) { [weak self] url, audioBuffers in
                    self?.buffer.register(
                        segment: segment,
                        bandwidth: bandwidth,
                        fileURL: url,
                        audioBuffers: audioBuffers,
                        isLast: segment.startTime == playlist.mediaSegments.last?.startTime
                    )
                    if self?.needToPeformAudioPreparationsAfterNewBuffering == true {
                        self?.needToPeformAudioPreparationsAfterNewBuffering = false
                        self?.performAudioPreparations()
                    }
                    print("HLSPLAYER: Register segment in buffer")
                    self?.fillInBufferIfNeeded()
                }
            }
            else {
                print("HLSPLAYER: No segment found for time \(time)")
            }
        }
        catch {
            print("HLSPLAYER: \(error)")
        }
    }

    private func downloadMediaInitializationSegmentIfNeeded(
        for playlist: ExtM3UPlaylist,
        completion: @escaping () -> Void
    ) {
        do {
            if let uri = playlist.mediaInitializationFileURI,
               try !fileExists(name: Constants.mediaInitializationDataFileName, for: playlist) {
                let url = try urlForResource(withURLString: uri)
                let range = playlist.mediaInitializationByteRange
                performDownloadTask(with: url, byteRange: range) { [weak self] location, _, _ in
                    do {
                        guard let location else {
                            return
                        }

                        try self?.copyFile(
                            as: Constants.mediaInitializationDataFileName,
                            from: location,
                            toFolderFor: playlist
                        )
                        print("HLSPLAYER: Downloaded media initialization segment for \(playlist.bandwidth)")
                        completion()
                    }
                    catch {
                        print("HLSPLAYER: MIS \(error)")
                    }
                }
            }
            else {
                completion()
            }
        }
        catch {
            print("HLSPLAYER: MIS \(error)")
        }
    }

    private func downloadVideoPart(
        for segment: ExtM3UMediaSegment,
        from playlist: ExtM3UPlaylist,
        completion: @escaping (URL, [AVAudioPCMBuffer]) -> Void
    ) {
        downloadMediaInitializationSegmentIfNeeded(for: playlist) { [weak self] in
            do {
                guard let self else {
                    return
                }

                let fileName = "\(segment.id).mp4"
                let mediaFileURL = try playlistFolderURL(playlist).appendingPathComponent(fileName)

                let segmentIndex = playlist.mediaSegments.firstIndex(where: { $0.id == segment.id }) ?? -1

                if try fileExists(name: fileName, for: playlist) {
                    print("HLSPLAYER: Found cached video file for segment at index \(segmentIndex). Total segments count: \(playlist.mediaSegments.count)")
                    let audioBuffers = self.audioBuffers(forFileAtURL: mediaFileURL)
                    DispatchQueue.main.async {
                        completion(mediaFileURL, audioBuffers)
                    }
                }
                else {
                    let url = try urlForResource(withURLString: segment.uri)
                    var byteRange: ExtM3UMediaSegmentByteRange.ByteRange?
                    if let segment = segment as? ExtM3UMediaSegmentByteRange {
                        byteRange = segment.byteRange
                    }

                    // For some reason last parts of the playlist are not downloaded properly
                    // with stricted range error from the server. So this is a workaround which
                    // decreases bytes length for them.
                    if segment.id == playlist.mediaSegments[playlist.mediaSegments.count - 2].id ||
                        segment.id == playlist.mediaSegments[playlist.mediaSegments.count - 1].id,
                       let originalByteRange = byteRange {
                        byteRange = ExtM3UMediaSegmentByteRange.ByteRange(
                            start: originalByteRange.start,
                            end: originalByteRange.end - 1
                        )
                    }

                    performDownloadTask(with: url, byteRange: byteRange) { [weak self] location, _, error in
                        do {
                            guard let self,
                                  let location else {
                                if let error {
                                    print("HLSPLAYER: Error downloading video part: \(error)")
                                }
                                return
                            }
                            let mediaInitializationFileURL = try mediaInitializationFileURL(of: playlist)
                            let mediaInitializationFileData = try Data(contentsOf: mediaInitializationFileURL)
                            let mediaFileData = try Data(contentsOf: location)
                            try writeFile(
                                named: fileName,
                                contents: mediaInitializationFileData + mediaFileData,
                                toFolderFor: playlist
                            )

                            let audioBuffers = self.audioBuffers(forFileAtURL: mediaFileURL)
                            print("HLSPLAYER: Downloaded video file for segment at index \(segmentIndex). Total segments count: \(playlist.mediaSegments.count)")
                            DispatchQueue.main.async {
                                completion(mediaFileURL, audioBuffers)
                            }
                        }
                        catch {
                            print("HLSPLAYER: \(error)")
                        }
                    }
                }
            }
            catch {
                print("HLSPLAYER: \(error)")
            }
        }
    }

    private func audioBuffers(forFileAtURL url: URL) -> [AVAudioPCMBuffer] {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let audioFormat = audioFile.processingFormat

            var buffers: [AVAudioPCMBuffer] = []
            let maxBufferDuration: UInt32 = 50 * 1024
            let audioFileLength = AVAudioFrameCount(audioFile.length)
            var spentLength: AVAudioFrameCount = AVAudioFrameCount(audioFile.length)

            if let shouldStartPlayingAudioAtTime {
                spentLength -= min(
                    audioFileLength,
                    AVAudioFrameCount(shouldStartPlayingAudioAtTime * audioFormat.sampleRate)
                )
                self.shouldStartPlayingAudioAtTime = nil
            }

            while spentLength > 0 {
                let frameCapacity = min(maxBufferDuration, spentLength)
                guard let audioFileBuffer = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: frameCapacity
                ) else {
                    break
                }
                audioFile.framePosition = AVAudioFramePosition(audioFileLength - spentLength)
                try audioFile.read(into: audioFileBuffer, frameCount: frameCapacity)
                buffers.append(audioFileBuffer)

                spentLength -= frameCapacity
            }
            return buffers
        }
        catch {
            print("HLSPLAYER: \(error)")
            return []
        }
    }

    // MARK: Playlists

    private func downloadManifest(from url: ExtM3UURL, completion: ((ExtM3UManifest) -> Void)?) {
        baseURL = url.value.deletingLastPathComponent()
        performDataTask(with: url.value) { data, response, error in
            guard let data else {
                return
            }
            print(String(decoding: data, as: UTF8.self))
            do {
                let manifest = try ExtM3UParser.parseManifest(from: data)
                completion?(manifest)
            }
            catch {
                print("HLSPLAYER: \(error)")
            }
        }
    }

    private func handle(_ manifest: ExtM3UManifest, completion: @escaping (ExtM3UManifest) -> Void) {
        for info in manifest.playlistInfos {
            do {
                playlistsDispatchGroup.enter()
                try downloadPlaylist(with: info)
            }
            catch {
                print("HLSPLAYER: \(error)")
            }
        }
        playlistsDispatchGroup.notify(queue: .main) {
            completion(manifest)
        }
    }

    private func downloadPlaylist(with info: ExtM3UPlaylistInfo) throws {
        let url = try urlForResource(withURLString: info.urlString)
        performDataTask(with: url) { [weak self] data, response, error in
            defer {
                self?.playlistsDispatchGroup.leave()
            }

            guard let data else {
                return
            }
            do {
                let playlist = try ExtM3UParser.parsePlaylist(
                    from: data,
                    for: info.resolution,
                    bandwidth: info.bandwidth
                )
                self?.playlistsDispatchLock.lock()
                self?.playlists.append(playlist)
                self?.playlistsDispatchLock.unlock()
            }
            catch {
                print("HLSPLAYER: \(error)")
            }
        }
    }

    private func findBestPlaylist(forBandwidth bandwidth: Double) throws -> ExtM3UPlaylist {
        guard playlists.count > 0 else {
            throw Error.noPlaylists
        }

        guard playlists.count > 1 else {
            return playlists[0]
        }

        guard prefferedQuality == .auto else {
            let playlist = playlists.first {
                $0.resolution == prefferedQuality.resolution
            }
            return playlist ?? playlists[0]
        }

        var bandwidthsDiff = Double.greatestFiniteMagnitude
        let playlists = self.playlists.sorted { p1, p2 in
            p1.bandwidth > p2.bandwidth
        }
        var possiblePlaylist = playlists[0]
        for playlist in playlists {
            let diff = bandwidth - playlist.bandwidth
            if diff > 0 {
                if diff < bandwidthsDiff {
                    possiblePlaylist = playlist
                    bandwidthsDiff = diff
                }
            }
        }
        return possiblePlaylist
    }

    // MARK: Files + URLs

    private func urlForResource(withURLString urlString: String) throws -> URL {
        guard let url = URL(string: urlString),
              url.scheme != nil else {
            if let baseURL {
                return baseURL.appendingPathComponent(urlString)
            }
            throw Error.invalidURL
        }
        return url
    }

    private func fileExists(name: String, for playlist: ExtM3UPlaylist) throws -> Bool {
        let folderURL = try playlistFolderURL(playlist)
        return FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(name).path
        )
    }

    private func copyFile(as name: String, from source: URL, toFolderFor playlist: ExtM3UPlaylist) throws {
        let destination = try playlistFolderURL(playlist).appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func writeFile(named name: String, contents: Data, toFolderFor playlist: ExtM3UPlaylist) throws {
        let destination = try playlistFolderURL(playlist).appendingPathComponent(name)
        try contents.write(to: destination)
    }

    private func fileURL(named name: String, of playlist: ExtM3UPlaylist) throws -> URL {
        let folderURL = try playlistFolderURL(playlist)
        return folderURL.appendingPathComponent(name)
    }

    private func mediaInitializationFileURL(of playlist: ExtM3UPlaylist) throws -> URL {
        let folderURL = try playlistFolderURL(playlist)
        return folderURL.appendingPathComponent(Constants.mediaInitializationDataFileName)
    }

    private func playlistFolderURL(_ playlist: ExtM3UPlaylist) throws -> URL {
        let basePath = try currentItemFolderURL()
        let path = basePath.appendingPathComponent("\(Int(playlist.bandwidth))")
        var isDirectory: ObjCBool = true
        if !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        return path
    }

    private func currentItemFolderURL() throws -> URL {
        let basePath = try basePathURL()
        let path = basePath.appendingPathComponent(currentItemName)
        var isDirectory: ObjCBool = true
        if !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        return path
    }

    private func basePathURL() throws -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let basePath = documentsDirectory.appendingPathComponent(Constants.baseFolderName)
        var isDirectory: ObjCBool = true
        if !FileManager.default.fileExists(atPath: basePath.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
        }
        return basePath
    }

    // MARK: - Network

    private func performDataTask(with url: URL, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Swift.Error)?) -> Void) {
        var measurement = BandwidthMeasurement()
        playerDispatchQueue.async { [weak self] in
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                measurement.finishTime = Date()
                measurement.bytes = data?.count ?? 0
                self?.bandwidthMonitor.update(with: measurement)
                completionHandler(data, response, error)
            }
            task.resume()
            self?.urlSessionDataTasks.append(task)
        }
    }

    private func performDownloadTask(
        with url: URL,
        byteRange: ExtM3UMediaSegmentByteRange.ByteRange?,
        completionHandler: @escaping @Sendable (URL?, URLResponse?, (any Swift.Error)?) -> Void)
    {
        var measurement = BandwidthMeasurement()
        var request = URLRequest(url: url)
        if let byteRange {
            request.setValue("bytes=\(byteRange.start)-\(byteRange.end)", forHTTPHeaderField: "Range")
        }
        print("HLSPLAYER: Downloading file from \(url.absoluteString). Range: \(byteRange?.start ?? -1)-\(byteRange?.end ?? -1)")
        playerDispatchQueue.async { [weak self] in
            let task = URLSession.shared.downloadTask(with: request) { location, response, error in
                measurement.finishTime = Date()
                measurement.bytes = Int(response?.expectedContentLength ?? 0)
                self?.bandwidthMonitor.update(with: measurement)
                completionHandler(location, response, error)
            }
            task.resume()
            self?.urlSessionDownloadTasks.append(task)
        }
    }
}

extension HLSPlayer {

    enum Quality: Int, CaseIterable {
        case auto = 0
        case q240 = 240
        case q360 = 360
        case q480 = 480
        case q720 = 720
        case q1080 = 1080

        init(resolution: ExtM3UPlaylistInfo.Resolution) {
            switch resolution {
            case .unsupported:
                self = .auto
            case .r240:
                self = .q240
            case .r360:
                self = .q360
            case .r480:
                self = .q480
            case .r720:
                self = .q720
            case .r1080:
                self = .q1080
            }
        }

        var resolution: ExtM3UPlaylistInfo.Resolution {
            switch self {
            case .q240:
                return .r240
            case .q360:
                return .r360
            case .q480:
                return .r480
            case .q720:
                return .r720
            case .q1080:
                return .r1080
            default:
                return .unsupported
            }
        }
    }

    enum PlaybackState {
        case idle
        case playing
        case paused
        case waitingForBuffer
    }

    enum Error: Swift.Error {
        case invalidURL
        case noPlaylists
    }

    private enum Constants {
        static let baseFolderName = "HLSPlayer"
        static let mediaInitializationDataFileName = "data.mis"
    }
}
