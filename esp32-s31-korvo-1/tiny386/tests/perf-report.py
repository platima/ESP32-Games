#!/usr/bin/env python3
"""Puts together what tests/perf printed, what tests/tracecount counted and a
disassembly of the program, and says what each piece of work cost the host:
instructions, loads and stores, and which functions they were in.

    perf-report.py PERF.txt COUNTS.txt DISASSEMBLY.txt [picture|grid]

PERF.txt         stdout of perf: "boot N", then "MARK N" for each piece
COUNTS.txt       stdout of tracecount
DISASSEMBLY.txt  riscv32-...-objdump -d of the program that was traced, not
                 stripped
picture          the pieces are pictures put on the screen ("perf file.ini
                 pictures"): the table is for one picture, in milliseconds
grid             the pieces are those of tests/guest/bgrid.S ("BGRID perf"):
                 the table has the whole of each piece

The times are a guess from two figures: what an instruction and what a store
cost on the ESP32-S31-Korvo-1 with its LCD on, 16 ns and 135 ns.  They were
fitted to three frame rates of Wolfenstein 3D on that board (see the notes of
that port), with counts of x86 code.  Nothing here was timed on the board.
"""
import re
import sys

NS_INSN = 16.0
NS_STORE = 135.0

NAMES = {
    0xa1: '16-bit arithmetic in registers',
    0xa2: '16-bit loads and stores',
    0xa3: '16-bit calls and stack',
    0xa4: 'rep movsw/stosw, for each BYTE',
    0xa5: 'DOS calls (int 21h)',
    0xa6: '32-bit arithmetic, paging on',
    0xa7: '32-bit loads and stores, paging on',
    0xa8: '32-bit calls and stack, paging on',
    0xa9: 'translation cache miss every time',
    0xc1: 'first picture after a mode change',
    0xc2: 'the one after that',
    0xc3: 'told to draw everything',
    0xc4: 'nothing has changed',
}

# the pieces of tests/guest/bgrid.S
GRID_NAMES = {
    0xa1: 'a: map mask, a plane at a time',
    0xa2: 'b: write mode 0, set/reset',
    0xa3: 'c: write mode 2',
    0xa4: 'd: write mode 3, rotate',
    0xa5: 'a row up, write mode 1; clear',
    0xa6: 'BIOS: AH=02h and 09h, 2000 cells',
    0xa7: 'BIOS: AH=06h, a row up',
}

# what piece 0xA4 of tests/guest/bench.S moves and fills: 1000 times 16 KB each
STRING_BYTES = 1000 * 2 * 16384

STORES = {'sb', 'sh', 'sw', 'c.sw', 'c.swsp', 'sc.w', 'fsw', 'fsd', 'c.fsw', 'c.fswsp'}
LOADS = {'lb', 'lbu', 'lh', 'lhu', 'lw', 'c.lw', 'c.lwsp', 'lr.w', 'flw', 'fld'}
AMOS = ('amoswap', 'amoadd', 'amoand', 'amoor', 'amoxor', 'amomax', 'amomin')


def read_disassembly(path):
    kind = {}       # address -> 'store', 'stack store', 'load' or ''
    func = {}       # address -> function
    cur = '?'
    head = re.compile(r'^([0-9a-f]+) <([^>]+)>:')
    insn = re.compile(r'^\s*([0-9a-f]+):\s+[0-9a-f]+\s+(\S+)\s*(.*)')
    for line in open(path, errors='replace'):
        m = head.match(line)
        if m:
            cur = m.group(2)
            continue
        m = insn.match(line)
        if not m:
            continue
        addr, mnem, ops = int(m.group(1), 16), m.group(2), m.group(3)
        func[addr] = cur
        if mnem in STORES or mnem.startswith(AMOS):
            kind[addr] = 'stack store' if '(sp)' in ops else 'store'
        elif mnem in LOADS:
            kind[addr] = 'load'
        else:
            kind[addr] = ''
    return kind, func


def main():
    perf, countfile, dis = sys.argv[1:4]
    picture = len(sys.argv) > 4 and sys.argv[4] == 'picture'
    grid = len(sys.argv) > 4 and sys.argv[4] == 'grid'
    kind, func = read_disassembly(dis)

    guest = []      # (mark, instructions)
    for line in open(perf):
        w = line.split()
        if len(w) == 2 and w[0] != 'boot':
            guest.append((int(w[0], 16), int(w[1])))

    stretches = []
    cur = None
    for line in open(countfile):
        w = line.split()
        if w[0] == 'stretch':
            cur = {'total': int(w[3]), 'outside': int(w[5]), 'pcs': {}}
            stretches.append(cur)
        else:
            cur['pcs'][int(w[0], 16)] = int(w[1])

    rows = []
    for (mark, n), st in zip(guest, stretches):
        if mark == 0xa4 and not grid:
            n = STRING_BYTES
        insns = st['total']
        loads = sum(c for pc, c in st['pcs'].items() if kind.get(pc) == 'load')
        stack = sum(c for pc, c in st['pcs'].items() if kind.get(pc) == 'stack store')
        stores = stack + sum(c for pc, c in st['pcs'].items() if kind.get(pc) == 'store')
        ns = (insns * NS_INSN + stores * NS_STORE) / n
        rows.append((mark, n, insns, loads, stores, stack, ns, st))

    if grid:
        print('Host work for each piece of BGRID, the whole of it (RV32, counted from a trace)')
        print()
        print('%-36s %9s %10s %9s %9s %7s %6s' % (
            '', 'guest', 'host', 'loads', 'stores', 'host a', 'ms'))
        print('%-36s %9s %10s %9s %9s %7s %6s' % (
            '', 'instr.', 'instr.', '', '', 'guest', ''))
        for mark, n, insns, loads, stores, stack, ns, st in rows:
            print('%-36s %9d %10d %9d %9d %7.1f %6.0f' % (
                GRID_NAMES.get(mark, '%02x' % mark), n, insns, loads, stores,
                insns / n, ns * n / 1e6))
        print()
        print('"ms" is a guess: %.0f ns for each instruction and %.0f ns for each store.'
              % (NS_INSN, NS_STORE))
        for mark, n, insns, loads, stores, stack, ns, st in rows:
            print()
            print('-- %s: where the host instructions and stores were --'
                  % GRID_NAMES.get(mark, '%02x' % mark))
            byfunc = {}
            for pc, c in st['pcs'].items():
                f = func.get(pc, '?')
                a = byfunc.setdefault(f, [0, 0])
                a[0] += c
                if kind.get(pc) in ('store', 'stack store'):
                    a[1] += c
            for f, (i, s) in sorted(byfunc.items(), key=lambda kv: -kv[1][0])[:6]:
                print('   %-28s %10d instructions %9d stores' % (f[:28], i, s))
        return

    if picture:
        print('Host work for one picture (RV32, counted from a trace)')
        print()
        print('%-36s %12s %10s %10s %8s' % ('', 'instructions', 'loads', 'stores', 'ms'))
        for mark, n, insns, loads, stores, stack, ns, st in rows:
            print('%-36s %12d %10d %10d %8.0f' % (
                NAMES.get(mark, '%02x' % mark), insns, loads, stores, ns / 1e6))
        print()
        print('"ms" is a guess: %.0f ns for each instruction and %.0f ns for each store.'
              % (NS_INSN, NS_STORE))
        return

    print('Host work for one guest instruction (RV32, counted from a trace)')
    print()
    print('%-36s %10s %8s %7s %7s %7s %9s' % (
        'piece of work', 'guest', 'host', 'loads', 'stores', 'of them', 'thousand'))
    print('%-36s %10s %8s %7s %7s %7s %9s' % (
        '', 'instr.', 'instr.', '', '', 'stack', 'a second'))
    for mark, n, insns, loads, stores, stack, ns, st in rows:
        print('%-36s %10d %8.1f %7.1f %7.2f %7.2f %9.0f' % (
            NAMES.get(mark, '%02x' % mark), n, insns / n, loads / n, stores / n,
            stack / n, 1e6 / ns))
    print()
    print('"thousand a second" is a guess: %.0f ns for each host instruction and %.0f ns'
          % (NS_INSN, NS_STORE))
    print('for each store, which is what three frame rates of another program on the')
    print('ESP32-S31-Korvo-1 came to. Nothing here was timed on that board.')

    for mark, n, insns, loads, stores, stack, ns, st in rows:
        print()
        print('-- %s: where the host instructions and stores were --' % NAMES.get(mark, '%02x' % mark))
        byfunc = {}
        for pc, c in st['pcs'].items():
            f = func.get(pc, '?')
            a = byfunc.setdefault(f, [0, 0])
            a[0] += c
            if kind.get(pc) in ('store', 'stack store'):
                a[1] += c
        for f, (i, s) in sorted(byfunc.items(), key=lambda kv: -kv[1][0])[:8]:
            print('   %-28s %7.1f instructions %6.2f stores, for each guest instruction'
                  % (f[:28], i / n, s / n))
        if st['outside']:
            print('   %-28s %7.1f instructions' % ('(outside the program)', st['outside'] / n))


main()
