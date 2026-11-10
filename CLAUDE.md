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
- Installable build: `./package.sh` (universal app + DMG in `build/`). The
  Intel slice is built separately into `.build-x86` and joined with `lipo`,
  because `swift build --arch arm64 --arch x86_64` needs full Xcode.
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
  devices, screens, output names), GO / GO + KEEP, timeline seeking,
  start/end points, autosave, Finder file opening.
- `VideoOutput.swift`: borderless window on the chosen display. It must exist
  only while a cue with video plays (user requirement).
- UI: `ContentView`, `InspectorView`, `TimelineViews`, `Waveform` (bottom
  panel: whole-file ruler with start/end handles + per-channel waveforms),
  `Layouts.swift` (`FlowLayout` for wrapping in narrow windows).
  `SettingsView` (⌘,): default audio routing per stream (`RoutingDefault`)
  and the CasparCG server.
- `Caspar.swift` (`CasparOutput`): AMCP over TCP (Network framework) to a
  CasparCG server. The engine calls `update(lines)` every tick (nil = clear
  layers, [] = template loaded, no text); the same lines go to every channel
  in `channels` (one subtitle language for all, owner's decision: CasparCG
  is set only in Settings, server + port + channels, the template
  `caspardcg/subtitle` is fixed, a cue always uses its first subtitle track). Only
  changes are sent, everything is re-sent after a reconnect. Template `template/caspardcg/subtitle.html`
  (webcg): data `{"step":{"0":{"lines":[…]}}}`, shown with `CG INVOKE "show"`.
  Layer fixed at 20. `VideoOutput.setSubtitle` draws the same lines over the
  video (`SubtitleOverlay`, Settings › Subtitles) for setups without CasparCG.
  Subtitles come from tx3g tracks (`SubtitleReader` in
  `Media.swift`), timed by the session's `displayedFileTime`.
- BCC Media (`BCCMedia.swift`, `BCCMediaViews.swift`, `StreamAudio.swift`):
  device-code sign-in at login.bcc.no with the public client of the BCC
  Media tvOS app (tokens in Application Support/CueDeck/bcc-media.json,
  0600), GraphQL API api.brunstad.tv/query (header `X-Application: cuedeck`).
  Episodes stream as unencrypted HLS CMAF: one audio rendition per language,
  WebVTT subtitles. A stream cue stores only `bccEpisodeID` and the chosen
  languages (`audioTracks[].language`); links are fetched fresh per play
  (`PlaybackEngine.streamPlan`, cached while they last the whole cue).
  `StreamAudioTrack` downloads the fMP4 segments, decodes AAC with
  AVAudioConverter (sample-identical to ffmpeg) and writes into the mixer
  voice via `StreamAudioDecoder` (a `VoiceFeeder`); video is an AVPlayer on
  the master playlist, synced with `setRate(time:atHostTime:)` (works for HLS,
  measured within 1 ms). Player time = media time + `playerOffset`. The next
  stream cue is preloaded (`preloadStream`: segments into `StreamCache`,
  buffered AVPlayer handed to the session). Streams: 1× only, no loop
  (owner's decision). No thumbnail strip or waveforms for streams (would mean
  loading everything): `StreamFrameGrabber` makes the preview from one small
  segment, `StreamLoadBar` (one bar per cue, owner's wish) shows the loaded part.
- BCC Live (`LiveStream.swift`, `bccEpisodeID == "live"`): `live { url }` in the
  same API. `LiveStartPoint` picks the segment 3 behind the live edge and its
  tfdt; audio runs `StreamAudioTrack` in live mode (playlist reloads, link
  renewal); the AVPlayer loads its playlists through `LiveHLSProxy`
  (`cuedeck-live://`), which cuts them to start at that segment, so player
  time 0 = audio start (measured in sync within 1 ms). The proxy drops
  subtitles; players never draw subtitles (legible selection set to none).
  `LiveSubtitleFeed` reloads live WebVTT; times are matched to the stream
  timeline (`liveStreamTime`, MPEG-TS wrap handled).
- `Sources/ObjCSupport`: `CDCatchException`. AVFoundation raises Objective-C
  exceptions for settings it rejects, which Swift can't catch and which kill
  the app. Wrap risky AVFoundation calls (reader outputs, `canAdd`/`add`) in it.

## Things learned the hard way

- macOS 14 rejects `AVSampleRateKey` below 8000 Hz with an exception (crashed
  the app at launch). Waveforms read at 8 kHz with fallbacks.
- Only pass an `AVChannelLayoutKey` whose channel count matches the track.
- `NSWorkspace.setDefaultApplication` async label is `at:toOpen:`.
- Seeks use `Cue.seekTarget` (+¼ frame) so rounding never lands on the
  previous frame; start/end points are stored at frame starts (`Cue.frameStart`).
- Keyboard shortcuts (Space, ⇧Space, Esc, P, ⌫, ←/→, I, O) are handled
  in `AppDelegate.handleKey` and ignored while a text field or sheet is active.

## Product decisions (from the owner)

- No audio delay setting (removed on request).
- Only audio tracks (streams) can be renamed, not single channels. Output
  channels can be named per device.
- Playing several cues at once is done with GO + KEEP (⇧ Space), not a per-cue
  setting.
- Never use em dashes in user-facing text; use commas, periods or "·".
