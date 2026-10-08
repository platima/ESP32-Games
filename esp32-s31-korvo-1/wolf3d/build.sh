#!/bin/bash
# Builds Wolfenstein 3D (Wolf4SDL) for the ESP32-S31-Korvo-1 from the sources
# as their authors released them and the two patches in patches/.
#
#   bash build.sh [WORKDIR]
#   VARIANT=zb bash build.sh [WORKDIR]
#
# WORKDIR (default $HOME/wolf-scratch/build) is made if it is not there, and
# everything is fetched, unpacked and built inside it.  Nothing outside it is
# written.  The result is WORKDIR/wolf3d-korvo.  BUILD.txt says more.
#
# Settings, from the environment:
#   VARIANT    empty for the plain build, which runs on any RV32IMAC; "zb" to
#              let the compiler use the Zba, Zbb and Zbs instructions as well.
#              That one is WORKDIR/wolf3d-korvo-zb, and its WORKDIR is
#              $HOME/wolf-scratch/build-zb unless given.  The C library and
#              the compiler's own routines are the toolchain's either way.
#   M          the Buildroot output directory of the board's build; only its
#              compiler is used  ($HOME/esp32-s31-linux-main/build/br-output)
#   GNUCONFIG  a directory with a current config.sub and config.guess
#              (the one in the board's Buildroot tree)
#   JOBS       how many compilers to run at once  (8)

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
case "${VARIANT:-}" in
"")  ARCH=""
     NAME=wolf3d-korvo
     WORK=${1:-$HOME/wolf-scratch/build} ;;
zb)  ARCH="-march=rv32imac_zicsr_zifencei_zba_zbb_zbs -mabi=ilp32"
     NAME=wolf3d-korvo-zb
     WORK=${1:-$HOME/wolf-scratch/build-zb} ;;
*)   echo "VARIANT is empty or zb"; exit 1 ;;
esac
M=${M:-$HOME/esp32-s31-linux-main/build/br-output}
GNUCONFIG=${GNUCONFIG:-$HOME/esp32-s31-linux-main/external/buildroot/support/gnuconfig}
JOBS=${JOBS:-8}

HOST=riscv32-buildroot-linux-musl
T=$M/host/bin/$HOST

SDL_VERSION=1.2.15
SDL_URL=https://www.libsdl.org/release/SDL-$SDL_VERSION.tar.gz
SDL_SHA256=d6d316a793e5e348155f0dd93b979798933fb98aa1edebcc108829d6474aad00
MIXER_VERSION=1.2.12
MIXER_URL=https://www.libsdl.org/projects/SDL_mixer/release/SDL_mixer-$MIXER_VERSION.tar.gz
MIXER_SHA256=1644308279a975799049e4826af2cfc787cad2abb11aa14562e402521f86992a
WOLF_GIT=https://github.com/ioan-chera/Wolf4SDL
WOLF_COMMIT=51b3694e58bad8c9be9cddba720f86a4749d469c

[ -x $T-gcc ] || { echo "no compiler at $T-gcc: set M"; exit 1; }
[ -f "$GNUCONFIG/config.sub" ] || { echo "no config.sub in $GNUCONFIG: set GNUCONFIG"; exit 1; }

mkdir -p "$WORK/dl"
cd "$WORK"

fetch() {   # URL SHA256
    local file=dl/${1##*/}
    [ -f "$file" ] || curl -fsSL -o "$file" "$1"
    echo "$2  $file" | sha256sum -c -
}

echo "== sources =="
fetch $SDL_URL $SDL_SHA256
fetch $MIXER_URL $MIXER_SHA256
rm -rf SDL-$SDL_VERSION SDL-$SDL_VERSION-stock SDL_mixer-$MIXER_VERSION Wolf4SDL prefix
tar xzf dl/SDL-$SDL_VERSION.tar.gz
# a second copy that stays as released: the tests compare the two
cp -a SDL-$SDL_VERSION SDL-$SDL_VERSION-stock
tar xzf dl/SDL_mixer-$MIXER_VERSION.tar.gz
git clone -q $WOLF_GIT Wolf4SDL
git -C Wolf4SDL checkout -q $WOLF_COMMIT

echo "== SDL $SDL_VERSION =="
cd "$WORK/SDL-$SDL_VERSION"
patch -p1 < "$HERE/patches/SDL-$SDL_VERSION-korvo-fbcon.patch"
# the copies in the tarball are from 2012 and do not know riscv32
cp "$GNUCONFIG/config.sub" "$GNUCONFIG/config.guess" build-scripts/
CC=$T-gcc AR=$T-ar RANLIB=$T-ranlib CFLAGS="-O2 -std=gnu99${ARCH:+ $ARCH}" \
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

echo "== SDL_mixer $MIXER_VERSION =="
cd "$WORK/SDL_mixer-$MIXER_VERSION"
cp "$GNUCONFIG/config.sub" "$GNUCONFIG/config.guess" build-scripts/
CC=$T-gcc AR=$T-ar RANLIB=$T-ranlib CFLAGS="-O2 -std=gnu99${ARCH:+ $ARCH}" \
SDL_CFLAGS="$("$WORK/prefix/bin/sdl-config" --cflags)" \
SDL_LIBS="$("$WORK/prefix/bin/sdl-config" --static-libs)" \
./configure --host=$HOST --build=x86_64-pc-linux-gnu --prefix="$WORK/prefix" \
    --disable-shared --enable-static --disable-sdltest --with-sdl-prefix="$WORK/prefix" \
    --disable-music-cmd --disable-music-wave --disable-music-mod --disable-music-mod-modplug \
    --disable-music-midi --disable-music-timidity-midi --disable-music-native-midi \
    --disable-music-fluidsynth-midi --disable-music-ogg --disable-music-ogg-tremor \
    --disable-music-flac --disable-music-mp3 --disable-music-mp3-mad-gpl \
    > "$WORK/SDL_mixer-configure.log" 2>&1
make > "$WORK/SDL_mixer-make.log" 2>&1
make install > "$WORK/SDL_mixer-install.log" 2>&1

echo "== Wolf4SDL $WOLF_COMMIT =="
cd "$WORK/Wolf4SDL"
git apply --check "$HERE/patches/Wolf4SDL-korvo.patch"
git apply "$HERE/patches/Wolf4SDL-korvo.patch"
# CFLAGS and LDFLAGS go in the environment: the Makefile adds to them, and
# does not get to if they are given as arguments to make.  GPL=1 takes the
# DOSBox OPL emulator in place of the MAME one, whose licence the GPL does
# not go with.  SDL_mixer has to come before SDL in a static link.
CFLAGS="$ARCH" LDFLAGS="-static" make -j$JOBS GPL=1 CXX=$T-g++ CC=$T-gcc \
    SDL_CONFIG="$WORK/prefix/bin/sdl-config" \
    LDFLAGS_SDL="-L$WORK/prefix/lib -lSDL_mixer -lSDL -lpthread -lm" \
    BINARY=wolf3d > "$WORK/Wolf4SDL-make.log" 2>&1
$T-strip -o "$WORK/$NAME" wolf3d

echo "== done =="
cd "$WORK"
ls -l $NAME
sha256sum $NAME
