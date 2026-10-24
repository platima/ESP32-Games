/*
 * vgatest: does the quick way of drawing the 16-colour modes put the same
 * picture on the screen as the way it stands in for?
 *
 * vga.c of the patched tiny386 is compiled into this file as it is, so that
 * the test can get at the VGA's registers and at the switch between the two
 * ways (vga_planar_fast).  Then, many times over:
 *
 *  - the registers that decide a picture, the palette and the video memory
 *    are set at random: mostly to what the BIOS sets for mode 12h (a pixel
 *    to a dot) or mode 0Dh (each pixel two dots wide, at half the dot
 *    clock), which are the cases the quick way is for, or for the text mode
 *    03h, but also to everything else, where it has to stand back.  The
 *    video memory is noise in half of the rounds and a few values over and
 *    over in the other half, as a desktop is: eight pixels that are passed
 *    over because they look as they did are then common, and have to be
 *    right;
 *  - a picture is drawn the quick way on a screen full of rubbish, as the
 *    first picture after a change of mode;
 *  - then pictures follow in which a little of the video memory has
 *    changed, or a colour, or the size, or where in the video memory the
 *    picture starts (inside it or past its end), or nothing, each one
 *    drawn as the emulator would draw it: told to draw everything, or not;
 *  - or the guest has written registers of the CRT controller through its
 *    ports, as the BIOS does for every character it prints (where the text
 *    cursor is) and for every change of mode: the same value again, the
 *    cursor's registers, any register, the size.  tiny386 as released
 *    clears the screen at each such write.  The patched one puts the clear
 *    off until the next picture and leaves it out if the screen would come
 *    out the same;
 *  - or the picture has been split (the line compare) or panned (AR13h):
 *    the quick way stands back for panning, and has to follow the split;
 *  - or the dot clock has been halved or put back (mode 0Dh and mode 12h,
 *    40 and 80 columns of text), the mode has gone from text to graphics or
 *    back, or the screen has been blanked or shown again.  A change of mode
 *    clears the screen; a text screen of another size or place is cleared
 *    as well, and the patched one leaves that second clear out when nothing
 *    has been drawn since the first;
 *  - a second VGA with a second screen is taken through the same steps
 *    with the quick way switched off: the same registers, the same video
 *    memory, the same rubbish to begin with, the same writes to its ports,
 *    which clear its screen there and then.  After every picture the two
 *    screens have to be the same, pixel for pixel.
 *
 * This is done for four screens: the board's 800x480, one that is smaller
 * than the picture and not a multiple of eight pixels wide, one that is
 * larger than any picture, and one of an odd width that cuts a pixel of
 * mode 0Dh in half.
 *
 * With the quick way switched off the code is what tiny386 has as released,
 * but for storing a pixel only where the screen differs.  The registers are
 * allowed to point the picture past the end of the video memory, as a guest
 * may; the memory has a margin of zeroes behind it here so that both ways
 * read the same there.
 *
 * Build and run, on a PC, in the patched tree:
 *   gcc -O2 -std=gnu11 -I. -DBPP=16 -DVGA_STORE_CHANGED -o vgatest \
 *       .../tests/vgatest.c vgafont.c && ./vgatest [ROUNDS [SEED]]
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* vga.c clears a screen with memset(): the times it does that to each of
   the two screens are counted, to know whether a clear was left out */
static const void *watched, *watched_ref;
static unsigned long clears, ref_clears;

static void *counted_memset(void *d, int c, size_t n)
{
	clears += d == watched;
	ref_clears += d == watched_ref;
	return memset(d, c, n);
}

#define memset(d, c, n) counted_memset(d, c, n)
#include "vga.c"
#undef memset

#include <time.h>

/* what vga.c wants from the rest of the emulator */
uint32_t get_uticks()
{
	return 0;
}

PCIDevice *pci_register_device(PCIBus *b, const char *name, int devfn,
			       uint16_t vendor_id, uint16_t device_id,
			       uint8_t revision, uint16_t class_id)
{
	return NULL;
}

void pci_register_bar(PCIDevice *d, unsigned int bar_num, uint32_t size,
		      int type, void *opaque, PCIBarSetFunc *bar_set)
{
}

#define VRAM (256 * 1024)
#define MARGIN (4 * 1024 * 1024)

static const struct { int w, h; } sizes[] = {
	{ 800, 480 }, { 636, 350 }, { 1024, 768 }, { 637, 479 },
};
#define NSIZES ((int) (sizeof(sizes) / sizeof(sizes[0])))

static uint64_t rng = 88172645463325252ull;

static uint32_t rnd(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint32_t) (rng >> 16);
}

static void nothing(void *opaque, int x, int y, int w, int h)
{
}

struct screen {
	VGAState *vga;
	uint8_t *vram;
	uint16_t *fb;
	int pixels;
};

static void screen_new(struct screen *sc, int w, int h)
{
	sc->pixels = w * h;
	sc->vram = calloc(1, VRAM + MARGIN);
	sc->fb = malloc(sc->pixels * 2);
	sc->vga = vga_init((char *) sc->vram, VRAM, (uint8_t *) sc->fb, w, h);
}

/* the modes a round begins in */
enum { MODE_12H, MODE_0DH, MODE_TEXT };
static const char *const mode_names[] = { "mode 12h", "mode 0Dh", "text mode" };

/* the registers of a mode as the BIOS leaves them, and then some of them
   as something else */
static void random_registers(VGAState *s, int mode, int wild)
{
	static const uint8_t crtc[3][25] = {
		{ 0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0x0b, 0x3e,	/* 12h */
		  0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		  0xea, 0x8c, 0xdf, 0x28, 0x00, 0xe7, 0x04, 0xe3,
		  0xff },
		{ 0x2d, 0x27, 0x28, 0x90, 0x2b, 0x80, 0xbf, 0x1f,	/* 0Dh */
		  0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		  0x9c, 0x8e, 0x8f, 0x14, 0x00, 0x96, 0xb9, 0xe3,
		  0xff },
		{ 0x5f, 0x4f, 0x50, 0x82, 0x55, 0x81, 0xbf, 0x1f,	/* 03h */
		  0x00, 0x4f, 0x0d, 0x0e, 0x00, 0x00, 0x00, 0x00,
		  0x9c, 0x8e, 0x8f, 0x28, 0x1f, 0x96, 0xb9, 0xa3,
		  0xff },
	};
	static const uint8_t sr1[3] = { 0x01, 0x09, 0x00 };
	static const uint8_t sr4[3] = { 0x06, 0x06, 0x02 };
	static const uint8_t gr5[3] = { 0x00, 0x00, 0x10 };
	static const uint8_t gr6[3] = { 0x05, 0x05, 0x0e };
	static const uint8_t ar10[3] = { 0x01, 0x01, 0x0c };
	static const uint8_t ar13[3] = { 0x00, 0x00, 0x08 };
	int i;

	for (i = 0; i < 25; i++)
		s->cr[i] = crtc[mode][i];
	s->sr[1] = sr1[mode];
	s->sr[4] = sr4[mode];
	s->gr[5] = gr5[mode];
	s->gr[6] = gr6[mode];
	s->ar[0x10] = ar10[mode];
	s->ar[0x12] = 0x0f;
	s->ar[0x13] = ar13[mode];
	s->ar[0x14] = 0x00;
	s->ar_index = 0x20;
	s->msr = mode == MODE_TEXT ? 0x67 : 0xe3;	/* the CRT controller at 0x3d4 */
	s->vbe_regs[VBE_DISPI_INDEX_ENABLE] = 0;
	s->comp_ntsc = 0;
	for (i = 0; i < 16; i++)
		s->ar[i] = rnd() & 0x3f;
	for (i = 0; i < 768; i++)
		s->palette[i] = rnd() & 0x3f;

	/* other sizes of the same kind of mode: 350 lines, 400 lines each
	   drawn twice, wider and narrower than the screen, a start that is
	   not 0 */
	switch (rnd() % 8) {
	case 0:
		s->cr[0x12] = 0x5d;		/* 350 lines */
		s->cr[0x07] = 0x1f;
		break;
	case 1:
		s->cr[0x12] = 0x8f;		/* 400 lines, each drawn twice */
		s->cr[0x07] = 0x1f;
		s->cr[0x09] = 0xc0;
		break;
	case 2:
		s->cr[0x01] = rnd() % 140;	/* any width up to 1120 */
		break;
	case 3:
		s->cr[0x12] = rnd();		/* any height */
		s->cr[0x07] = rnd();
		break;
	case 4:
		s->cr[0x0c] = rnd() & 0x1f;	/* scrolled */
		s->cr[0x0d] = rnd();
		break;
	case 5:
		s->cr[0x13] = rnd() & 0x7f;	/* another line length */
		break;
	case 6:					/* split, inside the picture */
		s->cr[0x18] = rnd();
		s->cr[0x07] &= ~0x10;
		s->cr[0x09] &= ~0x40;
		break;
	case 7:					/* panned, and maybe not below a split */
		s->ar[0x13] = rnd() & 7;
		s->ar[0x10] ^= rnd() & 0x20;
		s->cr[0x18] = rnd();
		s->cr[0x07] ^= rnd() & 0x10;
		break;
	}

	if (!wild)
		return;
	/* and anything at all in the registers that the drawing looks at */
	switch (rnd() % 10) {
	case 0: s->sr[1] ^= 0x08; break;		/* half dot clock */
	case 1: s->gr[5] = rnd() & 0x7f; break;		/* other shift modes */
	case 2: s->ar[0x12] = rnd() & 0x0f; break;	/* fewer planes */
	case 3: s->cr[0x17] = rnd(); break;		/* CGA and Hercules addressing */
	case 4: s->cr[0x09] = rnd(); break;		/* scan line doubling */
	case 5: s->cr[0x0c] = rnd(); s->cr[0x0d] = rnd(); break; /* a start near the end */
	case 6: s->ar[0x10] = rnd(); s->ar[0x14] = rnd() & 0x0f; break;
	case 7: s->comp_ntsc = 1; s->ar[0x12] = 1; break;
	case 8: s->cr[0x13] = rnd(); s->cr[0x01] = rnd(); break;
	}
}

static void copy_state(VGAState *to, const VGAState *from)
{
	memcpy(to->sr, from->sr, sizeof(to->sr));
	memcpy(to->gr, from->gr, sizeof(to->gr));
	memcpy(to->ar, from->ar, sizeof(to->ar));
	memcpy(to->cr, from->cr, sizeof(to->cr));
	memcpy(to->palette, from->palette, sizeof(to->palette));
	memcpy(to->vbe_regs, from->vbe_regs, sizeof(to->vbe_regs));
	to->ar_index = from->ar_index;
	to->comp_ntsc = from->comp_ntsc;
	to->msr = from->msr;
	to->vbe_start_addr = from->vbe_start_addr;
	to->vbe_line_offset = from->vbe_line_offset;
	to->dac_8bit = from->dac_8bit;
}

/* a word of video memory: noise, or one of a few */
static uint32_t few[4];
static int nfew;

static uint32_t memory_word(void)
{
	if (nfew)
		return few[rnd() % nfew];
	return rnd() * 2654435761u ^ rnd();
}

static unsigned long pictures, quick, half, writes, put_off, left_out;
static unsigned long text_pictures, text_left_out;

/* The guest writes a register of the CRT controller.  Both VGAs get the
   write: the one under test as it is built, the other the way tiny386 does
   it as released, which clears its screen at once. */
static void crtc_write(struct screen *test, struct screen *ref, int index, int val)
{
	vga_ioport_write(test->vga, 0x3d4, index);
	vga_ioport_write(test->vga, 0x3d5, val);
	vga_planar_fast = 0;
	vga_ioport_write(ref->vga, 0x3d4, index);
	vga_ioport_write(ref->vga, 0x3d5, val);
	vga_planar_fast = 1;
	writes++;
}

/* The same picture on the second screen, the old way, and the two screens
   compared.  Returns the number of pixels that differ; *cleared is how many
   times the second screen was cleared for its picture. */
static long check(struct screen *test, struct screen *ref, int full,
		  unsigned long *cleared)
{
	long wrong = 0, i;
	unsigned long before = ref_clears;

	copy_state(ref->vga, test->vga);
	memcpy(ref->vram, test->vram, VRAM);
	vga_planar_fast = 0;
	vga_refresh(ref->vga, nothing, NULL, full);
	vga_planar_fast = 1;
	*cleared = ref_clears - before;
	for (i = 0; i < test->pixels; i++)
		wrong += test->fb[i] != ref->fb[i];
	return wrong;
}

int main(int argc, char *argv[])
{
	long rounds = argc > 1 ? atol(argv[1]) : 600;
	struct screen tests[NSIZES], refs[NSIZES];
	long round, failures = 0;
	int i, step;

	if (argc > 2)
		rng = strtoull(argv[2], NULL, 0) | 1;
	for (i = 0; i < NSIZES; i++) {
		screen_new(&tests[i], sizes[i].w, sizes[i].h);
		screen_new(&refs[i], sizes[i].w, sizes[i].h);
	}

	for (round = 0; round < rounds; round++) {
		struct screen *test = &tests[round % NSIZES], *ref = &refs[round % NSIZES];
		VGAState *s = test->vga;
		int wild = round / NSIZES % 4 == 3;
		int bytes = test->pixels * 2;
		int mode = rnd() % 4;

		/* half of the rounds in mode 12h, a quarter each in mode 0Dh
		   and in text */
		mode = mode == 3 ? MODE_TEXT : mode == 2 ? MODE_0DH : MODE_12H;
		watched = test->fb;
		watched_ref = ref->fb;

		random_registers(s, mode, wild);
		nfew = round & 1 ? 1 + rnd() % 4 : 0;
		for (i = 0; i < nfew; i++)
			few[i] = i ? rnd() * 2654435761u : 0;
		for (i = 0; i < VRAM / 4; i++)
			((uint32_t *) test->vram)[i] = memory_word();
		/* a new mode: the emulator clears the screen and says so */
		for (i = 0; i < test->pixels; i++)
			test->fb[i] = rnd();
		memcpy(ref->fb, test->fb, bytes);
		s->graphic_mode = 0;
		ref->vga->graphic_mode = 0;

		for (step = 0; step < 12; step++) {
			static const uint8_t cursor[4] = { 0x0a, 0x0b, 0x0e, 0x0f };
			static const uint8_t size[4] = { 0x01, 0x12, 0x07, 0x09 };
			int full = 0;
			long wrong;

			if (step > 0) {
				switch (rnd() % 17) {
				case 0:		/* nothing at all */
					break;
				case 1:		/* a few bytes of the picture */
					for (i = rnd() % 40; i >= 0; i--)
						test->vram[rnd() % VRAM] = memory_word();
					break;
				case 2:		/* a block of it */
					memset(test->vram + rnd() % (VRAM - 4096), memory_word(), 1 + rnd() % 4096);
					break;
				case 3:		/* a colour */
					s->palette[rnd() % 768] = rnd() & 0x3f;
					s->ar[rnd() % 16] = rnd() & 0x3f;
					break;
				case 4:		/* the size */
					s->cr[0x01] = rnd() % 140;
					break;
				case 5:		/* something else drew on the screen, and
						   the emulator knows: it asks for all of it */
					for (i = rnd() % 2000; i >= 0; i--)
						test->fb[rnd() % test->pixels] = rnd();
					memcpy(ref->fb, test->fb, bytes);
					full = 1;
					break;
				case 6:		/* scrolled a little */
					s->cr[0x0d] = rnd();
					break;
				case 7:		/* where the picture starts: anywhere,
						   past the end of the memory too */
					s->cr[0x0c] = rnd() & 1 ? rnd() : rnd() & 0x1f;
					break;
				case 8:		/* the guest writes registers with
						   what they hold already */
					for (i = rnd() % 3; i >= 0; i--) {
						int index = rnd() % 25;

						crtc_write(test, ref, index, s->cr[index]);
					}
					break;
				case 9:		/* and where the text cursor is, and
						   what it looks like */
					for (i = rnd() % 3; i >= 0; i--)
						crtc_write(test, ref, cursor[rnd() % 4], rnd());
					break;
				case 10:	/* and any of them, with anything:
						   the first eight may be locked */
					if (rnd() & 1)
						crtc_write(test, ref, 0x11, s->cr[0x11] ^ 0x80);
					for (i = rnd() % 3; i >= 0; i--)
						crtc_write(test, ref, rnd() % 25, rnd());
					break;
				case 11:	/* and the size of the picture */
					crtc_write(test, ref, 0x11, s->cr[0x11] & 0x7f);
					crtc_write(test, ref, size[rnd() % 4],
						   rnd() & 1 ? rnd() : rnd() % 100);
					break;
				case 12:	/* the split moved */
					crtc_write(test, ref, 0x18, rnd());
					break;
				case 13:	/* panned, or no longer */
					s->ar[0x13] = rnd() & 1 ? rnd() & 7 : 0;
					break;
				case 14:	/* the dot clock halved, or no longer:
						   0Dh and 12h, 40 and 80 columns */
					s->sr[1] ^= 0x08;
					break;
				case 15:	/* text, or graphics, from the same
						   registers: a change of mode */
					s->gr[6] ^= 0x01;
					break;
				case 16:	/* the screen blanked, or not any more */
					s->ar_index ^= 0x20;
					break;
				}
			}
			/* was a clear put off, and was it left out then? */
			int wanted = s->clear_wanted;
			unsigned long before = clears, ref_cleared;

			vga_refresh(s, nothing, NULL, full);
			unsigned long cleared = clears - before;
			put_off += wanted;
			left_out += wanted && !cleared;
			pictures++;
			quick += s->seen_valid;
			half += s->seen_valid && s->seen_xdiv == 2;
			wrong = check(test, ref, full, &ref_cleared);
			/* a text screen that the old way cleared once more */
			if (s->graphic_mode == 1) {
				text_pictures++;
				text_left_out += ref_cleared > cleared;
			}
			if (wrong) {
				failures++;
				printf("round %ld step %d (%dx%d screen, %s, %s memory): %ld pixels differ\n",
				       round, step, sizes[round % NSIZES].w, sizes[round % NSIZES].h,
				       wild ? "any registers" : mode_names[mode],
				       nfew ? "repeating" : "noisy", wrong);
				break;
			}
		}
	}
	printf("%lu pictures, %lu of them drawn the quick way from first line to last "
	       "(%lu at half the dot clock), %lu writes to the CRT controller, "
	       "%lu pictures with a clear put off, %lu of those clears left out, "
	       "%lu text pictures, %lu second clears of a text screen left out: "
	       "%ld rounds of %ld went wrong\n",
	       pictures, quick, half, writes, put_off, left_out,
	       text_pictures, text_left_out, failures, rounds);
	/* a test that never came by what it is for has shown nothing */
	if (rounds >= 100 && (!quick || !half || !left_out || left_out == put_off ||
			      !text_left_out)) {
		puts("no picture drawn the quick way, or none at half the dot clock, "
		     "or no clear left out, or none carried out, or no second clear "
		     "of a text screen left out");
		return 1;
	}
	return failures != 0;
}
