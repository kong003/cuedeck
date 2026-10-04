import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var engine: PlaybackEngine

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
            if let msg = engine.message {
                Banner(text: msg, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    engine.message = nil
                }
            }
            if let busy = engine.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
            }
            Divider()
            HSplitView {
                CueListView()
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                InspectorPane()
                    .frame(minWidth: 400, idealWidth: 450, maxWidth: 640, maxHeight: .infinity)
            }
            Divider()
            WaveformPanel()
            Divider()
            OutputBar()
        }
        .onChange(of: engine.message) { msg in
            guard let msg else { return }
            let e = engine
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if e.message == msg { e.message = nil }
            }
        }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.15))
    }
}

// MARK: - Transport

struct TransportBar: View {
    @EnvironmentObject var engine: PlaybackEngine

    private var nextName: String {
        guard let i = engine.selectedIndex else { return engine.cues.first?.name ?? "—" }
        return "\(i + 1). \(engine.cues[i].name)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Button { engine.go() } label: {
                    VStack(spacing: 2) {
                        Text("GO").font(.system(size: 26, weight: .heavy))
                        Text("Space").font(.caption2).opacity(0.85)
                    }
                    .frame(width: 92, height: 58)
                }
                .buttonStyle(GoButtonStyle(color: .green))
                .help("Play the selected cue and fade out everything that is playing (Space)")

                Button { engine.go(keepOthers: true) } label: {
                    VStack(spacing: 2) {
                        Text("GO + KEEP").font(.system(size: 13, weight: .heavy))
                        Text("⇧ Space").font(.caption2).opacity(0.85)
                    }
                    .frame(width: 92, height: 58)
                }
                .buttonStyle(GoButtonStyle(color: .blue))
                .help("Play the selected cue and keep everything else playing (⇧ Space)")
            }
            .disabled(engine.cues.isEmpty)
            .fixedSize()

            VStack(alignment: .leading, spacing: 4) {
                Text("Next").font(.caption).foregroundStyle(.secondary)
                Text(nextName).font(.headline).lineLimit(1).truncationMode(.tail)
            }
            .frame(minWidth: 90, idealWidth: 180, maxWidth: 200, alignment: .leading)

            Divider().frame(height: 50)

            NowPlayingList()
                .frame(maxWidth: .infinity)

            ViewThatFits(in: .horizontal) {
                transportButtons.labelStyle(.titleAndIcon)
                transportButtons.labelStyle(.iconOnly)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var transportButtons: some View {
        HStack(spacing: 8) {
            Button {
                engine.togglePause()
            } label: {
                Label(engine.isAnythingPlaying || engine.playing.isEmpty ? "Pause" : "Resume",
                      systemImage: engine.isAnythingPlaying || engine.playing.isEmpty ? "pause.fill" : "play.fill")
            }
            .help("Pause or resume everything (P)")
            .disabled(engine.playing.isEmpty)

            Button {
                engine.stopAll()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop all cues with their stop fade (Esc)")

            Button(role: .destructive) {
                engine.panic()
            } label: {
                Label("Panic", systemImage: "exclamationmark.octagon.fill")
            }
            .help("Stop everything immediately and close the video output (⌘.)")
        }
    }
}

struct GoButtonStyle: ButtonStyle {
    var color: Color = .green
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isEnabled ? color.opacity(configuration.isPressed ? 0.7 : 0.9) : Color.gray.opacity(0.4))
            )
    }
}

/// Every playing cue with its time, live speed control, pause and stop.
struct NowPlayingList: View {
    @EnvironmentObject var engine: PlaybackEngine

    var body: some View {
        if engine.playing.isEmpty {
            HStack {
                Text("Nothing playing").foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            VStack(spacing: 4) {
                ForEach(engine.playing.suffix(3)) { np in
                    NowPlayingRow(np: np)
                }
                if engine.playing.count > 3 {
                    Text("+ \(engine.playing.count - 3) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct NowPlayingRow: View {
    @EnvironmentObject var engine: PlaybackEngine
    let np: NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: np.paused ? "pause.circle.fill" : (np.stopping ? "speaker.wave.1.fill" : "play.circle.fill"))
                    .foregroundStyle(np.paused ? Color.orange : Color.green)
                Text(np.name).font(.headline).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1)
                Spacer(minLength: 6)

                // Live speed
                HStack(spacing: 2) {
                    Button { engine.changeSpeed(np.cueID, to: max(0.25, np.speed - 0.05)) } label: { Image(systemName: "minus") }
                    Text(String(format: "%.2f×", np.speed)).monospacedDigit().frame(width: 48)
                    Button { engine.changeSpeed(np.cueID, to: min(4, np.speed + 0.05)) } label: { Image(systemName: "plus") }
                    if np.speed != 1 {
                        Button("1×") { engine.changeSpeed(np.cueID, to: 1) }
                    }
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Change the speed while playing")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(formatTime(np.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                        Text("−\(formatTime(np.remaining))").monospacedDigit().font(.body.weight(.semibold))
                    }
                    Text("−\(formatTime(np.remaining))").monospacedDigit().font(.body.weight(.semibold))
                }

                Button { engine.togglePause(np.cueID) } label: {
                    Image(systemName: np.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(np.paused ? "Resume this cue" : "Pause this cue")
                Button { engine.stopCue(np.cueID) } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop this cue")
            }
            ProgressView(value: min(max(np.progress, 0), 1))
                .controlSize(.small)
        }
    }
}

// MARK: - Cue list

struct CueListView: View {
    @EnvironmentObject var engine: PlaybackEngine
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $engine.selectedIDs) {
                ForEach(Array(engine.cues.enumerated()), id: \.element.id) { index, cue in
                    CueRow(number: index + 1, cue: cue, active: engine.activeCueIDs.contains(cue.id))
                        .contextMenu {
                            Button("Play (fade out others)") { engine.play(cue.id) }
                            Button("Play and Keep Others") { engine.play(cue.id, keepOthers: true) }
                            if engine.activeCueIDs.contains(cue.id) {
                                Button("Stop") { engine.stopCue(cue.id) }
                            }
                            Divider()
                            Button("Reload Media Info") { engine.reinspect(cue.id) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([cue.url]) }
                            Divider()
                            if engine.selectedIDs.count > 1 && engine.selectedIDs.contains(cue.id) {
                                Button("Delete \(engine.selectedIDs.count) Cues", role: .destructive) {
                                    engine.removeSelected()
                                }
                            } else {
                                Button("Delete", role: .destructive) {
                                    engine.removeCues([cue.id])
                                }
                            }
                        }
                }
                .onMove { engine.moveCues(from: $0, to: $1) }
            }
            .overlay {
                if engine.cues.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Drop video or audio files here").font(.title3)
                        Text("or use File › Add Media… (⌘I)").foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in PlaybackEngine.shared.addFiles([url]) }
                    }
                }
                return true
            }

            Divider()
            HStack {
                Button { engine.addFilesWithPanel() } label: { Label("Add Media", systemImage: "plus") }
                Button { engine.removeSelected() } label: {
                    Label(engine.selectedIDs.count > 1 ? "Remove \(engine.selectedIDs.count)" : "Remove", systemImage: "minus")
                }
                .disabled(engine.selectedIDs.isEmpty && engine.selection == nil)
                .help("Delete the selected cues (⌫). Shift-click selects a range, ⌘-click adds cues.")
                Spacer()
                Text("\(engine.cues.count) cues").foregroundStyle(.secondary).font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

struct CueRow: View {
    @EnvironmentObject var engine: PlaybackEngine
    let number: Int
    let cue: Cue
    let active: Bool

    private var details: String {
        var parts: [String] = []
        if cue.hasVideo { parts.append(cue.videoSize.isEmpty ? "Video" : cue.videoSize) }
        if cue.speed != 1 { parts.append(String(format: "%.2g×", cue.speed)) }
        if cue.fadeIn > 0 || cue.fadeOut > 0 { parts.append("fades") }
        switch cue.endAction {
        case .loop: parts.append("loop")
        case .next: parts.append("→ next")
        case .stop: break
        }
        if !cue.markers.isEmpty { parts.append("\(cue.markers.count) marker\(cue.markers.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(width: 28, alignment: .trailing)
                .foregroundStyle(.secondary)
            Image(systemName: cue.hasVideo ? "film" : "waveform")
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(cue.name).lineLimit(1)
                    if cue.missing {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            .help("File not found: \(cue.url.path)")
                    }
                }
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !cue.audioTracks.isEmpty {
                    // One output dropdown per audio stream.
                    FlowLayout(spacing: 10, lineSpacing: 2) {
                        ForEach(cue.audioTracks) { track in
                            StreamRouteMenu(cue: cue, track: track, compact: true)
                                .font(.caption)
                        }
                    }
                }
            }
            Spacer()
            if active {
                Button { engine.stopCue(cue.id) } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop this cue")
            }
            Text(cue.endAction == .loop ? "∞" : formatTime(cue.playDuration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, 3)
    }
}
