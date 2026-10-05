# CueDeck: notes for Claude

Native macOS cue player for live shows (similar to Mitti): plays video on a
second display and routes every audio track of a file to its own output
channels (typically Dante Virtual Soundcard). Swift + SwiftUI, a C real-time
mixer, one small Objective-C helper. macOS 13+, Apple Silicon.

## Build and test

- Build: `./build.sh` (release) or `./build.sh debug`; output `build/CueDeck.app`.
  It runs `swift build`, wraps the binary in an app bundle, builds the icon
  with `iconutil` from `Resources/AppIcon-1024.png`, ad-hoc signs and
  registers the app with Launch Services.
- Mixer unit tests (any OS with a C compiler): `make -C Tests/cmixer`.
  Also run them under ThreadSanitizer after changing `Sources/CMixer`.
- Swift only compiles on macOS. If a build fails, the compiler's diagnostics
  are in `.build/out/Intermediates.noindex/CueDeck.build/Release/CueDeck-p.build/Objects-normal/arm64/CueDeck-primary.dia`
  (`strings` shows the messages).
- Package uses swift-tools-version 5.9 (Swift 5 language mode on purpose).

## Architecture

- `Sources/CMixer` (C): lock-free SPSC ring buffers, voices (one per playing
  cue, up to 16 audio tracks each), per-channel routing, gain, fades, start at
  an exact host time, scheduled stop (`cm_voice_stop_at`) and start ramp for
  crossfades. Runs on the Core Audio IO thread: never allocate, lock or block
  there. `cm_render_callback` is the AURenderCallback.
- `AudioOutput.swift`: AUHAL output unit bound to the chosen device, owns the
  mixer, compensates device latency, exposes the device clock (`CMAudioDeviceClock`).
- `AudioDecoder.swift`: one `AVAssetReader` per audio track on a background
  thread, feeding the mixer's rings. Resamples to the device rate and applies
  pitch-preserving time stretch (`AVAssetReaderAudioMixOutput`).
- `Media.swift`: file inspection and `CueTimeline` (trimmed/looped
  compositions). Video composition is unscaled; speed = AVPlayer rate. Audio
  composition is scaled to the current speed.
- `PlaybackSession.swift`: one playing cue. Works in "media time" (seconds of
  source material since the start point). Handles start at host time, pause,
  seek (rebuilds the voice), live speed change (crossfade to a re-stretched
  voice at an exact host time while the video changes rate at the same moment).
  AVPlayer uses the audio device clock as `sourceClock` so video never drifts.
- `PlaybackEngine.swift`: app state (cue list, selection incl. multi-select,
  devices, screens, output names), GO / GO + KEEP, timeline seeking, markers,
  start/end points, autosave, Finder file opening.
- `VideoOutput.swift`: borderless window on the chosen display. It must exist
  only while a cue with video plays (user requirement).
- UI: `ContentView`, `InspectorView`, `TimelineViews`, `Waveform` (bottom
  panel: whole-file ruler with start/end handles + per-channel waveforms),
  `Layouts.swift` (`FlowLayout` for wrapping in narrow windows).
  `SettingsView` (⌘,): default audio routing per stream (`RoutingDefault`).
- `Sources/ObjCSupport`: `CDCatchException`. AVFoundation raises Objective-C
  exceptions for settings it rejects, which Swift can't catch and which kill
  the app. Wrap risky AVFoundation calls (reader outputs, `canAdd`/`add`) in it.

## Things learned the hard way

- macOS 14 rejects `AVSampleRateKey` below 8000 Hz with an exception (crashed
  the app at launch). Waveforms read at 8 kHz with fallbacks.
- Only pass an `AVChannelLayoutKey` whose channel count matches the track.
- `NSWorkspace.setDefaultApplication` async label is `at:toOpen:`.
- Seeks use `Cue.seekTarget` (+¼ frame) so rounding never lands on the
  previous frame; markers are stored at frame starts (`Cue.frameStart`).
- Keyboard shortcuts (Space, ⇧Space, Esc, P, ⌫, ←/→, I, O, M) are handled
  in `AppDelegate.handleKey` and ignored while a text field or sheet is active.

## Product decisions (from the owner)

- No audio delay setting (removed on request).
- Only audio tracks (streams) can be renamed, not single channels. Output
  channels can be named per device.
- Playing several cues at once is done with GO + KEEP (⇧ Space), not a per-cue
  setting.
- Never use em dashes in user-facing text; use commas, periods or "·".
