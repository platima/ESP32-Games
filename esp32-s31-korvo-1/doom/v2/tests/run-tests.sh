#!/bin/bash
# Rebuilds and runs the fbDOOM v2 tests with the board toolchain, under
# qemu-riscv32-static.  Nothing here touches a board.
#
#   bash run-tests.sh
#
# Settings, all optional, from the environment:
#   M         Buildroot output directory  ($HOME/esp32-s31-linux-main/build/br-output)
#   SRC       the patched fbdoom source directory  ($HOME/doom-scratch/v2/fbDOOM/fbdoom)
#   BIN       the binary to start without a WAD  (../fbdoom-korvo beside this directory)
#   OUT       work directory  ($HOME/doom-scratch/v2/testbuild)
#   PREVIEWS  where the preview PNG files go  ($OUT)
#   QEMU      the emulator  (qemu-riscv32-static)

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
M=${M:-$HOME/esp32-s31-linux-main/build/br-output}
SRC=${SRC:-$HOME/doom-scratch/v2/fbDOOM/fbdoom}
BIN=${BIN:-$HERE/../fbdoom-korvo}
OUT=${OUT:-$HOME/doom-scratch/v2/testbuild}
PREVIEWS=${PREVIEWS:-$OUT}
QEMU=${QEMU:-qemu-riscv32-static}
# nothing here takes long: a test that is still going after this has hung
RUN="timeout 300 $QEMU"

CC=$M/host/bin/riscv32-buildroot-linux-musl-gcc
# the flags the fbDOOM Makefile uses, as built for the board
# (-Wno-unused-const-variable: upstream's rcsid string in i_video_fbdev.c)
CFLAGS="-std=gnu11 -Os -Wall -Wno-unused-const-variable -DNORMALUNIX -DLINUX -DSNDSERV -static"
# what test_console.c stands in for, in the four files it links
FAKES="-Dopen=fake_open -Dclose=fake_close -Dioctl=fake_ioctl -Dmmap=fake_mmap"
FAKES="$FAKES -Dtcgetattr=fake_tcgetattr -Dtcsetattr=fake_tcsetattr -Dtcflush=fake_tcflush"

pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "PASS  $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

mkdir -p "$OUT" "$PREVIEWS" || exit 2
cd "$OUT" || exit 2
rm -rf ./*.log ./*.raw test_scaler test_mouse test_console con_*.o mut

echo "== build =="
$CC $CFLAGS -I "$SRC" -o test_scaler "$HERE/test_scaler.c" "$SRC/tables.c" -lm
$CC $CFLAGS -I "$SRC" -o test_mouse "$HERE/test_mouse.c"
for f in i_video_fbdev i_input_tty i_input_evdev_mouse i_system; do
    $CC $CFLAGS $FAKES -I "$SRC" -c "$SRC/$f.c" -o con_$f.o
done
$CC $CFLAGS -I "$SRC" -o test_console "$HERE/test_console.c" con_*.o "$SRC/tables.c"
for t in test_scaler test_mouse test_console; do
    [ -x $t ] || { echo "FAIL  $t did not build"; exit 1; }
done
echo "built test_scaler, test_mouse, test_console"

# Builds one of the tests against a copy of a source file with one thing
# broken in it, and runs that.  The real source is not touched.  The broken
# copy has to build, and the test has to run to its verdict and fail.
#   mutant TEST FILE NAME SED-EXPRESSION [arguments for the test]
mutant() {
    local t=$1 f=$2 name=$3 expr=$4 status others
    shift 4
    rm -rf mut && mkdir mut
    sed "$expr" "$SRC/$f" > "mut/$f"
    if cmp -s "mut/$f" "$SRC/$f"; then
        bad "$name: the change did not apply"
        return
    fi
    case $t in
    scaler)
        $CC $CFLAGS -I mut -I "$SRC" -o mut/broken "$HERE/test_scaler.c" "$SRC/tables.c" -lm ;;
    mouse)
        $CC $CFLAGS -I mut -I "$SRC" -o mut/broken "$HERE/test_mouse.c" ;;
    console)
        others=$(ls con_*.o | grep -v "con_${f%.c}.o")
        $CC $CFLAGS $FAKES -I "$SRC" -c "mut/$f" -o mut/broken.o \
            && $CC $CFLAGS -I "$SRC" -o mut/broken "$HERE/test_console.c" mut/broken.o $others \
                   "$SRC/tables.c" ;;
    esac > mut/build.log 2>&1
    if [ ! -x mut/broken ]; then
        bad "$name: the broken copy did not build"
        head -20 mut/build.log | sed 's/^/    | /'
        return
    fi
    # in its own directory, so that it does not write over the logs of the real run
    (cd mut && $RUN ./broken "$@") > run.log 2>&1
    status=$?
    if [ $status -eq 1 ] && grep -q "^FAIL" run.log; then
        ok "$name: caught ($(grep -m1 '^  \|^FAIL  ' run.log | sed 's/^ *//; s/^FAIL  //'))"
    else
        bad "$name: not noticed (status $status)"
    fi
    { echo "## broken: $name"; cat run.log; } >> mutants.log
}

echo
echo "== scaler: every byte against the reference, nothing written outside the picture =="
# XRES YRES PAD EXTRA flags
scaler() {
    if $RUN ./test_scaler "$@" > run.log 2>&1; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        grep "^  " run.log
    fi
    grep "^PASS\|^FAIL" run.log || echo "FAIL  $* (no result line)"
    { echo "## test_scaler $*"; cat run.log; } >> scaler.log
}

# the geometries that were asked for
scaler 800 480 0 0
scaler 800 480 0 0 -aspect
scaler 800 480 0 0 -scaling 2
scaler 240 240 0 0
scaler 240 240 0 0 -aspect
scaler 320 200 0 0
scaler 1024 600 0 0
# integer scaling by 1 and by 3, and factors that do not fit
scaler 800 480 0 0 -scaling 1
scaler 1024 600 0 0 -scaling 3
scaler 800 480 0 0 -scaling 3
scaler 800 480 0 0 -scaling 0
scaler 800 480 0 0 -scaling -1
# 800 across has a row loop of its own: with 1, 2, 3 and 5 rows to a source row
scaler 800 200 0 0
scaler 800 300 0 0
scaler 800 600 0 0
scaler 800 1000 0 0
# so has 640 across
scaler 640 200 0 0
scaler 640 400 0 0
scaler 640 600 0 0
scaler 640 1000 0 0
# line padding, a mapping longer than the screen, odd sizes and offsets
scaler 800 480 64 4096
scaler 800 480 2 0
scaler 802 480 0 0 -aspect
scaler 802 600 0 0 -aspect
scaler 801 480 0 0
scaler 801 481 2 6 -aspect
scaler 1280 720 0 0 -aspect
scaler 1600 1200 0 0
# smaller than the source
scaler 160 100 0 0
scaler 100 75 0 0
scaler 64 48 0 0 -aspect
# another 16 bpp layout
scaler 800 480 0 0 -rgb555
# -showfps in each mode, and where the box does not fit
scaler 800 480 0 0 -showfps -fpsval 23
scaler 800 480 0 0 -aspect -showfps -fpsval 7
scaler 800 480 0 0 -scaling 2 -showfps -fpsval 135
scaler 800 480 0 0 -scaling 1 -showfps -fpsval 999
scaler 240 240 0 0 -aspect -showfps -fpsval 35
scaler 320 200 0 0 -showfps -fpsval 1234
scaler 801 480 0 0 -showfps -fpsval 60
scaler 24 12 0 0 -showfps -fpsval 88
scaler 8 6 0 0 -showfps -fpsval 88
scaler 800 480 0 0 -showfps -runms 1300
# the original write() path: no mmap, not 16 bpp, or a mapping that is not
# word aligned
scaler 800 480 0 0 -nommap
scaler 800 480 0 0 -nommap -showfps -fpsval 23
scaler 800 480 0 0 -bpp 32
scaler 800 480 0 0 -bpp 32 -nommap
scaler 800 480 0 0 -misalign 2
scaler 800 480 0 0 -misalign 1 -scaling 2
# the tables cannot be allocated: integer scaling instead
scaler 800 480 0 0 -failmalloc 1
scaler 800 480 0 0 -failmalloc 2
# a screen smaller than 320x200 that the general scaler cannot be used on:
# nothing could be drawn, so it has to stop with an error
scaler 240 240 0 0 -failmalloc 1
scaler 100 75 0 0 -nommap
scaler 160 100 0 0 -bpp 32

echo
echo "== the exit line and the -showfps number, with a clock that the test sets =="
scaler 64 48 0 0 -noframes
scaler 64 48 0 0 -frames 1 -exitline "fbdoom: 1 frame"
scaler 64 48 0 0 -frames 2 -step 0 -exitline "fbdoom: 2 frames"
scaler 64 48 0 0 -frames 3 -step 10000 -exitline "fbdoom: 3 frames in 0.0 s (100.0 fps)"
scaler 64 48 0 0 -frames 2 -step 999000 -exitline "fbdoom: 2 frames in 1.0 s (1.0 fps)"
scaler 64 48 0 0 -frames 36 -step 28571 -showfps -shown "35" \
    -exitline "fbdoom: 36 frames in 1.0 s (35.0 fps)"
scaler 64 48 0 0 -frames 9 -step 250000 -showfps -shown "4 4" \
    -exitline "fbdoom: 9 frames in 2.0 s (4.0 fps)"
scaler 64 48 0 0 -frames 100 -step 45700 -showfps -shown "22 22 22 22" \
    -exitline "fbdoom: 100 frames in 4.5 s (21.9 fps)"
scaler 64 48 0 0 -frames 3121 -step 45700 -exitline "fbdoom: 3121 frames in 142.6 s (21.9 fps)"
# and with the real clock
$RUN ./test_scaler 800 480 0 0 > run.log 2>&1
if grep -qE '^fbdoom: 3 frames in [0-9]+\.[0-9] s \([0-9]+\.[0-9] fps\)$' run.log; then
    ok "3 frames, real clock: $(grep '^fbdoom:' run.log)"
else
    bad "3 frames, real clock: the exit line is missing or malformed"
fi

echo
echo "== the scaler test must fail when the scaler is broken =="
S=i_video_fbdev.c
mutant scaler $S "xmap samples the left edge, not the centre" \
    's/xmap\[i\] = ((2 \* i + 1) \* SCREENWIDTH)/xmap[i] = ((2 * i) * SCREENWIDTH)/' 800 480 0 0
mutant scaler $S "ymap samples the top edge, not the centre" \
    's/ymap\[i\] = ((2 \* i + 1) \* SCREENHEIGHT)/ymap[i] = ((2 * i) * SCREENHEIGHT)/' 800 480 0 0
# the row loop through xmap
mutant scaler $S "xmap loop: the two pixels of a store swapped" \
    's/PAL16_PAIR(pal16\[in\[xm\[0\]\]\], pal16\[in\[xm\[1\]\]\])/PAL16_PAIR(pal16[in[xm[1]]], pal16[in[xm[0]]])/' \
    1024 600 0 0
mutant scaler $S "xmap loop: the second row of a group not written" \
    '/^ROW_LOOP row16_any/,/^}/ s/if (n > 1)/if (n > 3)/' 1024 600 0 0
mutant scaler $S "xmap loop: the third row of a group not written" \
    '/^ROW_LOOP row16_any/,/^}/ s/if (n > 2)/if (n > 3)/' 1024 600 0 0
# the row loop for 640 across
mutant scaler $S "640 loop: the wrong source pixel" \
    's/uint32_t v = pal16\[in\[x\]\];/uint32_t v = pal16[in[x ^ 1]];/' 800 480 0 0 -aspect
mutant scaler $S "640 loop: the second row of a group not written" \
    '/^ROW_LOOP row16_2x/,/^}/ s/if (n > 1)/if (n > 3)/' 800 480 0 0 -aspect
mutant scaler $S "640 loop: the third row of a group not written" \
    '/^ROW_LOOP row16_2x/,/^}/ s/if (n > 2)/if (n > 3)/' 800 480 0 0 -aspect
# the row loop for 800 across
mutant scaler $S "800 loop: two of the five stores the wrong way round" \
    's/(o)\[2\] = bc, (o)\[3\] = cd/(o)[2] = cd, (o)[3] = bc/' 800 480 0 0
mutant scaler $S "800 loop: the two pixels of the middle store swapped" \
    's/bc = PAL16_PAIR(b, c)/bc = PAL16_PAIR(c, b)/' 800 480 0 0
mutant scaler $S "800 loop: the second row of a group not written" \
    '/^ROW_LOOP row16_5_2/,/^}/ s/if (n > 1)/if (n > 3)/' 800 480 0 0
mutant scaler $S "800 loop: the third row of a group not written" \
    '/^ROW_LOOP row16_5_2/,/^}/ s/if (n > 2)/if (n > 3)/' 800 480 0 0
# the choice between them
mutant scaler $S "the 800 loop used for a width it does not suit" \
    's/return is_2x ? XPAT_2X : is_5_2 ? XPAT_5_2 : XPAT_ANY;/return XPAT_5_2;/' 1024 600 0 0
mutant scaler $S "the 640 loop used for a width it does not suit" \
    's/return is_2x ? XPAT_2X : is_5_2 ? XPAT_5_2 : XPAT_ANY;/return XPAT_2X;/' 800 480 0 0
mutant scaler $S "a group of two rows drawn as one" \
    's/rows16(row, line, in, w, 2);/rows16(row, line, in, w, 1);/' 800 480 0 0
mutant scaler $S "a group of three rows drawn as two" \
    's/rows16(row, line, in, w, 3);/rows16(row, line, in, w, 2);/' 800 480 0 0 -aspect
# rows that are copied, and the loop for what is not word aligned
mutant scaler $S "the fourth row of a group not copied" \
    's/k = n < 3 ? n : 3;/k = n < 3 ? n : 4;/' 1280 720 0 0 -aspect
mutant scaler $S "a copied row one pixel short" \
    's/memcpy(row + k \* line, row, w \* 2)/memcpy(row + k * line, row, w * 2 - 2)/' 801 480 0 0
mutant scaler $S "a copied row one pixel too long" \
    's/memcpy(row + k \* line, row, w \* 2)/memcpy(row + k * line, row, w * 2 + 2)/' \
    1280 720 0 0 -aspect
mutant scaler $S "the 16-bit loop writes one pixel too many" \
    's/for (x = 0; x < w; x++)/for (x = 0; x <= w; x++)/' 802 480 0 0 -aspect
mutant scaler $S "a mapping that is not word aligned is drawn in" \
    's/ && ((uintptr_t)fb_mem & 3) == 0 && (fix.line_length & 1) == 0/ \&\& (fix.line_length \& 1) == 0/' \
    800 480 0 0 -misalign 2
mutant scaler $S "a screen that nothing can be drawn on is left black" \
    's/        if (fb_scaling < 1)/        if (0)/' 240 240 0 0 -failmalloc 1
# the -showfps box
mutant scaler $S "the fps box one pixel too far right" \
    's/(dst_x + dst_w - cols \* s) \* 2/(dst_x + dst_w - cols * s + 1) * 2/' \
    800 480 0 0 -showfps -fpsval 23
mutant scaler $S "the fps box one row too tall" \
    's/for (cy = 0; cy < 7; cy++)/for (cy = 0; cy < 8; cy++)/' \
    800 480 0 0 -scaling 2 -showfps -fpsval 135
mutant scaler $S "a wrong bit in the digit 3" \
    's/0x73cf, 0x5bc9/0x73c7, 0x5bc9/' 800 480 0 0 -showfps -fpsval 23
# the frame rate
mutant scaler $S "the exit line counts the first frame as well as the time before it" \
    's/((uint64_t)(fps_frames - 1) \* 10000/((uint64_t)fps_frames * 10000/' \
    64 48 0 0 -frames 36 -step 28571 -exitline "fbdoom: 36 frames in 1.0 s (35.0 fps)"
mutant scaler $S "so does the first number on the screen" \
    's/        fps_mark_frames = 1;/        fps_mark_frames = 0;/' \
    64 48 0 0 -frames 9 -step 250000 -showfps -shown "4 4"
mutant scaler $S "a single frame gets a frame rate" \
    's/if (fps_frames == 1 || ms == 0) {/if (0) {/' 64 48 0 0 -frames 1 -exitline "fbdoom: 1 frame"
# the mouse around the blit
mutant scaler $S "the mouse is not read before the blit" \
    '/do not fill up meanwhile/,/if (blit_mode != BLIT_WRITE)/ s/    I_PollMouse();//' 800 480 0 0
mutant scaler $S "the mouse is not read after the blit" \
    '/^        fps_frame();$/,/^        return;$/ s/        I_PollMouse();//' 800 480 0 0
mutant scaler $S "the mouse is not read after the blit, write() path" \
    '/draw only portion used by doom/,/^}/ s/    I_PollMouse();//' 800 480 0 0 -nommap

echo
echo "== mouse: synthetic events through pipes =="
if $RUN ./test_mouse > mouse.log 2>&1; then
    ok "test_mouse: $(grep -c '^ok' mouse.log) checks"
else
    bad "test_mouse (status $?)"
fi
grep "^FAIL\|^   \|^sizeof" mouse.log
S=i_input_evdev_mouse.c
mutant mouse $S "movement is not held to a limit" \
    's/#define MOUSE_MAX 0x7fff$/#define MOUSE_MAX 0x7fffffff/'
mutant mouse $S "movement is posted twice" \
    's/    mouse_dx = mouse_dy = 0;//'
mutant mouse $S "every read is followed by another" \
    's/        if (n < room)/        if (0)/'
mutant mouse $S "movement to the left or forwards is not accelerated" \
    's/    if (val < -10)/    if (0)/'

echo
echo "== console: start-up, keys and every way out, against a fake VT =="
SCENARIOS="timedemo-quit timedemo-end play-quit play-quit-right play-quit-mixed play-quit-media
    keys noframes error-early error-unread exit kbmode-fails tcgetattr-fails
    null-store abort stack-overflow
    segv sigbus sigill sigfpe sigabrt sigterm sighup sigint sigquit sigpipe sigalrm sigusr1 sigusr2"
for s in $SCENARIOS; do
    if $RUN ./test_console $s > run.log 2>&1; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        grep "^FAIL " run.log
    fi
    tail -1 run.log
    cat run.log >> console.log
done

echo
echo "== the console test must fail when a way out is left unguarded =="
S=i_input_tty.c
mutant console $S "no atexit() handler" \
    's/^    atexit(kbd_restore);$//' exit
mutant console $S "kbd_shutdown does not put the VT back" \
    '/^void kbd_shutdown/,/^}/ s/^    kbd_restore();$//' kbmode-fails
mutant console $S "the terminal settings are written back without having been read" \
    's/^    if (tcgetattr(kb, &old_term) != 0) {$/    ioctl(kb, KDGKBMODE, \&old_mode);\n&/' \
    tcgetattr-fails
mutant console $S "unread key bytes are left for the shell" \
    's/^        tcflush(kb, TCIFLUSH);$//' error-unread
mutant console $S "the handler has no stack of its own" \
    's/sa.sa_flags = SA_ONSTACK;/sa.sa_flags = 0;/' stack-overflow
mutant console $S "the bytes of a keycode above 127 are read as keys" \
    's/            skip = 2;/            skip = 0;/' play-quit-media
mutant console $S "Backspace alone quits, as in v1" \
    's/         && (ctrlaltdown & 3) != 0 && (ctrlaltdown & 12) != 0) {/) {/' keys
for s in segv sigbus sigill sigfpe sigabrt sigterm sighup sigint sigquit sigpipe sigalrm \
         sigusr1 sigusr2; do
    name=$(echo $s | tr a-z A-Z | sed 's/^SEGV/SIGSEGV/')
    mutant console $S "$name is not caught" \
        "/^static const int kbd_fatal_signals/,/^};/ s/$name,\{0,1\} \{0,1\}//" $s
done
S=i_system.c
mutant console $S "I_Quit runs the exit functions before the VT is back in text mode" \
    '/^void I_Quit/,/^}/ s/^    kbd_restore();$//' play-quit
mutant console $S "I_Error prints before the VT is back in text mode" \
    '/^void I_Error/,/^}/ s/^    kbd_restore();$//' timedemo-end

echo
echo "== preview images, through the same scaler =="
preview() {
    local name=$1
    shift
    if $RUN ./test_scaler 800 480 0 0 -card -frames 1 -out "$name.raw" "$@" > run.log 2>&1 \
       && python3 "$HERE/raw2png.py" 800 480 "$name.raw" "$PREVIEWS/$name.png"; then
        ok "$name.png ($(sed -n 's/^I_InitGraphics: \(320x200 -> .*\)/\1/p' run.log))"
    else
        bad "$name.png"
        cat run.log
    fi
}
preview preview-fill -showfps -fpsval 23
preview preview-aspect -aspect
preview preview-scaling2 -scaling 2

echo
echo "== the binary itself, with no WAD =="
if [ -f "$BIN" ]; then
    rm -rf empty && mkdir empty
    run_bin() {
        local what=$1 status
        shift
        (cd empty && timeout 60 $QEMU "$BIN" "$@" > "../binary-$what.log" 2>&1)
        status=$?
        if [ $status -eq 255 ]; then
            ok "$what: exits with status 255"
        elif [ $status -eq 124 ]; then
            bad "$what: still running after 60 s"
        else
            bad "$what: status $status"
        fi
        sed 's/^/    | /' "binary-$what.log"
    }
    run_bin no-arguments
    run_bin missing-iwad -iwad /nonexistent/doom1.wad
    sha256sum "$BIN" | sed 's/^/    /'
else
    echo "SKIP  $BIN is not there"
fi

rm -rf mut

echo
echo "== $pass passed, $fail failed =="
[ $fail -eq 0 ]
