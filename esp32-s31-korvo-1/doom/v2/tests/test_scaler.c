/*
 * Runs the real I_InitGraphics and I_FinishUpdate from i_video_fbdev.c
 * against a frame buffer in memory, and compares every byte of it with a
 * reference written separately below.
 *
 * The source file is included, not copied.  The few system calls it makes
 * on /dev/fb0 are pointed at the fakes in this file.
 *
 * Before each frame the whole frame buffer is filled with a pattern that
 * has no zero in it and changes from byte to byte.  After the frame, the
 * picture must be where the reference says, and every other byte must
 * still hold the pattern: the border, the padding at the end of each line
 * and whatever follows the last line.  So a stray store is seen whatever
 * it writes, black included.
 *
 * Usage: test_scaler XRES YRES PAD EXTRA [flags]
 *   PAD     bytes added to each line after the visible pixels
 *   EXTRA   bytes added to the mapping after the last line
 * Flags for the code under test: -aspect, -scaling N, -showfps
 * Flags for the test:
 *   -bpp N          frame buffer depth, 16 (default) or 32
 *   -rgb555         16 bpp with 5 bits of green
 *   -nommap         make mmap() fail
 *   -misalign N     hand out a mapping N bytes off word alignment
 *   -failmalloc N   make the Nth malloc() in the code under test fail
 *   -fpsval N       the number that -showfps draws
 *   -frames N       frames to draw and check (default 3)
 *   -step US        use a clock that moves on US microseconds a frame
 *   -exitline TEXT  what the exit line has to be, word for word
 *   -shown LIST     the numbers -showfps has to work out, in order
 *   -runms N        then keep drawing for N ms and check the counter
 *   -noframes       draw nothing, and check that the exit line stays quiet
 *   -card           draw a test card instead of noise
 *   -out FILE       write the visible screen to FILE as raw RGB565 (the
 *                   frame buffer is then left black around the picture,
 *                   as it is on the board)
 */
#define open            fake_open
#define ioctl           fake_ioctl
#define mmap            fake_mmap
#define lseek           fake_lseek
#define write           fake_write
#define atexit          fake_atexit
#define malloc          fake_malloc
#define clock_gettime   fake_clock_gettime
#include "i_video_fbdev.c"
#undef open
#undef ioctl
#undef mmap
#undef lseek
#undef write
#undef atexit
#undef malloc
#undef clock_gettime

#include <math.h>
#include <strings.h>

/* the real ones, which the headers above declared under the fake names */
int clock_gettime(clockid_t, struct timespec *);
void *malloc(size_t);
int pipe2(int [2], int);

#define GUARD 65536

/* the fake frame buffer */

static int t_xres, t_yres, t_bpp = 16, t_line, t_smem;
static int t_green = 6;
static int t_nommap, t_misalign, t_failmalloc;
static byte *t_arena;           /* guard, mapping, guard */
static byte *t_fb;              /* what mmap() hands out */
static byte *t_file;            /* what write() fills in */
static off_t t_pos;
static int t_bad_write;
static int t_mallocs;
static int t_seq, t_atexit_seq, t_input_seq;
static void (*t_exit_fn)(void);

int fake_open(const char *path, int flags, ...)
{
    return strcmp(path, "/dev/fb0") == 0 ? 100 : -1;
}

int fake_ioctl(int fd, int req, ...)
{
    va_list ap;
    void *arg;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (fd != 100)
        return -1;
    if (req == FBIOGET_VSCREENINFO) {
        struct fb_var_screeninfo *v = arg;

        memset(v, 0, sizeof(*v));
        v->xres = v->xres_virtual = t_xres;
        v->yres = v->yres_virtual = t_yres;
        v->bits_per_pixel = t_bpp;
        if (t_bpp == 16) {
            v->blue.length = 5;
            v->green.offset = 5;
            v->green.length = t_green;
            v->red.offset = 5 + t_green;
            v->red.length = 5;
        } else {
            v->blue.length = v->green.length = v->red.length = 8;
            v->green.offset = 8;
            v->red.offset = 16;
        }
        return 0;
    }
    if (req == FBIOGET_FSCREENINFO) {
        struct fb_fix_screeninfo *f = arg;

        memset(f, 0, sizeof(*f));
        f->line_length = t_line;
        f->smem_len = t_smem;
        return 0;
    }
    return -1;
}

void *fake_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    if (t_nommap || fd != 100 || len != (size_t)t_smem || off != 0)
        return MAP_FAILED;
    return t_fb;
}

off_t fake_lseek(int fd, off_t off, int whence)
{
    t_pos = off;
    return off;
}

ssize_t fake_write(int fd, const void *buf, size_t n)
{
    if (fd != 100 || t_pos < 0 || t_pos + n > (size_t)t_smem) {
        t_bad_write = 1;
        return -1;
    }
    memcpy(t_file + t_pos, buf, n);
    return n;
}

int fake_atexit(void (*fn)(void))
{
    t_exit_fn = fn;
    t_atexit_seq = ++t_seq;
    return 0;
}

/* Zeroed, like the fresh pages a large malloc() gets on the board. */
void *fake_malloc(size_t n)
{
    if (++t_mallocs == t_failmalloc)
        return NULL;
    return calloc(1, n);
}

/* The real clock, or with -step one that the test moves on by hand. */
static int t_step = -1;
static uint64_t t_clock_us = 4321987654ull;

int fake_clock_gettime(clockid_t id, struct timespec *ts)
{
    if (t_step < 0)
        return clock_gettime(id, ts);
    ts->tv_sec = t_clock_us / 1000000;
    ts->tv_nsec = t_clock_us % 1000000 * 1000;
    return 0;
}

/* what the rest of Doom would provide */

char **myargv;
int myargc;

int M_CheckParmWithArgs(char *check, int num_args)
{
    int i;

    for (i = 1; i < myargc - num_args; i++)
        if (!strcasecmp(check, myargv[i]))
            return i;
    return 0;
}

int M_CheckParm(char *check)
{
    return M_CheckParmWithArgs(check, 0);
}

void *Z_Malloc(int size, int tag, void *ptr) { return calloc(1, size); }
void Z_Free(void *ptr) { free(ptr); }

int I_InitInput(void)
{
    t_input_seq = ++t_seq;
    return 0;
}

/* the reference */

static int e_x, e_y, e_w, e_h;  /* where the picture should be */
static int e_write;             /* through write() instead of the mapping */
static int e_error;             /* nothing can be drawn: I_Error instead */
static const char *e_how;
static byte t_pal[768];
static char t_label[256];

static void expect(void)
{
    int fit = t_xres / 320 < t_yres / 200 ? t_xres / 320 : t_yres / 200;
    int mapped = t_bpp == 16 && !t_nommap && t_misalign % 4 == 0;
    int p = M_CheckParmWithArgs("-scaling", 1);
    int n = p ? atoi(myargv[p + 1]) : 0;

    if (n >= 1 && n <= fit) {
        e_how = "integer";
    } else if (mapped && !t_failmalloc && t_line % 2 == 0) {
        e_w = t_xres;
        e_h = t_yres;
        e_how = "fill";
        if (M_CheckParm("-aspect")) {
            e_how = "aspect";
            /* 4:3: three quarters as tall as it is wide */
            if (e_w * 3 > e_h * 4)
                e_w = e_h * 4 / 3;
            else
                e_h = e_w * 3 / 4;
        }
        e_x = (t_xres - e_w) / 2;
        e_y = (t_yres - e_h) / 2;
        return;
    } else {
        n = fit;
        e_how = "integer";
    }
    /* whole number scaling cannot make the picture smaller */
    e_error = n < 1;
    e_w = 320 * n;
    e_h = 200 * n;
    e_x = (t_xres - e_w) / 2;
    e_y = (t_yres - e_h) / 2;
    e_write = !(mapped && t_line % 4 == 0 && n >= 1);
}

void I_Error(char *error, ...)
{
    va_list ap;

    printf("I_Error: ");
    va_start(ap, error);
    vprintf(error, ap);
    va_end(ap);
    printf("\n%s %s: stopped with an error, nothing can be drawn\n",
           e_error ? "PASS" : "FAIL", t_label);
    exit(e_error ? 0 : 1);
}

static uint32_t ref_colour(int index)
{
    uint32_t r = gammatable[0][t_pal[index * 3]];
    uint32_t g = gammatable[0][t_pal[index * 3 + 1]];
    uint32_t b = gammatable[0][t_pal[index * 3 + 2]];

    if (t_bpp == 32)
        return r << 16 | g << 8 | b;
    if (t_green == 5)
        return (r >> 3) << 10 | (g >> 3) << 5 | b >> 3;
    return (r >> 3) << 11 | (g >> 2) << 5 | b >> 3;
}

/* The -showfps box, drawn from pictures of the digits. */
static const char *t_glyph[10][5] = {
    { "###", "#.#", "#.#", "#.#", "###" },
    { ".#.", "##.", ".#.", ".#.", "###" },
    { "###", "..#", "###", "#..", "###" },
    { "###", "..#", "###", "..#", "###" },
    { "#.#", "#.#", "###", "..#", "..#" },
    { "###", "#..", "###", "..#", "###" },
    { "###", "#..", "###", "#.#", "###" },
    { "###", "..#", "..#", "..#", "..#" },
    { "###", "#.#", "###", "#.#", "###" },
    { "###", "#.#", "###", "..#", "###" },
};

static int t_fpsval = -1;
static int b_x, b_y, b_w, b_h, b_s;     /* the box; b_s 0 when there is none */
static char b_text[16];

/* The box for the number that is on show while the frame is drawn. */
static void expect_box(int value)
{
    int n, cols;

    b_s = 0;
    if (!M_CheckParm("-showfps") || value < 0 || e_write || e_w == 0)
        return;
    n = sprintf(b_text, "%d", value > 999 ? 999 : value);
    cols = 4 * n + 1;
    b_s = e_h / 96 > 1 ? e_h / 96 : 1;
    while (b_s > 0 && (cols * b_s > e_w || 7 * b_s > e_h))
        b_s--;
    b_w = cols * b_s;
    b_h = 7 * b_s;
    b_x = e_x + e_w - b_w;
    b_y = e_y + e_h - b_h;
}

/* What the pixel at (x, y) should be; (x, y) is inside the picture. */
static uint32_t ref_pixel(int x, int y)
{
    int sx, sy;

    if (b_s && x >= b_x && y >= b_y) {
        int cx = (x - b_x) / b_s, cy = (y - b_y) / b_s;

        if (cy >= 1 && cy <= 5 && cx % 4 != 0
            && t_glyph[b_text[cx / 4] - '0'][cy - 1][cx % 4 - 1] == '#')
            return t_bpp == 16 && t_green == 5 ? 0x7fff : 0xffff;
        return 0;
    }

    /* the source pixel under the centre of this destination pixel */
    sx = (int)floor((x - e_x + 0.5) * 320.0 / e_w);
    sy = (int)floor((y - e_y + 0.5) * 200.0 / e_h);
    return ref_colour(I_VideoBuffer[sy * 320 + sx]);
}

/* What a byte holds before the frame, and still has to hold after it if
 * it is not part of the picture.  Never zero, and different from frame to
 * frame and from its neighbours. */
static int t_plain;             /* -out: leave it black instead */

static byte before_byte(long i, int frame)
{
    uint32_t h = (uint32_t)i * 2654435761u + (uint32_t)frame * 0x9e3779b1u;

    return t_plain ? 0 : 0x80 | (h >> 25);
}

static byte *t_before;          /* both buffers before the frame */
static byte *t_expect;          /* the one that is drawn in, after it */

static void build_expect(int frame)
{
    int bytes = t_bpp / 8;
    int x, y;
    long i;

    for (i = 0; i < t_smem; i++)
        t_before[i] = before_byte(i, frame);
    memcpy(t_expect, t_before, t_smem);

    /* write() sends whole lines from a buffer that malloc() zeroed, so it
     * is black beside the picture */
    if (e_write)
        memset(t_expect + e_y * t_line, 0, e_h * t_line);

    for (y = e_y; y < e_y + e_h; y++) {
        for (x = e_x; x < e_x + e_w; x++) {
            uint32_t v = ref_pixel(x, y);

            if (bytes == 2) {
                uint16_t v16 = v;

                memcpy(t_expect + y * t_line + x * 2, &v16, 2);
            } else {
                memcpy(t_expect + y * t_line + x * 4, &v, 4);
            }
        }
    }
}

/* The mouse has to be read once before anything is drawn and once when it
 * has all been drawn (see I_PollMouse in i_input_evdev_mouse.c). */
static int t_polls, t_poll_bad, t_watch_polls;

void I_PollMouse(void)
{
    const byte *buf = e_write ? t_file : t_fb;

    t_polls++;
    if (t_watch_polls && memcmp(buf, t_polls == 1 ? t_before : t_expect, t_smem) != 0)
        t_poll_bad++;
}

static int check_frame(int frame)
{
    const byte *buf = e_write ? t_file : t_fb;
    const byte *other = e_write ? t_fb : t_file;
    int bytes = t_bpp / 8;
    int x, y, bad = 0;
    long i;

    if (t_bad_write) {
        printf("  frame %d: write() outside the frame buffer\n", frame);
        return 1;
    }
    for (i = 0; i < GUARD + t_misalign; i++) {
        if (t_arena[i] != 0x5a) {
            printf("  frame %d: guard byte %ld before the mapping overwritten\n", frame, i);
            return 1;
        }
    }
    for (i = 0; i < GUARD; i++) {
        if (t_fb[t_smem + i] != 0x5a) {
            printf("  frame %d: guard byte %ld after the mapping overwritten\n", frame, i);
            return 1;
        }
    }
    /* the mapping when write() is used, and the other way round */
    for (i = 0; i < t_smem; i++) {
        if (other[i] != t_before[i]) {
            printf("  frame %d: byte %ld of the %s changed\n", frame, i,
                   e_write ? "mapping, with the picture going through write()"
                           : "file, with the picture going into the mapping");
            return 1;
        }
    }
    /* every pixel on the screen, inside the picture and outside it */
    for (y = 0; y < t_yres; y++) {
        for (x = 0; x < t_xres; x++) {
            long at = (long)y * t_line + x * bytes;
            int inside = x >= e_x && x < e_x + e_w && y >= e_y && y < e_y + e_h;
            uint32_t got = 0, want = 0;

            memcpy(&got, buf + at, bytes);
            memcpy(&want, t_expect + at, bytes);
            if (got != want && bad++ < 5)
                printf("  frame %d: (%d,%d)%s is 0x%x, should be 0x%x\n", frame, x, y,
                       inside ? "" : ", outside the picture,", (unsigned)got, (unsigned)want);
        }
        /* the padding after the visible pixels of each line */
        for (i = (long)y * t_line + t_xres * bytes; i < (long)(y + 1) * t_line; i++)
            if (buf[i] != t_expect[i] && bad++ < 5)
                printf("  frame %d: line %d padding byte %ld written\n", frame, y,
                       i - (long)y * t_line);
    }
    /* anything after the last line */
    for (i = (long)t_yres * t_line; i < t_smem; i++)
        if (buf[i] != t_expect[i] && bad++ < 5)
            printf("  frame %d: byte %ld after the last line written\n", frame, i);

    if (bad) {
        printf("  frame %d: %d wrong pixels or bytes\n", frame, bad);
    } else if (t_polls != 2 || t_poll_bad) {
        /* the frame is right, but it was not all there when the mouse was
         * read the second time, or it was begun before the first */
        printf("  frame %d: I_PollMouse called %d times, %d of them at the wrong moment; "
               "it should be once before the blit and once after\n", frame, t_polls, t_poll_bad);
        bad++;
    }
    return bad != 0;
}

/* Draw one frame of whatever is in I_VideoBuffer, and check all of it. */
static int draw_and_check(int frame)
{
    expect_box(fps_shown);
    build_expect(frame);
    memcpy(t_fb, t_before, t_smem);
    memcpy(t_file, t_before, t_smem);

    t_polls = t_poll_bad = 0;
    t_watch_polls = 1;
    I_FinishUpdate();
    t_watch_polls = 0;

    return check_frame(frame);
}

/* pictures */

static void put(int x, int y, int c)
{
    if (x >= 0 && x < 320 && y >= 0 && y < 200)
        I_VideoBuffer[y * 320 + x] = c;
}

static int in_circle(int x, int y)
{
    /* round on a 4:3 screen: 90 pixels across, 75 down */
    int dx = x - 160, dy = y - 100;

    return dx * dx * 25 + dy * dy * 36 <= 90 * 90 * 25;
}

static void digits(const char *s, int x0, int y0, int scale, int c)
{
    int i, x, y;

    for (i = 0; s[i]; i++)
        for (y = 0; y < 5 * scale; y++)
            for (x = 0; x < 3 * scale; x++)
                if (s[i] != ' ' && t_glyph[s[i] - '0'][y / scale][x / scale] == '#')
                    put(x0 + i * 4 * scale + x, y0 + y, c);
}

static const byte card_colours[10][3] = {
    { 0, 0, 0 }, { 255, 255, 255 }, { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 },
    { 255, 255, 0 }, { 0, 255, 255 }, { 255, 0, 255 }, { 128, 128, 128 }, { 40, 40, 48 },
};

static void make_card(void)
{
    int x, y;

    memset(t_pal, 0, sizeof(t_pal));
    memcpy(t_pal, card_colours, sizeof(card_colours));

    for (y = 0; y < 200; y++) {
        for (x = 0; x < 320; x++) {
            int c = 9;

            if (x % 20 == 0 || y % 20 == 0)
                c = 8;                                  /* grid */
            if (x == 0 || y == 0 || x == 319 || y == 199)
                c = 1;                                  /* the edge of the picture */
            if (in_circle(x, y) && !(in_circle(x - 1, y) && in_circle(x + 1, y)
                                     && in_circle(x, y - 1) && in_circle(x, y + 1)))
                c = 1;                                  /* circle */
            if (y == x * 199 / 319 || y == 199 - x * 199 / 319)
                c = 5;                                  /* diagonals */
            if (y >= 150 && y < 175 && x >= 40 && x < 280)
                c = (x - 40) / 30;                      /* colour bars */
            if (y >= 24 && y < 48) {
                if (x >= 24 && x < 72)
                    c = x & 1;                          /* 1 pixel columns */
                if (x >= 84 && x < 132)
                    c = y & 1;                          /* 1 pixel rows */
                if (x >= 144 && x < 192)
                    c = (x ^ y) & 1;                    /* checks */
            }
            put(x, y, c);
        }
    }
    for (y = 54; y < 62; y++)
        for (x = 24; x < 110; x++)
            put(x, y, 0);
    digits("0123456789 320 200", 26, 56, 1, 1);         /* small text */
    digits("0123456789", 204, 24, 2, 1);
}

static void make_noise(void)
{
    int i;

    for (i = 0; i < 320 * 200; i++)
        I_VideoBuffer[i] = rand() & 255;
    for (i = 0; i < 768; i++)
        t_pal[i] = rand() & 255;
}

static uint32_t now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int arg_int(char *name, int def)
{
    int p = M_CheckParmWithArgs(name, 1);

    return p ? atoi(myargv[p + 1]) : def;
}

static const char *arg_str(char *name)
{
    int p = M_CheckParmWithArgs(name, 1);

    return p ? myargv[p + 1] : NULL;
}

/* Runs the exit function and checks the line it prints on stderr: TEXT if
 * -exitline TEXT was given, and otherwise that it counts the frames, or
 * says nothing if there were none. */
static int check_exit_line(void)
{
    const char *want = arg_str("-exitline");
    char line[256], start[64];
    int p[2], saved, n;

    fflush(stderr);
    saved = dup(2);
    if (saved < 0 || pipe2(p, O_NONBLOCK) != 0)
        abort();
    dup2(p[1], 2);
    t_exit_fn();
    fflush(stderr);
    dup2(saved, 2);
    close(saved);
    close(p[1]);
    n = read(p[0], line, sizeof(line) - 1);
    close(p[0]);
    line[n > 0 ? n : 0] = 0;
    fputs(line, stderr);

    if (want != NULL) {
        n = strlen(want);
        if (strncmp(line, want, n) != 0 || strcmp(line + n, "\n") != 0) {
            printf("  the exit line should be \"%s\"\n", want);
            return 1;
        }
    } else if (fps_frames == 0) {
        if (line[0] != 0) {
            printf("  no frames drawn, but an exit line was printed\n");
            return 1;
        }
    } else {
        snprintf(start, sizeof(start), "fbdoom: %u frame", fps_frames);
        if (strncmp(line, start, strlen(start)) != 0 || strchr(line, '\n') == NULL) {
            printf("  the exit line does not begin \"%s\"\n", start);
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    int frames, runms, f, i, p, fails = 0;
    char shown[256] = "";
    const char *want;
    long l;

    if (argc < 5) {
        fprintf(stderr, "usage: %s XRES YRES PAD EXTRA [flags]\n", argv[0]);
        return 2;
    }
    myargc = argc;
    myargv = argv;

    t_xres = atoi(argv[1]);
    t_yres = atoi(argv[2]);
    t_bpp = arg_int("-bpp", 16);
    if (M_CheckParm("-rgb555"))
        t_green = 5;
    t_line = t_xres * (t_bpp / 8) + atoi(argv[3]);
    t_smem = t_line * t_yres + atoi(argv[4]);
    t_nommap = M_CheckParm("-nommap") != 0;
    t_misalign = arg_int("-misalign", 0);
    t_failmalloc = arg_int("-failmalloc", 0);
    t_fpsval = arg_int("-fpsval", -1);
    t_step = arg_int("-step", -1);
    t_plain = M_CheckParm("-out") != 0;
    frames = arg_int("-frames", 3);
    runms = arg_int("-runms", 0);

    t_arena = malloc(GUARD + t_misalign + t_smem + GUARD);
    t_file = calloc(1, t_smem);
    t_before = malloc(t_smem);
    t_expect = malloc(t_smem);
    if (t_arena == NULL || t_file == NULL || t_before == NULL || t_expect == NULL)
        abort();
    memset(t_arena, 0x5a, GUARD + t_misalign + t_smem + GUARD);
    t_fb = t_arena + GUARD + t_misalign;
    memset(t_fb, 0xa5, t_smem);         /* I_InitGraphics should clear this */

    p = snprintf(t_label, sizeof(t_label), "%dx%d", t_xres, t_yres);
    for (i = 3; i < argc && p < (int)sizeof(t_label); i++)
        p += snprintf(t_label + p, sizeof(t_label) - p, " %s", argv[i]);

    expect();
    if (e_write && t_line != t_xres * (t_bpp / 8)) {
        fprintf(stderr, "the reference cannot do the write() path with line padding\n");
        return 2;
    }

    I_InitGraphics();

    if (e_error) {
        printf("  carried on with a screen that nothing can be drawn on\n");
        printf("FAIL %s: no error\n", t_label);
        return 1;
    }

    /* The exit line has to be registered before the input code registers
     * its handler, or it would print while the VT is in graphics mode. */
    if (t_exit_fn == NULL || t_atexit_seq == 0 || t_input_seq == 0
        || t_atexit_seq > t_input_seq) {
        printf("  atexit handler missing or registered after I_InitInput\n");
        fails++;
    }

    /* The picture goes where the reference says, by the path it says. */
    if (dst_x != e_x || dst_y != e_y || dst_w != e_w || dst_h != e_h
        || (blit_mode == BLIT_WRITE) != e_write
        || (blit_mode == BLIT_SCALED) != (e_how[0] != 'i')) {
        printf("  chose %dx%d at (%d,%d) mode %d, expected %dx%d at (%d,%d) %s%s\n",
               dst_w, dst_h, dst_x, dst_y, blit_mode, e_w, e_h, e_x, e_y, e_how,
               e_write ? " by write()" : "");
        fails++;
    }

    /* The console image is cleared once, if there is a mapping. */
    for (l = 0; l < t_smem; l++) {
        if (t_fb[l] != (t_nommap ? 0xa5 : 0)) {
            printf("  I_InitGraphics left byte %ld of the mapping at 0x%02x\n", l, t_fb[l]);
            fails++;
            break;
        }
    }

    if (M_CheckParm("-noframes")) {
        fails += check_exit_line();
        printf("%s %s: no frames drawn\n", fails ? "FAIL" : "PASS", t_label);
        return fails != 0;
    }

    srand(t_xres * 31 + t_yres);
    for (f = 0; f < frames && !fails; f++) {
        unsigned int mark = fps_mark_frames;

        if (M_CheckParm("-card"))
            make_card();
        else
            make_noise();
        I_SetPalette(t_pal);
        if (t_fpsval >= 0)
            fps_set(t_fpsval);
        if (t_step >= 0 && f > 0)
            t_clock_us += t_step;
        fails += draw_and_check(f);

        /* note each number the code works out for -showfps */
        if (f > 0 && fps_mark_frames != mark && strlen(shown) < sizeof(shown) - 16)
            sprintf(shown + strlen(shown), "%s%d", shown[0] ? " " : "", fps_shown);
    }

    want = arg_str("-shown");
    if (want != NULL) {
        printf("  -showfps worked out: %s\n", shown);
        if (strcmp(shown, want) != 0) {
            printf("  it should have been: %s\n", want);
            fails++;
        }
    }

    if (runms) {
        uint32_t t0 = now_ms();

        fps_shown = -1;
        while (now_ms() - t0 < (uint32_t)runms)
            I_FinishUpdate();
        if (fps_shown < 1) {
            printf("  the counter did not update in %d ms\n", runms);
            fails++;
        }
        printf("  counter after %d ms: %d fps (under qemu)\n", runms, fps_shown);
        /* check the box with the number it worked out for itself */
        fails += draw_and_check(frames);
    }

    p = M_CheckParmWithArgs("-out", 1);
    if (p) {
        FILE *out = fopen(myargv[p + 1], "wb");
        int y;

        if (out == NULL || t_bpp != 16 || e_write) {
            printf("  cannot write %s\n", myargv[p + 1]);
            fails++;
        } else {
            for (y = 0; y < t_yres; y++)
                fwrite(t_fb + y * t_line, 2, t_xres, out);
            fclose(out);
        }
    }

    fails += check_exit_line();

    printf("%s %s: 320x200 -> %dx%d at (%d,%d), %s%s, %d frames checked\n",
           fails ? "FAIL" : "PASS", t_label, e_w, e_h, e_x, e_y, e_how,
           e_write ? " by write()" : "", f);
    return fails != 0;
}
