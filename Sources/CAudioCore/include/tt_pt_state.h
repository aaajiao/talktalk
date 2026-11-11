#ifndef TT_PT_STATE_H
#define TT_PT_STATE_H

/* tt_pt_state: the passthrough switch shared by PassthroughGate (writer) and feedIOProc and
 * PassthroughGate.admit (readers) (ARCHITECTURE.md, "实时音频与生命周期约束"):
 *   { open, generation, source, open time, lease until, hard deadline }.
 *
 * Times are host times in mach ticks (AudioTimeStamp.mHostTime units), so the IOProc compares
 * them with its own timestamps without any clock conversion. Swift converts with
 * HostClock.machTicks(fromNanos:) / HostClock.nanos(fromMachTicks:), the only conversion.
 *
 * Writers: any non-real-time threads (PassthroughKey on the key-tap thread renews the lease,
 * PassthroughGate opens and closes); they serialize on an internal os_unfair_lock, held for a
 * few stores. Readers never block: a sequence lock gives them a consistent snapshot; a reader that
 * keeps colliding with writers gets valid = 0, which every caller treats as closed.
 *
 * Generation: every open bumps it and returns the new value; PassthroughStage tags ringP blocks
 * with it, so blocks from an earlier open are never played. A switch between .mic and
 * .selfTest is always a close and a new open, hence a new generation. */

#include <stdbool.h>
#include <stdint.h>
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/* The source and the Feed channel are one value and cannot be combined differently
 * (§3.8 privacy invariant 1, `--self-test --passthrough`). */
#define TT_PT_SOURCE_MIC       0u   /* microphone → Feed channel 1 (index 0) → TalkTalk Mic */
#define TT_PT_SOURCE_SELF_TEST 1u   /* synthetic pulses → Feed channel 2 (index 1) → Test Mic */

static inline uint32_t tt_pt_source_channel(uint32_t source) TT_NONBLOCKING {
    return source == TT_PT_SOURCE_SELF_TEST ? 1u : 0u;
}

typedef struct tt_pt_snapshot {
    uint32_t valid;               /* 0: no consistent read (treat as closed) */
    uint32_t open;
    uint32_t generation;
    uint32_t source;              /* TT_PT_SOURCE_* */
    uint64_t open_ticks;          /* passthrough really opened (the admit lower bound) */
    uint64_t lease_until_ticks;   /* lease end; set to the close time on close */
    uint64_t deadline_ticks;      /* open + 30 s (maxHoldS); the lease never passes it */
} tt_pt_snapshot;

typedef struct tt_pt_state tt_pt_state;

/* Not real-time safe. A new state is closed, generation 0. */
tt_pt_state *_Nullable tt_pt_state_create(void);
void tt_pt_state_destroy(tt_pt_state *_Nullable state);

/* Writer: opens with a new generation (returned). lease_until is clamped to deadline. */
uint32_t tt_pt_state_open(tt_pt_state *state, uint32_t source, uint64_t open_ticks,
                          uint64_t lease_until_ticks, uint64_t deadline_ticks);
/* Writer: extends the lease of the open `generation` (clamped to its deadline; a lease is
 * never shortened here). False if that generation is not the open one. Once feedIOProc has
 * seen a generation not live (lease over), it never plays it again: a late renewal changes
 * nothing for the IOProc and a new open is needed. */
bool tt_pt_state_renew(tt_pt_state *state, uint32_t generation, uint64_t lease_until_ticks);
/* Writer: closes `generation` if it is the open one: open = 0 and the lease ends at
 * min(lease, close_ticks), so no frame captured at or after the close is ever played.
 * False if `generation` is not the open one: a newer open stays untouched, and a second close
 * of the same generation changes nothing (as InMemoryPassthroughStateSink). */
bool tt_pt_state_close(tt_pt_state *state, uint32_t generation, uint64_t close_ticks);

/* Reader (real-time safe). */
tt_pt_snapshot tt_pt_state_read(const tt_pt_state *state) TT_NONBLOCKING;
/* Reads that gave up after colliding with writers (they returned valid = 0). */
uint64_t tt_pt_state_failed_reads(const tt_pt_state *state) TT_NONBLOCKING;

/* End of the window in which captured frames may be played: min(lease, deadline). */
static inline uint64_t tt_pt_snapshot_valid_until(const tt_pt_snapshot *s) TT_NONBLOCKING {
    return s->lease_until_ticks < s->deadline_ticks ? s->lease_until_ticks : s->deadline_ticks;
}

/* Open, consistent, and `now` before the lease end and the deadline. */
static inline bool tt_pt_snapshot_live(const tt_pt_snapshot *s, uint64_t now_ticks) TT_NONBLOCKING {
    return s->valid != 0 && s->open != 0 && now_ticks < tt_pt_snapshot_valid_until(s);
}

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
