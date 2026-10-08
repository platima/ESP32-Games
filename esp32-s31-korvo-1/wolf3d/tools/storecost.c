/*
 * storecost: what loads and stores cost on this machine, beside arithmetic.
 *
 * Written for the ESP32-S31-Korvo-1, where a frame of a game seems to cost
 * about what it stores to memory and not what it computes: with the LCD on,
 * the port runs its cache write-through, so every store goes out to the
 * PSRAM.  "Seems" is from one frame rate and a count of instructions and
 * stores on a PC.  This measures it directly, and tells apart things that a
 * frame rate cannot: a store of one byte from a store of four, memory that
 * is in the cache from memory that is not, going along a line of a picture
 * from going down a column of it.
 *
 * It touches nothing but its own memory (4 MiB): not the screen, not the
 * console.  Ctrl+C ends it.  It should run for under a minute.  Run it from
 * the panel's own console, as a game is: what a store costs may depend on
 * the LCD being on.
 *
 * Build:
 *   $M/host/bin/riscv32-buildroot-linux-musl-gcc -O2 -static -o storecost-korvo storecost.c
 *
 * Offered under the MIT licence.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define KB 1024
#define MB (1024 * 1024)

/* a picture as the game draws it, and one as large as the panel */
#define SMALLW 320
#define SMALLH 200
#define PANELW 800
#define PANELH 480

static uint8_t *mem;            /* 4 MiB, every page touched */
static uint32_t sink;

static double now(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* something the compiler cannot see through, so that a loop stays a loop */
#define OPAQUE(p) __asm__ volatile ("" : "+r" (p))

/*
 * Each of these does its thing "count" times, "step" bytes on each time,
 * over "size" bytes at "base".  At the end of the piece it starts again
 * "shift" bytes from where it started the last time: 0 to go over the same
 * places, 1 to go down the next column of a picture "step" wide.
 */
#define WALK(type, body) \
    uint32_t sum = 0; \
    size_t at = 0; \
    long i; \
    for (i = 0; i < count; i++) { \
        type *p = (type *) (void *) (base + at); \
        OPAQUE(p); \
        body; \
        at += step; \
        if (at >= size) \
            at -= size - shift; \
    } \
    return sum;

#define TEST(name) \
    static uint32_t __attribute__((noinline)) name(uint8_t *base, size_t size, size_t step, size_t shift, long count)

/* the loop alone: what the others cost without their load or store */
TEST(nothing)   { WALK(uint8_t,  sum += (uint32_t) (uintptr_t) p) }
TEST(store8)    { WALK(uint8_t,  *p = (uint8_t) i) }
TEST(store16)   { WALK(uint16_t, *p = (uint16_t) i) }
TEST(store32)   { WALK(uint32_t, *p = (uint32_t) i) }
TEST(load8)     { WALK(uint8_t,  sum += *p) }
TEST(load32)    { WALK(uint32_t, sum += *p) }
/* a store only where the byte is not what it should be already */
TEST(same8)     { WALK(uint8_t,  if (*p != 0x5a) *p = 0x5a) }

/* the C library's own, "count" bytes of it, "size" at a time */
TEST(libc_memset)
{
    long i;

    (void) step; (void) shift;
    for (i = 0; i < count; i += (long) size) {
        OPAQUE(base);
        memset(base, (int) i, size);
    }
    return 0;
}

TEST(libc_memcpy)
{
    long i;

    (void) step; (void) shift;
    for (i = 0; i < count; i += (long) size) {
        OPAQUE(base);
        memcpy(base, base + 2 * MB, size);
    }
    return 0;
}

typedef uint32_t (*test_fn)(uint8_t *, size_t, size_t, size_t, long);

/*
 * Run it for long enough to time, and print the time for one.  "unit" is
 * what the count has to be a whole number of: 1, or the size for the C
 * library's functions.
 */
static double run(const char *what, test_fn fn, size_t size, size_t step, size_t shift, long unit)
{
    long count = unit > 20000 ? unit : 20000;
    double t, each;

    /* once over the whole piece, untimed */
    sink += fn(mem, size, step, shift, unit > 1 ? unit : (long) (size / step) + 1);

    for (;;) {
        t = now();
        sink += fn(mem, size, step, shift, count);
        t = now() - t;
        if (t >= 0.25 || count >= 400000000L)
            break;
        /* aim past a quarter of a second, with at most 16 times as many */
        if (t < 0.3 / 16)
            count *= 16;
        else
            count = (long) (count * 0.3 / t) + 1;
        count = (count + unit - 1) / unit * unit;
    }
    each = t / count * 1e9;
    printf("  %-52s %8.1f ns\n", what, each);
    fflush(stdout);
    return each;
}

static double over(double with, double without)
{
    return with > without ? with - without : 0;
}

int main(void)
{
    double loop, b_in, b_out, w_out, col_small, col_panel, l_in, l_out, l_col;

    mem = malloc(4 * MB);
    if (!mem) {
        puts("storecost: no memory");
        return 1;
    }
    memset(mem, 0x5a, 4 * MB);

    puts("storecost: time for one of each, in nanoseconds");
    puts("");
    puts("the loop that all of these are, with no load or store in it");
    loop = run("one turn", nothing, 2 * MB, 1, 0, 1);
    puts("");
    puts("stores, one after the other");
    b_in = run("1 byte, the same 8 KB over and over", store8, 8 * KB, 1, 0, 1);
    run("4 bytes, the same 8 KB over and over", store32, 8 * KB, 4, 0, 1);
    b_out = run("1 byte, through 2 MiB", store8, 2 * MB, 1, 0, 1);
    run("2 bytes, through 2 MiB", store16, 2 * MB, 2, 0, 1);
    w_out = run("4 bytes, through 2 MiB", store32, 2 * MB, 4, 0, 1);
    puts("");
    puts("stores of 1 byte, down the columns of a picture");
    col_small = run("320x200", store8, SMALLW * SMALLH, SMALLW, 1, 1);
    col_panel = run("800x480", store8, PANELW * PANELH, PANELW, 1, 1);
    puts("");
    puts("loads");
    l_in = run("1 byte, the same 8 KB over and over", load8, 8 * KB, 1, 0, 1);
    l_out = run("1 byte, through 2 MiB", load8, 2 * MB, 1, 0, 1);
    run("4 bytes, through 2 MiB", load32, 2 * MB, 4, 0, 1);
    run("1 byte in every 64, through 2 MiB", load8, 2 * MB, 64, 0, 1);
    l_col = run("1 byte, down the columns of 320x200", load8, SMALLW * SMALLH, SMALLW, 1, 1);
    run("1 byte, down the columns of 800x480", load8, PANELW * PANELH, PANELW, 1, 1);
    puts("");
    puts("a store only if the byte is not right already, and it always is");
    memset(mem, 0x5a, 4 * MB);
    run("1 byte, through 2 MiB", same8, 2 * MB, 1, 0, 1);
    run("1 byte, down the columns of 320x200", same8, SMALLW * SMALLH, SMALLW, 1, 1);
    puts("");
    puts("the C library, for each byte");
    run("memset, 2 MiB at a time", libc_memset, 2 * MB, 1, 0, 2 * MB);
    run("memcpy, 2 MiB at a time", libc_memcpy, 2 * MB, 1, 0, 2 * MB);

    puts("");
    puts("Less the loop itself, that makes");
    printf("  a store of 1 byte    %6.0f ns in 8 KB, %6.0f ns through 2 MiB\n", over(b_in, loop), over(b_out, loop));
    printf("  a store of 4 bytes   %6.0f ns through 2 MiB\n", over(w_out, loop));
    printf("  a store down a column %5.0f ns at 320x200, %6.0f ns at 800x480\n", over(col_small, loop), over(col_panel, loop));
    printf("  a load of 1 byte     %6.0f ns in 8 KB, %6.0f ns through 2 MiB, %6.0f ns down a column\n",
        over(l_in, loop), over(l_out, loop), over(l_col, loop));
    return sink == 12345;   /* so that the sums are used */
}
