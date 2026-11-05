#ifndef TT_VAD_H
#define TT_VAD_H

/* tt_vad: thin wrapper over the vendored libfvad (third_party/libfvad, BSD-3-Clause, pinned
 * commit in third_party/libfvad/VENDOR.md; ARCHITECTURE.md §2.3, §3.2). Runs on the audio
 * worker, not in an IOProc (libfvad allocates in fvad_new). The adaptive energy gate, the
 * 3-frame onset rule and the 120 ms hangover of §3.2 live in the Swift segmenters; this layer
 * only classifies one frame and reports its level. */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define TT_VAD_MAX_FRAME 960u   /* 30 ms at 32 kHz */

typedef struct tt_vad tt_vad;

/* mode 0..3 (§3.2 uses 2), sample_rate 8000 / 16000 / 32000 (§3.2 runs it on the 16 kHz mic
 * stream). 48000 is refused: libfvad's 48 kHz path resamples only the first 10 ms of a 20 or
 * 30 ms frame (vad_core.c WebRtcVad_CalcVad48khz passes speech_frame without the i * 480
 * offset), so it would judge a frame by its first half or third. NULL on bad arguments or
 * allocation failure. */
tt_vad *_Nullable tt_vad_create(int mode, int sample_rate);
void tt_vad_destroy(tt_vad *_Nullable vad);
/* 0 on success, -1 on a bad value. */
int tt_vad_set_mode(tt_vad *vad, int mode);
/* Back to the initial state (mode and rate kept). */
void tt_vad_reset(tt_vad *vad);
int tt_vad_sample_rate(const tt_vad *vad);

/* One frame of 10, 20 or 30 ms. Returns 1 (voice), 0 (no voice) or -1 (bad length). */
int tt_vad_process_i16(tt_vad *vad, const int16_t *frame, size_t frames);
/* Same for Float32 in [-1, 1] (clamped, rounded to Int16 into a preallocated buffer). */
int tt_vad_process_f32(tt_vad *vad, const float *frame, size_t frames);

/* RMS of a Float32 frame in dBFS (full scale sine = -3.01 dB); -120 for digital silence. */
float tt_vad_rms_dbfs(const float *frame, size_t frames);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
