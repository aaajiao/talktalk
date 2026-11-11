#ifndef TT_RING_H
#define TT_RING_H

/* tt_ring: single-producer / single-consumer ring of mono Float32 frames
 * (ARCHITECTURE.md, "实时音频与生命周期约束"). The producer is a Core Audio IOProc; the consumer is the
 * audio worker. Lock-free: one atomic write index, one atomic read index, both monotonically
 * increasing 64-bit frame counters (they never wrap in practice), capacity a power of two.
 *
 * Overflow policy: the producer never blocks and never overwrites unread data. When the ring
 * is full the excess frames of that write are dropped and counted in `overruns`; the consumer
 * sees a gap it can detect through tt_ring_overrun_frames().
 *
 * The functions above the "Playout" section are the plain ring the enrollment and bench
 * recorders use; their behaviour is fixed. The Playout section (§3.3, M2) turns a ring into
 * ringO / ringO2: clause marks, pause at the next clause start, skip / flush with a 30 ms cut,
 * the 5 ms hold-back, and the 0.5 s producer lead limit. */

#include <stdbool.h>
#include <stdint.h>
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct tt_ring tt_ring;

/* Creates a ring holding at least `min_capacity_frames` frames (rounded up to a power of two,
 * at least 1024). Returns NULL on allocation failure. Not real-time safe. */
tt_ring *_Nullable tt_ring_create(uint32_t min_capacity_frames);
void tt_ring_destroy(tt_ring *_Nullable ring);

uint32_t tt_ring_capacity(const tt_ring *ring);

/* Producer side. Copies `frames` samples taken every `stride` floats from `src`
 * (stride 1 = contiguous mono; stride N = channel k of an N-channel interleaved buffer when
 * `src` points at sample k). Returns the number of frames stored (< frames on overflow). */
uint32_t tt_ring_write_strided(tt_ring *ring, const float *src, uint32_t frames, uint32_t stride) TT_NONBLOCKING;
/* Producer side: store `frames` zeros (used when an input buffer is missing). */
uint32_t tt_ring_write_zeros(tt_ring *ring, uint32_t frames) TT_NONBLOCKING;

/* Consumer side. Copies up to `max_frames` into dst; returns frames copied. */
uint32_t tt_ring_read(tt_ring *ring, float *dst, uint32_t max_frames) TT_NONBLOCKING;

/* Either side: frames written but not yet read. */
uint32_t tt_ring_available(const tt_ring *ring) TT_NONBLOCKING;

/* Total frames ever stored / dropped because the ring was full. */
uint64_t tt_ring_written_frames(const tt_ring *ring) TT_NONBLOCKING;
uint64_t tt_ring_overrun_frames(const tt_ring *ring) TT_NONBLOCKING;

/* Drops all unread frames. Call only while the producer is stopped. */
void tt_ring_reset(tt_ring *ring);

/* ---- Playout (ringO, ringO2; ARCHITECTURE.md, "实时音频与生命周期约束") -----------------------------------------
 *
 * Roles. One producer: PlayoutStage on the audio worker (writes with tt_ring_write_clause and
 * issues the control calls: pause, jump). One consumer: feedIOProc (ringO) or monitorIOProc
 * (ringO2), which reads only with tt_ring_playout_read. Do not mix tt_ring_read and
 * tt_ring_playout_read on one ring. Control calls must come from the producer thread (or be
 * serialized with its writes): a jump snapshots the write index at the call.
 *
 * Clause marks. A START mark (with the caller's 32-bit tag, e.g. a clause slot) sits at the
 * first frame of a clause; an END mark sits after the clause's last frame, i.e. after
 * isLast was written, including any inter-clause pause written for that clause. Put the pause
 * before END, so the next clause's START is its first audio frame (out.first_sample).
 *
 * Consumer behaviour, per call (all frames of dst are written, audio or zeros):
 *  - Hold-back: the last TT_RING_HOLD_FRAMES (5 ms) before the write index are only ever played
 *    as a fade-out. When the clause has ended (END at the write index) they fade out and the
 *    ring goes idle. When no END is there they fade out as an underrun: zeros follow, the
 *    underrun is counted, and playback resumes only once `resume_frames` frames beyond the
 *    hold-back are buffered (or the clause's END has arrived), with a 5 ms fade-in.
 *    resume_frames is capped at max_lead - hold-back: the writer cannot get further ahead, so
 *    a larger threshold could only be met by an END the lead limit keeps from being written.
 *  - Every restart from silence (first clause, after an underrun, after a pause, after a jump,
 *    after tt_ring_playout_suspend) fades in over TT_RING_FADE_IN_FRAMES (5 ms).
 *  - Pause (tt_ring_set_pause(true)): playback continues to the next START mark, fades out over
 *    the 5 ms before it, then outputs zeros with the read index parked on that START mark
 *    (tt_ring_is_parked). An idle ring parks at once. tt_ring_set_pause(false) resumes there.
 *  - Jump: TT_RING_JUMP_NEXT_START cuts the clause in progress: 30 ms fade-out from the current
 *    position (TT_RING_CUT_FADE_FRAMES, shorter if the target is closer), then the read index
 *    moves to the first START mark at or after it, or to the write index of the request call
 *    when there is none. TT_RING_JUMP_WRITE_INDEX (flush) does the same with the request's
 *    write index as the target, and also drops every mark pushed before the request (a START
 *    at the request's write index belongs to the flushed audio). A ring that is not playing
 *    jumps without a fade. A jump that drops the clause in progress (it moves the read index,
 *    or the ring had run dry inside the clause) leaves the reader idle, so the next clause
 *    starts like a first one (no rebuffer threshold); a parked reader stays parked.
 *  - Suspend (tt_ring_playout_suspend, every cycle the consumer gives its output to something
 *    else): the caller has already faded the ring to silence, so a fade-out segment in progress
 *    (cut, pause, END or underrun hold-back) completes at once, a pending jump happens at once
 *    without a fade, an idle ring parks if pause is requested, and a ring that was playing
 *    fades in when it is read again. A hold-back fade that holds the next clause's START stops
 *    on that START instead: the clause before has ended (TT_RING_EV_ENDED, no underrun), and
 *    the next one plays from its first frame and reports its first sample when read again.
 *  - Lead limit: tt_ring_write_clause stores at most tt_ring_lead_room() frames, so the writer
 *    never runs more than max_lead frames ahead of the reader (0.5 s for ringO). Refused frames
 *    are not overruns: the caller keeps them and retries.
 *
 * Fade shapes: tt_fade.h. Overrun policy is unchanged: nothing is ever overwritten. */

#define TT_RING_HOLD_FRAMES        240u   /* 5 ms at 48 kHz */
#define TT_RING_FADE_IN_FRAMES     240u   /* 5 ms */
#define TT_RING_CUT_FADE_FRAMES    1440u  /* 30 ms */
#define TT_RING_MAX_MARKS          256u   /* START + END marks not yet passed by the reader */
#define TT_RING_REPORT_MAX_STARTS  8u

/* Flags for tt_ring_write_clause. */
#define TT_RING_CLAUSE_START 1u
#define TT_RING_CLAUSE_END   2u

/* tt_ring_request_jump kinds. */
#define TT_RING_JUMP_NEXT_START  1u
#define TT_RING_JUMP_WRITE_INDEX 2u

/* tt_ring_playout_state values. */
#define TT_RING_STATE_IDLE     0u   /* nothing to play (start, after END, after a jump) */
#define TT_RING_STATE_PLAYING  1u
#define TT_RING_STATE_UNDERRUN 2u   /* ran dry mid-clause, waiting for resume_frames */
#define TT_RING_STATE_PARKED   3u   /* paused on a START mark */

/* tt_ring_playout_report.events bits. */
#define TT_RING_EV_UNDERRUN 1u   /* an underrun began; zeros start at report.zero_offset */
#define TT_RING_EV_RESUMED  2u   /* playback resumed after an underrun */
#define TT_RING_EV_ENDED    4u   /* a clause END was reached with nothing after it */
#define TT_RING_EV_PARKED   8u   /* the reader parked on a START mark */
#define TT_RING_EV_CUT      16u  /* a NEXT_START jump completed */
#define TT_RING_EV_FLUSHED  32u  /* a WRITE_INDEX jump completed */

/* Each event is reported at most once per call, with the dst index where it happened (the
 * first occurrence when it happened more than once). In feedIOProc's 10 ms cycles an event
 * cannot happen twice: a second END needs a whole clause within the cycle, a second underrun a
 * rebuffer (>= 80 ms) within it. */
typedef struct tt_ring_playout_report {
    uint32_t ring_frames;      /* frames taken from the ring (played, faded or cut) */
    uint32_t audio_frames;     /* frames of dst that carry ring audio (the rest are zeros) */
    uint32_t events;           /* TT_RING_EV_* */
    uint32_t zero_offset;      /* with TT_RING_EV_UNDERRUN: first zero frame in dst */
    uint32_t resumed_offset;   /* with TT_RING_EV_RESUMED */
    uint32_t ended_offset;     /* with TT_RING_EV_ENDED */
    uint32_t parked_offset;    /* with TT_RING_EV_PARKED */
    uint32_t cut_offset;       /* with TT_RING_EV_CUT / TT_RING_EV_FLUSHED */
    uint32_t cut_tag;          /* with EV_CUT / EV_FLUSHED: tag of the clause in progress */
    uint32_t cut_dropped;      /* frames skipped over by the jump (not played) */
    uint32_t start_count;      /* START marks whose first frame was played in this call */
    uint32_t start_tag[TT_RING_REPORT_MAX_STARTS];
    uint32_t start_offset[TT_RING_REPORT_MAX_STARTS]; /* index in dst of that first frame */
} tt_ring_playout_report;

/* Producer setup (not real-time): maximum frames the writer may be ahead of the reader.
 * 0 or more than the capacity means the capacity. */
void tt_ring_set_max_lead(tt_ring *ring, uint32_t frames);
uint32_t tt_ring_max_lead(const tt_ring *ring) TT_NONBLOCKING;

/* Producer: frames tt_ring_write_clause would store now. */
uint32_t tt_ring_lead_room(const tt_ring *ring) TT_NONBLOCKING;

/* Producer: stores n = min(frames, lead room) frames from src (NULL = zeros) and returns n.
 * TT_RING_CLAUSE_START pushes a START mark with `tag` at the current write index first, but only
 * when n > 0 or frames == 0: keep passing it until a call stores something.
 * TT_RING_CLAUSE_END pushes an END mark after the stored frames, but only when n == frames:
 * keep passing it until the clause's remainder is fully stored. If the mark queue is full
 * nothing is stored, 0 is returned and tt_ring_mark_overflows() counts it. */
uint32_t tt_ring_write_clause(tt_ring *ring, const float *_Nullable src, uint32_t frames,
                              uint32_t flags, uint32_t tag) TT_NONBLOCKING;

/* Producer control. Pause takes effect at the next START mark (see above). */
void tt_ring_set_pause(tt_ring *ring, bool paused) TT_NONBLOCKING;
bool tt_ring_pause_requested(const tt_ring *ring) TT_NONBLOCKING;
/* True while the reader is parked: it outputs zeros and its read index does not move. */
bool tt_ring_is_parked(const tt_ring *ring) TT_NONBLOCKING;

/* Producer control: NEXT_START refuses while a jump is pending. WRITE_INDEX supersedes a
 * pending jump, including a cut already fading. The target and mark boundary are snapshotted
 * together at this call; frames written afterwards are kept. */
bool tt_ring_request_jump(tt_ring *ring, uint32_t kind) TT_NONBLOCKING;
bool tt_ring_jump_pending(const tt_ring *ring) TT_NONBLOCKING;

/* Consumer: fills dst[0..frames) (audio or zeros) and returns frames. `resume_frames` is the
 * rebuffer threshold after an underrun (feedIOProc computes it adaptively, §3.3). */
uint32_t tt_ring_playout_read(tt_ring *ring, float *dst, uint32_t frames, uint32_t resume_frames,
                              tt_ring_playout_report *_Nullable report) TT_NONBLOCKING;
/* Consumer: this cycle's output does not come from the ring (feedIOProc gives it to ringP).
 * Call it every such cycle; see "Suspend" above. Events are reported at offset 0. */
void tt_ring_playout_suspend(tt_ring *ring, tt_ring_playout_report *_Nullable report) TT_NONBLOCKING;

uint32_t tt_ring_playout_state(const tt_ring *ring) TT_NONBLOCKING;
uint64_t tt_ring_playout_underruns(const tt_ring *ring) TT_NONBLOCKING;
uint64_t tt_ring_mark_overflows(const tt_ring *ring) TT_NONBLOCKING;

/* Drops data, marks, pending requests and reader state. Both sides stopped; not real-time. */
void tt_ring_playout_reset(tt_ring *ring);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
