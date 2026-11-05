#ifndef TT_RINGP_H
#define TT_RINGP_H

/* tt_ringp: ringP, the passthrough ring (ARCHITECTURE.md §3.8). Its own type and functions, not
 * another tt_ring, so scripts/check-audio-paths.sh can name every reader and writer:
 *   tt_ringp_write  only in PassthroughStage (audio worker);
 *   tt_ringp_read / tt_ringp_flush / tt_ringp_discard_through  only in tt_ioproc_feed.c.
 *
 * 48 kHz mono Float32, 200 ms. Single producer, single consumer, lock-free, nothing is ever
 * overwritten (excess frames of a write are dropped and counted). Every write is a block that
 * carries the host time of its first sample's capture (mach ticks: mHostTime of the mic buffer
 * through TimeMap, converted with HostClock.machTicks(fromNanos:)) and the passthrough
 * generation it was admitted under (tt_pt_state). Sample k of a block was captured at
 * src_host_ticks + k * host_ticks_per_frame.
 *
 * Consumer rules (tt_ringp_read), all checked per block and per frame:
 *  - only frames of blocks with the reader's generation are played; older generations are
 *    discarded (stale), newer ones are left for later;
 *  - frames captured before valid_from (the open time) are discarded and counted
 *    (out_of_interval: PassthroughGate.admit should never let them through), frames captured
 *    at or after valid_until (lease end / close time) are discarded and counted (expired);
 *  - after a flush, playback starts once TT_RINGP_START_FRAMES are buffered, with a 5 ms fade-in;
 *  - the last TT_RINGP_HOLD_FRAMES (2 ms) are only played as a fade-out: when the ring runs dry
 *    they fade out, zeros follow and an underrun is counted (pt.underrun); playback resumes
 *    after TT_RINGP_START_FRAMES again with a 2 ms fade-in;
 *  - when more than TT_RINGP_MAX_FILL_FRAMES (60 ms) are buffered, the oldest frames are dropped
 *    so that TT_RINGP_START_FRAMES remain after this call, with a 2 ms crossfade over the cut.
 * Fade shapes: tt_fade.h. */

#include <stdbool.h>
#include <stdint.h>
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define TT_RINGP_CAPACITY_FRAMES       9600u  /* 200 ms */
#define TT_RINGP_MAX_BLOCKS            256u
#define TT_RINGP_START_FRAMES          720u   /* 15 ms start buffer (§3.8 latency table) */
#define TT_RINGP_HOLD_FRAMES           96u    /* 2 ms underrun fade-out */
#define TT_RINGP_MAX_FILL_FRAMES       2880u  /* 60 ms */
#define TT_RINGP_XFADE_FRAMES          96u    /* 2 ms crossfade over a drop */
#define TT_RINGP_OPEN_FADE_IN_FRAMES   240u   /* 5 ms at the first sample after a flush */
#define TT_RINGP_RESUME_FADE_IN_FRAMES 96u    /* 2 ms after an underrun */

typedef struct tt_ringp tt_ringp;

typedef struct tt_ringp_report {
    uint32_t audio_frames;     /* frames of dst that carry passthrough audio (incl. fades) */
    uint32_t first_audio;      /* 1: the first audio frame since the last flush is in this call */
    uint32_t first_offset;     /* its index in dst */
    uint64_t first_src_ticks;  /* its capture host time (mach ticks) */
    uint32_t underrun;         /* 1: an underrun began in this call (a read longer than the
                                * start buffer can hold two: tt_ringp_underruns counts each) */
    uint32_t dropped_old;      /* frames dropped by the 60 ms bound */
    uint32_t stale;            /* frames of older generations discarded */
    uint32_t out_of_interval;  /* frames captured before valid_from discarded */
    uint32_t expired;          /* frames captured at/after valid_until discarded */
} tt_ringp_report;

/* host_ticks_per_frame: mach ticks per 48 kHz frame (500 on Apple silicon); from
 * HostClock.machTicks(fromNanos:). Not real-time safe. */
tt_ringp *_Nullable tt_ringp_create(double host_ticks_per_frame);
void tt_ringp_destroy(tt_ringp *_Nullable rp);

/* Producer. Stores a block; returns frames stored (< frames when the ring or the block queue
 * is full; the rest is dropped and counted in tt_ringp_overrun_frames). */
uint32_t tt_ringp_write(tt_ringp *rp, const float *src, uint32_t frames,
                        uint64_t src_host_ticks, uint32_t generation) TT_NONBLOCKING;

/* Either side: frames written and not yet consumed or discarded. */
uint32_t tt_ringp_fill(const tt_ringp *rp) TT_NONBLOCKING;
uint64_t tt_ringp_written_frames(const tt_ringp *rp) TT_NONBLOCKING;
uint64_t tt_ringp_overrun_frames(const tt_ringp *rp) TT_NONBLOCKING;

/* Consumer. Fills dst[0..frames) with audio or zeros (see the rules above) and returns
 * frames. */
uint32_t tt_ringp_read(tt_ringp *rp, float *dst, uint32_t frames, uint32_t generation,
                       uint64_t valid_from_ticks, uint64_t valid_until_ticks,
                       tt_ringp_report *_Nullable report) TT_NONBLOCKING;
/* Consumer: the read index jumps to the write index; the next audio waits for the start
 * buffer and fades in over 5 ms. */
void tt_ringp_flush(tt_ringp *rp) TT_NONBLOCKING;
/* Consumer: discards the leading blocks of `generation` and every older generation. */
void tt_ringp_discard_through(tt_ringp *rp, uint32_t generation) TT_NONBLOCKING;

/* Consumer-side totals. */
uint64_t tt_ringp_underruns(const tt_ringp *rp) TT_NONBLOCKING;
uint64_t tt_ringp_dropped_old_frames(const tt_ringp *rp) TT_NONBLOCKING;
uint64_t tt_ringp_stale_frames(const tt_ringp *rp) TT_NONBLOCKING;
uint64_t tt_ringp_out_of_interval_frames(const tt_ringp *rp) TT_NONBLOCKING;
uint64_t tt_ringp_expired_frames(const tt_ringp *rp) TT_NONBLOCKING;
uint64_t tt_ringp_flushed_frames(const tt_ringp *rp) TT_NONBLOCKING;

/* Generations compare modulo 2^32: a is older than b. */
static inline bool tt_ringp_gen_before(uint32_t a, uint32_t b) TT_NONBLOCKING {
    return (int32_t)(a - b) < 0;
}

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
