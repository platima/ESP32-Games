/*
 * A small SDL 1.2 program for testing the frame buffer driver without the
 * game: sets a video mode, says what it got, fills the picture with one
 * colour, and prints the events it is sent until Esc is pressed or the time
 * is up.
 *
 * Usage: sdlprobe [WIDTH HEIGHT] [-ms N] [-deaf] [-flags hw|sw|dbl] [-end HOW]
 *   -ms N      give up after N milliseconds (3000)
 *   -deaf      do not read any events: what is typed stays unread
 *   -flags     what to ask SDL_SetVideoMode for (hw)
 *   -end HOW   how to finish: quit (SDL_Quit, the default), return (from
 *              main, without SDL_Quit), exit (exit(5), without SDL_Quit)
 *   -linger N  after SDL_Quit, stay for N milliseconds before ending
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL.h>

int main(int argc, char **argv)
{
    int w = 640, h = 400, ms = 3000, deaf = 0, linger = 0, i;
    Uint32 flags = SDL_HWSURFACE;
    const char *end = "quit";
    SDL_Surface *screen, *small;
    SDL_Event ev;
    Uint32 start;
    int running = 1;

    setvbuf(stdout, NULL, _IONBF, 0);

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-ms") && i + 1 < argc)
            ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-deaf"))
            deaf = 1;
        else if (!strcmp(argv[i], "-linger") && i + 1 < argc)
            linger = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-end") && i + 1 < argc)
            end = argv[++i];
        else if (!strcmp(argv[i], "-flags") && i + 1 < argc) {
            i++;
            flags = !strcmp(argv[i], "sw") ? SDL_SWSURFACE
                  : !strcmp(argv[i], "dbl") ? SDL_HWSURFACE | SDL_DOUBLEBUF : SDL_HWSURFACE;
        } else if (i + 1 < argc) {
            w = atoi(argv[i]);
            h = atoi(argv[++i]);
        }
    }

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        printf("SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    screen = SDL_SetVideoMode(w, h, 16, flags);
    if (screen == NULL) {
        printf("SDL_SetVideoMode failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    printf("video: %dx%d, %d bpp, pitch %d, offset %u, %s%s\n", screen->w, screen->h,
           screen->format->BitsPerPixel, screen->pitch, (unsigned)screen->offset,
           (screen->flags & SDL_HWSURFACE) ? "hardware surface" : "software surface",
           (screen->flags & SDL_DOUBLEBUF) ? ", double buffered" : "");
    printf("video: the surface the program draws on is %s\n",
           screen == SDL_GetVideoSurface() && (screen->flags & SDL_HWSURFACE)
           ? "the frame buffer itself" : "a copy that SDL keeps");

    /* What Wolf4SDL does for each of its small pictures */
    small = SDL_CreateRGBSurface(SDL_HWSURFACE, 24, 32, 8, 0, 0, 0, 0);
    if (small != NULL)
        printf("surface: 24x32 asked for as a hardware surface: %d bpp, pitch %d, %d bytes\n",
               small->format->BitsPerPixel, small->pitch, small->pitch * small->h);

    SDL_ShowCursor(SDL_DISABLE);
    SDL_FillRect(screen, NULL, SDL_MapRGB(screen->format, 255, 255, 255));
    SDL_Flip(screen);

    start = SDL_GetTicks();
    while (running && (int)(SDL_GetTicks() - start) < ms) {
        while (!deaf && SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_KEYDOWN:
            case SDL_KEYUP:
                printf("key %s: %s (code %d)\n", ev.type == SDL_KEYDOWN ? "down" : "up",
                       SDL_GetKeyName(ev.key.keysym.sym), ev.key.keysym.scancode);
                if (ev.type == SDL_KEYUP && ev.key.keysym.sym == SDLK_ESCAPE)
                    running = 0;
                break;
            case SDL_MOUSEMOTION:
                printf("mouse moved by (%d,%d) to (%d,%d)\n", ev.motion.xrel, ev.motion.yrel,
                       ev.motion.x, ev.motion.y);
                break;
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP:
                printf("mouse button %d %s\n", ev.button.button,
                       ev.type == SDL_MOUSEBUTTONDOWN ? "down" : "up");
                break;
            case SDL_QUIT:
                printf("quit event\n");
                running = 0;
                break;
            }
        }
        SDL_Delay(10);
    }

    printf("ending: %s\n", end);
    if (!strcmp(end, "return"))
        return 0;
    if (!strcmp(end, "exit"))
        exit(5);
    SDL_Quit();
    printf("after SDL_Quit\n");
    if (linger > 0) {
        SDL_Delay(linger);
        printf("lingered to the end\n");
    }
    return 0;
}
