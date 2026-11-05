#include "tt_pt_state.h"

#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* Sequence lock: writers (serialized by an os_unfair_lock, never taken on a real-time thread)
 * make `seq` odd, store the fields, make it even again. Readers retry a few times and give up
 * with valid = 0 rather than wait. Fields are relaxed atomics so a torn read is merely
 * detected, never undefined behaviour. */
struct tt_pt_state {
    _Alignas(128) _Atomic uint32_t seq;
    _Atomic uint32_t open;
    _Atomic uint32_t generation;
    _Atomic uint32_t source;
    _Atomic uint64_t open_ticks;
    _Atomic uint64_t lease_until;
    _Atomic uint64_t deadline;
    _Alignas(128) _Atomic uint64_t failed_reads;
    os_unfair_lock writer_lock;
};

#define READ_ATTEMPTS 8

tt_pt_state *_Nullable tt_pt_state_create(void) {
    tt_pt_state *s = NULL;
    if (posix_memalign((void **)&s, 128, sizeof(tt_pt_state)) != 0 || s == NULL) return NULL;
    memset(s, 0, sizeof(*s));
    atomic_init(&s->seq, 0);
    atomic_init(&s->open, 0);
    atomic_init(&s->generation, 0);
    atomic_init(&s->source, TT_PT_SOURCE_MIC);
    atomic_init(&s->open_ticks, 0);
    atomic_init(&s->lease_until, 0);
    atomic_init(&s->deadline, 0);
    atomic_init(&s->failed_reads, 0);
    s->writer_lock = OS_UNFAIR_LOCK_INIT;
    return s;
}

void tt_pt_state_destroy(tt_pt_state *_Nullable state) { free(state); }

static uint32_t write_begin(tt_pt_state *s) {
    os_unfair_lock_lock(&s->writer_lock);
    uint32_t q = atomic_load_explicit(&s->seq, memory_order_relaxed);
    atomic_store_explicit(&s->seq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    return q;
}

static void write_end(tt_pt_state *s, uint32_t q) {
    atomic_store_explicit(&s->seq, q + 2, memory_order_release);
    os_unfair_lock_unlock(&s->writer_lock);
}

#define LOAD(f) atomic_load_explicit(&s->f, memory_order_relaxed)
#define STORE(f, v) atomic_store_explicit(&s->f, (v), memory_order_relaxed)

uint32_t tt_pt_state_open(tt_pt_state *s, uint32_t source, uint64_t open_ticks,
                          uint64_t lease_until_ticks, uint64_t deadline_ticks) {
    uint32_t q = write_begin(s);
    uint32_t gen = LOAD(generation) + 1;
    STORE(generation, gen);
    STORE(source, source == TT_PT_SOURCE_SELF_TEST ? TT_PT_SOURCE_SELF_TEST : TT_PT_SOURCE_MIC);
    STORE(open_ticks, open_ticks);
    STORE(deadline, deadline_ticks);
    STORE(lease_until, lease_until_ticks < deadline_ticks ? lease_until_ticks : deadline_ticks);
    STORE(open, 1);
    write_end(s, q);
    return gen;
}

bool tt_pt_state_renew(tt_pt_state *s, uint32_t generation, uint64_t lease_until_ticks) {
    uint32_t q = write_begin(s);
    bool ok = LOAD(open) != 0 && LOAD(generation) == generation;
    if (ok) {
        uint64_t cur = LOAD(lease_until);
        uint64_t dl = LOAD(deadline);
        uint64_t next = lease_until_ticks > cur ? lease_until_ticks : cur;
        if (next > dl) next = dl;
        STORE(lease_until, next);
    }
    write_end(s, q);
    return ok;
}

bool tt_pt_state_close(tt_pt_state *s, uint32_t generation, uint64_t close_ticks) {
    uint32_t q = write_begin(s);
    bool ok = LOAD(open) != 0 && LOAD(generation) == generation;
    if (ok) {
        STORE(open, 0);
        uint64_t cur = LOAD(lease_until);
        if (close_ticks < cur) STORE(lease_until, close_ticks);
    }
    write_end(s, q);
    return ok;
}

tt_pt_snapshot tt_pt_state_read(const tt_pt_state *state) TT_NONBLOCKING {
    tt_pt_state *s = (tt_pt_state *)state;
    for (int attempt = 0; attempt < READ_ATTEMPTS; attempt++) {
        uint32_t q1 = atomic_load_explicit(&s->seq, memory_order_acquire);
        if (q1 & 1u) continue;
        tt_pt_snapshot snap = {
            .valid = 1,
            .open = LOAD(open),
            .generation = LOAD(generation),
            .source = LOAD(source),
            .open_ticks = LOAD(open_ticks),
            .lease_until_ticks = LOAD(lease_until),
            .deadline_ticks = LOAD(deadline),
        };
        atomic_thread_fence(memory_order_acquire);
        uint32_t q2 = atomic_load_explicit(&s->seq, memory_order_relaxed);
        if (q1 == q2) return snap;
    }
    atomic_fetch_add_explicit(&s->failed_reads, 1, memory_order_relaxed);
    return (tt_pt_snapshot){ .valid = 0 };
}

uint64_t tt_pt_state_failed_reads(const tt_pt_state *state) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_pt_state *)state)->failed_reads, memory_order_relaxed);
}
