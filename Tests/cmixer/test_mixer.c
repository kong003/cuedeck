// Unit tests for the real-time mixer. Run with: make -C Tests/cmixer
#include "cmixer.h"

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define NEAR(a, b) (fabs((double)(a) - (double)(b)) < 1e-4)

#define RATE 48000.0
#define TPS 1000000000.0   // host ticks = nanoseconds in tests
#define NOUT 8
#define BUF 256

static float bufs[NOUT][BUF];
static float *outs[NOUT];

static void render(cm_mixer *m, uint64_t host) {
    for (int c = 0; c < NOUT; c++) outs[c] = bufs[c];
    cm_mixer_render(m, outs, NOUT, BUF, host);
}

static uint64_t frames_to_ticks(double f) { return (uint64_t)(f / RATE * TPS); }

// Fill a track with a ramp so we can identify each frame: value = frame index + base
static void fill(cm_mixer *m, int v, uint32_t track, uint32_t ch, uint32_t frames, float base) {
    float *tmp = malloc(sizeof(float) * frames * ch);
    for (uint32_t i = 0; i < frames; i++)
        for (uint32_t c = 0; c < ch; c++) tmp[i * ch + c] = base + (float)c * 1000.0f + (float)i;
    uint32_t w = cm_voice_write(m, v, track, tmp, frames);
    CHECK(w == frames, "write %u of %u", w, frames);
    free(tmp);
}

static void test_routing_and_start_offset(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[2] = {2, 1};
    int v = cm_voice_create(m, 2, chs, 4096);
    CHECK(v >= 0, "create voice");
    // track0 L->out2, R->out3, track1 mono -> out5
    cm_voice_set_route(m, v, 0, 0, 2);
    cm_voice_set_route(m, v, 0, 1, 3);
    cm_voice_set_route(m, v, 1, 0, 5);
    fill(m, v, 0, 2, 1000, 1.0f);
    fill(m, v, 1, 1, 1000, 0.5f);

    uint64_t t0 = 1000000000ULL;
    // start 100 frames into the next buffer
    cm_voice_start(m, v, t0 + frames_to_ticks(100.0) + 1);
    render(m, t0);
    CHECK(cm_voice_state(m, v) == CM_PLAYING, "playing state %d", cm_voice_state(m, v));
    CHECK(bufs[2][99] == 0.0f, "silence before start: %f", bufs[2][99]);
    CHECK(NEAR(bufs[2][100], 1.0f), "first frame L: %f", bufs[2][100]);
    CHECK(NEAR(bufs[3][100], 1001.0f), "first frame R: %f", bufs[3][100]);
    CHECK(NEAR(bufs[5][101], 1.5f), "mono track: %f", bufs[5][101]);
    CHECK(bufs[0][150] == 0.0f && bufs[1][150] == 0.0f, "unrouted channels silent");
    CHECK(cm_voice_position(m, v) == BUF - 100, "position %lld", (long long)cm_voice_position(m, v));

    // live re-route
    cm_voice_set_route(m, v, 0, 0, 7);
    render(m, t0 + frames_to_ticks(BUF));
    CHECK(bufs[2][0] == 0.0f && NEAR(bufs[7][0], 1.0f + 156.0f), "reroute: %f", bufs[7][0]);
    cm_voice_release(m, v);
    CHECK(cm_voice_state(m, v) == CM_FREE, "released");
    cm_mixer_destroy(m);
}

static void test_late_start_skips(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int v = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, v, 0, 0, 0);
    fill(m, v, 0, 1, 2000, 0.0f);
    uint64_t t0 = 5000000000ULL;
    cm_voice_start(m, v, t0);
    render(m, t0 + frames_to_ticks(300.0) + 1); // 300 frames late
    CHECK(NEAR(bufs[0][0], 300.0f), "late start skips to 300: %f", bufs[0][0]);
    CHECK(cm_voice_position(m, v) == 300 + BUF, "pos %lld", (long long)cm_voice_position(m, v));
    cm_mixer_destroy(m);
}

static void test_fades_and_end(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int v = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, v, 0, 0, 0);
    float *ones = malloc(sizeof(float) * 1000);
    for (int i = 0; i < 1000; i++) ones[i] = 1.0f;
    cm_voice_write(m, v, 0, ones, 1000);
    cm_voice_set_eof(m, v, 0);
    cm_voice_set_envelope(m, v, 600, 100, 200);
    cm_voice_set_gain(m, v, 0.5f);
    uint64_t t0 = 0;
    cm_voice_start(m, v, t0);
    render(m, t0);
    CHECK(bufs[0][0] == 0.0f, "fade in starts at 0");
    CHECK(NEAR(bufs[0][50], 0.5f * 0.25f), "fade in midpoint t^2: %f", bufs[0][50]);
    CHECK(NEAR(bufs[0][150], 0.5f), "full gain: %f", bufs[0][150]);
    render(m, t0 + frames_to_ticks(BUF));
    CHECK(NEAR(bufs[0][0], 0.5f), "full gain in 2nd buffer (pos 256): %f", bufs[0][0]);
    render(m, t0 + frames_to_ticks(2 * BUF)); // pos 512..767, total 600, fade-out from 400
    // pos 512 -> t = (600-512)/200 = 0.44
    CHECK(NEAR(bufs[0][0], 0.5f * 0.44f * 0.44f), "fade out: %f", bufs[0][0]);
    CHECK(bufs[0][88] == 0.0f && bufs[0][100] == 0.0f, "silent after end");
    CHECK(cm_voice_state(m, v) == CM_FINISHED, "finished at total: %d", cm_voice_state(m, v));
    free(ones);
    cm_mixer_destroy(m);
}

static void test_eof_ends_unknown_length(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {2};
    int v = cm_voice_create(m, 1, chs, 4096);
    fill(m, v, 0, 2, 100, 0.0f);
    cm_voice_set_eof(m, v, 0);
    cm_voice_start(m, v, 0);
    render(m, 0);
    CHECK(cm_voice_state(m, v) == CM_FINISHED, "eof drained -> finished %d", cm_voice_state(m, v));
    cm_mixer_destroy(m);
}

static void test_pause_resume_and_stop_fade(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int v = cm_voice_create(m, 1, chs, 8192);
    cm_voice_set_route(m, v, 0, 0, 1);
    fill(m, v, 0, 1, 5000, 0.0f);
    cm_voice_start(m, v, 0);
    render(m, 0);
    CHECK(cm_voice_pause(m, v), "pause");
    render(m, frames_to_ticks(BUF));
    CHECK(bufs[1][10] == 0.0f, "paused is silent");
    CHECK(cm_voice_position(m, v) == BUF, "position held while paused");
    uint64_t resume = frames_to_ticks(10 * BUF);
    cm_voice_start(m, v, resume);
    render(m, resume);
    CHECK(NEAR(bufs[1][0], (float)BUF), "resumes where it paused: %f", bufs[1][0]);

    // stop with a 300 frame fade
    cm_voice_stop(m, v, 300);
    CHECK(cm_voice_state(m, v) == CM_STOP_REQ, "stop requested");
    render(m, resume + frames_to_ticks(BUF));
    CHECK(cm_voice_state(m, v) == CM_STOPPING, "stopping");
    CHECK(NEAR(bufs[1][0], 2.0f * BUF), "fade starts at full: %f", bufs[1][0]);
    CHECK(bufs[1][255] < bufs[1][0] * 1.2f && bufs[1][255] > 0.0f, "fading");
    render(m, resume + frames_to_ticks(2 * BUF));
    CHECK(cm_voice_state(m, v) == CM_FINISHED, "finished after fade: %d", cm_voice_state(m, v));
    CHECK(bufs[1][44] == 0.0f, "silent after fade end: %f", bufs[1][44]);
    cm_mixer_destroy(m);
}

static void test_underrun_keeps_sync(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int v = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, v, 0, 0, 0);
    fill(m, v, 0, 1, 100, 0.0f);   // only 100 frames available
    cm_voice_start(m, v, 0);
    render(m, 0);
    CHECK(cm_mixer_underruns(m) >= 1, "underrun counted");
    CHECK(cm_voice_position(m, v) == BUF, "timeline advanced");
    // decoder catches up with frames 100..999
    float tmp[900];
    for (int i = 0; i < 900; i++) tmp[i] = 100.0f + i;
    cm_voice_write(m, v, 0, tmp, 900);
    render(m, frames_to_ticks(BUF));
    CHECK(NEAR(bufs[0][0], (float)BUF), "after underrun stays aligned to frame 256: %f", bufs[0][0]);
    cm_mixer_destroy(m);
}

static void test_master_and_peaks(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int v = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, v, 0, 0, 4);
    float tmp[512];
    for (int i = 0; i < 512; i++) tmp[i] = (i == 10) ? -0.8f : 0.1f;
    cm_voice_write(m, v, 0, tmp, 512);
    cm_mixer_set_master_gain(m, 0.5f);
    cm_voice_start(m, v, 0);
    render(m, 0);
    float peaks[NOUT];
    cm_mixer_take_peaks(m, peaks, NOUT);
    CHECK(NEAR(peaks[4], 0.4f), "peak %f", peaks[4]);
    CHECK(peaks[0] == 0.0f, "no peak elsewhere");
    cm_mixer_take_peaks(m, peaks, NOUT);
    CHECK(peaks[4] == 0.0f, "peaks reset");
    cm_mixer_destroy(m);
}

static void test_latency_offset(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int v = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, v, 0, 0, 0);
    fill(m, v, 0, 1, 1000, 1.0f);
    // device latency of 50 frames: callback host time + 50 frames = heard time
    cm_mixer_set_latency_ticks(m, (int64_t)frames_to_ticks(50));
    cm_voice_start(m, v, frames_to_ticks(100) + 1);
    render(m, 0);
    CHECK(bufs[0][49] == 0.0f && NEAR(bufs[0][50], 1.0f), "latency compensation: %f %f", bufs[0][49], bufs[0][50]);
    cm_mixer_destroy(m);
}

// Producer/consumer stress test: decoder thread writes a counter sequence,
// render thread checks continuity.
static cm_mixer *sm;
static int sv;
#define STRESS_FRAMES 2000000
static void *producer(void *arg) {
    (void)arg;
    float chunk[333 * 2];
    uint32_t next = 0;
    while (next < STRESS_FRAMES) {
        uint32_t n = 333;
        if (next + n > STRESS_FRAMES) n = STRESS_FRAMES - next;
        for (uint32_t i = 0; i < n; i++) { chunk[i * 2] = (float)(next + i); chunk[i * 2 + 1] = -(float)(next + i); }
        uint32_t done = 0;
        while (done < n) {
            uint32_t w = cm_voice_write(sm, sv, 0, chunk + done * 2, n - done);
            done += w;
            next += w;
            if (w == 0) { struct timespec ts = {0, 50000}; nanosleep(&ts, NULL); }
        }
    }
    cm_voice_set_eof(sm, sv, 0);
    return NULL;
}

static void test_stress(void) {
    sm = cm_mixer_create(2, RATE, TPS);
    uint32_t chs[1] = {2};
    sv = cm_voice_create(sm, 1, chs, 2048);
    cm_voice_set_route(sm, sv, 0, 0, 0);
    cm_voice_set_route(sm, sv, 0, 1, 1);
    // prefill a bit before starting, like the app does
    pthread_t th;
    pthread_create(&th, NULL, producer, NULL);
    while (cm_voice_buffered(sm, sv, 0) < 1024) { struct timespec ts = {0, 100000}; nanosleep(&ts, NULL); }
    cm_voice_start(sm, sv, 0);
    float a[BUF], b[BUF];
    float *o[2] = {a, b};
    uint64_t host = 0;
    int64_t expected = 0;
    int errors = 0;
    while (cm_voice_state(sm, sv) != CM_FINISHED) {
        cm_mixer_render(sm, o, 2, BUF, host);
        host += frames_to_ticks(BUF);
        for (int j = 0; j < BUF && expected < STRESS_FRAMES; j++) {
            if (a[j] == 0.0f && expected != 0) { expected++; continue; } // underrun gap: timeline keeps moving
            if (a[j] != (float)expected && errors < 5) { errors++; printf("  stress mismatch at %lld: %f\n", (long long)expected, a[j]); }
            expected++;
        }
        struct timespec ts = {0, 2000};
        nanosleep(&ts, NULL);
    }
    pthread_join(th, NULL);
    printf("  stress: %lld frames, %llu underruns\n", (long long)expected, (unsigned long long)cm_mixer_underruns(sm));
    CHECK(errors == 0, "stress data integrity");
    cm_mixer_destroy(sm);
}

static void test_voice_slots(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int ids[CM_MAX_VOICES];
    for (int i = 0; i < CM_MAX_VOICES; i++) { ids[i] = cm_voice_create(m, 1, chs, 128); CHECK(ids[i] == i, "slot %d", i); }
    CHECK(cm_voice_create(m, 1, chs, 128) == -1, "no free slot");
    cm_voice_release(m, ids[3]);
    CHECK(cm_voice_create(m, 1, chs, 128) == 3, "reuse slot");
    uint32_t bad[1] = {0};
    CHECK(cm_voice_create(m, 1, bad, 128) == -1, "reject 0 channels");
    cm_mixer_destroy(m);
}

static void test_start_mid_cue(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    int v = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, v, 0, 0, 0);
    float ones[512];
    for (int i = 0; i < 512; i++) ones[i] = 1.0f;
    cm_voice_write(m, v, 0, ones, 512);
    // cue is 1000 frames with a 100 frame fade-out; we start at frame 850
    cm_voice_set_envelope(m, v, 1000, 200, 100);
    cm_voice_set_position(m, v, 850);
    CHECK(cm_voice_position(m, v) == 850, "position set");
    cm_voice_start(m, v, 0);
    cm_voice_set_position(m, v, 0); // ignored once started
    render(m, 0);
    CHECK(NEAR(bufs[0][0], 1.0f), "no fade-in when starting past it: %f", bufs[0][0]);
    CHECK(NEAR(bufs[0][60], 0.9f * 0.9f), "fade-out measured on cue timeline: %f", bufs[0][60]); // pos 910 of 1000, 100 frame fade
    CHECK(bufs[0][150] == 0.0f, "ends at cue end");
    CHECK(cm_voice_state(m, v) == CM_FINISHED, "finished");
    cm_mixer_destroy(m);
}

static void test_scheduled_crossfade(void) {
    cm_mixer *m = cm_mixer_create(NOUT, RATE, TPS);
    uint32_t chs[1] = {1};
    float ones[2048];
    for (int i = 0; i < 2048; i++) ones[i] = 1.0f;
    int a = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, a, 0, 0, 0);
    cm_voice_write(m, a, 0, ones, 2048);
    cm_voice_start(m, a, 0);
    render(m, 0);
    // switch at frame 256+100 of the next buffer, 100-frame crossfade
    uint64_t h = frames_to_ticks(BUF + 100) + 1;
    int b = cm_voice_create(m, 1, chs, 4096);
    cm_voice_set_route(m, b, 0, 0, 0);
    cm_voice_write(m, b, 0, ones, 2048);
    cm_voice_set_start_ramp(m, b, 100);
    cm_voice_start(m, b, h);
    cm_voice_stop_at(m, a, h, 100);
    render(m, frames_to_ticks(BUF));
    CHECK(NEAR(bufs[0][50], 1.0f), "before switch only A: %f", bufs[0][50]);
    for (int i = 100; i < 200; i++) {
        CHECK(bufs[0][i] > 0.74f && bufs[0][i] < 1.01f, "crossfade sum %d: %f", i, bufs[0][i]);
        if (bufs[0][i] <= 0.74f || bufs[0][i] >= 1.01f) break;
    }
    CHECK(NEAR(bufs[0][230], 1.0f), "after switch only B: %f", bufs[0][230]);
    CHECK(cm_voice_state(m, a) == CM_FINISHED, "A finished %d", cm_voice_state(m, a));
    CHECK(cm_voice_state(m, b) == CM_PLAYING, "B playing");
    cm_mixer_destroy(m);
}

int main(void) {
    test_scheduled_crossfade();
    test_start_mid_cue();
    test_routing_and_start_offset();
    test_late_start_skips();
    test_fades_and_end();
    test_eof_ends_unknown_length();
    test_pause_resume_and_stop_fade();
    test_underrun_keeps_sync();
    test_master_and_peaks();
    test_latency_offset();
    test_voice_slots();
    test_stress();
    if (failures) { printf("%d FAILURES\n", failures); return 1; }
    printf("all mixer tests passed\n");
    return 0;
}
