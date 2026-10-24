/*
 * BENCH.COM: fixed pieces of work for an emulated 386, to count what an
 * emulator spends on them.
 *
 * A DOS program.  It runs nine pieces of work one after the other and puts
 * a number in the byte at 0000:04F0 (the BIOS's "intra-application
 * communication area", which nothing else uses) before each one, and 0xAF
 * at the end.  Whoever runs the emulator watches that byte: tiny386-korvo
 * with -marks, which times each piece and ends at the last mark, or
 * tests/perf-main.c.  Nothing is printed and nothing is returned to: after
 * the last piece the program stops in a loop, because by then it is in
 * 32-bit protected mode with paging on and has thrown DOS away.
 *
 *   0xA1  16-bit arithmetic in registers
 *   0xA2  16-bit loads and stores in 32 KB of memory
 *   0xA3  16-bit calls, returns, pushes and pops
 *   0xA4  rep movsw and rep stosw, 16 KB at a time and 32 MB in all (the
 *         cost of this one is for each byte, not for each instruction)
 *   0xA5  DOS calls (int 21h, function 30h)
 *   0xA6  32-bit arithmetic in registers, paging on
 *   0xA7  32-bit loads and stores in 256 KB of memory, paging on
 *   0xA8  32-bit calls, returns, pushes and pops, paging on
 *   0xA9  two loads in each of 256 pairs of pages, chosen so that a small
 *         translation cache misses every time
 *   0xAF  done
 *
 * The first megabytes of memory are used as they are: page tables at 2 MiB,
 * data at 3 MiB.  Run it on a machine with at least 4 MB and nothing loaded
 * above the first megabyte (no HIMEM).
 *
 * Build (GNU as and ld, on a PC):
 *   as --32 -o bench.o bench.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BENCH.COM bench.o
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
	.intel_syntax noprefix
	.code16
	.text
	.globl _start
_start:
	cld
	/* 3 MB above the first one, and nobody else's: the BIOS says how
	   much there is, and says none when HIMEM has taken it */
	mov	ah, 0x88
	int	0x15
	jc	1f
	cmp	ax, 3072
	jae	2f
1:	mov	dx, offset needs
	mov	ah, 0x09
	int	0x21
	ret
needs:	.ascii	"BENCH needs a machine with 4 MB and no HIMEM.\r\n$"
2:
	in	al, 0x21		/* no timer and no keyboard interrupts: */
	or	al, 0x03		/* what is counted is this program */
	out	0x21, al

/* ---- 0xA1: arithmetic in registers ------------------------------------ */
	mov	al, 0xa1
	call	mark
	mov	dx, 4
1:	xor	cx, cx			/* 65536 times */
2:	add	ax, bx
	xor	bx, ax
	shl	ax, 1
	adc	bx, 3
	cmp	ax, bx
	jz	3f
3:	dec	cx
	jnz	2b
	dec	dx
	jnz	1b

/* ---- 0xA2: loads and stores ------------------------------------------- */
	mov	al, 0xa2
	call	mark
	mov	dx, 24
1:	mov	si, 0x4000
	mov	cx, 0x2000
2:	mov	ax, [si]
	add	ax, [si + 2]
	mov	[si + 4], ax
	inc	word ptr [si + 6]
	mov	bl, [si + 1]
	mov	[si + 9], bl
	add	si, 4
	dec	cx
	jnz	2b
	dec	dx
	jnz	1b

/* ---- 0xA3: calls and the stack ---------------------------------------- */
	mov	al, 0xa3
	call	mark
	mov	dx, 3
1:	xor	cx, cx
2:	push	ax
	push	bx
	call	addup
	pop	bx
	pop	ax
	dec	cx
	jnz	2b
	dec	dx
	jnz	1b

/* ---- 0xA4: string instructions ---------------------------------------- */
	mov	al, 0xa4
	call	mark
	push	ds
	pop	es
	/* A string instruction with a repeat prefix is one instruction
	   however much it moves, so this piece is 32 MB of moving and
	   filling in a few thousand instructions.  Twelve thousand that do
	   nothing first, so that whoever watches the mark gets to see it. */
	mov	cx, 6000
0:	dec	cx
	jnz	0b
	mov	dx, 1000
1:	mov	si, 0x4000
	mov	di, 0x8000
	mov	cx, 0x2000		/* 16 KB */
	rep	movsw
	mov	di, 0x8000
	mov	cx, 0x2000
	mov	ax, dx
	rep	stosw
	dec	dx
	jnz	1b

/* ---- 0xA5: DOS calls --------------------------------------------------- */
	mov	al, 0xa5
	call	mark
	mov	cx, 10000
1:	push	cx
	mov	ah, 0x30		/* get DOS version */
	int	0x21
	pop	cx
	dec	cx
	jnz	1b

/* ---- into 32-bit protected mode ---------------------------------------- */
	cli
	in	al, 0x92		/* address line 20 */
	or	al, 2
	out	0x92, al

	xor	eax, eax
	mov	ax, cs
	shl	eax, 4			/* where this segment is in memory */
	mov	ebx, eax
	add	eax, offset gdt
	mov	dword ptr [gdtr + 2], eax
	mov	eax, ebx
	add	eax, offset pm32
	mov	dword ptr [farjump + 2], eax
	lgdt	[gdtr]
	mov	eax, cr0
	or	al, 1
	mov	cr0, eax
farjump:
	.byte	0x66, 0xea		/* jmp far 0x08:pm32, the offset filled in above */
	.long	0
	.word	0x08

/* al to 0000:04F0, real mode */
mark:
	push	es
	push	bx
	xor	bx, bx
	mov	es, bx
	mov	es:[0x4f0], al
	pop	bx
	pop	es
	ret

addup:
	push	bp
	mov	bp, sp
	mov	ax, [bp + 4]
	add	ax, [bp + 6]
	pop	bp
	ret

	.balign	8
gdt:
	.quad	0
	.quad	0x00cf9a000000ffff	/* 0x08: code, 32 bits, all of memory */
	.quad	0x00cf92000000ffff	/* 0x10: data, all of memory */
gdtr:
	.word	3 * 8 - 1
	.long	0

	.code32
pm32:
	mov	ax, 0x10
	mov	ds, ax
	mov	es, ax
	mov	ss, ax
	mov	esp, 0x3f0000

	/* One page directory at 2 MiB and one page table after it: the
	   first 4 MiB, each page where it is. */
	mov	edi, 0x200000
	xor	eax, eax
	mov	ecx, 2048
	rep	stosd
	mov	dword ptr [0x200000], 0x201007
	mov	edi, 0x201000
	mov	eax, 7
	mov	ecx, 1024
1:	stosd
	add	eax, 0x1000
	dec	ecx
	jnz	1b
	mov	eax, 0x200000
	mov	cr3, eax
	mov	eax, cr0
	or	eax, 0x80000000
	mov	cr0, eax
	jmp	1f
1:

/* ---- 0xA6: arithmetic in registers, 32 bits ---------------------------- */
	mov	byte ptr [0x4f0], 0xa6
	mov	ecx, 250000
2:	add	eax, ebx
	xor	ebx, eax
	shl	eax, 1
	adc	ebx, 3
	cmp	eax, ebx
	jz	3f
3:	dec	ecx
	jnz	2b

/* ---- 0xA7: loads and stores, 32 bits ----------------------------------- */
	mov	byte ptr [0x4f0], 0xa7
	mov	edx, 3
1:	mov	esi, 0x300000
	mov	ecx, 0x10000		/* 256 KB, 64 pages */
2:	mov	eax, [esi]
	add	eax, [esi + 4]
	mov	[esi + 8], eax
	inc	dword ptr [esi + 12]
	mov	bl, [esi + 1]
	mov	[esi + 17], bl
	add	esi, 4
	dec	ecx
	jnz	2b
	dec	edx
	jnz	1b

/* ---- 0xA8: calls and the stack, 32 bits -------------------------------- */
	mov	byte ptr [0x4f0], 0xa8
	mov	ecx, 200000
2:	push	eax
	push	ebx
	call	addup32
	pop	ebx
	pop	eax
	dec	ecx
	jnz	2b

/* ---- 0xA9: a miss in the translation cache every time ------------------ */
	/* Pages n and n + 512 by turns: a cache of 512 entries that is
	   indexed by the page number has room for one of the two.  The
	   pages from 1 MiB up, to keep clear of the video memory. */
	mov	byte ptr [0x4f0], 0xa9
	mov	edx, 800
1:	mov	esi, 0x100000
	mov	ecx, 256
2:	mov	eax, [esi + 0x800]
	add	eax, [esi + 0x200800]
	add	esi, 0x1000
	dec	ecx
	jnz	2b
	dec	edx
	jnz	1b

	mov	byte ptr [0x4f0], 0xaf
9:	jmp	9b

addup32:
	push	ebp
	mov	ebp, esp
	mov	eax, [ebp + 8]
	add	eax, [ebp + 12]
	pop	ebp
	ret
