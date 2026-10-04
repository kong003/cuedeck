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

## Using it

1. **Pick the outputs** in the bar at the bottom:
   - **Audio output**: e.g. *Dante Virtual Soundcard*. Start DVS first. CueDeck
     uses every channel the device offers and follows the device's sample rate.
   - **Video output**: the display the video goes to. A borderless window opens
     there only while a cue with video is playing and closes as soon as nothing
     plays.
2. **Add media**: drag files onto the cue list, or use File › Add Media (⌘I).
3. **Set each cue** in the inspector on the right:
   - Speed 0.25× to 4× (pitch preserved)
   - Volume, fade in, fade out at the end, fade when stopped
   - Start/end points to trim the file
   - When finished: stop, play the next cue (seamlessly), or loop
   - **Audio routing**: each audio stream has an output dropdown, right in the
     cue list and in the inspector (stream 1 → 1–2, stream 2 → 3–4, …). Open
     "channels" in the inspector to route single channels. Changes apply
     instantly, also while playing.
   - **Names**: rename audio streams in the inspector; name the outputs
     themselves with *Output names…* in the bottom bar.
4. **Jump around**: click or drag the timeline in the inspector or at the
   bottom, type a time (e.g. `1:23.5`) and press Return, step frame by frame
   with ← →, or add markers (M) and click them. Markers land on the exact
   frame. While a cue isn't playing this sets where GO starts.
   **Start and end points**: drag the green and red handles in the bottom
   timeline, or press I / O to set them at the playhead.
5. **Change speed live** with the inspector slider or the − / + buttons in the
   transport bar.
6. **Run the show** with the keyboard:

| Key | Action |
| --- | --- |
| Space | GO: play the selected cue (fades out what is playing), select the next one |
| ⇧ Space | GO + KEEP: play the selected cue and keep everything else playing |
| P | Pause / resume |
| ← / → | One frame back / forward |
| I / O | Start / end point at the playhead |
| M | Marker at the playhead |
| ⌫ | Delete the selected cues (Shift-click selects a range, ⌘-click adds single cues) |
| Esc | Stop all cues with their stop fade |
| ⌘. | Panic: stop everything now and close the video output |
| ⌘S / ⌘O | Save / open a show |

The cue list is also autosaved and restored on the next launch.

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
