#!/usr/bin/env python3
"""Runs a tiny386 binary with -term under a pseudo terminal, keeps a copy of the
text screen from the escape sequences it prints, types what a script says,
and reports the screen.

    drive.py [--timeout S] [--dump FILE] [--log FILE] STEPS.json -- CMD ARGS...

STEPS.json is a list of steps, each a dict with any of
    "name"     what to call the step in the report
    "sleep"    seconds to wait first, without looking
    "wait"     a regular expression that has to match the screen text
    "timeout"  how long to wait for it (120 s)
    "send"     what to type then; "keydelay" is the time between keys (0.08 s)
The exit status is 0 when every "wait" was seen in time.
"""
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ROWS, COLS = 50, 132
ESC = 0x1b


class Screen:
    def __init__(self):
        self.g = [[' '] * COLS for _ in range(ROWS)]
        self.r = self.c = 0
        self.saved = (0, 0)
        self.buf = b''

    def feed(self, data):
        self.buf += data
        b = self.buf
        n = len(b)
        i = 0
        while i < n:
            ch = b[i]
            if ch == ESC:
                if i + 1 >= n:
                    break
                c1 = b[i + 1]
                if c1 == ord('7'):
                    self.saved = (self.r, self.c)
                    i += 2
                    continue
                if c1 == ord('8'):
                    self.r, self.c = self.saved
                    i += 2
                    continue
                if c1 == ord('['):
                    j = i + 2
                    while j < n and not (0x40 <= b[j] <= 0x7e):
                        j += 1
                    if j >= n:
                        break
                    params = b[i + 2:j].decode('ascii', 'replace')
                    if chr(b[j]) == 'H':
                        p = params.split(';')
                        try:
                            self.r = max(0, int(p[0] or 1) - 1)
                            self.c = max(0, int(p[1] or 1) - 1) if len(p) > 1 else 0
                        except ValueError:
                            pass
                    i = j + 1
                    continue
                i += 2
                continue
            if ch == 0x0d:
                self.c = 0
                i += 1
                continue
            if ch == 0x0a:
                self.r = min(ROWS - 1, self.r + 1)
                i += 1
                continue
            if ch < 0x20:
                # a control character that the guest draws as a glyph
                self.put('.')
                i += 1
                continue
            if ch < 0x80:
                self.put(chr(ch))
                i += 1
                continue
            ln = 2 if ch < 0xe0 else 3 if ch < 0xf0 else 4
            if i + ln > n:
                break
            self.put(b[i:i + ln].decode('utf-8', 'replace'))
            i += ln
        self.buf = b[i:]

    def put(self, s):
        if self.r < ROWS and self.c < COLS:
            self.g[self.r][self.c] = s
        self.c += 1

    def text(self, rows=25, cols=80):
        return '\n'.join(''.join(row[:cols]).rstrip() for row in self.g[:rows])


def main():
    a = sys.argv[1:]
    timeout = 3600.0
    dump = log = None
    while a and a[0].startswith('--') and a[0] != '--':
        if a[0] == '--timeout':
            timeout = float(a[1])
        elif a[0] == '--dump':
            dump = a[1]
        elif a[0] == '--log':
            log = a[1]
        else:
            sys.exit('unknown option ' + a[0])
        a = a[2:]
    steps = json.load(open(a[0]))
    assert a[1] == '--'
    cmd = a[2:]

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 25, 80, 0, 0))
    scr = Screen()
    logf = open(log, 'wb') if log else None
    state = {'alive': True}

    def pump(dt):
        try:
            r, _, _ = select.select([fd], [], [], dt)
        except InterruptedError:
            return
        if fd in r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                d = b''
            if not d:
                state['alive'] = False
                return
            if logf:
                logf.write(d)
            scr.feed(d)

    def idle(seconds):
        t1 = time.time() + seconds
        while time.time() < t1 and state['alive']:
            pump(min(0.1, seconds))

    t0 = time.time()
    t_end = t0 + timeout
    ok = True
    for n, st in enumerate(steps):
        name = st.get('name', 'step %d' % n)
        if 'sleep' in st:
            idle(st['sleep'])
        if 'wait' in st:
            rx = re.compile(st['wait'], re.S)
            t1 = min(t_end, time.time() + st.get('timeout', 120))
            seen = False
            while True:
                if rx.search(scr.text()):
                    seen = True
                    break
                if time.time() > t1 or not state['alive']:
                    break
                pump(0.2)
            print('[%7.1fs] %-34s %s' % (time.time() - t0, name,
                                         'ok' if seen else 'NOT SEEN: ' + st['wait']),
                  flush=True)
            if not seen:
                ok = False
                break
        if 'send' in st and state['alive']:
            # one key at a time: the guest's keyboard buffer is short
            for chb in st['send'].encode('latin-1'):
                os.write(fd, bytes([chb]))
                idle(st.get('keydelay', 0.08))
    idle(1.0)
    txt = scr.text()
    if dump:
        open(dump, 'w').write(txt + '\n')
    else:
        print('----- screen -----')
        print(txt)
        print('------------------')
    if state['alive']:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        idle(5)
        if state['alive']:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        _, status = os.waitpid(pid, 0)
        print('exit status', os.waitstatus_to_exitcode(status))
    except ChildProcessError:
        pass
    sys.exit(0 if ok else 1)


main()
