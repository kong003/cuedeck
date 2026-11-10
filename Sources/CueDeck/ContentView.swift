import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var engine: PlaybackEngine
    @AppStorage("cueListWidth") private var cueListWidth = 480.0
    @AppStorage("bottomPanelHeight") private var bottomHeight = 220.0
    @AppStorage(LayoutKeys.inspectorHidden) private var inspectorHidden = false
    @AppStorage(LayoutKeys.bottomHidden) private var bottomHidden = false
    @AppStorage(LayoutKeys.keepInFront) private var keepInFront = false

    // Show mode always shows the minimal window.
    private var hideInspector: Bool { inspectorHidden || engine.showMode }
    private var hideBottom: Bool { bottomHidden || engine.showMode }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), max(lo, hi))
    }

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
            // Own split handles instead of HSplitView/VSplitView: the sizes only
            // change when the user drags, never because the content changes.
            GeometryReader { geo in
                let listWidth = clamp(cueListWidth, 320, geo.size.width - 400)
                let bottom = clamp(bottomHeight, 110, geo.size.height - 220)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if hideInspector {
                            CueListView()
                                .frame(maxWidth: .infinity)
                        } else {
                            CueListView()
                                .frame(width: listWidth)
                            SplitHandle(vertical: true, value: $cueListWidth, current: listWidth)
                            InspectorPane()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if !hideBottom {
                        SplitHandle(vertical: false, value: $bottomHeight, current: bottom, inverted: true)
                        WaveformPanel()
                            .frame(height: bottom)
                    }
                }
            }
            if !engine.showMode {
                Divider()
                OutputBar()
            }
        }
        // Hiding the inspector and the bottom panel allows a small window for the show.
        .frame(minWidth: hideInspector ? 600 : 1000, minHeight: hideBottom ? (engine.showMode ? 200 : 420) : 620)
        .background(WindowLevel(floating: keepInFront))
        // The show file's name, and whether the list is kept in a file.
        .sheet(isPresented: $engine.showBCCSheet) {
            BCCLinkSheet(account: engine.bcc).environmentObject(engine)
        }
        .navigationTitle(engine.showURL?.deletingPathExtension().lastPathComponent ?? "Untitled Show")
        .navigationSubtitle(engine.showURL == nil
                            ? "Not saved as a file yet (⌘S)"
                            : "Changes are saved automatically")
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

/// UserDefaults keys of the collapsible panels, shared by the window and the View menu.
enum LayoutKeys {
    static let inspectorHidden = "inspectorHidden"
    static let bottomHidden = "bottomPanelHidden"
    static let keepInFront = "keepWindowInFront"
}

/// Keeps the window above other apps' windows while `floating` is on.
struct WindowLevel: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        DispatchQueue.main.async { view.window?.level = level }
    }
}

/// A divider that can be dragged to resize the views next to it.
/// `vertical`: a vertical line dragged left/right; otherwise horizontal, dragged up/down.
/// `inverted`: dragging up/left makes `value` bigger (for a panel below or right of the handle).
struct SplitHandle: View {
    let vertical: Bool
    @Binding var value: Double
    /// The size actually shown (value after clamping), where a drag starts from.
    let current: Double
    var inverted = false
    @State private var dragStart: Double?

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                if dragStart == nil { dragStart = current }
                                let delta = vertical ? g.translation.width : g.translation.height
                                value = (dragStart ?? current) + (inverted ? -delta : delta)
                            }
                            .onEnded { _ in
                                value = current
                                dragStart = nil
                            }
                    )
            )
            .zIndex(1)
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
                .help("Hide this message")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.15))
    }
}

// MARK: - Transport

struct TransportBar: View {
    @EnvironmentObject var engine: PlaybackEngine
    @AppStorage(LayoutKeys.keepInFront) private var keepInFront = false

    private var nextName: String {
        guard let i = engine.selectedIndex else { return engine.cues.first?.name ?? "—" }
        return "\(i + 1). \(engine.cues[i].name)"
    }

    /// Width of the bar; below `wideMinimum` it uses two rows.
    @State private var barWidth: CGFloat = 1200
    private let wideMinimum: CGFloat = 920

    var body: some View {
        Group {
            if barWidth >= wideMinimum {
                // One row: GO, next cue, playing cues, transport, switches.
                HStack(alignment: .center, spacing: 14) {
                    goButtons
                    nextCue
                        .frame(minWidth: 90, idealWidth: 180, maxWidth: 200, alignment: .leading)
                    Divider().frame(height: 50)
                    NowPlayingList()
                        .frame(maxWidth: .infinity)
                    ViewThatFits(in: .horizontal) {
                        transportButtons.labelStyle(.titleAndIcon)
                        transportButtons.labelStyle(.iconOnly)
                    }
                    .controlSize(.large)
                    windowToggles.labelStyle(.titleAndIcon).frame(width: 104)
                }
            } else {
                // Narrow window: the playing cues get their own full-width row.
                VStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        goButtons
                        nextCue
                            .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                        transportButtons.labelStyle(.iconOnly)
                            .controlSize(.large)
                        windowToggles.labelStyle(.iconOnly).fixedSize()
                    }
                    NowPlayingList()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { barWidth = g.size.width }
                .onChange(of: g.size.width) { barWidth = $0 }
        })
    }

    private var goButtons: some View {
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
    }

    private var nextCue: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Next").font(.caption).foregroundStyle(.secondary)
            Text(nextName).font(.headline).lineLimit(1).truncationMode(.tail)
                .help(nextName)
        }
    }

    /// Show mode and On Top: two small switches stacked, so they take little width.
    private var windowToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $engine.showMode) {
                Label("Show Mode", systemImage: engine.showMode ? "lock.fill" : "lock.open")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(.orange)
            .help(engine.showMode
                  ? "Show mode is on: minimal window, editing locked. Click to edit again (⌥⌘L)."
                  : "Show mode: minimal window for the show, locks editing (⌥⌘L)")

            Toggle(isOn: $keepInFront) {
                Label("On Top", systemImage: keepInFront ? "pin.fill" : "pin")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help(keepInFront
                  ? "CueDeck stays in front of other windows. Click to turn off."
                  : "Keep CueDeck in front of other windows")
        }
        .toggleStyle(.button)
        .controlSize(.small)
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
                    .frame(minWidth: 60, maxWidth: 220, alignment: .leading)
                    .layoutPriority(1)
                    .help(np.name)
                Spacer(minLength: 6)

                // Drops the speed controls, then the elapsed time, when space runs out.
                // The remaining time is always shown on one line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { speedControls; times(elapsed: true) }
                    HStack(spacing: 10) { speedControls; times(elapsed: false) }
                    times(elapsed: false)
                }

                HStack(spacing: 8) {
                    Button { engine.togglePause(np.cueID) } label: {
                        Image(systemName: np.paused ? "play.fill" : "pause.fill")
                    }
                    .help(np.paused ? "Resume this cue" : "Pause this cue")
                    Button { engine.stopCue(np.cueID) } label: { Image(systemName: "stop.fill") }
                        .help("Stop this cue")
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
            ProgressView(value: min(max(np.progress, 0), 1))
                .controlSize(.small)
        }
    }

    private var speedControls: some View {
        HStack(spacing: 2) {
            Button { engine.changeSpeed(np.cueID, to: max(0.25, np.speed - 0.05)) } label: { Image(systemName: "minus") }
                .help("Slower by 0.05× (pitch stays the same)")
            Text(String(format: "%.2f×", np.speed)).monospacedDigit().frame(width: 48)
                .help("Current speed")
            Button { engine.changeSpeed(np.cueID, to: min(4, np.speed + 0.05)) } label: { Image(systemName: "plus") }
                .help("Faster by 0.05× (pitch stays the same)")
            if np.speed != 1 {
                Button("1×") { engine.changeSpeed(np.cueID, to: 1) }
                    .help("Back to normal speed")
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private func times(elapsed: Bool) -> some View {
        HStack(spacing: 8) {
            if elapsed {
                Text(formatTime(np.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                    .help("Time played")
            }
            Text("−\(formatTime(np.remaining))").monospacedDigit().font(.body.weight(.semibold))
                .help("Time remaining")
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Cue list

struct CueListView: View {
    @EnvironmentObject var engine: PlaybackEngine
    @State private var dropTargeted = false
    @AppStorage(LayoutKeys.inspectorHidden) private var inspectorHidden = false
    @AppStorage(LayoutKeys.bottomHidden) private var bottomHidden = false

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
                            if !cue.audioTracks.isEmpty && !engine.showMode {
                                Button("Apply Default Routing") { engine.resetRoutes(for: cue.id) }
                            }
                            if cue.isStream {
                                Button("Open in BCC Media") { NSWorkspace.shared.open(cue.url) }
                            } else {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([cue.url]) }
                            }
                            Divider()
                            if engine.showMode {
                                // No deleting during the show.
                            } else if engine.selectedIDs.count > 1 && engine.selectedIDs.contains(cue.id) {
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
                // Files dropped between cues are inserted there.
                .onInsert(of: [UTType.fileURL]) { index, providers in
                    loadURLs(providers) { engine.addFiles($0, at: index) }
                }
            }
            .overlay {
                // An empty list has no rows to drop between, so this hint takes the drop.
                // (It only exists while the list is empty, so it never hides rows.)
                if engine.cues.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Drop video or audio files here").font(.title3)
                        Text("or use File › Add Media… (⌘I)").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                        loadURLs(providers) { engine.addFiles($0) }
                        return true
                    }
                }
            }
            .overlay {
                if dropTargeted && engine.cues.isEmpty {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
                }
            }

            if !engine.showMode { footer }
        }
    }

    /// Reads dropped file URLs, keeping their order.
    private func loadURLs(_ providers: [NSItemProvider], then add: @escaping @MainActor ([URL]) -> Void) {
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { urls[i] = url; group.leave() }
            }
        }
        group.notify(queue: .main) {
            let found = urls.compactMap { $0 }
            if !found.isEmpty { MainActor.assumeIsolated { add(found) } }
        }
    }

    /// Add / delete and the panel toggles; hidden in show mode to save height.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button { engine.addFilesWithPanel() } label: { Label("Add Media", systemImage: "plus") }
                    .help("Add video or audio files to the cue list (⌘I). You can also drop files here.")
                Button { engine.showBCCSheet = true } label: { Label("BCC Media", systemImage: "globe") }
                    .help("Add an episode from app.bcc.media by its link (⇧⌘L)")
                Button { engine.removeSelected() } label: {
                    Label(engine.selectedIDs.count > 1 ? "Delete \(engine.selectedIDs.count)" : "Delete", systemImage: "minus")
                }
                .disabled(engine.selectedIDs.isEmpty && engine.selection == nil)
                .help("Delete the selected cues (⌫, ⌘Z to undo). Shift-click selects a range, ⌘-click adds cues.")
                Spacer()
                Text("\(engine.cues.count) cues").foregroundStyle(.secondary).font(.caption)
                panelToggles
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var panelToggles: some View {
        Group {
            Button { bottomHidden.toggle() } label: {
                Image(systemName: bottomHidden ? "rectangle.bottomthird.inset.filled" : "rectangle.split.1x2")
            }
            .help(bottomHidden ? "Show the timeline and waveforms (⌥⌘B)" : "Hide the timeline and waveforms (⌥⌘B)")
            Button { inspectorHidden.toggle() } label: {
                Image(systemName: inspectorHidden ? "sidebar.right" : "rectangle.split.2x1")
            }
            .help(inspectorHidden ? "Show the inspector (⌥⌘I)" : "Hide the inspector (⌥⌘I)")
        }
    }
}

struct CueRow: View {
    @EnvironmentObject var engine: PlaybackEngine
    let number: Int
    let cue: Cue
    let active: Bool

    /// The cue GO plays next.
    private var isNext: Bool { engine.selection == cue.id && engine.selectedIDs.count <= 1 }
    private var nowPlaying: NowPlaying? { engine.playing.last { $0.cueID == cue.id } }

    /// Remaining time while playing (green, orange when paused), else the length.
    @ViewBuilder private var timeLabel: some View {
        if let np = nowPlaying {
            Text(cue.endAction == .loop ? "∞" : "−\(formatTime(np.remaining))")
                .monospacedDigit()
                .fontWeight(.semibold)
                .foregroundStyle(np.paused ? Color.orange : Color.green)
                .fixedSize()
                .help(np.paused ? "Paused, time remaining" : "Playing, time remaining")
        } else {
            Text(cue.endAction == .loop ? "∞" : formatTime(cue.playDuration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("How long the cue plays")
        }
    }

    private var details: String {
        var parts: [String] = []
        if cue.hasVideo { parts.append(cue.videoSize.isEmpty ? "Video" : cue.videoSize) }
        if cue.speed != 1 { parts.append(String(format: "%.2g×", cue.speed)) }
        if cue.fadeIn > 0 || cue.fadeOut > 0 { parts.append("fades") }
        switch cue.endAction {
        case .loop: parts.append("loop")
        case .stop, .next: break
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                if isNext {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("GO plays this cue next")
                }
                Text("\(number)")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(isNext ? Color.green : Color.secondary)
            }
            .frame(width: 40, alignment: .trailing)
            Image(systemName: cue.isStream ? "globe" : (cue.playsVideo ? "film" : "waveform"))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: name, and the time on the right.
                HStack(spacing: 6) {
                    Text(cue.name).lineLimit(1).truncationMode(.tail)
                        .help(cue.name)
                    if cue.missing {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            .help("File not found: \(cue.url.path)")
                    }
                    Spacer(minLength: 6)
                    if active {
                        Button { engine.stopCue(cue.id) } label: {
                            Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop this cue")
                    }
                    timeLabel
                }
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // Line 2: all settings; wraps in a narrow list instead of overlapping.
                FlowLayout(spacing: 8, lineSpacing: 4) {
                    ForEach(cue.audioTracks) { track in
                        StreamRouteMenu(cue: cue, track: track, compact: true)
                            .font(.caption)
                            .disabled(engine.showMode)
                    }
                    if cue.isStream && cue.audioTracks.count < cue.streamLanguages.count {
                        Button { engine.addStream(cueID: cue.id) } label: { Image(systemName: "plus") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(engine.showMode)
                            .help("Add a stream with another language")
                    }
                    if cue.hasVideo {
                        Toggle("Audio only", isOn: Binding(
                            get: { cue.audioOnly },
                            set: { engine.setAudioOnly(cue.id, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .fixedSize()
                        .disabled(engine.showMode)
                        .help("Play only the audio of this file, without video output. Applies the next time the cue starts.")
                    }
                    AutoStartMenu(cue: cue, isFirst: number == 1)
                        .disabled(engine.showMode)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .background(alignment: .bottom) {
            // Playing cues: tinted row with a progress line.
            if let np = nowPlaying {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill((np.paused ? Color.orange : Color.green).opacity(0.14))
                    GeometryReader { g in
                        Rectangle()
                            .fill(np.paused ? Color.orange : Color.green)
                            .frame(width: g.size.width * min(max(np.progress, 0), 1), height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .padding(.horizontal, -6)
            }
        }
    }
}

/// Dropdown in the cue list: whether the cue starts by itself after or with the cue above it.
struct AutoStartMenu: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    let isFirst: Bool

    /// The first cue has no previous cue, so it always waits for GO.
    private var mode: AutoStart { isFirst ? .off : cue.autoStart }

    var body: some View {
        Menu {
            ForEach(AutoStart.allCases) { mode in
                Button { engine.setAutoStart(cue.id, mode) } label: {
                    if cue.autoStart == mode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                }
            }
        } label: {
            Label(mode.shortLabel, systemImage: mode.systemImage)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(mode == .off ? nil : Color.accentColor)
        .fixedSize()
        .disabled(isFirst)
        .help(isFirst ? "The first cue always waits for GO"
                      : "Autostart: \(mode.label). Choose whether this cue starts by itself.")
    }
}
