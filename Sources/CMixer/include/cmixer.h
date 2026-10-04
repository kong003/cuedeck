// CMixer: real-time multichannel mixer for CueDeck.
//
// Threading model
//  - One "render" thread (the Core Audio IO thread) calls cm_mixer_render().
//  - One "control" thread (main thread) creates, starts, pauses, stops and
//    releases voices.
//  - One "decoder" thread per voice writes decoded PCM with cm_voice_write().
// Every ring buffer is single-producer / single-consumer and lock free.
// The render thread never allocates, locks or blocks.

#ifndef CMIXER_H
#define CMIXER_H

#include <stdint.h>
#include <stdbool.h>
#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#endif

// Nullability annotations for clang/Swift; empty for other compilers.
#if defined(__clang__)
#define CM_NULLABLE _Nullable
#define CM_NONNULL _Nonnull
#pragma clang assume_nonnull begin
#else
#define CM_NULLABLE
#define CM_NONNULL
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define CM_MAX_VOICES    16    // simultaneous cues (overlaps during fades)
#define CM_MAX_TRACKS    16    // audio tracks per cue
#define CM_MAX_TRACK_CH  32    // channels per audio track
#define CM_MAX_OUT       256   // output channels of the device

// Voice states (macros so Swift imports them as Int32, like cm_voice_state()).
#define CM_FREE      0   // slot unused
#define CM_LOADING   1   // allocated, decoder pre-filling, not audible
#define CM_ARMED     2   // will start exactly at start_host_time
#define CM_PLAYING   3
#define CM_PAUSED    4
#define CM_STOP_REQ  5   // control asked for a fade-out stop
#define CM_STOPPING  6   // fading out
#define CM_FINISHED  7   // reached the end or the stop fade completed
#define CM_FREEING   8   // being released by the control thread

typedef struct cm_mixer cm_mixer;

// host_ticks_per_second: frequency of the clock used for host times
// (mach_absolute_time ticks on macOS).
cm_mixer *CM_NULLABLE cm_mixer_create(uint32_t out_channels, double sample_rate,
                          double host_ticks_per_second);
void      cm_mixer_destroy(cm_mixer *CM_NULLABLE m);
uint32_t  cm_mixer_out_channels(const cm_mixer *m);
double    cm_mixer_sample_rate(const cm_mixer *m);
void      cm_mixer_set_master_gain(cm_mixer *m, float gain);
// Added to the host time passed to cm_mixer_render: the delay between the
// render callback's timestamp and the sound actually leaving the device
// (device latency + safety offset + user sync offset). May be negative.
void      cm_mixer_set_latency_ticks(cm_mixer *m, int64_t ticks);

// Renders `frames` frames into n_out non-interleaved float buffers.
// host_time is the host time at which the first frame will be heard.
void cm_mixer_render(cm_mixer *m, float *CM_NULLABLE const *CM_NONNULL outs, uint32_t n_out,
                     uint32_t frames, uint64_t host_time);

// Copies the peak level of each output channel since the last call into
// peaks[0..n) and resets the meters.
void cm_mixer_take_peaks(cm_mixer *m, float *peaks, uint32_t n);

// Number of buffer underruns (decoder too slow) since creation.
uint64_t cm_mixer_underruns(const cm_mixer *m);

// ---- voices -------------------------------------------------------------

// Returns a voice id >= 0, or -1 if no slot is free or the arguments are bad.
// The voice starts in CM_LOADING. All routes start as "off" (-1).
int  cm_voice_create(cm_mixer *m, uint32_t n_tracks,
                     const uint32_t *track_channels, uint32_t ring_frames);

// Route source channel src_ch of track to output channel out_ch (0 based),
// or -1 to mute it. Safe to call at any time, including while playing.
void cm_voice_set_route(cm_mixer *m, int v, uint32_t track, uint32_t src_ch,
                        int32_t out_ch);
void cm_voice_set_gain(cm_mixer *m, int v, float gain);

// total_frames: length of the cue in output frames, or <= 0 if unknown.
// Fades are in output frames, 0 = none. Call before cm_voice_start.
void cm_voice_set_envelope(cm_mixer *m, int v, int64_t total_frames,
                           int64_t fade_in_frames, int64_t fade_out_frames);

// Starting position on the cue timeline (for starting mid-cue or after a
// seek). Only allowed while the voice is CM_LOADING. Fades and the cue end
// are measured on the same timeline.
void cm_voice_set_position(cm_mixer *m, int v, int64_t position_frames);

// Fades the voice in over `frames` from the moment it starts (used for
// crossfades when a cue switches speed). Only while CM_LOADING.
void cm_voice_set_start_ramp(cm_mixer *m, int v, int64_t frames);

// Like cm_voice_stop, but the fade begins exactly at host_time.
void cm_voice_stop_at(cm_mixer *m, int v, uint64_t host_time, int64_t fade_frames);

// Decoder side.
uint32_t cm_voice_write_space(cm_mixer *m, int v, uint32_t track);
uint32_t cm_voice_buffered(cm_mixer *m, int v, uint32_t track);
uint32_t cm_voice_write(cm_mixer *m, int v, uint32_t track,
                        const float *interleaved, uint32_t frames);
void     cm_voice_set_eof(cm_mixer *m, int v, uint32_t track);

// Control side.
// LOADING or PAUSED -> ARMED. Audio starts exactly at host_time; if that
// moment has already passed, the voice skips ahead to stay in sync.
bool    cm_voice_start(cm_mixer *m, int v, uint64_t host_time);
// ARMED or PLAYING -> PAUSED.
bool    cm_voice_pause(cm_mixer *m, int v);
// Fade out over fade_frames and finish. 0 = stop at the next buffer.
void    cm_voice_stop(cm_mixer *m, int v, int64_t fade_frames);
int     cm_voice_state(cm_mixer *m, int v);
// Frames played so far, on the cue timeline.
int64_t cm_voice_position(cm_mixer *m, int v);
// Frees the voice from any state. Waits for an in-flight render cycle
// to finish, so never call it from the render thread.
void    cm_voice_release(cm_mixer *m, int v);

#ifdef __APPLE__
// Core Audio render callback (matches AURenderCallback). inRefCon must be the
// cm_mixer pointer and the unit's input format must be non-interleaved Float32.
OSStatus cm_render_callback(void *inRefCon,
                            AudioUnitRenderActionFlags *ioActionFlags,
                            const AudioTimeStamp *inTimeStamp,
                            UInt32 inBusNumber,
                            UInt32 inNumberFrames,
                            AudioBufferList *CM_NULLABLE ioData);
#endif

#if defined(__clang__)
#pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

#endif
