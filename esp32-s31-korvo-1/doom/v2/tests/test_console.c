/*
 * Runs the real start-up, key handling and exit code against a fake VT and
 * a fake /dev/fb0, and checks what happens in what order: the console must
 * be back in text mode before anything is printed on the way out, and it
 * must be put back on every way out.
 *
 * i_video_fbdev.c, i_input_tty.c, i_input_evdev_mouse.c and i_system.c are
 * compiled as they are, with open(), close(), ioctl(), mmap(), tcgetattr(),
 * tcsetattr() and tcflush() renamed on the compiler command line to the
 * fakes below.
 *
 * Each scenario runs in a child process, so that its real exit status and
 * its output can both be checked.  The state of the fake VT is kept in
 * memory that the parent shares, so the parent can see how the child left
 * it, whatever ended the child.
 *
 * Usage: test_console SCENARIO      (with no argument, it lists them)
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <linux/fb.h>
#include <linux/kd.h>

#include "doomtype.h"
#include "d_event.h"
#include "doomkeys.h"
#include "i_system.h"
#include "i_video.h"
#include "m_argv.h"
#include "m_misc.h"
#include "z_zone.h"

void I_GetEvent(void);

/* the fake VT and frame buffer */

#define FB_FD 100
#define ORIG_KBMODE K_UNICODE

static struct vt {
    int mode;
    int kbmode;
    struct termios term;
} *vt;

static int kb_rd = -1, kb_wr = -1;      /* a pipe stands in for /dev/tty */
static int kb_open;                     /* the code under test has it open */
static const char *t_inject = "";       /* the call that is made to fail */

int fake_open(const char *path, int flags, ...)
{
    int p[2];

    if (strcmp(path, "/dev/fb0") == 0)
        return FB_FD;
    if (strcmp(path, "/dev/tty") == 0) {
        if (pipe(p) != 0)
            abort();
        kb_rd = p[0];
        kb_wr = p[1];
        kb_open = 1;
        return kb_rd;
    }
    errno = ENOENT;     /* no /dev/input/eventN here */
    return -1;
}

/* Once the keyboard descriptor is closed, nothing more can be done to the
 * VT through it. */
int fake_close(int fd)
{
    if (fd == kb_rd && kb_open) {
        kb_open = 0;
        fprintf(stderr, "[vt] closed\n");
    }
    return close(fd);
}

static int is_kb(int fd)
{
    if (fd == kb_rd && kb_open)
        return 1;
    errno = fd == kb_rd ? EBADF : ENOTTY;
    return 0;
}

int fake_ioctl(int fd, int req, ...)
{
    va_list ap;
    void *arg;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (fd == FB_FD && req == FBIOGET_VSCREENINFO) {
        struct fb_var_screeninfo *v = arg;

        memset(v, 0, sizeof(*v));
        v->xres = v->xres_virtual = 800;
        v->yres = v->yres_virtual = 480;
        v->bits_per_pixel = 16;
        v->red.offset = 11;
        v->red.length = 5;
        v->green.offset = 5;
        v->green.length = 6;
        v->blue.length = 5;
        return 0;
    }
    if (fd == FB_FD && req == FBIOGET_FSCREENINFO) {
        struct fb_fix_screeninfo *f = arg;

        memset(f, 0, sizeof(*f));
        f->line_length = 1600;
        f->smem_len = 1600 * 480;
        return 0;
    }
    if (!is_kb(fd))
        return -1;

    switch (req) {
    case KDGKBTYPE:
        *(int *)arg = KB_101;
        return 0;
    case KDGKBMODE:
        *(int *)arg = vt->kbmode;
        return 0;
    case KDSKBMODE:
        if ((long)arg == K_MEDIUMRAW && !strcmp(t_inject, "KDSKBMODE")) {
            errno = EPERM;
            return -1;
        }
        vt->kbmode = (long)arg;
        fprintf(stderr, "[vt] KDSKBMODE %s\n", vt->kbmode == K_MEDIUMRAW ? "K_MEDIUMRAW"
                : vt->kbmode == ORIG_KBMODE ? "as it was" : "something else");
        return 0;
    case KDGETMODE:
        *(int *)arg = vt->mode;
        return 0;
    case KDSETMODE:
        vt->mode = (long)arg;
        fprintf(stderr, "[vt] KDSETMODE %s\n", vt->mode == KD_GRAPHICS ? "KD_GRAPHICS"
                : vt->mode == KD_TEXT ? "KD_TEXT" : "something else");
        return 0;
    }
    errno = EINVAL;
    return -1;
}

static void orig_term(struct termios *t)
{
    memset(t, 0, sizeof(*t));
    t->c_iflag = ICRNL | IXON;
    t->c_oflag = OPOST | ONLCR;
    t->c_lflag = ECHO | ICANON | ISIG;
}

int fake_tcgetattr(int fd, struct termios *t)
{
    if (!is_kb(fd))
        return -1;
    if (!strcmp(t_inject, "TCGETATTR")) {
        errno = EIO;
        return -1;
    }
    *t = vt->term;
    return 0;
}

int fake_tcsetattr(int fd, int act, const struct termios *t)
{
    struct termios o;

    if (!is_kb(fd))
        return -1;
    vt->term = *t;
    orig_term(&o);
    fprintf(stderr, "[vt] tcsetattr %s\n", memcmp(t, &o, sizeof(o)) == 0 ? "as it was"
            : (t->c_lflag & (ECHO | ICANON | ISIG)) == 0 ? "raw" : "something else");
    return 0;
}

/* Throws away the key bytes that nobody read, as the tty would. */
int fake_tcflush(int fd, int queue)
{
    unsigned char c;
    int n = 0, i;

    if (!is_kb(fd))
        return -1;
    if (queue == TCIFLUSH && ioctl(kb_rd, FIONREAD, &n) == 0) {
        for (i = 0; i < n; i++)
            if (read(kb_rd, &c, 1) != 1)
                abort();
    }
    fprintf(stderr, "[vt] tcflush%s: %d unread key bytes dropped\n",
            queue == TCIFLUSH ? "" : " of the wrong queue", n);
    return 0;
}

void *fake_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    return fd == FB_FD ? calloc(1, len) : MAP_FAILED;
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

/* -nogui keeps I_Error from running zenity */
boolean M_ParmExists(char *check)
{
    return strcmp(check, "-nogui") == 0 || M_CheckParm(check) != 0;
}

boolean M_StrToInt(const char *str, int *result)
{
    return sscanf(str, "%i", result) == 1;
}

int M_vsnprintf(char *buf, size_t buf_len, const char *s, va_list args)
{
    return vsnprintf(buf, buf_len, s, args);
}

int M_snprintf(char *buf, size_t buf_len, const char *s, ...)
{
    va_list args;
    int n;

    va_start(args, s);
    n = vsnprintf(buf, buf_len, s, args);
    va_end(args);
    return n;
}

void *Z_Malloc(int size, int tag, void *ptr) { return calloc(1, size); }
void Z_Free(void *ptr) { free(ptr); }

void D_PostEvent(event_t *ev)
{
    if (ev->type == ev_mouse)
        fprintf(stderr, "[event] mouse %d %d %d\n", ev->data1, ev->data2, ev->data3);
    else
        fprintf(stderr, "[event] %s 0x%02x\n", ev->type == ev_keydown ? "keydown" : "keyup",
                ev->data1);
}

/* Stand-ins for the exit functions that d_main.c registers, in the same
 * order and with the same run-on-error flags (d_main.c 1169, 1360, 1510). */
static int timingdemo;

static void D_Endoom(void)
{
    fprintf(stderr, "[exit function] D_Endoom\n");
}

static void M_SaveDefaults(void)
{
    fprintf(stderr, "[exit function] M_SaveDefaults\n");
}

static void G_CheckDemoStatus(void)
{
    if (timingdemo) {
        timingdemo = 0;
        I_Error("timed %i gametics in %i realtics (%f fps)", 3, 1, 105.0f);
    }
}

/* scenarios */

static const struct {
    const char *name;
    int sig;
} signals[] = {
    { "segv", SIGSEGV }, { "sigbus", SIGBUS }, { "sigill", SIGILL }, { "sigfpe", SIGFPE },
    { "sigabrt", SIGABRT }, { "sigterm", SIGTERM }, { "sighup", SIGHUP },
    { "sigint", SIGINT }, { "sigquit", SIGQUIT }, { "sigpipe", SIGPIPE },
    { "sigalrm", SIGALRM }, { "sigusr1", SIGUSR1 }, { "sigusr2", SIGUSR2 },
};

#define NSIGNALS ((int)(sizeof(signals) / sizeof(signals[0])))

static void start(int demo)
{
    I_AtExit(D_Endoom, false);
    I_AtExit(M_SaveDefaults, false);
    I_AtExit((atexit_func_t)G_CheckDemoStatus, true);
    timingdemo = demo;
}

static void frames(int n)
{
    static byte palette[768];

    I_SetPalette(palette);
    while (n--)
        I_FinishUpdate();
}

/* Key bytes as the VT sends them in medium raw mode: the keycode, with
 * bit 7 set on release.  The list ends with -1. */
static int send_keys(const char *what, int each, va_list ap)
{
    int k, n = 0;
    unsigned char c;

    fprintf(stderr, "[test] %s\n", what);
    while ((k = va_arg(ap, int)) >= 0) {
        c = k;
        if (write(kb_wr, &c, 1) != 1)
            abort();
        if (each)
            I_GetEvent();
        n++;
    }
    return n;
}

/* all the bytes at once, then enough calls of I_GetEvent to read them */
static void keys(const char *what, ...)
{
    va_list ap;
    int n;

    va_start(ap, what);
    n = send_keys(what, 0, ap);
    va_end(ap);
    while (n-- >= 0)
        I_GetEvent();
}

/* a call of I_GetEvent after every byte */
static void keys_slowly(const char *what, ...)
{
    va_list ap;

    va_start(ap, what);
    send_keys(what, 1, ap);
    va_end(ap);
    I_GetEvent();
}

/* bytes that are left unread */
static void keys_unread(const char *what, ...)
{
    va_list ap;

    va_start(ap, what);
    send_keys(what, 0, ap);
    va_end(ap);
}

#define LCTRL 0x1d
#define RCTRL 0x61
#define LALT 0x38
#define RALT 0x64
#define BKSP 0x0e
#define UP 0x80
/* keycode 157 as medium raw mode sends it: three bytes, of which the last
 * two look like the releases of Esc and of Left Ctrl */
#define MEDIA_DOWN 0x00, 0x81, 0x9d
#define MEDIA_UP 0x80, 0x81, 0x9d

static volatile int t_forever = 1;

static int __attribute__((noinline)) recurse(int n)
{
    volatile char pad[4096];

    pad[0] = n;
    return t_forever ? recurse(n + 1) + pad[0] : 0;
}

static void scenario(const char *name)
{
    int i;

    if (!strcmp(name, "error-early")) {
        start(0);
        I_Error("W_InitFiles: no files found");
    }
    if (!strcmp(name, "kbmode-fails"))
        t_inject = "KDSKBMODE";
    if (!strcmp(name, "tcgetattr-fails"))
        t_inject = "TCGETATTR";

    start(!strncmp(name, "timedemo", 8));
    I_InitGraphics();

    if (!strcmp(name, "noframes"))
        I_Quit();

    frames(3);

    for (i = 0; i < NSIGNALS; i++) {
        if (!strcmp(name, signals[i].name)) {
            fprintf(stderr, "[test] raise(%d)\n", signals[i].sig);
            raise(signals[i].sig);
        }
    }

    if (!strcmp(name, "timedemo-quit") || !strcmp(name, "play-quit")) {
        keys("Left Ctrl + Left Alt + Backspace", LCTRL, LALT, BKSP, -1);
    } else if (!strcmp(name, "play-quit-right")) {
        keys("Right Ctrl + Right Alt + Backspace", RCTRL, RALT, BKSP, -1);
    } else if (!strcmp(name, "play-quit-mixed")) {
        keys("Right Alt + Left Ctrl + Backspace", RALT, LCTRL, BKSP, -1);
    } else if (!strcmp(name, "play-quit-media")) {
        keys("Ctrl + Alt, a multimedia key, Backspace", LCTRL, LALT, MEDIA_DOWN, BKSP, -1);
    } else if (!strcmp(name, "timedemo-end")) {
        /* the demo runs out: G_ReadDemoTiccmd calls G_CheckDemoStatus */
        fprintf(stderr, "[test] the demo ends\n");
        G_CheckDemoStatus();
    } else if (!strcmp(name, "keys")) {
        keys("Backspace", BKSP, BKSP | UP, -1);
        keys("Right Ctrl", RCTRL, RCTRL | UP, -1);
        keys("Right Alt", RALT, RALT | UP, -1);
        keys("Left Ctrl", LCTRL, LCTRL | UP, -1);
        keys("Left Alt", LALT, LALT | UP, -1);
        keys("Ctrl + Backspace", LCTRL, BKSP, BKSP | UP, LCTRL | UP, -1);
        keys("Alt + Backspace", RALT, BKSP, BKSP | UP, RALT | UP, -1);
        keys("Ctrl, Alt, Alt up, Backspace", LCTRL, LALT, LALT | UP, BKSP, BKSP | UP,
             LCTRL | UP, -1);
        keys("Ctrl, Ctrl up, Alt, Backspace", RCTRL, RCTRL | UP, RALT, BKSP, BKSP | UP,
             RALT | UP, -1);
        keys("Ctrl + Alt + Backspace up, with no Backspace down", LCTRL, LALT, BKSP | UP,
             LALT | UP, LCTRL | UP, -1);
        keys("A multimedia key", MEDIA_DOWN, MEDIA_UP, -1);
        keys_slowly("A multimedia key, a byte at a time", MEDIA_DOWN, MEDIA_UP, -1);
        keys("Backspace once more", BKSP, BKSP | UP, -1);
        fprintf(stderr, "[test] still running; quit from the menu\n");
        I_Quit();
    } else if (!strcmp(name, "exit")) {
        fprintf(stderr, "[test] exit(3)\n");
        exit(3);
    } else if (!strcmp(name, "error-unread")) {
        keys_unread("four key bytes that are not read, then an error",
                    0x15 | UP, 0x67, 0x67 | UP, 0x0a, -1);
        I_Error("Z_Malloc: failed on allocation of %i bytes", 12345);
    } else if (!strcmp(name, "null-store")) {
        fprintf(stderr, "[test] a store through a null pointer\n");
        *(volatile int *)0 = 1;
    } else if (!strcmp(name, "abort")) {
        fprintf(stderr, "[test] abort()\n");
        abort();
    } else if (!strcmp(name, "stack-overflow")) {
        fprintf(stderr, "[test] recursion without end\n");
        fprintf(stderr, "[test] came back from %d\n", recurse(1));
    }
    fprintf(stderr, "[test] STILL RUNNING\n");
}

/* checking a scenario's output */

#define RESTORED "[vt] KDSKBMODE as it was", "[vt] tcflush", "[vt] tcsetattr as it was", \
                 "[vt] KDSETMODE KD_TEXT"
#define STARTED  "No mouse found.", "[vt] tcsetattr raw", "[vt] KDSKBMODE K_MEDIUMRAW", \
                 "Press Ctrl+Alt+Backspace to exit.", "[vt] KDSETMODE KD_GRAPHICS"
#define CLEAN    "[vt] afterwards: KD_TEXT, keyboard mode as it was, termios as it was"

static struct expectation {
    const char *name;
    int status;                 /* exit status, or minus the signal */
    const char *order[40];      /* these, in this order */
    const char *never[6];
} expectations[] = {
    { "timedemo-quit", 255,
      { STARTED, "Ctrl + Left Alt + Backspace", RESTORED,
        "timed 3 gametics in 1 realtics (105.000000 fps)", "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "M_SaveDefaults" } },
    { "timedemo-end", 255,
      { STARTED, "the demo ends", RESTORED,
        "timed 3 gametics in 1 realtics (105.000000 fps)", "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING" } },
    { "play-quit", 0,
      { STARTED, "Ctrl + Left Alt + Backspace", RESTORED, "[exit function] M_SaveDefaults",
        "[exit function] D_Endoom", "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "timed" } },
    { "play-quit-right", 0,
      { STARTED, "[event] keydown 0xa3", "[event] keydown 0xb8", RESTORED,
        "[exit function] M_SaveDefaults", "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "keydown 0x7f" } },
    { "play-quit-mixed", 0,
      { STARTED, RESTORED, "[exit function] M_SaveDefaults", "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "keydown 0x7f" } },
    /* the three bytes of a keycode above 127 are not keys: they must not
     * let go of Ctrl, and they post nothing */
    { "play-quit-media", 0,
      { STARTED, "[event] keydown 0xa3", "[event] keydown 0xb8", RESTORED,
        "[exit function] M_SaveDefaults", "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "keydown 0x7f", "keyup" } },
    { "keys", 0,
      { STARTED,
        "[test] Backspace", "[event] keydown 0x7f", "[event] keyup 0x7f",
        "[test] Right Ctrl", "[event] keydown 0xa3", "[event] keyup 0xa3",
        "[test] Right Alt", "[event] keydown 0xb8", "[event] keyup 0xb8",
        "[test] Left Ctrl", "[event] keydown 0xa3", "[event] keyup 0xa3",
        "[test] Left Alt", "[event] keydown 0xb8", "[event] keyup 0xb8",
        "[test] A multimedia key\n[test] A multimedia key, a byte at a time\n"
        "[test] Backspace once more\n[event] keydown 0x7f\n[event] keyup 0x7f\n"
        "[test] still running; quit from the menu", RESTORED, "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "0x1b" } },
    { "noframes", 0,
      { STARTED, RESTORED, "[exit function] M_SaveDefaults", CLEAN },
      { "STILL RUNNING", "fbdoom:" } },
    { "error-early", 255,
      { "W_InitFiles: no files found", CLEAN },
      { "STILL RUNNING", "fbdoom:", "[vt] KD", "M_SaveDefaults" } },
    /* an error in the middle of a game, with keys still unread */
    { "error-unread", 255,
      { STARTED, "[test] four key bytes", "[vt] KDSKBMODE as it was",
        "[vt] tcflush: 4 unread key bytes dropped", "[vt] tcsetattr as it was",
        "[vt] KDSETMODE KD_TEXT", "Z_Malloc: failed on allocation of 12345 bytes",
        "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "M_SaveDefaults", "[event]" } },
    /* exit() from anywhere else: only the atexit() handler can put it back */
    { "exit", 3,
      { STARTED, "[test] exit(3)", RESTORED, "fbdoom: 3 frames", CLEAN },
      { "STILL RUNNING", "[exit function]" } },
    /* start-up fails after the terminal settings were changed: kbd_shutdown
     * has to put them back before it closes the keyboard */
    { "kbmode-fails", 0,
      { "No mouse found.", "[vt] tcsetattr raw", "Unable to set mediumraw mode.",
        "Exiting normally.", "[vt] KDSKBMODE as it was", "[vt] tcflush",
        "[vt] tcsetattr as it was", "[vt] closed", CLEAN },
      { "STILL RUNNING", "KD_GRAPHICS", "fbdoom:", "K_MEDIUMRAW" } },
    /* start-up fails before anything was changed: nothing to put back, and
     * no terminal settings to write that were never read */
    { "tcgetattr-fails", 0,
      { "No mouse found.", "Unable to query terminal settings.", "Exiting normally.",
        "[vt] closed", CLEAN },
      { "STILL RUNNING", "[vt] tcsetattr", "[vt] KDS", "fbdoom:" } },
    { "null-store", -SIGSEGV,
      { STARTED, "[test] a store through a null pointer", RESTORED, CLEAN },
      { "STILL RUNNING" } },
    { "abort", -SIGABRT,
      { STARTED, "[test] abort()", RESTORED, CLEAN },
      { "STILL RUNNING" } },
    /* the handler needs a stack of its own for this one */
    { "stack-overflow", -SIGSEGV,
      { STARTED, "[test] recursion without end", RESTORED, CLEAN },
      { "STILL RUNNING", "came back" } },
    /* filled in for whichever signal is asked for */
    { NULL, 0,
      { STARTED, "[test] raise(", RESTORED, CLEAN },
      { "STILL RUNNING" } },
};

#define NEXPECTATIONS ((int)(sizeof(expectations) / sizeof(expectations[0])))

static int count(const char *text, const char *what)
{
    int n = 0;

    while ((text = strstr(text, what)) != NULL) {
        n++;
        text++;
    }
    return n;
}

int main(int argc, char **argv)
{
    static char *child_argv[] = { "fbdoom", NULL };
    static char out[65536];
    struct expectation *e = NULL;
    struct termios o;
    char path[64];
    const char *at;
    int i, fd, status, got, fails = 0;
    pid_t pid;
    FILE *f;

    for (i = 0; argc > 1 && i < NSIGNALS; i++) {
        if (!strcmp(signals[i].name, argv[1])) {
            e = &expectations[NEXPECTATIONS - 1];
            e->name = signals[i].name;
            e->status = -signals[i].sig;
        }
    }
    for (i = 0; argc > 1 && i < NEXPECTATIONS - 1; i++)
        if (!strcmp(expectations[i].name, argv[1]))
            e = &expectations[i];
    if (e == NULL) {
        fprintf(stderr, "usage: %s SCENARIO\nscenarios:", argv[0]);
        for (i = 0; i < NEXPECTATIONS - 1; i++)
            fprintf(stderr, " %s", expectations[i].name);
        for (i = 0; i < NSIGNALS; i++)
            fprintf(stderr, " %s", signals[i].name);
        fprintf(stderr, "\n");
        return 2;
    }

    vt = mmap(NULL, sizeof(*vt), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (vt == MAP_FAILED) {
        perror("mmap");
        return 2;
    }
    vt->mode = KD_TEXT;
    vt->kbmode = ORIG_KBMODE;
    orig_term(&vt->term);

    snprintf(path, sizeof(path), "console-%s.log", e->name);
    fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror(path);
        return 2;
    }

    fflush(NULL);
    pid = fork();
    if (pid == 0) {
        dup2(fd, 1);
        dup2(fd, 2);
        setvbuf(stdout, NULL, _IONBF, 0);
        myargc = 1;
        myargv = child_argv;
        scenario(e->name);
        _exit(99);
    }
    if (pid < 0 || waitpid(pid, &status, 0) != pid) {
        perror("fork");
        return 2;
    }

    f = fopen(path, "r");
    i = f ? fread(out, 1, sizeof(out) - 256, f) : 0;

    /* how the child left the VT */
    orig_term(&o);
    snprintf(out + i, 256, "[vt] afterwards: %s, keyboard mode %s, termios %s\n",
             vt->mode == KD_TEXT ? "KD_TEXT" : "NOT TEXT",
             vt->kbmode == ORIG_KBMODE ? "as it was" : "NOT RESTORED",
             memcmp(&vt->term, &o, sizeof(o)) == 0 ? "as it was" : "NOT RESTORED");

    printf("== %s ==\n%s", e->name, out);

    got = WIFSIGNALED(status) ? -WTERMSIG(status) : WEXITSTATUS(status);
    if (got != e->status) {
        printf("FAIL  status %d, expected %d\n", got, e->status);
        fails++;
    }
    for (at = out, i = 0; i < 40 && e->order[i]; i++) {
        const char *found = strstr(at, e->order[i]);

        if (found == NULL) {
            printf("FAIL  \"%s\" is missing, or out of order\n", e->order[i]);
            fails++;
        } else {
            at = found + strlen(e->order[i]);
        }
    }
    for (i = 0; i < 6 && e->never[i]; i++) {
        if (strstr(out, e->never[i])) {
            printf("FAIL  \"%s\" should not be there\n", e->never[i]);
            fails++;
        }
    }
    /* While the VT is in graphics mode fbcon does not scroll, so nothing
     * may be printed then.  Lines from this test begin with a bracket. */
    at = strstr(out, "[vt] KDSETMODE KD_GRAPHICS");
    if (at != NULL) {
        const char *end = strstr(at, "[vt] KDSETMODE KD_TEXT");

        while ((at = strchr(at, '\n')) != NULL && (end == NULL || at < end)) {
            at++;
            if (*at != '[' && *at != 0) {
                printf("FAIL  printed while the VT was in graphics mode: %.60s\n", at);
                fails++;
            }
        }
    }

    /* the console is put back once, not over and over */
    if (count(out, "[vt] KDSETMODE KD_TEXT") > 1 || count(out, "[vt] KDSETMODE KD_GRAPHICS") > 1) {
        printf("FAIL  the VT mode was set more than once each way\n");
        fails++;
    }

    printf("%s test_console %s (status %d)\n", fails ? "FAIL" : "PASS", e->name, got);
    return fails != 0;
}
