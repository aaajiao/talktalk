#ifndef TT_IOPROC_TAP_H
#define TT_IOPROC_TAP_H

/* Meeting-tap IOProc (ARCHITECTURE.md §3.1 step 4). Attached with AudioDeviceCreateIOProcID on
 * the private aggregate that holds the include tap. It only copies: the tap's stereo Float32
 * input goes into two mono tt_rings (left, right), and every callback's (mHostTime, frames)
 * goes into a small SPSC timestamp ring so the worker can build the TimeMap. It also remembers
 * the host time of the latest callback that carried any non-zero sample, for the all-zero
 * watchdog (§3.1). No allocation, no locks: TT_NONBLOCKING is checked by the compiler. */

#include <CoreAudio/AudioHardware.h>
#include <stdatomic.h>
#include <stdint.h>
#include "tt_ring.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define TT_TAP_STAMPS 1024u   /* power of two; 10 s of 10 ms callbacks */

typedef struct tt_tap_stamp {
    uint64_t host_time;   /* mHostTime of the callback's first input frame (mach ticks); 0 if invalid */
    uint32_t frames;
    uint32_t nonzero;     /* 1 if any sample in this callback was non-zero */
} tt_tap_stamp;

typedef struct tt_tap_ctx tt_tap_ctx;

/* `right` may equal `left` for a mono tap. Not real-time safe. */
tt_tap_ctx *_Nullable tt_tap_ctx_create(tt_ring *left, tt_ring *right);
void tt_tap_ctx_destroy(tt_tap_ctx *_Nullable ctx);

uint64_t tt_tap_callbacks(const tt_tap_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_tap_frames(const tt_tap_ctx *ctx) TT_NONBLOCKING;
/* Host time (mach ticks) of the latest callback with a non-zero sample; 0 if none yet. */
uint64_t tt_tap_last_nonzero_host_time(const tt_tap_ctx *ctx) TT_NONBLOCKING;
/* Stamps dropped because the worker fell >TT_TAP_STAMPS callbacks behind. */
uint64_t tt_tap_dropped_stamps(const tt_tap_ctx *ctx) TT_NONBLOCKING;

/* Consumer side: pops up to `max` stamps in order; returns how many. */
uint32_t tt_tap_read_stamps(tt_tap_ctx *ctx, tt_tap_stamp *dst, uint32_t max) TT_NONBLOCKING;

OSStatus tt_tap_ioproc(AudioObjectID inDevice,
                       const AudioTimeStamp * inNow,
                       const AudioBufferList * inInputData,
                       const AudioTimeStamp * inInputTime,
                       AudioBufferList * outOutputData,
                       const AudioTimeStamp * inOutputTime,
                       void *_Nullable inClientData) TT_NONBLOCKING;

/* The copy logic without Core Audio, for tests. */
void tt_tap_process(tt_tap_ctx *ctx, const AudioBufferList *_Nullable input, uint32_t frames, uint64_t host_time) TT_NONBLOCKING;

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
