import Foundation

/// What happens when a cue reaches its end.
enum EndAction: String, Codable, CaseIterable, Identifiable {
    case stop      // stop and close the video output
    case next      // older shows only: becomes AutoStart.afterPrevious on the next cue
    case loop      // repeat seamlessly until stopped

    /// The choices offered in the inspector.
    static let selectable: [EndAction] = [.stop, .loop]

    var id: String { rawValue }
    var label: String {
        switch self {
        case .stop: return "Stop"
        case .next: return "Play next cue"
        case .loop: return "Loop"
        }
    }
}

/// Whether a cue starts by itself, relative to the cue above it in the list.
enum AutoStart: String, Codable, CaseIterable, Identifiable {
    case off            // waits for GO
    case afterPrevious  // starts exactly when the previous cue ends
    case withPrevious   // starts together with the previous cue

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "No autostart"
        case .afterPrevious: return "At end of previous cue"
        case .withPrevious: return "Together with previous cue"
        }
    }
    var shortLabel: String {
        switch self {
        case .off: return "No autostart"
        case .afterPrevious: return "After previous"
        case .withPrevious: return "With previous"
        }
    }
    var systemImage: String {
        switch self {
        case .off: return "hand.point.up.left"
        case .afterPrevious: return "arrow.turn.down.right"
        case .withPrevious: return "link"
        }
    }
}

/// One audio track (stream) found in a media file.
struct AudioTrackInfo: Codable, Equatable, Identifiable {
    var index: Int          // order among the file's audio tracks
    var channels: Int
    var label: String       // detected, e.g. "Stream 2 · 2 ch · deu"
    var name: String = ""   // user-given name, empty = use label
    var fileName: String = "" // name stored in the media file, if any
    var channelNames: [String] = []
    var id: Int { index }

    init(index: Int, channels: Int, label: String) {
        self.index = index
        self.channels = channels
        self.label = label
    }

    /// Shown everywhere in the app: the user's name, else "Stream 1" plus the
    /// name from the file ("Stream 1 · English").
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let f = fileName.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? "Stream \(index + 1)" : "Stream \(index + 1) · \(f)"
    }

    func defaultChannelName(_ c: Int) -> String {
        if channels == 1 { return "Mono" }
        if channels == 2 { return c == 0 ? "L" : "R" }
        return "Ch \(c + 1)"
    }

    func channelName(_ c: Int) -> String {
        if c < channelNames.count, !channelNames[c].trimmingCharacters(in: .whitespaces).isEmpty {
            return channelNames[c]
        }
        return defaultChannelName(c)
    }

    enum CodingKeys: String, CodingKey { case index, channels, label, name, fileName, channelNames }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        channels = try c.decode(Int.self, forKey: .channels)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Stream \(index + 1)"
        // Older shows saved "Track 2 · 2 ch".
        if label.hasPrefix("Track ") { label = "Stream " + label.dropFirst("Track ".count) }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        channelNames = try c.decodeIfPresent([String].self, forKey: .channelNames) ?? []
    }
}

/// A subtitle track (text, tx3g) found in a media file.
struct SubtitleTrackInfo: Codable, Equatable, Identifiable {
    var index: Int                  // order among the file's subtitle tracks
    var trackID: Int32              // AVAssetTrack.trackID, to read the track again
    var language: String = ""       // ISO code, e.g. "deu"
    var fileName: String = ""       // name stored in the file, if any
    var id: Int { index }

    /// "German", the file's name for the track, or "Subtitles 1".
    var displayName: String {
        let f = fileName.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty { return f }
        if !language.isEmpty, let name = Locale(identifier: "en").localizedString(forLanguageCode: language) {
            return name
        }
        return "Subtitles \(index + 1)"
    }
}

/// Special values in the default routing (Settings). Other values are the
/// first output of the stream, 0 based.
enum RoutingDefault {
    static let automatic = -2   // right after the previous stream
    static let off = -1
    /// Streams listed in the settings (a cue plays up to 16 audio tracks).
    static let streams = 16
}

/// A playable item in the cue list.
struct Cue: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var name: String

    // Playback options
    var speed: Double = 1.0            // 0.25 ... 4.0, pitch preserved
    var volumeDB: Double = 0           // -60 ... +12
    var fadeIn: Double = 0             // seconds
    var fadeOut: Double = 0            // seconds, before the natural end
    var stopFade: Double = 1.0         // seconds, used when the cue is stopped manually
    var inPoint: Double = 0            // seconds into the source file
    var outPoint: Double = 0           // seconds into the source file, 0 = until the end
    var endAction: EndAction = .stop
    var autoStart: AutoStart = .off
    /// Play only the audio of a video file (no video output).
    var audioOnly: Bool = false
    /// Start without stopping cues that are already playing.
    var playAlongside: Bool = false

    /// routes[track][channel] = output channel (0 based), -1 = off.
    var routes: [[Int]] = []

    // Media information (filled in when the file is inspected)
    var duration: Double = 0           // source duration in seconds
    var hasVideo: Bool = false
    var videoSize: String = ""
    var frameRate: Double = 0          // video frames per second, 0 = unknown / no video
    var audioTracks: [AudioTrackInfo] = []
    var subtitleTracks: [SubtitleTrackInfo] = []
    /// Index into `subtitleTracks` sent to CasparCG, -1 = off.
    var subtitleTrack: Int = 0
    var missing: Bool = false

    init(url: URL) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
    }

    /// The subtitle track sent to CasparCG, nil = off or none.
    var selectedSubtitles: SubtitleTrackInfo? {
        subtitleTrack >= 0 && subtitleTrack < subtitleTracks.count ? subtitleTracks[subtitleTrack] : nil
    }

    /// Whether playing this cue shows video.
    var playsVideo: Bool { hasVideo && !audioOnly }

    /// End of the selected part, in source seconds.
    var segmentEnd: Double { outPoint > 0 ? min(outPoint, duration) : duration }
    var segmentStart: Double { min(max(0, inPoint), segmentEnd) }

    /// Length of the selected part of the source, in source seconds.
    var segmentDuration: Double { max(0, segmentEnd - segmentStart) }

    /// How long the cue plays (one pass) at its speed.
    var playDuration: Double { speed > 0 ? segmentDuration / speed : segmentDuration }

    var linearGain: Float {
        volumeDB <= -60 ? 0 : Float(pow(10.0, volumeDB / 20.0))
    }

    /// Media time (seconds of source material since the cue's start point,
    /// loop passes back to back) to a time in the source file.
    func fileTime(forMedia m: Double) -> Double {
        let seg = segmentDuration
        guard seg > 0 else { return segmentStart }
        var local = max(0, m)
        if endAction == .loop { local = local.truncatingRemainder(dividingBy: seg) }
        return segmentStart + min(local, seg)
    }

    /// Start time of the video frame that contains `t` (file seconds).
    func frameStart(_ t: Double) -> Double {
        guard frameRate > 0 else { return t }
        return (t * frameRate + 1e-6).rounded(.down) / frameRate
    }

    /// A seek target safely inside the frame that starts at `t`, so rounding
    /// in the media timeline can never land on the previous frame.
    func seekTarget(_ t: Double) -> Double {
        frameRate > 0 ? t + 0.25 / frameRate : t
    }

    /// Source-file time to media time in the given loop pass.
    func mediaTime(forFile f: Double, pass: Int = 0) -> Double {
        let local = min(max(f, segmentStart), segmentEnd) - segmentStart
        return Double(pass) * segmentDuration + local
    }

    // MARK: Routing

    /// Routes every track by the default routing from the settings:
    /// `defaults[track]` is the first output (0 based), `RoutingDefault.off`, or
    /// `RoutingDefault.automatic` (right after the previous track; the default,
    /// so track 1 -> outputs 1-2, track 2 -> outputs 3-4, ...).
    mutating func assignDefaultRoutes(outputChannels: Int, defaults: [Int] = []) {
        var next = 0
        routes = audioTracks.enumerated().map { t, track in
            let setting = t < defaults.count ? defaults[t] : RoutingDefault.automatic
            if setting == RoutingDefault.off { return Array(repeating: -1, count: track.channels) }
            let start = setting >= 0 ? setting : next
            next = start + track.channels
            return (0..<track.channels).map { c in start + c < outputChannels ? start + c : -1 }
        }
    }

    /// Makes sure routes has one entry per track channel.
    mutating func normalizeRoutes(outputChannels: Int, defaults: [Int] = []) {
        let shapeOK = routes.count == audioTracks.count &&
            zip(routes, audioTracks).allSatisfy { $0.count == $1.channels }
        if !shapeOK { assignDefaultRoutes(outputChannels: outputChannels, defaults: defaults) }
    }

    /// First output of a track if its channels go to consecutive outputs,
    /// -1 if the track is off, nil if the routing is custom.
    func blockStart(ofTrack t: Int) -> Int? {
        guard t < routes.count, !routes[t].isEmpty else { return -1 }
        let r = routes[t]
        if r.allSatisfy({ $0 < 0 }) { return -1 }
        guard let first = r.first, first >= 0 else { return nil }
        for (i, o) in r.enumerated() where o != first + i { return nil }
        return first
    }

    /// Routes a whole track to consecutive outputs starting at `start` (0 based), or off with -1.
    mutating func setBlock(track t: Int, start: Int, outputChannels: Int) {
        guard t < audioTracks.count else { return }
        while routes.count <= t { routes.append([]) }
        let n = audioTracks[t].channels
        routes[t] = (0..<n).map { c in
            guard start >= 0 else { return -1 }
            let o = start + c
            return o < outputChannels ? o : -1
        }
    }

    /// Values clamped to their allowed ranges.
    func sanitized() -> Cue {
        var c = self
        c.speed = min(max(c.speed.isFinite ? c.speed : 1, 0.25), 4)
        c.volumeDB = min(max(c.volumeDB.isFinite ? c.volumeDB : 0, -60), 12)
        c.fadeIn = max(0, c.fadeIn.isFinite ? c.fadeIn : 0)
        c.fadeOut = max(0, c.fadeOut.isFinite ? c.fadeOut : 0)
        c.stopFade = max(0, c.stopFade.isFinite ? c.stopFade : 0)
        c.inPoint = max(0, c.inPoint.isFinite ? c.inPoint : 0)
        c.outPoint = max(0, c.outPoint.isFinite ? c.outPoint : 0)
        return c
    }

    /// Keeps user names when media info is refreshed.
    mutating func adoptNames(from old: [AudioTrackInfo]) {
        for i in audioTracks.indices where i < old.count {
            audioTracks[i].name = old[i].name
            audioTracks[i].channelNames = old[i].channelNames
        }
    }

    // MARK: Coding (defaults for keys older show files may not have)

    enum CodingKeys: String, CodingKey {
        case id, url, name, speed, volumeDB, fadeIn, fadeOut, stopFade, inPoint, outPoint,
             endAction, autoStart, audioOnly, playAlongside, routes, duration, hasVideo, videoSize, frameRate, audioTracks,
             subtitleTracks, subtitleTrack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decode(URL.self, forKey: .url)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? url.lastPathComponent
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        stopFade = try c.decodeIfPresent(Double.self, forKey: .stopFade) ?? 1
        inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0
        outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint) ?? 0
        endAction = try c.decodeIfPresent(EndAction.self, forKey: .endAction) ?? .stop
        autoStart = try c.decodeIfPresent(AutoStart.self, forKey: .autoStart) ?? .off
        audioOnly = try c.decodeIfPresent(Bool.self, forKey: .audioOnly) ?? false
        playAlongside = try c.decodeIfPresent(Bool.self, forKey: .playAlongside) ?? false
        routes = try c.decodeIfPresent([[Int]].self, forKey: .routes) ?? []
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        videoSize = try c.decodeIfPresent(String.self, forKey: .videoSize) ?? ""
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate) ?? 0
        audioTracks = try c.decodeIfPresent([AudioTrackInfo].self, forKey: .audioTracks) ?? []
        subtitleTracks = try c.decodeIfPresent([SubtitleTrackInfo].self, forKey: .subtitleTracks) ?? []
        subtitleTrack = try c.decodeIfPresent(Int.self, forKey: .subtitleTrack) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(name, forKey: .name)
        try c.encode(speed, forKey: .speed)
        try c.encode(volumeDB, forKey: .volumeDB)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(stopFade, forKey: .stopFade)
        try c.encode(inPoint, forKey: .inPoint)
        try c.encode(outPoint, forKey: .outPoint)
        try c.encode(endAction, forKey: .endAction)
        try c.encode(autoStart, forKey: .autoStart)
        try c.encode(audioOnly, forKey: .audioOnly)
        try c.encode(playAlongside, forKey: .playAlongside)
        try c.encode(routes, forKey: .routes)
        try c.encode(duration, forKey: .duration)
        try c.encode(hasVideo, forKey: .hasVideo)
        try c.encode(videoSize, forKey: .videoSize)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encode(subtitleTracks, forKey: .subtitleTracks)
        try c.encode(subtitleTrack, forKey: .subtitleTrack)
    }
}

/// A saved show: the cue list.
struct ShowFile: Codable {
    var version = 1
    var cues: [Cue]
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    let tenths = Int((seconds - Double(total)) * 10)
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d.%d", m, s, tenths)
}

/// "1:02:03.25" / "02:03.25" with hundredths, for timecode fields.
func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00.00" }
    let hundredths = Int((seconds * 100).rounded())
    let h = hundredths / 360_000, m = (hundredths / 6000) % 60, s = (hundredths / 100) % 60, f = hundredths % 100
    if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, f) }
    return String(format: "%02d:%02d.%02d", m, s, f)
}

/// Parses "90", "90.5", "1:30", "1:30,5", "01:02:03.250" into seconds.
func parseTimecode(_ text: String) -> Double? {
    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard !cleaned.isEmpty else { return nil }
    let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 3 else { return nil }
    var total = 0.0
    for (i, part) in parts.enumerated() {
        guard let v = Double(part), v >= 0 else { return nil }
        let isLast = i == parts.count - 1
        if !isLast && v != v.rounded() { return nil }
        total = total * 60 + v
    }
    return total
}
