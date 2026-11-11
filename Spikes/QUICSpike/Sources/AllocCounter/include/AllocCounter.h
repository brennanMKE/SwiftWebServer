#ifndef ALLOC_COUNTER_H
#define ALLOC_COUNTER_H

#include <stdint.h>
#include <stdbool.h>

/// Installs a process-wide malloc_logger hook that counts allocation events.
/// Rough instrument only: counts every malloc/calloc/realloc/valloc in the process
/// (including Network.framework's internal threads).
bool alloc_counter_install(void);
uint64_t alloc_counter_allocations(void);
uint64_t alloc_counter_bytes(void);

#endif
