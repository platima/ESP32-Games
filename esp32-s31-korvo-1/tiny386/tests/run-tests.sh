#!/bin/bash
# Tests for tiny386 on the ESP32-S31-Korvo-1, under qemu-riscv32-static.
# Nothing here touches a board.
#
#   bash run-tests.sh [CASE...]
#
# With no arguments every case is run.  The first ones run the board's
# binary as it is, with no screen or on a pseudo terminal.  The rest run the
# same program against the fake console of the Wolfenstein 3D port's tests
# (a frame buffer of 800x480 with one mode, virtual terminals, a keyboard):
# SDL's frame buffer driver and this port's console guard are compiled
# against it unchanged, with open(), ioctl(), tcsetattr() and so on renamed,
# and every other object is the one in the board's binary.  After each case
# the console has to be as it was found.
#
# It needs the trees that build.sh leaves behind, a FreeDOS image from
# tools/make-freedos-image.sh, the FreeDOS boot floppy that script fetched,
# gcc, as and ld for a PC (the guest's test programs), mtools and python3.
#
# Settings, all optional, from the environment:
#   WORK     the directory build.sh built in  ($HOME/tiny386-scratch/build)
#   M        Buildroot output directory with the compiler; as in build.sh
#   BIN      the binary for the board  ($WORK/tiny386-korvo)
#   FAKE     where fakefb.c and fbtool.py are  (../../wolf3d/tests from here)
#   FREEDOS  the hard disk image  (freedos-hd.img beside this directory)
#   FLOPPY   the FreeDOS 1.4 boot floppy
#            ($HOME/tiny386-scratch/freedos/floppy/144m/x86BOOT.img)
#   BIOS     a directory with bios.bin and vgabios.bin  (beside this directory)
#   OUT      work directory  ($WORK/tests)
#   SHOTS    where the screen shots go  ($OUT/shots)
#   QEMU     the emulator  (qemu-riscv32-static)

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/tiny386-scratch/build}
BIN=${BIN:-$WORK/tiny386-korvo}
FAKE=${FAKE:-$HERE/../../wolf3d/tests}
FREEDOS=${FREEDOS:-$HERE/../freedos-hd.img}
FLOPPY=${FLOPPY:-$HOME/tiny386-scratch/freedos/floppy/144m/x86BOOT.img}
BIOS=${BIOS:-$HERE/..}
OUT=${OUT:-$WORK/tests}
SHOTS=${SHOTS:-$OUT/shots}
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
DRIVE="python3 $HERE/../tools/drive.py"
FBTEXT="python3 $HERE/fbtext.py $TREE/vgafont.c 800 480"

# what fakefb.c stands in for, in the files that talk to the console
FAKES="-Dopen=fake_open -Dclose=fake_close -Dioctl=fake_ioctl -Dmmap=fake_mmap"
FAKES="$FAKES -Dtcgetattr=fake_tcgetattr -Dtcsetattr=fake_tcsetattr -Dtcflush=fake_tcflush"
FAKES="$FAKES -Dgeteuid=fake_geteuid -Daccess=fake_access -Dselect=fake_select -Dexecl=fake_execl"
# the flags SDL's own Makefile compiles with
SDLFLAGS="-O2 -std=gnu99 -D_GNU_SOURCE=1 -fvisibility=hidden -D_REENTRANT -DHAVE_LINUX_VERSION_H"

pass=0
fail=0
casefails=0

mkdir -p "$OUT/cases" "$SHOTS" || exit 2
cd "$OUT" || exit 2

# ---------------------------------------------------------------- build

FBTEST=$OUT/tiny386-fbtest

build() {
    echo "== build =="
    rm -f ./*.o "$FBTEST"
    $CC -O2 -Wall -c "$FAKE/fakefb.c" -o fakefb.o || exit 1
    # SDL's frame buffer driver, as build.sh patched it, against the fake console
    for f in SDL_fbvideo SDL_fbevents SDL_fbevdev; do
        $CC $SDLFLAGS -I"$SDL/include" -I"$SDL/src/video/fbcon" $FAKES \
            -c "$SDL/src/video/fbcon/$f.c" -o t_$f.o || exit 1
    done
    # the console guard likewise; every other object is the board's
    local cflags
    cflags=$(sed -n '1s/^[^ ]* \(.*\) -c [^ ]* -o [^ ]*$/\1/p' "$WORK/tiny386-commands.txt")
    (cd "$TREE" && $CC $cflags $FAKES -c korvo/guard.c -o "$OUT/t_guard.o") || exit 1
    $CC -static -Wl,--gc-sections -o "$FBTEST" \
        $(ls "$TREE"/obj/*.o "$TREE"/obj/korvo/*.o | grep -v '/guard\.o$') \
        t_guard.o t_SDL_*.o fakefb.o -L"$PREFIX/lib" -lSDL -lpthread -lm || exit 1

    # the guest's test programs, and a disk with them on it
    for p in bench vga12 vga13; do
        as --32 -o $p.o "$HERE/guest/$p.S" || exit 1
        ld -m elf_i386 -Ttext 0x100 --oformat binary -o $(echo $p | tr a-z A-Z).COM $p.o || exit 1
    done
    # VGA12 again, with text printed by the BIOS on the picture
    as --32 --defsym TEXT=1 -o vga12t.o "$HERE/guest/vga12.S" || exit 1
    ld -m elf_i386 -Ttext 0x100 --oformat binary -o VGA12T.COM vga12t.o || exit 1
    cp "$FREEDOS" test-hd.img
    # where the image's partition begins, for mtools
    START=$(python3 -c "
import struct
m = open('test-hd.img', 'rb').read(512)
print(struct.unpack('<I', m[454:458])[0] * 512)")
    mcopy -o -i "test-hd.img@@$START" BENCH.COM VGA12.COM VGA12T.COM VGA13.COM ::/DOS/ || exit 1
    echo "built: $(ls "$FBTEST" BENCH.COM VGA12.COM VGA12T.COM VGA13.COM | tr '\n' ' ')"
}

# ---------------------------------------------------------------- helpers

# begin NAME: a new case, with a directory, a disk and a console of its own
begin() {
    name=$1
    d=$OUT/cases/$name
    casefails=0
    rm -rf "$d"
    mkdir -p "$d"
    mkfifo "$d/kbd"
    : > "$d/log"
    cp "$BIOS/bios.bin" "$BIOS/vgabios.bin" "$d/"
    cp test-hd.img "$d/freedos-hd.img"
    [ -f "$FLOPPY" ] && cp "$FLOPPY" "$d/boot.img"
    # the sample configurations, as they are handed over: 2M of memory each
    cp "$HERE/../conf/freedos.ini" "$d/hd.ini"
    cp "$HERE/../conf/freedos-floppy.ini" "$d/floppy.ini"
    echo
    echo "-- $name --"
}

# run PROGRAM ARGS...: the board's binary in the case's directory, to its end
run() {
    ( cd "$d" && exec "$QEMUPATH" "$@" ) >> "$d/log" 2>&1
    status=$?
}

# start "VAR=value ..." ARGS...: the program against the fake console, in the
# background.  What it prints goes to the same file as what the fake console
# logs, in the order that it happened.
start() {
    local extra=$1
    shift
    ( cd "$d" && exec env FAKE_STATE="$d/state" FAKE_LOG="$d/log" FAKE_FB="$d/fb" \
        FAKE_KBD="$d/kbd" FAKE_QEMU="$QEMUPATH" $extra "$QEMUPATH" "$FBTEST" "$@" ) >> "$d/log" 2>&1 &
    pid=$!
}

# wait_log PATTERN [TENTHS]: until the log has a line that matches
wait_log() {
    local i
    for ((i = 0; i < ${2:-300}; i++)); do
        grep -q -- "$1" "$d/log" && return 0
        kill -0 $pid 2>/dev/null || { grep -q -- "$1" "$d/log" && return 0; break; }
        sleep 0.1
    done
    bad "never logged: $1"
    return 1
}

# wait_text PATTERN [SECONDS]: until the text on the fake screen matches
wait_text() {
    local i
    for ((i = 0; i < ${2:-120} * 2; i++)); do
        if [ -s "$d/fb" ]; then
            cp "$d/fb" "$d/now.raw"
            $FBTEXT "$d/now.raw" > "$d/now.txt" 2>/dev/null
            grep -q -- "$1" "$d/now.txt" && return 0
        fi
        kill -0 $pid 2>/dev/null || break
        sleep 0.5
    done
    bad "never on the screen: $1"
    sed 's/^/      : /' "$d/now.txt" 2>/dev/null | grep -v '^      : $' | tail -8
    return 1
}

# finish [SECONDS]: wait for the program to end, and for the console guard
# after it.  The exit status is left in $status: 128 + N for signal N.
finish() {
    local i
    for ((i = 0; i < ${1:-60} * 10; i++)); do
        kill -0 $pid 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 $pid 2>/dev/null; then
        bad "still running after ${1:-60} s"
        kill -9 $pid
    fi
    wait $pid 2>/dev/null
    status=$?
    for ((i = 0; i < 100; i++)); do
        pgrep -f -- "--console-guard" > /dev/null || break
        sleep 0.1
    done
    pgrep -f -- "--console-guard" > /dev/null && { bad "the console guard is still running"; pkill -9 -f -- "--console-guard"; }
    $TOOL state "$d/state" > "$d/state.txt" 2>&1
}

# keys CODE...: key codes as the kernel sends them: +N down, -N up, N both
keys() { $TOOL keys "$d/kbd" "$@"; }

# type WORD...: letters and digits, each word followed by Enter
type_line() {
    local codes="" c w
    for w in "$@"; do
        for ((c = 0; c < ${#w}; c++)); do
            case ${w:$c:1} in
            a) codes="$codes 30" ;; b) codes="$codes 48" ;; c) codes="$codes 46" ;;
            d) codes="$codes 32" ;; e) codes="$codes 18" ;; f) codes="$codes 33" ;;
            g) codes="$codes 34" ;; h) codes="$codes 35" ;; i) codes="$codes 23" ;;
            m) codes="$codes 50" ;; o) codes="$codes 24" ;; r) codes="$codes 19" ;;
            t) codes="$codes 20" ;;
            v) codes="$codes 47" ;; 1) codes="$codes 2" ;; 2) codes="$codes 3" ;;
            3) codes="$codes 4" ;; *) echo "type_line: no key for ${w:$c:1}"; exit 2 ;;
            esac
        done
        codes="$codes 28"
    done
    # one key at a time: the fake keyboard hands over what it is given at once
    for c in $codes; do
        keys $c
        sleep 0.15
    done
}

# settle [SECONDS]: until the fake screen has been the same for three seconds
settle() {
    local i same=0
    for ((i = 0; i < ${1:-60}; i++)); do
        cp "$d/fb" "$d/settle.raw"
        sleep 1
        if cmp -s "$d/fb" "$d/settle.raw"; then
            same=$((same + 1))
            [ $same -ge 3 ] && return 0
        else
            same=0
        fi
    done
    bad "the screen never came to rest"
    return 1
}

# shot NAME: what is on the fake screen now
shot() {
    cp "$d/fb" "$d/$1.raw"
    $TOOL bbox 800 480 "$d/$1.raw" > "$d/$1.txt"
    $TOOL png 800 480 "$d/$1.raw" "$SHOTS/$name-$1.png"
}

bad() {
    casefails=$((casefails + 1))
    echo "   FAIL: $*"
}

has()       { grep -q -- "$1" "$d/log" || bad "missing from the log: $1"; }
hasnot()    { grep -q -- "$1" "$d/log" && bad "should not be in the log: $1"; }
state_has() { grep -q -- "$1" "$d/state.txt" || bad "state: wanted \"$1\", got: $(tr '\n' ';' < "$d/state.txt")"; }
shot_is()   { grep -q -- "$2" "$d/$1.txt" || bad "screen shot $1: wanted \"$2\", got: $(cat "$d/$1.txt")"; }
exited()    { [ "$status" = "$1" ] || bad "exit status $status, expected $1"; }

# in_order PATTERN...: these lines, in this order
in_order() {
    local at=0 n p
    for p in "$@"; do
        n=$(awk -v at=$at -v p="$p" 'NR > at && index($0, p) { print NR; exit }' "$d/log")
        if [ -z "$n" ]; then
            bad "missing, or out of order: $p"
            return
        fi
        at=$n
    done
}

# Nothing may be printed while the terminal is in graphics mode: the console
# does not scroll then, and lines land on top of each other.  Lines from the
# fake console begin with "game " or "guard ".
quiet_in_graphics() {
    local n
    n=$(awk '/KDSETMODE KD_GRAPHICS/ { g = 1; next } /KDSETMODE KD_TEXT/ { g = 0 }
             g && !/^(game|guard) / { n++ } END { print n + 0 }' "$d/log")
    [ "$n" = 0 ] || bad "$n lines were printed while the terminal was in graphics mode"
}

# the console is as it was before the program started, and it got there by
# the steps that put it back
restored() {
    state_has "console: as it was"
    in_order "KDSETMODE KD_GRAPHICS" "KDSETMODE KD_TEXT"
    hasnot "WOULD WAIT FOR EVER"
}

done_case() {
    if [ $casefails -eq 0 ]; then
        pass=$((pass + 1))
        echo "PASS  $name${1:+: $1}"
    else
        fail=$((fail + 1))
        echo "FAIL  $name"
        sed 's/^/      | /' "$d/log" | tail -30
        sed 's/^/      = /' "$d/state.txt" 2>/dev/null
    fi
}

# ---------------------------------------------------------------- no screen

t_usage() {
    begin usage
    run "$BIN"
    has "Usage:"
    exited 1
    done_case

    begin no-bios
    rm "$d/bios.bin"
    run "$BIN" -none hd.ini
    has "bios = bios.bin: No such file"
    exited 1
    done_case

    begin no-disk
    rm "$d/freedos-hd.img"
    run "$BIN" -none hd.ini
    has "hda = freedos-hd.img: No such file"
    exited 1
    done_case

    # tiny386's serial port is the terminal's keyboard: not on this board
    begin no-serial
    echo "enable_serial = 1" > "$d/serial.ini"
    sed -i "/^fill_cmos = 1/r $d/serial.ini" "$d/hd.ini"
    grep -q "^enable_serial = 1" "$d/hd.ini" || bad "the test did not set it"
    run "$BIN" -none hd.ini
    has "enable_serial = 1: this front end has no serial port to give"
    hasnot "instructions in"
    exited 1
    done_case

    # a file that is not the size of any floppy
    begin bad-floppy
    head -c 1000000 /dev/zero > "$d/boot.img"
    run "$BIN" -none floppy.ini
    has "fda = boot.img: 1000000 bytes is not the size of any floppy"
    hasnot "instructions in"
    exited 1
    done_case

    begin no-memory
    printf 'MemTotal: 15376 kB\nMemAvailable: 3000 kB\nSwapFree: 65532 kB\n' > "$d/meminfo"
    ( cd "$d" && TINY386_MEMINFO=meminfo "$QEMUPATH" "$BIN" -none hd.ini ) >> "$d/log" 2>&1
    status=$?
    has "this machine has 3000 KiB available and 65532 KiB of swap free"
    has "that is not enough"
    hasnot "instructions in"
    exited 1
    done_case "$(grep 'guest memory' "$d/log")"

    begin no-memory-forced
    printf 'MemTotal: 15376 kB\nMemAvailable: 3000 kB\nSwapFree: 65532 kB\n' > "$d/meminfo"
    ( cd "$d" && TINY386_MEMINFO=meminfo "$QEMUPATH" "$BIN" -none -force -insns 1 hd.ini ) >> "$d/log" 2>&1
    status=$?
    has "going on because of -force"
    has "instructions in"
    exited 0
    done_case
}

t_none() {
    begin none
    run "$BIN" -none -insns 5 -log emu.log hd.ini
    has "tiny386: 50[0-9]* instructions in"
    grep -q "SeaBIOS (version" "$d/emu.log" || bad "the BIOS's messages are not in the log file"
    grep -q "load_rom: bios.bin" "$d/emu.log" || bad "the emulator's messages are not in the log file"
    exited 0
    done_case "$(grep 'instructions in' "$d/log")"

    begin none-time
    run "$BIN" -none -time 3 hd.ini
    has "tiny386: 3\.[0-9] s in all"
    exited 0
    done_case

    begin none-kips
    run "$BIN" -none -kips 500 -insns 2 hd.ini
    has "instructions in [34]\.[0-9] s of running: 0\.[45][0-9]* million a second"
    exited 0
    done_case "$(grep 'instructions in' "$d/log")"

    # BENCH.COM, started by FreeDOS itself, with the 4M it wants: nine
    # pieces of work timed, and the emulator ends at the last mark
    begin marks
    cp "$HERE/../conf/bench.ini" "$d/bench.ini"
    printf '@echo off\r\nSET PATH=C:\\DOS\r\nbench\r\n' > "$d/fdauto.bat"
    mcopy -o -i "$d/freedos-hd.img@@$START" "$d/fdauto.bat" ::/FDAUTO.BAT
    run "$BIN" -none -marks bench.ini
    # the counts are as near as the emulator looks: every 4,096 instructions
    has "tiny386: a1 16-bit arithmetic in registers  *2[01][0-9]\{5\} instructions in"
    has "tiny386: a4 rep movsw and stosw, 32 MB  *32768000 bytes"
    has "tiny386: a7 32-bit loads and stores, paging on  *17[0-9]\{5\} instructions in"
    has "tiny386: a9 translation cache miss every time  *10[0-9]\{5\} instructions in"
    [ "$(grep -c '^tiny386: a[1-9] ' "$d/log")" = 9 ] || bad "not nine pieces"
    exited 0
    done_case "$(grep -c '^tiny386: a[1-9] ' "$d/log") pieces timed"

    begin hostbench
    run "$BIN" --hostbench
    has "store of 32 bits"
    has "reading the clock"
    has "This build"
    exited 0
    done_case "$(grep '^This build' "$d/log")"
}

# ---------------------------------------------------------------- a terminal

steps() {   # FILE, then the steps as JSON
    cat > "$1"
}

t_term() {
    begin term-hd
    steps "$d/steps.json" <<'EOF'
[
  {"name": "prompt from the hard disk", "wait": "C:\\\\>", "timeout": 300, "send": "ver\r"},
  {"name": "ver answers", "wait": "C:\\\\>ver\\s+FreeCom version[^\\n]*\\n\\s*C:\\\\>", "timeout": 120, "send": "mem\r"},
  {"name": "mem answers", "wait": "Largest executable program size", "timeout": 120, "send": "dir\r"},
  {"name": "dir answers", "wait": "bytes free", "timeout": 120, "send": "off\r"},
  {"sleep": 5}
]
EOF
    ( cd "$d" && $DRIVE --log raw.log --dump screen.txt steps.json -- "$QEMUPATH" "$BIN" -term hd.ini ) >> "$d/log" 2>&1
    status=$?
    exited 0
    has "dir answers  *ok"
    has "exit status 0"
    grep -q "Total memory  *2,048K" "$d/screen.txt" || bad "mem did not report 2,048K"
    grep -q "Turning OFF system" "$d/screen.txt" || bad "the guest did not switch itself off"
    grep -a -q "tiny386: [0-9]* instructions in" "$d/raw.log" || bad "no count at the end"
    done_case "FreeDOS from the hard disk to a prompt, and off"

    # with the 2M of the sample configuration BENCH says what it needs
    begin term-bench-2M
    steps "$d/steps.json" <<'EOF'
[
  {"name": "prompt from the hard disk", "wait": "C:\\\\>", "timeout": 300, "send": "bench\r"},
  {"name": "BENCH declines", "wait": "BENCH needs a machine with 4 MB and no HIMEM\\.\\s+C:\\\\>", "timeout": 120, "send": "off\r"},
  {"sleep": 5}
]
EOF
    ( cd "$d" && $DRIVE --log raw.log --dump screen.txt steps.json -- "$QEMUPATH" "$BIN" -term -marks hd.ini ) >> "$d/log" 2>&1
    status=$?
    exited 0
    has "BENCH declines  *ok"
    grep -a -q "tiny386: a1 " "$d/raw.log" && bad "a piece was timed"
    done_case "BENCH wants 4 MB, and says so"

    begin term-quit
    steps "$d/steps.json" <<'EOF'
[
  {"name": "prompt from the hard disk", "wait": "C:\\\\>", "timeout": 300, "send": "\u001d"},
  {"sleep": 3}
]
EOF
    ( cd "$d" && $DRIVE --log raw.log --dump screen.txt steps.json -- "$QEMUPATH" "$BIN" -term hd.ini ) >> "$d/log" 2>&1
    status=$?
    exited 0
    has "exit status 0"
    grep -a -q "tiny386: [0-9]* instructions in" "$d/raw.log" || bad "no count at the end"
    done_case "Ctrl+] ends it"

    if [ -f "$d/boot.img" ]; then
        begin term-floppy
        steps "$d/steps.json" <<'EOF'
[
  {"name": "installer question", "wait": "Do you want to proceed \\[Y,N\\]\\?", "timeout": 900, "send": "n\r"},
  {"name": "prompt after N", "wait": "has been aborted\\.\\s+A:\\\\>", "timeout": 600, "send": "ver\r"},
  {"name": "ver answers", "wait": "A:\\\\>ver\\s+FreeCom version[^\\n]*\\n\\s*A:\\\\>", "timeout": 300, "send": "mem\r"},
  {"name": "mem answers", "wait": "Largest executable program size", "timeout": 300},
  {"sleep": 2}
]
EOF
        ( cd "$d" && $DRIVE --log raw.log --dump screen.txt steps.json -- "$QEMUPATH" "$BIN" -term floppy.ini ) >> "$d/log" 2>&1
        status=$?
        exited 0
        has "mem answers  *ok"
        grep -q "Total memory  *2,048K" "$d/screen.txt" || bad "mem did not report 2,048K"
        done_case "FreeDOS from the boot floppy to a prompt"
    fi
}

# ---------------------------------------------------------------- the fake console

t_screen() {
    begin screen-text
    start "" -log emu.log hd.ini
    wait_log "KDSETMODE KD_GRAPHICS"
    wait_text 'C:\\>'
    shot prompt
    $TOOL state "$d/state" > "$d/running.txt"
    grep -q "vt1: GRAPHICS mode, keyboard MEDIUMRAW" "$d/running.txt" \
        || bad "while running: $(tr '\n' ';' < "$d/running.txt")"
    type_line ver mem
    wait_text 'Largest executable program size'
    shot mem
    grep -q "Total memory  *2,048K" "$d/now.txt" || bad "mem did not report 2,048K on the screen"
    type_line off
    finish 60
    has "SDL fbcon: 800x480"
    hasnot "using that, not"
    # the 80x25 text screen is 720x400, and belongs in the middle
    shot_is prompt "at (40,[0-9]*)"
    restored
    quiet_in_graphics
    has "tiny386: [0-9]* instructions in"
    exited 0
    done_case "$(cat "$d/mem.txt"); $(grep -c . "$d/now.txt") lines of text read back"

    begin screen-size
    sed -i 's/width = 800/width = 640/; s/height = 480/height = 400/' "$d/hd.ini"
    start "" hd.ini
    wait_text 'C:\\>'
    type_line off
    finish 60
    has "the screen is 800x480: using that, not the 640x400 of \[display\]"
    restored
    exited 0
    done_case "a [display] of another size is put right"

    begin screen-mode13
    start "" hd.ini
    wait_text 'C:\\>'
    type_line vga13
    sleep 4
    shot picture
    keys 57
    wait_text 'C:\\>'
    type_line off
    finish 60
    # 320x200 with every pixel doubled both ways: 640x400 in the middle
    shot_is picture "picture: 640x400 at (80,40)"
    restored
    exited 0
    done_case "mode 13h: $(cat "$d/picture.txt")"

    begin screen-mode12
    start "" hd.ini
    wait_text 'C:\\>'
    type_line vga12
    sleep 9
    shot picture
    keys 57
    wait_text 'C:\\>'
    type_line off
    finish 60
    # 640x480; the top band is black but for the box, so what is not black
    # begins with the box at the fifth line
    shot_is picture "picture: 640x476 at (80,4), 15 colours"
    restored
    exited 0
    done_case "mode 12h: $(cat "$d/picture.txt")"

    # The BIOS prints on a 16-colour picture, and writes to the CRT
    # controller for every character.  As released, tiny386 clears the screen
    # at each of those writes; this build puts the clear off and mostly leaves
    # it out.  With -plainvga it does what tiny386 does as released.  The
    # two have to leave the same screen, pixel for pixel.
    begin screen-mode12-text
    local way
    for way in quick plain; do
        : > "$d/log"
        rm -f "$d/fb" "$d/state" "$d/now.raw" "$d/now.txt"
        cp test-hd.img "$d/freedos-hd.img"
        if [ $way = plain ]; then start "" -plainvga hd.ini; else start "" hd.ini; fi
        wait_text 'C:\\>'
        type_line vga12t
        sleep 6
        settle
        shot $way
        keys 57
        wait_text 'C:\\>'
        type_line off
        finish 60
        restored
        exited 0
    done
    cmp -s "$d/quick.raw" "$d/plain.raw" || bad "the two ways left different screens"
    cmp -s "$d/quick.raw" "$OUT/cases/screen-mode12/picture.raw" \
        && bad "the text is not on the picture"
    shot_is quick "picture: 640x4[0-9]* at (80,[0-9]*), 1[56] colours"
    done_case "text by the BIOS on mode 12h, the quick way and the plain: $(cat "$d/quick.txt")"
}

t_exits() {
    begin quit-key
    start "" hd.ini
    wait_text 'C:\\>'
    keys +29 +56 14
    finish 30
    restored
    quiet_in_graphics
    has "tiny386: [0-9]* instructions in"
    exited 0
    done_case "Ctrl+Alt+Backspace"

    begin sigterm
    start "" hd.ini
    wait_text 'C:\\>'
    kill -TERM $pid
    finish 30
    restored
    exited 143
    done_case

    begin kill9
    start "" hd.ini
    wait_text 'C:\\>'
    kill -9 $pid
    finish 30
    in_order "KDSETMODE KD_GRAPHICS" "guard vt1 KDSKBMODE K_UNICODE" \
        "guard vt1 tcsetattr as at the start" "guard vt1 KDSETMODE KD_TEXT"
    state_has "console: as it was"
    exited 137
    done_case "the guard put the console back"

    begin kill9-noguard
    start "TINY386_NOGUARD=1" hd.ini
    wait_text 'C:\\>'
    kill -9 $pid
    finish 30
    state_has "NOT AS IT WAS"
    # and by hand
    ( cd "$d" && env FAKE_STATE="$d/state" FAKE_LOG="$d/log" FAKE_FB="$d/fb" FAKE_KBD="$d/kbd" \
        FAKE_TAG=fix "$QEMUPATH" "$FBTEST" --fix-console ) >> "$d/log" 2>&1
    $TOOL state "$d/state" > "$d/state.txt" 2>&1
    has "It has been put back"
    state_has "console: as it was"
    done_case "without the guard the console stays as it was left, and --fix-console puts it back"

    begin screen-no-memory
    printf 'MemTotal: 15376 kB\nMemAvailable: 3000 kB\nSwapFree: 65532 kB\n' > "$d/meminfo"
    start "TINY386_MEMINFO=meminfo" hd.ini
    finish 30
    has "that is not enough"
    hasnot "KD_GRAPHICS"
    exited 1
    done_case "too little memory is said before the screen is touched"
}

# ---------------------------------------------------------------- main

all="usage none term screen exits"
build
for t in ${*:-$all}; do
    case " $all " in
    *" $t "*) t_$t ;;
    *) echo "no such case: $t (there are: $all)"; exit 2 ;;
    esac
done
echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
