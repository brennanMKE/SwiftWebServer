#include "AllocCounter.h"
#include <stdatomic.h>
#include <stddef.h>

// libsystem_malloc exports this hook (it is what MallocStackLogging uses). It is not in the
// public headers, so declare it here. type bit 2 = allocate, 4 = deallocate.
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                              uintptr_t result, uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

static _Atomic uint64_t g_allocs = 0;
static _Atomic uint64_t g_bytes = 0;

static void counting_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                            uintptr_t result, uint32_t skip) {
    (void)arg1; (void)arg3; (void)skip;
    if ((type & 2) && result != 0) {
        atomic_fetch_add_explicit(&g_allocs, 1, memory_order_relaxed);
        // For malloc with zone (type & 8), arg2 is the size.
        atomic_fetch_add_explicit(&g_bytes, (uint64_t)arg2, memory_order_relaxed);
    }
}

bool alloc_counter_install(void) {
    if (&malloc_logger == NULL) { return false; }
    malloc_logger = counting_logger;
    return true;
}

uint64_t alloc_counter_allocations(void) {
    return atomic_load_explicit(&g_allocs, memory_order_relaxed);
}

uint64_t alloc_counter_bytes(void) {
    return atomic_load_explicit(&g_bytes, memory_order_relaxed);
}
