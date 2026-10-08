# ESP32-S31-Korvo-1 🔧

Espressif's ESP32-S31 has an MMU, so it can run real Linux. The games here run on the Korvo-1 dev board under [annoyedmilk's esp32-s31-linux](https://github.com/annoyedmilk/esp32-s31-linux), tested at commit `be5b725` - that's the v0.1.0 release plus a README change.

## What a game has to work with

| | |
|---|---|
| CPU | One RISC-V core for Linux at 320 MHz (RV32IMAC). The other core runs the Wi-Fi firmware. No FPU in use. |
| RAM | 16 MB of PSRAM inside the chip package. Roughly 10 MB is left once the kernel is up. |
| Display | 800x480 LCD, RGB565, as a plain framebuffer at `/dev/fb0`. No vsync. |
| Input | USB keyboard and mouse. |
| Audio | None. |
| Storage | microSD. A FAT partition called `KORVO_SD` is mounted at `/mnt/sd`. |

Memory is the tight one. While the LCD is on, every write goes straight out to the PSRAM chip, so drawing a full screen costs more than you'd expect.

## Getting a game onto the board

1. Copy the binary and your game data onto the card's `KORVO_SD` partition from a PC.
2. On the board, put the binary somewhere it can run from:
   ```sh
   cp /mnt/sd/fbdoom /root/ && chmod +x /root/fbdoom
   ```
3. Run it from the LCD console, with a USB keyboard plugged in.

## Things that will bite you

- **One console.** A game takes over the keyboard and the screen. The builds here hand both back on every exit they can catch, but if the kernel kills one outright - which is what it does when memory runs out - nothing can. Then it's SSH, the UART, or a power cycle.
- **Hard resets mark the FAT partition dirty.** Nothing is lost, but the kernel warns about it at every boot from then on, and the stock image has no `fsck.fat` to clear it. Fix it on a PC.

## Building for it

The notes use the toolchain that esp32-s31-linux builds for itself: run its `scripts/ci-build.sh` on a Linux host and you get Buildroot 2026.08's GCC 15.3 for `riscv32-buildroot-linux-musl` (rv32imac, ilp32, soft-float) under `build/br-output/host/bin/`. The `BUILD.txt` files call that output directory `$M`.

Link statically and a game is a single file. `qemu-riscv32-static` will run the result on a PC, which is enough to check that it starts before it goes anywhere near the board.
