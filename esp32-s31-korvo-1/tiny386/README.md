# tiny386 on the ESP32-S31-Korvo-1 🪟

Can the Korvo-1 run Windows 9x? DOSBox-X can't get there - no RISC-V dynamic core, and its page tables alone are bigger than the board's memory. [tiny386](https://github.com/hchunhui/tiny386) might: it's a small x86 PC emulator in C that was written to boot Windows 95 on an ESP32-S3. This is tiny386 at commit `9ed786b`, with a patch and a front end for this board, linked statically with the SDL 1.2.15 that the [Wolfenstein 3D port](../wolf3d/) already runs on.

## Where it's at

| What | State |
|------|-------|
| `tiny386-korvo` | Built with the board's toolchain. Boots FreeDOS 1.4 to a prompt under `qemu-riscv32-static`, from a hard disk image and from FreeDOS's own boot floppy, on a terminal and against a fake copy of the panel's console. 26 test cases pass. **Runs on the board** since 2026-10-21: FreeDOS on the panel at 0.36 million x86 instructions a second. |
| `tiny386-korvo-ua` | The same with one build option the other way (see below). Same tests, same result. Runs on the board too, a touch slower. |
| Windows 95 or 98 | Not under Linux. A 4M guest only fits with the board's services stopped, and at this speed it wouldn't be worth it. Windows 95 does run on the board under the bare-metal firmware instead, which skips Linux altogether: that lives on the [esp32-s31 branch of my tiny386 fork](https://github.com/platima/tiny386/tree/esp32-s31). [DISK-IMAGES.txt](DISK-IMAGES.txt) still has how I'd go about it here. |

## On the board

The first runs on the board, on 2026-10-21, with the be5b725 card layout:

- FreeDOS boots on the panel, the keyboard works, the 16-colour test picture (VGA12T) looks right, and `mem` gives 599K for the largest program with a 2M guest.
- Memory: `MemAvailable` read 5,076 KiB with everything running, and 5,700 KiB after stopping Wi-Fi, dropbear, crond and both log daemons and dropping the caches. So a 4M guest (5.25 MiB) only fits with those stopped.
- Speed: the BIOS and FreeDOS starting, 5 million instructions, went at 0.358 million a second with `tiny386-korvo` and 0.346 million with `tiny386-korvo-ua`, so the aligned-only build stays the one to use. Idling at the FreeDOS prompt with a 4M guest in `-term` it was 0.223 million a second. That's a little over the top of the 130 to 310 thousand I guessed below.
- `--hostbench`: an aligned store costs 97 ns in cache and 134 ns through 2 MiB, which is the Wolfenstein figure again. The ESP32-S31 does unaligned loads and stores in hardware rather than trapping, at 1.6 times the cost for a load and 3.1 times for a store. Reading the clock costs 17.2 microseconds.
- The emulator's own memory came to 564 to 576 KiB (peak RSS less the guest), which is what I'd estimated.
- The `-marks` run recorded nothing, so the piece-by-piece table for `BENCH.COM` is still to come.

The `tiny386:` summary lines go to stderr, so capture them with `2> file`. Everything below was written before the board run, and I've left it as it was: the sums held up.

## Will it fit?

The emulator takes the guest's memory, the guest's video memory, and something for itself. The first two are exact - it touches every byte when it starts. The third I worked out from its system calls under emulation and from the binary:

| | |
|---|---:|
| Guest memory | as `mem_size` says |
| Guest video memory | as `vga_mem_size` says |
| Emulator's heap | 152 KiB (counted) |
| 16-colour graphics modes, while one is up | 150 KiB (from the source) |
| Its data, stack, the code in use, the console guard | about 400 KiB (estimated) |

That's the guest plus 0.55 to 0.7 MiB. The emulator allows itself 1 MiB when it checks, reads `MemAvailable` from `/proc/meminfo` before it takes anything, and stops with the numbers if there isn't enough - better that than being killed half way into starting. At the end of every run it prints what it really used.

| Guest | Needs | Against a board with 5 to 7 MiB free |
|-------|------:|------|
| FreeDOS, 2M + 256K video | 3.25 MiB | Fits. |
| 4M + 256K | 5.25 MiB | Fits the guess, just. Windows 95's official minimum. |
| 6M + 320K - what tiny386's own 800x480 board gives Windows 95 | 7.3 MiB | Only with things stopped. |
| 7M + 768K - tiny386's Windows 98 config | 8.75 MiB | No. |

The "5 to 7 MiB free with Wi-Fi up" was never measured either. The board has 16 MiB, Linux gets 15,376 KiB of it, and what's left once the system is up is the first thing [TEST-PLAN.txt](TEST-PLAN.txt) asks for - along with what stopping `wpa_supplicant`, `dropbear`, `crond` and the two log daemons gives back.

## Will it be fast enough?

Timing anything under qemu tells you about qemu. So I counted instead: a small DOS program does nine fixed pieces of work, the board's emulator runs it under an emulator that logs every instruction, and a counter adds up what each guest instruction cost in host instructions and stores.

| Guest code | Host instructions | Stores | Guess, thousand a second |
|------------|------:|------:|------:|
| 16-bit arithmetic | 90 | 13.5 | 307 |
| 16-bit loads and stores | 169 | 20.1 | 185 |
| DOS calls | 139 | 17.3 | 219 |
| 32-bit arithmetic, paging on | 87 | 13.5 | 310 |
| 32-bit loads and stores, paging on | 180 | 21.4 | 173 |
| 32-bit calls and stack, paging on | 140 | 15.5 | 231 |
| Every memory access missing the translation cache | 197 | 27.1 | 147 |

The last column uses the two figures the Wolfenstein work got from the board - about 16 ns an instruction and 135 ns a store, because with the LCD on every store goes straight out to the PSRAM. An interpreter that stores 13 to 27 times per guest instruction is about the worst thing you could run on that.

So my guess is **130 to 310 thousand instructions a second**: an original IBM PC, give or take, running 386 code. FreeDOS is fine with that - held to 250 thousand a second on a PC it's at its prompt in 37 seconds. Windows 95 would start, I think, and take something like half an hour doing it. That last part is a guess from how long other machines take, not a count.

The board can settle this in five minutes: `BENCH.COM` is on the FreeDOS image, and `tiny386 -marks` times the same nine pieces.

## What had to change

- **The screen.** tiny386 works out every pixel of the guest's screen at every refresh. In 640x480 with 16 colours - Windows' standard VGA mode - that's 12 million instructions, a fifth of a second here, even when nothing has moved. Its own boards have a second core to do that on. This build draws at most ten times a second, never spends more than a fifth of its time drawing, stores a pixel only where the screen differs, and in the 16-colour modes skips any eight pixels whose video memory hasn't changed. A still desktop then costs about 6 ms a look, by the same sums. tiny386 also clears the whole screen every time the guest touches the CRT controller, which the BIOS does twice for every character it prints in a graphics mode; here that clear waits for the next picture and is skipped when it wouldn't change anything. A test draws 72,000 random pictures both ways and compares every pixel.
- **Unaligned memory access.** tiny386 reads guest memory through pointers that are only as aligned as the guest's addresses, and x86 code doesn't align much - about one instruction in eight does it while FreeDOS starts. If the ESP32-S31 traps on those instead of doing them, each one is a trip into the firmware, and the emulator would be several times slower with nothing to say why. I couldn't find out which it is. So `tiny386-korvo` never makes one, `tiny386-korvo-ua` is as tiny386 was, and `--hostbench` times both kinds of access on the board and says which to use.
- **The console.** Same story as Wolfenstein: the panel is the only way in, so a second small process - the console guard - puts it back in text mode if the emulator is killed outright, which is what the kernel does when memory runs out.
- **Getting out.** Ctrl+Alt+Backspace quits. The emulator looks at the keyboard between every 4,096 guest instructions, so a guest that's hung can't take the keyboard with it.
- **What DOS programs see.** tiny386 runs a real BIOS (SeaBIOS) on an emulated VGA. A suite of DOS test programs checks every int 10h function and the register tricks games use (mode X, split screens, smooth scrolling, palette tricks in the retrace) against what a real VGA does, 707 checks in all. The VGA gaps it found are fixed, and so are the BIOS's own: the BIOS files here are built from SeaBIOS's source with a small patch of fixes (mode 07h, 43-line text, the cursor, a few info fields), and the same script without the patch rebuilds tiny386's released files byte for byte. What's left is the floppy port's, a screen-off bit the VGA ignores, and VBE's protected mode interface. [BIOS-COVERAGE.txt](BIOS-COVERAGE.txt) has the table.
- **Disks.** What the guest writes goes to the kernel straight away, and is asked onto the card once the guest has been quiet for two seconds, so that losing power doesn't lose more than that. Floppy images too.

[BUILD.txt](BUILD.txt) has all of it at length, and the patch says file by file what it changes.

## The picture

The emulator asks for the whole 800x480 screen and draws RGB565 straight into the frame buffer - no second copy, no conversion. tiny386 centres what the guest shows and doesn't scale:

| Guest mode | On the panel |
|------------|--------------|
| Text, 80x25 | 720x400 in the middle |
| 320x200, 256 colours | 640x400 in the middle |
| 640x480, 16 colours | Full height, 80 black pixels either side |
| 800x600 and up | The top left 800x480 of it |

`[display]` in the ini should say 800 and 480. If it doesn't, the emulator uses the screen's size anyway and says so.

## Running it

Build it from [BUILD.txt](BUILD.txt), put the binary, `bios.bin`, `vgabios.bin`, `freedos-hd.img` and [`conf/freedos.ini`](conf/freedos.ini) in a folder called `tiny386` on the card, then:

```sh
cp /mnt/sd/tiny386/tiny386-korvo /root/tiny386 && chmod +x /root/tiny386
cd /mnt/sd/tiny386
/root/tiny386 freedos.ini
```

Don't start there, though - [TEST-PLAN.txt](TEST-PLAN.txt) goes at it from the safe end: memory first, then a run with no screen at all, then text on the console, then the picture.

| Option | What it does |
|--------|--------------|
| *(none)* | The guest's picture on the panel. |
| `-term` | The guest's text screen on the terminal you started it from. No graphics. Ctrl+] quits. |
| `-none` | No screen, no keyboard. For timing. |
| `-insns N` | Stops after N million guest instructions. |
| `-time S` | Stops after S seconds. |
| `-marks` | Times `BENCH.COM` piece by piece and stops when it's done. |
| `-log FILE` | The emulator's and the BIOS's messages go to FILE. Otherwise they're dropped. |
| `-plainvga` | Draws the 16-colour modes the slow way. For when a picture looks wrong. |
| `-force` | Runs even if the board has less memory than the guest needs. |
| `--hostbench` | Times loads and stores on this machine and stops. |
| `--fix-console` | Puts the console back in text mode after a killed run. |

Every run ends with how many instructions it emulated, how fast, and how much memory it used.

## Good to know

- No sound. The board doesn't have any, and the Adlib synthesiser is left out of the build.
- No networking. The NE2000 is there with nothing behind it.
- No serial port. tiny386's is the terminal's keyboard, so `enable_serial = 1` would hand every key to the guest, the quit keys included. The emulator refuses it.
- No x87. tiny386 has one, but everything on this board is soft-float and it'd be painfully slow; the build includes it and the sample configs leave it off.
- A mouse has to be plugged in before the emulator starts.
- Text blinks, as on a real VGA: a character with attribute bit 7 set blinks unless the program turns blinking off (int 10h AX=1003h) to get bright backgrounds, which most programs that want them do.
- `killall tiny386` from another login is safe. `killall -9 tiny386` takes the console guard down too - kill the one process by number if it has to be `-9`.
- Windows wants a bigger disk than the card's 64 MiB FAT partition has. [DISK-IMAGES.txt](DISK-IMAGES.txt) has how to add a partition behind the root, tried with the board's own `fdisk` on a copy of the card image.
- The board's toolchain had been cleaned out of the build trees when I got here, so [`toolchain.sh`](toolchain.sh) rebuilds just the compiler. It reproduces the Wolfenstein binary byte for byte, which is how I know it's the same one.

## Checking a build

`bash build.sh` and `VARIANT=ua bash build.sh`. Both are reproducible with the same toolchain: fresh sources plus the two patches give these bytes.

| Build | Size | SHA-256 |
|-------|-----:|---------|
| `tiny386-korvo` | 587,412 | `dd34a04fd0eb000f65187e086363d32a1c8ffccdd8615a0f283e30d6868a0a71` |
| `tiny386-korvo-ua` | 603,796 | `c5400aead863e5e195d22038d0a69c4ccce65f1da5745ff1505dbba275399091` |

## Licences

tiny386 is under the BSD 3-clause licence, with parts from QEMU and TinyEMU under the MIT licence, and the patch here is offered under the same. SDL 1.2 is LGPL 2.1 or later. The BIOS files are SeaBIOS, LGPL 3: their source (`seabios-korvo-src.tar.xz`), the patches and `tools/build-bios.sh` go with them. FreeDOS is GPL 2 or later for the kernel and shell, with other free licences for the rest. Binaries, BIOS files and disk images don't belong in the repository - [BUILD.txt](BUILD.txt) says where each comes from, and the [releases page](https://github.com/platima/ESP32-Games/releases) has the two binaries and the BIOS pair, each with its complete source. The FreeDOS image isn't released: `tools/make-freedos-image.sh` makes one from freedos.org's boot floppy. Licence texts are in [LICENSES](../../LICENSES/).
