# Wolfenstein 3D on the ESP32-S31-Korvo-1 🏰

[Wolf4SDL](https://github.com/ioan-chera/Wolf4SDL) at commit `51b3694` - the last revision that uses SDL 1.2 - linked statically with SDL 1.2.15 and SDL_mixer 1.2.12. SDL 1.2 still has a driver for the Linux framebuffer console, so the game draws on `/dev/fb0` and reads the keyboard from the console with nothing installed on the board. One patch changes SDL, one changes the game.

## Where it's at

| Build | What it is | State |
|-------|------------|-------|
| First version | Draws at 640x400, or at 800x480 with `--resf 800 480`, and leaves it to SDL to put on the screen. | Ran on the board first go - at 6.2 fps with `--resf 800 480`. |
| `wolf3d-korvo` | Draws at 320x200 and enlarges the picture itself, writing only what changed since the last frame. | Runs on the board: 35.3 fps in `--timedemo 0`, and 29.7 fps filling the panel with `--scale fill`. Tested under emulation with 125 checks. |
| `wolf3d-korvo-zb` | The same sources, built so the compiler can use the Zba, Zbb and Zbs instructions. | Built, and tested under emulation with the same 89 cases. Not yet run on the board. |

The patches here are the second version's. `--scale off --res 640 400` makes it draw the way the first one did, so the old behaviour is still there to compare against.

## Why stock SDL and Wolf4SDL needed patching

SDL 1.2's framebuffer driver was written for desktop PCs with a spare virtual terminal or two. On a board where the LCD is the only console:

- It won't start without a mouse at `/dev/input/mice` or similar, and this kernel doesn't have those. It reads `/dev/input/eventN` now.
- As root it moves the game to a new virtual terminal. It stays on the one it was started from now.
- It asks the framebuffer about sixty video modes at start-up. simplefb says yes to every one, and the kernel redraws the whole text console each time. One question now.
- Ctrl+Alt+F1 to F12 switch terminals. In this game that's fire, strafe and a function key.
- Its crash handler covers four signals. Anything else that ends the game leaves the console in graphics mode with a raw keyboard, which on this board means a power cycle. The driver now catches thirteen, and puts the console back with system calls only.

And Wolf4SDL itself:

- It quits at start-up when there's no sound device.
- It asks for double buffering, which this framebuffer can't do, so SDL quietly keeps a second copy of the screen and copies it across every frame.
- It hands the whole picture to SDL on every frame, which converts it one pixel to a store, changed or not.
- Nothing can catch `kill -9`, which is what the kernel uses when memory runs out. So the game starts a second small process - the console guard - that waits for the game to go away and puts the console back if the game didn't.

## The frame rate

On this board every store to memory goes straight out to the PSRAM while the LCD is on, so a store costs far more than an instruction does. Building the same sources for a PC and counting with valgrind's cachegrind gave this for one frame of the first demo. The first two rows are the first version; the rest are the current one with the option shown:

| | Instructions | Stores | Picture |
|---|---:|---:|---|
| First version, 640x400 | 3,720,000 | 478,000 | 640x400, centred |
| First version, `--resf 800 480` | 5,330,000 | 704,000 | 800x480 |
| *(none)* | 1,080,000 | 83,000 | 640x400, centred |
| `--scale fill` | 1,200,000 | 101,000 | 800x480 |
| `--resf 400 240` | 1,450,000 | 113,000 | 800x480 |
| `--res 640 400` | 3,440,000 | 275,000 | 640x400, centred |
| `--resf 800 480` | 4,890,000 | 397,000 | 800x480 |

Those are counts of x86 code, not times. Here's what the board made of three of them in `--timedemo 0`:

| | fps | ms a frame |
|---|---:|---:|
| *(none)* | 35.3 | 28.3 |
| `--scale fill` | 29.7 | 33.7 |
| `--scale off --res 640 400` - the first version's way | 8.1 | 123.5 |

Take the first and the last and you get about 16 ns an instruction and 135 ns a store. The middle one is then a check: it should take 32.7 ms, and took 33.7. So the counts are a fair guide, and both things cost - a default frame is roughly 17 ms of instructions and 11 ms of stores.

By the same two figures `--resf 400 240` should manage about 26 fps and `--resf 800 480` about 7.6. Those two are worked out, not measured - [BUILD.txt](BUILD.txt) shows the working.

The short of it: fill the panel from a small picture, don't draw at 800x480. Every wall pixel is a store and a handful of instructions, and 800x480 has six times the pixels of 320x200.

The Zb build saves instructions, not stores: under emulation it gets through the first demo in 3 to 4% fewer. That should be worth about half a frame a second.

16 ns is five clock ticks for an average instruction, which is a lot. [`tools/storecost.c`](tools/storecost.c) is a small program that times loads and stores on the board on their own, to find out where that goes. It hasn't been run on the board yet.

## Running it

Build it from [BUILD.txt](BUILD.txt), put the binary and your eight `.WL6` files in a folder called `wolf3d` on the card, then:

```sh
cp /mnt/sd/wolf3d/wolf3d-korvo /root/wolf3d && chmod +x /root/wolf3d
cd /mnt/sd/wolf3d
/root/wolf3d
```

The game looks for its data in the directory it's started from, in lower case first and then upper case. Settings and saved games go in `/root/.wolf4sdl/`.

| Option | What it does |
|--------|--------------|
| *(none)* | Draws 320x200 and shows it doubled: 640x400 in the middle of the panel. |
| `--scale fill` | The same picture stretched to the whole panel, menus included. |
| `--scale aspect` | The same picture at 640x480 - the shape it had on a monitor. |
| `--resf 400 240` | Draws at 400x240 and doubles it: the whole panel, with even pixels. Menus sit in the top left corner. |
| `--res 640 400` | Draws at 640x400. Finer walls, about three times the work. |
| `--resf 800 480` | Draws every pixel of the panel. The most work by a long way. |
| `--scale off` | Leaves the picture to SDL, as the first version did. |
| `--showfps` | The frame rate in the top left corner while playing. |
| `--timedemo N` | Plays demo N (0 to 3) flat out, prints the frame rate and quits. |
| `--tedlevel N` | Starts in a level. 0 to 9 are the floors of episode 1, 10 to 19 episode 2, and so on. |
| `--fix-console` | Puts the panel's console back in text mode if a killed game left it in graphics mode. Does nothing else. |

Every run ends with a line like `wolf3d: 1830 frames of the 3D view, 61.0 s of drawing (30.0 fps)`.

### Keys

| Key | Does |
|-----|------|
| Arrows | Move and turn |
| Ctrl | Fire |
| Alt | Strafe, held with left and right |
| Shift | Run |
| Space | Open doors, use |
| 1 to 4 | Weapons |
| Esc | Menu |
| F10, then Y | Quit |
| Alt+F4 | Quit straight away, without asking |

The mouse turns and walks you, the left button fires, the right button strafes and the middle button is "use".

## Good to know

- You need the full game, version 1.4 as GT Interactive and Activision sold it - which is what Steam has. Other versions are turned away with a message; they'd need a rebuild with different lines in `version.h`.
- No sound. The board doesn't have any.
- The game uses about 2 MB while playing, plus the binary.
- `--resf 400 240` and `--resf 800 480` leave the menus, the title and the screens between levels at 640x400 in the top left corner. That's how Wolf4SDL does it. `--scale fill` fills the panel with those too.
- `killall wolf3d` ends the game cleanly. `killall -9 wolf3d` takes the console guard down with the game - don't.
- A game that hangs without ending can't be stopped from the panel, because no key reaches it. It hasn't happened under emulation, and the test plan starts a timer first for that reason.
- A mouse has to be plugged in before the game starts.
- The Zb build checks for its three extensions before it does anything else, and says so and quits if one is missing. The board's device tree lists all three.

## Testing

[TEST-PLAN.txt](TEST-PLAN.txt) lists what's still worth running on the board, and walks through a first run with the safest steps first. It installs the game as `/root/wolf3d2`, because on my board the first version is still at `/root/wolf3d`.

[tests/](tests/) has what runs under `qemu-riscv32-static`. A fake console stands in for the framebuffer, the virtual terminals and the input devices, and the files that talk to the console are compiled against it unchanged. Each case starts SDL or the game, does something to it - a key, a signal, `kill -9`, a crash, a failing system call - and checks that the console was left as it was found, and by which steps. The game also reads the screen back after every picture and stops if a pixel isn't what it drew. Then 36 deliberately broken copies have to make at least one case fail each.

`run-tests.sh` needs the trees `build.sh` leaves behind and your own data files. [tests/results.txt](tests/results.txt) is the last full run, and [tests/results-zb.txt](tests/results-zb.txt) the run against the Zb build.

## Checking a build

`bash build.sh` makes the first and `VARIANT=zb bash build.sh` the second. Both are reproducible with the same toolchain: fresh sources plus the two patches give these bytes.

| Build | Size | SHA-256 |
|-------|-----:|---------|
| `wolf3d-korvo` | 661,848 | `fbb3ab87a7b925629b1f44dac35d81e296b5974830ded1f020ddb4492abdb743` |
| `wolf3d-korvo-zb` | 661,872 | `39e118098480e0c076c4e2bc77a05bf2c282148c5fab609eba9ac4da458e5a44` |

## Licences

Wolf4SDL is built from id Software's source under the GNU GPL version 2, with the DOSBox OPL emulator in place of the MAME one (`GPL=1`). SDL 1.2 is under the LGPL 2.1 or later, and SDL_mixer under the zlib licence. The game patch is offered under the GPL and the SDL patch under the LGPL; each says so at the top. Copies of the GPL and the LGPL are in [LICENSES/](../../LICENSES/).
