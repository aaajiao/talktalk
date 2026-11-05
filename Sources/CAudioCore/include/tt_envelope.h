#ifndef TT_ENVELOPE_H
#define TT_ENVELOPE_H

/* tt_envelope: RMS envelope history for the acoustic echo score (ARCHITECTURE.md §3.5, §3.8
 * "Feed 输出包络"). One producer pushes audio; every `window_frames` frames (10 ms) it publishes
 * one point {seq, host time of the window's first frame, RMS, peak}. The history keeps the
 * latest TT_ENVELOPE_POINTS points (> 3 s of 10 ms points); the oldest are overwritten, which is
 * the point of a history (unlike the audio rings, nothing waits on it). One consumer
 * (EchoScorer on the audio worker) reads with a cursor and is told when it fell behind.
 *
 * feedIOProc pushes what it actually writes to Feed channel 1 (ringO or ringP, after fades), so
 * the envelope covers TTS and passthrough at their real output times, pauses and cuts
 * included. The worker can use a second instance for the tap side. */

#include <stdint.h>
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define TT_ENVELOPE_POINTS        512u   /* power of two; 5.12 s of 10 ms points */
#define TT_ENVELOPE_WINDOW_48K    480u   /* 10 ms at 48 kHz */

typedef struct tt_envelope_point {
    uint64_t seq;          /* 0, 1, 2, ... with no gaps on the producer side */
    uint64_t host_ticks;   /* host time of the window's first frame (mach ticks) */
    float rms;             /* linear RMS of the window */
    float peak;            /* max |sample| in the window */
} tt_envelope_point;

typedef struct tt_envelope tt_envelope;

/* host_ticks_per_frame: mach ticks per frame at the pushed rate (500 at 48 kHz on Apple
 * silicon). Not real-time safe. */
tt_envelope *_Nullable tt_envelope_create(uint32_t window_frames, double host_ticks_per_frame);
void tt_envelope_destroy(tt_envelope *_Nullable env);

/* Producer: `frames` samples taken every `stride` floats from src (NULL = zeros), the first one
 * output (or captured) at host_ticks. A host-time jump of more than half a window against
 * the previous push restarts the current window (the partial window is not published). */
void tt_envelope_push(tt_envelope *env, const float *_Nullable src, uint32_t frames, uint32_t stride,
                      uint64_t host_ticks) TT_NONBLOCKING;

/* Points published so far (the next point's seq). */
uint64_t tt_envelope_count(const tt_envelope *env) TT_NONBLOCKING;

/* Consumer: copies up to `max` points starting at seq *cursor, oldest first, and advances
 * *cursor past them. Points already overwritten are skipped (the cursor jumps forward and the
 * skipped count is added to tt_envelope_lost_points). Returns the number copied. */
uint32_t tt_envelope_read(tt_envelope *env, uint64_t *cursor, tt_envelope_point *dst, uint32_t max) TT_NONBLOCKING;
/* Consumer: copies the latest min(max, available) points, oldest first. */
uint32_t tt_envelope_read_recent(tt_envelope *env, tt_envelope_point *dst, uint32_t max) TT_NONBLOCKING;
uint64_t tt_envelope_lost_points(const tt_envelope *env) TT_NONBLOCKING;

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
