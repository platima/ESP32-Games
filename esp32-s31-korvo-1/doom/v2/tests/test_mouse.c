/*
 * Feeds events to the real code in i_input_evdev_mouse.c and checks the
 * ev_mouse events it posts.  Pipes stand in for /dev/input/eventN.  The
 * events are built here byte by byte in the layout the kernel uses, not
 * with the struct from the code under test.
 */
#define open    fake_open
#define ioctl   fake_ioctl
#define close   fake_close
#define read    fake_read
#include "i_input_evdev_mouse.c"
#undef open
#undef ioctl
#undef close
#undef read

#include <limits.h>
#include <stdarg.h>
#include <stdlib.h>

/* the real ones, which the headers above declared under the fake names */
int close(int);
int ioctl(int, int, ...);
ssize_t read(int, void *, size_t);
int pipe2(int [2], int);

/* every read() the code under test makes is counted */
static int t_reads;

ssize_t fake_read(int fd, void *buf, size_t n)
{
    t_reads++;
    return read(fd, buf, n);
}

/* what the rest of Doom would provide */

static event_t posted[64];
static int nposted;

void D_PostEvent(event_t *ev)
{
    if (nposted < 64)
        posted[nposted] = *ev;
    nposted++;
}

static const char *t_flags = "";

int M_CheckParm(char *check)
{
    return strstr(t_flags, check) != NULL;
}

/* fake devices for the scan */

#define NDEV 12
#define KEY_LONGS BITMAP_LONGS(KEY_CNT)

static struct fake_dev {
    int present;
    const char *name;
    unsigned long ev[1], rel[1], key[KEY_LONGS], down[KEY_LONGS];
    int no_keystate;    /* EVIOCGKEY fails */
    int rd, wr;         /* the pipe behind it; rd is what open() returns */
    int opened, closed;
} dev[NDEV];

static int t_opens, t_bad_flags, t_bad_ioctl;

static void set_bit(unsigned long *map, int n)
{
    map[n / LONG_BITS] |= 1UL << (n % LONG_BITS);
}

static struct fake_dev *dev_by_fd(int fd)
{
    int i;

    for (i = 0; i < NDEV; i++)
        if (dev[i].present && dev[i].opened && !dev[i].closed && dev[i].rd == fd)
            return &dev[i];
    return NULL;
}

int fake_close(int fd)
{
    struct fake_dev *d = dev_by_fd(fd);

    if (d != NULL)
        d->closed = 1;
    return close(fd);
}

int fake_open(const char *path, int flags, ...)
{
    int n, p[2];

    t_opens++;
    if (flags != (O_RDONLY | O_NONBLOCK))
        t_bad_flags++;
    if (sscanf(path, "/dev/input/event%d", &n) != 1 || n < 0 || n >= NDEV
        || !dev[n].present) {
        errno = ENOENT;
        return -1;
    }
    if (pipe2(p, O_NONBLOCK) != 0)
        abort();
    dev[n].rd = p[0];
    dev[n].wr = p[1];
    dev[n].opened = 1;
    return p[0];
}

/* Copies a bitmap out the way the kernel does: as much as fits. */
static int bits_out(void *arg, int len, const unsigned long *map, int maplen)
{
    if (len > maplen)
        len = maplen;
    memcpy(arg, map, len);
    return len;
}

int fake_ioctl(int fd, int req, ...)
{
    struct fake_dev *d = dev_by_fd(fd);
    /* an ioctl number: 8 bits of number, 8 of type, 14 of size, 2 of direction */
    unsigned int r = req;
    int nr = r & 0xff, type = (r >> 8) & 0xff, len = (r >> 16) & 0x3fff, dir = r >> 30;
    va_list ap;
    void *arg;

    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (d == NULL || type != 'E' || dir != 2) {
        if (d != NULL)
            t_bad_ioctl++;      /* EVIOCGRAB, for one, must never be sent */
        errno = ENOTTY;
        return -1;
    }
    if (nr == 0x20)
        return bits_out(arg, len, d->ev, sizeof(d->ev));
    if (nr == 0x20 + EV_REL)
        return bits_out(arg, len, d->rel, sizeof(d->rel));
    if (nr == 0x20 + EV_KEY)
        return bits_out(arg, len, d->key, sizeof(d->key));
    if (nr == 0x18 && !d->no_keystate)
        return bits_out(arg, len, d->down, sizeof(d->down));
    if (nr == 0x06) {
        /* like the kernel: no terminating zero if the name is cut short */
        int n = strlen(d->name) + 1;

        if (n > len)
            n = len;
        memcpy(arg, d->name, n);
        return n;
    }
    errno = EINVAL;
    return -1;
}

static void add_dev(int n, const char *name, int rel, int xy, int key, int left)
{
    memset(&dev[n], 0, sizeof(dev[n]));
    dev[n].present = 1;
    dev[n].name = name;
    if (rel)
        set_bit(dev[n].ev, EV_REL);
    if (key)
        set_bit(dev[n].ev, EV_KEY);
    if (xy) {
        set_bit(dev[n].rel, REL_X);
        set_bit(dev[n].rel, REL_Y);
    }
    set_bit(dev[n].rel, REL_WHEEL);
    set_bit(dev[n].key, KEY_A);
    if (left) {
        set_bit(dev[n].key, BTN_LEFT);
        set_bit(dev[n].key, BTN_RIGHT);
        set_bit(dev[n].key, BTN_MIDDLE);
    }
}

/* helpers */

static int fails;

static void check(int ok, const char *what)
{
    printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok)
        fails++;
}

/* One event in the kernel's own layout: two longs of time, then
 * 16 bits of type, 16 bits of code and 32 bits of value. */
#define EVSIZE (2 * sizeof(long) + 8)

static unsigned char *pack(unsigned char *p, int type, int code, int value)
{
    unsigned long sec = 1234, usec = 5678;
    uint16_t t = type, c = code;
    int32_t v = value;

    memcpy(p, &sec, sizeof(long));
    memcpy(p + sizeof(long), &usec, sizeof(long));
    memcpy(p + 2 * sizeof(long), &t, 2);
    memcpy(p + 2 * sizeof(long) + 2, &c, 2);
    memcpy(p + 2 * sizeof(long) + 4, &v, 4);
    return p + EVSIZE;
}

static void send(int fd, int type, int code, int value)
{
    unsigned char b[EVSIZE];

    pack(b, type, code, value);
    if (write(fd, b, EVSIZE) != EVSIZE)
        abort();
}

static void syn(int fd)
{
    send(fd, EV_SYN, SYN_REPORT, 0);
}

/* Run the reader once and report what it posted. */
static int poll_mouse(void)
{
    nposted = 0;
    I_ReadMouse();
    return nposted;
}

/* True if exactly one ev_mouse event came out, with these values. */
static int got(int buttons, int dx, int dy)
{
    int n = poll_mouse();
    int ok = n == 1 && posted[0].type == ev_mouse && posted[0].data1 == buttons
          && posted[0].data2 == dx && posted[0].data3 == dy;

    if (!ok) {
        if (n == 1)
            printf("      posted buttons %d, x %d, y %d; wanted %d, %d, %d\n",
                   posted[0].data1, posted[0].data2, posted[0].data3, buttons, dx, dy);
        else
            printf("      posted %d events; wanted one\n", n);
    }
    return ok;
}

static int closed(int fd)
{
    return fcntl(fd, F_GETFD) == -1 && errno == EBADF;
}

/* Bytes that nobody has read yet. */
static int waiting(int fd)
{
    int n = -1;

    ioctl(fd, FIONREAD, &n);
    return n;
}

/* A pipe with a non-blocking read end, registered as a mouse. */
static int new_mouse(int *rd)
{
    int p[2];

    if (pipe2(p, O_NONBLOCK) != 0 || !mouse_add(p[0]))
        abort();
    if (rd)
        *rd = p[0];
    return p[1];
}

static void drop_all(void)
{
    while (nmice > 0)
        close(mice[--nmice].fd);
    poll_mouse();       /* forget the buttons */
}

int main(void)
{
    unsigned char big[100 * EVSIZE], *p;
    int w, w2, r, r2, i;

    printf("sizeof(struct kernel_input_event) = %d, sizeof(struct input_event) = %d, "
           "sizeof(long) = %d\n", (int)sizeof(struct kernel_input_event),
           (int)sizeof(struct input_event), (int)sizeof(long));
    check(sizeof(struct kernel_input_event) == EVSIZE, "the event struct is two longs and 8 bytes");

    /* no mouse at all */
    check(poll_mouse() == 0 && t_reads == 0, "no mouse: nothing read, nothing posted");

    /* movement */
    w = new_mouse(&r);
    check(poll_mouse() == 0, "nothing waiting: nothing posted, and no blocking");
    check(t_reads == 1, "and that took one read()");

    send(w, EV_REL, REL_X, 3);
    send(w, EV_REL, REL_Y, 2);
    syn(w);
    send(w, EV_REL, REL_X, 4);
    syn(w);
    check(got(0, 7, -2), "movement adds up: x 3+4, y 2 -> one event, x 7, y -2");
    check(poll_mouse() == 0, "nothing new: nothing posted");

    send(w, EV_REL, REL_WHEEL, 1);
    send(w, EV_KEY, BTN_SIDE, 1);
    send(w, EV_MSC, MSC_SCAN, 0x90001);
    syn(w);
    check(poll_mouse() == 0, "wheel, side button and EV_MSC are ignored");
    send(w, EV_KEY, BTN_SIDE, 0);

    /* acceleration: beyond 10 counts, the excess is doubled */
    send(w, EV_REL, REL_X, 10);
    check(got(0, 10, 0), "x 10 -> 10 (at the threshold)");
    send(w, EV_REL, REL_X, 11);
    check(got(0, 12, 0), "x 11 -> 12");
    send(w, EV_REL, REL_X, 25);
    check(got(0, 40, 0), "x 25 -> 40");
    send(w, EV_REL, REL_X, -10);
    check(got(0, -10, 0), "x -10 -> -10");
    send(w, EV_REL, REL_X, -11);
    check(got(0, -12, 0), "x -11 -> -12");
    send(w, EV_REL, REL_X, -25);
    check(got(0, -40, 0), "x -25 -> -40");
    send(w, EV_REL, REL_X, 6);
    send(w, EV_REL, REL_X, 6);
    check(got(0, 14, 0), "x 6+6 -> 14 (the sum is accelerated, not the parts)");
    send(w, EV_REL, REL_Y, 25);
    check(got(0, 0, -40), "y 25 -> -40 (down is backwards)");
    send(w, EV_REL, REL_Y, -25);
    check(got(0, 0, 40), "y -25 -> 40");
    send(w, EV_REL, REL_X, 5);
    send(w, EV_REL, REL_X, -5);
    check(poll_mouse() == 0, "x 5-5: no movement, nothing posted");

    /* values no mouse sends: they are held to 32767 either way, so that
     * nothing overflows, and the call comes back */
    send(w, EV_REL, REL_X, INT_MIN);
    check(got(0, -65524, 0), "x -2147483648 -> -65524 (held to -32767, then accelerated)");
    send(w, EV_REL, REL_X, INT_MAX);
    check(got(0, 65524, 0), "x 2147483647 -> 65524");
    send(w, EV_REL, REL_Y, INT_MIN);
    check(got(0, 0, 65524), "y -2147483648 -> 65524");
    send(w, EV_REL, REL_Y, INT_MAX);
    check(got(0, 0, -65524), "y 2147483647 -> -65524");
    send(w, EV_REL, REL_X, INT_MAX);
    send(w, EV_REL, REL_X, INT_MAX);
    check(got(0, 65524, 0), "x 2147483647 twice -> 65524");
    send(w, EV_REL, REL_X, INT_MIN);
    send(w, EV_REL, REL_X, INT_MIN);
    check(got(0, -65524, 0), "x -2147483648 twice -> -65524");
    send(w, EV_REL, REL_X, 30000);
    send(w, EV_REL, REL_X, 30000);
    check(got(0, 65524, 0), "x 30000+30000 -> 65524 (the sum is held too)");
    send(w, EV_REL, REL_X, 32767);
    check(got(0, 65524, 0), "x 32767 -> 65524");
    send(w, EV_REL, REL_X, -32767);
    check(got(0, -65524, 0), "x -32767 -> -65524");
    send(w, EV_REL, REL_X, 32766);
    check(got(0, 65522, 0), "x 32766 -> 65522 (below the limit, untouched)");

    /* I_PollMouse reads and keeps, I_ReadMouse posts */
    send(w, EV_REL, REL_X, 3);
    send(w, EV_REL, REL_Y, 1);
    nposted = 0;
    t_reads = 0;
    I_PollMouse();
    check(nposted == 0 && waiting(r) == 0 && t_reads == 1,
          "I_PollMouse reads what is waiting, with one read(), and posts nothing");
    send(w, EV_REL, REL_X, 4);
    I_PollMouse();
    I_PollMouse();
    check(nposted == 0 && waiting(r) == 0, "again, and once more with nothing waiting");
    send(w, EV_REL, REL_X, 6);
    check(got(0, 16, -1), "I_ReadMouse then posts all of it as one event: x 3+4+6 -> 16, y 1 -> -1");
    check(poll_mouse() == 0, "and only once");
    send(w, EV_KEY, BTN_LEFT, 1);
    nposted = 0;
    I_PollMouse();
    check(nposted == 0, "a button read by I_PollMouse is not posted by it");
    check(got(1, 0, 0), "but by the next I_ReadMouse");
    send(w, EV_KEY, BTN_LEFT, 0);
    I_PollMouse();
    check(got(0, 0, 0), "and so is its release");

    /* how many times read() is called */
    send(w, EV_REL, REL_X, 1);
    send(w, EV_REL, REL_Y, 1);
    syn(w);
    t_reads = 0;
    check(got(0, 1, -1) && t_reads == 1, "one report waiting: one read(), which comes back short");
    for (p = big, i = 0; i < 16; i++)
        p = pack(p, EV_REL, REL_X, 1);
    if (write(w, big, 16 * EVSIZE) != 16 * EVSIZE)
        abort();
    t_reads = 0;
    check(got(0, 22, 0) && t_reads == 2, "exactly one buffer of events: a second read() to be sure");

    /* buttons */
    send(w, EV_KEY, BTN_LEFT, 1);
    syn(w);
    check(got(1, 0, 0), "left down -> buttons 1");
    check(poll_mouse() == 0, "left still down, nothing new: nothing posted");
    send(w, EV_REL, REL_X, 2);
    check(got(1, 2, 0), "movement with left held keeps buttons 1");
    send(w, EV_KEY, BTN_RIGHT, 1);
    check(got(3, 0, 0), "right down -> buttons 3");
    send(w, EV_KEY, BTN_MIDDLE, 1);
    check(got(7, 0, 0), "middle down -> buttons 7");
    send(w, EV_KEY, BTN_LEFT, 0);
    check(got(6, 0, 0), "left up -> buttons 6");
    send(w, EV_KEY, BTN_RIGHT, 0);
    send(w, EV_KEY, BTN_MIDDLE, 0);
    send(w, EV_REL, REL_X, -3);
    check(got(0, -3, 0), "right and middle up with movement -> one event, buttons 0");

    /* -novert */
    novert = 1;
    send(w, EV_REL, REL_X, 4);
    send(w, EV_REL, REL_Y, 30);
    check(got(0, 4, 0), "-novert: y is dropped, x is kept");
    novert = 0;

    /* an event cut in two by the end of a read */
    p = pack(big, EV_REL, REL_X, 3);
    p = pack(p, EV_REL, REL_X, 100);
    if (write(w, big, EVSIZE + 5) != EVSIZE + 5)
        abort();
    check(got(0, 3, 0), "one event and 5 bytes of the next: only the first counts");
    check(poll_mouse() == 0, "the 5 bytes wait");
    if (write(w, big + EVSIZE + 5, 3) != 3)
        abort();
    check(poll_mouse() == 0, "8 bytes of it: still waiting");
    if (write(w, big + EVSIZE + 8, EVSIZE - 8) != EVSIZE - 8)
        abort();
    check(got(0, 190, 0), "the rest arrives: x 100 -> 190, stream still in step");
    send(w, EV_REL, REL_Y, -1);
    check(got(0, 0, 1), "and the next event reads correctly");

    /* more than one buffer of events in a single call */
    for (p = big, i = 0; i < 100; i++)
        p = pack(p, EV_REL, i & 1 ? REL_Y : REL_X, 1);
    if (write(w, big, sizeof(big)) != sizeof(big))
        abort();
    t_reads = 0;
    check(got(0, 90, -90), "100 events at once are all read: x 50 -> 90, y 50 -> -90");
    check(t_reads == 7, "in six full reads and a short one");

    /* the kernel dropped events */
    send(w, EV_KEY, BTN_LEFT, 1);
    check(got(1, 0, 0), "left down");
    send(w, EV_SYN, SYN_DROPPED, 0);
    check(got(0, 0, 0), "SYN_DROPPED, state unknown (not a device): buttons released");

    /* a mouse that goes away */
    w2 = new_mouse(&r2);
    send(w, EV_REL, REL_X, 1);
    send(w2, EV_REL, REL_X, 2);
    send(w2, EV_KEY, BTN_RIGHT, 1);
    check(got(2, 3, 0), "two mice: movement adds, buttons combine");
    close(w2);          /* read() now returns 0 */
    send(w, EV_REL, REL_X, 1);
    check(got(0, 1, 0), "one unplugged with a button held: button released, the other still works");
    check(nmice == 1 && closed(r2) && !closed(r), "its descriptor is closed, the other is not");

    /* one that goes away between a poll and the next I_ReadMouse */
    w2 = new_mouse(&r2);
    send(w2, EV_REL, REL_X, 5);
    I_PollMouse();
    close(w2);
    I_PollMouse();
    check(nmice == 1 && closed(r2), "a mouse that goes away is dropped by I_PollMouse too");
    check(got(0, 5, 0), "what was read from it before that is still posted");

    /* read() fails with an error that is not EAGAIN: the write end of a pipe */
    w2 = new_mouse(NULL);
    if (!mouse_add(w2))
        abort();
    send(w, EV_REL, REL_Y, 1);
    check(got(0, 0, -1), "read() error (EBADF): carried on with the others");
    check(nmice == 2 && closed(w2), "the failing descriptor is closed and forgotten");
    check(poll_mouse() == 0, "and nothing more is posted");
    drop_all();

    /* finding the mice */
    add_dev(0, "Fake Keyboard", 0, 0, 1, 0);            /* keys only */
    add_dev(1, "Fake Mouse A", 1, 1, 1, 1);
    /* event2 does not exist */
    add_dev(3, "Fake Tablet Pad", 1, 1, 1, 0);          /* X and Y, no left button */
    add_dev(4, "Fake Volume Knob", 1, 0, 1, 1);         /* wheel only */
    add_dev(5, "Fake Mouse B with a name that is much too long to fit in the "
               "buffer that the code keeps for it", 1, 1, 1, 1);
    add_dev(6, "Fake Mouse C", 1, 1, 1, 1);
    add_dev(7, "Fake Mouse D", 1, 1, 1, 1);
    add_dev(8, "Fake Mouse E", 1, 1, 1, 1);             /* the fifth: not used */

    t_flags = "-nomouse -novert";
    t_opens = 0;
    I_InitMouse();
    check(t_opens == 0 && nmice == 0, "-nomouse: nothing is opened");
    check(novert == 1, "-novert is read");

    t_flags = "";
    I_InitMouse();
    check(novert == 0, "no -novert");
    check(nmice == 4, "four mice are used, the fifth is left alone");
    check(nmice == 4 && mice[0].fd == dev[1].rd && mice[1].fd == dev[5].rd
          && mice[2].fd == dev[6].rd && mice[3].fd == dev[7].rd,
          "event1, event5, event6 and event7 are the ones");
    check(dev[0].closed && dev[3].closed && dev[4].closed,
          "the keyboard, the pad and the knob are closed again");
    check(!dev[1].closed && !dev[5].closed && !dev[6].closed && !dev[7].closed,
          "the mice are left open");
    check(!dev[8].opened, "event8 was never opened");
    check(t_bad_flags == 0, "everything is opened O_RDONLY | O_NONBLOCK");
    check(t_bad_ioctl == 0, "no ioctl other than the queries (no EVIOCGRAB)");

    send(dev[1].wr, EV_REL, REL_X, 2);
    send(dev[7].wr, EV_KEY, BTN_MIDDLE, 1);
    check(got(4, 2, 0), "events from the found mice arrive");

    /* SYN_DROPPED on something that can say which buttons are down */
    set_bit(dev[1].down, BTN_LEFT);
    send(dev[1].wr, EV_SYN, SYN_DROPPED, 0);
    check(got(5, 0, 0), "SYN_DROPPED: the buttons are asked for again (left is down)");
    send(dev[1].wr, EV_KEY, BTN_LEFT, 0);
    send(dev[7].wr, EV_KEY, BTN_MIDDLE, 0);
    check(got(0, 0, 0), "and released");
    drop_all();

    for (i = 0; i < NDEV; i++)
        dev[i].present = 0;
    t_opens = 0;
    I_InitMouse();
    check(nmice == 0 && t_opens == 32, "no devices: event0 to event31 tried, none used");

    printf("%s: test_mouse, %d failed\n", fails ? "FAIL" : "PASS", fails);
    return fails != 0;
}
