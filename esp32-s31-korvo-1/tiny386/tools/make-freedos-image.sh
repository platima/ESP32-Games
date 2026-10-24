#!/bin/bash
# Makes freedos-hd.img: a 16 MiB hard disk image with FreeDOS 1.4 on it that
# boots to a C:\> prompt.  It is made the way it would be on a real PC: boot
# the FreeDOS boot floppy, FDISK, FORMAT, SYS.  The PC is tiny386 itself,
# built for this computer from the same patched sources as the board's
# binary and driven through its terminal mode by tools/drive.py.
#
#   bash tools/make-freedos-image.sh [WORKDIR]
#
# WORKDIR (default $HOME/tiny386-scratch/freedos) is made if it is not there.
# It needs gcc (with as and ld), python3, curl, unzip and mtools, a tiny386
# tree that build.sh has patched (TREE), and bios.bin and vgabios.bin (BIOS,
# a directory).
#
#   TREE   $HOME/tiny386-scratch/build/tiny386
#   BIOS   the directory this script's parent is  (bios.bin, vgabios.bin)
#
# FreeDOS is fetched from freedos.org and is under the GNU GPL and other free
# licences; see https://www.freedos.org/about/license/ before passing the
# image on.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:-$HOME/tiny386-scratch/freedos}
TREE=${TREE:-$HOME/tiny386-scratch/build/tiny386}
BIOS=${BIOS:-$HERE/..}

FD_URL=https://download.freedos.org/1.4/FD14-FloppyEdition.zip
FD_SHA256=45b1fa7c52dd996c3bfa5e352ffcd410781b952a6ad629f15a4c9ec4bbaefc5a

[ -f "$TREE/korvo/main.c" ] || { echo "no patched tiny386 tree at $TREE: run build.sh first, or set TREE"; exit 1; }
[ -f "$BIOS/bios.bin" ] && [ -f "$BIOS/vgabios.bin" ] || { echo "no bios.bin and vgabios.bin in $BIOS: set BIOS"; exit 1; }

mkdir -p "$WORK/dl"
cd "$WORK"

echo "== FreeDOS 1.4 floppy edition =="
[ -f dl/FD14-FloppyEdition.zip ] || curl -fsSL -o dl/FD14-FloppyEdition.zip $FD_URL
echo "$FD_SHA256  dl/FD14-FloppyEdition.zip" | sha256sum -c -
rm -rf floppy && mkdir floppy
unzip -q -o dl/FD14-FloppyEdition.zip '144m/x86BOOT.img' -d floppy

echo "== tiny386 for this computer =="
# the board's front end without SDL: -term and -none are all this needs
SRCS="korvo/main.c korvo/guard.c korvo/hostbench.c i386.c fpu.c ini.c i8259.c
      i8254.c ide.c vga.c vgafont.c i8042.c misc.c adlib.c ne2000.c i8257.c
      sb16.c pcspk.c pc.c pci.c term.c"
(cd "$TREE" && gcc -O2 -std=gnu11 -I. -DKORVO_NO_SDL -DBPP=16 -DPC_DEBUGCON=stderr \
    -DI386_ENABLE_FPU $SRCS -o "$WORK/tiny386-pc" -lm) 2> "$WORK/tiny386-pc.log"

cp "$BIOS/bios.bin" "$BIOS/vgabios.bin" .
cp floppy/144m/x86BOOT.img boot.img
rm -f freedos-hd.img
truncate -s 16M freedos-hd.img

ini() {     # NAME, then lines for [pc]
    local name=$1
    shift
    {
        echo "[pc]"
        echo "bios = bios.bin"
        echo "vga_bios = vgabios.bin"
        echo "mem_size = 4M"
        echo "vga_mem_size = 256K"
        echo "fill_cmos = 1"
        for line in "$@"; do echo "$line"; done
        echo
        echo "[cpu]"
        echo "gen = 4"
        echo "fpu = 0"
    } > "$name"
}
ini install.ini "fda = boot.img" "hda = freedos-hd.img"
ini hd.ini "hda = freedos-hd.img"

drive() {   # STEPS INI
    python3 "$HERE/drive.py" --log "${1%.json}.raw" --dump "${1%.json}.txt" "$1" -- \
        ./tiny386-pc -term -log "${1%.json}.log" "$2"
}

# The boot floppy starts FreeDOS's installer, which asks before it does
# anything.  "N" and Enter leave it for a prompt.
cat > 1-partition.json <<'EOF'
[
  {"name": "installer question", "wait": "Do you want to proceed \\[Y,N\\]\\?", "timeout": 300, "send": "n\r"},
  {"name": "prompt", "wait": "has been aborted\\.\\s+A:\\\\>", "timeout": 120, "send": "fdisk 1 /pri:100,100\r"},
  {"name": "partition made", "wait": "A:\\\\>fdisk 1 /pri:100,100\\s+(\\S.*\\s+)?A:\\\\>", "timeout": 120, "send": "fdisk 1 /activate:1\r"},
  {"name": "partition active", "wait": "A:\\\\>fdisk 1 /activate:1\\s+(\\S.*\\s+)?A:\\\\>", "timeout": 120, "send": "fdisk 1 /mbr\r"},
  {"name": "boot code in the MBR", "wait": "A:\\\\>fdisk 1 /mbr\\s+(\\S.*\\s+)?A:\\\\>", "timeout": 120, "send": "fdisk /info 1\r"},
  {"name": "partition table shown", "wait": "FAT-?1[26]", "timeout": 120},
  {"sleep": 1}
]
EOF
cat > 2-format.json <<'EOF'
[
  {"name": "installer question", "wait": "Do you want to proceed \\[Y,N\\]\\?", "timeout": 300, "send": "n\r"},
  {"name": "prompt", "wait": "has been aborted\\.\\s+A:\\\\>", "timeout": 120, "send": "format c: /v:FREEDOS /q /u /z:seriously\r"},
  {"name": "formatted", "wait": "Format complete|bytes total disk space|bytes available on disk", "timeout": 300},
  {"name": "prompt again", "wait": "A:\\\\>\\s*$", "timeout": 120, "send": "sys c:\r"},
  {"name": "system files copied", "wait": "System transferred", "timeout": 300},
  {"sleep": 2}
]
EOF
cat > 3-boot.json <<'EOF'
[
  {"name": "prompt from the hard disk", "wait": "C:\\\\>", "timeout": 300, "send": "ver\r"},
  {"name": "ver answers", "wait": "C:\\\\>ver\\s+FreeCom version[^\\n]*\\n\\s*C:\\\\>", "timeout": 120, "send": "mem\r"},
  {"name": "mem answers", "wait": "Total Free|Largest executable|Conventional", "timeout": 120, "send": "dir\r"},
  {"name": "dir answers", "wait": "bytes free", "timeout": 120, "send": "off\r"},
  {"sleep": 5}
]
EOF

echo "== partition =="
drive 1-partition.json install.ini
echo "== format and system files =="
drive 2-format.json install.ini

echo "== the rest of the files =="
# where FDISK put the partition, from the table it wrote
START=$(python3 - <<'EOF'
import struct
mbr = open('freedos-hd.img', 'rb').read(512)
assert mbr[510:512] == b'\x55\xaa', 'no partition table'
boot, kind, lba, count = mbr[446], mbr[450], *struct.unpack('<II', mbr[454:462])
assert boot == 0x80 and count > 0, 'no active partition'
print(lba * 512)
EOF
)
P="freedos-hd.img@@$START"
mkdir -p files && rm -f files/*
for f in command.com mem.exe more.exe fdapm.com attrib.com xcopy.exe fdisk.exe format.exe sys.com deltree.com; do
    mcopy -n -i boot.img "::/freedos/bin/$f" files/
done
# small programs of this port's own, from tests/guest: BENCH for
# "tiny386 -marks", and two pictures in VGA modes 12h and 13h
for p in bench vga12 vga13; do
    as --32 -o files/$p.o "$HERE/../tests/guest/$p.S"
    ld -m elf_i386 -Ttext 0x100 --oformat binary -o files/$(echo $p | tr a-z A-Z).COM files/$p.o
    rm files/$p.o
done
# and VGA12 once more, with text printed by the BIOS on its picture
as --32 --defsym TEXT=1 -o files/vga12t.o "$HERE/../tests/guest/vga12.S"
ld -m elf_i386 -Ttext 0x100 --oformat binary -o files/VGA12T.COM files/vga12t.o
rm files/vga12t.o
mmd -i "$P" ::/DOS
for f in files/*; do
    [ "${f##*/}" = command.com ] || mcopy -i "$P" "$f" ::/DOS/
done
# SYS takes COMMAND.COM from where the floppy's shell was started; make sure
mdir -i "$P" ::/COMMAND.COM > /dev/null 2>&1 || mcopy -i "$P" files/command.com ::/
printf 'LASTDRIVE=Z\r\nBUFFERS=20\r\nFILES=40\r\nDOS=HIGH\r\nSHELL=C:\\COMMAND.COM C:\\ /E:1024 /P=C:\\FDAUTO.BAT\r\n' > files/fdconfig.sys
printf '@echo off\r\nSET PATH=C:\\DOS\r\nSET DIRCMD=/OGN\r\nalias off=fdapm poweroff\r\nalias reboot=fdapm warmboot\r\necho.\r\necho FreeDOS on tiny386. OFF leaves the emulator.\r\necho VGA12, VGA12T and VGA13 draw a picture each; a key ends it.\r\necho.\r\n' > files/fdauto.bat
mcopy -o -i "$P" files/fdconfig.sys ::/FDCONFIG.SYS
mcopy -o -i "$P" files/fdauto.bat ::/FDAUTO.BAT
mdir -i "$P" ::/ ::/DOS

echo "== boot it =="
drive 3-boot.json hd.ini
cat 3-boot.txt

echo "== done =="
ls -l freedos-hd.img
sha256sum freedos-hd.img
