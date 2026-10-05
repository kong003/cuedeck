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
                .help("Delete the selected cues from the list (⌫)")
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
        } else if let id = engine.selection, let cue = engine.findCue(id) {
            CueInspector(cue: Binding(
                get: { engine.findCue(id) ?? cue },
                set: { engine.updateCue($0) }
            ))
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
                    "\(cue.audioTracks.count) stream\(cue.audioTracks.count == 1 ? "" : "s"), \(cue.audioTracks.reduce(0) { $0 + $1.channels }) channels")
            }

            Section {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $cue.speed, in: 0.25...4.0)
                            .help("Speed from 0.25× to 4×, the pitch stays the same")
                        NumberField(value: $cue.speed, digits: 2, width: 56)
                            .help("Type the speed and press Return")
                        Text("×")
                    }
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                        Button(String(format: "%g×", s)) { cue.speed = s }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(cue.speed == s ? Color.accentColor : nil)
                            .help("Set the speed to \(String(format: "%g", s))×")
                    }
                }
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: $cue.volumeDB, in: -60...12)
                            .help("Volume of this cue, -60 dB (silent) to +12 dB")
                        TextField("", value: $cue.volumeDB, format: .number.precision(.fractionLength(0...1)),
                                  prompt: Text("0"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .help("Type the gain in dB (-60 to +12) and press Return")
                        Text("dB").foregroundStyle(.secondary)
                    }
                }
                SecondsRow(title: "Fade in", value: $cue.fadeIn)
                    .help("Seconds the cue fades in from silence when it starts")
                SecondsRow(title: "Fade out", value: $cue.fadeOut)
                    .disabled(cue.endAction == .loop)
                    .help("Seconds the cue fades out before it reaches its end")
                SecondsRow(title: "Fade on stop", value: $cue.stopFade)
                    .help("Seconds the cue fades out when it is stopped, e.g. by Stop or by GO on another cue")
                if cue.hasVideo {
                    Toggle("Audio only (no video output)", isOn: $cue.audioOnly)
                        .help("Play only the audio of this file. Applies the next time the cue starts.")
                }
                Picker("When finished", selection: $cue.endAction) {
                    ForEach(EndAction.selectable) { Text($0.label).tag($0) }
                }
                .help("Stop at the end, or loop seamlessly until stopped")
                LabeledContent("Plays for", value: cue.endAction == .loop ? "Until stopped" : formatTime(cue.playDuration))
            } header: {
                Text("Playback")
            } footer: {
                Text("Speed keeps the pitch. Speed and volume change instantly while the cue plays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Seconds with a slider (0 to 5 s, in 0.1 s steps) and a field for exact or longer values.
struct SecondsRow: View {
    let title: String
    @Binding var value: Double
    private let sliderMax = 5.0

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(
                    get: { min(value, sliderMax) },
                    set: { value = ($0 * 10).rounded() / 10 }
                ), in: 0...sliderMax)
                NumberField(value: $value, digits: 2, width: 64)
                    .help("Type the time in seconds and press Return, also more than 5 s")
                Text("s").foregroundStyle(.secondary)
            }
        }
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
            Text(compact ? "\(track.displayName) → \(currentLabel)" : currentLabel)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
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
                    .help("Audio device all cues play on, e.g. Dante Virtual Soundcard")
                    Button { engine.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Rescan audio devices")
                    Button("Output names…") { showNames = true }
                        .controlSize(.small)
                        .help("Name the output channels of this device, e.g. FOH L, FOH R")
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
                    .help("Display the video plays on (full screen)")
                }

                HStack(spacing: 4) {
                    Text("Master")
                    Slider(value: $engine.masterDB, in: -60...6).frame(width: 110)
                        .help("Master volume for all cues, -60 dB (silent) to +6 dB")
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
