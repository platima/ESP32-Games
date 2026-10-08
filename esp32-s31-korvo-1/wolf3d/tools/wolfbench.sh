#!/bin/sh
# wolfbench.sh: plays the timed demo in every picture mode, one after the
# other, and collects the frame rates in a table.
#
# For the ESP32-S31-Korvo-1.  Run it at the panel, in the folder with the WL6
# files:
#
#   cd /mnt/sd/wolf3d
#   sh wolfbench.sh [GAME] [MODE...]
#
# GAME is the binary to time, /root/wolf3d2 if none is given; a word with a
# "/" in it is taken for one.  MODE is one or more names from the list below;
# with none, every mode is run, which takes ten minutes or so.  Each line of
# the table is printed as its run ends, and the whole table is added to
# wolfbench.txt in the folder this was started in.
#
# Leave the keyboard alone while it runs: a key ends a demo early.  A run
# that takes too long is ended with "killall", which the game answers by
# putting the console back; nothing here uses "kill -9".
#
# From the environment:
#   DEMO    which demo, 0 to 3  (0)
#   LIMIT   seconds one run may take before it is ended  (600)
#   OUT     the file the table is added to  (wolfbench.txt)
#   EXTRA   more options, for every run
#
# Plain sh: the board's /bin/sh is bash, and BusyBox ash and dash run it too.
# Offered under the MIT licence.

# name|options.  The quick ones and the ones of most interest come first, so
# that a run cut short still has them.
MODES='default|
fill|--scale fill
r400|--resf 400 240
aspect|--scale aspect
noscreen|
off320|--scale off
res640|--res 640 400
off640|--scale off --res 640 400
resf800|--resf 800 480
off800|--scale off --resf 800 480'

# What a mode is, for the table's last column where the game does not say
about() {
    case $1 in
    default)  echo "320x200 doubled, centred" ;;
    fill)     echo "320x200 over the whole panel" ;;
    r400)     echo "400x240 doubled: whole panel" ;;
    aspect)   echo "320x200 as 640x480" ;;
    noscreen) echo "no screen: the game alone" ;;
    off320)   echo "320x200 by SDL, not enlarged" ;;
    res640)   echo "drawn at 640x400" ;;
    off640)   echo "by SDL: the first version" ;;
    resf800)  echo "drawn at 800x480" ;;
    off800)   echo "by SDL: the first version" ;;
    esac
}

GAME=/root/wolf3d2
ASKED=
for arg in "$@"; do
    case $arg in
    -h|--help)
        sed -n '2,/^$/ s/^# \{0,1\}//p' "$0"
        echo "Modes:"
        echo "$MODES" | while IFS='|' read -r name opts; do
            printf '  %-9s %-27s %s\n' "$name" "${opts:-(no options)}" "$(about "$name")"
        done
        exit 0 ;;
    */*)  GAME=$arg ;;
    *)    ASKED="$ASKED $arg" ;;
    esac
done

DEMO=${DEMO:-0}
LIMIT=${LIMIT:-600}
OUT=${OUT:-wolfbench.txt}
EXTRA=${EXTRA:-}

case $DEMO in
0) expected=691 ;;
1) expected=1899 ;;
2) expected=1140 ;;
3) expected=1656 ;;
*) echo "wolfbench: DEMO is 0 to 3"; exit 2 ;;
esac

for name in $ASKED; do
    case "
$MODES" in
    *"
$name|"*) ;;
    *)  echo "wolfbench: no mode called $name. They are:"
        echo "$MODES" | sed 's/|.*//' | tr '\n' ' '
        echo
        exit 2 ;;
    esac
done

if [ ! -x "$GAME" ]; then
    echo "wolfbench: $GAME is not there, or cannot be run."
    echo "Give the binary as the first word, such as: sh $0 /root/wolf3d2zb"
    exit 2
fi
if [ ! -f vswap.wl6 ] && [ ! -f VSWAP.WL6 ]; then
    echo "wolfbench: no VSWAP.WL6 here. Start this in the folder with the game's data."
    exit 2
fi

gamename=${GAME##*/}
tmp=${TMPDIR:-/tmp}
[ -d "$tmp" ] && [ -w "$tmp" ] || tmp=.
log=$tmp/wolfbench.$$.log
rows=$tmp/wolfbench.$$.rows
fired=$tmp/wolfbench.$$.fired
wd=

# from here on no word is taken for a pattern of file names
set -f

cleanup() {
    [ -n "$wd" ] && kill "$wd" 2>/dev/null
    rm -f "$log" "$rows" "$fired"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# The timer.  It sleeps beside the game and costs it nothing.  If it wakes
# while the game is still there, it ends the game by name.
have_killall=yes
command -v killall >/dev/null 2>&1 || have_killall=
watch_start() {
    rm -f "$fired"
    [ -n "$have_killall" ] || return 0
    (
        trap - EXIT
        sp=
        trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM INT HUP
        sleep "$LIMIT" &
        sp=$!
        wait "$sp"
        : > "$fired"
        killall "$gamename" 2>/dev/null
    ) 3<&- &
    wd=$!
}
watch_stop() {
    [ -n "$wd" ] || return 0
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    wd=
}

wanted() {
    [ -z "$ASKED" ] && return 0
    case " $ASKED " in
    *" $1 "*) return 0 ;;
    esac
    return 1
}

header() {
    echo "wolfbench: $(date 2>/dev/null)"
    size=$(wc -c < "$GAME" 2>/dev/null | tr -d ' ')
    sum=
    command -v sha256sum >/dev/null 2>&1 && sum=$(sha256sum "$GAME" 2>/dev/null | cut -c1-16)
    echo "game:    $GAME, $size bytes${sum:+, sha256 $sum...}"
    echo "demo:    $DEMO ($expected frames)${EXTRA:+, with $EXTRA}"
    echo "kernel:  $(uname -r 2>/dev/null)"
    isa=$(sed -n 's/^isa[^:]*: *//p' /proc/cpuinfo 2>/dev/null | head -n 1)
    [ -n "$isa" ] && echo "isa:     $isa"
    echo "console: $console"
}

# "demo s" and "fps" are the game's own "timedemo" line, which includes the
# fade at the start of the demo; "view" is its line for the 3D view alone;
# "run s" is the whole run by the clock, loading included.
fmt='%-8s %-26s %6s %6s %6s %6s %5s  %s\n'
heading() {
    # shellcheck disable=SC2059
    printf "$fmt" mode options frames "demo s" fps view "run s" what
}

# one run: NAME OPTIONS
run_one() {
    name=$1
    opts=$2
    : > "$log"
    watch_start
    t0=$(date +%s)
    # $opts and $EXTRA are lists of words on purpose.  The braces are for the
    # shell's own "Terminated" when a run is ended: the table says that.
    {
        if [ "$name" = noscreen ]; then
            SDL_VIDEODRIVER=dummy "$GAME" --timedemo "$DEMO" $opts $EXTRA > "$log" 2>&1 3<&-
        else
            "$GAME" --timedemo "$DEMO" $opts $EXTRA > "$log" 2>&1 3<&-
        fi
        status=$?
    } 2>/dev/null
    t1=$(date +%s)
    watch_stop

    line=$(grep '^timedemo ' "$log" | tail -n 1)
    frames=$(echo "$line" | sed -n 's/^timedemo [0-9]*: \([0-9]*\) frames in .*/\1/p')
    secs=$(echo "$line" | sed -n 's/.* frames in \([0-9.]*\) s (.*/\1/p')
    fps=$(echo "$line" | sed -n 's/.* s (\([0-9.]*\) fps).*/\1/p')
    view=$(sed -n 's/^wolf3d: [0-9]* frames of the 3D view, [0-9.]* s of drawing (\([0-9.]*\) fps)$/\1/p' "$log" | tail -n 1)
    shown=$(sed -n 's/^wolf3d: drawn at \([0-9x]*\), shown at \([0-9x]*\) from .*/\1 shown as \2/p' "$log" | tail -n 1)

    what=${shown:-$(about "$name")}
    if [ -f "$fired" ]; then
        what="ENDED BY THE TIMER after $LIMIT s"
    elif [ -z "$line" ]; then
        what="NO RESULT, exit status $status: $(grep -v '^SDL fbcon:' "$log" | grep . | tail -n 1 | cut -c1-70)"
    else
        case $line in
        *"stopped early"*) what="STOPPED EARLY by a key; $what" ;;
        *)  [ "$frames" = "$expected" ] || what="$frames FRAMES, NOT $expected; $what" ;;
        esac
        [ "$status" = 0 ] || what="exit status $status; $what"
    fi

    # After anything but a clean end, see that the console is as it should
    # be.  The game does this itself; this is the second look.
    if [ "$status" != 0 ] && [ "$name" != noscreen ]; then
        sleep 1
        case $("$GAME" --fix-console 2>&1 | tail -n 1) in
        *"put back"*) what="$what (the console had to be put back)" ;;
        esac
    fi

    # shellcheck disable=SC2059
    printf "$fmt" "$name" "${opts:-(none)}" "${frames:--}" "${secs:--}" "${fps:--}" "${view:--}" \
        "$((t1 - t0))" "$what" >> "$rows"
    tail -n 1 "$rows"
}

# Does the game start, and is this the panel's console?  --fix-console says
# one of three things, and changes nothing when all is well.
console=$("$GAME" --fix-console 2>&1 | tail -n 1)
case $console in
"The console "*|"The screen is not showing"*) ;;
*)  echo "wolfbench: $GAME does not start here. It says:"
    "$GAME" --fix-console
    exit 2 ;;
esac

: > "$rows"
header
[ -n "$have_killall" ] || echo "No killall here: a run that hangs will not be ended."
echo "Leave the keyboard alone: a key ends a demo early."
echo
heading

while IFS='|' read -r name opts <&3; do
    wanted "$name" || continue
    run_one "$name" "$opts"
done 3<<EOF
$MODES
EOF

set +f
if {
    echo
    header
    echo
    heading
    cat "$rows"
} 2>/dev/null >> "$OUT"; then
    sync
    echo
    echo "Added to $OUT."
else
    echo
    echo "Could not write $OUT: the lines above are all there is."
fi
