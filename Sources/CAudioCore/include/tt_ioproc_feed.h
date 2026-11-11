#ifndef TT_IOPROC_FEED_H
#define TT_IOPROC_FEED_H

/* Feed IOProc (ARCHITECTURE.md, "实时音频与生命周期约束"). Attached with AudioDeviceCreateIOProcID on the
 * hidden "TalkTalk Feed" device, resolved by UID: output only, 2 channels (1 = meeting →
 * TalkTalk Mic, 2 = self-test → Test Mic), 48 kHz Float32, 480-frame IO buffer; the driver's Mic
 * reads channel 1 at sample time T - 480 (docs/decisions/m0-t8-driver.md). No SRC, no
 * allocation, no locks: TT_NONBLOCKING is checked by the compiler.
 *
 * Every IO cycle plays exactly one source, never a mix:
 *  - ringO (TTS, through tt_ring_playout_read) on channel 1, or
 *  - ringP (passthrough, through tt_ringp_read) on the channel of its source:
 *    TT_PT_SOURCE_MIC → channel 1, TT_PT_SOURCE_SELF_TEST → channel 2.
 * Channel 2 carries nothing but .selfTest passthrough; .mic never reaches channel 2 and ringO
 * never reaches channel 2.
 *
 * Switching (tt_pt_state, read once per cycle, compared with the cycle's output host time):
 *  - live (open, consistent, before lease end and deadline): ringP of that generation is
 *    played; ringO is not read (it is parked on a clause start by then). If ringO was still
 *    playing, one 10 ms fade-out cycle of ringO comes first.
 *  - the cycle in which the same generation stops being live (closed or lease expired): ringP
 *    fades out over 10 ms from its current position, zeros follow, then ringP is flushed
 *    (read index → write index) and ringO is played again from the next cycle.
 *  - a generation seen not live in any cycle is finished: a lease renewed after that never
 *    plays it again (frames captured after its end stay unplayed); only a new open does.
 *  - the generation current when the context is created is finished for it too (a new context
 *    follows a detach or an interruption, after which only a new open, a new clean press, may
 *    play: §3.6). Generations start at 1, so a never-opened state (generation 0) loses nothing.
 *  - a generation change while playing ringP: the old one stops at once (zeros, flush), the
 *    new one starts in a later cycle.
 *  - while ringO is the source, ringP blocks of the current or older generations are discarded
 *    every cycle, so each open starts from an empty ring.
 *
 * ringO underruns: the rebuffer threshold is max(80 ms, 2 × chunk interval p95) (p95 set by the
 * worker), doubled when an underrun follows another within 10 s (max 640 ms) and halved again
 * after each 30 s without one. Time is counted in Feed frames, not host time.
 *
 * Measurements go to the event ring (tt_event_ring.h): out.first_sample per clause start,
 * out.underrun, pt.first_sample (arrival and capture time), pt.underrun, pt.lease_expired,
 * pt.zero. Arrival = output host time of the frame + mic_latency_frames frames. What goes to
 * channel 1 is also pushed into the Feed output envelope. */

#include <CoreAudio/AudioHardware.h>
#include <stdint.h>
#include "tt_envelope.h"
#include "tt_event_ring.h"
#include "tt_pt_state.h"
#include "tt_ring.h"
#include "tt_ringp.h"
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define TT_FEED_RATE                        48000u
#define TT_FEED_CHANNELS                    2u
#define TT_FEED_MIC_LATENCY_FRAMES          480u      /* driver loopback lag (§8.3, m0-t8) */
#define TT_FEED_PT_FADE_OUT_FRAMES          480u      /* 10 ms close fade */
#define TT_FEED_O_FADE_OUT_FRAMES           480u      /* 10 ms ringO fade when ringP takes over */
#define TT_FEED_RESUME_MIN_FRAMES           3840u     /* 80 ms */
#define TT_FEED_RESUME_MAX_FRAMES           30720u    /* 640 ms */
#define TT_FEED_RESUME_DOUBLE_WINDOW_FRAMES 480000u   /* 10 s */
#define TT_FEED_RESUME_DECAY_FRAMES         1440000u  /* 30 s */
#define TT_FEED_DEFAULT_MAX_CYCLE_FRAMES    4096u
#define TT_FEED_IO_BUFFER_FRAMES            480u      /* IO buffer FeedOutput sets (§8.2; m0-t8 measured both
                                                         * ends at 480; the HAL default was 512) */

/* tt_feed_mode values. */
#define TT_FEED_MODE_RING_O     0u   /* ringO on channel 1 */
#define TT_FEED_MODE_O_TO_P     1u   /* ringO fading out because passthrough opened */
#define TT_FEED_MODE_PT         2u   /* ringP on its source's channel */
#define TT_FEED_MODE_PT_CLOSING 3u   /* ringP fading out after a close or lease end */

typedef struct tt_feed_config {
    /* mach ticks per 48 kHz frame: HostClock.machTicks(fromNanos: 1_000_000_000) / 48000
     * (exactly 500 on Apple silicon). */
    double host_ticks_per_frame;
    /* Driver lag from Feed channel 1 to TalkTalk Mic: TT_FEED_MIC_LATENCY_FRAMES. */
    uint32_t mic_latency_frames;
    /* Scratch size; longer cycles are processed in pieces (same source for the whole cycle). */
    uint32_t max_cycle_frames;
} tt_feed_config;

/* What the last cycle did (for tests and diagnostics). */
typedef struct tt_feed_cycle {
    uint32_t frames;
    uint32_t mode;              /* TT_FEED_MODE_* the cycle ran in */
    uint32_t ring_o_audio;      /* frames of ringO audio written */
    uint32_t ring_p_audio;      /* frames of ringP audio written */
    uint32_t ring_p_channel;    /* channel index ringP went to (when ring_p_audio > 0) */
    uint32_t generation;        /* ringP generation played (when ring_p_audio > 0) */
    uint64_t out_host_ticks;
} tt_feed_cycle;

typedef struct tt_feed_ctx tt_feed_ctx;

/* Not real-time safe. The rings, state, event ring and envelope must outlive the context and
 * are not owned by it. Reads `pt` once (retrying until the seqlock read is consistent) to take
 * its current generation as finished; NULL if no consistent read was possible. */
tt_feed_ctx *_Nullable tt_feed_ctx_create(tt_ring *ring_o, tt_ringp *ring_p, tt_pt_state *pt,
                                          tt_event_ring *_Nullable events,
                                          tt_envelope *_Nullable envelope,
                                          const tt_feed_config *config);
void tt_feed_ctx_destroy(tt_feed_ctx *_Nullable ctx);

/* Worker: p95 of the recent TTS chunk arrival interval, in 48 kHz frames. */
void tt_feed_set_chunk_interval_p95_frames(tt_feed_ctx *ctx, uint32_t frames) TT_NONBLOCKING;
/* Current ringO rebuffer threshold in frames. */
uint32_t tt_feed_resume_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint32_t tt_feed_mode(const tt_feed_ctx *ctx) TT_NONBLOCKING;
tt_feed_cycle tt_feed_last_cycle(const tt_feed_ctx *ctx) TT_NONBLOCKING;

uint64_t tt_feed_callbacks(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_feed_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_feed_ring_o_audio_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_feed_ring_p_audio_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_feed_out_underruns(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_feed_pt_underruns(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_feed_pt_opens(const tt_feed_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_feed_pt_lease_expiries(const tt_feed_ctx *ctx) TT_NONBLOCKING;
/* Microphone frames that reached the Feed outside their passthrough interval (captured before
 * the open or at/after the lease end / close) and were discarded instead of played. */
uint64_t tt_feed_pt_out_of_interval_frames(const tt_feed_ctx *ctx) TT_NONBLOCKING;
/* Cycles in which both rings produced audio. Always 0; kept as a self-check. */
uint64_t tt_feed_mixed_cycles(const tt_feed_ctx *ctx) TT_NONBLOCKING;
/* Cycles whose output buffers had no usable channel 1 (nothing was written). */
uint64_t tt_feed_missing_buffers(const tt_feed_ctx *ctx) TT_NONBLOCKING;

/* AudioDeviceIOProc. Pass the tt_feed_ctx as inClientData. */
OSStatus tt_feed_ioproc(AudioObjectID inDevice,
                        const AudioTimeStamp *inNow,
                        const AudioBufferList *inInputData,
                        const AudioTimeStamp *inInputTime,
                        AudioBufferList *outOutputData,
                        const AudioTimeStamp *inOutputTime,
                        void *_Nullable inClientData) TT_NONBLOCKING;

/* The cycle logic without Core Audio, for tests: fills every channel of `output` for `frames`
 * frames whose first frame is output at out_host_ticks. */
void tt_feed_process(tt_feed_ctx *ctx, AudioBufferList *output, uint32_t frames,
                     uint64_t out_host_ticks) TT_NONBLOCKING;

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
