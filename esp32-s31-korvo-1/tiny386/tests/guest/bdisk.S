/*
 * BDISK.COM: int 13h on a hard disk, drive 81h: a second disk, an image of
 * 300 cylinders, 16 heads and 63 sectors that bioscheck.py has filled with
 * a pattern in three places (cylinders 0 to 3, 255 and 256, and 299).
 *
 * Functions 00h, 01h, 08h, 09h, 0Ch, 0Dh, 10h, 11h, 14h, 15h; reads (02h)
 * and writes (03h) by cylinder, head and sector, over the end of a track,
 * of a cylinder, and of cylinder 255 (which needs the top two bits in CL);
 * 04h; the extensions 41h to 49h with LBA reads and writes.  What is read
 * is held against the pattern; what is written is the written pattern, and
 * the harness looks for it in the image afterwards (@wrote).  No screen.
 *
 * Build:
 *   as --32 -I tests/guest -o bdisk.o bdisk.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BDISK.COM bdisk.o
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

DRIVE	= 0x81
TOTAL	= 300 * 16 * 63		/* sectors */

/* READ NAME, C, H, S, N, LBA: N sectors from C/H/S, which should be LBA */
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

/* WRITE NAME, C, H, S, N, LBA: the written pattern for LBA on, N sectors
   to C/H/S; read back */
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

/* EXT NAME, AH, AL, LBA, N, SEGMENT: an extended read or write with the
   disk address packet */
	.macro	EXT ah, al, lba, n, seg
	mov	byte ptr [dap], 16
	mov	byte ptr [dap + 1], 0
	mov	word ptr [dap + 2], \n
	mov	word ptr [dap + 4], 0
	mov	ax, [\seg]
	mov	[dap + 6], ax
	mov	dword ptr [dap + 8], \lba
	mov	dword ptr [dap + 12], 0
	mov	ax, (\ah << 8) | \al
	mov	dl, DRIVE
	mov	si, offset dap
	int	0x13
	.endm

main:
	cld
	call	disk_init
	push	0
	pop	es
	INFO32	13.hd.vector, es:[0x13*4]
	push	0x40
	pop	es
	CK8	13.hd.bda-count, es:[0x75], 2

	/* ---- 08h: the geometry */
	mov	ah, 0x08
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.08
	CK8	13.hd.08.ah, ah, 0
	mov	al, cl
	and	al, 0x3f
	CK8	13.hd.08.sectors, al, 63
	CK8	13.hd.08.heads, dh, 15
	CK8	13.hd.08.drives, dl, 2
	movzx	ax, cl
	shl	ax, 2
	mov	al, ch			/* the top two bits from CL, the rest CH */
	INFO16	13.hd.08.max-cylinder, ax
	cmp	ax, 298
	jb	1f
	cmp	ax, 299
	ja	1f
	OK	13.hd.08.cylinders, "299, or 298 with one kept back"
	jmp	2f
1:	BAD	13.hd.08.cylinders, "not 298 or 299"
2:
	/* ---- 15h: a hard disk, and how many sectors */
	mov	ah, 0x15
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.15
	CK8	13.hd.15.type, ah, 3
	mov	ax, cx
	shl	eax, 16
	mov	ax, dx
	INFO32	13.hd.15.sectors, eax

	/* ---- what has no answer but yes */
	mov	ah, 0x00
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.00
	mov	ah, 0x0d
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.0d
	mov	ah, 0x10
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.10
	mov	ah, 0x11
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.11
	mov	ah, 0x0c
	CHS	5, 0, 1, DRIVE
	int	0x13
	CKNC	13.hd.0c
	mov	ah, 0x09
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.09
	mov	ah, 0x14
	mov	dl, DRIVE
	int	0x13
	INFO16	13.hd.14.ax, ax

	/* ---- 01h: the status of what went before */
	mov	ah, 0x01
	mov	dl, DRIVE
	int	0x13
	CK8	13.hd.01.after-success, ah, 0
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0201
	CHS	0, 0, 0, DRIVE		/* sector 0: there is none */
	int	0x13
	pop	es
	CKC	13.hd.02.sector-0-refused
	mov	ah, 0x01
	mov	dl, DRIVE
	int	0x13
	CK8	13.hd.01.after-error, ah, 0x01
	INFO16	13.hd.01.after-error-ax, ax
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0201
	CHS	300, 0, 1, DRIVE	/* past the last cylinder */
	int	0x13
	pop	es
	CKC	13.hd.02.cylinder-300-refused

	/* ---- 02h */
	READ	13.hd.02.first, 0, 0, 1, 1, 0
	READ	13.hd.02.over-a-head, 0, 0, 62, 4, 61
	READ	13.hd.02.over-a-cylinder, 0, 15, 62, 4, 1006
	READ	13.hd.02.over-cylinder-255, 255, 15, 63, 2, 258047
	READ	13.hd.02.cylinder-256, 256, 3, 10, 3, 258048+3*63+9
	READ	13.hd.02.last, 299, 15, 63, 1, 302399
	READ	13.hd.02.127-sectors, 0, 0, 1, 127, 0

	/* the same over cylinder 255 by LBA (42h), before 03h writes there */
	EXT	0x42, 0, 258047, 2, bufseg
	CKNC	13.hd.42.over-cylinder-255
	DATA	13.hd.42.over-cylinder-255.data, 258047, 2

	/* ---- 03h */
	WRITE	13.hd.03.over-a-head, 1, 5, 61, 4, 1383
	WRITE	13.hd.03.cylinder-256, 256, 0, 1, 1, 258048

	/* ---- 04h */
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0404
	CHS	0, 0, 1, DRIVE
	int	0x13
	pop	es
	CKNC	13.hd.04
	CK8	13.hd.04.count, al, 4

	/* ---- the extensions: 41h */
	mov	ah, 0x41
	mov	bx, 0x55aa
	mov	dl, DRIVE
	int	0x13
	CKNC	13.hd.41
	CK16	13.hd.41.bx, bx, 0xaa55
	INFO8	13.hd.41.version, ah
	INFO16	13.hd.41.cx-interfaces, cx
	and	cx, 1
	CK16	13.hd.41.packet-access, cx, 1

	/* 42h: three sectors at 1000, and two over cylinder 255 */
	EXT	0x42, 0, 1000, 3, bufseg
	CKNC	13.hd.42
	CK16	13.hd.42.count-back, [dap+2], 3
	DATA	13.hd.42.data, 1000, 3
	EXT	0x42, 0, TOTAL, 1, bufseg
	CKC	13.hd.42.past-the-end-refused

	/* 43h: two at 2000, then read back by C/H/S: 2000 is 1/15/48 */
	push	es
	mov	es, [wseg]
	mov	eax, 2000
	mov	cx, 2
	mov	bh, 1
	call	fill_sectors
	call	say_wrote
	pop	es
	EXT	0x43, 0, 2000, 2, wseg
	CKNC	13.hd.43
	push	es
	mov	es, [bufseg]
	xor	bx, bx
	mov	ax, 0x0202
	CHS	1, 15, 48, DRIVE
	int	0x13
	pop	es
	DATA	13.hd.43.read-by-chs, 2000, 2, 1
	/* 43h with verify (AL=1), one at 2010 */
	push	es
	mov	es, [wseg]
	mov	eax, 2010
	mov	cx, 1
	mov	bh, 1
	call	fill_sectors
	call	say_wrote
	pop	es
	EXT	0x43, 1, 2010, 1, wseg
	CKNC	13.hd.43.verify
	EXT	0x42, 0, 2010, 1, bufseg
	DATA	13.hd.43.verify.read-back, 2010, 1, 1

	/* 44h, 47h */
	EXT	0x44, 0, 0, 4, bufseg
	CKNC	13.hd.44
	EXT	0x47, 0, 3000, 0, bufseg
	CKNC	13.hd.47

	/* 48h: the drive's parameters, 1Ah and 1Eh bytes */
	mov	word ptr [params], 0x1a
	mov	ah, 0x48
	mov	dl, DRIVE
	mov	si, offset params
	int	0x13
	CKNC	13.hd.48
	INFO16	13.hd.48.size, [params]
	INFO16	13.hd.48.flags, [params+2]
	INFO32	13.hd.48.cylinders, [params+4]
	INFO32	13.hd.48.heads, [params+8]
	INFO32	13.hd.48.sectors, [params+12]
	CK32	13.hd.48.total, [params+16], TOTAL
	CK32	13.hd.48.total-high, [params+20], 0
	CK16	13.hd.48.bytes, [params+24], 512
	mov	word ptr [params], 0x1e
	mov	ah, 0x48
	mov	dl, DRIVE
	mov	si, offset params
	int	0x13
	CKNC	13.hd.48.edd2
	INFO32	13.hd.48.edd2.dpte, [params+26]

	/* 45h, 46h, 49h, 4Eh: for removable media; only what is said */
	mov	ax, 0x4500
	mov	dl, DRIVE
	int	0x13
	pushf
	INFO16	13.hd.45.ax, ax
	popf
	sbb	ax, ax
	INFO16	13.hd.45.carry, ax
	mov	ax, 0x4600
	mov	dl, DRIVE
	int	0x13
	sbb	bx, bx
	INFO16	13.hd.46.ax, ax
	INFO16	13.hd.46.carry, bx
	mov	ah, 0x49
	mov	dl, DRIVE
	int	0x13
	sbb	bx, bx
	INFO16	13.hd.49.ax, ax
	INFO16	13.hd.49.carry, bx
	mov	ax, 0x4e08
	mov	dl, DRIVE
	int	0x13
	sbb	bx, bx
	INFO16	13.hd.4e.ax, ax
	INFO16	13.hd.4e.carry, bx

	/* ---- the FreeDOS disk, drive 80h, for the record */
	mov	ah, 0x08
	mov	dl, 0x80
	int	0x13
	INFO16	13.hd80.08.cx, cx
	INFO16	13.hd80.08.dx, dx
	DONE

dap:	.space	16
params:	.space	0x42
