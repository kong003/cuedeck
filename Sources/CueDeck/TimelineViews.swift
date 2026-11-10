import AVFoundation
import SwiftUI

// MARK: - Thumbnails

/// Loads a strip of video thumbnails (and a single preview frame) for a cue.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var preview: CGImage?

    private var key = ""
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generator: AVAssetImageGenerator?

    func load(url: URL, start: Double, end: Double, count: Int) {
        let newKey = "\(url.path)|\(start)|\(end)|\(count)"
        guard newKey != key else { return }
        key = newKey
        loadTask?.cancel()
        thumbnails = []
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        let tol = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        generator = gen
        loadTask = Task {
            var images: [CGImage] = []
            let span = max(end - start, 0.01)
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = start + span * (Double(i) + 0.5) / Double(count)
                if let result = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                    images.append(result.image)
                    thumbnails = images
                }
            }
        }
    }

    /// A sharper single frame at `seconds`, for the preview while skimming.
    func requestPreview(url: URL, at seconds: Double) {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)   // debounce while dragging
            if Task.isCancelled { return }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 640, height: 360)
            // Exact frame, so the preview matches typed times.
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            if let result = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)),
               !Task.isCancelled {
                preview = result.image
            }
        }
    }
}

// MARK: - Video lane of the bottom panel

/// Video row of the bottom panel: the frame at the playhead on the left and
/// a thumbnail strip to click or drag, aligned with the waveforms below.
struct VideoLane: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    @StateObject private var thumbs = ThumbnailStore()

    private var playhead: Double { engine.playhead(for: cue.id) ?? cue.segmentStart }
    private var isPlaying: Bool { engine.activeCueIDs.contains(cue.id) }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Color.black
                if let img = thumbs.preview {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text("Video").font(.caption.weight(.semibold))
                Text(cue.audioOnly ? "Audio only, not shown" : cue.videoSize)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(width: 102, alignment: .leading)

            ScrubBar(cue: cue, playhead: playhead, thumbnails: thumbs.thumbnails) { seconds, final in
                if final { engine.seek(cue.id, toFile: seconds) } else { engine.scrub(cue.id, toFile: seconds) }
            }
        }
        .frame(height: 48)
        .task(id: "\(cue.url.path)|\(cue.duration)") {
            guard !cue.isStream else { return }      // no thumbnails for internet streams
            thumbs.load(url: cue.url, start: 0, end: cue.duration, count: 16)
            thumbs.requestPreview(url: cue.url, at: cue.seekTarget(playhead))
        }
        .onChange(of: playhead) { p in
            if !isPlaying && !cue.isStream { thumbs.requestPreview(url: cue.url, at: cue.seekTarget(p)) }
        }
    }
}

/// Horizontal bar over the whole file. Shows thumbnails and the
/// playhead; the parts outside the start and end points are dimmed. Click
/// or drag to move the playhead.
struct ScrubBar: View {
    let cue: Cue
    let playhead: Double
    let thumbnails: [CGImage]
    /// (seconds in file, final)
    let onMove: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let tl = FileTimeline(duration: cue.duration, width: geo.size.width)
            let h = geo.size.height
            let sx = tl.x(cue.segmentStart)
            let ex = tl.x(cue.segmentEnd)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))

                if !thumbnails.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(0..<thumbnails.count, id: \.self) { i in
                            Image(decorative: thumbnails[i], scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width / CGFloat(thumbnails.count), height: h)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .opacity(0.9)
                }

                // Dim outside the start/end points
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(sx, 0), height: h)
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(geo.size.width - ex, 0), height: h)
                    .offset(x: ex)
                Rectangle().fill(Color.green).frame(width: 2, height: h).offset(x: sx - 1)
                Rectangle().fill(Color.red.opacity(0.8)).frame(width: 2, height: h).offset(x: ex - 1)

                Rectangle().fill(Color.red)
                    .frame(width: 2, height: h + 6)
                    .offset(x: min(max(tl.x(playhead), 0), geo.size.width) - 1, y: -3)
                    .shadow(radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if abs(v.translation.width) > 2 { onMove(tl.time(v.location.x), false) }
                    }
                    .onEnded { v in
                        onMove(tl.time(v.location.x), true)
                    }
            )
        }
    }
}

/// Shows the playhead time; type a new time and press Return to jump there.
struct TimecodeField: View {
    let seconds: Double
    let onCommit: (Double) -> Void
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("00:00.00", text: $text)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : Color.clear))
            .onSubmit {
                if let v = parseTimecode(text) {
                    invalid = false
                    onCommit(v)
                    focused = false   // back to the show keys (Space = GO)
                } else {
                    invalid = true
                }
            }
            .onAppear { text = formatTimecode(seconds) }
            .onChange(of: seconds) { s in
                if !focused { text = formatTimecode(s) }
            }
            .onChange(of: focused) { f in
                if !f { invalid = false; text = formatTimecode(seconds) }
            }
            .help("Type a time (e.g. 1:23.5 or 83.5) and press Return")
    }
}
