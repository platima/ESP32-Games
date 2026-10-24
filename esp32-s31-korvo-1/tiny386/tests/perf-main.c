/*
 * perf: runs a guest that marks pieces of its work and says how many guest
 * instructions each piece was.  The guest is tests/guest/bench.S, started
 * from FDAUTO.BAT of a FreeDOS disk image; it puts 0xA1, 0xA2 and so on in
 * the byte at 0000:04F0 as it goes, and 0xAF when it is done.
 *
 * This is the emulator of the board's build with another main(): every
 * object but korvo/main.o is the one in tiny386-korvo.  It has no screen
 * and no keyboard.
 *
 * Each time the mark changes, perf_mark() is called.  That function does
 * nothing; it is a place in the program that a log of every instruction the
 * host carried out can be cut at.  tests/tracecount.c reads such a log from
 * qemu-riscv32-static and counts the host's instructions between the marks;
 * tests/perf-report.py puts the two together.
 *
 *   perf file.ini
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>

#include "pc.h"

uint32_t get_uticks()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint32_t) ts.tv_sec * 1000000 +
		(uint32_t) ts.tv_nsec / 1000);
}

void *bigmalloc(size_t size)
{
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	return p;
}

int load_rom(void *phys_mem, const char *file, uword addr, int backward)
{
	FILE *fp = fopen(file, "rb");
	if (fp == NULL) {
		fprintf(stderr, "%s: %s\n", file, strerror(errno));
		exit(1);
	}
	fseek(fp, 0, SEEK_END);
	int len = ftell(fp);
	rewind(fp);
	if (backward)
		fread((char *) phys_mem + addr - len, 1, len, fp);
	else
		fread((char *) phys_mem + addr, 1, len, fp);
	fclose(fp);
	return len;
}

static void redraw(void *opaque, int x, int y, int w, int h)
{
}

#ifdef PERF_CALLGRIND
/* a build for this PC, run under valgrind --tool=callgrind: the counts so
   far are written out at every mark, and counting starts again */
#include <valgrind/callgrind.h>
#endif

void __attribute__((noinline)) perf_mark(int mark)
{
#ifdef PERF_CALLGRIND
	char name[16];

	snprintf(name, sizeof(name), "before-%02x", mark);
	CALLGRIND_DUMP_STATS_AT(name);
#else
	__asm__ volatile ("" : : "r" (mark));
#endif
}

int main(int argc, char *argv[])
{
	PCConfig conf;

	int pictures = argc == 3 && !strcmp(argv[2], "pictures");

	if (argc != 2 && !pictures) {
		fprintf(stderr, "Usage: %s file.ini [pictures]\n", argv[0]);
		return 1;
	}
	memset(&conf, 0, sizeof(conf));
	conf.mem_size = 8 * 1024 * 1024;
	conf.vga_mem_size = 256 * 1024;
	conf.cpu_gen = 4;
	ne2000_set_config_file(argv[1]);
	if (ini_parse(argv[1], parse_conf_ini, &conf)) {
		fprintf(stderr, "%s: cannot be read\n", argv[1]);
		return 1;
	}
	/* a screen of the board's size if pictures are what is counted */
	conf.width = pictures ? 800 : 16;
	conf.height = pictures ? 480 : 16;
	/* PERF_PLAINVGA in the environment: the 16-colour modes drawn pixel
	   by pixel, as tiny386 draws them (tiny386-korvo -plainvga) */
	if (getenv("PERF_PLAINVGA"))
		vga_planar_fast = 0;

	/* the emulator's own messages are not wanted in a trace */
	freopen("/dev/null", "w", stderr);

	PC *pc = pc_new(redraw, NULL,
			bigmalloc(conf.width * conf.height * (BPP / 8)), &conf);
	load_bios_and_reset(pc);
	pc->boot_start_time = get_uticks();

	int mark = 0;
	uint32_t at = 0;
	while (pc->shutdown_state != 8) {
		pc_step(pc);
		vga_step(pc->vga);

		int m = (uint8_t) pc->phys_mem[0x4f0];
		if (pictures && m >= 0xa1) {
			/*
			 * "perf file.ini pictures": the guest has put up what
			 * it wants looked at (0xA1 from BENCH.COM: the text
			 * screen it was started from; 0xB1 from VGA12.COM,
			 * VGA13.COM and VGA0D.COM).  Four pictures, each a
			 * stretch of its own for the trace:
			 *  c1  the first after a change of mode: the screen is
			 *      cleared and all of the picture drawn.  (A text
			 *      screen is drawn black on black here: tiny386 as
			 *      it is works the colours out one picture later.)
			 *  c2  the next, as it comes one retrace later.  A text
			 *      screen has its colours now and is drawn again.
			 *  c3  one that is told to draw everything
			 *  c4  one where nothing has changed
			 */
			perf_mark(0xc1);
			vga_refresh(pc->vga, redraw, NULL, 1);
			perf_mark(0xc2);
			vga_refresh(pc->vga, redraw, NULL, 0);
			perf_mark(0xc3);
			vga_refresh(pc->vga, redraw, NULL, 1);
			perf_mark(0xc4);
			vga_refresh(pc->vga, redraw, NULL, 0);
			perf_mark(0xcf);
			printf("c1 1\nc2 1\nc3 1\nc4 1\n");
			return 0;
		}
		if (m == mark || m < 0xa1 || m > 0xaf)
			continue;
		uint32_t cycle = (uint32_t) cpui386_get_cycle(pc->cpu);
		if (mark)
			printf("%02x %u\n", mark, cycle - at);
		else
			printf("boot %u\n", cycle);
		fflush(stdout);
		mark = m;
		at = cycle;
		perf_mark(m);
		if (m == 0xaf)
			return 0;
	}
	return 1;
}
