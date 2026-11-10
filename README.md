# CueDeck

A native macOS cue player for shows: plays video on a second display and sends
every audio track of the file to its own output channels, for example through
Dante Virtual Soundcard.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode Command Line Tools: `xcode-select --install`
- Optional: `brew install ffmpeg` to import MKV, AVI, WebM and other formats
  macOS can't play natively (they are converted to ProRes, keeping all audio tracks)

## Build

```bash
cd CueDeck
./build.sh
open build/CueDeck.app
```

`./build.sh debug` builds a debug version. The first build takes a minute or two.

## Installing on another Mac

`./package.sh` builds a universal app (Apple Silicon and Intel, macOS 13 or
newer) and packs it into `build/CueDeck-<version>.dmg`.

1. Copy the DMG to the other Mac and open it.
2. In Terminal, run the install script from the DMG (drag `install.sh` from
   the DMG window into Terminal after typing `sh `):

   ```sh
   sh "/Volumes/CueDeck 0.4.1/install.sh"
   ```

   It quits CueDeck, replaces the app in Applications, removes the
   quarantine flag (the app has no Developer ID signature, so macOS would
   block it) and starts it. Cue list and settings are kept.

Without the script: drag CueDeck into Applications, then run
`xattr -dr com.apple.quarantine /Applications/CueDeck.app` once.

## Using it

1. **Pick the outputs** in the bar at the bottom:
   - **Audio output**: e.g. *Dante Virtual Soundcard*. Start DVS first. CueDeck
     uses every channel the device offers and follows the device's sample rate.
   - **Video output**: the display the video goes to. A borderless window opens
     there only while a cue with video is playing and closes as soon as nothing
     plays.
2. **Add media**: drag files onto the cue list (they are inserted where you
   drop them), or use File › Add Media (⌘I).
3. **Set each cue** in the inspector on the right:
   - Speed 0.25× to 4× (pitch preserved)
   - Volume, fade in, fade out at the end, fade when stopped
   - Start/end points to trim the file
   - When finished: stop or loop
   - **Autostart** (dropdown in the cue list): no autostart, at the end of the
     previous cue (seamlessly), or together with the previous cue. GO skips
     cues that start by themselves.
   - **Audio routing**: each audio stream has an output dropdown, right in the
     cue list (Stream 1 → 1–2, Stream 2 → 3–4, …). Changes apply
     instantly, also while playing. The routing new cues get is set in
     CueDeck › Settings (⌘,): choose the first output for each stream.
   - **Names**: streams show the name stored in the file; name the outputs
     themselves with *Output names…* in the bottom bar.
4. **Jump around**: click or drag the timeline at the
   bottom, type a time (e.g. `1:23.5`) and press Return, step frame by frame
   with ← →. While a cue isn't playing this sets where GO starts.
   **Start and end points**: drag the green and red handles in the bottom
   timeline, type a time in the Start / End fields, or press I / O to set
   them at the playhead.
5. **Change speed live** with the inspector slider or the − / + buttons in the
   transport bar.
6. **Run the show** with the keyboard:

| Key | Action |
| --- | --- |
| Space | GO: play the selected cue (fades out what is playing), select the next one |
| ⇧ Space | GO + KEEP: play the selected cue and keep everything else playing |
| ⌘Z / ⇧⌘Z | Undo / redo changes to the cue list |
| Return / Esc | Leave a text field, so Space is GO again |
| ⌥⌘L | Show mode: minimal window, editing locked |
| ⌥⌘I / ⌥⌘B | Hide or show the inspector / the timeline and waveforms |
| P | Pause / resume |
| ← / → | One frame back / forward |
| I / O | Start / end point at the playhead |
| ⌫ | Delete the selected cues (Shift-click selects a range, ⌘-click adds single cues) |
| Esc | Stop all cues with their stop fade |
| ⌘. | Panic: stop everything now and close the video output |
| ⌘S / ⌘O | Save / open a show |

The cue list is also autosaved and restored on the next launch.

## Subtitles

Without CasparCG: turn on *Show subtitles in the video output* in
CueDeck › Settings (⌘,) › Subtitles. The first subtitle track of a video
then appears at the bottom of the picture on the output display.

### Subtitles to CasparCG

Subtitles embedded in MP4 or MOV files (text tracks, as ffmpeg writes with
`-c:s mov_text`) can play on a CasparCG server in time with the cue.

1. Copy `template/caspardcg` into the template folder of the server.
2. In CueDeck › Settings (⌘,) › Subtitles, turn on *Send subtitles to
   CasparCG* and enter the server IP and port. Add as many channels as
   needed with *Add Channel*: all of them show the same subtitles, with the
   template `caspardcg/subtitle` on layer 20.
   *Send Test Subtitle* checks the connection.
3. Every cue whose file has subtitles sends its first subtitle track while
   it plays; nothing needs to be set per cue.

## Supported formats

Everything AVFoundation plays: MOV, MP4, M4V with H.264, HEVC, ProRes (incl.
4444), Apple Animation, MJPEG; audio in AAC, PCM/WAV/AIFF, ALAC, MP3, AC-3 and
others. Multiple audio tracks per file and multichannel tracks (up to 32
channels per track, 16 tracks per file) are supported.

## How it works

- **Audio** is decoded per track with `AVAssetReader` (which also resamples to
  the device rate and time-stretches for speed changes) into lock-free ring
  buffers. A real-time mixer written in C (`Sources/CMixer`) routes every
  channel to its output, applies volume and fades, and renders into a Core
  Audio output unit bound to the chosen device.
- **Video** plays in an `AVPlayer` whose clock is the audio device's clock, so
  picture and sound stay locked even over long cues. Both start at the same
  host time.
- **Speed changes** while playing crossfade the audio to a re-stretched stream
  at an exact clock time while the video changes rate at the same moment.

## Opening files from Finder

Right-click a video › Open With › CueDeck, or drop files on the Dock icon. To
make double-clicking videos open CueDeck, use CueDeck › Make CueDeck the
Default Video Player (or Finder › Get Info › Open with › Change All).

## Tests

The mixer has unit tests that run on any machine with a C compiler:

```bash
make -C Tests/cmixer
```
