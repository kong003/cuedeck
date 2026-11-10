import AppKit
import AVFoundation
import ObjCSupport
import SwiftUI

/// Peak overview of every channel of every audio track of a cue.
struct Waveform {
    /// peaks[track][channel][bucket], 0...1
    let peaks: [[[Float]]]
}

/// Computes waveforms in the background and caches them.
@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()
    nonisolated static let buckets = 1500

    @Published private(set) var waveforms: [String: Waveform] = [:]
    private var loading: Set<String> = []

    /// Waveforms cover the whole file, so changing start/end points is instant.
    static func key(for cue: Cue) -> String {
        "\(cue.url.path)|\(cue.duration)"
    }

    func waveform(for cue: Cue) -> Waveform? { waveforms[Self.key(for: cue)] }

    func load(_ cue: Cue) {
        let key = Self.key(for: cue)
        guard waveforms[key] == nil, !loading.contains(key), !cue.audioTracks.isEmpty, !cue.isStream else { return }
        loading.insert(key)
        let url = cue.url
        let start = 0.0
        let end = max(cue.duration, 0.01)
        Task.detached(priority: .utility) {
            let result = await Self.compute(url: url, start: start, end: end)
            await MainActor.run {
                let store = WaveformStore.shared
                store.loading.remove(key)
                if let result { store.waveforms[key] = result }
            }
        }
    }

    nonisolated static func compute(url: URL, start: Double, end: Double) async -> Waveform? {
        let asset = AVURLAsset(url: url)
        guard let sources = try? await MediaInspector.audioTracks(of: asset), !sources.isEmpty else { return nil }
        let rate = 8000.0   // lowest rate AVFoundation accepts everywhere
        let span = max(end - start, 0.01)
        var all: [[[Float]]] = []

        for src in sources {
            let ch = src.channels
            var peaks = [[Float]](repeating: [Float](repeating: 0, count: buckets), count: ch)
            guard let reader = try? AVAssetReader(asset: asset) else {
                all.append(peaks)
                continue
            }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000),
                                           end: CMTime(seconds: end, preferredTimescale: 48000))
            // Resampled to 8 kHz if possible, else at the file's own rate.
            var output: AVAssetReaderTrackOutput?
            var sourceRate = rate
            let attempts: [(Data?, Double?)] = [(src.layoutData, rate), (nil, rate), (nil, nil)]
            for (layout, wantedRate) in attempts {
                let settings = MediaInspector.pcmSettings(channels: ch, layout: layout, rate: wantedRate)
                var candidate: AVAssetReaderTrackOutput?
                let problem = CDCatchException({
                    let o = AVAssetReaderTrackOutput(track: src.track, outputSettings: settings)
                    o.alwaysCopiesSampleData = false
                    if reader.canAdd(o) {
                        reader.add(o)
                        candidate = o
                    }
                })
                if problem == nil, let candidate {
                    output = candidate
                    if wantedRate == nil {
                        let fds = (try? await src.track.load(.formatDescriptions)) ?? []
                        if let fd = fds.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                            sourceRate = asbd.pointee.mSampleRate
                        }
                    }
                    break
                }
            }
            guard let output else {
                all.append(peaks)
                continue
            }
            let totalFrames = span * sourceRate
            if CDCatchException({ reader.startReading() }) != nil {
                all.append(peaks)
                continue
            }

            var frameIndex = 0.0
            var scratch: [Float] = []
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); return nil }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
                scratch.withUnsafeMutableBytes { raw in
                    if let base = raw.baseAddress {
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: base)
                    }
                }
                let frames = count / ch
                for f in 0..<frames {
                    let b = min(buckets - 1, Int(frameIndex / totalFrames * Double(buckets)))
                    for c in 0..<ch {
                        let v = abs(scratch[f * ch + c])
                        if v > peaks[c][b] { peaks[c][b] = v }
                    }
                    frameIndex += 1
                }
            }
            all.append(peaks)
        }
        return Waveform(peaks: all)
    }
}

// MARK: - Bottom panel

/// Maps file seconds to x positions across the whole file.
struct FileTimeline {
    let duration: Double
    let width: CGFloat
    func x(_ t: Double) -> CGFloat { duration > 0 ? CGFloat(t / duration) * width : 0 }
    func time(_ x: CGFloat) -> Double { duration * Double(min(max(x, 0), width) / max(width, 1)) }
}

/// Bottom panel for the selected cue (or the playing cue if nothing is
/// selected): a ruler over the whole file with draggable start and end
/// points, and one waveform lane per audio channel. Click or drag anywhere
/// to jump.
struct WaveformPanel: View {
    @EnvironmentObject var engine: PlaybackEngine
    @ObservedObject private var store = WaveformStore.shared
    /// Streams of the shown cue drawn as one combined lane; remembered per cue.
    @State private var collapsed: Set<Int> = []

    private static func collapsedKey(_ id: UUID) -> String { "collapsedStreams.\(id.uuidString)" }

    private var cue: Cue? {
        if let id = engine.selection, let c = engine.findCue(id) { return c }
        if let id = engine.playing.last?.cueID { return engine.findCue(id) }
        return nil
    }

    var body: some View {
        if let cue, cue.isLive {
            // No timeline for the livestream: it always plays from "now".
            HStack(spacing: 10) {
                LivePreview(cue: cue)
                Text("● LIVE").font(.caption.weight(.bold)).foregroundStyle(.red)
                Text("\(cue.name): the BCC livestream starts a few seconds behind live and plays until it is stopped.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let cue, cue.duration > 0 {
            VStack(alignment: .leading, spacing: 6) {
                TimelineControls(cue: cue)

                HStack(spacing: 8) {
                    Color.clear.frame(width: 190, height: 1)
                    TrimRuler(cue: cue)
                        .frame(height: 26)
                }

                // Video and audio lanes scroll together.
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        if cue.hasVideo {
                            VideoLane(cue: cue)
                                .id(cue.id)
                        }
                        if cue.audioTracks.isEmpty {
                            Text("This cue has no audio.").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Streams have no waveforms: one loading bar for the whole cue,
                        // next to the preview, or here if the cue has no video.
                        if cue.isStream && !cue.hasVideo {
                            HStack(spacing: 8) {
                                Text("Audio").font(.caption.weight(.semibold))
                                    .frame(width: 190, alignment: .leading)
                                StreamLoadBar(cue: cue).frame(height: 10)
                            }
                            .frame(height: 16)
                        }
                        ForEach(cue.isStream ? [] : cue.audioTracks) { track in
                            WaveformTrackGroup(
                                cue: cue, track: track,
                                channelPeaks: (0..<track.channels).map { peaks(cue, track.index, $0) },
                                collapsed: Binding(
                                    get: { collapsed.contains(track.index) },
                                    set: {
                                        if $0 { collapsed.insert(track.index) } else { collapsed.remove(track.index) }
                                        UserDefaults.standard.set(Array(collapsed).sorted(), forKey: Self.collapsedKey(cue.id))
                                    }
                                ))
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .task(id: WaveformStore.key(for: cue)) { store.load(cue) }
            .task(id: cue.id) {
                collapsed = Set(UserDefaults.standard.array(forKey: Self.collapsedKey(cue.id)) as? [Int] ?? [])
            }
        } else {
            HStack {
                Text(cue == nil ? "Select a cue to see its timeline and audio channels." : "No media information for this cue.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func peaks(_ cue: Cue, _ t: Int, _ c: Int) -> [Float]? {
        guard let w = store.waveform(for: cue), t < w.peaks.count, c < w.peaks[t].count else { return nil }
        return w.peaks[t][c]
    }
}

/// Time ruler over the whole file. The part between start and end is
/// highlighted; drag the green start and red end handles to trim. Click or
/// drag elsewhere to move the playhead.
struct TrimRuler: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    @State private var dragging: Handle?

    private enum Handle { case start, end, playhead }

    var body: some View {
        GeometryReader { geo in
            let tl = FileTimeline(duration: cue.duration, width: geo.size.width)
            let h = geo.size.height
            let startX = tl.x(cue.segmentStart)
            let endX = tl.x(cue.segmentEnd)
            let playhead = engine.playhead(for: cue.id)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Whole file
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: h * 0.35, width: size.width, height: h * 0.3), cornerRadius: 3),
                             with: .color(.secondary.opacity(0.18)))
                    // Selected part
                    ctx.fill(Path(roundedRect: CGRect(x: startX, y: h * 0.3, width: max(endX - startX, 1), height: h * 0.4), cornerRadius: 3),
                             with: .color(.accentColor.opacity(0.55)))
                    // Ticks every "nice" interval
                    let step = niceStep(duration: cue.duration, width: size.width)
                    var t = 0.0
                    while t <= cue.duration {
                        let x = tl.x(t)
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: h * 0.25)), with: .color(.secondary.opacity(0.5)))
                        t += step
                    }
                    if let p = playhead {
                        let x = tl.x(p)
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)), with: .color(.red))
                    }
                }

                handle(color: .green, x: startX, height: h, label: "Start")
                handle(color: .red, x: endX, height: h, label: "End")
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragging == nil {
                            let x0 = v.startLocation.x
                            if abs(x0 - startX) <= 8 { dragging = .start }
                            else if abs(x0 - endX) <= 8 { dragging = .end }
                            else { dragging = .playhead }
                        }
                        let t = tl.time(v.location.x)
                        switch dragging {
                        case .some(.start): engine.setStartPoint(cue.id, to: t)
                        case .some(.end): engine.setEndPoint(cue.id, to: t)
                        default:
                            if abs(v.translation.width) > 2 { engine.scrub(cue.id, toFile: t) }
                        }
                    }
                    .onEnded { v in
                        if dragging == .playhead || dragging == nil {
                            engine.seek(cue.id, toFile: tl.time(v.location.x))
                        }
                        dragging = nil
                    }
            )
        }
        .help("Drag the green handle to set the start point and the red handle to set the end point")
    }

    private func handle(color: Color, x: CGFloat, height: CGFloat, label: String) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 6, height: height)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.7), lineWidth: 1))
            .offset(x: x - 3)
            .accessibilityLabel(label)
    }

    private func niceStep(duration: Double, width: CGFloat) -> Double {
        let target = duration / Double(max(width / 60, 1))
        for s in [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600] where s >= target { return s }
        return 3600
    }
}

/// Header of the bottom panel: the cue, the playhead (type a time to jump),
/// frame and jump buttons, and the start and end points (typed or set at the playhead).
struct TimelineControls: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue

    private var playhead: Double { engine.playhead(for: cue.id) ?? cue.segmentStart }
    private var isPlaying: Bool { engine.activeCueIDs.contains(cue.id) }

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 4) {
            HStack(spacing: 6) {
                Text(cue.name).font(.caption.weight(.semibold)).lineLimit(1)
                // Always as wide as the longest status, so the row never re-wraps.
                ZStack(alignment: .leading) {
                    Text("GO starts here").hidden()
                    if isPlaying {
                        Text("Playing").foregroundStyle(.green)
                    } else if engine.pendingStarts[cue.id] != nil {
                        Text("GO starts here").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 4) {
                TimecodeField(seconds: playhead) { engine.seek(cue.id, toFile: $0) }
                    .frame(width: 104)
                    .controlSize(.small)
                Button { engine.stepFrame(cue.id, by: -1) } label: { Image(systemName: "chevron.left") }
                    .help("One frame back (←)")
                Button { engine.stepFrame(cue.id, by: 1) } label: { Image(systemName: "chevron.right") }
                    .help("One frame forward (→)")
                Button { engine.nudge(cue.id, by: -10) } label: { Image(systemName: "gobackward.10") }
                    .help("Back 10 seconds")
                Button { engine.nudge(cue.id, by: 10) } label: { Image(systemName: "goforward.10") }
                    .help("Forward 10 seconds")
                Button { engine.seek(cue.id, toFile: cue.segmentStart) } label: { Image(systemName: "backward.end.fill") }
                    .help("Back to the start point")
            }

            HStack(spacing: 4) {
                Text("Start").font(.caption).foregroundStyle(.green)
                TimecodeField(seconds: cue.segmentStart) { engine.setStartPoint(cue.id, to: $0) }
                    .frame(width: 96)
                    .help("Type the start point (e.g. 0:12.5 or 12.5) and press Return")
                Button("Set (I)") { engine.setStartPoint(cue.id, to: engine.livePlayhead(cue.id)) }
                    .help("Set the start point at the playhead (I)")
            }

            HStack(spacing: 4) {
                Text("End").font(.caption).foregroundStyle(.red)
                TimecodeField(seconds: cue.segmentEnd) { engine.setEndPoint(cue.id, to: $0) }
                    .frame(width: 96)
                    .help("Type the end point (e.g. 2:10 or 130) and press Return")
                Button("Set (O)") { engine.setEndPoint(cue.id, to: engine.livePlayhead(cue.id)) }
                    .help("Set the end point at the playhead (O)")
                Button("Reset") { engine.clearStartEnd(cue.id) }
                    .disabled(cue.inPoint == 0 && cue.outPoint == 0)
                    .help("Play the whole file again")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// One audio stream in the bottom panel: its name and routing on the left,
/// one waveform lane per channel (or one combined lane when collapsed).
struct WaveformTrackGroup: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    let track: AudioTrackInfo
    let channelPeaks: [[Float]?]
    @Binding var collapsed: Bool

    private var routeLabel: String {
        switch cue.blockStart(ofTrack: track.index) {
        case .some(-1): return "Off"
        case .some(let s): return track.channels == 1 ? "→ \(s + 1)" : "→ \(s + 1)–\(s + track.channels)"
        case .none: return "→ custom"
        }
    }

    /// Loudest channel at every point, for the collapsed lane.
    private var combinedPeaks: [Float]? {
        let all = channelPeaks.compactMap { $0 }
        guard let first = all.first else { return nil }
        var out = first
        for p in all.dropFirst() {
            for i in 0..<min(out.count, p.count) { out[i] = max(out[i], p[i]) }
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if track.channels > 1 {
                        Button { collapsed.toggle() } label: {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 10)
                        }
                        .buttonStyle(.borderless)
                        .help(collapsed ? "Show every channel" : "Show the channels as one lane")
                    }
                    Text(track.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Text("\(track.channels) ch · \(routeLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 116, alignment: .leading)
            .padding(.top, 3)
            .help(track.displayName)

            VStack(spacing: 2) {
                if collapsed && track.channels > 1 {
                    WaveformLane(cue: cue, title: "All", subtitle: "\(track.channels) ch", peaks: combinedPeaks)
                } else {
                    ForEach(0..<track.channels, id: \.self) { c in
                        WaveformLane(cue: cue, title: track.defaultChannelName(c), subtitle: route(c),
                                     peaks: c < channelPeaks.count ? channelPeaks[c] : nil)
                    }
                }
            }
        }
        .padding(.leading, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.18)))
    }

    private func route(_ c: Int) -> String {
        guard track.index < cue.routes.count, c < cue.routes[track.index].count else { return "Off" }
        let o = cue.routes[track.index][c]
        return o >= 0 ? "→ \(o + 1)" : "Off"
    }
}

/// One channel lane: short label and the waveform.
struct WaveformLane: View {
    let cue: Cue
    let title: String
    let subtitle: String
    let peaks: [Float]?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).lineLimit(1)
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 62, alignment: .leading)
            WaveformStrip(cue: cue, peaks: peaks)
        }
        .frame(height: 30)
    }
}

/// Waveform over the whole file with start/end points and the
/// playhead. Click or drag to move the playhead.
struct WaveformStrip: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    let peaks: [Float]?

    var body: some View {
        GeometryReader { geo in
            let tl = FileTimeline(duration: cue.duration, width: geo.size.width)
            let playhead = engine.playhead(for: cue.id)
            Canvas { ctx, size in
                let mid = size.height / 2
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3),
                         with: .color(.secondary.opacity(0.12)))
                if let peaks, !peaks.isEmpty {
                    var path = Path()
                    let n = peaks.count
                    let step = max(1, n / max(Int(size.width), 1))
                    var i = 0
                    while i < n {
                        var p: Float = 0
                        for j in i..<min(i + step, n) { p = max(p, peaks[j]) }
                        let x = CGFloat(i) / CGFloat(n) * size.width
                        let h = CGFloat(min(p, 1)) * (mid - 1)
                        path.addRect(CGRect(x: x, y: mid - h, width: max(1, size.width / CGFloat(n) * CGFloat(step)),
                                            height: max(0.5, h * 2)))
                        i += step
                    }
                    ctx.fill(path, with: .color(.accentColor.opacity(0.85)))
                } else {
                    ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                             with: .color(.secondary.opacity(0.4)))
                }
                // Dim what is outside the start and end points.
                let sx = tl.x(cue.segmentStart), ex = tl.x(cue.segmentEnd)
                let shade = GraphicsContext.Shading.color(Color(nsColor: .windowBackgroundColor).opacity(0.65))
                if sx > 0 { ctx.fill(Path(CGRect(x: 0, y: 0, width: sx, height: size.height)), with: shade) }
                if ex < size.width { ctx.fill(Path(CGRect(x: ex, y: 0, width: size.width - ex, height: size.height)), with: shade) }
                ctx.fill(Path(CGRect(x: sx - 0.5, y: 0, width: 1, height: size.height)), with: .color(.green))
                ctx.fill(Path(CGRect(x: ex - 0.5, y: 0, width: 1, height: size.height)), with: .color(.red.opacity(0.8)))

                if let playhead {
                    let x = tl.x(playhead)
                    ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.red))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if abs(v.translation.width) > 2 {
                            engine.scrub(cue.id, toFile: tl.time(v.location.x))
                        }
                    }
                    .onEnded { v in
                        engine.seek(cue.id, toFile: tl.time(v.location.x))
                    }
            )
        }
    }
}

// MARK: - Output names editor

struct OutputNamesSheet: View {
    @EnvironmentObject var engine: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output channel names").font(.title3.weight(.semibold))
            Text("Names are saved for this audio device and shown in all routing menus.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 8) {
                    ForEach(0..<max(engine.routingChannels, 1), id: \.self) { i in
                        HStack {
                            Text("\(i + 1)").monospacedDigit().frame(width: 28, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            TextField("Output \(i + 1)", text: Binding(
                                get: { engine.customOutputName(i) },
                                set: { engine.setOutputName(i, $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 200, maxHeight: 420)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// The newest frame of the livestream, renewed every 15 seconds.
struct LivePreview: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Current picture of the livestream")
        .task(id: cue.id) {
            while !Task.isCancelled {
                if let frame = await engine.streamPreview(for: cue, at: 0) { image = frame }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}

/// Thin bar for BCC Media cues: the whole video, the loaded part in blue,
/// start/end points and the playhead. Click or drag to jump.
struct StreamLoadBar: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue

    var body: some View {
        GeometryReader { geo in
            let tl = FileTimeline(duration: cue.duration, width: geo.size.width)
            let playhead = engine.playhead(for: cue.id)
            Canvas { ctx, size in
                let h = size.height, y = (size.height - h) / 2
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: h), cornerRadius: h / 2),
                         with: .color(.secondary.opacity(0.18)))
                if let b = engine.streamBuffered[cue.id] {
                    let bx = tl.x(b.lowerBound)
                    ctx.fill(Path(roundedRect: CGRect(x: bx, y: y, width: max(0, tl.x(b.upperBound) - bx), height: h),
                                  cornerRadius: h / 2), with: .color(.accentColor.opacity(0.55)))
                }
                let sx = tl.x(cue.segmentStart), ex = tl.x(cue.segmentEnd)
                let shade = GraphicsContext.Shading.color(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                if sx > 0 { ctx.fill(Path(CGRect(x: 0, y: y, width: sx, height: h)), with: shade) }
                if ex < size.width { ctx.fill(Path(CGRect(x: ex, y: y, width: size.width - ex, height: h)), with: shade) }
                if let playhead {
                    ctx.fill(Path(CGRect(x: tl.x(playhead) - 1, y: 0, width: 2, height: size.height)), with: .color(.red))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if abs(v.translation.width) > 2 { engine.scrub(cue.id, toFile: tl.time(v.location.x)) }
                    }
                    .onEnded { v in engine.seek(cue.id, toFile: tl.time(v.location.x)) }
            )
        }
        .help("Loaded part of the stream. Click or drag to jump.")
    }
}
