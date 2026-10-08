/*
 * A fake Linux console for testing SDL's frame buffer driver and the game
 * without a board: a frame buffer that has one mode, like simplefb, some
 * virtual terminals, and event devices.
 *
 * The files under test are compiled as they are, with open(), close(),
 * ioctl(), mmap(), tcgetattr(), tcsetattr(), tcflush(), geteuid(),
 * access(), select() and execl() renamed on the compiler command line to
 * the fake_ functions below.  Nothing else in the program is touched.
 *
 * What the fakes hold is kept outside the program, so that it can be looked
 * at after the program has gone, whatever ended it, and so that a second
 * process (the game's console guard) sees the same console:
 *
 *   FAKE_STATE   a file that holds the state of the terminals (struct state)
 *   FAKE_LOG     every call that changes or asks something, one per line
 *   FAKE_FB      a file that is the frame buffer's memory
 *   FAKE_KBD     a FIFO that the keyboard is read from
 *   FAKE_MOUSEn  a FIFO that /dev/input/eventn is read from; it is a mouse
 *   FAKE_OTHERn  /dev/input/eventn is there, and is not a mouse
 *
 * And how the console is set up:
 *
 *   FAKE_GEOMETRY  WIDTHxHEIGHT of the frame buffer (800x480); 16 bpp
 *   FAKE_CTTY      the virtual terminal the program is started on (1);
 *                  0 means a terminal that is not a console, like ssh
 *   FAKE_EUID      what geteuid() answers (0)
 *   FAKE_FAIL      the name of one call that is made to fail, and
 *   FAKE_FAIL_AT   which of those calls in the process, counting from 1
 *   FAKE_CRASH     a file; when it appears, the program does what it says:
 *                  null, abort, stack, exit, _exit, return
 *   FAKE_DIE_AT    KDSKBMODE: the program ends, as if killed, at the moment
 *                  it asks for the raw keyboard, with only the terminal
 *                  settings changed so far
 *   FAKE_HANGUP    a file; once it is there, the terminal the program was
 *                  started on has been hung up: descriptors that were got
 *                  by opening /dev/tty answer EIO to everything
 *   FAKE_BACKGROUND  the program is a background job of its terminal: a
 *                  change to the terminal settings stops it (here: ends it
 *                  with status 150) unless it ignores SIGTTOU
 *   FAKE_QEMU      the emulator to start the console guard with
 *   FAKE_TAG       what to put at the start of each log line
 *
 * How the fake frame buffer and terminals answer was taken from the kernel
 * source of the board (Linux 7.2.7): fb_set_var() and do_fb_ioctl() in
 * drivers/video/fbdev/core, vt_ioctl.c, and keyboard.c.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <linux/kd.h>
#include <linux/keyboard.h>
#include <linux/vt.h>

#define NVT     8
#define MAGIC   0x464b4642

/* Everything is an int, so that a script can read it; the termios are at
 * the end.  tests/fakestate.py knows this layout. */
struct state {
    int magic;
    int active;             /* the terminal on the screen */
    int locked;             /* VT_LOCKSWITCH */
    int putvar;             /* FBIOPUT_VSCREENINFO calls */
    int redraws;            /* of those, with the terminal in text mode */
    int kbent;              /* KDGKBENT calls */
    int switches;           /* times the terminal on the screen changed */
    int blocked;            /* VT_WAITACTIVE calls that would never return */
    int flushed;            /* unread key bytes thrown away */
    int kdmode[NVT];
    int kbmode[NVT];
    int termstate[NVT];     /* 0 as at the start, 1 raw, 2 something else */
    int opened[NVT];
    struct termios term[NVT];
};

enum { FD_NONE, FD_FB, FD_VT, FD_PTY, FD_MOUSE, FD_OTHER };

static struct state *st;
static struct { int kind, n, ctty; } fds[256];
static int logfd = -1;
static int fb_w = 800, fb_h = 480;
static int ctty = 1;

static void flog(const char *fmt, ...)
{
    const char *tag = getenv("FAKE_TAG");
    char line[256];
    va_list ap;
    int n;

    if (logfd < 0)
        return;
    n = snprintf(line, sizeof(line), "%s ", tag ? tag : "game");
    va_start(ap, fmt);
    n += vsnprintf(line + n, sizeof(line) - n - 1, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof(line) - 2)
        n = sizeof(line) - 2;
    line[n++] = '\n';
    if (write(logfd, line, n) != n)
        abort();
}

static void cooked(struct termios *t)
{
    memset(t, 0, sizeof(*t));
    t->c_iflag = ICRNL | IXON;
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = CS8 | CREAD | B38400;
    t->c_lflag = ECHO | ICANON | ISIG | IEXTEN | ECHOE | ECHOK;
    t->c_cc[VMIN] = 1;
    t->c_cc[VINTR] = 3;
    t->c_cc[VEOF] = 4;
}

static void init(void)
{
    const char *path;
    int fd, i;

    if (st != NULL)
        return;

    /* On the board standard output is the console, which gets every line
     * as it is printed.  Here it is a file: make it behave the same, so
     * that the log shows what was printed when. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    if ((path = getenv("FAKE_LOG")) != NULL)
        logfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if ((path = getenv("FAKE_GEOMETRY")) != NULL)
        sscanf(path, "%dx%d", &fb_w, &fb_h);
    if ((path = getenv("FAKE_CTTY")) != NULL)
        ctty = atoi(path);

    path = getenv("FAKE_STATE");
    fd = path ? open(path, O_RDWR | O_CREAT, 0644) : -1;
    if (fd < 0 || ftruncate(fd, sizeof(*st)) != 0) {
        fprintf(stderr, "fakefb: FAKE_STATE is not set to a file that can be written\n");
        _exit(98);
    }
    st = mmap(NULL, sizeof(*st), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (st == MAP_FAILED)
        _exit(98);
    close(fd);

    if (st->magic != MAGIC) {
        memset(st, 0, sizeof(*st));
        st->active = ctty > 0 ? ctty : 1;
        for (i = 0; i < NVT; i++) {
            st->kdmode[i] = KD_TEXT;
            st->kbmode[i] = K_UNICODE;
            cooked(&st->term[i]);
        }
        st->opened[1] = 1;      /* the shell is on it */
        st->magic = MAGIC;
    }
}

/* FAKE_FAIL names a call to fail; FAKE_FAIL_AT says which one of them in
 * this process, counting from 1.  Without it they all fail. */
static int failing(const char *what)
{
    const char *f = getenv("FAKE_FAIL");
    const char *at = getenv("FAKE_FAIL_AT");
    static int count;

    if (f == NULL || strcmp(f, what) != 0)
        return 0;
    count++;
    return at == NULL || atoi(at) == count;
}

static int keep(int fd, int kind, int n)
{
    if (fd >= 0 && fd < 256) {
        fds[fd].kind = kind;
        fds[fd].n = n;
        fds[fd].ctty = 0;
    }
    return fd;
}

/* __tty_hangup(): after a hangup, a descriptor that was open on the
 * terminal can do nothing more.  One opened afterwards can. */
static int hung_up(int fd)
{
    const char *file = getenv("FAKE_HANGUP");

    if (file == NULL || !fds[fd].ctty || access(file, F_OK) != 0)
        return 0;
    flog("EIO: this descriptor is on a terminal that was hung up");
    errno = EIO;
    return 1;
}

/* tty_check_change(): a background job that changes the settings of its
 * own terminal is sent SIGTTOU, which stops it unless it ignores or blocks
 * the signal. */
static void check_background(int fd)
{
    struct sigaction sa;
    sigset_t blocked;

    if (getenv("FAKE_BACKGROUND") == NULL || fds[fd].kind != FD_VT || fds[fd].n != ctty)
        return;
    sigaction(SIGTTOU, NULL, &sa);
    sigprocmask(SIG_BLOCK, NULL, &blocked);
    if (sa.sa_handler == SIG_IGN || sigismember(&blocked, SIGTTOU))
        return;
    flog("SIGTTOU: a background job changing its terminal's settings is STOPPED here");
    _exit(150);
}

/* A real descriptor to stand for a terminal: the keyboard FIFO if there is
 * one, so that read() and select() work on it as they are. */
static int open_tty(int kind, int n)
{
    const char *kbd = getenv("FAKE_KBD");
    int fd = open(kbd ? kbd : "/dev/null", O_RDWR | O_NONBLOCK);

    if (kind == FD_VT && n >= 1 && n < NVT)
        st->opened[n]++;
    return keep(fd, kind, n);
}

int fake_open(const char *path, int flags, ...)
{
    char name[32];
    const char *fifo;
    va_list ap;
    int n, mode;

    init();

    if (strcmp(path, "/dev/fb0") == 0) {
        const char *file = getenv("FAKE_FB");
        int fd = file ? open(file, O_RDWR | O_CREAT, 0644) : -1;

        if (fd < 0 || ftruncate(fd, (fb_w * fb_h * 2 + 4095) & ~4095) != 0) {
            errno = ENODEV;
            return -1;
        }
        return keep(fd, FD_FB, 0);
    }
    if (strcmp(path, "/dev/tty") == 0) {
        int fd;

        if (ctty < 0) {
            errno = ENXIO;      /* no controlling terminal at all */
            return -1;
        }
        fd = ctty > 0 ? open_tty(FD_VT, ctty) : open_tty(FD_PTY, 0);
        if (fd >= 0 && fd < 256)
            fds[fd].ctty = 1;
        return fd;
    }
    if (strcmp(path, "/dev/tty0") == 0) {
        if (failing("open-tty0")) {
            errno = EACCES;
            return -1;
        }
        return open_tty(FD_VT, st->active);
    }
    if (sscanf(path, "/dev/tty%d", &n) == 1 && n >= 1 && n < NVT) {
        flog("open %s", path);
        return open_tty(FD_VT, n);
    }
    if (sscanf(path, "/dev/input/event%d", &n) == 1) {
        snprintf(name, sizeof(name), "FAKE_MOUSE%d", n);
        if ((fifo = getenv(name)) != NULL)
            return keep(open(fifo, O_RDWR | O_NONBLOCK), FD_MOUSE, n);
        snprintf(name, sizeof(name), "FAKE_OTHER%d", n);
        if (getenv(name) != NULL)
            return keep(open("/dev/null", O_RDONLY | O_NONBLOCK), FD_OTHER, n);
        errno = ENOENT;
        return -1;
    }
    if (strncmp(path, "/dev/", 5) == 0 && strcmp(path, "/dev/null") != 0) {
        errno = ENOENT;         /* no gpm, no /dev/input/mice, no /dev/psaux */
        return -1;
    }

    va_start(ap, flags);
    mode = va_arg(ap, int);
    va_end(ap);
    return open(path, flags, mode);
}

int fake_close(int fd)
{
    if (fd >= 0 && fd < 256) {
        if (fds[fd].kind == FD_VT && st != NULL && fds[fd].n < NVT)
            st->opened[fds[fd].n]--;
        fds[fd].kind = FD_NONE;
    }
    return close(fd);
}

int fake_access(const char *path, int mode)
{
    if (strncmp(path, "/dev/", 5) == 0) {
        errno = ENOENT;
        return -1;
    }
    return access(path, mode);
}

uid_t fake_geteuid(void)
{
    const char *e = getenv("FAKE_EUID");

    return e ? (uid_t)atoi(e) : 0;
}

static void fill_var(struct fb_var_screeninfo *v)
{
    memset(v, 0, sizeof(*v));
    v->xres = v->xres_virtual = fb_w;
    v->yres = v->yres_virtual = fb_h;
    v->bits_per_pixel = 16;
    v->red.offset = 11;
    v->red.length = 5;
    v->green.offset = 5;
    v->green.length = 6;
    v->blue.length = 5;
    v->height = v->width = -1;
}

static int fb_ioctl(int req, void *arg)
{
    switch (req) {
    case FBIOGET_FSCREENINFO: {
        struct fb_fix_screeninfo *f = arg;

        if (failing("FBIOGET_FSCREENINFO")) {
            flog("FBIOGET_FSCREENINFO: made to fail");
            errno = EIO;
            return -1;
        }
        memset(f, 0, sizeof(*f));
        strcpy(f->id, "simple");
        f->smem_start = 0x48f44000;
        f->smem_len = (fb_w * fb_h * 2 + 4095) & ~4095;
        f->type = FB_TYPE_PACKED_PIXELS;
        f->visual = FB_VISUAL_TRUECOLOR;
        f->line_length = fb_w * 2;
        return 0;
    }
    case FBIOGET_VSCREENINFO:
        fill_var(arg);
        return 0;
    case FBIOPUT_VSCREENINFO: {
        struct fb_var_screeninfo *v = arg;
        int text = st->kdmode[st->active] == KD_TEXT;

        st->putvar++;
        /* fbcon_modechange_possible(): not smaller than a character */
        if (text && (v->xres < 8 || v->yres < 16)) {
            errno = EINVAL;
            return -1;
        }
        flog("FBIOPUT_VSCREENINFO %ux%u %u bpp, virtual %ux%u%s: %s", v->xres, v->yres,
             v->bits_per_pixel, v->xres_virtual, v->yres_virtual,
             (v->activate & FB_ACTIVATE_MASK) == FB_ACTIVATE_TEST ? ", test" : "",
             text ? "text mode, the console is redrawn" : "graphics mode");
        if (text)
            st->redraws++;
        /* fb_set_var() without fb_check_var: the mode there is, whatever
         * was asked for */
        fill_var(v);
        return 0;
    }
    case FBIOPAN_DISPLAY:
        flog("FBIOPAN_DISPLAY: not supported");
        errno = EINVAL;
        return -1;
    case FBIOGETCMAP:
    case FBIOPUTCMAP:
        return 0;
    }
    errno = EINVAL;
    return -1;
}

static const char *kdname(int m)
{
    return m == KD_TEXT ? "KD_TEXT" : m == KD_GRAPHICS ? "KD_GRAPHICS" : "?";
}

static const char *kbname(int m)
{
    return m == K_UNICODE ? "K_UNICODE" : m == K_MEDIUMRAW ? "K_MEDIUMRAW"
         : m == K_XLATE ? "K_XLATE" : m == K_RAW ? "K_RAW" : "?";
}

/* The plain map of the kernel's default keyboard, as far as SDL and the
 * game look at it. */
static unsigned short plain_key(int k)
{
    static const char row1[] = "1234567890-=";
    static const char row2[] = "qwertyuiop[]";
    static const char row3[] = "asdfghjkl;'`";
    static const char row4[] = "\\zxcvbnm,./";
    int c;

    if (k >= 2 && k <= 13)
        c = row1[k - 2];
    else if (k >= 16 && k <= 27)
        c = row2[k - 16];
    else if (k >= 30 && k <= 41)
        c = row3[k - 30];
    else if (k >= 43 && k <= 53)
        c = row4[k - 43];
    else
        c = 0;
    if (c >= 'a' && c <= 'z')
        return K(KT_LETTER, c);
    if (c)
        return K(KT_LATIN, c);

    switch (k) {
    case 1: return K(KT_LATIN, 27);
    case 14: return K(KT_LATIN, 127);
    case 15: return K(KT_LATIN, 9);
    case 28: return K_ENTER;
    case 29: case 97: return K_CTRL;
    case 42: case 54: return K_SHIFT;
    case 55: return K_PSTAR;
    case 56: return K_ALT;
    case 57: return K(KT_LATIN, ' ');
    case 58: return K_CAPS;
    case 69: return K_NUM;
    case 70: return K_HOLD;
    case 87: return K_F11;
    case 88: return K_F12;
    case 96: return K_PENTER;
    case 98: return K_PSLASH;
    case 100: return K_ALTGR;
    case 102: return K_FIND;
    case 103: return K_UP;
    case 104: return K_PGUP;
    case 105: return K_LEFT;
    case 106: return K_RIGHT;
    case 107: return K_SELECT;
    case 108: return K_DOWN;
    case 109: return K_PGDN;
    case 110: return K_INSERT;
    case 111: return K_REMOVE;
    }
    if (k >= 59 && k <= 68)
        return K_F1 + (k - 59);
    return K_HOLE;
}

static void set_active(int n)
{
    if (st->active != n) {
        st->active = n;
        st->switches++;
    }
}

static int vt_ioctl(int fd, int n, int req, void *arg)
{
    switch (req) {
    case KDGKBTYPE:
        *(char *)arg = KB_101;
        return 0;
    case KDGKBMODE:
        if (failing("KDGKBMODE")) {
            flog("vt%d KDGKBMODE: made to fail", n);
            errno = EIO;
            return -1;
        }
        *(int *)arg = st->kbmode[n];
        return 0;
    case KDSKBMODE:
        if ((long)arg == K_MEDIUMRAW && getenv("FAKE_DIE_AT") != NULL
            && strcmp(getenv("FAKE_DIE_AT"), "KDSKBMODE") == 0) {
            flog("vt%d KDSKBMODE K_MEDIUMRAW: the program is killed here", n);
            _exit(4);
        }
        if ((long)arg == K_MEDIUMRAW && failing("KDSKBMODE")) {
            flog("vt%d KDSKBMODE K_MEDIUMRAW: made to fail", n);
            errno = EPERM;
            return -1;
        }
        st->kbmode[n] = (long)arg;
        flog("vt%d KDSKBMODE %s", n, kbname(st->kbmode[n]));
        return 0;
    case KDGETMODE:
        *(int *)arg = st->kdmode[n];
        return 0;
    case KDSETMODE:
        if ((long)arg == KD_GRAPHICS && failing("KDSETMODE")) {
            flog("vt%d KDSETMODE KD_GRAPHICS: made to fail", n);
            errno = EPERM;
            return -1;
        }
        st->kdmode[n] = (long)arg;
        flog("vt%d KDSETMODE %s", n, kdname(st->kdmode[n]));
        return 0;
    case KDGKBENT: {
        struct kbentry *e = arg;
        /* the maps the kernel's default keyboard has */
        static const char have[16] = { 1, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1 };

        st->kbent++;
        if (e->kb_table == 0)
            e->kb_value = plain_key(e->kb_index);
        else if (e->kb_table < 16 && have[e->kb_table])
            e->kb_value = K_HOLE;
        else
            e->kb_value = e->kb_index ? K_HOLE : K_NOSUCHMAP;
        return 0;
    }
    case VT_GETSTATE: {
        struct vt_stat *s = arg;

        s->v_active = st->active;
        s->v_signal = 0;
        s->v_state = 0;
        return 0;
    }
    case VT_OPENQRY: {
        int i;

        for (i = 1; i < NVT && st->opened[i] > 0; i++)
            ;
        *(int *)arg = i < NVT ? i : -1;
        flog("VT_OPENQRY: %d", *(int *)arg);
        return 0;
    }
    case VT_ACTIVATE: {
        int to = (long)arg;

        if (to < 1 || to >= NVT) {
            errno = ENXIO;
            return -1;
        }
        /* set_console(): refused without a word while switching is locked,
         * or while the terminal on the screen is in graphics mode */
        if (to == st->active)
            flog("VT_ACTIVATE %d: already there", to);
        else if (st->locked || st->kdmode[st->active] == KD_GRAPHICS)
            flog("VT_ACTIVATE %d: REFUSED, the screen stays on vt%d", to, st->active);
        else {
            flog("VT_ACTIVATE %d: the screen moves from vt%d", to, st->active);
            set_active(to);
        }
        return 0;
    }
    case VT_WAITACTIVE:
        if ((long)arg != st->active) {
            st->blocked++;
            flog("VT_WAITACTIVE %ld: WOULD WAIT FOR EVER", (long)arg);
            errno = EINTR;
            return -1;
        }
        return 0;
    case VT_LOCKSWITCH:
        st->locked = 1;
        flog("VT_LOCKSWITCH");
        return 0;
    case VT_UNLOCKSWITCH:
        st->locked = 0;
        flog("VT_UNLOCKSWITCH");
        return 0;
    case TIOCNOTTY:
        flog("TIOCNOTTY: the program gives up its terminal");
        return 0;
    case TIOCGDEV:
        if (failing("TIOCGDEV")) {
            errno = ENOTTY;
            return -1;
        }
        *(unsigned int *)arg = (4 << 8) | n;
        return 0;
    }
    errno = EINVAL;
    return -1;
}

static int evdev_ioctl(int fd, unsigned int req, void *arg)
{
    int mouse = fds[fd].kind == FD_MOUSE;
    unsigned long *bits = arg;
    unsigned int len = _IOC_SIZE(req);

    if (_IOC_TYPE(req) != 'E')
        goto bad;

    if (_IOC_NR(req) == _IOC_NR(EVIOCGNAME(0))) {
        snprintf(arg, len, mouse ? "Fake Mouse %d" : "Fake Keyboard %d", fds[fd].n);
        return strlen(arg);
    }
    if (_IOC_NR(req) == _IOC_NR(EVIOCGKEY(0))) {
        memset(arg, 0, len);    /* no button is down */
        return len;
    }
    if (_IOC_NR(req) >= 0x20 && _IOC_NR(req) < 0x20 + EV_CNT) {
        int ev = _IOC_NR(req) - 0x20;

        memset(arg, 0, len);
#define SET(b) (bits[(b) / (8 * sizeof(long))] |= 1UL << ((b) % (8 * sizeof(long))))
        if (ev == 0) {
            SET(EV_SYN);
            SET(EV_KEY);
            if (mouse)
                SET(EV_REL);
        } else if (ev == EV_REL && mouse) {
            SET(REL_X);
            SET(REL_Y);
            SET(REL_WHEEL);
        } else if (ev == EV_KEY) {
            if (mouse) {
                SET(BTN_LEFT);
                SET(BTN_RIGHT);
                SET(BTN_MIDDLE);
            } else {
                SET(KEY_A);
                SET(KEY_ENTER);
            }
        }
        return len;
    }
bad:
    errno = EINVAL;
    return -1;
}

int fake_ioctl(int fd, int req, ...)
{
    va_list ap;
    void *arg;

    init();
    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (fd < 0 || fd >= 256 || fds[fd].kind == FD_NONE)
        return ioctl(fd, req, arg);

    switch (fds[fd].kind) {
    case FD_FB:
        return fb_ioctl(req, arg);
    case FD_VT:
        if (hung_up(fd))
            return -1;
        return vt_ioctl(fd, fds[fd].n, req, arg);
    case FD_MOUSE:
    case FD_OTHER:
        return evdev_ioctl(fd, req, arg);
    }
    if (req == (int)TIOCNOTTY) {
        flog("TIOCNOTTY: the program gives up its terminal");
        return 0;
    }
    errno = ENOTTY;             /* a terminal, and not a console */
    return -1;
}

void *fake_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    if (fd >= 0 && fd < 256 && fds[fd].kind == FD_FB && failing("mmap")) {
        errno = ENODEV;
        return MAP_FAILED;
    }
    return mmap(addr, len, prot, flags, fd, off);
}

static int termstate(const struct termios *t)
{
    struct termios c;

    cooked(&c);
    if (memcmp(t, &c, sizeof(c)) == 0)
        return 0;
    return (t->c_lflag & (ICANON | ECHO | ISIG)) == 0 ? 1 : 2;
}

int fake_tcgetattr(int fd, struct termios *t)
{
    init();
    if (fd < 0 || fd >= 256 || (fds[fd].kind != FD_VT && fds[fd].kind != FD_PTY)) {
        errno = ENOTTY;
        return -1;
    }
    if (hung_up(fd))
        return -1;
    if (failing("tcgetattr")) {
        flog("tcgetattr: made to fail");
        errno = EIO;
        return -1;
    }
    *t = st->term[fds[fd].kind == FD_VT ? fds[fd].n : 0];
    return 0;
}

static int drop_keys(int fd)
{
    unsigned char buf[64];
    int n, total = 0;

    while ((n = read(fd, buf, sizeof(buf))) > 0)
        total += n;
    st->flushed += total;
    return total;
}

int fake_tcsetattr(int fd, int act, const struct termios *t)
{
    static const char *const names[] = { "as at the start", "raw", "SOMETHING ELSE" };
    int n, dropped = 0;

    init();
    if (fd < 0 || fd >= 256 || (fds[fd].kind != FD_VT && fds[fd].kind != FD_PTY)) {
        errno = ENOTTY;
        return -1;
    }
    if (hung_up(fd))
        return -1;
    check_background(fd);
    n = fds[fd].kind == FD_VT ? fds[fd].n : 0;
    if (act == TCSAFLUSH)
        dropped = drop_keys(fd);
    st->term[n] = *t;
    st->termstate[n] = termstate(t);
    if (act == TCSAFLUSH)
        flog("vt%d tcsetattr %s, %d unread key bytes dropped", n, names[st->termstate[n]], dropped);
    else
        flog("vt%d tcsetattr %s", n, names[st->termstate[n]]);
    return 0;
}

int fake_tcflush(int fd, int queue)
{
    init();
    if (fd < 0 || fd >= 256 || (fds[fd].kind != FD_VT && fds[fd].kind != FD_PTY)) {
        errno = ENOTTY;
        return -1;
    }
    flog("vt%d tcflush, %d unread key bytes dropped", fds[fd].n,
         queue == TCIFLUSH ? drop_keys(fd) : -1);
    return 0;
}

/* Ways for the program to end that only it can bring about. */
static volatile int forever = 1;

static int __attribute__((noinline)) recurse(int n)
{
    volatile char pad[4096];

    pad[0] = n;
    return forever ? recurse(n + 1) + pad[0] : 0;
}

static void crash(void)
{
    const char *path = getenv("FAKE_CRASH");
    char how[16] = "";
    FILE *f;

    if (path == NULL || (f = fopen(path, "r")) == NULL)
        return;
    if (fscanf(f, "%15s", how) != 1)
        how[0] = 0;
    fclose(f);
    unlink(path);

    flog("crash: %s", how);
    if (strcmp(how, "null") == 0)
        *(volatile int *)0 = 1;
    else if (strcmp(how, "abort") == 0)
        abort();
    else if (strcmp(how, "stack") == 0)
        flog("came back from %d", recurse(1));
    else if (strcmp(how, "exit") == 0)
        exit(3);
    else if (strcmp(how, "_exit") == 0)
        _exit(4);
}

/* SDL calls select() every time the program asks for its events. */
int fake_select(int n, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    crash();
    return select(n, r, w, e, tv);
}

/* The console guard is the game started again.  Under the emulator the game
 * cannot start itself by its own name; the emulator has to be named. */
int fake_execl(const char *path, const char *arg0, ...)
{
    const char *qemu = getenv("FAKE_QEMU");
    char self[512];
    char *argv[8];
    va_list ap;
    ssize_t len;
    int n = 0;

    len = readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (len <= 0 || qemu == NULL) {
        errno = ENOENT;
        return -1;
    }
    self[len] = 0;

    argv[n++] = (char *)qemu;
    argv[n++] = self;
    va_start(ap, arg0);
    while (n < 7 && (argv[n] = va_arg(ap, char *)) != NULL)
        n++;
    va_end(ap);
    argv[n] = NULL;

    flog("the console guard is started");
    setenv("FAKE_TAG", "guard", 1);
    /* by the time it acts, the shell has the terminal back and the guard
     * is a background job of it */
    setenv("FAKE_BACKGROUND", "1", 1);
    return execv(qemu, argv);
}
