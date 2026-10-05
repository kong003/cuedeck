import AVFoundation
import CoreMedia
import Foundation

enum MediaError: LocalizedError {
    case notPlayable(String)
    case noMedia(String)
    case build(String)

    var errorDescription: String? {
        switch self {
        case let .notPlayable(name): return "\(name) can't be played by macOS directly."
        case let .noMedia(name): return "\(name) has no video or audio tracks."
        case let .build(msg): return msg
        }
    }
}

/// Details about one source audio track needed for decoding.
struct SourceAudioTrack {
    let track: AVAssetTrack
    let channels: Int
    /// The track's AudioChannelLayout, passed back to the decoder so channels
    /// come out in their original order without remixing.
    let layoutData: Data?
}

enum MediaInspector {
    /// Extensions macOS can't decode natively; these go through ffmpeg.
    static let needsConversion: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "vob",
                                               "ts", "m2ts", "mts", "ogv", "ogg", "opus", "flac", "3gp"]

    /// Number of channels an AudioChannelLayout describes.
    static func channelCount(of layout: UnsafePointer<AudioChannelLayout>) -> Int {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return Int(layout.pointee.mNumberChannelDescriptions)
        }
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            return layout.pointee.mChannelBitmap.rawValue.nonzeroBitCount
        }
        return Int(tag & 0xFFFF)
    }

    /// Reader output settings for float PCM at `rate` with the track's channels.
    static func pcmSettings(channels: Int, layout: Data?, rate: Double?) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        if let rate {
            settings[AVSampleRateKey] = rate
            settings[AVNumberOfChannelsKey] = channels
            if let layout {
                settings[AVChannelLayoutKey] = layout
            } else if channels > 2 {
                var discrete = AudioChannelLayout()
                discrete.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
                settings[AVChannelLayoutKey] = Data(bytes: &discrete, count: MemoryLayout<AudioChannelLayout>.size)
            }
        }
        return settings
    }

    static func audioTracks(of asset: AVAsset) async throws -> [SourceAudioTrack] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var result: [SourceAudioTrack] = []
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            var channels = 2
            var layout: Data?
            if let fd = descriptions.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                    channels = Int(asbd.pointee.mChannelsPerFrame)
                }
                var size = 0
                if let ptr = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size), size > 0,
                   channelCount(of: ptr) == channels {
                    // Only keep layouts that agree with the channel count;
                    // AVFoundation rejects mismatching ones.
                    layout = Data(bytes: ptr, count: size)
                }
            }
            channels = max(1, min(channels, 32))
            result.append(SourceAudioTrack(track: track, channels: channels, layoutData: layout))
        }
        return result
    }

    /// Fills in the cue's media information.
    static func inspect(_ cue: inout Cue) async throws {
        guard FileManager.default.fileExists(atPath: cue.url.path) else {
            cue.missing = true
            throw MediaError.noMedia(cue.url.lastPathComponent)
        }
        cue.missing = false
        let asset = AVURLAsset(url: cue.url)
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await audioTracks(of: asset)
        if !playable && videoTracks.isEmpty && audio.isEmpty {
            throw MediaError.notPlayable(cue.url.lastPathComponent)
        }
        if videoTracks.isEmpty && audio.isEmpty {
            throw MediaError.noMedia(cue.url.lastPathComponent)
        }

        cue.duration = duration.seconds.isFinite ? duration.seconds : 0
        cue.hasVideo = !videoTracks.isEmpty
        if let v = videoTracks.first {
            let (size, transform, fps) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let r = CGRect(origin: .zero, size: size).applying(transform)
            cue.videoSize = "\(Int(abs(r.width)))×\(Int(abs(r.height)))"
            cue.frameRate = fps > 0 ? Double(fps) : 0
            if cue.frameRate > 0 { cue.videoSize += String(format: " · %g fps", (cue.frameRate * 100).rounded() / 100) }
        } else {
            cue.videoSize = ""
            cue.frameRate = 0
        }

        let handlerNames = MovieHeader.handlerNames(of: cue.url)
        var infos: [AudioTrackInfo] = []
        for (i, t) in audio.enumerated() {
            var label = "Stream \(i + 1) · \(t.channels) ch"
            if let lang = try? await t.track.load(.languageCode), !lang.isEmpty, lang != "und" {
                label += " · \(lang)"
            }
            var info = AudioTrackInfo(index: i, channels: t.channels, label: label)
            info.fileName = await trackName(t.track, handlerNames: handlerNames)
            infos.append(info)
        }
        cue.audioTracks = infos
    }

    /// The name a track carries in the file, "" if none: the QuickTime track
    /// name (ffmpeg writes it from a stream title), a title tag, or the
    /// handler name many MP4 encoders use for it ("German").
    static func trackName(_ track: AVAssetTrack, handlerNames: [CMPersistentTrackID: String]) async -> String {
        if let items = try? await track.load(.metadata), !items.isEmpty {
            for id in [AVMetadataIdentifier.quickTimeUserDataTrackName, .quickTimeMetadataTitle,
                       .commonIdentifierTitle, .iTunesMetadataSongName] {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                    if let v = try? await item.load(.stringValue) {
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { return t }
                    }
                }
            }
        }
        return handlerNames[track.trackID] ?? ""
    }

    /// Stream names from the file, in audio track order.
    static func trackNames(of url: URL) async -> [String]? {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio) else { return nil }
        let handlerNames = MovieHeader.handlerNames(of: url)
        var names: [String] = []
        for t in tracks { names.append(await trackName(t, handlerNames: handlerNames)) }
        return names
    }
}

/// The playable timeline of a cue: trimmed and looped compositions.
///
/// "Media time" is time in the unscaled timeline: seconds of source material
/// since the cue's start point, all loop passes back to back. The video
/// composition is unscaled (speed is the player's rate, so it can change
/// live); the audio composition is time-stretched to `audioSpeed` so the
/// decoder delivers pitch-corrected audio at that speed.
struct CueTimeline {
    /// Video timeline at speed 1; the AVPlayerItem is created on the main actor.
    let videoAsset: AVComposition?
    let audioAsset: AVComposition?
    let audioTracks: [(track: AVCompositionTrack, channels: Int, layout: Data?)]
    /// Length of the media timeline in seconds (all loop passes, speed 1).
    let mediaDuration: Double
    let audioSpeed: Double
    let repetitions: Int

    /// Loops are built as one long seamless timeline, up to this length.
    static let maxLoopSeconds: Double = 8 * 3600
    static let maxLoopRepetitions = 1000

    static func build(for cue: Cue, audioSpeed: Double, includeVideo: Bool = true) async throws -> CueTimeline {
        let asset = AVURLAsset(url: cue.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let scale: CMTimeScale = 48000

        let start = CMTime(seconds: max(0, cue.inPoint), preferredTimescale: scale)
        var end = duration
        if cue.outPoint > 0 {
            end = CMTimeMinimum(duration, CMTime(seconds: cue.outPoint, preferredTimescale: scale))
        }
        guard CMTimeCompare(end, start) > 0 else {
            throw MediaError.build("The in point of \(cue.name) is after its out point.")
        }
        let segment = CMTimeRange(start: start, end: end)
        let segmentSeconds = segment.duration.seconds

        var reps = 1
        if cue.endAction == .loop {
            let wanted = Int((maxLoopSeconds / max(segmentSeconds, 0.04)).rounded(.up))
            reps = max(1, min(maxLoopRepetitions, wanted))
        }

        // Inserts `segment` of `source` `reps` times back to back.
        func fill(_ ct: AVMutableCompositionTrack, from source: AVAssetTrack) async throws {
            let trackRange = try await source.load(.timeRange)
            let usable = CMTimeRangeGetIntersection(trackRange, otherRange: segment)
            guard usable.duration.seconds > 0 else { return }
            let lead = CMTimeSubtract(usable.start, segment.start)
            var cursor = CMTime.zero
            for _ in 0..<reps {
                try ct.insertTimeRange(usable, of: source, at: CMTimeAdd(cursor, lead))
                cursor = CMTimeAdd(cursor, segment.duration)
            }
        }

        let total = CMTimeMultiply(segment.duration, multiplier: Int32(reps))
        let speed = min(max(audioSpeed, 0.25), 4.0)

        // Video (unscaled)
        var videoAsset: AVComposition?
        if includeVideo, let v = try await asset.loadTracks(withMediaType: .video).first {
            let comp = AVMutableComposition()
            guard let ct = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaError.build("Could not prepare the video of \(cue.name).")
            }
            try await fill(ct, from: v)
            ct.preferredTransform = try await v.load(.preferredTransform)
            videoAsset = comp
        }

        // Audio
        var audioComp: AVMutableComposition?
        var audioTracks: [(track: AVCompositionTrack, channels: Int, layout: Data?)] = []
        let sources = try await MediaInspector.audioTracks(of: asset)
        if !sources.isEmpty {
            let comp = AVMutableComposition()
            for src in sources {
                guard let ct = comp.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try await fill(ct, from: src.track)
                audioTracks.append((ct, src.channels, src.layoutData))
            }
            if speed != 1.0 {
                comp.scaleTimeRange(CMTimeRange(start: .zero, duration: total),
                                    toDuration: CMTimeMultiplyByFloat64(total, multiplier: 1.0 / speed))
            }
            audioComp = comp
        }

        return CueTimeline(videoAsset: videoAsset, audioAsset: audioComp, audioTracks: audioTracks,
                           mediaDuration: total.seconds, audioSpeed: speed, repetitions: reps)
    }
}

/// Minimal MP4/MOV box reader for what AVFoundation doesn't expose: the
/// handler name of each track (moov/trak/mdia/hdlr), keyed by track ID.
/// Generic encoder names ("SoundHandler", "… Media Handler") are skipped.
enum MovieHeader {
    static func handlerNames(of url: URL) -> [CMPersistentTrackID: String] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? file.close() }
        guard let moov = findTopLevelBox("moov", in: file) else { return [:] }
        var result: [CMPersistentTrackID: String] = [:]
        for trak in boxes(in: moov) where trak.type == "trak" {
            var trackID: CMPersistentTrackID?
            var name: String?
            for b in boxes(in: trak.body) {
                if b.type == "tkhd" { trackID = tkhdTrackID(b.body) }
                if b.type == "mdia" {
                    for m in boxes(in: b.body) where m.type == "hdlr" { name = hdlrName(m.body) }
                }
            }
            if let trackID, let name, isMeaningful(name) { result[trackID] = name }
        }
        return result
    }

    private static func isMeaningful(_ name: String) -> Bool {
        let n = name.lowercased()
        let generic = ["soundhandler", "core media audio", "sound handler", "audio handler", "alias data handler"]
        return !n.isEmpty && !n.contains("media handler") && !n.hasSuffix(" handler") && !generic.contains(n)
    }

    private static func readUInt32(_ d: Data, _ at: Int) -> UInt32? {
        guard at + 4 <= d.count else { return nil }
        return d[d.startIndex + at ..< d.startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ d: Data, _ at: Int) -> UInt64? {
        guard at + 8 <= d.count else { return nil }
        return d[d.startIndex + at ..< d.startIndex + at + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Reads the top-level boxes' headers until `type` is found, returns its body.
    private static func findTopLevelBox(_ type: String, in file: FileHandle) -> Data? {
        guard let end = try? file.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        while offset + 8 <= end {
            try? file.seek(toOffset: offset)
            guard let head = try? file.read(upToCount: 16), head.count >= 8,
                  let size32 = readUInt32(head, 0) else { return nil }
            let boxType = String(decoding: head[head.startIndex + 4 ..< head.startIndex + 8], as: UTF8.self)
            var size = UInt64(size32), headerSize: UInt64 = 8
            if size32 == 1 {
                guard let large = readUInt64(head, 8) else { return nil }
                size = large; headerSize = 16
            } else if size32 == 0 {
                size = end - offset
            }
            guard size >= headerSize else { return nil }
            if boxType == type {
                // The movie header is small; refuse anything absurd.
                guard size - headerSize < 256 << 20 else { return nil }
                try? file.seek(toOffset: offset + headerSize)
                return try? file.read(upToCount: Int(size - headerSize))
            }
            offset += size
        }
        return nil
    }

    private static func boxes(in data: Data) -> [(type: String, body: Data)] {
        var result: [(String, Data)] = []
        var at = 0
        while at + 8 <= data.count, let size32 = readUInt32(data, at) {
            let type = String(decoding: data[data.startIndex + at + 4 ..< data.startIndex + at + 8], as: UTF8.self)
            var size = Int(size32), header = 8
            if size32 == 1 {
                guard let large = readUInt64(data, at + 8), large <= UInt64(Int.max) else { break }
                size = Int(large); header = 16
            } else if size32 == 0 {
                size = data.count - at
            }
            guard size >= header, at + size <= data.count else { break }
            result.append((type, data[data.startIndex + at + header ..< data.startIndex + at + size]))
            at += size
        }
        return result
    }

    private static func tkhdTrackID(_ body: Data) -> CMPersistentTrackID? {
        guard let first = body.first else { return nil }
        let at = first == 1 ? 4 + 16 : 4 + 8   // version 1 has 64-bit times
        return readUInt32(body, at).map { CMPersistentTrackID(bitPattern: $0) }
    }

    /// hdlr: version/flags, pre_defined, handler type, 12 reserved bytes, name.
    private static func hdlrName(_ body: Data) -> String? {
        guard body.count > 24 else { return nil }
        var bytes = [UInt8](body[body.startIndex + 24 ..< body.endIndex])
        // QuickTime files store a length-prefixed (Pascal) string, MP4 a C string.
        // A name never starts with a control character, so such a byte is a length.
        if let len = bytes.first, len > 0, len < 0x20, Int(len) < bytes.count {
            bytes = Array(bytes[1...Int(len)])
        }
        if let zero = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<zero]) }
        let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
