#!/bin/bash
# How much of the PC BIOS that tiny386 ships (SeaBIOS and SeaVGABIOS, in
# bios.bin and vgabios.bin beside this directory) works, as DOS programs
# use it: int 10h, int 13h, and the VGA's registers.  Under
# qemu-riscv32-static, with the board's binary; nothing here touches a board.
#
#   bash bios-tests.sh [CASE...]
#
# Each case boots FreeDOS from a copy of the FreeDOS image, which runs one of
# the programs in guest/ (b*.S) from FDAUTO.BAT.  The program calls the BIOS
# and says what it got on the BIOS's debug port, which the emulator writes
# to its -log file; it ends by putting 0xAF at 0000:04F0, which ends the
# emulator because of -marks.  Programs that draw run against the fake
# console of run-tests.sh (the board's objects, SDL's frame buffer driver,
# a fake frame buffer and keyboard); when one says @shot, the screen is
# read off the fake frame buffer and checked by bioscheck.py, and a key
# tells the program to go on.  Disk images are checked after the run.
# Every result is then held against bios-expected.txt: what works has to
# pass, and what is known not to work has to fail.  BIOS-COVERAGE.txt, beside
# this directory, says what each means.
#
# It needs what run-tests.sh needs: the trees that build.sh leaves behind,
# the FreeDOS image, gcc's as and ld for a PC, mtools and python3.
#
# Settings, all optional, from the environment:
#   WORK     the directory build.sh built in  ($HOME/tiny386-scratch/build)
#   M        Buildroot output directory with the compiler; as in build.sh
#   BIN      the binary for the board  ($WORK/tiny386-korvo)
#   FAKE     where fakefb.c and fbtool.py are  (../../wolf3d/tests from here)
#   FREEDOS  the hard disk image  (freedos-hd.img beside this directory)
#   BIOS     a directory with bios.bin and vgabios.bin  (beside this directory)
#   OUT      work directory  ($WORK/bios-tests)
#   QEMU     the emulator  (qemu-riscv32-static)

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/tiny386-scratch/build}
BIN=${BIN:-$WORK/tiny386-korvo}
FAKE=${FAKE:-$HERE/../../wolf3d/tests}
FREEDOS=${FREEDOS:-$HERE/../freedos-hd.img}
BIOS=${BIOS:-$HERE/..}
OUT=${OUT:-$WORK/bios-tests}
QEMU=${QEMU:-qemu-riscv32-static}
HOST=riscv32-buildroot-linux-musl
if [ -z "${M:-}" ]; then
    for M in "$HOME/esp32-s31-linux-main/build/br-output" \
             "$HOME/tiny386-scratch/toolchain/br-output"; do
        [ -x "$M/host/bin/$HOST-gcc" ] && break
    done
fi
CC=$M/host/bin/$HOST-gcc
TREE=$WORK/tiny386
SDL=$WORK/SDL-1.2.15
PREFIX=$WORK/prefix

for need in "$BIN" "$TREE/obj/korvo/main.o" "$SDL/src/video/fbcon/SDL_fbevdev.c" \
            "$PREFIX/lib/libSDL.a" "$FAKE/fakefb.c" "$FAKE/fbtool.py" "$FREEDOS" \
            "$BIOS/bios.bin" "$BIOS/vgabios.bin"; do
    [ -e "$need" ] || { echo "$need is not there: see the settings at the top of this script"; exit 2; }
done
QEMUPATH=$(command -v "$QEMU") || { echo "$QEMU is not installed"; exit 2; }
TOOL="python3 $FAKE/fbtool.py"
CHECK="python3 $HERE/bioscheck.py"

FAKES="-Dopen=fake_open -Dclose=fake_close -Dioctl=fake_ioctl -Dmmap=fake_mmap"
FAKES="$FAKES -Dtcgetattr=fake_tcgetattr -Dtcsetattr=fake_tcsetattr -Dtcflush=fake_tcflush"
FAKES="$FAKES -Dgeteuid=fake_geteuid -Daccess=fake_access -Dselect=fake_select -Dexecl=fake_execl"
SDLFLAGS="-O2 -std=gnu99 -D_GNU_SOURCE=1 -fvisibility=hidden -D_REENTRANT -DHAVE_LINUX_VERSION_H"

PROGRAMS="bfonts bmodes btext bpal bchargen binfo bpixel bvbe bregs bdisk bflop bgrid"

mkdir -p "$OUT/cases" "$OUT/shots" || exit 2
cd "$OUT" || exit 2
RESULTS=$OUT/results.txt
# the fake screen's size; the cases change it
GEOM_W=800
GEOM_H=480

# ---------------------------------------------------------------- build

FBTEST=$OUT/tiny386-fbtest

build() {
    echo "== build =="
    rm -f ./*.o "$FBTEST" ./*.COM
    # the board's emulator against the fake console, as run-tests.sh builds it
    $CC -O2 -Wall -c "$FAKE/fakefb.c" -o fakefb.o || exit 1
    for f in SDL_fbvideo SDL_fbevents SDL_fbevdev; do
        $CC $SDLFLAGS -I"$SDL/include" -I"$SDL/src/video/fbcon" $FAKES \
            -c "$SDL/src/video/fbcon/$f.c" -o t_$f.o || exit 1
    done
    local cflags
    cflags=$(sed -n '1s/^[^ ]* \(.*\) -c [^ ]* -o [^ ]*$/\1/p' "$WORK/tiny386-commands.txt")
    (cd "$TREE" && $CC $cflags $FAKES -c korvo/guard.c -o "$OUT/t_guard.o") || exit 1
    $CC -static -Wl,--gc-sections -o "$FBTEST" \
        $(ls "$TREE"/obj/*.o "$TREE"/obj/korvo/*.o | grep -v '/guard\.o$') \
        t_guard.o t_SDL_*.o fakefb.o -L"$PREFIX/lib" -lSDL -lpthread -lm || exit 1

    # the guest's programs
    local p
    for p in $PROGRAMS; do
        [ -f "$HERE/guest/$p.S" ] || continue
        as --32 -I "$HERE/guest" -o $p.o "$HERE/guest/$p.S" || exit 1
        ld -m elf_i386 -Ttext 0x100 --oformat binary -o $(echo $p | tr a-z A-Z).COM $p.o || exit 1
    done
    # two more from the same sources: the floppy test for 720K, and the
    # VBE test for 256K of video memory
    as --32 -I "$HERE/guest" --defsym SPT=9 -o bflop720.o "$HERE/guest/bflop.S" || exit 1
    ld -m elf_i386 -Ttext 0x100 --oformat binary -o BFLOP720.COM bflop720.o || exit 1
    as --32 -I "$HERE/guest" --defsym V256=1 -o bvbe256.o "$HERE/guest/bvbe.S" || exit 1
    ld -m elf_i386 -Ttext 0x100 --oformat binary -o BVBE256.COM bvbe256.o || exit 1
    cp "$FREEDOS" test-hd.img
    START=$(python3 -c "
import struct
m = open('test-hd.img', 'rb').read(512)
print(struct.unpack('<I', m[454:458])[0] * 512)")
    mcopy -o -i "test-hd.img@@$START" ./*.COM ::/DOS/ || exit 1
    # the disks that int 13h is tried on
    $CHECK mkdisk hd disk-hd.img
    $CHECK mkdisk fd144 disk-fd144.img
    $CHECK mkdisk fd720 disk-fd720.img
    : > "$RESULTS"
    echo "built: $(ls "$FBTEST" ./*.COM | tr '\n' ' ')"
}

# ---------------------------------------------------------------- helpers

# begin NAME PROGRAM: a case, with a directory, a disk that runs PROGRAM when
# FreeDOS has started, and a configuration of its own: conf/freedos.ini as
# handed over, which ini changes
begin() {
    name=$1
    d=$OUT/cases/$name
    rm -rf "$d"
    mkdir -p "$d"
    mkfifo "$d/kbd"
    : > "$d/log"
    cp "$BIOS/bios.bin" "$BIOS/vgabios.bin" "$d/"
    cp test-hd.img "$d/freedos-hd.img"
    printf '@echo off\r\nC:\\DOS\\%s.COM\r\n' "$2" > "$d/fdauto.bat"
    mcopy -o -i "$d/freedos-hd.img@@$START" "$d/fdauto.bat" ::/FDAUTO.BAT
    cp "$HERE/../conf/freedos.ini" "$d/t.ini"
    echo
    echo "-- $name ($2.COM) --"
}

# ini KEY VALUE: a [pc] setting, in place of the one there or added
ini() {
    if grep -q "^$1 = " "$d/t.ini"; then
        sed -i "s|^$1 = .*|$1 = $2|" "$d/t.ini"
    else
        sed -i "/^\[pc\]/a $1 = $2" "$d/t.ini"
    fi
}

# run_none: the board's binary with no screen, to its end
run_none() {
    ( cd "$d" && exec "$QEMUPATH" "$BIN" -none -marks -time 300 -log emu.log t.ini ) >> "$d/log" 2>&1
    status=$?
}

# run_screen: the program against the fake console; every @shot it makes is
# looked at, checked, and answered with a key
run_screen() {
    ( cd "$d" && exec env FAKE_STATE="$d/state" FAKE_LOG="$d/log" FAKE_FB="$d/fb" \
        FAKE_KBD="$d/kbd" FAKE_QEMU="$QEMUPATH" FAKE_GEOMETRY=${GEOM_W}x$GEOM_H "$QEMUPATH" "$FBTEST" \
        -marks -time 600 -log emu.log t.ini ) >> "$d/log" 2>&1 &
    pid=$!
    local shots=0 n s suffix=
    [ "${GEOM_W}x$GEOM_H" = 800x480 ] || suffix=-${GEOM_W}x$GEOM_H
    # nothing is ever stopped here: the program ends the emulator (-marks),
    # or -time does
    while [ -e /proc/$pid ]; do
        n=$(grep -a -c '^@shot ' "$d/emu.log" 2>/dev/null)
        if [ "${n:-0}" -gt $shots ]; then
            shots=$((shots + 1))
            s=$(grep -a '^@shot ' "$d/emu.log" | sed -n "${shots}p" | cut -d' ' -f2)
            local raws="$d/$s.raw" i
            case $s in
            *cursor*|*blink*)
                # it blinks, so it never comes to rest: ten looks at it
                sleep 2
                raws=
                for ((i = 0; i < 10; i++)); do
                    cp "$d/fb" "$d/$s-$i.raw"
                    raws="$raws${raws:+,}$d/$s-$i.raw"
                    sleep 0.15
                done
                cp "$d/$s-0.raw" "$d/$s.raw" ;;
            *)
                settle
                cp "$d/fb" "$d/$s.raw" ;;
            esac
            $TOOL png $GEOM_W $GEOM_H "$d/$s.raw" "$OUT/shots/$s$suffix.png"
            BIOSCHECK_GEOMETRY=${GEOM_W}x$GEOM_H $CHECK shot "$s" "$raws" "$d/emu.log" "$OUT/fonts.txt" |
                tee -a "$d/shots.txt" | sed 's/^/   /'
            $TOOL keys "$d/kbd" 57
        fi
        sleep 0.3
    done
    wait $pid
    status=$?
}

# settle: until the fake screen has been the same for a second and a half
settle() {
    local i same=0
    sleep 0.5
    for ((i = 0; i < 60; i++)); do
        cp "$d/fb" "$d/settle.raw"
        sleep 0.5
        if cmp -s "$d/fb" "$d/settle.raw"; then
            same=$((same + 1))
            [ $same -ge 3 ] && return 0
        else
            same=0
        fi
    done
    echo "   the screen never came to rest"
}

# end_case [FROM TO]: the guest's results, the shots' and any others, into
# $RESULTS; names that begin FROM. begin TO. instead (a program run twice)
end_case() {
    local from=${1:-} to=${2:-}
    grep -a -h '^@\(ok\|bad\|info\) ' "$d/emu.log" "$d/shots.txt" "$d/more.txt" 2>/dev/null \
        | if [ -n "$from" ]; then sed "s/^\(@[a-z]*\) ${from//./\\.}\./\1 $to./"; else cat; fi \
        > "$d/results.txt"
    grep -a -q '^@done' "$d/emu.log" || echo "@bad $name.finished the program did not reach its end" >> "$d/results.txt"
    [ "$status" = 0 ] || echo "@bad $name.exit the emulator's exit status was $status" >> "$d/results.txt"
    cat "$d/results.txt" >> "$RESULTS"
    echo "   $(grep -c '^@ok' "$d/results.txt") ok, $(grep -c '^@bad' "$d/results.txt") bad, $(grep -c '^@info' "$d/results.txt") for the record"
    grep '^@bad' "$d/results.txt" | sed 's/^/   /' | head -40
}

# ---------------------------------------------------------------- cases

t_fonts() {
    begin fonts BFONTS
    run_none
    $CHECK fonts "$d/emu.log" "$OUT/fonts.txt"
    end_case
}

# the pictures with text in them are read with the BIOS's fonts
need_fonts() {
    [ -s "$OUT/fonts.txt" ] || t_fonts
}

t_modes() {
    need_fonts
    begin modes BMODES
    run_screen
    end_case
}

t_text() {
    need_fonts
    begin text BTEXT
    run_screen
    end_case
}

t_pal() {
    begin pal BPAL
    run_screen
    end_case
}

t_chargen() {
    need_fonts
    begin chargen BCHARGEN
    run_screen
    end_case
}

t_info() {
    begin info BINFO
    run_screen
    end_case
}

t_pixel() {
    need_fonts
    begin pixel BPIXEL
    run_screen
    end_case
}

# VBE with the 256K of video memory that conf/freedos.ini gives, and with
# 1M, which 640x480 in 256 colours needs.  Both with the screen: VBE offers
# no mode bigger than the screen, and with -none the screen is 16x16.
t_vbe() {
    begin vbe256 BVBE256
    run_screen
    end_case
    begin vbe BVBE
    ini vga_mem_size 1M
    run_screen
    end_case
}

t_regs() {
    need_fonts
    begin regs BREGS
    run_screen
    end_case
}

# int 13h on a second hard disk (drive 81h), and on floppies of 1.44M and
# 720K as drive A:
t_disk() {
    begin disk BDISK
    cp --sparse=always disk-hd.img "$d/hd2.img"
    ini hdb hd2.img
    run_none
    $CHECK disk hd disk-hd.img "$d/hd2.img" "$d/emu.log" > "$d/more.txt"
    end_case
}

t_floppy() {
    local size prog
    for size in 144 720; do
        prog=BFLOP
        [ $size = 720 ] && prog=BFLOP720
        begin floppy$size $prog
        cp disk-fd$size.img "$d/fd.img"
        ini fda fd.img
        run_none
        $CHECK disk fd$size disk-fd$size.img "$d/fd.img" "$d/emu.log" > "$d/more.txt"
        end_case 13.fd 13.fd$size
    done
}

# mode 10h as an 80x25 grid of text written straight into video memory,
# on the 800x480 screen and again on one of 800x600
t_grid() {
    need_fonts
    begin grid BGRID
    run_screen
    end_case
    begin grid600 BGRID
    GEOM_W=800 GEOM_H=600
    run_screen
    GEOM_W=800 GEOM_H=480
    end_case grid grid600
}

# ---------------------------------------------------------------- main

all="fonts modes text pal chargen info pixel vbe regs disk floppy grid"
build
for t in ${*:-$all}; do
    case " $all " in
    *" $t "*) t_$t ;;
    *) echo "no such case: $t (there are: $all)"; exit 2 ;;
    esac
done
echo
# a run of some cases leaves out the others' results: not missing, then
$CHECK report "$RESULTS" "$HERE/bios-expected.txt" ${*:+some} > "$OUT/report.txt"
status=$?
grep -v '^PASS\|^info' "$OUT/report.txt"
exit $status
