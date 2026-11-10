import SwiftUI

/// Help › CueDeck Help (⌘?): the main functions, one topic per page.
enum HelpTopic: String, CaseIterable, Identifiable {
    case start, cueList, show, timeline, inspector, routing, subtitles, bcc, files, shortcuts, install
    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return "Getting Started"
        case .cueList: return "The Cue List"
        case .show: return "Running the Show"
        case .timeline: return "Timeline and Trimming"
        case .inspector: return "Playback Settings"
        case .routing: return "Audio Routing"
        case .subtitles: return "Subtitles"
        case .bcc: return "BCC Media and BCC Live"
        case .files: return "Files and Shows"
        case .shortcuts: return "Keyboard Shortcuts"
        case .install: return "Installing and Updating"
        }
    }

    var symbol: String {
        switch self {
        case .start: return "star"
        case .cueList: return "list.number"
        case .show: return "play.circle"
        case .timeline: return "timeline.selection"
        case .inspector: return "slider.horizontal.3"
        case .routing: return "hifispeaker.2"
        case .subtitles: return "captions.bubble"
        case .bcc: return "globe"
        case .files: return "doc"
        case .shortcuts: return "keyboard"
        case .install: return "arrow.down.app"
        }
    }

    /// Paragraphs; lines starting with "• " are bullets, "## " sub-headings.
    var text: [String] {
        switch self {
        case .start:
            return [
                "CueDeck plays video on a second display and sends every audio track of a file to its own output channels, for example over Dante Virtual Soundcard.",
                "## First steps",
                "• Choose the audio device and the display for the video in the bar at the bottom of the window. Output names… names the device's channels, e.g. FOH L, FOH R.",
                "• Drag video or audio files into the cue list, or use File › Add Media… (⌘I). Files are inserted where you drop them.",
                "• Select the first cue and press Space (GO). The selection moves on to the next cue, ready for the next GO.",
                "The video window on the output display only exists while a cue with video plays, so nothing stays on the screen in between.",
            ]
        case .cueList:
            return [
                "Every row is one cue. The green ▶ and the green number mark the cue GO plays next. Clicking a cue makes it the next one.",
                "## In each row",
                "• Name and, on the right, the length. While a cue plays the row turns green with a progress line and shows the time remaining (orange when paused).",
                "• One menu per audio stream: which outputs it plays on, e.g. Stream 1 · German → 1–2, or Off.",
                "• Audio only (video files): play only the sound, without opening the video output.",
                "• Autostart: No autostart (waits for GO), At end of previous cue (starts seamlessly when the cue above ends) or Together with previous cue (starts at the same moment). GO skips cues that start by themselves.",
                "## Editing",
                "• Drag cues to reorder them. Shift-click selects a range, ⌘-click adds single cues.",
                "• Delete removes the selected cues (⌫). Undo (⌘Z) brings them back.",
                "• Right-click a cue for Play, Play and Keep Others, Apply Default Routing, Show in Finder and Delete.",
            ]
        case .show:
            return [
                "## Transport",
                "• GO (Space) plays the next cue and fades out everything that is playing.",
                "• GO + KEEP (⇧Space) plays the next cue and keeps the others running.",
                "• Pause (P) pauses or resumes everything. Stop (Esc) stops all cues with their stop fade. Panic (⌘.) stops everything at once and closes the video output.",
                "• The playing cues are listed at the top with their time, a pause and stop button each, and − / + to change the speed live (the pitch stays the same).",
                "## Show Mode",
                "Show Mode (button at the top right, ⌥⌘L) gives a minimal window and locks editing: cues can't be deleted, moved, trimmed or rerouted by accident, and Undo is off. GO, Stop, Pause and Panic work as usual. It stays on after a restart.",
                "## Window",
                "• On Top keeps CueDeck in front of other windows.",
                "• The buttons under the cue list (or ⌥⌘I and ⌥⌘B) hide the inspector and the timeline. The dividers between the panels can be dragged.",
                "• After typing in a field, Return or Esc leaves it, so Space is GO again.",
            ]
        case .timeline:
            return [
                "The panel at the bottom shows the selected cue (or the one playing).",
                "## Controls",
                "• Type a time into the playhead field (e.g. 1:23.5 or 83.5) and press Return to jump there. Without the cue playing, this sets where GO starts.",
                "• ‹ › step one frame (← →), the round arrows jump 10 seconds, ⏮ goes back to the start point.",
                "• Start and End: type a time, or press Set (I / O) to use the playhead. Reset plays the whole file again. You can also drag the green and red handles on the ruler.",
                "## Lanes",
                "• The video lane shows a preview of the frame at the playhead and thumbnails of the whole file. Click or drag to jump.",
                "• Every audio stream has a box with one waveform per channel. The arrow folds a stream into one lane.",
                "• BCC Media cues show a preview frame and one bar with the part that is already loaded, instead of thumbnails and waveforms.",
            ]
        case .inspector:
            return [
                "The inspector on the right shows the settings of the selected cue. Changes to speed and volume apply at once, also while the cue plays.",
                "• Speed: 0.25× to 4×, the pitch stays the same.",
                "• Volume: -60 to +12 dB.",
                "• Fade in, Fade out (before the end) and Fade on stop (when stopped or by GO on another cue). The sliders go to 5 seconds, the fields take any length.",
                "• Audio only: no video output for this cue.",
                "• When finished: Stop, or Loop seamlessly until stopped.",
                "Under Media you see the file, its length, video size, audio streams and subtitle tracks.",
            ]
        case .routing:
            return [
                "Each audio stream (track) of a file goes to consecutive outputs: a stereo stream from output 3 plays on 3–4.",
                "• Choose the outputs in the stream's menu in the cue list, or Off.",
                "• CueDeck › Settings › Audio Routing sets the default routing new cues get, stream by stream. Automatic continues right after the previous stream (1–2, 3–4, …).",
                "• Apply Default Routing (right-click a cue) or Apply to All Cues… (Settings) sets the default routing again.",
                "• Output names… (bottom bar) names the channels of each audio device; the names appear in all menus.",
                "Streams show the name stored in the file, e.g. Stream 1 · German.",
            ]
        case .subtitles:
            return [
                "Subtitles embedded in MP4 or MOV files (the first subtitle track) and the subtitles of BCC Media and BCC Live are shown in time with the cue. Set it up in CueDeck › Settings › Subtitles.",
                "## In the video",
                "Show subtitles in the video output draws them at the bottom of the picture on the output display, for setups without CasparCG.",
                "## CasparCG",
                "• Copy the template folder caspardcg into the template folder of the CasparCG server.",
                "• Turn on Send subtitles to CasparCG and enter the server IP and port (normally 5250).",
                "• Add every channel that should show the subtitles. All channels show the same subtitles, on layer 20.",
                "• Send Test Subtitle checks the connection; errors from the server are shown below it.",
            ]
        case .bcc:
            return [
                "Episodes from app.bcc.media and the BCC livestream play straight from the internet, with every language on its own outputs and with subtitles. The Mac needs internet during the show.",
                "## Sign in",
                "File › Add BCC Media Link… (⇧⌘L) or the BCC Media button under the cue list. The first time, Sign In… shows a code: open the sign-in page on this Mac or your phone, sign in with your BCC account and confirm the code. CueDeck never sees your password. Settings › BCC Media shows the account and Sign Out.",
                "## Episodes",
                "• Paste the link of an episode, e.g. https://app.bcc.media/episode/3075, and press Add.",
                "• The cue gets two streams, German and Norwegian (only one if the episode has just one of them). Pick another language in a stream's menu and add more streams with +.",
                "• The next BCC cue is loaded ahead, so GO starts it at once. BCC cues play at 1× and don't loop.",
                "## BCC Live",
                "Add BCC Live in the same window adds the livestream of live.bcc-connect.org. It starts a few seconds behind live, shows ● LIVE and plays until it is stopped. Its languages and subtitles work like those of episodes.",
            ]
        case .files:
            return [
                "• Video: MOV, MP4 and M4V play directly, with every audio track; ProRes, H.264 and HEVC video, any number of channels per track.",
                "• Audio: WAV, AIFF, MP3, M4A/AAC and CAF play directly.",
                "• Other formats (MKV, WebM, AVI, FLAC, Ogg, …) are converted when you add them. This needs ffmpeg (brew install ffmpeg).",
                "• The cue list is saved automatically and comes back at the next start. File › Save Show (⌘S) saves it as a .cuedeck file; changes to an opened show are saved automatically. The window title shows the show's name.",
                "• CueDeck › Make CueDeck the Default Video Player opens .mov, .mp4 and .m4v files from Finder in CueDeck.",
                "• Files that can't be found are marked with a red warning in the cue list.",
            ]
        case .shortcuts:
            return []
        case .install:
            return [
                "Every version is a DMG on the GitHub releases page (kong003/cuedeck). It runs on Apple Silicon and Intel Macs with macOS 13 or newer.",
                "• Open the DMG, then run its install script in Terminal: sh \"/Volumes/CueDeck <version>/install.sh\". It quits CueDeck, replaces the app and allows it to run. Without admin rights it can use an admin account's password or install into your own Applications folder.",
                "• CueDeck is not notarized by Apple. Without the script, run xattr -dr com.apple.quarantine /Applications/CueDeck.app once after copying the app.",
                "• Cue lists and settings stay when you update. On a new Mac choose the audio device and the video display once.",
            ]
        }
    }
}

struct HelpView: View {
    @AppStorage("helpTopic") private var topic: HelpTopic = .start

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: Binding(get: { topic }, set: { if let t = $0 { topic = t } })) { t in
                Label(t.title, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(topic.title, systemImage: topic.symbol).font(.title2.weight(.semibold))
                    if topic == .shortcuts {
                        ShortcutTable()
                    } else {
                        ForEach(Array(topic.text.enumerated()), id: \.offset) { _, line in
                            paragraph(line)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private func paragraph(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(line.dropFirst(3)).font(.headline).padding(.top, 6)
        } else if line.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(line.dropFirst(2)).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(line).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// All keyboard shortcuts, grouped.
private struct ShortcutTable: View {
    private let groups: [(String, [(String, String)])] = [
        ("Show", [
            ("Space", "GO: play the next cue, fade out the others"),
            ("⇧ Space", "GO + KEEP: play the next cue, keep the others"),
            ("P", "Pause / resume everything"),
            ("Esc", "Stop all cues with their stop fade"),
            ("⌘ .", "Panic: stop everything at once"),
            ("⌥⌘ L", "Show Mode on / off"),
        ]),
        ("Editing", [
            ("← →", "One frame back / forward"),
            ("I / O", "Set the start / end point at the playhead"),
            ("⌫", "Delete the selected cues"),
            ("⌘ Z / ⇧⌘ Z", "Undo / redo"),
            ("Return / Esc", "Leave a text field (Space is GO again)"),
        ]),
        ("Files", [
            ("⌘ I", "Add media files"),
            ("⇧⌘ L", "Add a BCC Media link or BCC Live"),
            ("⌘ N", "New show"),
            ("⌘ O", "Open a show"),
            ("⌘ S / ⇧⌘ S", "Save show / save as"),
        ]),
        ("Window", [
            ("⌥⌘ I", "Hide / show the inspector"),
            ("⌥⌘ B", "Hide / show the timeline"),
            ("⌘ ,", "Settings"),
            ("⌘ ?", "This help"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show keys (Space, P, Esc, arrows, I, O, ⌫) don't act while you type in a text field or a dialog is open.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.0).font(.headline)
                    ForEach(group.1, id: \.0) { key, action in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(key)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .frame(width: 120, alignment: .leading)
                            Text(action)
                        }
                    }
                }
            }
        }
    }
}

/// Help menu: CueDeck Help and Keyboard Shortcuts open the help window.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("helpTopic") private var topic: HelpTopic = .start

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("CueDeck Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Keyboard Shortcuts") {
                topic = .shortcuts
                openWindow(id: "help")
            }
            Divider()
            Button("CueDeck Releases on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/kong003/cuedeck/releases")!)
            }
        }
    }
}
