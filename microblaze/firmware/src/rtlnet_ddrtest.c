/*
 * rtlnet_ddrtest.c -- DDR3 memory test on the cached 0x8000_0000 window
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Phases, ordering rules and the rate definition: rtlnet_ddrtest.h. Every read
 * that has to come from the SDRAM is preceded by the settle callback (after the
 * writes) and a cache invalidation of the lines read.
 */
#include "rtlnet_ddrtest.h"

#include "rtlnet_platform.h"

#define DDRT_BLOCK_WORDS    1024u       /* pseudo-random block, repeated with a salt */
#define DDRT_SALT_MUL       0x9E3779B1u /* odd multiplier: a different salt per block */
#define DDRT_LINE_WORDS     (DDRTEST_LINE_BYTES / 4u)
#define DDRT_PATTERN        0xAAAAAAAAu
#define DDRT_ANTIPATTERN    0x55555555u
#define DDRT_DATA_BITS      (DDRTEST_LINE_BYTES * 8u)

#ifdef RTLNET_HOST_TEST
static inline uint32_t ddrt_rd(uintptr_t addr)
{
    return rtlnet_host_mem_read32(addr);
}

static inline void ddrt_wr(uintptr_t addr, uint32_t value)
{
    rtlnet_host_mem_write32(addr, value);
}
#else
static inline uint32_t ddrt_rd(uintptr_t addr)
{
    return *(volatile const uint32_t *)addr;
}

static inline void ddrt_wr(uintptr_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
}
#endif

static uint32_t g_block[DDRT_BLOCK_WORDS];

/*
 * ddrt_next -- one step of the xorshift32 generator.
 * Returns: the next word (never 0 for a non-zero state).
 */
static uint32_t ddrt_next(uint32_t x)
{
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

/*
 * ddrt_note -- record a mismatch.
 * Steps:
 *   1. Count it in the phase's counter.
 *   2. Keep the first one of the whole run (phase, address, expected, actual).
 * Returns: nothing.
 */
static void ddrt_note(ddrtest_result_t *r, ddrtest_phase_t phase, uintptr_t addr, uint32_t expected, uint32_t actual)
{
    switch (phase) {
    case DDRTEST_PHASE_DATA_BUS:
        r->data_errors++;
        break;
    case DDRTEST_PHASE_ADDRESS_BUS:
        r->addr_errors++;
        break;
    default:
        r->random_errors++;
        break;
    }
    if (r->first_phase == DDRTEST_PHASE_NONE) {
        r->first_phase    = phase;
        r->first_addr     = addr;
        r->first_expected = expected;
        r->first_actual   = actual;
    }
}

/*
 * ddrt_settle -- wait for earlier writes (callback, when given).
 * Returns: nothing.
 */
static void ddrt_settle(ddrtest_settle_fn settle)
{
    if (settle != NULL) {
        settle();
    }
}

/*
 * ddrt_read_word -- read one word from the SDRAM, not from the cache.
 * Steps:
 *   1. Invalidate the cache line of the address.
 *   2. Load the word.
 * Returns: the word.
 */
static uint32_t ddrt_read_word(uintptr_t addr)
{
    plat_dcache_invalidate_range(addr, 4u);
    return ddrt_rd(addr);
}

/*
 * ddrt_walk_line -- walking ones, then walking zeros, across one 16-byte line.
 * Steps:
 *   1. For each of the 128 bit positions, write the line with only that bit set (or only that
 *      bit clear), settle, then read each word of the line from the SDRAM and compare.
 *   2. Stop the phase after DDRTEST_MAX_ERRORS mismatches.
 * Returns: nothing.
 */
static void ddrt_walk_line(uintptr_t line, ddrtest_settle_fn settle, ddrtest_result_t *r)
{
    for (unsigned invert = 0; invert < 2u; invert++) {
        for (unsigned bit = 0; bit < DDRT_DATA_BITS; bit++) {
            for (unsigned w = 0; w < DDRT_LINE_WORDS; w++) {
                uint32_t v = (w == (bit / 32u)) ? (1u << (bit % 32u)) : 0u;
                ddrt_wr(line + 4u * w, invert ? ~v : v);
            }
            plat_dcache_flush_range(line, DDRTEST_LINE_BYTES);
            ddrt_settle(settle);
            for (unsigned w = 0; w < DDRT_LINE_WORDS; w++) {
                uint32_t want = (w == (bit / 32u)) ? (1u << (bit % 32u)) : 0u;
                uint32_t got;
                if (invert) {
                    want = ~want;
                }
                got = ddrt_read_word(line + 4u * w);
                if (got != want) {
                    ddrt_note(r, DDRTEST_PHASE_DATA_BUS, line + 4u * w, want, got);
                }
            }
            if (r->data_errors >= DDRTEST_MAX_ERRORS) {
                return;
            }
        }
    }
}

/*
 * ddrt_address_bus -- walking-address test.
 * Steps:
 *   1. Write the pattern at every power-of-two word offset below the tested size.
 *   2. Write the antipattern at offset 0; every other offset must still hold the pattern.
 *   3. Restore offset 0. For each offset, write the antipattern there; offset 0 and every other
 *      offset must still hold the pattern; restore the pattern.
 *   Every check reads the SDRAM (settle, invalidate, load).
 * Returns: nothing; r->addr_offsets holds the number of offsets exercised.
 */
static void ddrt_address_bus(uintptr_t base, uint32_t words, ddrtest_settle_fn settle, ddrtest_result_t *r)
{
    uint32_t offsets[32];
    unsigned n = 0;

    for (uint32_t off = 1u; off < words && n < 32u; off <<= 1) {
        offsets[n++] = off;
    }
    r->addr_offsets = n;
    for (unsigned i = 0; i < n; i++) {
        ddrt_wr(base + 4u * offsets[i], DDRT_PATTERN);
    }
    ddrt_wr(base, DDRT_ANTIPATTERN);
    plat_dcache_flush_range(base, 4u);
    ddrt_settle(settle);
    for (unsigned i = 0; i < n; i++) {
        uint32_t got = ddrt_read_word(base + 4u * offsets[i]);
        if (got != DDRT_PATTERN) {
            ddrt_note(r, DDRTEST_PHASE_ADDRESS_BUS, base + 4u * offsets[i], DDRT_PATTERN, got);
        }
    }
    ddrt_wr(base, DDRT_PATTERN);
    for (unsigned t = 0; t < n && r->addr_errors < DDRTEST_MAX_ERRORS; t++) {
        uint32_t got;
        ddrt_wr(base + 4u * offsets[t], DDRT_ANTIPATTERN);
        plat_dcache_flush_range(base, 4u);
        plat_dcache_flush_range(base + 4u * offsets[t], 4u);
        ddrt_settle(settle);
        got = ddrt_read_word(base);
        if (got != DDRT_PATTERN) {
            ddrt_note(r, DDRTEST_PHASE_ADDRESS_BUS, base, DDRT_PATTERN, got);
        }
        for (unsigned i = 0; i < n; i++) {
            if (i == t) {
                continue;
            }
            got = ddrt_read_word(base + 4u * offsets[i]);
            if (got != DDRT_PATTERN) {
                ddrt_note(r, DDRTEST_PHASE_ADDRESS_BUS, base + 4u * offsets[i], DDRT_PATTERN, got);
            }
        }
        ddrt_wr(base + 4u * offsets[t], DDRT_PATTERN);
        plat_dcache_flush_range(base + 4u * offsets[t], 4u);
        ddrt_settle(settle);
    }
}

/*
 * ddrt_fill_block -- the pseudo-random block of phase 3.
 * Returns: nothing; g_block holds DDRT_BLOCK_WORDS words.
 */
static void ddrt_fill_block(uint32_t seed)
{
    uint32_t x = seed;
    for (unsigned i = 0; i < DDRT_BLOCK_WORDS; i++) {
        x = ddrt_next(x);
        g_block[i] = x;
    }
}

/*
 * ddrt_random_pass -- fill, settle, invalidate and verify the whole region.
 * Steps:
 *   1. Word i of the region is g_block[i % block] ^ ((i / block) * salt multiplier).
 *   2. Write in chunks of DDRTEST_CHUNK_BYTES; each chunk is timed from its first store to the end
 *      of the settle callback.
 *   3. Flush and invalidate the whole data cache once (outside the timed spans), then read the region back in the same chunks, each
 *      timed, comparing every word.
 *   4. Between chunks call the progress callback and plat_poll (outside the timed spans).
 *   5. Stop the verify after DDRTEST_MAX_ERRORS mismatches.
 * Returns: nothing.
 */
static void ddrt_random_pass(uintptr_t base, uint32_t size, ddrtest_settle_fn settle, ddrtest_progress_fn progress,
                             ddrtest_result_t *r)
{
    const uint32_t chunk_words = DDRTEST_CHUNK_BYTES / 4u;
    const uint32_t words       = size / 4u;

    for (uint32_t first = 0; first < words; first += chunk_words) {
        uint32_t n  = (words - first < chunk_words) ? (words - first) : chunk_words;
        uint32_t t0 = plat_ticks();
        for (uint32_t i = first; i < first + n; i++) {
            ddrt_wr(base + 4u * i, g_block[i % DDRT_BLOCK_WORDS] ^ ((i / DDRT_BLOCK_WORDS) * DDRT_SALT_MUL));
        }
        ddrt_settle(settle);
        r->write_ticks += (uint32_t)(plat_ticks() - t0);
        r->write_bytes += 4u * n;
        if (progress != NULL) {
            progress((unsigned)(((uint64_t)(first + n) * 50u) / words));
        }
        plat_poll();
    }
    plat_dcache_flush_all();
    plat_dcache_invalidate_all();
    for (uint32_t first = 0; first < words && r->random_errors < DDRTEST_MAX_ERRORS; first += chunk_words) {
        uint32_t n  = (words - first < chunk_words) ? (words - first) : chunk_words;
        uint32_t t0 = plat_ticks();
        uint32_t bad_i = 0;
        uint32_t bad_got = 0;
        uint32_t bad_want = 0;
        uint32_t bad_count = 0;
        for (uint32_t i = first; i < first + n; i++) {
            uint32_t want = g_block[i % DDRT_BLOCK_WORDS] ^ ((i / DDRT_BLOCK_WORDS) * DDRT_SALT_MUL);
            uint32_t got  = ddrt_rd(base + 4u * i);
            if (got != want) {
                if (bad_count == 0u) {
                    bad_i    = i;
                    bad_got  = got;
                    bad_want = want;
                }
                bad_count++;
            }
        }
        r->read_ticks += (uint32_t)(plat_ticks() - t0);
        r->read_bytes += 4u * n;
        if (bad_count != 0u) {
            /* The first bad word of the chunk is reported; the rest of the chunk is counted
             * (capped), not listed. */
            ddrt_note(r, DDRTEST_PHASE_RANDOM, base + 4u * bad_i, bad_want, bad_got);
            r->random_errors += (bad_count - 1u < DDRTEST_MAX_ERRORS) ? (bad_count - 1u) : DDRTEST_MAX_ERRORS;
        }
        if (progress != NULL) {
            progress((unsigned)(50u + ((uint64_t)(first + n) * 50u) / words));
        }
        plat_poll();
    }
}

/*
 * ddrtest_rate_x100 -- MB/s times 100.
 * Steps:
 *   1. bytes * ticks_per_us * 100 / ticks (10^6 bytes per second = bytes per microsecond).
 * Returns: the rate, 0 when ticks is 0.
 */
uint32_t ddrtest_rate_x100(uint64_t bytes, uint64_t ticks, uint32_t ticks_per_us)
{
    if (ticks == 0u) {
        return 0u;
    }
    return (uint32_t)((bytes * ticks_per_us * 100u) / ticks);
}

/*
 * ddrtest_run -- see rtlnet_ddrtest.h.
 * Steps:
 *   1. Validate the arguments before writing anything.
 *   2. Phase 1 at the first and the last line, phase 2, phase 3.
 *   3. pass = no mismatch anywhere.
 */
int ddrtest_run(uintptr_t base, uint32_t size_bytes, uint32_t seed, ddrtest_settle_fn settle, ddrtest_progress_fn progress,
                ddrtest_result_t *result)
{
    if (result == NULL || seed == 0u || (base % DDRTEST_LINE_BYTES) != 0u || size_bytes < DDRTEST_MIN_BYTES ||
        (size_bytes % DDRTEST_LINE_BYTES) != 0u) {
        return -1;
    }
    *result = (ddrtest_result_t){ 0 };
    result->size_bytes = size_bytes;
    result->first_phase = DDRTEST_PHASE_NONE;

    ddrt_walk_line(base, settle, result);
    ddrt_walk_line(base + size_bytes - DDRTEST_LINE_BYTES, settle, result);
    ddrt_address_bus(base, size_bytes / 4u, settle, result);
    ddrt_fill_block(seed);
    ddrt_random_pass(base, size_bytes, settle, progress, result);
    result->pass = (result->data_errors == 0u && result->addr_errors == 0u && result->random_errors == 0u) ? 1 : 0;
    return 0;
}
