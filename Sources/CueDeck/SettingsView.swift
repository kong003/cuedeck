import SwiftUI

/// CueDeck › Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            DefaultRoutingSettings()
                .tabItem { Label("Audio Routing", systemImage: "hifispeaker.2") }
            CasparSettings()
                .tabItem { Label("Subtitles", systemImage: "captions.bubble") }
            BCCSettings()
                .tabItem { Label("BCC Media", systemImage: "globe") }
        }
        .frame(width: 520, height: 560)
    }
}

/// Which outputs each audio stream of a new cue plays on.
struct DefaultRoutingSettings: View {
    @EnvironmentObject var engine: PlaybackEngine
    @State private var confirmApplyAll = false

    private var outputs: Int { max(engine.routingChannels, 1) }

    var body: some View {
        Form {
            Section {
                ForEach(0..<RoutingDefault.streams, id: \.self) { t in
                    Picker("Stream \(t + 1)", selection: Binding(
                        get: { engine.defaultRouting(forStream: t) },
                        set: { engine.setDefaultRouting(forStream: t, to: $0) }
                    )) {
                        Text("Automatic").tag(RoutingDefault.automatic)
                        Text("Off").tag(RoutingDefault.off)
                        Divider()
                        ForEach(0..<outputs, id: \.self) { o in
                            Text("From \(engine.outputName(o))").tag(o)
                        }
                    }
                }
            } header: {
                Text("Default routing for new cues")
            } footer: {
                Text("Each stream starts at the chosen output, its channels go to the outputs that follow (a stereo stream from output 5 plays on 5–6). Automatic continues right after the previous stream. Applies to added files and to Apply Default Routing in the context menu of a cue.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset to Automatic") { engine.defaultRouting = [] }
                        .disabled(engine.defaultRouting.isEmpty)
                        .help("Set every stream back to Automatic (1–2, 3–4, …)")
                    Spacer()
                    Button("Apply to All Cues…") { confirmApplyAll = true }
                        .disabled(engine.cues.isEmpty)
                        .help("Replace the routing of every cue in the list with this default routing")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Apply the default routing to all \(engine.cues.count) cues?",
                            isPresented: $confirmApplyAll) {
            Button("Apply to All Cues", role: .destructive) { engine.applyDefaultRoutingToAllCues() }
        } message: {
            Text("The routing you set for each cue is replaced.")
        }
    }
}

/// Where subtitles of playing cues are sent.
struct CasparSettings: View {
    @EnvironmentObject var engine: PlaybackEngine
    var body: some View { CasparSettingsForm(caspar: engine.caspar, onVideo: $engine.subtitlesOnVideo) }
}

private struct CasparSettingsForm: View {
    @ObservedObject var caspar: CasparOutput
    @Binding var onVideo: Bool

    private var statusText: (String, Color) {
        switch caspar.status {
        case .off: return (caspar.enabled ? "Enter the server address" : "Off", .secondary)
        case .connecting: return ("Connecting…", .orange)
        case .connected: return ("Connected", .green)
        case .failed(let message): return ("Not connected: \(message)", .red)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show subtitles in the video output", isOn: $onVideo)
                    .help("Draws the subtitles over the video on the output display, for setups without CasparCG")
            } header: {
                Text("Video output")
            } footer: {
                Text("Subtitles embedded in MP4 or MOV files (the first subtitle track) appear at the bottom of the video, in time with the cue.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Send subtitles to CasparCG", isOn: $caspar.enabled)
                    .help("Subtitles embedded in a video play on the CasparCG server while the cue plays")
                TextField("Server IP", text: $caspar.host, prompt: Text("192.168.1.50"))
                    .help("IP address or host name of the CasparCG server")
                TextField("Port", value: $caspar.port, format: .number.grouping(.never), prompt: Text("5250"))
                    .help("AMCP port of the server, normally 5250")
            } header: {
                Text("CasparCG server")
            } footer: {
                Text("Subtitles embedded in MP4 or MOV files are sent in time with the cue (the first subtitle track of a file). The template folder caspardcg must be in the template folder of the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(caspar.channels.indices, id: \.self) { i in
                    HStack {
                        Stepper("Channel \(caspar.channels[i])", value: Binding(
                            get: { i < caspar.channels.count ? caspar.channels[i] : 1 },
                            set: { if i < caspar.channels.count { caspar.channels[i] = $0 } }
                        ), in: 1...99)
                        .help("CasparCG channel that shows the subtitles, on layer \(CasparOutput.layer)")
                        Button { caspar.channels.remove(at: i) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(caspar.channels.count <= 1)
                        .help("Remove this channel")
                    }
                }
                Button {
                    caspar.channels.append((caspar.channels.max() ?? 0) + 1)
                } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .help("Show the same subtitles on one more channel")
            } header: {
                Text("Channels")
            } footer: {
                Text("Every channel shows the same subtitles, on layer \(CasparOutput.layer).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Circle().fill(statusText.1).frame(width: 8, height: 8)
                    Text(statusText.0).lineLimit(2)
                    Spacer()
                    Button("Send Test Subtitle") { caspar.test() }
                        .disabled(caspar.status != .connected)
                        .help("Shows a test subtitle on every channel for 4 seconds")
                }
                if let error = caspar.serverError {
                    Text("Server answered: \(error)")
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
