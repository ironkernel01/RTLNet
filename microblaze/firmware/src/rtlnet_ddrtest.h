/*
 * rtlnet_ddrtest.h -- DDR3 memory test on the cached 0x8000_0000 window
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the memory test behind the CLI command "ddr test". It runs on the DDR3
 * window as the processor sees it, through the 8 KiB instruction and 8 KiB
 * write-through data caches, with explicit cache maintenance around every read
 * that must come from the SDRAM. Three phases:
 *
 *   1. Data bus walking ones and zeros: one 16-byte line (the full 128-bit
 *      AXI4 beat, 16 DQ pins x 8 beats), 128 patterns of a single 1 and 128 of a
 *      single 0, at the first and at the last line of the tested region.
 *   2. Address bus test: a word pattern at every power-of-two word offset, the
 *      classic walking-address check (a stuck or shorted address line shows as an
 *      alias of two offsets). Offsets run up to the tested size, so a test of 512 MiB
 *      covers all 29 address lines of the module.
 *   3. Random fill and verify of the whole region: a 4 KiB block of pseudo-random
 *      words from a seeded xorshift32 generator, repeated with a per-block salt, written
 *      in 64 KiB chunks, then read back after the data cache is invalidated.
 *
 * Write rate and read rate are measured on phase 3 only (processor-driven: 32-bit
 * stores through the write-through cache, 16-byte line fills; the rates are those of this
 * access path, not the SDRAM peak). A write chunk is timed through the settle callback, so
 * the rate counts completed writes.
 *
 * Ordering: AXI4 does not order a read behind an earlier write of another channel. After
 * every batch of writes the test calls the settle callback (the CLI passes a function that
 * executes a fence and waits for the arbiter's write-in-flight flag to clear), then
 * invalidates the affected lines before reading them.
 *
 * Builds for the target (volatile accesses to the window) and for the host harness
 * (RTLNET_HOST_TEST: accesses go to the host memory model through
 * rtlnet_host_mem_read32 / rtlnet_host_mem_write32).
 *
 * This header holds the types and the function contract; the .c file holds the
 * per-function commentary.
 */
#ifndef RTLNET_DDRTEST_H
#define RTLNET_DDRTEST_H

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* uint32_t, uint64_t, uintptr_t */

#define DDRTEST_LINE_BYTES    16u        /* one AXI4 beat, one cache line */
#define DDRTEST_MIN_BYTES     4096u
#define DDRTEST_CHUNK_BYTES   65536u     /* timing and progress granularity of phase 3 */
#define DDRTEST_MAX_ERRORS    64u        /* a phase stops after this many mismatches */

/* Phase identifiers for the first-failure report. */
typedef enum {
    DDRTEST_PHASE_NONE = 0,
    DDRTEST_PHASE_DATA_BUS,
    DDRTEST_PHASE_ADDRESS_BUS,
    DDRTEST_PHASE_RANDOM
} ddrtest_phase_t;

typedef struct {
    uint32_t        size_bytes;       /* tested region, from the window base */
    int             pass;             /* 1 when no mismatch in any phase */
    uint32_t        data_errors;      /* mismatches per phase (each capped at DDRTEST_MAX_ERRORS) */
    uint32_t        addr_errors;
    uint32_t        random_errors;
    ddrtest_phase_t first_phase;      /* phase of the first mismatch (NONE on pass) */
    uintptr_t       first_addr;       /* address, expected and read word of the first mismatch */
    uint32_t        first_expected;
    uint32_t        first_actual;
    uint32_t        addr_offsets;     /* address lines exercised by phase 2 (offsets tested) */
    uint64_t        write_bytes;      /* phase 3 volume and elapsed ticks per direction */
    uint64_t        write_ticks;
    uint64_t        read_bytes;
    uint64_t        read_ticks;
} ddrtest_result_t;

/* Called after a batch of writes, before the matching reads: fence and wait for the writes
 * to reach the memory controller. May be NULL (no wait). */
typedef void (*ddrtest_settle_fn)(void);

/* Called between 64 KiB chunks of phase 3 with the percentage done (0..100); may be NULL. */
typedef void (*ddrtest_progress_fn)(unsigned percent);

/* Run the three phases on [base, base + size_bytes). size_bytes: a multiple of
 * DDRTEST_LINE_BYTES, at least DDRTEST_MIN_BYTES. seed: xorshift32 seed, non-zero.
 * Returns 0 when the test ran (read result->pass), -1 for a bad argument (NULL result,
 * unaligned base, size not a multiple of the line size or below the minimum, seed 0);
 * nothing is written to memory then. */
int ddrtest_run(uintptr_t base, uint32_t size_bytes, uint32_t seed, ddrtest_settle_fn settle,
                ddrtest_progress_fn progress, ddrtest_result_t *result);

/* Rate in MB/s (10^6 bytes per second) times 100, from a byte count and a tick count at
 * ticks_per_us ticks per microsecond. Returns 0 when ticks is 0. */
uint32_t ddrtest_rate_x100(uint64_t bytes, uint64_t ticks, uint32_t ticks_per_us);

#ifdef RTLNET_HOST_TEST
/* Provided by the host harness: the DDR3 window model. */
uint32_t rtlnet_host_mem_read32(uintptr_t addr);
void rtlnet_host_mem_write32(uintptr_t addr, uint32_t value);
#endif

#endif /* RTLNET_DDRTEST_H */
