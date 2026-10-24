/*
 * tracecount: counts how often each instruction of a program was carried
 * out, from the log that qemu's user mode emulators write with
 *
 *     qemu-riscv32-static -d in_asm,exec,nochain -D /dev/stderr PROGRAM ...
 *
 * qemu translates a program a block at a time, a block being the
 * instructions up to the next jump.  That log has every block once, when it
 * is translated:
 *
 *     ----------------
 *     IN:
 *     0x000101a0:  00001197          auipc           gp,4096
 *     0x000101a4:  ...
 *
 * and a line for every time a block is run, with the address it begins at:
 *
 *     Trace 0: 0x7f0e5c000100 [00000000/000101a0/00001a23/ff000001]
 *
 * ("nochain" is what makes that every time.)  So an instruction was carried
 * out as often as the blocks it is in were run.
 *
 * The counts are kept apart for each stretch between two runs of the block
 * that begins at MARK (the first instruction of a function that the program
 * calls to say "here": perf_mark() in tests/perf-main.c).  What comes
 * before the first mark is not counted.
 *
 *     tracecount MARK_HEX BASE_HEX END_HEX < log > counts.txt
 *
 * Output: a line "stretch N total T outside O" for each stretch, followed
 * by "ADDRESS COUNT" for every address in BASE..END that was executed in
 * it.  For a PC:  gcc -O2 -o tracecount tracecount.c
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXBLOCK 1024		/* instructions; qemu stops at 512 */

struct block {
	uint32_t n;		/* instructions, 0: not seen */
	uint32_t first;		/* index into pcs[] */
	uint64_t runs;		/* in this stretch */
};

static uint32_t base, end, slots;
static struct block *blocks;	/* by (address - base) / 2 */
static uint32_t *pcs;		/* the addresses of every block's instructions */
static size_t npcs, maxpcs;
static uint64_t *counts;	/* by (address - base) / 2 */
static uint64_t total;		/* instructions in this stretch */

static int hexval(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return -1;
}

static int hex8(const char *p, uint32_t *v)
{
	int i;

	*v = 0;
	for (i = 0; i < 8; i++) {
		int d = hexval(p[i]);

		if (d < 0)
			return 0;
		*v = *v << 4 | d;
	}
	return 1;
}

/* what the runs of a block so far come to, for each of its instructions */
static void settle(struct block *b)
{
	uint32_t i;

	if (!b->runs)
		return;
	total += b->runs * b->n;
	for (i = 0; i < b->n; i++) {
		uint32_t pc = pcs[b->first + i];

		if (pc >= base && pc < end)
			counts[(pc - base) / 2] += b->runs;
	}
	b->runs = 0;
}

static void define(const uint32_t *list, uint32_t n)
{
	struct block *b;

	if (!n || list[0] < base || list[0] >= end)
		return;
	b = &blocks[(list[0] - base) / 2];
	if (b->n == n && !memcmp(&pcs[b->first], list, n * sizeof(*list)))
		return;		/* translated again, the same */
	settle(b);
	if (npcs + n > maxpcs) {
		maxpcs = (npcs + n) * 2;
		pcs = realloc(pcs, maxpcs * sizeof(*pcs));
		if (!pcs)
			exit(1);
	}
	memcpy(&pcs[npcs], list, n * sizeof(*list));
	b->first = npcs;
	b->n = n;
	npcs += n;
}

int main(int argc, char *argv[])
{
	static char buf[1 << 20];
	static uint32_t list[MAXBLOCK];
	char line[512];
	uint32_t mark, i, n = 0;
	uint64_t outside = 0, unknown = 0;
	int stretch = 0, inblock = 0;

	if (argc != 4) {
		fprintf(stderr, "Usage: %s MARK_HEX BASE_HEX END_HEX < log\n", argv[0]);
		return 1;
	}
	mark = strtoul(argv[1], NULL, 16);
	base = strtoul(argv[2], NULL, 16);
	end = strtoul(argv[3], NULL, 16);
	slots = (end - base) / 2 + 1;
	blocks = calloc(slots, sizeof(*blocks));
	counts = calloc(slots, sizeof(*counts));
	if (!blocks || !counts)
		return 1;
	setvbuf(stdin, buf, _IOFBF, sizeof(buf));

#define FLUSH() do { \
	for (i = 0; i < slots; i++) \
		settle(&blocks[i]); \
	if (stretch) { \
		printf("stretch %d total %llu outside %llu\n", stretch, \
		       (unsigned long long) total, (unsigned long long) outside); \
		for (i = 0; i < slots; i++) \
			if (counts[i]) \
				printf("%x %llu\n", base + 2 * i, (unsigned long long) counts[i]); \
	} \
	memset(counts, 0, slots * sizeof(*counts)); \
	total = outside = 0; \
} while (0)

	while (fgets(line, sizeof(line), stdin)) {
		uint32_t pc;

		if (line[0] == 'T' && !strncmp(line, "Trace ", 6)) {
			const char *p = strchr(line, '[');

			if (!p || strlen(p) < 18 || p[9] != '/' || !hex8(p + 10, &pc))
				continue;
			if (pc == mark) {
				FLUSH();
				stretch++;
			}
			if (!stretch)
				continue;
			if (pc < base || pc >= end) {
				outside++;
			} else if (blocks[(pc - base) / 2].n) {
				blocks[(pc - base) / 2].runs++;
			} else {
				unknown++;
			}
			continue;
		}
		if (line[0] == 'I' && !strncmp(line, "IN:", 3)) {
			inblock = 1;
			n = 0;
			continue;
		}
		if (inblock && line[0] == '0' && line[1] == 'x' && hex8(line + 2, &pc) &&
		    line[10] == ':') {
			if (n < MAXBLOCK)
				list[n++] = pc;
			continue;
		}
		if (inblock) {
			define(list, n);
			inblock = 0;
		}
	}
	FLUSH();
	if (unknown)
		fprintf(stderr, "tracecount: %llu runs of blocks that the log did not show\n",
			(unsigned long long) unknown);
	return 0;
}
