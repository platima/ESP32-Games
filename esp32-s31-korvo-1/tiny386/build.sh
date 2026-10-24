#!/bin/bash
# Builds tiny386 for the ESP32-S31-Korvo-1 from the sources as their authors
# released them and two patches: patches/tiny386-korvo.patch here, and the
# SDL patch of the Wolfenstein 3D port beside this directory.
#
#   bash build.sh [WORKDIR]
#   VARIANT=ua bash build.sh [WORKDIR]
#
# WORKDIR (default $HOME/tiny386-scratch/build) is made if it is not there,
# and everything is fetched, unpacked and built inside it.  Nothing outside
# it is written.  The result is WORKDIR/tiny386-korvo.  BUILD.txt says more.
#
# Settings, from the environment:
#   VARIANT    empty for the build that never makes a load or a store at an
#              address that is not aligned; "ua" for the one that leaves
#              those to the processor, as tiny386 does everywhere else.  That
#              one is WORKDIR/tiny386-korvo-ua, and its WORKDIR is
#              $HOME/tiny386-scratch/build-ua unless given.
#   M          the Buildroot output directory of the board's build; only its
#              compiler is used.  The first of these that has one:
#              $HOME/esp32-s31-linux-main/build/br-output
#              $HOME/tiny386-scratch/toolchain/br-output   (see toolchain.sh)
#   GNUCONFIG  a directory with a current config.sub and config.guess
#              (support/gnuconfig of a Buildroot tree; looked for beside M)
#   SDL_PATCH  the SDL patch  (../wolf3d/patches/SDL-1.2.15-korvo-fbcon.patch)
#   OPT        the optimisation level for tiny386's sources  (-O3, which is
#              what tiny386 builds itself with; BUILD.txt has the counts
#              that say why not -O2)
#   JOBS       how many compilers to run at once  (8)

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
case "${VARIANT:-}" in
"")  ALIGN="-DI386_ALIGNED_ONLY"
     NAME=tiny386-korvo
     WORK=${1:-$HOME/tiny386-scratch/build} ;;
ua)  ALIGN=""
     NAME=tiny386-korvo-ua
     WORK=${1:-$HOME/tiny386-scratch/build-ua} ;;
*)   echo "VARIANT is empty or ua"; exit 1 ;;
esac
OPT=${OPT:--O3}
JOBS=${JOBS:-8}
SDL_PATCH=${SDL_PATCH:-$HERE/../wolf3d/patches/SDL-1.2.15-korvo-fbcon.patch}

HOST=riscv32-buildroot-linux-musl
if [ -z "${M:-}" ]; then
    for M in "$HOME/esp32-s31-linux-main/build/br-output" \
             "$HOME/tiny386-scratch/toolchain/br-output"; do
        [ -x "$M/host/bin/$HOST-gcc" ] && break
    done
fi
T=$M/host/bin/$HOST
[ -x $T-gcc ] || { echo "no compiler at $T-gcc: set M, or run toolchain.sh first"; exit 1; }
if [ -z "${GNUCONFIG:-}" ]; then
    for GNUCONFIG in "$HOME/esp32-s31-linux-main/external/buildroot/support/gnuconfig" \
                     "$HOME/tiny386-scratch/toolchain/src/external/buildroot/support/gnuconfig"; do
        [ -f "$GNUCONFIG/config.sub" ] && break
    done
fi
[ -f "$GNUCONFIG/config.sub" ] || { echo "no config.sub in $GNUCONFIG: set GNUCONFIG"; exit 1; }
[ -f "$SDL_PATCH" ] || { echo "no SDL patch at $SDL_PATCH: set SDL_PATCH"; exit 1; }
[ -f "$HERE/patches/tiny386-korvo.patch" ] || { echo "patches/tiny386-korvo.patch is not beside this script"; exit 1; }

SDL_VERSION=1.2.15
SDL_URL=https://www.libsdl.org/release/SDL-$SDL_VERSION.tar.gz
SDL_SHA256=d6d316a793e5e348155f0dd93b979798933fb98aa1edebcc108829d6474aad00
TINY_GIT=https://github.com/hchunhui/tiny386
TINY_COMMIT=9ed786b4dd9698306dccdb7595858dee10949994

mkdir -p "$WORK/dl"
cd "$WORK"

fetch() {   # URL SHA256
    local file=dl/${1##*/}
    [ -f "$file" ] || curl -fsSL -o "$file" "$1"
    echo "$2  $file" | sha256sum -c -
}

echo "== sources =="
fetch $SDL_URL $SDL_SHA256
rm -rf SDL-$SDL_VERSION tiny386 prefix
tar xzf dl/SDL-$SDL_VERSION.tar.gz
git clone -q $TINY_GIT tiny386
git -C tiny386 checkout -q $TINY_COMMIT

echo "== SDL $SDL_VERSION =="
cd "$WORK/SDL-$SDL_VERSION"
patch -p1 < "$SDL_PATCH"
# the copies in the tarball are from 2012 and do not know riscv32
cp "$GNUCONFIG/config.sub" "$GNUCONFIG/config.guess" build-scripts/
# the configuration the Wolfenstein 3D port builds it with, so that this is
# the library that has run on the board
CC=$T-gcc AR=$T-ar RANLIB=$T-ranlib CFLAGS="-O2 -std=gnu99" \
./configure --host=$HOST --build=x86_64-pc-linux-gnu --prefix="$WORK/prefix" \
    --disable-shared --enable-static \
    --enable-video-fbcon --enable-video-dummy \
    --disable-video-x11 --disable-video-directfb --disable-video-qtopia --disable-video-photon \
    --disable-video-ps2gs --disable-video-ps3 --disable-video-svga --disable-video-vgl \
    --disable-video-wscons --disable-video-aalib --disable-video-caca --disable-video-opengl \
    --disable-dga --disable-video-dga --disable-video-x11-vm --disable-video-x11-xv \
    --disable-osmesa-shared --disable-video-nanox --disable-video-picogui \
    --disable-cdrom --disable-loadso --disable-rpath --disable-nasm --disable-assembly \
    --disable-alsa --disable-esd --disable-pulseaudio --disable-arts --disable-nas \
    --disable-diskaudio --disable-mintaudio --disable-pth --disable-input-tslib \
    --enable-clock_gettime \
    > "$WORK/SDL-configure.log" 2>&1
make -j$JOBS > "$WORK/SDL-make.log" 2>&1
make install > "$WORK/SDL-install.log" 2>&1

echo "== tiny386 $TINY_COMMIT =="
cd "$WORK/tiny386"
git apply --check "$HERE/patches/tiny386-korvo.patch"
git apply "$HERE/patches/tiny386-korvo.patch"

# What the board's build is made of.  No fmopl.c (the board has no sound, and
# its tables are 140 KB), no slirp, no tun/tap, no on-screen display.
SRCS="korvo/main.c korvo/guard.c korvo/hostbench.c
      i386.c fpu.c ini.c i8259.c i8254.c ide.c vga.c vgafont.c i8042.c misc.c
      adlib.c ne2000.c i8257.c sb16.c pcspk.c pc.c pci.c term.c"
# BPP=16              the VGA draws RGB565, which is what the panel is
# VGA_STORE_CHANGED   and stores a pixel only where the screen differs
# PC_STEP_COUNT       guest instructions between two looks at the clock,
#                     the keyboard and the screen
# PC_DEBUGCON         the BIOS's debug messages go where the emulator's do
DEFS="-DBPP=16 -DVGA_STORE_CHANGED -DPC_STEP_COUNT=4096 -DPC_DEBUGCON=stderr
      -DI386_ENABLE_FPU $ALIGN"
CFLAGS="$OPT -std=gnu11 -Wall -ffunction-sections -fdata-sections -I. $DEFS
        $("$WORK/prefix/bin/sdl-config" --cflags)"
CFLAGS=$(echo $CFLAGS)      # on one line

# Sources are named as they are in the tree, so that the file names that
# assert() keeps do not depend on where the tree is.  One compiler command
# to a line, and xargs runs JOBS of them at a time.
rm -rf obj && mkdir -p obj/korvo
objs=
for src in $SRCS; do
    obj=obj/${src%.c}.o
    objs="$objs $obj"
    echo "$T-gcc $CFLAGS -c $src -o $obj"
done > "$WORK/tiny386-commands.txt"
xargs -P "$JOBS" -d '\n' -n 1 sh -c < "$WORK/tiny386-commands.txt" > "$WORK/tiny386-make.log" 2>&1
$T-gcc -static -Wl,--gc-sections -o tiny386 $objs \
    -L"$WORK/prefix/lib" -lSDL -lpthread -lm >> "$WORK/tiny386-make.log" 2>&1
$T-strip -o "$WORK/$NAME" tiny386

echo "== done =="
cd "$WORK"
ls -l $NAME
sha256sum $NAME
