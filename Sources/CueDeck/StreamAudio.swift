import AVFoundation
import CMixer
import Foundation

// Audio of HLS (CMAF) streams, decoded by CueDeck itself so every language
// can go to its own outputs through the mixer, exactly like file audio.
//
// One StreamAudioTrack per language: it loads the media playlist, downloads
// the fragmented-MP4 segments a little ahead, takes the AAC packets out of
// them, decodes them continuously (no gaps at segment borders), converts to
// the device rate and writes interleaved Float32 into a PCMSink (a track of a
// mixer voice), starting exactly at the requested position.

// MARK: - Media playlist

struct HLSMediaPlaylist {
    struct Segment {
        var url: URL
        var start: Double       // seconds, sum of the EXTINF durations before it
        var duration: Double
        var sequence: Int       // media sequence number
    }
    var initURL: URL?
    var segments: [Segment] = []
    var isLive = true           // until #EXT-X-ENDLIST
    var duration: Double { segments.last.map { $0.start + $0.duration } ?? 0 }

    /// `cached: false` for live playlists, which change all the time.
    static func load(_ url: URL, cached: Bool = true) async throws -> HLSMediaPlaylist {
        let data = try await StreamAudioTrack.fetch(url, cached: cached)
        return parse(String(decoding: data, as: UTF8.self), base: url)
    }

    static func parse(_ text: String, base: URL) -> HLSMediaPlaylist {
        var p = HLSMediaPlaylist()
        var nextDuration: Double?
        var t = 0.0
        var sequence = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                p.isLive = false
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = HLSMaster.attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = a["URI"] { p.initURL = URL(string: uri, relativeTo: base)?.absoluteURL }
            } else if line.hasPrefix("#EXTINF:") {
                nextDuration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "")
            } else if !line.isEmpty && !line.hasPrefix("#"), let d = nextDuration,
                      let url = URL(string: line, relativeTo: base)?.absoluteURL {
                p.segments.append(Segment(url: url, start: t, duration: d, sequence: sequence))
                t += d
                sequence += 1
                nextDuration = nil
            }
        }
        return p
    }

    /// Index of the segment that contains `time`.
    func segmentIndex(at time: Double) -> Int {
        var i = 0
        while i + 1 < segments.count && segments[i + 1].start <= time { i += 1 }
        return i
    }
}

// MARK: - Fragmented MP4 (just what AAC audio needs)

enum FMP4 {
    struct InitInfo {
        var timescale: UInt32
        var sampleRate: Double
        var channels: Int
        var magicCookie: Data           // ES descriptor from esds, for the AAC decoder
        var defaultDuration: UInt32     // from trex
        var defaultSize: UInt32
    }

    struct Fragment {
        var baseTime: UInt64            // tfdt, in timescale units
        var packets: [Data]
        var durations: [UInt32]
    }

    struct ParseError: Error {}

    private static func u32(_ d: Data, _ at: Int) -> UInt32? {
        guard at >= 0, at + 4 <= d.count else { return nil }
        let i = d.startIndex + at
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    private static func u64(_ d: Data, _ at: Int) -> UInt64? {
        guard let hi = u32(d, at), let lo = u32(d, at + 4) else { return nil }
        return UInt64(hi) << 32 | UInt64(lo)
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16? {
        guard at >= 0, at + 2 <= d.count else { return nil }
        let i = d.startIndex + at
        return UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }

    /// Child boxes in `range` of `d`: (type, start of box, start of payload, end).
    private static func boxes(_ d: Data, _ range: Range<Int>) -> [(type: String, start: Int, body: Int, end: Int)] {
        var result: [(String, Int, Int, Int)] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound, let size32 = u32(d, at) {
            let typeBytes = d[(d.startIndex + at + 4)..<(d.startIndex + at + 8)]
            let type = String(decoding: typeBytes, as: UTF8.self)
            var size = Int(size32), header = 8
            if size32 == 1, let large = u64(d, at + 8) { size = Int(large); header = 16 }
            if size32 == 0 { size = range.upperBound - at }
            guard size >= header, at + size <= range.upperBound else { break }
            result.append((type, at, at + header, at + size))
            at += size
        }
        return result
    }

    private static func child(_ d: Data, _ range: Range<Int>, _ path: [String]) -> (start: Int, body: Int, end: Int)? {
        var r = range
        var found: (Int, Int, Int)?
        for (n, name) in path.enumerated() {
            guard let b = boxes(d, r).first(where: { $0.type == name }) else { return nil }
            found = (b.start, b.body, b.end)
            r = b.body..<b.end
            if name == "stsd" && n < path.count - 1 { r = (b.body + 8)..<b.end }      // version/flags + entry count
            if name == "mp4a" && n < path.count - 1 { r = (b.body + 28)..<b.end }     // audio sample entry fields
        }
        return found
    }

    static func parseInit(_ d: Data) throws -> InitInfo {
        let all = 0..<d.count
        guard let mdhd = child(d, all, ["moov", "trak", "mdia", "mdhd"]),
              let mp4a = child(d, all, ["moov", "trak", "mdia", "minf", "stbl", "stsd", "mp4a"]),
              let esds = child(d, all, ["moov", "trak", "mdia", "minf", "stbl", "stsd", "mp4a", "esds"])
        else { throw ParseError() }
        let version = d[d.startIndex + mdhd.body]
        let timescale = u32(d, mdhd.body + (version == 1 ? 20 : 12)) ?? 48000
        let channels = Int(u16(d, mp4a.body + 16) ?? 2)
        let rate = Double((u32(d, mp4a.body + 24) ?? (48000 << 16)) >> 16)
        let cookie = d[(d.startIndex + esds.body + 4)..<(d.startIndex + esds.end)]   // after version/flags
        var defDuration: UInt32 = 1024, defSize: UInt32 = 0
        if let trex = child(d, all, ["moov", "mvex", "trex"]) {
            defDuration = u32(d, trex.body + 12) ?? 1024
            defSize = u32(d, trex.body + 16) ?? 0
        }
        return InitInfo(timescale: timescale, sampleRate: rate > 0 ? rate : Double(timescale),
                        channels: max(1, channels), magicCookie: Data(cookie),
                        defaultDuration: defDuration, defaultSize: defSize)
    }

    /// AAC packets of one media segment (all moof/mdat pairs in it).
    static func parseSegment(_ d: Data, _ info: InitInfo) throws -> Fragment {
        var packets: [Data] = [], durations: [UInt32] = []
        var base: UInt64?
        let top = boxes(d, 0..<d.count)
        for (i, moof) in top.enumerated() where moof.type == "moof" {
            let mdat = top[(i + 1)...].first { $0.type == "mdat" }
            for traf in boxes(d, moof.body..<moof.end) where traf.type == "traf" {
                let kids = boxes(d, traf.body..<traf.end)
                var dataBase = moof.start
                var defDuration = info.defaultDuration, defSize = info.defaultSize
                if let tfhd = kids.first(where: { $0.type == "tfhd" }), let flags = u32(d, tfhd.body) {
                    var at = tfhd.body + 8                                       // flags + track id
                    if flags & 0x01 != 0 { dataBase = Int(u64(d, at) ?? 0); at += 8 }
                    if flags & 0x02 != 0 { at += 4 }
                    if flags & 0x08 != 0 { defDuration = u32(d, at) ?? defDuration; at += 4 }
                    if flags & 0x10 != 0 { defSize = u32(d, at) ?? defSize; at += 4 }
                }
                if let tfdt = kids.first(where: { $0.type == "tfdt" }), base == nil {
                    let v = d[d.startIndex + tfdt.body]
                    base = v == 1 ? u64(d, tfdt.body + 4) : u32(d, tfdt.body + 4).map(UInt64.init)
                }
                for trun in kids where trun.type == "trun" {
                    guard let flags = u32(d, trun.body), let count = u32(d, trun.body + 4) else { continue }
                    var at = trun.body + 8
                    var offset = (mdat?.body ?? 0)
                    if flags & 0x01 != 0 { offset = dataBase + Int(Int32(bitPattern: u32(d, at) ?? 0)); at += 4 }
                    if flags & 0x04 != 0 { at += 4 }
                    for _ in 0..<count {
                        var dur = defDuration, size = defSize
                        if flags & 0x100 != 0 { dur = u32(d, at) ?? dur; at += 4 }
                        if flags & 0x200 != 0 { size = u32(d, at) ?? size; at += 4 }
                        if flags & 0x400 != 0 { at += 4 }
                        if flags & 0x800 != 0 { at += 4 }
                        guard size > 0, offset + Int(size) <= d.count else { throw ParseError() }
                        packets.append(d[(d.startIndex + offset)..<(d.startIndex + offset + Int(size))])
                        durations.append(dur)
                        offset += Int(size)
                    }
                }
            }
        }
        guard !packets.isEmpty else { throw ParseError() }
        return Fragment(baseTime: base ?? 0, packets: packets, durations: durations)
    }
}

// MARK: - Output

/// Where decoded audio goes: one track of a mixer voice (or a test).
protocol PCMSink: AnyObject {
    /// Frames that fit right now.
    func space() -> Int
    /// Writes interleaved Float32 frames; returns how many were taken.
    func write(_ samples: UnsafePointer<Float>, frames: Int) -> Int
    func finish()
}

final class MixerTrackSink: PCMSink {
    let mixer: OpaquePointer
    let voice: Int32
    let track: UInt32
    init(mixer: OpaquePointer, voice: Int32, track: UInt32) {
        self.mixer = mixer; self.voice = voice; self.track = track
    }
    func space() -> Int { Int(cm_voice_write_space(mixer, voice, track)) }
    func write(_ samples: UnsafePointer<Float>, frames: Int) -> Int {
        Int(cm_voice_write(mixer, voice, track, samples, UInt32(frames)))
    }
    func finish() { cm_voice_set_eof(mixer, voice, track) }
}

// MARK: - All languages of a cue

/// Feeds a mixer voice from HLS audio renditions, one per voice track.
final class StreamAudioDecoder: VoiceFeeder, @unchecked Sendable {
    private let tracks: [StreamAudioTrack]
    private let mixer: OpaquePointer
    private let voice: Int32
    private let group = DispatchGroup()
    private var started = false

    /// `playlists[t]` feeds track t from file time `start` to `end`, or for a
    /// livestream from `live` on (`refresh[t]` renews an expired link).
    init(playlists: [URL], channels: [Int], start: Double, end: Double,
         sampleRate: Double, mixer: OpaquePointer, voice: Int32,
         live: StreamAudioTrack.LiveStart? = nil, refresh: [@Sendable () async -> URL?] = []) {
        self.mixer = mixer
        self.voice = voice
        tracks = zip(playlists, channels).enumerated().map { t, pc in
            let track = StreamAudioTrack(playlistURL: pc.0, start: start, end: end, outputRate: sampleRate, channels: pc.1,
                                         sink: MixerTrackSink(mixer: mixer, voice: voice, track: UInt32(t)))
            if var l = live {
                l.refresh = t < refresh.count ? refresh[t] : nil
                track.live = l
            }
            return track
        }
    }

    func start() {
        guard !started else { return }
        started = true
        for t in tracks {
            group.enter()
            Task.detached(priority: .userInitiated) { [group] in
                await t.run()
                group.leave()
            }
        }
    }

    func cancelAndWait() {
        tracks.forEach { $0.cancelled = true }
        if started { _ = group.wait(timeout: .now() + 5) }
    }

    func waitForPrefill(seconds: Double, sampleRate: Double, timeout: Double) async -> Bool {
        let wanted = UInt32(seconds * sampleRate)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var ready = true
            for (i, t) in tracks.enumerated() where !t.done {
                let buffered = cm_voice_buffered(mixer, voice, UInt32(i))
                let space = cm_voice_write_space(mixer, voice, UInt32(i))
                if buffered < wanted && space > 0 { ready = false }
            }
            if ready { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// The first error of a language that failed, if any.
    var failure: String? { tracks.compactMap(\.failure).first }
}

// MARK: - One language

/// Streams one audio rendition into a sink from file time `start` to `end`.
final class StreamAudioTrack: @unchecked Sendable {
    /// Livestreams: start with media sequence `sequence`, exactly at stream
    /// time `time` (seconds of the fragment timeline), and play until cancelled.
    /// `refresh` gives a new playlist link when the old one has expired.
    struct LiveStart {
        var sequence: Int
        var time: Double
        var refresh: (@Sendable () async -> URL?)?
    }

    var live: LiveStart?
    let playlistURL: URL
    let start: Double
    let end: Double
    let outputRate: Double
    let channels: Int
    let sink: PCMSink

    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }
    private(set) var failure: String?
    private(set) var done = false

    init(playlistURL: URL, start: Double, end: Double, outputRate: Double, channels: Int, sink: PCMSink) {
        self.playlistURL = playlistURL
        self.start = max(0, start)
        self.end = end
        self.outputRate = outputRate
        self.channels = channels
        self.sink = sink
    }

    /// Runs until the end, an error or cancel(). Never touches the sink after returning.
    func run() async {
        defer { done = true }
        do {
            if let live {
                try await runLive(live)
                return
            }
            let playlist = try await HLSMediaPlaylist.load(playlistURL)
            guard let initURL = playlist.initURL, !playlist.segments.isEmpty else {
                throw StreamError("The audio stream has no segments.")
            }
            let info = try FMP4.parseInit(try await Self.fetch(initURL))
            let decoder = try AACDecoder(info: info, outputRate: outputRate, outputChannels: channels)

            // Decode from the segment before the start if the start is right at a
            // border, so the decoder is warmed up when the wanted audio begins.
            var first = playlist.segmentIndex(at: start)
            if first > 0 && start - playlist.segments[first].start < 0.1 { first -= 1 }
            let segments = Array(playlist.segments[first...])

            // Download ahead (at most 4 segments not yet decoded) while decoding.
            let ahead = AsyncSemaphore(4)
            let downloads = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { continuation in
                let task = Task {
                    for s in segments {
                        if Task.isCancelled || self.cancelled { break }
                        await ahead.wait()
                        do {
                            continuation.yield(try await Self.fetch(s.url))
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }

            var cursor: Double?            // file time of the next decoded output frame
            for try await data in downloads {
                if cancelled { return }
                await ahead.signal()
                let fragment = try FMP4.parseSegment(data, info)
                let fragmentStart = Double(fragment.baseTime) / Double(info.timescale)
                if cursor == nil { cursor = fragmentStart }
                var pcm = try decoder.decode(fragment)
                let frames = pcm.count / channels

                // Trim to [start, end) in file time.
                let t0 = cursor!
                cursor = t0 + Double(frames) / outputRate
                var from = 0, to = frames
                if t0 < start { from = min(frames, Int(((start - t0) * outputRate).rounded())) }
                if cursor! > end { to = max(from, frames - Int(((cursor! - end) * outputRate).rounded())) }
                if from < to {
                    try await write(&pcm, from: from, to: to)
                }
                if cursor! >= end { break }
            }
            sink.finish()
        } catch is CancellationError {
            return
        } catch {
            if !cancelled {
                failure = error.localizedDescription
                sink.finish()
            }
        }
    }

    /// Livestream: segments from `live.sequence` on, reloading the playlist for
    /// new ones, for as long as the cue plays.
    private func runLive(_ live: LiveStart) async throws {
        var url = playlistURL
        func reload() async throws -> HLSMediaPlaylist {
            do {
                return try await HLSMediaPlaylist.load(url, cached: false)
            } catch {
                // The signed link may have expired: ask for a fresh one once.
                guard let fresh = await live.refresh?() else { throw error }
                url = fresh
                return try await HLSMediaPlaylist.load(url, cached: false)
            }
        }
        var playlist = try await reload()
        guard let initURL = playlist.initURL else { throw StreamError("The livestream has no audio.") }
        let info = try FMP4.parseInit(try await Self.fetch(initURL))
        let decoder = try AACDecoder(info: info, outputRate: outputRate, outputChannels: channels)

        var next = live.sequence
        var cursor: Double?
        var lastNew = Date()
        while !cancelled {
            let pending = playlist.segments.filter { $0.sequence >= next }
            if pending.isEmpty {
                if Date().timeIntervalSince(lastNew) > 30 { throw StreamError("The livestream stopped.") }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                playlist = try await reload()
                // Fell out of the window (e.g. a long network outage): go on from what is there.
                if let first = playlist.segments.first, first.sequence > next { next = first.sequence }
                continue
            }
            for s in pending {
                if cancelled { throw CancellationError() }
                let data = try await Self.fetch(s.url, cached: false)
                next = s.sequence + 1
                lastNew = Date()
                let fragment = try FMP4.parseSegment(data, info)
                if cursor == nil { cursor = Double(fragment.baseTime) / Double(info.timescale) }
                var pcm = try decoder.decode(fragment)
                let frames = pcm.count / channels
                let t0 = cursor!
                cursor = t0 + Double(frames) / outputRate
                var from = 0
                if s.sequence == live.sequence {
                    // Line the first segment up with the picture, which starts at live.time.
                    if t0 < live.time {
                        from = min(frames, Int(((live.time - t0) * outputRate).rounded()))
                    } else if t0 > live.time {
                        var silence = [Float](repeating: 0, count: Int(((t0 - live.time) * outputRate).rounded()) * channels)
                        try await write(&silence, from: 0, to: silence.count / channels)
                    }
                }
                if from < frames { try await write(&pcm, from: from, to: frames) }
            }
            playlist = try await reload()
        }
    }

    /// Writes frames [from, to) of `pcm`, waiting for room in the ring.
    private func write(_ pcm: inout [Float], from: Int, to: Int) async throws {
        var at = from
        while at < to {
            if cancelled { throw CancellationError() }
            let room = sink.space()
            if room == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            let n = min(room, to - at)
            let written = pcm.withUnsafeBufferPointer { buf in
                sink.write(buf.baseAddress! + at * channels, frames: n)
            }
            at += written
        }
    }

    /// Loads the playlist, init segment and the first two segments from file
    /// time `start` into StreamCache, so playback from there starts at once.
    static func prefetch(playlistURL: URL, start: Double) async {
        guard let playlist = try? await HLSMediaPlaylist.load(playlistURL), !playlist.segments.isEmpty else { return }
        if let initURL = playlist.initURL { _ = try? await fetch(initURL) }
        var i = playlist.segmentIndex(at: start)
        if i > 0 && start - playlist.segments[i].start < 0.1 { i -= 1 }
        for s in playlist.segments[i..<min(i + 2, playlist.segments.count)] {
            if Task.isCancelled { return }
            _ = try? await fetch(s.url)
        }
    }

    static func fetch(_ url: URL, cached: Bool = true) async throws -> Data {
        if cached, let hit = StreamCache.shared.data(for: url) { return hit }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.setValue("CueDeck", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard status == 200 else { throw StreamError("The stream answered \(status).") }
                if cached { StreamCache.shared.store(data, for: url) }
                return data
            } catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
                try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? StreamError("Could not load the stream.")
    }
}

struct StreamError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - AAC decoding

/// Decodes AAC packets continuously to interleaved Float32 at the output rate.
final class AACDecoder {
    private let decoder: AVAudioConverter
    private let resampler: AVAudioConverter?
    private let pcmFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private let channels: Int

    init(info: FMP4.InitInfo, outputRate: Double, outputChannels: Int) throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: info.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(info.channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: info.sampleRate,
                                      channels: AVAudioChannelCount(outputChannels), interleaved: true),
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                                      channels: AVAudioChannelCount(outputChannels), interleaved: true),
              let dec = AVAudioConverter(from: aac, to: pcm)
        else { throw StreamError("This audio stream can't be decoded.") }
        dec.magicCookie = info.magicCookie
        decoder = dec
        aacFormat = aac
        pcmFormat = pcm
        outFormat = out
        resampler = outputRate == info.sampleRate ? nil : AVAudioConverter(from: pcm, to: out)
        channels = outputChannels
    }

    /// PCM of all packets of a fragment (interleaved, `channels` per frame).
    func decode(_ fragment: FMP4.Fragment) throws -> [Float] {
        let maxSize = fragment.packets.map(\.count).max() ?? 0
        let input = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: AVAudioPacketCount(fragment.packets.count),
                                            maximumPacketSize: maxSize)
        var offset = 0
        for (i, p) in fragment.packets.enumerated() {
            p.withUnsafeBytes { raw in
                (input.data + offset).copyMemory(from: raw.baseAddress!, byteCount: p.count)
            }
            input.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(offset),
                                                                         mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(p.count))
            offset += p.count
        }
        input.packetCount = AVAudioPacketCount(fragment.packets.count)
        input.byteLength = UInt32(offset)

        let frames = AVAudioFrameCount(fragment.packets.count * 1024)
        guard let decoded = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames) else { return [] }
        var given = false
        var error: NSError?
        let status = decoder.convert(to: decoded, error: &error) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? StreamError("Audio decoding failed.") }

        var buffer = decoded
        if let resampler {
            let capacity = AVAudioFrameCount(Double(decoded.frameLength) * outFormat.sampleRate / pcmFormat.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
            var fed = false
            _ = resampler.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return decoded
            }
            buffer = out
        }
        let n = Int(buffer.frameLength) * channels
        guard n > 0, let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: n))
    }
}

// MARK: - Subtitles of streams

extension SubtitleReader {
    /// All cues of an HLS WebVTT subtitle rendition, in file time.
    static func loadHLS(playlistURL: URL) async -> [SubtitleEntry] {
        guard let playlist = try? await HLSMediaPlaylist.load(playlistURL) else { return [] }
        let texts = await withTaskGroup(of: (Int, String).self) { group -> [String] in
            for (i, s) in playlist.segments.enumerated() {
                group.addTask {
                    let data = (try? await StreamAudioTrack.fetch(s.url)) ?? Data()
                    return (i, String(decoding: data, as: UTF8.self))
                }
            }
            var result = [String](repeating: "", count: playlist.segments.count)
            for await (i, text) in group { result[i] = text }
            return result
        }
        var seen = Set<String>()
        var entries: [SubtitleEntry] = []
        for text in texts {
            for e in parseWebVTT(text) {
                // A cue that spans a segment border is in both segments.
                let key = "\(Int(e.start * 1000))|\(Int(e.end * 1000))|\(e.lines.joined(separator: "\n"))"
                if seen.insert(key).inserted { entries.append(e) }
            }
        }
        return entries.sorted { $0.start < $1.start }
    }

    static func parseWebVTT(_ text: String) -> [SubtitleEntry] {
        var offset = 0.0
        var entries: [SubtitleEntry] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let map = lines.first(where: { $0.hasPrefix("X-TIMESTAMP-MAP=") }) {
                // LOCAL:00:00:00.000,MPEGTS:900000 -> cue times are shifted by MPEGTS/90000 - LOCAL
                var local = 0.0, mpegts = 0.0
                for part in map.dropFirst("X-TIMESTAMP-MAP=".count).split(separator: ",") {
                    if part.hasPrefix("LOCAL:") { local = timecode(String(part.dropFirst(6))) ?? 0 }
                    if part.hasPrefix("MPEGTS:") { mpegts = (Double(part.dropFirst(7)) ?? 0) / 90000 }
                }
                offset = mpegts - local
            }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timecode(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = timecode(String(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""))
            else { continue }
            let textLines = lines[(timing + 1)...].map(plain).filter { !$0.isEmpty }
            if !textLines.isEmpty {
                entries.append(SubtitleEntry(start: start + offset, end: end + offset, lines: textLines))
            }
        }
        return entries
    }

    /// "01:02:03.456" or "02:03.456" in seconds.
    private static func timecode(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    /// Text without WebVTT tags (<i>, <c.yellow>, …) and with entities decoded.
    private static func plain(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", ""), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Small helpers

/// Recently loaded stream data (playlists, init and media segments) in memory,
/// so a cue that was prepared ahead starts at once. Oldest entries go first.
final class StreamCache: @unchecked Sendable {
    static let shared = StreamCache()
    private let lock = NSLock()
    private var items: [URL: Data] = [:]
    private var order: [URL] = []
    private var bytes = 0
    private let limit = 96 << 20

    func data(for url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[url]
    }

    func store(_ data: Data, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        if items[url] != nil { return }
        items[url] = data
        order.append(url)
        bytes += data.count
        while bytes > limit, let oldest = order.first {
            order.removeFirst()
            bytes -= items.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}

/// A counting semaphore for async code (download-ahead limit).
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { self.count = count }
    func wait() async {
        if count > 0 { count -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if waiters.isEmpty { count += 1 } else { waiters.removeFirst().resume() }
    }
}
