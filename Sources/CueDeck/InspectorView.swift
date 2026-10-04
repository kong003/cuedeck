import AppKit
import SwiftUI

struct InspectorPane: View {
    @EnvironmentObject var engine: PlaybackEngine

    var body: some View {
        if engine.selectedIDs.count > 1 {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "square.stack.3d.up").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("\(engine.selectedIDs.count) cues selected").font(.title3)
                Text("Press ⌫ to delete them, or click a single cue to edit it.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(role: .destructive) { engine.removeSelected() } label: {
                    Label("Delete \(engine.selectedIDs.count) Cues", systemImage: "trash")
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
        } else if let id = engine.selection, let cue = engine.findCue(id) {
            CueInspector(cue: Binding(
                get: { engine.findCue(id) ?? cue },
                set: { engine.updateCue($0) }
            ), outputChannels: engine.routingChannels)
            .id(id)
        } else {
            VStack {
                Spacer()
                Text("Select a cue").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct CueInspector: View {
    @EnvironmentObject var engine: PlaybackEngine
    @Binding var cue: Cue
    let outputChannels: Int

    var body: some View {
        Form {
            Section("Media") {
                TextField("Name", text: $cue.name)
                LabeledContent("File") {
                    Text(cue.url.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                        .help(cue.url.path)
                }
                LabeledContent("Duration", value: formatTime(cue.duration))
                LabeledContent("Video", value: cue.hasVideo ? (cue.videoSize.isEmpty ? "Yes" : cue.videoSize) : "None")
                LabeledContent("Audio", value: cue.audioTracks.isEmpty ? "None" :
                    "\(cue.audioTracks.count) stream(s), \(cue.audioTracks.reduce(0) { $0 + $1.channels }) channels")
            }

            Section("Timeline") {
                CueTimelineSection(cue: $cue)
            }

            Section {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $cue.speed, in: 0.25...4.0)
                        NumberField(value: $cue.speed, digits: 2, width: 56)
                        Text("×")
                    }
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                        Button(String(format: "%g×", s)) { cue.speed = s }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(cue.speed == s ? Color.accentColor : nil)
                    }
                }
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: $cue.volumeDB, in: -60...12)
                        TextField("0", value: $cue.volumeDB, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .help("Type the gain in dB (-60 to +12) and press Return")
                        Text("dB").foregroundStyle(.secondary)
                    }
                }
                SecondsRow(title: "Fade in", value: $cue.fadeIn)
                SecondsRow(title: "Fade out", value: $cue.fadeOut)
                    .disabled(cue.endAction == .loop)
                SecondsRow(title: "Fade on stop", value: $cue.stopFade)
                TimeRow(title: "Start point", value: $cue.inPoint, placeholder: "00:00.00")
                TimeRow(title: "End point", value: $cue.outPoint, placeholder: "end of file")
                Picker("When finished", selection: $cue.endAction) {
                    ForEach(EndAction.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Plays for", value: cue.endAction == .loop ? "Until stopped" : formatTime(cue.playDuration))
            } header: {
                Text("Playback")
            } footer: {
                Text("Speed keeps the pitch. Speed, volume and routing change instantly while the cue plays.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                RoutingEditor(cue: $cue, outputChannels: outputChannels)
            } header: {
                HStack {
                    Text("Audio routing")
                    Spacer()
                    Button("Auto-assign") { engine.resetRoutes(for: cue.id) }
                        .controlSize(.small)
                        .help("Stream 1 → outputs 1–2, stream 2 → outputs 3–4, …")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SecondsRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                NumberField(value: $value, digits: 2, width: 70)
                Text("s").foregroundStyle(.secondary)
                Stepper("", value: $value, in: 0...36000, step: 0.5).labelsHidden()
            }
        }
    }
}

/// A time in the file, typed as 1:23.5 or seconds. 0 shows the placeholder.
struct TimeRow: View {
    let title: String
    @Binding var value: Double
    let placeholder: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
                .focused($focused)
                .onSubmit(commit)
                .onAppear { text = value > 0 ? formatTimecode(value) : "" }
                .onChange(of: value) { v in if !focused { text = v > 0 ? formatTimecode(v) : "" } }
                .onChange(of: focused) { f in if !f { commit() } }
        }
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            value = 0
        } else if let v = parseTimecode(text) {
            value = v
        }
        text = value > 0 ? formatTimecode(value) : ""
    }
}

struct NumberField: View {
    @Binding var value: Double
    let digits: Int
    let width: CGFloat

    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0...digits)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .labelsHidden()
    }
}

/// Dropdown that sends a whole audio stream to consecutive outputs
/// (e.g. stream 1 → 1–2, stream 2 → 3–4).
struct StreamRouteMenu: View {
    @EnvironmentObject var engine: PlaybackEngine
    let cue: Cue
    let track: AudioTrackInfo
    var compact = false

    private var outputs: Int { max(engine.routingChannels, 1) }
    private var width: Int { max(track.channels, 1) }

    private func shortRange(_ s: Int) -> String {
        width == 1 ? "\(s + 1)" : "\(s + 1)–\(s + width)"
    }

    private var currentLabel: String {
        switch cue.blockStart(ofTrack: track.index) {
        case .some(-1): return "Off"
        case .some(let s): return compact ? shortRange(s) : engine.outputBlockName(start: s, count: width)
        case .none: return "Custom"
        }
    }

    private var streamLabel: String {
        track.name.trimmingCharacters(in: .whitespaces).isEmpty ? "S\(track.index + 1)" : track.name
    }

    var body: some View {
        Menu {
            item("Off", selected: cue.blockStart(ofTrack: track.index) == -1) { set(-1) }
            Divider()
            ForEach(Array(stride(from: 0, to: max(outputs - width + 1, 1), by: width)), id: \.self) { s in
                item(engine.outputBlockName(start: s, count: width),
                     selected: cue.blockStart(ofTrack: track.index) == s) { set(s) }
            }
            if width > 1 && outputs > width {
                Menu("Other start channel") {
                    ForEach(0..<(outputs - width + 1), id: \.self) { s in
                        if s % width != 0 {
                            item(engine.outputBlockName(start: s, count: width),
                                 selected: cue.blockStart(ofTrack: track.index) == s) { set(s) }
                        }
                    }
                }
            }
        } label: {
            Text(compact ? "\(streamLabel) → \(currentLabel)" : currentLabel)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which outputs \(track.displayName) plays on")
    }

    @ViewBuilder
    private func item(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func set(_ start: Int) {
        engine.setTrackBlock(cueID: cue.id, track: track.index, start: start)
    }
}

struct RoutingEditor: View {
    @EnvironmentObject var engine: PlaybackEngine
    @Binding var cue: Cue
    let outputChannels: Int
    @State private var expanded: Set<Int> = []

    var body: some View {
        if cue.audioTracks.isEmpty {
            Text("This file has no audio.").foregroundStyle(.secondary)
        } else {
            ForEach(cue.audioTracks) { track in
                VStack(alignment: .leading, spacing: 6) {
                    FlowLayout(spacing: 8, lineSpacing: 4) {
                        TextField(track.label, text: trackName(track.index))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                            .help("Rename this audio stream")
                        StreamRouteMenu(cue: cue, track: track)
                    }
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(track.index) },
                        set: { if $0 { expanded.insert(track.index) } else { expanded.remove(track.index) } }
                    )) {
                        ForEach(0..<track.channels, id: \.self) { c in
                            HStack {
                                Text(track.defaultChannelName(c))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Picker("", selection: route(track.index, c)) {
                                    Text("Off").tag(-1)
                                    ForEach(0..<max(outputChannels, 1), id: \.self) { o in
                                        Text(engine.outputName(o)).tag(o)
                                    }
                                }
                                .labelsHidden()
                                .frame(minWidth: 130)
                                Spacer()
                            }
                        }
                    } label: {
                        Text("\(track.channels) channel\(track.channels == 1 ? "" : "s") · \(track.label)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func trackName(_ t: Int) -> Binding<String> {
        Binding(
            get: { t < cue.audioTracks.count ? cue.audioTracks[t].name : "" },
            set: { if t < cue.audioTracks.count { cue.audioTracks[t].name = $0 } }
        )
    }

    private func route(_ track: Int, _ channel: Int) -> Binding<Int> {
        Binding(
            get: {
                guard track < cue.routes.count, channel < cue.routes[track].count else { return -1 }
                return cue.routes[track][channel]
            },
            set: { newValue in
                var routes = cue.routes
                while routes.count <= track { routes.append([]) }
                while routes[track].count <= channel { routes[track].append(-1) }
                routes[track][channel] = newValue
                cue.routes = routes
            }
        )
    }
}

// MARK: - Output settings

struct OutputBar: View {
    @EnvironmentObject var engine: PlaybackEngine
    @State private var showNames = false

    private var selectedScreen: ScreenInfo? { engine.screens.first { $0.id == engine.screenID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 16, lineSpacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "hifispeaker.2.fill")
                    Picker("Audio output", selection: $engine.deviceUID) {
                        if !engine.devices.contains(where: { $0.uid == engine.deviceUID }) {
                            Text(engine.deviceUID.isEmpty ? "None" : "Unavailable device").tag(engine.deviceUID)
                        }
                        ForEach(engine.devices) { d in
                            Text(d.menuLabel).tag(d.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    Button { engine.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Rescan audio devices")
                    Button("Output names…") { showNames = true }
                        .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Image(systemName: "display")
                    Picker("Video output", selection: $engine.screenID) {
                        ForEach(engine.screens) { s in
                            Text(s.menuLabel).tag(s.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                HStack(spacing: 4) {
                    Text("Master")
                    Slider(value: $engine.masterDB, in: -60...6).frame(width: 110)
                    TextField("0", value: $engine.masterDB, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("dB").foregroundStyle(.secondary)
                }
                .fixedSize()
            }

            HStack(spacing: 8) {
                Text(engine.outputStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if engine.screens.count < 2 {
                    Text("· Only one display connected: video will cover this screen (Esc stops).")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else if selectedScreen?.isMain == true {
                    Text("· Video output is set to the main display.").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .sheet(isPresented: $showNames) {
            OutputNamesSheet().environmentObject(engine)
        }
    }
}
