/*
 * BFLOP.COM: int 13h on the floppy drive A:, an image of 80 cylinders, 2
 * heads and SPT sectors (18, 1.44M; built with --defsym SPT=9 as
 * BFLOP720.COM, 720K) that bioscheck.py has filled with a pattern.
 *
 * Functions 00h, 01h, 08h, 15h, 16h, 17h, 18h; reads (02h) over the end of
 * a track and of a cylinder, past the last sector of a track and past the
 * last cylinder, into a buffer over a 64K boundary; writes (03h); 04h; 05h
 * (format a track).  The names begin 13.fd.; the harness makes them
 * 13.fd144. or 13.fd720.  No screen.
 *
 * Build:
 *   as --32 -I tests/guest -o bflop.o bflop.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BFLOP.COM bflop.o
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
	.intel_syntax noprefix
	.code16
	.text
	.globl	_start
_start:
	jmp	main
	.include "bios.inc"
	.include "disk.inc"

	.ifndef	SPT
SPT	= 18
	.endif
DRIVE	= 0

	.macro	READ name, c, h, s, n, lba
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0200 | (\n)
	CHS	\c, \h, \s, DRIVE
	int	0x13
	CKNC	"\name"
	CK8	"\name\().count", al, \n
	pop	es
	DATA	"\name\().data", \lba, \n
	.endm

	.macro	WRITE name, c, h, s, n, lba
	push	es
	mov	es, [wseg]
	mov	eax, \lba
	mov	cx, \n
	mov	bh, 1
	call	fill_sectors
	call	say_wrote
	xor	bx, bx
	mov	ax, 0x0300 | (\n)
	CHS	\c, \h, \s, DRIVE
	int	0x13
	CKNC	"\name"
	CK8	"\name\().count", al, \n
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0200 | (\n)
	CHS	\c, \h, \s, DRIVE
	int	0x13
	pop	es
	DATA	"\name\().read-back", \lba, \n, 1
	.endm

/* a read that a drive should refuse: what came back */
	.macro	SHOULDFAIL name, c, h, s, n
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0200 | (\n)
	CHS	\c, \h, \s, DRIVE
	int	0x13
	pop	es
	CKC	"\name"
	.endm

main:
	cld
	call	disk_init
	int	0x11
	INFO16	13.fd.equipment, ax
	and	al, 0xc1
	CK8	13.fd.equipment-one-floppy, al, 0x01

	/* ---- 08h */
	push	es
	mov	ah, 0x08
	mov	dl, DRIVE
	xor	di, di
	int	0x13
	CKNC	13.fd.08
	INFO8	13.fd.08.type, bl
	CK8	13.fd.08.type-1.44m-drive, bl, 4
	CK8	13.fd.08.max-cylinder, ch, 79
	CK8	13.fd.08.sectors, cl, 18
	CK8	13.fd.08.max-head, dh, 1
	CK8	13.fd.08.drives, dl, 1
	CK8	13.fd.08.table-sectors, es:[di+4], 18
	CK8	13.fd.08.table-512, es:[di+3], 2
	pop	es

	/* ---- 15h, 16h */
	mov	ah, 0x15
	mov	dl, DRIVE
	int	0x13
	CKNC	13.fd.15
	INFO8	13.fd.15.type, ah
	cmp	ah, 1
	jb	1f
	cmp	ah, 2
	ja	1f
	OK	13.fd.15.a-floppy, "1 or 2"
	jmp	2f
1:	BAD	13.fd.15.a-floppy, "not 1 or 2"
2:	mov	ah, 0x16
	mov	dl, DRIVE
	int	0x13
	sbb	bx, bx
	INFO16	13.fd.16.ax, ax
	INFO16	13.fd.16.carry, bx
	cmp	ah, 0
	je	3f
	cmp	ah, 6
	je	3f
	BAD	13.fd.16.changed-or-not, "not 0 or 6"
	jmp	4f
3:	OK	13.fd.16.changed-or-not, "0 or 6"
4:
	/* ---- 00h, 01h */
	mov	ah, 0x00
	mov	dl, DRIVE
	int	0x13
	CKNC	13.fd.00
	mov	ah, 0x01
	mov	dl, DRIVE
	int	0x13
	CK8	13.fd.01, ah, 0

	/* ---- 02h */
	READ	13.fd.02.first, 0, 0, 1, 1, 0
	READ	13.fd.02.over-a-head, 0, 0, SPT-1, 4, SPT-2
	READ	13.fd.02.last, 79, 1, SPT, 1, 160*SPT-1
	READ	13.fd.02.whole-cylinder, 5, 0, 1, 2*SPT, 10*SPT
	/* what a floppy controller does not do: over the end of a cylinder
	   in one go, a sector past the end of the track, a cylinder past the
	   end of the disk */
	READ	13.fd.02.over-a-cylinder, 0, 1, SPT, 2, 2*SPT-1
	SHOULDFAIL 13.fd.02.past-the-track-refused, 0, 0, SPT+1, 1
	/* and if it was not, whose sector came: the next track's first? */
	push	es
	mov	es, [bufseg]
	mov	eax, SPT
	mov	cx, 1
	xor	bh, bh
	call	verify
	pop	es
	jnz	6f
	PUTS	"@info 13.fd.02.past-the-track.data cylinder 0, head 1, sector 1\n"
	jmp	7f
6:	PUTS	"@info 13.fd.02.past-the-track.data not the next track's first\n"
7:
	SHOULDFAIL 13.fd.02.past-the-disk-refused, 80, 0, 1, 1
	/* into a buffer over a 64K boundary of memory: a PC's DMA controller
	   cannot, and the BIOS says so (09h) */
	mov	ax, [bufseg]
	add	ax, 0x1020
	and	ax, 0xf000		/* a 64K boundary in the buffers' 128K */
	sub	ax, 0x0020		/* 512 bytes before it */
	push	es
	mov	es, ax
	xor	bx, bx
	mov	ax, 0x0202
	CHS	0, 0, 1, DRIVE
	int	0x13
	pop	es
	sbb	bx, bx
	INFO16	13.fd.02.over-64k-boundary.ax, ax
	INFO16	13.fd.02.over-64k-boundary.carry, bx

	/* ---- 03h */
	WRITE	13.fd.03.three, 2, 1, 5, 3, 5*SPT+4
	WRITE	13.fd.03.over-a-head, 3, 0, SPT, 2, 7*SPT-1

	/* ---- 04h */
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0402
	CHS	0, 0, 1, DRIVE
	int	0x13
	pop	es
	CKNC	13.fd.04

	/* ---- 05h: cylinder 10, head 0 formatted; a floppy then holds F6h
	   in every byte of the track */
	push	es
	push	cs
	pop	es
	mov	di, offset fmt
	mov	cx, SPT
	mov	ax, 0x000a		/* cylinder 10, head 0 */
	mov	bl, 1
5:	stosw
	mov	al, bl
	mov	ah, 2			/* 512 bytes */
	stosw
	mov	ax, 0x000a
	inc	bl
	loop	5b
	mov	ax, 0x0500 | SPT
	mov	bx, offset fmt
	CHS	10, 0, 1, DRIVE
	int	0x13
	pop	es
	CKNC	13.fd.05
	PUTS	"@ignore "
	mov	eax, 20 * SPT
	call	puthex32
	call	putsp
	mov	ax, SPT
	call	puthex16
	call	putnl
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0201
	CHS	10, 0, 1, DRIVE
	int	0x13
	xor	di, di
	mov	al, 0xf6
	mov	cx, 512
	repe	scasb
	pop	es
	CKZ	13.fd.05.f6-in-the-sector

	/* ---- 17h, 18h */
	mov	ax, 0x1704
	mov	dl, DRIVE
	int	0x13
	sbb	bx, bx
	INFO16	13.fd.17.ax, ax
	INFO16	13.fd.17.carry, bx
	push	es
	mov	ah, 0x18
	mov	cx, (79 << 8) | SPT
	mov	dl, DRIVE
	int	0x13
	CKNC	13.fd.18
	INFO8	13.fd.18.table-sectors, es:[di+4]
	pop	es

	/* ---- drive B:, which is not there */
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0201
	CHS	0, 0, 1, 1
	int	0x13
	pop	es
	CKC	13.fd.b-absent-refused
	INFO16	13.fd.b-absent.ax, ax
	DONE

fmt:	.space	4 * 18
