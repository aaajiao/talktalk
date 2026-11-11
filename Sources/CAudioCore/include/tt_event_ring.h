#ifndef TT_EVENT_RING_H
#define TT_EVENT_RING_H

/* tt_event_ring: lock-free host-time event ring (ARCHITECTURE.md, "实时音频与生命周期约束"). Producers are real-time IOProcs (feed and monitor run on different
 * IO threads, so several producers are allowed); the single consumer is the audio worker, which
 * converts host ticks with HostClock.nanos(fromMachTicks:) and writes EventLog lines.
 *
 * Bounded MPSC queue with a sequence number per slot (Vyukov): push never blocks and never
 * overwrites; a push into a full ring is dropped and counted. Events carry numbers only, never
 * audio or text. */

#include <stdbool.h>
#include <stdint.h>
#include "tt_rt.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

/* Event types. host_ticks is when it happened in mach ticks; for out.* / pt.* "arrival" times
 * it is the moment the sample reaches TalkTalk Mic (Feed output time + the driver's fixed
 * 480-frame lag, §8.3). */
#define TT_EV_OUT_FIRST_SAMPLE  1u   /* a = clause tag */
#define TT_EV_OUT_UNDERRUN      2u   /* host = arrival of the first zero */
#define TT_EV_OUT_RESUMED       3u   /* b = resume threshold in frames */
#define TT_EV_OUT_CLAUSE_CUT    4u   /* a = tag of the cut clause, b = frames skipped */
#define TT_EV_OUT_FLUSHED       5u   /* a = tag of the clause in progress, b = frames skipped */
#define TT_EV_OUT_PARKED        6u   /* ringO stopped on a clause start */
#define TT_EV_OUT_ENDED         7u   /* a clause END reached with nothing after it */
#define TT_EV_PT_OPEN_SEEN      16u  /* a = generation: first cycle feedIOProc played ringP */
#define TT_EV_PT_FIRST_SAMPLE   17u  /* a = generation, host = arrival, b = capture host ticks */
#define TT_EV_PT_UNDERRUN       18u  /* a = generation */
#define TT_EV_PT_LEASE_EXPIRED  19u  /* a = generation: open but the lease / deadline ran out */
#define TT_EV_PT_ZERO           20u  /* a = generation, host = arrival of the first zero after the close fade */
#define TT_EV_PT_DISCARDED      21u  /* a = generation, b = frames out of interval or expired */
#define TT_EV_MON_UNDERRUN      32u

/* Order: each producer pushes its events in output order, each with the arrival time of its own
 * frame. feedIOProc goes through a cycle chunk by chunk; the out.* events of one ringO read are
 * sorted by frame, and on the same frame what ends (ENDED, CLAUSE_CUT, FLUSHED, UNDERRUN) comes
 * before PARKED, then RESUMED, then FIRST_SAMPLE (so a cut that completes mid-read is pushed
 * before the next clause's first sample). An event that happens twice in one ringO read is pushed
 * once (tt_ring.h; not in 10 ms cycles). Feed and monitor events are not ordered against each
 * other: they come from different IO threads. */

/* Producer ids (tt_event.source). */
#define TT_EV_SRC_FEED    1u
#define TT_EV_SRC_MONITOR 2u

typedef struct tt_event {
    uint64_t host_ticks;
    uint64_t b;
    uint32_t a;
    uint16_t type;
    uint16_t source;
} tt_event;

typedef struct tt_event_ring tt_event_ring;

/* Capacity rounded up to a power of two (at least 64). Not real-time safe. */
tt_event_ring *_Nullable tt_event_ring_create(uint32_t min_capacity);
void tt_event_ring_destroy(tt_event_ring *_Nullable ring);
uint32_t tt_event_ring_capacity(const tt_event_ring *ring) TT_NONBLOCKING;

/* Producer (any thread). False when the ring is full (dropped and counted). */
bool tt_event_push(tt_event_ring *ring, const tt_event *event) TT_NONBLOCKING;
/* Convenience for the IOProcs. */
bool tt_event_push4(tt_event_ring *ring, uint16_t type, uint16_t source, uint64_t host_ticks,
                    uint32_t a, uint64_t b) TT_NONBLOCKING;

/* Consumer (one thread): pops up to `max` events in push order; returns how many. */
uint32_t tt_event_drain(tt_event_ring *ring, tt_event *dst, uint32_t max) TT_NONBLOCKING;

uint64_t tt_event_pushed(const tt_event_ring *ring) TT_NONBLOCKING;
uint64_t tt_event_dropped(const tt_event_ring *ring) TT_NONBLOCKING;

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
