#include "tt_event_ring.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* Bounded MPSC queue (Vyukov): slot i holds sequence i while free for position i, i + 1 once
 * written, i + capacity after the consumer took it. */
typedef struct event_cell {
    _Atomic uint64_t seq;
    tt_event event;
} event_cell;

struct tt_event_ring {
    _Alignas(128) _Atomic uint64_t enqueue_pos;
    _Atomic uint64_t pushed;
    _Atomic uint64_t dropped;
    _Alignas(128) _Atomic uint64_t dequeue_pos;   /* consumer only; atomic for the counters */
    uint32_t capacity;
    uint32_t mask;
    event_cell *cells;
};

/* A push that keeps losing the race to other producers gives up instead of spinning. */
#define PUSH_ATTEMPTS 64

tt_event_ring *_Nullable tt_event_ring_create(uint32_t min_capacity) {
    uint32_t cap = 64;
    while (cap < min_capacity && cap < (1u << 24)) cap <<= 1;
    tt_event_ring *ring = NULL;
    if (posix_memalign((void **)&ring, 128, sizeof(tt_event_ring)) != 0 || ring == NULL) return NULL;
    memset(ring, 0, sizeof(*ring));
    ring->cells = calloc(cap, sizeof(event_cell));
    if (ring->cells == NULL) {
        free(ring);
        return NULL;
    }
    ring->capacity = cap;
    ring->mask = cap - 1;
    for (uint32_t i = 0; i < cap; i++) atomic_init(&ring->cells[i].seq, i);
    atomic_init(&ring->enqueue_pos, 0);
    atomic_init(&ring->pushed, 0);
    atomic_init(&ring->dropped, 0);
    atomic_init(&ring->dequeue_pos, 0);
    return ring;
}

void tt_event_ring_destroy(tt_event_ring *_Nullable ring) {
    if (ring == NULL) return;
    free(ring->cells);
    free(ring);
}

uint32_t tt_event_ring_capacity(const tt_event_ring *ring) TT_NONBLOCKING { return ring->capacity; }

bool tt_event_push(tt_event_ring *ring, const tt_event *event) TT_NONBLOCKING {
    uint64_t pos = atomic_load_explicit(&ring->enqueue_pos, memory_order_relaxed);
    for (int attempt = 0; attempt < PUSH_ATTEMPTS; attempt++) {
        event_cell *cell = &ring->cells[pos & ring->mask];
        uint64_t seq = atomic_load_explicit(&cell->seq, memory_order_acquire);
        int64_t diff = (int64_t)(seq - pos);
        if (diff == 0) {
            if (atomic_compare_exchange_weak_explicit(&ring->enqueue_pos, &pos, pos + 1,
                                                      memory_order_relaxed, memory_order_relaxed)) {
                cell->event = *event;
                atomic_store_explicit(&cell->seq, pos + 1, memory_order_release);
                atomic_fetch_add_explicit(&ring->pushed, 1, memory_order_relaxed);
                return true;
            }
            /* pos was reloaded by the failed exchange */
        } else if (diff < 0) {
            break;   /* full */
        } else {
            pos = atomic_load_explicit(&ring->enqueue_pos, memory_order_relaxed);
        }
    }
    atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed);
    return false;
}

bool tt_event_push4(tt_event_ring *ring, uint16_t type, uint16_t source, uint64_t host_ticks,
                    uint32_t a, uint64_t b) TT_NONBLOCKING {
    tt_event e = { .host_ticks = host_ticks, .b = b, .a = a, .type = type, .source = source };
    return tt_event_push(ring, &e);
}

uint32_t tt_event_drain(tt_event_ring *ring, tt_event *dst, uint32_t max) TT_NONBLOCKING {
    uint64_t pos = atomic_load_explicit(&ring->dequeue_pos, memory_order_relaxed);
    uint32_t n = 0;
    while (n < max) {
        event_cell *cell = &ring->cells[pos & ring->mask];
        uint64_t seq = atomic_load_explicit(&cell->seq, memory_order_acquire);
        if (seq != pos + 1) break;   /* empty, or the producer of this slot is still writing */
        dst[n++] = cell->event;
        atomic_store_explicit(&cell->seq, pos + ring->capacity, memory_order_release);
        pos++;
    }
    atomic_store_explicit(&ring->dequeue_pos, pos, memory_order_relaxed);
    return n;
}

uint64_t tt_event_pushed(const tt_event_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_event_ring *)ring)->pushed, memory_order_relaxed);
}

uint64_t tt_event_dropped(const tt_event_ring *ring) TT_NONBLOCKING {
    return atomic_load_explicit(&((tt_event_ring *)ring)->dropped, memory_order_relaxed);
}
