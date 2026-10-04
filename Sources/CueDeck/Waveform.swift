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
        guard waveforms[key] == nil, !loading.contains(key), !cue.audioTracks.isEmpty else { return }
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

    private var cue: Cue? {
        if let id = engine.selection, let c = engine.findCue(id) { return c }
        if let id = engine.playing.last?.cueID { return engine.findCue(id) }
        return nil
    }

    var body: some View {
        if let cue, cue.duration > 0 {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 10, lineSpacing: 4) {
                    Text(cue.name).font(.caption.weight(.semibold)).lineLimit(1)
                    if engine.activeCueIDs.contains(cue.id) {
                        Text("Playing").font(.caption).foregroundStyle(.green)
                    }
                    Text("Playhead \(formatTimecode(engine.playhead(for: cue.id) ?? cue.segmentStart))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("Start \(formatTimecode(cue.segmentStart)) · End \(formatTimecode(cue.segmentEnd))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button("Set Start (I)") { engine.setStartPoint(cue.id, to: engine.livePlayhead(cue.id)) }
                            .help("Set the start point at the playhead")
                        Button("Set End (O)") { engine.setEndPoint(cue.id, to: engine.livePlayhead(cue.id)) }
                            .help("Set the end point at the playhead")
                        Button("Reset") { engine.clearStartEnd(cue.id) }
                            .disabled(cue.inPoint == 0 && cue.outPoint == 0)
                            .help("Play the whole file again")
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Color.clear.frame(width: 190, height: 1)
                    TrimRuler(cue: cue)
                        .frame(height: 26)
                }

                if cue.audioTracks.isEmpty {
                    Text("This cue has no audio.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(cue.audioTracks) { track in
                                ForEach(0..<track.channels, id: \.self) { c in
                                    WaveformLane(cue: cue, track: track, channel: c,
                                                 peaks: peaks(cue, track.index, c))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: laneAreaHeight(cue))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .task(id: WaveformStore.key(for: cue)) { store.load(cue) }
        } else {
            HStack {
                Text(cue == nil ? "Select a cue to see its timeline and audio channels." : "No media information for this cue.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func peaks(_ cue: Cue, _ t: Int, _ c: Int) -> [Float]? {
        guard let w = store.waveform(for: cue), t < w.peaks.count, c < w.peaks[t].count else { return nil }
        return w.peaks[t][c]
    }

    private func laneAreaHeight(_ cue: Cue) -> CGFloat {
        let lanes = cue.audioTracks.reduce(0) { $0 + $1.channels }
        return min(CGFloat(lanes) * 36, 180)
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
                    for m in cue.markers {
                        let x = tl.x(m.time)
                        ctx.fill(Path(CGRect(x: x - 0.5, y: h * 0.25, width: 1, height: h * 0.55)), with: .color(.yellow))
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

struct WaveformLane: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    let track: AudioTrackInfo
    let channel: Int
    let peaks: [Float]?

    private var routeLabel: String {
        guard track.index < cue.routes.count, channel < cue.routes[track.index].count else { return "Off" }
        let o = cue.routes[track.index][channel]
        return o >= 0 ? engine.outputName(o) : "Off"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(track.displayName) · \(track.defaultChannelName(channel))")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("→ \(routeLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 190, alignment: .leading)

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

                    for m in cue.markers {
                        let x = tl.x(m.time)
                        ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.yellow))
                    }
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
        .frame(height: 34)
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
