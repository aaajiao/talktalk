#ifndef TT_IOPROC_MIC_H
#define TT_IOPROC_MIC_H

/* Microphone IOProc (ARCHITECTURE.md, "实时音频与生命周期约束"). Attached with AudioDeviceCreateIOProcID
 * directly on the physical input device (never through AVAudioEngine). It copies one input
 * channel of the HAL's canonical Float32 buffers into a tt_ring and records timing; nothing
 * else (no downmix, no conversion, no allocation, no locks: TT_NONBLOCKING is checked by the
 * compiler). Resampling and analysis happen on the audio worker. */

#include <CoreAudio/AudioHardware.h>
#include <stdatomic.h>
#include <stdint.h>
#include "tt_ring.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/* Opaque so Swift never sees the _Atomic fields; read them through the accessors below. */
typedef struct tt_mic_ctx tt_mic_ctx;

#define TT_MIC_STAMPS 1024u
typedef struct tt_mic_stamp {
    uint64_t host_time;   /* mach ticks, 0 if HAL did not supply a timestamp */
    uint64_t frame_index; /* callback's first frame, including frames previously dropped */
    uint32_t frames;      /* samples actually stored, always a contiguous callback prefix */
} tt_mic_stamp;
uint32_t tt_mic_read_stamps(tt_mic_ctx *ctx, tt_mic_stamp *dst, uint32_t max) TT_NONBLOCKING;
uint64_t tt_mic_dropped_frames(const tt_mic_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_mic_dropped_stamps(const tt_mic_ctx *ctx) TT_NONBLOCKING;

/* Allocates and zeroes a context; returns NULL on failure. Not real-time safe. */
tt_mic_ctx *_Nullable tt_mic_ctx_create(tt_ring *ring, uint32_t channel);
void tt_mic_ctx_destroy(tt_mic_ctx *_Nullable ctx);

uint64_t tt_mic_callbacks(const tt_mic_ctx *ctx) TT_NONBLOCKING;
/* Frames delivered by the HAL (stored + dropped). */
uint64_t tt_mic_frames(const tt_mic_ctx *ctx) TT_NONBLOCKING;
/* mHostTime of the first / latest callback's input; 0 until the first callback. */
uint64_t tt_mic_first_host_time(const tt_mic_ctx *ctx) TT_NONBLOCKING;
uint64_t tt_mic_last_host_time(const tt_mic_ctx *ctx) TT_NONBLOCKING;
/* Callbacks in which the captured channel was absent (zeros were written instead). */
uint64_t tt_mic_missing_buffers(const tt_mic_ctx *ctx) TT_NONBLOCKING;

/* AudioDeviceIOProc. Pass the tt_mic_ctx as inClientData. */
OSStatus tt_mic_ioproc(AudioObjectID inDevice,
                       const AudioTimeStamp * inNow,
                       const AudioBufferList * inInputData,
                       const AudioTimeStamp * inInputTime,
                       AudioBufferList * outOutputData,
                       const AudioTimeStamp * inOutputTime,
                       void *_Nullable inClientData) TT_NONBLOCKING;

/* Same copy logic without Core Audio, for tests: feeds one callback's worth of buffers. */
void tt_mic_process(tt_mic_ctx *ctx, const AudioBufferList *_Nullable input, uint32_t frames, uint64_t host_time) TT_NONBLOCKING;

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
