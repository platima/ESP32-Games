<img align="right" src="https://visitor-badge.laobi.icu/badge?page_id=platima.esp32-games" height="20" />

# ESP32 Games 🎮

Old games, patched and built to run on ESP32 boards that boot Linux. Each one comes with its patch, build notes, tests and a test plan for the board.

No game data lives here - bring your own. Binaries aren't committed either; build them from the notes.

## What runs 🕹️

| Board | Game | Port | Status |
|-------|------|------|--------|
| ESP32-S31-Korvo-1 | Doom | [fbDOOM](esp32-s31-korvo-1/doom/) | Runs on the board at 18 fps in `-timedemo demo1`. A second build adds a full-screen picture, a USB mouse and an fps counter - built and tested under emulation, not yet run on the board. |
| ESP32-S31-Korvo-1 | Wolfenstein 3D | [Wolf4SDL on SDL 1.2](esp32-s31-korvo-1/wolf3d/) | Runs on the board at 35.3 fps in `--timedemo 0`, or 29.7 fps stretched to fill the panel. The first version managed 6 to 8. |

## Layout 📁

```
esp32-s31-korvo-1/      one folder per board
  README.md             what the board gives a game to work with, and how to get one onto it
  doom/
    README.md           where things stand, options and keys
    v1/                 the first patch - the one that has run on hardware
    v2/                 full screen, mouse and fps counter, with tests and a test plan
  wolf3d/
    README.md           where things stand, options and keys
    build.sh            fetches the sources, applies the patches, builds
    patches/            one patch for SDL 1.2.15, one for Wolf4SDL
    tests/              a fake console, and every way out of the game checked against it
    tools/              storecost.c - times loads and stores on the board
LICENSES/               licence texts for the patched projects
```

## The board 🔧

So far it's all on the ESP32-S31-Korvo-1 running [annoyedmilk's esp32-s31-linux](https://github.com/annoyedmilk/esp32-s31-linux). That gives a game one 320 MHz RISC-V core, 16 MB of RAM with roughly 10 MB left once the kernel is up, an 800x480 LCD as a plain framebuffer, a USB keyboard and mouse, and no audio at all.

The details, and how to get a game onto the card, are in [esp32-s31-korvo-1/README.md](esp32-s31-korvo-1/README.md).

## Game data 💾

You need your own copy. For Doom that's the shareware `doom1.wad`, or [Freedoom](https://freedoom.github.io/) if you'd rather something free to pass around. For Wolfenstein 3D it's the eight `.WL6` files of the full game - the Steam release has them in its `base` folder.

Nothing in this repo contains game data, and the `.gitignore` is set up to keep it that way.

## Building 🛠️

Each game has a `BUILD.txt` with the exact steps, and Wolfenstein a `build.sh` that does them. They use the board's own Buildroot toolchain, which you get by building esp32-s31-linux, so the result matches what the board runs. Everything is linked statically, so a game is one file you copy to the SD card.

## Sponsor This Project 💝

If this saved you some time, or you just like seeing old games on odd hardware, you can chip in:

**[💖 Sponsor on GitHub](https://github.com/sponsors/platima)**

## Acknowledgements 🙏

- id Software, for releasing the Doom and Wolfenstein 3D source in the first place.
- [fbDOOM](https://github.com/maximevince/fbDOOM) by maximevince - the framebuffer port the Doom patches apply to.
- Wolf4SDL by Moritz "Ripper" Kroll, and [ioan-chera's git copy](https://github.com/ioan-chera/Wolf4SDL) of it - the port the Wolfenstein patch applies to.
- [SDL](https://www.libsdl.org/) 1.2 by Sam Lantinga and contributors, whose framebuffer console driver still does the job.
- [annoyedmilk](https://github.com/annoyedmilk/esp32-s31-linux), for the Linux port that makes any of this possible.

## Licences 📄

- My own notes here are MIT - see [LICENSE](LICENSE).
- Each patch, and each test that builds against a patched project, carries the licence of the project it changes. For fbDOOM that's the GNU GPL, version 2 or later, as its source files say. For Wolf4SDL it's the GNU GPL version 2, which is one of the two licences it offers and the one it's built under here. A copy is in [LICENSES/GPL-2.0.txt](LICENSES/GPL-2.0.txt).
- SDL 1.2 is under the GNU LGPL, version 2.1 or later, and so is the patch to it. A copy is in [LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt). `build.sh` is what lets you relink the game against another SDL.
- A binary built from a patch is under that same licence. Its source is the upstream commit named in the `BUILD.txt`, plus the patch here.
- Game data has its own terms and isn't part of this repo.

## Author 👨‍💻

**Platima** - [GitHub Profile](https://github.com/platima)
