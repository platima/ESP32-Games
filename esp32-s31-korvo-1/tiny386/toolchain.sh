#!/bin/bash
# Builds the board's cross compiler, and nothing else, when the board's own
# build tree is not there to borrow it from.
#
#   bash toolchain.sh [SOURCE [WORKDIR]]
#
# SOURCE   a checkout of esp32-s31-linux at the commit the board runs
#          (be5b725), with its submodules  ($HOME/esp32-s31-linux-main).
#          It is only read: a copy is made and built from.
# WORKDIR  where the copy and the compiler go  ($HOME/tiny386-scratch/toolchain)
#
# The result is WORKDIR/br-output/host/bin/riscv32-buildroot-linux-musl-gcc:
# GCC 15.3.0, musl, rv32imac, ilp32 (soft float), the same as "make toolchain"
# gives in a full build of the board's system.  build.sh looks for it there.
# It fetches about 300 MB of sources and takes ten to fifteen minutes; the
# 7 GB of intermediate files are removed at the end, which leaves 0.9 GB.
#
# Run it with a plain environment: Buildroot refuses a PATH with spaces in
# it, which is what WSL hands a shell.
#   env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin bash toolchain.sh
#
# How to tell that the compiler is the board's: build something that was
# built with the board's and compare.  The Wolfenstein 3D port's build.sh
# with M set to WORKDIR/br-output gave wolf3d-korvo with the checksum in that
# port's notes, byte for byte, on 2026-10-14.

set -eu

SRC=${1:-$HOME/esp32-s31-linux-main}
WORK=${2:-$HOME/tiny386-scratch/toolchain}

[ -f "$SRC/br2-external/configs/esp32s31_defconfig" ] || { echo "no esp32-s31-linux checkout at $SRC"; exit 1; }
[ -f "$SRC/external/buildroot/Makefile" ] || { echo "$SRC/external/buildroot is empty: git submodule update --init"; exit 1; }

mkdir -p "$WORK"
cd "$WORK"
# with its .git, so that Buildroot names itself as it does in the original
[ -d src ] || cp -a "$SRC" src
export BR2_DL_DIR=$WORK/br-dl
br="make -C $WORK/src/external/buildroot O=$WORK/br-output BR2_EXTERNAL=$WORK/src/br2-external"
$br esp32s31_defconfig
$br toolchain
rm -rf "$WORK/br-output/build"
"$WORK/br-output/host/bin/riscv32-buildroot-linux-musl-gcc" --version | head -1
