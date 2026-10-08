#!/bin/bash
# Tests for Wolfenstein 3D on the ESP32-S31-Korvo-1: SDL 1.2's frame buffer
# driver as patched, and the game on top of it, under qemu-riscv32-static.
# Nothing here touches a board.
#
#   bash run-tests.sh [CASE...]
#
# With no arguments every case is run.  Each one starts a program against a
# fake console (fakefb.c), does something to it, and looks at how the console
# was left and at what happened in what order.
#
# It needs the trees that build.sh leaves behind, the game's data files,
# which are not part of this, and python3.
#
# Settings, all optional, from the environment:
#   WORK      the directory build.sh built in  ($HOME/wolf-scratch/build)
#   M         Buildroot output directory  ($HOME/esp32-s31-linux-main/build/br-output)
#   SDL       the patched and built SDL source tree  ($WORK/SDL-1.2.15)
#   SDLSTOCK  an SDL 1.2.15 source tree as released, for the comparison
#             cases, which are skipped if it is not there  ($WORK/SDL-1.2.15-stock)
#   WOLF      the patched and built Wolf4SDL tree  ($WORK/Wolf4SDL)
#   PREFIX    where the SDL libraries were installed  ($WORK/prefix)
#   DATA      a directory with the eight WL6 files, of the full version 1.4
#             as GT Interactive and Activision sold it  ($HOME/wolf-scratch/data/lower)
#   BIN       the binary for the board  (wolf3d-korvo beside this directory)
#   OUT       work directory  ($WORK/tests)
#   SHOTS     where the screen shots go  ($OUT/shots)
#   QEMU      the emulator  (qemu-riscv32-static)
#   ARCH      compiler flags that build.sh was given for this build and that
#             the files compiled here need as well  (none).  For the zb build:
#               WORK=$HOME/wolf-scratch/build-zb BIN=$WORK/wolf3d-korvo-zb \
#               ARCH="-march=rv32imac_zicsr_zifencei_zba_zbb_zbs -mabi=ilp32"

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/wolf-scratch/build}
M=${M:-$HOME/esp32-s31-linux-main/build/br-output}
SDL=${SDL:-$WORK/SDL-1.2.15}
SDLSTOCK=${SDLSTOCK-$WORK/SDL-1.2.15-stock}
[ -d "$SDLSTOCK" ] || SDLSTOCK=
WOLF=${WOLF:-$WORK/Wolf4SDL}
PREFIX=${PREFIX:-$WORK/prefix}
DATA=${DATA:-$HOME/wolf-scratch/data/lower}
BIN=${BIN:-$HERE/../wolf3d-korvo}
OUT=${OUT:-$WORK/tests}
SHOTS=${SHOTS:-$OUT/shots}
QEMU=${QEMU:-qemu-riscv32-static}
ARCH=${ARCH:-}

for need in "$SDL/src/video/fbcon/SDL_fbevdev.c" "$WOLF/wl_fbcon.o" "$PREFIX/lib/libSDL.a" "$DATA"; do
    [ -e "$need" ] || { echo "$need is not there: run build.sh first, or see the settings at the top of this script"; exit 2; }
done
QEMUPATH=$(command -v "$QEMU") || { echo "$QEMU is not installed"; exit 2; }

CC="$M/host/bin/riscv32-buildroot-linux-musl-gcc $ARCH"
CXX="$M/host/bin/riscv32-buildroot-linux-musl-g++ $ARCH"
TOOL="python3 $HERE/fbtool.py"

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

# the programs under test; the mutants put broken ones here for a while
PROBE=$OUT/sdlprobe
GAME=$OUT/wolf3d-fbtest
LIBS="-L$PREFIX/lib -lSDL_mixer -lSDL -lpthread -lm"
GAMEOBJS=$(ls "$WOLF"/*.o "$WOLF"/dosbox/*.o | grep -v '/wl_fbcon\.o$')

# a file of SDL's frame buffer driver, against the fake console
cc_sdl() {      # SOURCE OBJECT
    $CC $SDLFLAGS -I"$SDL/include" -I"$SDL/src/video/fbcon" $FAKES -c "$1" -o "$2"
}

# a file of the game, as its Makefile compiles it; with the fakes if asked
cxx_game() {    # SOURCE OBJECT [fakes]
    $CXX -O2 -I"$PREFIX/include/SDL" -I"$WOLF" -D_GNU_SOURCE=1 -D_REENTRANT -Wpointer-arith \
        -Wreturn-type -Wwrite-strings -Wcast-align -Wno-narrowing -DUSE_GPL ${3:+$FAKES} -c "$1" -o "$2"
}

link_probe() {  # OUTPUT OBJECTS...
    local out=$1
    shift
    $CC -O2 -Wall -static -I"$PREFIX/include/SDL" -D_GNU_SOURCE=1 -D_REENTRANT \
        -o "$out" "$HERE/sdlprobe.c" "$@" fakefb.o $LIBS
}

link_game() {   # OUTPUT OBJECTS...
    local out=$1
    shift
    $CXX -static -o "$out" "$@" fakefb.o $LIBS
}

build() {
    echo "== build =="
    rm -f ./*.o wolf3d-fbtest sdlprobe sdlprobe-stock wolf3d-fbtest-stock

    $CC -O2 -Wall -c "$HERE/fakefb.c" -o fakefb.o || exit 1

    # SDL's frame buffer driver, patched, against the fake console
    for f in SDL_fbvideo SDL_fbevents SDL_fbevdev; do
        cc_sdl "$SDL/src/video/fbcon/$f.c" t_$f.o || exit 1
    done
    # the game's console guard likewise; every other object is the board's
    cxx_game "$WOLF/wl_fbcon.cpp" t_wl_fbcon.o fakes || exit 1

    link_game wolf3d-fbtest $GAMEOBJS t_wl_fbcon.o t_SDL_*.o || exit 1
    link_probe sdlprobe t_SDL_*.o || exit 1

    # and the driver as released, to show what the patch changes
    if [ -n "$SDLSTOCK" ]; then
        for f in SDL_fbvideo SDL_fbevents; do
            $CC $SDLFLAGS -I"$SDL/include" $FAKES -c "$SDLSTOCK/src/video/fbcon/$f.c" -o s_$f.o || exit 1
        done
        $CC -O2 -Wall -static -I"$PREFIX/include/SDL" -D_GNU_SOURCE=1 -D_REENTRANT \
            -o sdlprobe-stock "$HERE/sdlprobe.c" s_SDL_*.o fakefb.o $LIBS || exit 1
        $CXX -static -o wolf3d-fbtest-stock $GAMEOBJS t_wl_fbcon.o s_SDL_*.o fakefb.o $LIBS || exit 1
    fi
    echo "built: $(ls wolf3d-fbtest sdlprobe sdlprobe-stock wolf3d-fbtest-stock 2>/dev/null | tr '\n' ' ')"
}

# ---------------------------------------------------------------- helpers

# begin NAME: a new case, with a console of its own
begin() {
    name=$1
    d=$OUT/cases/$name
    casefails=0
    rm -rf "$d"
    mkdir -p "$d/home"
    mkfifo "$d/kbd" "$d/mouse"
    : > "$d/log"
    echo
    echo "-- $name --"
}

# start "VAR=value ..." PROGRAM ARGS...: in the background, in the data
# directory.  What it prints goes to the same file as what the fake console
# logs, in the order that it happened.
start() {
    local extra=$1
    shift
    # WOLF3D_CHECK_PRESENT makes the game read the screen back after every
    # picture it puts there and stop if the two differ
    ( cd "$DATA" && exec env HOME="$d/home" FAKE_STATE="$d/state" FAKE_LOG="$d/log" \
        FAKE_FB="$d/fb" FAKE_KBD="$d/kbd" FAKE_QEMU="$QEMUPATH" FAKE_CRASH="$d/crash" \
        WOLF3D_CHECK_PRESENT=1 $extra "$QEMUPATH" "$@" ) >> "$d/log" 2>&1 &
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

keys()  { $TOOL keys "$d/kbd" "$@"; }
mouse() { $TOOL mouse "$d/mouse" "$@"; }

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
    in_order "KDSETMODE KD_GRAPHICS" "KDSETMODE KD_TEXT" "KDSKBMODE K_UNICODE" "tcsetattr as at the start"
    hasnot "WOULD WAIT FOR EVER"
}

done_case() {
    if [ $casefails -eq 0 ]; then
        pass=$((pass + 1))
        echo "PASS  $name${1:+: $1}"
    else
        fail=$((fail + 1))
        echo "FAIL  $name"
        sed 's/^/      | /' "$d/log" | tail -40
        sed 's/^/      = /' "$d/state.txt" 2>/dev/null
    fi
}

counts() { grep '^counts:' "$d/state.txt" | sed 's/^counts: //'; }

# ---------------------------------------------------------------- the driver alone

t_probe_sizes() {
    local size where
    for size in "640 400 80,40 64160" "320 200 240,140 224480" "800 480 0,0 0" "640 480 80,0 160"; do
        set -- $size
        begin "probe-$1x$2"
        start "" $PROBE $1 $2 -ms 1500
        wait_log "^video:" && sleep 0.5
        shot during
        $TOOL state "$d/state" > "$d/running.txt"
        finish
        has "video: $1x$2, 16 bpp, pitch 1600, offset $4, hardware surface"
        has "the frame buffer itself"
        shot_is during "picture: $1x$2 at ($3), 1 colours"
        grep -q "vt1: GRAPHICS mode, keyboard MEDIUMRAW, terminal settings RAW" "$d/running.txt" \
            || bad "while running: $(tr '\n' ';' < "$d/running.txt")"
        grep -q "switching LOCKED" "$d/running.txt" || bad "switching was not locked while running"
        shot after
        shot_is after "picture: none"
        restored
        exited 0
        done_case "$(cat "$d/during.txt")"
    done

    begin probe-too-big
    start "" $PROBE 1024 768 -ms 500
    finish
    has "SDL_SetVideoMode failed: No video mode large enough for 1024x768"
    hasnot "KD_GRAPHICS"
    state_has "console: as it was"
    exited 1
    done_case

    begin probe-startup-cost
    start "SDL_FBCON_VERBOSE=1" $PROBE -ms 300
    finish
    has "surface: 24x32 asked for as a hardware surface: 16 bpp, pitch 48, 1536 bytes"
    has "SDL fbcon: keyboard on virtual terminal 1 (the one this was started on)"
    has "SDL fbcon: no mouse found"
    has "SDL fbcon: 800x480, 16 bits per pixel, the only mode"
    state_has "0 screen switches"
    state_has "2048 keymap requests"
    [ "$(grep -c 'the console is redrawn' "$d/log")" -le 2 ] || bad "more than two console redraws"
    restored
    done_case "$(counts)"

    begin probe-double-buffer
    start "" $PROBE -ms 300 -flags dbl
    finish
    has "a copy that SDL keeps"
    restored
    done_case "asking for double buffering gets a second copy of the screen"
}

t_probe_stock() {
    [ -x $OUT/sdlprobe-stock ] || { echo; echo "SKIP  the comparison with SDL as released: SDLSTOCK is not set"; return; }

    begin stock-no-mouse
    start "" $OUT/sdlprobe-stock -ms 300
    finish
    has "SDL_Init failed: Unable to open mouse"
    exited 1
    done_case "SDL as released does not start without a mouse device"

    begin stock-startup-cost
    start "SDL_NOMOUSE=1" $OUT/sdlprobe-stock -ms 300
    finish
    has "surface: 24x32 asked for as a hardware surface: 16 bpp, pitch 1600, 51200 bytes"
    has "VT_OPENQRY: 2"
    has "TIOCNOTTY"
    has "the screen moves from vt1"
    state_has "console: as it was"
    done_case "$(counts)"
}

t_probe_keys() {
    begin probe-keys
    start "" $PROBE -ms 20000
    wait_log "^video:"
    keys 28 103 108 105 106 57        # Enter, the arrows, space
    keys +29 +56 60 -56 -29           # Ctrl + Alt + F2
    keys +97 -97 +100 -100            # Right Ctrl, AltGr
    # Keycode 157, down and up, while Ctrl is held.  Its three bytes are 0,
    # then 0x81 and 0x9d, which read as keys are Esc and Ctrl being let go.
    keys +29
    keys 0x00 0x81 0x9d 0x80 0x81 0x9d
    keys 14                           # Backspace, with Ctrl still down
    keys -29
    keys 68                           # F10
    keys 1                            # Esc
    finish
    in_order "key down: return" "key up: return" "key down: up" "key down: down" \
        "key down: left" "key down: right" "key down: space" \
        "key down: left ctrl" "key down: left alt" "key down: f2" "key up: f2" \
        "key up: left alt" "key up: left ctrl" \
        "key down: right ctrl" "key up: right ctrl" "key down: right alt" "key up: right alt" \
        "key down: left ctrl" "key down: backspace" "key up: backspace" "key up: left ctrl" \
        "key down: f10" "key down: escape" "key up: escape" "ending: quit"
    # Ctrl+Alt+F2 must not move the screen
    state_has "0 screen switches"
    hasnot "VT_ACTIVATE 2"
    [ "$(grep -c '^key ' "$d/log")" = 30 ] || bad "$(grep -c '^key ' "$d/log") key events, expected 30"
    restored
    exited 0
    done_case "30 key events from 15 key presses, none from the key above 127"

    begin probe-keys-vtswitch
    start "SDL_FBCON_VTSWITCH=1" $PROBE -ms 20000
    wait_log "^video:"
    keys +29 +56 +60
    sleep 0.5
    $TOOL state "$d/state" > "$d/running.txt"
    kill -TERM $pid
    finish
    has "the screen moves from vt1"
    grep -q "screen on vt2" "$d/running.txt" || bad "the screen did not move: $(head -1 "$d/running.txt")"
    done_case "with SDL_FBCON_VTSWITCH set, Ctrl+Alt+F2 moves the screen as it used to"

    begin probe-unread-keys
    start "" $PROBE -ms 2500 -deaf
    wait_log "^video:"
    keys +30 +31 +32 +33              # typed at a program that is not listening
    finish
    state_has "console: as it was"
    grep -q "tcsetattr as at the start, [1-9]" "$d/log" || bad "no unread key bytes were dropped"
    done_case "$(grep -o '[0-9]* unread key bytes dropped' "$d/log" | tail -1)"
}

t_probe_mouse() {
    begin probe-mouse
    start "FAKE_OTHER0=1 FAKE_MOUSE3=$d/mouse SDL_FBCON_VERBOSE=1" $PROBE -ms 20000
    wait_log "^video:"
    mouse x=5 y=-3 syn;                 sleep 0.3
    mouse left=1 syn;                   sleep 0.3
    mouse x=10 syn x=10 syn x=-4 syn;   sleep 0.3
    mouse left=0 syn right=1 syn right=0 syn middle=1 syn middle=0 syn; sleep 0.3
    mouse wheel=1 syn;                  sleep 0.3
    mouse wheel=-1 syn;                 sleep 0.3
    mouse x=100000 syn;                 sleep 0.3
    mouse drop syn;                     sleep 0.3
    keys 1
    finish
    has "SDL fbcon: mouse on /dev/input/event3 (Fake Mouse 3)"
    hasnot "event0"
    # the pointer starts in the top left corner and stops at the edges; three
    # movements that arrive together are one event; more movement than SDL
    # can count is cut down to what it can
    in_order "mouse moved by (5,-3) to (5,0)" "mouse button 1 down" \
        "mouse moved by (16,0) to (21,0)" "mouse button 1 up" \
        "mouse button 3 down" "mouse button 3 up" "mouse button 2 down" "mouse button 2 up" \
        "mouse button 4 down" "mouse button 4 up" "mouse button 5 down" "mouse button 5 up" \
        "mouse moved by (16383,0) to (639,0)"
    [ "$(grep -c '^mouse ' "$d/log")" = 13 ] || bad "$(grep -c '^mouse ' "$d/log") mouse events, expected 13"
    restored
    exited 0
    done_case "$(grep -c '^mouse ' "$d/log") mouse events"

    begin probe-mouse-unplugged
    start "FAKE_MOUSE1=$d/mouse" $PROBE -ms 20000
    wait_log "^video:"
    mouse left=1 syn; sleep 0.3
    # a read that fails: the FIFO is replaced by a file, which reads as ended
    exec 9<>"$d/mouse"; rm "$d/mouse"; : > "$d/mouse"
    sleep 0.5
    keys 1
    finish
    exec 9>&-
    in_order "mouse button 1 down" "key down: escape"
    restored
    done_case "the program carries on"

    begin probe-nomouse
    start "FAKE_MOUSE3=$d/mouse SDL_NOMOUSE=1 SDL_FBCON_VERBOSE=1" $PROBE -ms 300
    finish
    has "SDL fbcon: no mouse looked for, SDL_NOMOUSE is set"
    hasnot "mouse on /dev/input"
    restored
    done_case
}

t_probe_ends() {
    local how
    for how in return exit; do
        begin "probe-end-$how"
        start "" $PROBE -ms 300 -end $how
        finish
        has "ending: $how"
        hasnot "after SDL_Quit"
        restored
        [ $how = exit ] && exited 5
        done_case "ended without SDL_Quit"
    done

    # SDL takes its own SIGINT and SIGTERM handlers out when it quits, and
    # ours must not leave them in: they only post an event, and a program
    # that has quit SDL reads no events.
    begin probe-signal-after-quit
    start "" $PROBE -ms 300 -linger 8000
    wait_log "after SDL_Quit" && sleep 0.3
    kill -TERM $pid
    finish 5
    hasnot "lingered to the end"
    state_has "console: as it was"
    exited 143
    done_case "after SDL_Quit, SIGTERM ends the program as it should"
}

t_probe_hangup() {
    if is_ignored HUP; then
        echo
        echo "SKIP  probe-hangup: SIGHUP is ignored in this run"
        return
    fi
    begin probe-hangup
    start "FAKE_HANGUP=$d/hangup" $PROBE -ms 20000
    wait_log "^video:" && sleep 0.3
    : > "$d/hangup"
    kill -HUP $pid
    finish
    in_order "EIO: this descriptor" "open /dev/tty1" "vt1 KDSETMODE KD_TEXT" \
        "vt1 KDSKBMODE K_UNICODE" "vt1 tcsetattr as at the start"
    state_has "console: as it was"
    exited 129
    done_case "the terminal was hung up: it is opened again by its number, and put back"
}

t_probe_terminals() {
    begin probe-from-ssh-root
    start "FAKE_CTTY=0 SDL_FBCON_VERBOSE=1" $PROBE -ms 800
    wait_log "^video:" && sleep 0.3
    $TOOL state "$d/state" > "$d/running.txt"
    finish
    in_order "VT_OPENQRY: 2" "open /dev/tty2" "TIOCNOTTY" "the screen moves from vt1" \
        "vt2 KDSETMODE KD_GRAPHICS" "VT_LOCKSWITCH" "vt2 KDSETMODE KD_TEXT" "VT_UNLOCKSWITCH" \
        "VT_ACTIVATE 1: the screen moves from vt2"
    has "keyboard on virtual terminal 2 (not the one this was started on)"
    grep -q "vt1: text mode, keyboard unicode, terminal settings as at the start" "$d/running.txt" \
        || bad "vt1 was touched: $(tr '\n' ';' < "$d/running.txt")"
    state_has "console: as it was"
    exited 0
    done_case "not started on a console: a new terminal is used, and left again"

    begin probe-from-ssh-user
    start "FAKE_CTTY=0 FAKE_EUID=1000" $PROBE -ms 300
    finish
    has "SDL_Init failed: Unable to open a console terminal"
    hasnot "KD_GRAPHICS"
    state_has "console: as it was"
    exited 1
    done_case

    begin probe-newvt-asked-for
    start "SDL_FBCON_NEWVT=1" $PROBE -ms 500
    finish
    in_order "VT_OPENQRY: 2" "the screen moves from vt1" "vt2 KDSETMODE KD_GRAPHICS" \
        "vt2 KDSETMODE KD_TEXT" "VT_ACTIVATE 1: the screen moves from vt2"
    state_has "console: as it was"
    done_case

    begin probe-newvt-killed
    start "SDL_FBCON_NEWVT=1" $PROBE -ms 20000
    wait_log "^video:" && sleep 0.3
    kill -TERM $pid
    finish
    in_order "vt2 KDSETMODE KD_GRAPHICS" "vt2 KDSETMODE KD_TEXT" "VT_UNLOCKSWITCH" \
        "VT_ACTIVATE 1: the screen moves from vt2"
    state_has "console: as it was"
    exited 143
    done_case "SIGTERM on a new terminal: put back, and the screen is on vt1 again"

    begin probe-no-tiocgdev
    start "FAKE_FAIL=TIOCGDEV FAKE_EUID=1000 SDL_FBCON_VERBOSE=1" $PROBE -ms 300
    finish
    has "keyboard on virtual terminal 1"
    restored
    done_case "an old kernel, not root: the terminal it was started on, as SDL always did"
}

t_probe_failures() {
    local what at
    # the third KDGKBMODE is the one that saves the keyboard mode; the first
    # two ask whether this is a console.  The second FBIOGET_FSCREENINFO is
    # made when the console is in graphics mode already.
    for what in "tcgetattr 1" "KDGKBMODE 3" "KDSKBMODE 1" "KDSETMODE 1" "mmap 0" "FBIOGET_FSCREENINFO 2"; do
        set -- $what
        begin "probe-fails-$1"
        start "FAKE_FAIL=$1 $([ $2 = 0 ] || echo FAKE_FAIL_AT=$2)" $PROBE -ms 300
        finish
        has "failed:"
        state_has "console: as it was"
        quiet_in_graphics
        exited 1
        done_case "$(grep -o 'failed: .*' "$d/log")"
    done
}

SIGNALS="SEGV BUS ILL FPE ABRT TERM HUP INT QUIT PIPE ALRM USR1 USR2"

# A signal that is being ignored is left ignored: it must not end the
# program, and must not put the console back under it.  SIGALRM is always
# one, because SDL sets it to be ignored when it starts.  Others are if this
# script was started with them ignored: SIGHUP under nohup, SIGINT and SIGQUIT
# when it is put in the background by another script.  Ask a program started
# the way the cases start theirs.
( exec grep '^SigIgn:' /proc/self/status ) > "$OUT/sigign" 2>/dev/null &
wait
IGNMASK=$(( 0x$(awk '{ print $2 }' "$OUT/sigign") ))

is_ignored() {
    [ $1 = ALRM ] || [ $(( (IGNMASK >> ($(kill -l $1) - 1)) & 1 )) = 1 ]
}

for sig in $SIGNALS; do
    [ $sig = ALRM ] || ! is_ignored $sig || echo "NOTE  SIG$sig is ignored in this run, so its cases" \
        "only check that it stays ignored. Start the script in the foreground, without nohup, to test it."
done

# send_signal SIG [quiet]: to the program that was just started, and see what
# it does.  With "quiet" the program must also have printed nothing while the
# console was in graphics mode (the game; the probe prints as it goes).
send_signal() {
    kill -$1 $pid
    if is_ignored $1; then
        sleep 0.7
        kill -0 $pid 2>/dev/null || bad "SIG$1 ended the program, and was being ignored"
        $TOOL state "$d/state" | grep -q "GRAPHICS mode, keyboard MEDIUMRAW" \
            || bad "SIG$1 put the console back while the program runs"
        kill -TERM $pid
        finish
        restored
        [ -z "${2:-}" ] || quiet_in_graphics
        exited 143
        done_case "ignored$([ $1 = ALRM ] && echo ', as SDL sets it'): the program carries on"
    else
        finish
        restored
        [ -z "${2:-}" ] || quiet_in_graphics
        exited $((128 + $(kill -l $1)))
        hasnot "ending:"
        hasnot "guard vt"
        done_case "died of the signal, console put back first"
    fi
}

t_probe_signals() {
    local sig
    for sig in $SIGNALS; do
        begin "probe-SIG$sig"
        start "" $PROBE -ms 20000
        wait_log "^video:" && sleep 0.3
        send_signal $sig
    done
}

# ---------------------------------------------------------------- the game

# quit from inside a level: F10, then Y
quit_game() { keys 68; sleep 0.5; keys 21; }

t_game_play() {
    local res
    # name, options (with _ for a space), the picture on the screen, and
    # what the game says it drew and showed
    for res in "default - 640x400 80,40 320x200" \
               "fill --scale_fill 800x480 0,0 320x200" \
               "aspect --scale_aspect 640x480 80,0 320x200" \
               "drawn-640x400 --res_640_400 640x400 80,40 640x400" \
               "drawn-800x480 --resf_800_480 800x480 0,0 800x480" \
               "scale-off --scale_off 320x200 240,140 -"; do
        set -- $res
        begin "game-play-$1"
        start "" $GAME --tedlevel 0 --nowait $([ $2 = - ] || echo ${2//_/ })
        wait_log "KDSETMODE KD_GRAPHICS" && sleep 4
        shot playing
        keys 103 103 103                # walk forward a little
        quit_game
        finish
        shot_is playing "picture: $3 at ($4)"
        if [ $5 = - ]; then
            hasnot "wolf3d: drawn at"
        else
            has "wolf3d: drawn at $5, shown at $3 from ($4)"
        fi
        hasnot "VP_Check"
        restored
        quiet_in_graphics
        in_order "SDL fbcon: keyboard on virtual terminal 1" "KDSETMODE KD_GRAPHICS" \
            "KDSETMODE KD_TEXT" "No sound: No available audio device" "wolf3d: "
        state_has "0 screen switches"
        exited 0
        done_case "$(cat "$d/playing.txt"); $(grep '^wolf3d: [0-9]' "$d/log")"
    done
}

# sign_on NAME OPTIONS...: start the game, take a screen shot of its sign-on
# screen, which does not move, and end it
sign_on() {
    local shotname=$1
    shift
    start "" $GAME "$@"
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 3
    shot $shotname
    keys +56 +62                        # Alt+F4
    finish
    exited 0
}

t_game_scale() {
    local mode mode2
    # The same still picture, drawn by SDL at its own size and by the game
    # enlarged.  fbtool.py works out what the enlarged one has to be.
    begin game-scale-exact
    sign_on plain --scale off
    shot_is plain "picture: 320x200 at (240,140)"
    for mode in "whole 80,40,640,400" "fill 0,0,800,480" "aspect 80,0,640,480"; do
        set -- $mode
        sign_on $1 --scale $1
        $TOOL scalecheck 800 480 "$d/plain.raw" 240,140,320,200 "$d/$1.raw" $2 > "$d/$1-check.txt"
        grep -q "all 384000 pixels are right" "$d/$1-check.txt" || bad "--scale $1: $(cat "$d/$1-check.txt")"
    done
    hasnot "VP_Check"
    restored
    done_case "whole, fill and aspect: every pixel on the screen is the one it should be"

    # Drawn large and not enlarged: the game's own code against SDL's
    begin game-scale-one-to-one
    sign_on sdl --scale off --res 640 400
    sign_on own --res 640 400
    cmp -s "$d/sdl.raw" "$d/own.raw" || bad "640x400 by the game is not what SDL puts there"
    sign_on sdl800 --scale off --resf 800 480
    sign_on own800 --resf 800 480
    cmp -s "$d/sdl800.raw" "$d/own800.raw" || bad "800x480 by the game is not what SDL puts there"
    shot_is own "picture: 640x400 at (80,40)"
    hasnot "VP_Check"
    done_case "at 640x400 and 800x480 the screen is the same, byte for byte, as with SDL's code"

    # The fizzle fade puts the picture there a pixel at a time.  The player
    # dies of the debug keys (Tab+H takes 16 from his health), which is one
    # fade to red and one back into the level.
    for mode in whole fill; do
        begin "game-fizzle-$mode"
        start "" $GAME --tedlevel 0 --nowait --goobers --scale $mode
        wait_log "KDSETMODE KD_GRAPHICS" && sleep 4
        shot alive
        keys +42 +56 +14 -14 -56 -42    # Shift+Alt+Backspace: the debug keys
        sleep 1
        keys 28                         # past the message
        sleep 0.5
        for mode2 in 1 2 3 4 5 6 7 8; do
            keys +15 +35 -35 -15
        done
        sleep 9                         # dies, fades to red, and is back in the level
        shot again
        quit_game
        finish
        cmp -s "$d/alive.raw" "$d/again.raw" && bad "nothing happened on the screen"
        hasnot "VP_Check"
        restored
        exited 0
        done_case "the picture after each fade is the one it should be"
    done
}

t_game_menu() {
    begin game-menu-quit
    start "" $GAME
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 3
    shot signon
    keys 28; sleep 3                    # past the sign-on screen
    shot rating
    keys 28; sleep 3                    # past the rating screen
    shot title
    keys 28; sleep 3                    # any key: the main menu
    shot menu
    keys 16; sleep 0.5                  # Q goes to Quit
    keys 28; sleep 1
    shot quit
    keys 21                             # Y
    finish
    cmp -s "$d/title.raw" "$d/menu.raw" && bad "the main menu did not come up"
    [ -s "$d/home/.wolf4sdl/config.wl6" ] || bad "no configuration file was written on the way out"
    restored
    quiet_in_graphics
    exited 0
    done_case "sign-on, rating, title, main menu, quit; the configuration is saved"
}

t_game_timedemo() {
    begin game-timedemo
    start "" $GAME --timedemo 0
    finish 120
    restored
    quiet_in_graphics
    in_order "KDSETMODE KD_TEXT" "timedemo 0: 691 frames in "
    exited 0
    done_case "$(grep '^timedemo' "$d/log")"

    begin game-timedemo-stopped
    start "" $GAME --timedemo 1 --extravbls 2
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 3
    keys 1
    finish 120
    restored
    in_order "KDSETMODE KD_TEXT" "stopped early"
    done_case "$(grep '^timedemo' "$d/log")"
}

t_game_signals() {
    local sig
    for sig in $SIGNALS; do
        begin "game-SIG$sig"
        start "" $GAME --tedlevel 0 --nowait
        wait_log "KDSETMODE KD_GRAPHICS" && sleep 2.5
        send_signal $sig quiet
    done
}

t_game_killed() {
    begin game-SIGKILL
    start "" $GAME --tedlevel 0 --nowait
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 2.5
    kill -KILL $pid
    finish
    in_order "the console guard is started" "game vt1 KDSETMODE KD_GRAPHICS" \
        "guard vt1 KDSKBMODE K_UNICODE" "guard vt1 tcsetattr as at the start" \
        "guard vt1 KDSETMODE KD_TEXT" "guard VT_UNLOCKSWITCH"
    state_has "console: as it was"
    exited 137
    done_case "nothing in the game ran; the console guard put the console back"

    begin game-SIGKILL-no-guard
    start "WOLF3D_NOGUARD=1" $GAME --tedlevel 0 --nowait
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 2.5
    kill -KILL $pid
    finish
    hasnot "the console guard is started"
    state_has "console: NOT AS IT WAS"
    state_has "vt1: GRAPHICS mode, keyboard MEDIUMRAW, terminal settings RAW"
    # --fix-console, from another login, is the way out of this
    start "FAKE_CTTY=0" $GAME --fix-console
    finish
    has "It has been put back."
    # the settings from before are gone with the game: it undoes what SDL
    # changes in them, which here gives back what they were
    state_has "console: as it was"
    in_order "vt1 KDSKBMODE K_UNICODE" "vt1 tcsetattr as at the start" "vt1 KDSETMODE KD_TEXT" "VT_UNLOCKSWITCH"
    done_case "without the guard the console is left dead, as expected; --fix-console revives it"

    begin game-SIGKILL-newvt
    start "FAKE_CTTY=0" $GAME --tedlevel 0 --nowait
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 2.5
    kill -KILL $pid
    finish
    in_order "game vt2 KDSETMODE KD_GRAPHICS" "guard vt2 KDSKBMODE K_UNICODE" \
        "guard vt2 KDSETMODE KD_TEXT" "guard VT_UNLOCKSWITCH" \
        "guard VT_ACTIVATE 1: the screen moves from vt2"
    state_has "console: as it was"
    done_case "started from another login and killed: the guard also brings the screen back to vt1"

    begin game-fix-console-nothing-to-do
    start "" $GAME --fix-console
    finish
    has "Nothing to do."
    hasnot "KDSETMODE"
    state_has "console: as it was"
    done_case

    # With no other login, the only place --fix-console can be run from is
    # a timer started on the panel's own shell before the game.  There it is
    # a background job of the terminal it has to change.
    begin game-fix-console-from-a-timer
    start "WOLF3D_NOGUARD=1" $GAME --tedlevel 0 --nowait
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 2.5
    kill -KILL $pid
    finish
    state_has "console: NOT AS IT WAS"
    start "FAKE_BACKGROUND=1" $GAME --fix-console
    finish
    hasnot "STOPPED"
    has "It has been put back."
    state_has "console: as it was"
    exited 0
    done_case "run as a background job of the dead terminal, it is not stopped, and revives it"

    # Killed after the terminal settings were changed and before anything
    # else was: text mode and an ordinary keyboard, but no echo and no Ctrl+C
    begin game-killed-on-the-way-in
    start "FAKE_DIE_AT=KDSKBMODE" $GAME --tedlevel 0 --nowait
    finish
    in_order "vt1 tcsetattr raw" "the program is killed here" "guard vt1 tcsetattr as at the start"
    hasnot "KD_GRAPHICS"
    hasnot "STOPPED"
    state_has "console: as it was"
    exited 4
    done_case "killed with only the terminal settings changed: the guard puts those back"

    # Only where Ctrl+Alt+Fn is let through: the screen is on another
    # terminal when the game is killed, and the one it was started on still
    # has the raw keyboard
    begin game-SIGKILL-switched-away
    start "SDL_FBCON_VTSWITCH=1" $GAME --tedlevel 0 --nowait
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 2.5
    keys +29 +56 +60
    sleep 1
    kill -KILL $pid
    finish
    has "the screen moves from vt1"
    in_order "open /dev/tty1" "guard vt1 KDSKBMODE K_UNICODE" "guard vt1 tcsetattr as at the start"
    state_has "vt1: text mode, keyboard unicode, terminal settings as at the start"
    done_case "killed while the screen was on another terminal: the one it was started on is put right too"
}

t_game_crashes() {
    local how want
    for how in "null 139" "abort 134" "stack 139" "exit 3" "_exit 4"; do
        set -- $how
        begin "game-crash-$1"
        start "" $GAME --tedlevel 0 --nowait
        wait_log "KDSETMODE KD_GRAPHICS" && sleep 2.5
        echo $1 > "$d/crash"
        finish
        has "crash: $1"
        state_has "console: as it was"
        hasnot "came back"
        exited $2
        if [ $1 = _exit ]; then
            has "guard vt1 KDSETMODE KD_TEXT"
            done_case "_exit() runs nothing in the game: the console guard put the console back"
        else
            hasnot "guard vt"
            restored
            done_case
        fi
    done
}

t_game_errors() {
    # A data file that is missing is found out after the screen has been
    # taken over.  The game ends in one way before its pictures are loaded
    # (the maps are opened first) and in another after (the sounds, last).
    local missing f
    for missing in gamemaps audiot; do
        begin "game-error-no-$missing"
        mkdir "$d/data"
        for f in "$DATA"/*; do
            case $(basename "$f" | tr A-Z a-z) in $missing.*) ;; *) ln -s "$f" "$d/data/" ;; esac
        done
        ( cd "$d/data" && exec env HOME="$d/home" FAKE_STATE="$d/state" FAKE_LOG="$d/log" \
            FAKE_FB="$d/fb" FAKE_KBD="$d/kbd" FAKE_QEMU="$QEMUPATH" "$QEMUPATH" $GAME ) >> "$d/log" 2>&1 &
        pid=$!
        finish
        restored
        quiet_in_graphics
        in_order "KDSETMODE KD_GRAPHICS" "KDSETMODE KD_TEXT" "Can't open $missing.wl6!"
        exited 1
        done_case "the error is printed after the terminal is back in text mode"
    done

    begin game-mode-too-big
    start "" $GAME --resf 1024 768
    finish
    has "Unable to set 1024x768x16 video mode: No video mode large enough"
    hasnot "KD_GRAPHICS"
    state_has "console: as it was"
    exited 1
    done_case

    begin game-graphics-mode-refused
    start "FAKE_FAIL=KDSETMODE" $GAME
    finish
    has "Unable to set 800x480x16 video mode: Unable to set keyboard in graphics mode"
    state_has "console: as it was"
    quiet_in_graphics
    exited 1
    done_case
}

t_game_mouse() {
    begin game-mouse
    start "FAKE_MOUSE2=$d/mouse" $GAME --tedlevel 0 --nowait
    wait_log "KDSETMODE KD_GRAPHICS" && sleep 4
    shot before
    mouse x=120 syn; sleep 0.3; mouse x=120 syn; sleep 1
    shot turned
    quit_game
    finish
    has "SDL fbcon: mouse on /dev/input/event2 (Fake Mouse 2)"
    cmp -s "$d/before.raw" "$d/turned.raw" && bad "moving the mouse did not change the picture"
    restored
    exited 0
    done_case "moving the mouse turns the view"
}

t_game_stock() {
    [ -x $OUT/wolf3d-fbtest-stock ] || return

    begin stock-game
    start "SDL_NOMOUSE=1" $OUT/wolf3d-fbtest-stock --tedlevel 0 --nowait --dblbuf
    wait_log "KDSETMODE KD_GRAPHICS" 600 && sleep 4
    shot playing
    quit_game
    finish
    state_has "console: as it was"
    done_case "the game on SDL as released: $(counts)"
}

# ---------------------------------------------------------------- the board's binary

t_binary() {
    [ -f "$BIN" ] || { echo; echo "SKIP  $BIN is not there"; return; }
    local n frames

    begin binary
    d2=$d
    ( cd /tmp && HOME=$d/home timeout 60 "$QEMUPATH" "$BIN" ) >> "$d/log" 2>&1
    has "NO WOLFENSTEIN 3-D DATA FILES to be found!"
    ( cd "$DATA" && HOME=$d/home timeout 60 "$QEMUPATH" "$BIN" --help ) >> "$d/log" 2>&1
    has "--timedemo"
    # no console here at all: SDL has to say so and the game has to stop
    ( cd "$DATA" && HOME=$d/home SDL_VIDEODRIVER=fbcon timeout 60 "$QEMUPATH" "$BIN" ) >> "$d/log" 2>&1
    has "Unable to init SDL"
    for n in "0 691" "1 1899" "2 1140" "3 1656"; do
        set -- $n
        ( cd "$DATA" && HOME=$d/home SDL_VIDEODRIVER=dummy timeout 300 "$QEMUPATH" "$BIN" --timedemo $1 ) >> "$d/log" 2>&1
        has "timedemo $1: $2 frames in "
    done
    has "No sound: No available audio device"
    [ "$(grep -c '^No sound' "$d/log")" = 4 ] || bad "not every run said that there is no sound"
    # and with something for the sound to go to (SDL's dummy device), to
    # see that the sound code still runs where there is a device
    ( cd "$DATA" && HOME=$d/home SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 300 "$QEMUPATH" "$BIN" \
        --timedemo 0 --samplerate 11025 ) >> "$d/log" 2>&1
    [ "$(grep -c '^timedemo 0: 691 frames' "$d/log")" = 2 ] || bad "the demo did not play with a sound device"
    [ "$(grep -c '^No sound' "$d/log")" = 4 ] || bad "the sound device was not used"
    # and the binary's own code for enlarging the picture, into memory, with
    # the screen read back after every frame
    for n in whole fill aspect; do
        ( cd "$DATA" && HOME=$d/home SDL_VIDEODRIVER=dummy WOLF3D_CHECK_PRESENT=1 timeout 300 "$QEMUPATH" "$BIN" \
            --timedemo 0 --bits 16 --screen 800 480 --scale $n ) >> "$d/log" 2>&1
    done
    [ "$(grep -c '^timedemo 0: 691 frames' "$d/log")" = 5 ] || bad "the demo did not play with the picture enlarged"
    has "wolf3d: drawn at 320x200, shown at 640x400 from (80,40)"
    has "wolf3d: drawn at 320x200, shown at 800x480 from (0,0)"
    has "wolf3d: drawn at 320x200, shown at 640x480 from (80,0)"
    hasnot "VP_Check"
    done_case "all four demos play to the end with the real data and no sound device; $(sha256sum "$BIN" | cut -c1-16)..."

    # On a processor without Zba, Zbb or Zbs the plain build has to run, and
    # one built for them has to say which is missing and end, before it has
    # done anything: not stop at the first such instruction it comes to.
    begin binary-processor
    for n in zba zbb zbs; do
        ( cd "$DATA" && HOME=$d/home QEMU_CPU=rv32,$n=false SDL_VIDEODRIVER=dummy timeout 300 "$QEMUPATH" "$BIN" --timedemo 0
          echo "without $n: status $?" ) >> "$d/log" 2>&1
    done
    case "$ARCH" in
    *_zb*)
        has "this build is for a processor with Zba, and this one does not have it"
        has "this build is for a processor with Zbb, and this one does not have it"
        has "this build is for a processor with Zbs, and this one does not have it"
        [ "$(grep -c '^without zb.: status 1$' "$d/log")" = 3 ] || bad "it did not end with status 1 each time"
        hasnot "timedemo 0:"
        done_case "without Zba, Zbb or Zbs this build says which is missing and ends"
        ;;
    *)
        [ "$(grep -c '^timedemo 0: 691 frames' "$d/log")" = 3 ] || bad "the demo did not play"
        [ "$(grep -c '^without zb.: status 0$' "$d/log")" = 3 ] || bad "it did not end with status 0 each time"
        done_case "the demo plays on a processor without Zba, Zbb or Zbs"
        ;;
    esac
}

# ---------------------------------------------------------------- mutants

# Builds a program with one thing broken in a copy of one source file, and
# runs some of the cases above against it.  The real source is not touched.
# The broken copy has to build, and at least one of the cases has to fail:
# a test that cannot fail shows nothing.
#   mutant NAME sdl|game FILE SED-EXPRESSION CASES...
# MUTANT in the environment runs only those whose name has that in it, and
# MUTANT_FROM and MUTANT_TO only those from the one of that number to the
# other, counting from 1: they take a long time all together.
mcount=0
mutant() {
    local mname=$1 kind=$2 file=$3 expr=$4 src obj others p0=$pass f0=$fail t
    shift 4
    mcount=$((mcount + 1))
    case $mname in *"${MUTANT:-}"*) ;; *) return ;; esac
    [ $mcount -ge ${MUTANT_FROM:-1} ] && [ $mcount -le ${MUTANT_TO:-9999} ] || return
    rm -rf mut && mkdir mut
    if [ $kind = sdl ]; then src=$SDL/src/video/fbcon/$file; else src=$WOLF/$file; fi
    sed "$expr" "$src" > "mut/$file"
    if cmp -s "mut/$file" "$src"; then
        fail=$((fail + 1)); echo "FAIL  mutant: $mname: the change did not apply"
        return
    fi
    obj=${file%.*}
    if [ $kind = sdl ]; then
        others=$(ls t_SDL_*.o | grep -v "t_$obj\.o")
        cc_sdl "mut/$file" mut/broken.o \
            && link_probe mut/sdlprobe mut/broken.o $others \
            && link_game mut/wolf3d-fbtest $GAMEOBJS t_wl_fbcon.o mut/broken.o $others
    elif [ $file = wl_fbcon.cpp ]; then
        cxx_game "mut/$file" mut/broken.o fakes \
            && link_game mut/wolf3d-fbtest $GAMEOBJS mut/broken.o t_SDL_*.o
    else
        others=$(echo "$GAMEOBJS" | grep -v "/$obj\.o$")
        cxx_game "mut/$file" mut/broken.o \
            && link_game mut/wolf3d-fbtest $others mut/broken.o t_wl_fbcon.o t_SDL_*.o
    fi > mut/build.log 2>&1
    if [ ! -x mut/wolf3d-fbtest ]; then
        fail=$((fail + 1)); echo "FAIL  mutant: $mname: the broken copy did not build"
        head -20 mut/build.log | sed 's/^/      | /'
        return
    fi
    [ -x mut/sdlprobe ] && PROBE=$OUT/mut/sdlprobe
    GAME=$OUT/mut/wolf3d-fbtest
    for t in "$@"; do
        t_$t
    done > mut/run.log 2>&1
    PROBE=$OUT/sdlprobe
    GAME=$OUT/wolf3d-fbtest
    t=$((fail - f0))
    { echo "## broken: $mname"; grep -E "^(PASS|FAIL)|   FAIL" mut/run.log; } >> mutants.log
    pass=$p0
    fail=$f0
    if [ $t -gt 0 ]; then
        pass=$((pass + 1))
        echo "PASS  mutant: $mname: caught ($(grep -m1 '   FAIL: ' mut/run.log | sed 's/^ *FAIL: //' | cut -c1-90))"
    else
        fail=$((fail + 1))
        echo "FAIL  mutant: $mname: NOT NOTICED"
    fi
}

t_mutants() {
    local E=SDL_fbevents.c V=SDL_fbvideo.c
    echo
    echo "== the cases above must fail when what they check is taken away =="
    : > mutants.log
    mutant "the signals are not caught" sdl $E \
        's/^\t\tFB_CatchSignals(this);$//' probe_signals
    mutant "the signal handler has no stack of its own" sdl $E \
        's/action.sa_flags = SA_ONSTACK;/action.sa_flags = 0;/' game_crashes
    mutant "no atexit() function" sdl $E \
        's/fb_atexit_registered = (atexit(FB_AtExit) == 0);/fb_atexit_registered = 1;/' probe_ends
    mutant "a program started on a console is moved to a new one, as before" sdl $E \
        's/if ( SDL_getenv("SDL_FBCON_NEWVT") == NULL ) {/if ( 0 ) {/' probe_sizes
    mutant "the bytes of a keycode above 127 are read as keys" sdl $E \
        's/^\t\t\tskip = 2;$/\t\t\tskip = 0;/' probe_keys
    mutant "Ctrl+Alt+Fn always switches terminals, as before" sdl $E \
        's/vt_switching = (SDL_getenv("SDL_FBCON_VTSWITCH") != NULL);/vt_switching = 1;/' probe_keys
    mutant "every keymap is asked for, as before" sdl $E \
        's/(entry.kb_value == K_NOSUCHMAP) ) {/0 ) {/' probe_sizes
    mutant "unread keys are left for the shell" sdl $E \
        's/tcsetattr(fd, TCSAFLUSH, &saved_kbd_termios);/tcsetattr(fd, TCSANOW, \&saved_kbd_termios);/' probe_keys
    mutant "a frame buffer with one mode is not recognised" sdl $V \
        's/} else if ( FB_FixedMode(this, &vinfo) ) {/} else if ( 0 ) {/' probe_sizes
    mutant "no mouse is an error, as before" sdl $V \
        's/} else if ( FB_OpenMouse(this) < 0 ) {/} else if ( FB_OpenMouse(this) < 0 ) { FB_VideoQuit(this); return(-1);/' probe_sizes
    mutant "a mode that cannot be set leaves the console in graphics mode" sdl $V \
        '/mode = FB_DoSetVideoMode/,/return(mode)/ s/FB_LeaveGraphicsMode(this);//' probe_failures
    mutant "a surface keeps the pitch of the screen when there is no video memory" sdl $V \
        's/size = surface->h \* SDL_VideoSurface->pitch;/surface->pitch = SDL_VideoSurface->pitch; size = surface->h * surface->pitch;/' probe_sizes
    mutant "only the lines the program asked for are cleared at the end" sdl $V \
        's/lines += 2\*this->offset_y;//' probe_sizes
    mutant "mouse movement is not kept to what SDL can count" sdl SDL_fbevdev.c \
        's/#define FB_MOUSE_MAX\t0x3fff/#define FB_MOUSE_MAX\t0x7fffffff/' probe_mouse
    mutant "the game prints an early error before the console is back in text mode" game wl_main.cpp \
        's/^        FBC_TextMode();$//' game_errors
    mutant "the game prints a later error before the console is back in text mode" game wl_main.cpp \
        's/^    FBC_TextMode();$//' game_errors
    mutant "messages are printed at once, not kept for the end" game wl_fbcon.cpp \
        's/^    if(noteslen >= sizeof(notes) - 1)$/    { va_list v; va_start(v, format); vprintf(format, v); va_end(v); return; }\n&/' game_timedemo
    mutant "the picture is sampled at the left edge of each pixel, not its centre" game id_vp.cpp \
        's/xmap\[i\] = ((2 \* i + 1) \* sw) \/ (2 \* dstw);/xmap[i] = ((2 * i) * sw) \/ (2 * dstw);/' game_scale
    mutant "the picture is sampled at the top edge of each pixel, not its centre" game id_vp.cpp \
        's/ymap\[i\] = ((2 \* i + 1) \* sh) \/ (2 \* dsth);/ymap[i] = ((2 * i) * sh) \/ (2 * dsth);/' game_scale
    mutant "doubled: two of the four stores the wrong way round" game id_vp.cpp \
        's/o\[0\] = a; o\[1\] = b; o\[2\] = c; o\[3\] = d;/o[0] = b; o[1] = a; o[2] = c; o[3] = d;/' game_timedemo
    mutant "two and a half times: the two pixels of the middle store swapped" game id_vp.cpp \
        's/uint32_t bc = PAIR(b, c), cd = PAIR(c, d);/uint32_t bc = PAIR(c, b), cd = PAIR(c, d);/' game_play
    mutant "two and a half times: the third row of a group not written" game id_vp.cpp \
        's/else if(n == 3) Row5_2(row, line, 3, src, shd, words, all);/else if(n == 3) Row5_2(row, line, 2, src, shd, words, all);/' game_play
    mutant "one to one: the two pixels of a store swapped" game id_vp.cpp \
        's/uint32_t ab = PAIR(pal32\[v & 0xff\], pal32\[(v >> 8) & 0xff\]);/uint32_t ab = PAIR(pal32[(v >> 8) \& 0xff], pal32[v \& 0xff]);/' game_play
    mutant "nothing is drawn a second time, changed or not" game id_vp.cpp \
        's/if(!all && v == ((const word_t \*) (const void \*) shd)\[i\])/if(!all)/' game_timedemo
    mutant "the copy of what is on the screen is not kept up" game id_vp.cpp \
        's/((word_t \*) (void \*) shd)\[i\] = v;//' game_timedemo
    mutant "new colours do not make the picture be drawn again" game id_vp.cpp \
        '/^void VP_PaletteChanged/,/^}/ s/paldirty = true;//' game_timedemo
    mutant "the fizzle fade puts each pixel one place to the right" game id_vp.cpp \
        's/^            o\[c\] = v;$/            o[c + 1] = v;/' game_scale
    mutant "the picture is one line too low" game id_vp.cpp \
        's/dsty = (h - dsth) \/ 2;/dsty = (h - dsth) \/ 2 + 1;/' game_play
    mutant "a terminal that was hung up is not opened again" sdl $E \
        's/ && (errno == EIO) ) {/ \&\& 0 ) {/' probe_hangup
    mutant "SIGINT and SIGTERM are left with SDL after it has quit" sdl $V \
        's/^\tSDL_QuitQuit();$//' probe_ends
    mutant "--fix-console can be stopped by the kernel" game wl_fbcon.cpp \
        's/^        signal(SIGTTOU, SIG_IGN);$//' game_killed
    mutant "the guard can be stopped by the kernel" game wl_fbcon.cpp \
        's/SIGUSR1, SIGUSR2, SIGTTOU, SIGTTIN, SIGTSTP };/SIGUSR1, SIGUSR2, SIGTTIN, SIGTSTP };/' game_killed
    mutant "raw terminal settings alone are not seen as damage" game wl_fbcon.cpp \
        's/ && kbmode != K_RAW && !rawterm)/ \&\& kbmode != K_RAW)/' game_killed
    mutant "only the terminal on the screen is looked at" game wl_fbcon.cpp \
        's/^    if(start.vt > 0 && vt != start.vt)$/    if(0)/' game_killed
    mutant "no console guard" game wl_fbcon.cpp \
        's/^    if(getenv("WOLF3D_NOGUARD"))$/    if(1)/' game_killed
    mutant "the guard looks at the console itself, after the game has changed it" game wl_fbcon.cpp \
        's|^        // ... and then nothing, until the game has gone$|        usleep(1500000); RememberConsole();|' game_killed
    rm -rf mut
}

# ---------------------------------------------------------------- main

ALL="probe_sizes probe_stock probe_keys probe_mouse probe_ends probe_terminals probe_failures
     probe_signals probe_hangup game_play game_scale game_menu game_timedemo game_signals
     game_killed game_crashes game_errors game_mouse game_stock binary mutants"

[ "${NOBUILD:-}" = 1 ] || build
for t in ${*:-$ALL}; do
    t_$t
done

echo
echo "== $pass passed, $fail failed =="
[ $fail -eq 0 ]
