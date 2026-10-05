import SwiftUI

/// CueDeck › Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            DefaultRoutingSettings()
                .tabItem { Label("Audio Routing", systemImage: "hifispeaker.2") }
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
