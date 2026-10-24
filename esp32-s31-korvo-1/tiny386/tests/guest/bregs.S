/*
 * BREGS.COM: the VGA's registers as DOS games use them, without the BIOS.
 *
 *   mode X       mode 13h unchained (each pixel in plane x mod 4) and made
 *                320x240 through the CRT controller; drawn plane by plane,
 *                read back plane by plane; a second page at 4B00h shown by
 *                moving the start address; a line copied with write mode 1,
 *                four planes at once through the latches
 *   split screen line compare at scan line 240: the top half page 2, the
 *                bottom half the start of video memory (page 0)
 *   panning      the attribute controller's horizontal pel panning (AR13h)
 *                in mode 12h; the preset row scan (CR08h) in text mode
 *   retrace      bit 3 of 3DAh counted for a second; the DAC rotated in the
 *                vertical retrace, mode 13h
 *
 * Every picture goes to the harness.
 *
 * Build:
 *   as --32 -I tests/guest -o bregs.o bregs.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BREGS.COM bregs.o
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

	.macro	OUTW port, value
	mov	dx, \port
	mov	ax, \value
	out	dx, ax
	.endm

main:
	cld
	/* ---- mode X */
	mov	ax, 0x0013
	int	0x10
	OUTW	0x3c4, 0x0604		/* chain 4 off */
	OUTW	0x3d4, 0x0014		/* doubleword mode off */
	OUTW	0x3d4, 0xe317		/* byte mode */
	OUTW	0x3c4, 0x0100		/* synchronous reset while the clock changes */
	mov	dx, 0x3c2
	mov	al, 0xe3		/* 480-line timing */
	out	dx, al
	OUTW	0x3c4, 0x0300
	mov	dx, 0x3d4		/* CR0-7 writable */
	mov	al, 0x11
	out	dx, al
	inc	dx
	in	al, dx
	and	al, 0x7f
	out	dx, al
	OUTW	0x3d4, 0x0d06
	OUTW	0x3d4, 0x3e07
	OUTW	0x3d4, 0x4109
	OUTW	0x3d4, 0xea10
	OUTW	0x3d4, 0xac11
	OUTW	0x3d4, 0xdf12
	OUTW	0x3d4, 0xe715
	OUTW	0x3d4, 0x0616
	/* all of video memory cleared, four planes at once */
	OUTW	0x3c4, 0x0f02
	push	0xa000
	pop	es
	xor	di, di
	xor	ax, ax
	mov	cx, 0x8000
	rep	stosw
	/* page 0 the bars; page 2 (4B00h) the bars the other way round */
	xor	di, di
	mov	si, offset fwd
	call	draw_x
	mov	di, 0x4b00
	mov	si, offset back
	call	draw_x
	/* read back: plane 1 at line 100, column 10 is pixel 41, bar 2 */
	OUTW	0x3ce, 0x0104
	CK8	regs.modex.read-plane1, es:[100*80+10], 2
	OUTW	0x3ce, 0x0304
	CK8	regs.modex.read-plane3, es:[100*80+79], 15
	CK8	regs.modex.read-page2, es:[0x4b00+100*80+10], 13
	SHOT	regs.modex
	/* page 2 shown */
	OUTW	0x3d4, 0x4b0c
	OUTW	0x3d4, 0x000d
	SHOT	regs.modex.page2
	/* ---- split screen: page 2 above, page 0 from scan line 240 on */
	OUTW	0x3d4, 0xf018		/* line compare 240: bits 8 and 9 are 0 */
	mov	dx, 0x3d4
	mov	al, 0x07
	out	dx, al
	inc	dx
	in	al, dx
	and	al, 0xef
	out	dx, al
	mov	dx, 0x3d4
	mov	al, 0x09
	out	dx, al
	inc	dx
	in	al, dx
	and	al, 0xbf
	out	dx, al
	SHOT	regs.split
	OUTW	0x3d4, 0xff18		/* no split */
	mov	dx, 0x3d4
	mov	al, 0x07
	out	dx, al
	inc	dx
	in	al, dx
	or	al, 0x10
	out	dx, al
	mov	dx, 0x3d4
	mov	al, 0x09
	out	dx, al
	inc	dx
	in	al, dx
	or	al, 0x40
	out	dx, al
	/* ---- write mode 1: page 0's line 0 (the white border) copied to
	   line 120, four planes a byte */
	OUTW	0x3d4, 0x000c
	OUTW	0x3ce, 0x4105		/* write mode 1 (and 256-colour shift) */
	OUTW	0x3c4, 0x0f02
	push	ds
	push	0xa000
	pop	ds
	xor	si, si
	mov	di, 120 * 80
	mov	cx, 80
	rep	movsb			/* each read loads the latches */
	pop	ds
	OUTW	0x3ce, 0x4005
	SHOT	regs.modex.latch-copy

	/* ---- AR13h: mode 12h's bars panned 3 pixels to the left */
	mov	ax, 0x0012
	int	0x10
	mov	bx, 80
	mov	cx, 480
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	mov	dx, 0x3da
	in	al, dx
	mov	dx, 0x3c0
	mov	al, 0x33		/* AR13h, the palette address source on */
	out	dx, al
	mov	al, 3
	out	dx, al
	mov	al, 0x13
	call	ar_read
	CK8	regs.pan.ar13, al, 3
	SHOT	regs.pan12

	/* ---- CR08h: text 5 scan lines up */
	mov	ax, 0x0003
	int	0x10
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	push	0xb800
	pop	es
	mov	cx, 0x1950
	xor	bl, bl
	call	draw_text
	mov	dx, 0x3d4
	mov	ax, 0x0508
	out	dx, ax
	mov	si, offset n_preset
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	regs.preset-row

	/* ---- the retrace: how many in a second */
	mov	ax, 0x0013
	int	0x10
	call	draw_chain4
	push	0x40
	pop	es
	mov	ax, es:[0x6c]
	add	ax, 18			/* about a second of the BIOS's clock */
	mov	[deadline], ax
	xor	cx, cx			/* retraces */
	xor	si, si			/* changes of display enable */
	mov	dx, 0x3da
	in	al, dx
	mov	ah, al
1:	in	al, dx
	mov	bl, al
	xor	bl, ah			/* what changed */
	test	bl, 0x01
	jz	2f
	inc	si
2:	test	bl, 0x08
	jz	3f
	test	al, 0x08
	jz	3f
	inc	cx			/* a retrace has begun */
3:	mov	ah, al
	mov	di, es:[0x6c]
	cmp	di, [deadline]
	jne	1b
	jmp	4f
deadline: .word	0
4:
	INFO16	regs.retrace.per-second, cx
	INFO16	regs.retrace.display-enable-changes, si
	cmp	cx, 30
	jb	5f
	cmp	cx, 120
	ja	5f
	OK	regs.retrace.counted, "30 to 120 a second"
	jmp	6f
5:	BAD	regs.retrace.counted, "not 30 to 120 a second"
6:
	/* ---- the DAC rotated, entries 1 to 15, once in each of 7 retraces */
	mov	cx, 7
7:	call	wait_retrace
	call	rotate
	loop	7b
	/* read back through the ports */
	mov	dx, 0x3c7
	mov	al, 1
	out	dx, al
	mov	dx, 0x3c9
	mov	di, offset readback
	push	cs
	pop	es
	mov	cx, 45
8:	in	al, dx
	stosb
	loop	8b
	mov	si, offset readback
	mov	di, offset dac + 3
	mov	cx, 45
	repe	cmpsb
	CKZ	regs.retrace.dac-read-back
	/* what the bars should be: entries 0 to 31 */
	PUTS	"@pal regs.retrace-palette "
	mov	si, offset dac
	mov	cx, 32 * 3
9:	lodsb
	call	puthex8
	loop	9b
	call	putnl
	SHOT	regs.retrace-palette

	mov	ax, 0x0003
	int	0x10
	DONE

n_preset: .asciz "regs.preset-row"
/* the colour of each of 16 bars: as they are, and the other way round */
fwd:	.byte	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
back:	.byte	15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
/* the DAC as mode 13h has it: EGA's sixteen, then a grey ramp */
dac:	.byte	0, 0, 0,  0, 0, 42,  0, 42, 0,  0, 42, 42
	.byte	42, 0, 0,  42, 0, 42,  42, 21, 0,  42, 42, 42
	.byte	21, 21, 21,  21, 21, 63,  21, 63, 21,  21, 63, 63
	.byte	63, 21, 21,  63, 21, 63,  63, 63, 21,  63, 63, 63
	.byte	0, 0, 0,  5, 5, 5,  8, 8, 8,  11, 11, 11
	.byte	14, 14, 14,  17, 17, 17,  20, 20, 20,  24, 24, 24
	.byte	28, 28, 28,  32, 32, 32,  36, 36, 36,  40, 40, 40
	.byte	45, 45, 45,  50, 50, 50,  56, 56, 56,  63, 63, 63
readback: .space 45

/*
 * draw_x: a mode X page at a000:di, 320x240: the bar of pixel x is x / 20,
 * its colour from the table at si, and a border in colour 15.  Plane by
 * plane: pixel x is in plane x mod 4, at x / 4 in its line.
 */
draw_x:
	pusha
	mov	[x_base], di
	mov	[x_tab], si
	mov	byte ptr [x_plane], 0
1:	mov	dx, 0x3c4
	mov	al, 2
	out	dx, al
	inc	dx
	mov	cl, [x_plane]
	mov	al, 1
	shl	al, cl
	out	dx, al
	mov	di, [x_base]
	xor	bp, bp			/* the line */
2:	xor	cx, cx			/* the column of 4 pixels */
3:	mov	ax, cx
	shl	ax, 2
	add	al, [x_plane]
	adc	ah, 0
	mov	bx, ax			/* x */
	mov	dl, 20
	div	dl
	movzx	si, al
	add	si, [x_tab]
	mov	al, [si]
	test	bp, bp
	jz	4f
	cmp	bp, 239
	je	4f
	test	bx, bx
	jz	4f
	cmp	bx, 319
	jne	5f
4:	mov	al, 15
5:	mov	es:[di], al
	inc	di
	inc	cx
	cmp	cx, 80
	jb	3b
	inc	bp
	cmp	bp, 240
	jb	2b
	inc	byte ptr [x_plane]
	cmp	byte ptr [x_plane], 4
	jb	1b
	popa
	ret
x_base:	.word	0
x_tab:	.word	0
x_plane: .byte	0

/* an attribute controller register: al the index, al its value */
ar_read:
	push	dx
	push	ax
	mov	dx, 0x3da
	in	al, dx
	pop	ax
	mov	dx, 0x3c0
	or	al, 0x20
	out	dx, al
	inc	dx
	in	al, dx
	push	ax
	mov	dx, 0x3da
	in	al, dx
	pop	ax
	pop	dx
	ret

/* until the vertical retrace begins */
wait_retrace:
	push	ax
	push	dx
	mov	dx, 0x3da
1:	in	al, dx
	test	al, 8
	jnz	1b
2:	in	al, dx
	test	al, 8
	jz	2b
	pop	dx
	pop	ax
	ret

/* DAC entries 1 to 15 rotated by one: entry i gets what i + 1 had, 15
   what 1 had; in dac and in the DAC */
rotate:
	pusha
	mov	ax, word ptr [dac + 3]
	mov	bl, [dac + 5]
	mov	si, offset dac + 6
	mov	di, offset dac + 3
	mov	cx, 14 * 3
	push	es
	push	cs
	pop	es
	rep	movsb
	pop	es
	mov	word ptr [dac + 45], ax
	mov	[dac + 47], bl
	mov	dx, 0x3c8
	mov	al, 1
	out	dx, al
	inc	dx
	mov	si, offset dac + 3
	mov	cx, 45
1:	lodsb
	out	dx, al
	loop	1b
	popa
	ret

	.include "draw.inc"
