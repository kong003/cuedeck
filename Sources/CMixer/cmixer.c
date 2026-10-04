#include "cmixer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif

#define CM_ENV_CHUNK 1024

// ---- float atomics (stored as bit patterns) ------------------------------

static inline uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

// ---- ring buffer --------------------------------------------------------

typedef struct {
    float *data;               // capacity * channels, interleaved
    uint32_t capacity;         // frames
    uint32_t channels;
    _Atomic uint64_t wpos;     // total frames written
    _Atomic uint64_t rpos;     // total frames consumed
    _Atomic int eof;
    int64_t debt;              // render only: frames to discard (after underrun)
    _Atomic int32_t route[CM_MAX_TRACK_CH];
} cm_track;

typedef struct {
    _Atomic int state;
    uint32_t n_tracks;
    cm_track tracks[CM_MAX_TRACKS];

    _Atomic uint32_t gain_bits;
    int64_t total_frames;
    int64_t fade_in;
    int64_t fade_out;

    _Atomic uint64_t start_host;
    _Atomic int64_t stop_fade;   // frames, written before STOP_REQ
    int64_t mfade_start;         // render only
    _Atomic int64_t pos;         // frames played
    _Atomic uint64_t stop_host;  // scheduled stop (0 = none)
    _Atomic int64_t stop_at_fade;
    int64_t ramp_len;            // fade-in from first rendered frame
    int64_t played;              // render only: frames rendered since start
} cm_voice;

struct cm_mixer {
    uint32_t out_channels;
    double rate;
    double ticks_per_sec;
    _Atomic int64_t latency_ticks;
    _Atomic uint32_t master_bits;
    _Atomic uint64_t epoch;      // odd while a render cycle is running
    _Atomic uint64_t underruns;
    _Atomic uint32_t peaks[CM_MAX_OUT];
    float env[CM_ENV_CHUNK];     // render scratch
    cm_voice voices[CM_MAX_VOICES];
};

static void sleep_ms(int ms) {
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

// ---- mixer --------------------------------------------------------------

cm_mixer *cm_mixer_create(uint32_t out_channels, double sample_rate,
                          double host_ticks_per_second) {
    if (out_channels == 0 || out_channels > CM_MAX_OUT) return NULL;
    if (sample_rate <= 0 || host_ticks_per_second <= 0) return NULL;
    cm_mixer *m = (cm_mixer *)calloc(1, sizeof(cm_mixer));
    if (!m) return NULL;
    m->out_channels = out_channels;
    m->rate = sample_rate;
    m->ticks_per_sec = host_ticks_per_second;
    atomic_store(&m->master_bits, f2u(1.0f));
    for (int i = 0; i < CM_MAX_VOICES; i++) atomic_store(&m->voices[i].state, CM_FREE);
    return m;
}

static void free_voice_memory(cm_voice *v) {
    for (uint32_t t = 0; t < CM_MAX_TRACKS; t++) {
        free(v->tracks[t].data);
        v->tracks[t].data = NULL;
    }
}

void cm_mixer_destroy(cm_mixer *m) {
    if (!m) return;
    for (int i = 0; i < CM_MAX_VOICES; i++) free_voice_memory(&m->voices[i]);
    free(m);
}

uint32_t cm_mixer_out_channels(const cm_mixer *m) { return m->out_channels; }
double cm_mixer_sample_rate(const cm_mixer *m) { return m->rate; }

void cm_mixer_set_master_gain(cm_mixer *m, float gain) {
    atomic_store(&m->master_bits, f2u(gain));
}

void cm_mixer_set_latency_ticks(cm_mixer *m, int64_t ticks) {
    atomic_store(&m->latency_ticks, ticks);
}

uint64_t cm_mixer_underruns(const cm_mixer *m) {
    return atomic_load(&((cm_mixer *)m)->underruns);
}

void cm_mixer_take_peaks(cm_mixer *m, float *peaks, uint32_t n) {
    for (uint32_t c = 0; c < n; c++) {
        peaks[c] = c < CM_MAX_OUT ? u2f(atomic_exchange(&m->peaks[c], 0)) : 0.0f;
    }
}

// ---- voices: control / decoder side ------------------------------------

static cm_voice *voice_at(cm_mixer *m, int v) {
    if (!m || v < 0 || v >= CM_MAX_VOICES) return NULL;
    return &m->voices[v];
}

int cm_voice_create(cm_mixer *m, uint32_t n_tracks,
                    const uint32_t *track_channels, uint32_t ring_frames) {
    if (!m || n_tracks > CM_MAX_TRACKS || ring_frames < 64) return -1;
    for (uint32_t t = 0; t < n_tracks; t++) {
        if (track_channels[t] == 0 || track_channels[t] > CM_MAX_TRACK_CH) return -1;
    }
    for (int i = 0; i < CM_MAX_VOICES; i++) {
        cm_voice *v = &m->voices[i];
        int expected = CM_FREE;
        if (!atomic_compare_exchange_strong(&v->state, &expected, CM_LOADING)) continue;

        v->n_tracks = n_tracks;
        v->total_frames = 0;
        v->fade_in = 0;
        v->fade_out = 0;
        v->mfade_start = 0;
        atomic_store(&v->gain_bits, f2u(1.0f));
        atomic_store(&v->start_host, 0);
        atomic_store(&v->stop_fade, 0);
        atomic_store(&v->pos, 0);
        atomic_store(&v->stop_host, 0);
        atomic_store(&v->stop_at_fade, 0);
        v->ramp_len = 0;
        v->played = 0;
        for (uint32_t t = 0; t < CM_MAX_TRACKS; t++) {
            cm_track *tr = &v->tracks[t];
            free(tr->data);
            tr->data = NULL;
            tr->capacity = 0;
            tr->channels = 0;
            tr->debt = 0;
            atomic_store(&tr->wpos, 0);
            atomic_store(&tr->rpos, 0);
            atomic_store(&tr->eof, 0);
            for (int c = 0; c < CM_MAX_TRACK_CH; c++) atomic_store(&tr->route[c], -1);
            if (t < n_tracks) {
                tr->channels = track_channels[t];
                tr->capacity = ring_frames;
                tr->data = (float *)calloc((size_t)ring_frames * tr->channels, sizeof(float));
                if (!tr->data) {
                    free_voice_memory(v);
                    atomic_store(&v->state, CM_FREE);
                    return -1;
                }
            }
        }
        return i;
    }
    return -1;
}

void cm_voice_set_route(cm_mixer *m, int v, uint32_t track, uint32_t src_ch,
                        int32_t out_ch) {
    cm_voice *vo = voice_at(m, v);
    if (!vo || track >= vo->n_tracks || src_ch >= CM_MAX_TRACK_CH) return;
    if (out_ch >= (int32_t)m->out_channels) out_ch = -1;
    atomic_store(&vo->tracks[track].route[src_ch], out_ch < 0 ? -1 : out_ch);
}

void cm_voice_set_gain(cm_mixer *m, int v, float gain) {
    cm_voice *vo = voice_at(m, v);
    if (vo) atomic_store(&vo->gain_bits, f2u(gain));
}

void cm_voice_set_envelope(cm_mixer *m, int v, int64_t total_frames,
                           int64_t fade_in_frames, int64_t fade_out_frames) {
    cm_voice *vo = voice_at(m, v);
    if (!vo) return;
    vo->total_frames = total_frames > 0 ? total_frames : 0;
    vo->fade_in = fade_in_frames > 0 ? fade_in_frames : 0;
    vo->fade_out = fade_out_frames > 0 ? fade_out_frames : 0;
    atomic_thread_fence(memory_order_release);
}

void cm_voice_set_position(cm_mixer *m, int v, int64_t position_frames) {
    cm_voice *vo = voice_at(m, v);
    if (!vo || atomic_load(&vo->state) != CM_LOADING) return;
    atomic_store(&vo->pos, position_frames > 0 ? position_frames : 0);
}

void cm_voice_set_start_ramp(cm_mixer *m, int v, int64_t frames) {
    cm_voice *vo = voice_at(m, v);
    if (!vo || atomic_load(&vo->state) != CM_LOADING) return;
    vo->ramp_len = frames > 0 ? frames : 0;
    atomic_thread_fence(memory_order_release);
}

void cm_voice_stop_at(cm_mixer *m, int v, uint64_t host_time, int64_t fade_frames) {
    cm_voice *vo = voice_at(m, v);
    if (!vo) return;
    atomic_store(&vo->stop_at_fade, fade_frames > 0 ? fade_frames : 0);
    atomic_store(&vo->stop_host, host_time > 0 ? host_time : 1);
}

uint32_t cm_voice_write_space(cm_mixer *m, int v, uint32_t track) {
    cm_voice *vo = voice_at(m, v);
    if (!vo || track >= vo->n_tracks) return 0;
    cm_track *tr = &vo->tracks[track];
    uint64_t used = atomic_load(&tr->wpos) - atomic_load(&tr->rpos);
    return used >= tr->capacity ? 0 : (uint32_t)(tr->capacity - used);
}

uint32_t cm_voice_buffered(cm_mixer *m, int v, uint32_t track) {
    cm_voice *vo = voice_at(m, v);
    if (!vo || track >= vo->n_tracks) return 0;
    cm_track *tr = &vo->tracks[track];
    return (uint32_t)(atomic_load(&tr->wpos) - atomic_load(&tr->rpos));
}

uint32_t cm_voice_write(cm_mixer *m, int v, uint32_t track,
                        const float *src, uint32_t frames) {
    cm_voice *vo = voice_at(m, v);
    if (!vo || track >= vo->n_tracks) return 0;
    cm_track *tr = &vo->tracks[track];
    uint32_t space = cm_voice_write_space(m, v, track);
    if (frames > space) frames = space;
    if (frames == 0) return 0;
    uint64_t w = atomic_load_explicit(&tr->wpos, memory_order_relaxed);
    uint32_t ch = tr->channels;
    uint32_t start = (uint32_t)(w % tr->capacity);
    uint32_t first = tr->capacity - start;
    if (first > frames) first = frames;
    memcpy(tr->data + (size_t)start * ch, src, (size_t)first * ch * sizeof(float));
    if (frames > first) {
        memcpy(tr->data, src + (size_t)first * ch,
               (size_t)(frames - first) * ch * sizeof(float));
    }
    atomic_store_explicit(&tr->wpos, w + frames, memory_order_release);
    return frames;
}

void cm_voice_set_eof(cm_mixer *m, int v, uint32_t track) {
    cm_voice *vo = voice_at(m, v);
    if (vo && track < vo->n_tracks) atomic_store(&vo->tracks[track].eof, 1);
}

bool cm_voice_start(cm_mixer *m, int v, uint64_t host_time) {
    cm_voice *vo = voice_at(m, v);
    if (!vo) return false;
    atomic_store(&vo->start_host, host_time);
    int s = CM_LOADING;
    if (atomic_compare_exchange_strong(&vo->state, &s, CM_ARMED)) return true;
    s = CM_PAUSED;
    return atomic_compare_exchange_strong(&vo->state, &s, CM_ARMED);
}

bool cm_voice_pause(cm_mixer *m, int v) {
    cm_voice *vo = voice_at(m, v);
    if (!vo) return false;
    int s = CM_PLAYING;
    if (atomic_compare_exchange_strong(&vo->state, &s, CM_PAUSED)) return true;
    s = CM_ARMED;
    return atomic_compare_exchange_strong(&vo->state, &s, CM_PAUSED);
}

void cm_voice_stop(cm_mixer *m, int v, int64_t fade_frames) {
    cm_voice *vo = voice_at(m, v);
    if (!vo) return;
    atomic_store(&vo->stop_fade, fade_frames > 0 ? fade_frames : 0);
    for (;;) {
        int s = atomic_load(&vo->state);
        int next;
        switch (s) {
            case CM_PLAYING:
                next = fade_frames > 0 ? CM_STOP_REQ : CM_FINISHED;
                break;
            case CM_STOPPING:
                // Already fading. Only shorten to an immediate stop.
                if (fade_frames > 0) return;
                next = CM_FINISHED;
                break;
            case CM_LOADING:
            case CM_ARMED:
            case CM_PAUSED:
            case CM_STOP_REQ:
                next = CM_FINISHED;
                break;
            default:
                return;
        }
        if (atomic_compare_exchange_strong(&vo->state, &s, next)) return;
    }
}

int cm_voice_state(cm_mixer *m, int v) {
    cm_voice *vo = voice_at(m, v);
    return vo ? atomic_load(&vo->state) : CM_FREE;
}

int64_t cm_voice_position(cm_mixer *m, int v) {
    cm_voice *vo = voice_at(m, v);
    return vo ? atomic_load(&vo->pos) : 0;
}

void cm_voice_release(cm_mixer *m, int v) {
    cm_voice *vo = voice_at(m, v);
    if (!vo) return;
    int prev = atomic_exchange(&vo->state, CM_FREEING);
    if (prev == CM_FREE) {
        atomic_store(&vo->state, CM_FREE);
        return;
    }
    // Wait for a render cycle that may have seen the old state to finish.
    uint64_t e = atomic_load(&m->epoch);
    if (e & 1) {
        for (int i = 0; i < 500 && atomic_load(&m->epoch) == e; i++) sleep_ms(1);
    }
    free_voice_memory(vo);
    vo->n_tracks = 0;
    atomic_store(&vo->state, CM_FREE);
}

// ---- render side --------------------------------------------------------

static inline float curve(float t) {
    if (t <= 0.0f) return 0.0f;
    if (t >= 1.0f) return 1.0f;
    return t * t;
}

// Discards up to `frames` frames from every track (used to catch up when a
// voice starts late). Frames that are not decoded yet become debt.
static void skip_frames(cm_voice *v, int64_t frames) {
    for (uint32_t t = 0; t < v->n_tracks; t++) {
        cm_track *tr = &v->tracks[t];
        tr->debt += frames;
    }
    atomic_store_explicit(&v->pos, atomic_load_explicit(&v->pos, memory_order_relaxed) + frames,
                          memory_order_relaxed);
}

static void pay_debt(cm_track *tr) {
    if (tr->debt <= 0) return;
    uint64_t r = atomic_load_explicit(&tr->rpos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&tr->wpos, memory_order_acquire);
    uint64_t avail = w - r;
    uint64_t take = (uint64_t)tr->debt < avail ? (uint64_t)tr->debt : avail;
    tr->debt -= (int64_t)take;
    atomic_store_explicit(&tr->rpos, r + take, memory_order_release);
}

// Mixes frames [from, to) of the output buffer. Returns true if the voice
// reached its end inside this range.
static bool process_voice(cm_mixer *m, cm_voice *v, int state,
                          float *CM_NULLABLE const *CM_NONNULL outs, uint32_t n_out,
                          uint32_t from, uint32_t to) {
    const float gain = u2f(atomic_load_explicit(&v->gain_bits, memory_order_relaxed));
    int64_t pos = atomic_load_explicit(&v->pos, memory_order_relaxed);
    const int64_t total = v->total_frames;
    const int64_t mfade = atomic_load_explicit(&v->stop_fade, memory_order_relaxed);
    bool ended = false;

    uint32_t i = from;
    while (i < to && !ended) {
        uint32_t n = to - i;
        if (n > CM_ENV_CHUNK) n = CM_ENV_CHUNK;

        // Envelope for this chunk; stops at the end of the cue.
        uint32_t e = 0;
        for (; e < n; e++) {
            int64_t p = pos + e;
            if (total > 0 && p >= total) { ended = true; break; }
            float g = gain;
            if (v->fade_in > 0 && p < v->fade_in) g *= curve((float)p / (float)v->fade_in);
            if (total > 0 && v->fade_out > 0 && p > total - v->fade_out)
                g *= curve((float)(total - p) / (float)v->fade_out);
            if (state == CM_STOPPING && p >= v->mfade_start) {
                if (mfade <= 0 || p - v->mfade_start >= mfade) { ended = true; break; }
                g *= curve(1.0f - (float)(p - v->mfade_start) / (float)mfade);
            }
            if (v->ramp_len > 0 && v->played + (int64_t)e < v->ramp_len) {
                // complementary curve to the t^2 fade-out: constant power-ish crossfade
                float r = 1.0f - (float)(v->played + (int64_t)e) / (float)v->ramp_len;
                g *= 1.0f - r * r;
            }
            m->env[e] = g;
        }

        bool all_drained = v->n_tracks > 0;
        for (uint32_t t = 0; t < v->n_tracks; t++) {
            cm_track *tr = &v->tracks[t];
            pay_debt(tr);
            uint64_t r = atomic_load_explicit(&tr->rpos, memory_order_relaxed);
            uint64_t w = atomic_load_explicit(&tr->wpos, memory_order_acquire);
            uint64_t avail = tr->debt > 0 ? 0 : w - r;
            uint32_t take = avail < e ? (uint32_t)avail : e;
            const uint32_t ch = tr->channels;

            for (uint32_t c = 0; c < ch; c++) {
                int32_t o = atomic_load_explicit(&tr->route[c], memory_order_relaxed);
                if (o < 0 || (uint32_t)o >= n_out || !outs[o]) continue;
                float *dst = outs[o] + i;
                uint64_t idx = r % tr->capacity;
                for (uint32_t j = 0; j < take; j++) {
                    dst[j] += tr->data[idx * ch + c] * m->env[j];
                    if (++idx == tr->capacity) idx = 0;
                }
            }
            atomic_store_explicit(&tr->rpos, r + take, memory_order_release);

            bool eof = atomic_load_explicit(&tr->eof, memory_order_acquire) != 0;
            if (take < e) {
                if (!eof) {
                    // Underrun: keep the timeline moving, drop the missing
                    // frames later so this track stays in sync.
                    tr->debt += e - take;
                    atomic_fetch_add(&m->underruns, 1);
                }
            }
            if (!(eof && w - (r + take) == 0)) all_drained = false;
        }

        pos += e;
        v->played += e;
        i += e;
        if (all_drained && total <= 0) ended = true;
        if (all_drained && total > 0 && pos < total) ended = true;
    }
    atomic_store_explicit(&v->pos, pos, memory_order_relaxed);
    return ended;
}

static void render_voice(cm_mixer *m, cm_voice *v, float *CM_NULLABLE const *CM_NONNULL outs,
                         uint32_t n_out, uint32_t frames, uint64_t host) {
    int s = atomic_load_explicit(&v->state, memory_order_acquire);
    uint32_t from = 0;

    if (s == CM_ARMED) {
        uint64_t start = atomic_load(&v->start_host);
        if (start > host) {
            double f = (double)(start - host) / m->ticks_per_sec * m->rate;
            if (f >= (double)frames) return;
            from = (uint32_t)f;
        } else {
            double late = (double)(host - start) / m->ticks_per_sec * m->rate;
            int64_t skip = (int64_t)late;
            if (skip > 0) skip_frames(v, skip);
        }
        int expected = CM_ARMED;
        if (!atomic_compare_exchange_strong(&v->state, &expected, CM_PLAYING)) return;
        s = CM_PLAYING;
    } else if (s == CM_STOP_REQ) {
        v->mfade_start = atomic_load_explicit(&v->pos, memory_order_relaxed);
        int expected = CM_STOP_REQ;
        if (!atomic_compare_exchange_strong(&v->state, &expected, CM_STOPPING)) return;
        s = CM_STOPPING;
    } else if (s != CM_PLAYING && s != CM_STOPPING) {
        return;
    }

    // Scheduled stop (crossfade out at an exact host time).
    uint64_t stop_host = atomic_load_explicit(&v->stop_host, memory_order_acquire);
    if (s == CM_PLAYING && stop_host != 0) {
        int64_t off = -1;
        if (stop_host <= host) {
            off = from;
        } else {
            double f = (double)(stop_host - host) / m->ticks_per_sec * m->rate;
            if (f < (double)frames) off = (int64_t)f < from ? from : (int64_t)f;
        }
        if (off >= 0) {
            atomic_store(&v->stop_fade, atomic_load(&v->stop_at_fade));
            v->mfade_start = atomic_load_explicit(&v->pos, memory_order_relaxed) + (off - from);
            int expected = CM_PLAYING;
            if (atomic_compare_exchange_strong(&v->state, &expected, CM_STOPPING)) s = CM_STOPPING;
        }
    }

    if (process_voice(m, v, s, outs, n_out, from, frames)) {
        int expected = s;
        if (!atomic_compare_exchange_strong(&v->state, &expected, CM_FINISHED)) {
            // A concurrent stop request moved PLAYING -> STOP_REQ; we are done anyway.
            if (expected == CM_STOP_REQ) {
                atomic_compare_exchange_strong(&v->state, &expected, CM_FINISHED);
            }
        }
    }
}

void cm_mixer_render(cm_mixer *m, float *CM_NULLABLE const *CM_NONNULL outs, uint32_t n_out,
                     uint32_t frames, uint64_t host_time) {
    atomic_fetch_add(&m->epoch, 1);   // odd: rendering

    for (uint32_t c = 0; c < n_out; c++) {
        if (outs[c]) memset(outs[c], 0, frames * sizeof(float));
    }
    if (n_out > m->out_channels) n_out = m->out_channels;

    int64_t lat = atomic_load_explicit(&m->latency_ticks, memory_order_relaxed);
    uint64_t heard = (int64_t)host_time + lat > 0 ? (uint64_t)((int64_t)host_time + lat) : 0;

    for (int i = 0; i < CM_MAX_VOICES; i++) {
        render_voice(m, &m->voices[i], outs, n_out, frames, heard);
    }

    const float master = u2f(atomic_load_explicit(&m->master_bits, memory_order_relaxed));
    for (uint32_t c = 0; c < n_out; c++) {
        float *o = outs[c];
        if (!o) continue;
        float peak = 0.0f;
        for (uint32_t j = 0; j < frames; j++) {
            float x = o[j] * master;
            o[j] = x;
            float a = fabsf(x);
            if (a > peak) peak = a;
        }
        if (c < CM_MAX_OUT) {
            uint32_t prev = atomic_load_explicit(&m->peaks[c], memory_order_relaxed);
            while (u2f(prev) < peak &&
                   !atomic_compare_exchange_weak(&m->peaks[c], &prev, f2u(peak))) {}
        }
    }

    atomic_fetch_add(&m->epoch, 1);   // even: idle
}

#ifdef __APPLE__
OSStatus cm_render_callback(void *inRefCon,
                            AudioUnitRenderActionFlags *ioActionFlags,
                            const AudioTimeStamp *inTimeStamp,
                            UInt32 inBusNumber,
                            UInt32 inNumberFrames,
                            AudioBufferList *CM_NULLABLE ioData) {
    (void)ioActionFlags;
    (void)inBusNumber;
    cm_mixer *m = (cm_mixer *)inRefCon;
    if (!ioData) return noErr;
    float *outs[CM_MAX_OUT];
    UInt32 n = ioData->mNumberBuffers;
    if (n > CM_MAX_OUT) n = CM_MAX_OUT;
    for (UInt32 b = 0; b < n; b++) {
        outs[b] = (float *)ioData->mBuffers[b].mData;
    }
    uint64_t host = (inTimeStamp && (inTimeStamp->mFlags & kAudioTimeStampHostTimeValid))
                        ? inTimeStamp->mHostTime : mach_absolute_time();
    if (!m) {
        for (UInt32 b = 0; b < n; b++) if (outs[b]) memset(outs[b], 0, inNumberFrames * sizeof(float));
        return noErr;
    }
    cm_mixer_render(m, outs, n, inNumberFrames, host);
    return noErr;
}
#endif
