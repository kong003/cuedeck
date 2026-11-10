import AVFoundation
import Foundation

// The BCC livestream (live.bcc-connect.org): the same unencrypted HLS CMAF
// as BCC Media episodes, but endless. Audio is decoded by StreamAudioTrack
// in live mode; video plays in an AVPlayer that loads its playlists through
// LiveHLSProxy. The proxy cuts every video playlist so it begins at the start
// segment, which makes the player's time 0 the start of exactly the segment
// the audio starts with, so picture and sound can be started together.

extension BCCMedia {
    struct Live {
        var url: URL
        var expiresAt: Date?
    }

    /// The livestream's signed master playlist, nil when it is offline.
    static func live(token: String) async throws -> Live? {
        let (status, json) = try await postJSON(api, ["query": "{ live { isOnline url expiresAt } }"], headers: [
            "Authorization": "Bearer \(token)", "X-Application": "cuedeck",
        ])
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw APIError(message: "BCC Live: \(first["message"] as? String ?? "error \(status)")")
        }
        guard let live = (json["data"] as? [String: Any])?["live"] as? [String: Any] else {
            throw APIError(message: status == 401 ? "BCC Media: please sign in again." : "BCC Live is not available.")
        }
        guard live["isOnline"] as? Bool == true, let s = live["url"] as? String, let url = URL(string: s) else { return nil }
        let expires = (live["expiresAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Live(url: url, expiresAt: expires)
    }
}

/// Where a livestream cue starts: a media sequence number a few segments
/// behind the live edge, and that segment's start on the stream timeline.
struct LiveStartPoint {
    var sequence: Int
    var time: Double

    /// `segmentsBehind` segments before the newest one (like other players, so
    /// there is always something buffered).
    static func find(master: HLSMaster, segmentsBehind: Int = 3) async throws -> LiveStartPoint {
        // The smallest video variant: all variants share sequences and timestamps.
        guard let variant = master.variants.min(by: { $0.bandwidth < $1.bandwidth }) else {
            throw StreamError("The livestream has no video.")
        }
        let playlist = try await HLSMediaPlaylist.load(variant.url, cached: false)
        guard let last = playlist.segments.last, let initURL = playlist.initURL else {
            throw StreamError("The livestream has no segments yet.")
        }
        let index = max(0, playlist.segments.count - 1 - segmentsBehind)
        let segment = playlist.segments[index]
        let timescale = try timescale(ofInit: try await StreamAudioTrack.fetch(initURL))
        let data = try await StreamAudioTrack.fetch(segment.url, cached: true)
        guard let base = decodeTime(data) else { throw StreamError("Can't read the livestream's timing.") }
        _ = last
        return LiveStartPoint(sequence: segment.sequence, time: Double(base) / Double(timescale))
    }

    /// mdhd timescale of an init segment.
    private static func timescale(ofInit d: Data) throws -> UInt32 {
        guard let r = d.range(of: Data("mdhd".utf8)) else { throw StreamError("Can't read the livestream's timing.") }
        let at = r.upperBound
        let version = d[at]
        let o = at + (version == 1 ? 20 : 12)
        guard o + 4 <= d.endIndex else { throw StreamError("Can't read the livestream's timing.") }
        return UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }

    /// baseMediaDecodeTime of the first tfdt box of a media segment.
    private static func decodeTime(_ d: Data) -> UInt64? {
        guard let r = d.range(of: Data("tfdt".utf8)) else { return nil }
        let at = r.upperBound
        guard at + 12 <= d.endIndex else { return nil }
        let bytes = { (o: Int, n: Int) -> UInt64 in (0..<n).reduce(0) { $0 << 8 | UInt64(d[o + $1]) } }
        return d[at] == 1 ? bytes(at + 4, 8) : bytes(at + 4, 4)
    }
}

/// Serves the livestream's playlists to an AVPlayer (custom URL scheme):
/// video and the player's (muted) audio playlist are cut to start at the
/// start segment, subtitles are left out (CueDeck shows them itself), and an
/// expired link is replaced with a fresh one.
final class LiveHLSProxy: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "cuedeck-live"
    private let queue = DispatchQueue(label: "CueDeck.live-proxy")
    private let startSequence: Int
    private let refresh: @Sendable () async -> URL?
    private let lock = NSLock()
    private var masterURL: URL
    private var variants: [URL] = []      // real links by index, from the last master
    private var audioURL: URL?

    init(masterURL: URL, startSequence: Int, refresh: @escaping @Sendable () async -> URL?) {
        self.masterURL = masterURL
        self.startSequence = startSequence
        self.refresh = refresh
    }

    /// The asset to play; keep the proxy alive as long as the player.
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://live/master.m3u8")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }
        Task {
            do {
                let text = try await self.playlist(for: url.path)
                loadingRequest.contentInformationRequest?.contentType = "public.m3u-playlist"
                loadingRequest.contentInformationRequest?.contentLength = Int64(text.utf8.count)
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
                loadingRequest.dataRequest?.respond(with: Data(text.utf8))
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    private func playlist(for path: String) async throws -> String {
        if path.hasSuffix("master.m3u8") { return try await master() }
        if path.hasPrefix("/audio") {
            guard let url = lock.withLock({ audioURL }) else { throw StreamError("No audio playlist.") }
            return try await media(url, audio: true, index: 0)
        }
        let index = Int(path.split(separator: "/").last?.split(separator: ".").first ?? "") ?? 0
        guard let url = lock.withLock({ index < variants.count ? variants[index] : nil }) else {
            throw StreamError("No such video playlist.")
        }
        return try await media(url, audio: false, index: index)
    }

    /// The master with our links for the video variants and the default audio,
    /// without subtitles.
    private func master() async throws -> String {
        let url = lock.withLock { masterURL }
        let data = try await loadRefreshing(url, isMaster: true)
        let base = lock.withLock { masterURL }
        var out: [String] = []
        var vars: [URL] = []
        var audio: URL?
        var expectVariant = false
        for raw in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = HLSMaster.attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if a["TYPE"] == "SUBTITLES" || a["TYPE"] == "CLOSED-CAPTIONS" { continue }
                if a["TYPE"] == "AUDIO" {
                    // One (muted) audio rendition is enough for the player.
                    guard a["DEFAULT"] == "YES", audio == nil, let uri = a["URI"],
                          let u = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
                    audio = u
                    out.append(line.replacingOccurrences(of: uri, with: "\(Self.scheme)://live/audio.m3u8"))
                    continue
                }
                out.append(line)
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                out.append(line.replacingOccurrences(of: ",SUBTITLES=\"subs\"", with: "")
                    .replacingOccurrences(of: #",SUBTITLES="[^"]*""#, with: "", options: .regularExpression))
                expectVariant = true
            } else if expectVariant && !line.isEmpty && !line.hasPrefix("#") {
                if let u = URL(string: line, relativeTo: base)?.absoluteURL { vars.append(u) }
                out.append("\(Self.scheme)://live/video/\(vars.count - 1).m3u8")
                expectVariant = false
            } else {
                out.append(line)
            }
        }
        lock.withLock {
            variants = vars
            audioURL = audio
        }
        return out.joined(separator: "\n")
    }

    /// A media playlist with absolute links, starting at the start segment.
    private func media(_ url: URL, audio: Bool, index: Int) async throws -> String {
        var data: Data
        var base = url
        do {
            data = try await StreamAudioTrack.fetch(url, cached: false)
        } catch {
            // Expired link: new master, then the same variant from it.
            _ = try await master()
            guard let fresh = lock.withLock({ audio ? audioURL : (index < variants.count ? variants[index] : nil) })
            else { throw error }
            base = fresh
            data = try await StreamAudioTrack.fetch(fresh, cached: false)
        }
        var out: [String] = []
        var sequence = 0
        var pendingInf: String?
        for raw in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                out.append("#EXT-X-MEDIA-SEQUENCE:\(max(sequence, startSequence))")
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = HLSMaster.attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = a["URI"], let u = URL(string: uri, relativeTo: base)?.absoluteURL {
                    out.append(line.replacingOccurrences(of: uri, with: u.absoluteString))
                } else {
                    out.append(line)
                }
            } else if line.hasPrefix("#EXTINF:") {
                pendingInf = line
            } else if !line.isEmpty && !line.hasPrefix("#") {
                if sequence >= startSequence, let inf = pendingInf,
                   let u = URL(string: line, relativeTo: base)?.absoluteURL {
                    out.append(inf)
                    out.append(u.absoluteString)
                }
                pendingInf = nil
                sequence += 1
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                if sequence >= startSequence { out.append(line) }
            } else if !line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME") || sequence >= startSequence {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    private func loadRefreshing(_ url: URL, isMaster: Bool) async throws -> Data {
        do {
            return try await StreamAudioTrack.fetch(url, cached: false)
        } catch {
            guard let fresh = await refresh() else { throw error }
            lock.withLock { masterURL = fresh }
            return try await StreamAudioTrack.fetch(fresh, cached: false)
        }
    }
}

/// Subtitles of the livestream: the WebVTT playlist is read again and again
/// and only new segments are loaded.
@MainActor
final class LiveSubtitleFeed {
    let playlistURL: URL
    private(set) var entries: [SubtitleEntry] = []
    private var next: Int?
    private var seen = Set<String>()

    init(playlistURL: URL) { self.playlistURL = playlistURL }

    func update() async {
        guard let playlist = try? await HLSMediaPlaylist.load(playlistURL, cached: false) else { return }
        // At first only the last minute; later everything new.
        let new = next.map { n in playlist.segments.filter { $0.sequence >= n } } ?? Array(playlist.segments.suffix(10))
        for s in new {
            guard let data = try? await StreamAudioTrack.fetch(s.url, cached: false) else { continue }
            for e in SubtitleReader.parseWebVTT(String(decoding: data, as: UTF8.self)) {
                let key = "\(Int(e.start * 1000))|\(Int(e.end * 1000))|\(e.lines.joined(separator: "\n"))"
                if seen.insert(key).inserted { entries.append(e) }
            }
        }
        if let last = playlist.segments.last { next = last.sequence + 1 }
        entries.sort { $0.start < $1.start }
        if entries.count > 600 { entries.removeFirst(entries.count - 600) }
    }
}

/// A preview frame of a stream: only the one small video segment that holds
/// the frame is loaded (about 200 KB), never the whole video.
enum StreamFrameGrabber {
    /// The frame at file time `time`, or for a livestream (`time` nil) the newest one.
    static func frame(master: HLSMaster, at time: Double?) async -> CGImage? {
        let variants = master.variants
        guard let variant = variants.filter({ $0.height >= 120 }).min(by: { $0.bandwidth < $1.bandwidth })
                ?? variants.max(by: { $0.height < $1.height }),
              let playlist = try? await HLSMediaPlaylist.load(variant.url, cached: time != nil),
              let initURL = playlist.initURL, !playlist.segments.isEmpty else { return nil }
        let segment = time.map { playlist.segments[playlist.segmentIndex(at: $0)] } ?? playlist.segments.last!
        guard let initData = try? await StreamAudioTrack.fetch(initURL),
              let data = try? await StreamAudioTrack.fetch(segment.url, cached: time != nil) else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuedeck-frame-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? (initData + data).write(to: file)) != nil else { return nil }
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let offset = time.map { max(0, min($0 - segment.start, range.duration.seconds - 0.05)) } ?? 0
        let at = CMTime(seconds: range.start.seconds + offset, preferredTimescale: 600)
        return try? await generator.image(at: at).image
    }
}
