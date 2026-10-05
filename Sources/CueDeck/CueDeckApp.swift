import AppKit
import SwiftUI

@main
struct CueDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var engine = PlaybackEngine.shared

    var body: some Scene {
        Window("CueDeck", id: "main") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 1000, minHeight: 620)
        }
        Settings {
            SettingsView()
                .environmentObject(engine)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Show") { engine.newShow() }
                    .keyboardShortcut("n")
                Button("Open Show…") { engine.openShow() }
                    .keyboardShortcut("o")
                Divider()
                Button("Add Media…") { engine.addFilesWithPanel() }
                    .keyboardShortcut("i")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Show") { engine.saveShow() }
                    .keyboardShortcut("s")
                Button("Save Show As…") { engine.saveShowAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                // Space, P and Esc are handled by AppDelegate so they never
                // fire while typing in a text field.
                Button("GO: Play and Fade Out Others (Space)") { engine.go() }
                Button("GO + KEEP: Play Alongside Others (⇧Space)") { engine.go(keepOthers: true) }
                Button("Pause / Resume (P)") { engine.togglePause() }
                Button("Stop All with Fade (Esc)") { engine.stopAll() }
                Button("Panic: Stop Everything Now") { engine.panic() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Delete Cue (⌫)") { engine.removeSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Set Start Point at Playhead (I)") {
                    if let id = engine.selection { engine.setStartPoint(id, to: engine.livePlayhead(id)) }
                }
                Button("Set End Point at Playhead (O)") {
                    if let id = engine.selection { engine.setEndPoint(id, to: engine.livePlayhead(id)) }
                }
                Button("Add Marker at Playhead (M)") {
                    if let id = engine.selection { engine.addMarker(id) }
                }
                Button("Previous Frame (←)") { if let id = engine.selection { engine.stepFrame(id, by: -1) } }
                Button("Next Frame (→)") { if let id = engine.selection { engine.stepFrame(id, by: 1) } }
            }
            CommandGroup(after: .appSettings) {
                Button("Make CueDeck the Default Video Player") { engine.makeDefaultVideoPlayer() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = PlaybackEngine.shared
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Let text fields receive spaces, letters and backspace, and leave
        // sheets (e.g. Output names) alone.
        if NSApp.keyWindow?.firstResponder is NSText { return event }
        if NSApp.keyWindow?.isSheet == true || NSApp.keyWindow?.attachedSheet != nil { return event }
        // Never GO or delete cues from the Settings window.
        if NSApp.keyWindow?.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let engine = PlaybackEngine.shared
        if mods == .shift && event.keyCode == 49 {             // ⇧ Space: GO + KEEP
            engine.go(keepOthers: true)
            return nil
        }
        guard mods.isEmpty else { return event }
        let selected = engine.selection
        switch event.keyCode {
        case 49: engine.go(); return nil                       // Space
        case 53: engine.stopAll(); return nil                  // Esc
        case 51, 117:                                          // Backspace, forward delete
            guard selected != nil else { return event }
            engine.removeSelected()
            return nil
        case 123:                                              // ←  one frame back
            guard let id = selected else { return event }
            engine.stepFrame(id, by: -1)
            return nil
        case 124:                                              // →  one frame forward
            guard let id = selected else { return event }
            engine.stepFrame(id, by: 1)
            return nil
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p":
            engine.togglePause()
            return nil
        case "i":                                              // start point at playhead
            guard let id = selected else { return event }
            engine.setStartPoint(id, to: engine.livePlayhead(id))
            return nil
        case "o":                                              // end point at playhead
            guard let id = selected else { return event }
            engine.setEndPoint(id, to: engine.livePlayhead(id))
            return nil
        case "m":                                              // marker at playhead
            guard let id = selected else { return event }
            engine.addMarker(id)
            return nil
        default:
            return event
        }
    }

    /// Files opened from Finder: double-click (if CueDeck is the default app),
    /// Open With › CueDeck, or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        PlaybackEngine.shared.openFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PlaybackEngine.shared.shutdown()
    }
}
