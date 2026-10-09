import SwiftUI

/// CueDeck › Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            DefaultRoutingSettings()
                .tabItem { Label("Audio Routing", systemImage: "hifispeaker.2") }
            CasparSettings()
                .tabItem { Label("CasparCG", systemImage: "captions.bubble") }
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
    var body: some View { CasparSettingsForm(caspar: engine.caspar) }
}

private struct CasparSettingsForm: View {
    @ObservedObject var caspar: CasparOutput

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
                Toggle("Send subtitles to CasparCG", isOn: $caspar.enabled)
                    .help("Subtitles embedded in a video play on the CasparCG server while the cue plays")
                TextField("Server IP", text: $caspar.host, prompt: Text("192.168.1.50"))
                    .help("IP address or host name of the CasparCG server")
                TextField("Port", value: $caspar.port, format: .number.grouping(.never), prompt: Text("5250"))
                    .help("AMCP port of the server, normally 5250")
                Stepper("Channel \(caspar.channel)", value: $caspar.channel, in: 1...99)
                    .help("CasparCG channel the subtitles play on. CueDeck uses layer \(CasparOutput.layer) of it.")
                TextField("Template", text: $caspar.template, prompt: Text("caspardcg/subtitle"))
                    .help("Name of the subtitle template in the server's template folder")
            } header: {
                Text("CasparCG server")
            } footer: {
                Text("Subtitles embedded in MP4 or MOV files are sent with the template on layer \(CasparOutput.layer) of the channel, in time with the cue. Choose the subtitle language of each cue in the cue list. The template files (template/caspardcg) must be in the template folder of the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Circle().fill(statusText.1).frame(width: 8, height: 8)
                    Text(statusText.0).lineLimit(2)
                    Spacer()
                    Button("Send Test Subtitle") { caspar.test() }
                        .disabled(caspar.status != .connected)
                        .help("Shows a test subtitle on the server for 4 seconds")
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
