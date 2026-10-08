/* Checks the 16 bpp fast path against fbDOOM's original write() path. */
#include "i_video_fbdev.c"
#include <time.h>

char **myargv;
int myargc;
int M_CheckParmWithArgs(char *check, int num_args) { return 0; }
void *Z_Malloc(int size, int tag, void *ptr) { return malloc(size); }
void Z_Free(void *ptr) { free(ptr); }
int I_InitInput(void) { return 0; }

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void setup_fb(int scaling)
{
    memset(&fb, 0, sizeof fb);
    fb.xres = fb.xres_virtual = 800;
    fb.yres = fb.yres_virtual = 480;
    fb.bits_per_pixel = 16;
    fb.red.offset = 11;  fb.red.length = 5;
    fb.green.offset = 5; fb.green.length = 6;
    fb.blue.offset = 0;  fb.blue.length = 5;
    memset(&fix, 0, sizeof fix);
    fix.line_length = 1600;
    fix.smem_len = 800 * 480 * 2;
    fb_scaling = scaling;
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 20;
    int i, s, f, fails = 0;
    byte *a = malloc(768000);

    srand(1);
    I_VideoBuffer = malloc(SCREENWIDTH * SCREENHEIGHT);
    for (i = 0; i < SCREENWIDTH * SCREENHEIGHT; i++)
        I_VideoBuffer[i] = rand() & 255;
    for (i = 0; i < 256; i++) {
        colors[i].r = rand() & 255;
        colors[i].g = rand() & 255;
        colors[i].b = rand() & 255;
    }

    for (s = 1; s <= 2; s++) {
        double t0, t1, t2;
        int nz = 0;

        setup_fb(s);

        /* A: the original path, write() into a file standing in for /dev/fb0 */
        fb_mem = NULL;
        I_VideoBuffer_FB = calloc(768000, 1);
        fd_fb = open("fbA.bin", O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd_fb < 0 || ftruncate(fd_fb, 768000) != 0) { perror("fbA.bin"); return 2; }
        t0 = now();
        for (f = 0; f < frames; f++)
            I_FinishUpdate();
        t1 = now();
        if (pread(fd_fb, a, 768000, 0) != 768000) { perror("pread"); return 2; }
        close(fd_fb);
        free(I_VideoBuffer_FB);

        /* B: the fast path, into memory standing in for the mapped buffer */
        fb_mem = calloc(768000, 1);
        pal16_dirty = 1;
        t1 = now();
        for (f = 0; f < frames; f++)
            I_FinishUpdate();
        t2 = now();

        for (i = 0; i < 768000; i++)
            nz += a[i] != 0;
        i = memcmp(a, fb_mem, 768000);
        printf("scaling %d: original %.2f ms/frame, fast %.2f ms/frame (under qemu), "
               "%d non-zero bytes, %s\n", s,
               (t1 - t0) * 1000 / frames, (t2 - t1) * 1000 / frames, nz,
               i == 0 ? "IDENTICAL" : "DIFFERENT");
        fails += i != 0;
        free(fb_mem);
    }
    return fails;
}
