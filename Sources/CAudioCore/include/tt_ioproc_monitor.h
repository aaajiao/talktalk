#ifndef TT_IOPROC_MONITOR_H
#define TT_IOPROC_MONITOR_H

/* Monitor IOProc (ARCHITECTURE.md §3.4): optional self-monitoring on the current default output
 * device (we never change the default output). It reads ringO2, a playout tt_ring that
 * ClauseQueue fills with the same post-processed TTS as ringO (48 kHz mono; marks, pause and
 * jumps mirrored), applies an adjustable gain (default -10 dB, changes ramp over one cycle) and
 * writes it to every output channel, or to the two channels tt_monitor_set_channels names. There
 * is no rate conversion here: MonitorOutput keeps the gain at 0 on a device that does not run at
 * 48 kHz (ringO2 is still read, so its pause and jumps behave). An optional cue ring (plain
 * tt_ring, mono, at the device's nominal rate) carries CueTones (passthrough and MeetingMicGuard
 * tones) and the voice audition, added at the cue gain (1 by default, 0 = read and dropped).
 * The first cycle of a context calls tt_ring_playout_suspend on ringO2, so a jump the producer
 * asked for while no monitor was running completes at once, without a fade (no replay of the
 * old read position's audio). A newer WRITE_INDEX flush takes over a pending NEXT_START or
 * in-progress cut before this first read. Passthrough audio never comes here: ringP has no path to this
 * IOProc (§3.8 privacy invariant 1). No allocation, no locks. */

#include <CoreAudio/AudioHardware.h>
#include <stdint.h>
#include "tt_event_ring.h"
#include "tt_ring.h"
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define TT_MONITOR_DEFAULT_GAIN          0.31622776601683794f  /* -10 dB */
#define TT_MONITOR_RESUME_FRAMES         3840u                  /* rebuffer after an underrun */
#define TT_MONITOR_DEFAULT_MAX_CYCLE     4096u

typedef struct tt_monitor_ctx tt_monitor_ctx;

/* `cues` and `events` may be NULL. Not real-time safe. */
tt_monitor_ctx *_Nullable tt_monitor_ctx_create(tt_ring *ring_o2, tt_ring *_Nullable cues,
                                                tt_event_ring *_Nullable events,
                                                uint32_t max_cycle_frames);
void tt_monitor_ctx_destroy(tt_monitor_ctx *_Nullable ctx);

/* Linear gain, clamped to [0, 4]. Takes effect over the next cycle (linear ramp). */
void tt_monitor_set_gain(tt_monitor_ctx *ctx, float linear) TT_NONBLOCKING;
float tt_monitor_gain(const tt_monitor_ctx *ctx) TT_NONBLOCKING;
/* Not real-time safe (powf): gain in dB, clamped to [-60, +12]; -inf or below -60 = mute. */
void tt_monitor_set_gain_db(tt_monitor_ctx *ctx, float db);
/* Before the IOProc first runs: sets the target and the current gain alike (clamped like
 * tt_monitor_set_gain), so the first cycle does not ramp from the default. Not real-time safe;
 * never while the IOProc may be running (the current gain belongs to the IO thread). */
void tt_monitor_set_gain_initial(tt_monitor_ctx *ctx, float linear);

/* Cue ring gain, linear, clamped to [0, 1] (NaN = 0). The cue ring is read every cycle whatever
 * the gain, so what is queued while it is 0 is dropped. Changes ramp over one cycle. */
void tt_monitor_set_cue_gain(tt_monitor_ctx *ctx, float linear) TT_NONBLOCKING;
float tt_monitor_cue_gain(const tt_monitor_ctx *ctx) TT_NONBLOCKING;
/* Like tt_monitor_set_gain_initial, for the cue gain. */
void tt_monitor_set_cue_gain_initial(tt_monitor_ctx *ctx, float linear);

/* Before the IOProc first runs (not real-time safe; never while it may run): write only these
 * two output slots, (buffer index, channel within that buffer) for left and right, instead of
 * every channel of every buffer; everything else gets zeros. The same slot twice writes one
 * channel. A slot the cycle's buffer list does not have is skipped. */
void tt_monitor_set_channels(tt_monitor_ctx *ctx, uint32_t left_buffer, uint32_t left_channel,
                             uint32_t right_buffer, uint32_t right_channel);

uint64_t tt_monitor_callbacks(const tt_monitor_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_monitor_frames(const tt_monitor_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_monitor_audio_frames(const tt_monitor_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_monitor_cue_frames(const tt_monitor_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_monitor_underruns(const tt_monitor_ctx *ctx) TT_NONBLOCKING;

OSStatus tt_monitor_ioproc(AudioObjectID inDevice,
                           const AudioTimeStamp *inNow,
                           const AudioBufferList *inInputData,
                           const AudioTimeStamp *inInputTime,
                           AudioBufferList *outOutputData,
                           const AudioTimeStamp *inOutputTime,
                           void *_Nullable inClientData) TT_NONBLOCKING;

/* The cycle logic without Core Audio, for tests. */
void tt_monitor_process(tt_monitor_ctx *ctx, AudioBufferList *output, uint32_t frames,
                        uint64_t out_host_ticks) TT_NONBLOCKING;

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
