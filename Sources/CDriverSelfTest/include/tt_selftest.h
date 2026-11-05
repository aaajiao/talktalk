#ifndef TT_SELFTEST_H
#define TT_SELFTEST_H

/* Driver self-test IOProcs (ARCHITECTURE.md §8.4 "校验"; the M0-T8 ttdrv writer/reader, in C).
 *
 * A writer on TalkTalk Feed puts one signal on ONE channel (0-based; the product self-test uses
 * channel index 1 = Feed channel 2 → Test Mic) and zeros on every other channel. A recorder on an
 * input device (Test Mic, or TalkTalk Mic for the isolation check) copies channel 0 into a
 * preallocated buffer and logs each callback's input sample time, so the analysis (Swift,
 * DriverLoopbackAnalysis) can place every sample on the driver's shared sample-time axis.
 *
 * No allocation, no locks, no libm in the IO path: the signal and the tone table are computed
 * when the context is created. TT_NONBLOCKING is checked by -Wfunction-effects. Contexts are
 * changed (reset, mode) only while their IOProc is stopped, except tt_st_writer_set_mode. */

#include <CoreAudio/AudioHardware.h>
#include <stdint.h>

#if defined(__has_attribute)
#  if __has_attribute(nonblocking)
#    define TT_ST_NONBLOCKING __attribute__((nonblocking))
#  endif
#endif
#ifndef TT_ST_NONBLOCKING
#  define TT_ST_NONBLOCKING
#endif

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define TT_ST_RATE        48000u
#define TT_ST_NO_SAMPLE   INT64_MIN

/* Writer modes. */
#define TT_ST_MODE_SILENCE 0u   /* zeros on every channel */
#define TT_ST_MODE_SIGNAL  1u   /* the signal once, lead_frames after the first callback, then zeros */
#define TT_ST_MODE_TONE    2u   /* tt_st_tone(sample time) on the channel, forever */

typedef struct tt_st_writer tt_st_writer;

typedef struct tt_st_range {
    int64_t begin;   /* first output sample time of a contiguous run of callbacks */
    int64_t end;     /* one past the last */
} tt_st_range;

/* `signal` (copied) is played in TT_ST_MODE_SIGNAL; lead_frames of zeros come first.
 * max_ranges: how many contiguous output runs are logged (the anti-replay test restarts the
 * IOProc once per cycle). Not real-time safe. */
tt_st_writer *_Nullable tt_st_writer_create(const float *_Nullable signal, uint32_t signal_frames,
                                            uint32_t channel, uint32_t lead_frames, uint32_t max_ranges);
void tt_st_writer_destroy(tt_st_writer *_Nullable w);
/* Forget the first sample and the ranges (the next callback starts over). IOProc stopped. */
void tt_st_writer_reset(tt_st_writer *w);
/* Forget only the "contiguous" state, so the next callback opens a new range (anti-replay
 * restarts keep their ranges). IOProc stopped. */
void tt_st_writer_break_range(tt_st_writer *w);
void tt_st_writer_set_mode(tt_st_writer *w, uint32_t mode) TT_ST_NONBLOCKING;

/* Output sample time of the first callback since the last reset (TT_ST_NO_SAMPLE if none). */
int64_t tt_st_writer_first_sample(const tt_st_writer *w) TT_ST_NONBLOCKING;
/* Sample time where the signal's first frame was written (TT_ST_NO_SAMPLE if not yet). */
int64_t tt_st_writer_signal_start(const tt_st_writer *w) TT_ST_NONBLOCKING;
int64_t tt_st_writer_end_sample(const tt_st_writer *w) TT_ST_NONBLOCKING;
uint64_t tt_st_writer_cycles(const tt_st_writer *w) TT_ST_NONBLOCKING;
uint64_t tt_st_writer_discontinuities(const tt_st_writer *w) TT_ST_NONBLOCKING;
/* Copies up to `max` logged ranges; returns how many there are (may exceed max). */
uint32_t tt_st_writer_ranges(const tt_st_writer *w, tt_st_range *dst, uint32_t max);

/* 0.25 · sin(2π · ((s · 997) mod 48000) / 48000): a tone keyed by absolute sample time, so a
 * replayed or shifted sample shows up as a mismatch (M0-T8 replay test). Table lookup. */
float tt_st_tone(const tt_st_writer *w, int64_t sample_time) TT_ST_NONBLOCKING;

OSStatus tt_st_writer_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                             const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime,
                             AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime,
                             void *_Nullable inClientData) TT_ST_NONBLOCKING;

/* The writer cycle without Core Audio, for tests: fills `frames` interleaved frames of
 * `channels` channels whose first frame is output at sample time s0. */
void tt_st_writer_render(tt_st_writer *w, float *out, uint32_t frames, uint32_t channels, int64_t s0) TT_ST_NONBLOCKING;

typedef struct tt_st_recorder tt_st_recorder;

typedef struct tt_st_chunk {
    int64_t sample_time;   /* input sample time of the chunk's first frame */
    uint64_t host_time;    /* inInputTime->mHostTime */
    uint32_t frames;
    uint32_t offset;       /* index of the first frame in the sample buffer */
} tt_st_chunk;

/* Not real-time safe. */
tt_st_recorder *_Nullable tt_st_recorder_create(uint32_t capacity_frames, uint32_t max_chunks);
void tt_st_recorder_destroy(tt_st_recorder *_Nullable r);
void tt_st_recorder_reset(tt_st_recorder *r);

uint64_t tt_st_recorder_cycles(const tt_st_recorder *r) TT_ST_NONBLOCKING;
uint64_t tt_st_recorder_frames(const tt_st_recorder *r) TT_ST_NONBLOCKING;
uint64_t tt_st_recorder_nonzero(const tt_st_recorder *r) TT_ST_NONBLOCKING;
uint64_t tt_st_recorder_discontinuities(const tt_st_recorder *r) TT_ST_NONBLOCKING;
/* Callbacks whose frames did not fit (buffer or chunk log full). */
uint64_t tt_st_recorder_overflows(const tt_st_recorder *r) TT_ST_NONBLOCKING;
/* Read after the IOProc stopped. */
uint32_t tt_st_recorder_chunk_count(const tt_st_recorder *r);
uint32_t tt_st_recorder_chunks(const tt_st_recorder *r, tt_st_chunk *dst, uint32_t max);
uint32_t tt_st_recorder_sample_count(const tt_st_recorder *r);
uint32_t tt_st_recorder_samples(const tt_st_recorder *r, float *dst, uint32_t max);

OSStatus tt_st_recorder_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                               const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime,
                               AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime,
                               void *_Nullable inClientData) TT_ST_NONBLOCKING;

/* The recorder cycle without Core Audio, for tests: `data` has `stride` floats per frame
 * (NULL = the HAL gave no buffer, counted as zeros). */
void tt_st_recorder_append(tt_st_recorder *r, const float *_Nullable data, uint32_t frames, uint32_t stride,
                           int64_t s0, uint64_t host_time) TT_ST_NONBLOCKING;

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
