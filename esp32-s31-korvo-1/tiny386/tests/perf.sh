#!/bin/bash
# What the emulator spends on a guest instruction: counted, not timed.
#
#   bash tests/perf.sh [rv32] [x86] [grid]
#
# rv32  The board's emulator (every object of tiny386-korvo but its main())
#       runs tests/guest/bench.S under qemu-riscv32-static, which logs every
#       instruction it carries out.  tracecount counts them between the
#       guest's marks, and perf-report.py says how many instructions, loads
#       and stores each guest instruction cost.  About twenty minutes.
# x86   The same sources built for this PC run the same guest under
#       valgrind's callgrind, which counts instructions and stores of x86
#       code.  These are the units the board's two timing figures were
#       fitted in (see BUILD.txt).  About two minutes.
# grid  Mode 10h as an 80x25 grid of 8x14 glyphs written straight into video
#       memory (tests/guest/bgrid.S, "BGRID perf"), traced as rv32 is: what
#       a whole screen of glyphs costs by each way of writing them, what a
#       scroll of a row costs, and the same through the BIOS; then what
#       showing such a screen costs ("BGRID pic").  About ten minutes.
# With no argument, rv32 and x86.
#
# It needs the tree that build.sh leaves in WORK, a FreeDOS image from
# tools/make-freedos-image.sh, the board's compiler, gcc, mtools, python3,
# qemu-riscv32-static and valgrind.
#
# Settings, from the environment:
#   WORK     where build.sh built  ($HOME/tiny386-scratch/build)
#   M        the Buildroot output directory with the compiler; as in build.sh
#   FREEDOS  the image  (freedos-hd.img beside this directory)
#   BIOS     a directory with bios.bin and vgabios.bin  (beside this directory)
#   OUT      work directory  ($WORK/perf)

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/tiny386-scratch/build}
FREEDOS=${FREEDOS:-$HERE/../freedos-hd.img}
BIOS=${BIOS:-$HERE/..}
OUT=${OUT:-$WORK/perf}
HOST=riscv32-buildroot-linux-musl
if [ -z "${M:-}" ]; then
    for M in "$HOME/esp32-s31-linux-main/build/br-output" \
             "$HOME/tiny386-scratch/toolchain/br-output"; do
        [ -x "$M/host/bin/$HOST-gcc" ] && break
    done
fi
T=$M/host/bin/$HOST
TREE=$WORK/tiny386
[ -f "$TREE/obj/i386.o" ] || { echo "no built tree at $TREE: run build.sh first"; exit 1; }
[ -f "$FREEDOS" ] || { echo "no FreeDOS image at $FREEDOS: run tools/make-freedos-image.sh, or set FREEDOS"; exit 1; }
what=${*:-rv32 x86}

mkdir -p "$OUT"
cd "$OUT"

echo "== the guest =="
for p in bench vga12 vga13 vga0d; do
    as --32 -o $p.o "$HERE/guest/$p.S"
    ld -m elf_i386 -Ttext 0x100 --oformat binary -o $(echo $p | tr a-z A-Z).COM $p.o
done
ls -l BENCH.COM VGA12.COM VGA13.COM VGA0D.COM
cp "$BIOS/bios.bin" "$BIOS/vgabios.bin" .
cp "$FREEDOS" bench-hd.img
START=$(python3 -c "
import struct
m = open('bench-hd.img', 'rb').read(512)
print(struct.unpack('<I', m[454:458])[0] * 512)")
# a disk for each program, which FreeDOS starts when it has started itself
for p in bench vga12 vga13 vga0d; do
    [ $p = bench ] || cp bench-hd.img $p-hd.img
    P="$p-hd.img@@$START"
    mcopy -o -i "$P" $(echo $p | tr a-z A-Z).COM ::/DOS/
    printf '@echo off\r\nSET PATH=C:\\DOS\r\n%s\r\n' $p > fdauto.bat
    mcopy -o -i "$P" fdauto.bat ::/FDAUTO.BAT
done
# and two for the grid: BGRID perf, BGRID pic (its source wants the
# includes beside it)
as --32 -I "$HERE/guest" -o bgrid.o "$HERE/guest/bgrid.S"
ld -m elf_i386 -Ttext 0x100 --oformat binary -o BGRID.COM bgrid.o
for a in perf pic; do
    cp bench-hd.img grid-$a-hd.img
    P="grid-$a-hd.img@@$START"
    mcopy -o -i "$P" BGRID.COM ::/DOS/
    printf '@echo off\r\nSET PATH=C:\\DOS\r\nbgrid %s\r\n' $a > fdauto.bat
    mcopy -o -i "$P" fdauto.bat ::/FDAUTO.BAT
done
printf '%s\n' '[pc]' 'bios = bios.bin' 'vga_bios = vgabios.bin' 'mem_size = 8M' \
    'vga_mem_size = 256K' 'fill_cmos = 1' 'hda = bench-hd.img' '' '[cpu]' 'gen = 4' 'fpu = 0' > bench.ini

# the flags build.sh compiled the emulator with
CFLAGS=$(sed -n '1s/^[^ ]* \(.*\) -c [^ ]* -o [^ ]*$/\1/p' "$WORK/tiny386-commands.txt")
OBJS=$(cd "$TREE" && ls obj/*.o | sed "s|^|$TREE/|")

# the board's emulator with perf-main.c for its main(), and the counting
rv32_setup() {
    (cd "$TREE" && $T-gcc $CFLAGS -c "$HERE/perf-main.c" -o "$OUT/perf-main.o")
    $T-gcc -static -Wl,--gc-sections -o perf-rv32 perf-main.o $OBJS -lm
    $T-strip -o perf-rv32-stripped perf-rv32
    $T-objdump -d perf-rv32 > perf-rv32.dis
    MARK=$($T-nm perf-rv32 | awk '$3 == "perf_mark" { print $1 }')
    read SIZE BASE <<< "$($T-objdump -h perf-rv32 | awk '$2 == ".text" { print $3, $4 }')"
    END=$(printf '%x' $((0x$BASE + 0x$SIZE)))
    echo "perf_mark at $MARK, text $BASE to $END"
    gcc -O2 -o tracecount "$HERE/tracecount.c"

    # trace NAME OUT ARGS...: perf with a disk that starts NAME.COM, under
    # the log, into OUT-guest.txt and OUT-counts.txt
    trace() {
        local name=$1 out=$2
        shift 2
        cp $name-hd.img run.img
        sed "s/bench-hd.img/run.img/" bench.ini > run.ini
        qemu-riscv32-static -d in_asm,exec,nochain -D /dev/stderr \
            ./perf-rv32-stripped run.ini "$@" 2>&1 > $out-guest.txt |
            ./tracecount $MARK $BASE $END > $out-counts.txt
    }
}

for w in $what; do
case $w in
rv32)
    echo "== RV32: the board's emulator under a trace =="
    rv32_setup

    echo "-- without the trace, to see that it runs"
    cp bench-hd.img run.img
    sed "s/bench-hd.img/run.img/" bench.ini > run.ini
    qemu-riscv32-static ./perf-rv32-stripped run.ini | tee perf-plain.txt
    echo "-- with the trace"
    time trace bench bench
    python3 "$HERE/perf-report.py" bench-guest.txt bench-counts.txt perf-rv32.dis | tee perf-rv32.txt

    echo "-- pictures: what putting the guest's screen on an 800x480 RGB565 screen costs"
    for p in bench vga13 vga12 vga12-plain vga0d vga0d-plain; do
        case $p in
        *-plain) PERF_PLAINVGA=1 trace ${p%-plain} pictures-$p pictures ;;
        *) trace $p pictures-$p pictures ;;
        esac
        case $p in
        bench) echo; echo "TEXT MODE, 80x25 (the screen FreeDOS has started on)" ;;
        vga13) echo; echo "MODE 13h, 320x200 in 256 colours, shown as 640x400" ;;
        vga12) echo; echo "MODE 12h, 640x480 in 16 colours (Windows' standard VGA driver)" ;;
        vga12-plain) echo; echo "MODE 12h again, drawn pixel by pixel as the other modes are (-plainvga)" ;;
        vga0d) echo; echo "MODE 0Dh, 320x200 in 16 colours (each pixel two dots wide), shown as 640x400" ;;
        vga0d-plain) echo; echo "MODE 0Dh again, drawn pixel by pixel (-plainvga)" ;;
        esac
        # the table only, and "for one picture" where it says "guest instr."
        python3 "$HERE/perf-report.py" pictures-$p-guest.txt pictures-$p-counts.txt perf-rv32.dis picture |
            sed -n '3,9p'
    done | tee pictures-rv32.txt
    ;;
grid)
    echo "== RV32: mode 10h as a grid of text, by each way of drawing it =="
    rv32_setup
    time trace grid-perf grid
    python3 "$HERE/perf-report.py" grid-guest.txt grid-counts.txt perf-rv32.dis grid | tee grid-rv32.txt
    trace grid-pic pictures-grid pictures
    {
        echo
        echo "MODE 10h, 640x350 in 16 colours, the grid of text on the screen (BGRID pic)"
        python3 "$HERE/perf-report.py" pictures-grid-guest.txt pictures-grid-counts.txt perf-rv32.dis picture |
            sed -n '3,9p'
    } | tee -a grid-rv32.txt
    ;;
x86)
    echo "== x86: the same sources under callgrind =="
    DEFS=$(echo " $CFLAGS " | tr ' ' '\n' | grep -E '^-D' | tr '\n' ' ')
    # optimised as the board's build is
    OPT=$(echo " $CFLAGS " | tr ' ' '\n' | grep -E '^-O' | tail -1)
    SRCS="i386.c fpu.c ini.c i8259.c i8254.c ide.c vga.c vgafont.c i8042.c misc.c
          adlib.c ne2000.c i8257.c sb16.c pcspk.c pc.c pci.c term.c"
    (cd "$TREE" && gcc ${OPT:--O2} -g -std=gnu11 -I. $DEFS -DPERF_CALLGRIND $SRCS "$HERE/perf-main.c" -o "$OUT/perf-x86" -lm) 2> perf-x86-build.log
    echo "built with ${OPT:--O2}"
    cp bench-hd.img run.img
    sed "s/bench-hd.img/run.img/" bench.ini > run.ini
    rm -f callgrind.out.*
    valgrind --tool=callgrind --cache-sim=yes --callgrind-out-file=callgrind.out \
        ./perf-x86 run.ini > perf-x86-guest.txt 2> perf-x86-valgrind.log
    cat perf-x86-guest.txt
    python3 - "$@" <<'EOF' | tee perf-x86.txt
import glob, re
guest = [l.split() for l in open('perf-x86-guest.txt') if not l.startswith('boot')]
# one dump for each mark: what was counted since the mark before it
dumps = {}
for path in glob.glob('callgrind.out*'):
    text = open(path, errors='replace').read()
    m = re.search(r'^desc: Trigger: Client Request: before-(\w+)', text, re.M)
    ev = re.search(r'^events: (.*)$', text, re.M)
    tot = re.search(r'^(?:totals|summary): (.*)$', text, re.M)
    if m and ev and tot:
        dumps[int(m.group(1), 16)] = dict(zip(ev.group(1).split(), map(int, tot.group(1).split())))
names = {0xa1: '16-bit arithmetic in registers', 0xa2: '16-bit loads and stores',
         0xa3: '16-bit calls and stack', 0xa4: 'rep movsw/stosw, for each BYTE',
         0xa5: 'DOS calls (int 21h)', 0xa6: '32-bit arithmetic, paging on',
         0xa7: '32-bit loads and stores, paging on', 0xa8: '32-bit calls and stack, paging on',
         0xa9: 'translation cache miss every time'}
print('Host work for one guest instruction (x86-64, counted by callgrind)')
print()
print('%-36s %10s %8s %7s %7s %9s' % ('piece of work', 'guest', 'host', 'loads', 'stores', 'thousand'))
print('%-36s %10s %8s %7s %7s %9s' % ('', 'instr.', 'instr.', '', '', 'a second'))
marks = [int(g[0], 16) for g in guest] + [0xaf]
for (mark, n), nxt in zip(guest, marks[1:]):
    mark, n = int(mark, 16), int(n)
    if mark == 0xa4:
        n = 1000 * 2 * 16384    # what that piece moves and fills
    d = dumps.get(nxt)
    if not d:
        continue
    ns = (d['Ir'] * 16.0 + d['Dw'] * 135.0) / n
    print('%-36s %10d %8.1f %7.1f %7.2f %9.0f' % (names.get(mark, '%02x' % mark), n,
          d['Ir'] / n, d['Dr'] / n, d['Dw'] / n, 1e6 / ns))
print()
print('"thousand a second" is a guess: 16 ns for each host instruction and 135 ns for')
print('each store, which is what three frame rates of another program on the')
print('ESP32-S31-Korvo-1 came to, with counts of this kind. Nothing here was timed on')
print('that board.')
EOF
    ;;
*)  echo "rv32, x86 or grid, not $w"; exit 1 ;;
esac
done
