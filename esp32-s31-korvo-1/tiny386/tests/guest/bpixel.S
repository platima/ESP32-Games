/*
 * BPIXEL.COM: pixels through int 10h AH=0Ch (write) and 0Dh (read) in
 * every graphics mode of a VGA, with XOR (bit 7 of the colour) where the
 * mode has it; and scrolling (AH=06h and 07h) in modes 12h and 13h.
 *
 * In each mode a few pixels are written at the corners, the middle and
 * either side of a byte's edge, and read back; then written again with
 * XOR.  In mode 13h one is read straight from video memory as well.  Two
 * pictures (modes 12h and 13h) show the pixels, listed as @gpixel X Y
 * COLOUR.  For scrolling the screen is striped across, a stripe a
 * character row high with its own colour, a window of it is scrolled, and
 * every eighth pixel of the screen is read back with 0Dh and held against
 * what the scroll should have left.
 *
 * Build:
 *   as --32 -I tests/guest -o bpixel.o bpixel.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BPIXEL.COM bpixel.o
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

/* PIXELS M, W, H, COLOURS, XOR: the pixels of the table in mode M,
   W x H, colours anded with COLOURS - 1; XOR 1 if the mode has it */
	.macro	PIXELS m, w, h, colours, xor
	mov	ax, 0x00\m
	int	0x10
	mov	word ptr [p_w], \w
	mov	word ptr [p_h], \h
	mov	byte ptr [p_mask], \colours - 1
	mov	byte ptr [p_xor], \xor
	mov	si, offset .Ln\@
	call	pixels
	jmp	.Le\@
.Ln\@:	.asciz	"10.0c.m\m"
.Le\@:
	.endm

main:
	cld
	PIXELS	04, 320, 200, 4, 1
	PIXELS	05, 320, 200, 4, 1
	PIXELS	06, 640, 200, 2, 1
	PIXELS	0d, 320, 200, 16, 1
	PIXELS	0e, 640, 200, 16, 1
	PIXELS	0f, 640, 350, 4, 1
	PIXELS	10, 640, 350, 16, 1
	PIXELS	11, 640, 480, 2, 1
	mov	byte ptr [p_shot], 1	/* the pixels of these two are looked at */
	PIXELS	12, 640, 480, 16, 1
	SHOT	10.0c.m12
	PIXELS	13, 320, 200, 256, 0
	/* and one of them in video memory: 13h is a byte a pixel */
	push	es
	push	0xa000
	pop	es
	CK8	10.0c.m13.memory, es:[100*320+160], 0x15
	pop	es
	SHOT	10.0c.m13

	/* ---- a page that is not shown: mode 0Dh has 8 */
	mov	ax, 0x000d
	int	0x10
	mov	ax, 0x0c0e
	mov	bh, 1
	mov	cx, 10
	mov	dx, 10
	int	0x10
	mov	ax, 0x0d00
	mov	bh, 1
	mov	cx, 10
	mov	dx, 10
	int	0x10
	CK8	10.0c.m0d.page1, al, 0x0e
	mov	ax, 0x0d00
	mov	bh, 0
	mov	cx, 10
	mov	dx, 10
	int	0x10
	CK8	10.0c.m0d.page0-untouched, al, 0

	/* ---- scrolling: mode 13h (8 lines a character row) and 12h (16) */
	mov	ax, 0x0013
	int	0x10
	mov	byte ptr [s_ch], 8
	mov	word ptr [s_w], 320
	mov	word ptr [s_h], 200
	call	stripes13
	/* up 3 rows in rows 5 to 15, columns 4 to 30; colour 0C9h in */
	mov	ax, 0x0603
	mov	bh, 0xc9
	mov	cx, 0x0504
	mov	dx, 0x0f1e
	call	scroll_and_check
	mov	si, offset n_up13
	call	report
	/* down 2 rows in rows 2 to 9, columns 0 to 39 (the whole width) */
	call	stripes13
	mov	ax, 0x0702
	mov	bh, 0x2c
	mov	cx, 0x0200
	mov	dx, 0x0927
	call	scroll_and_check
	mov	si, offset n_down13
	call	report

	mov	ax, 0x0012
	int	0x10
	mov	byte ptr [s_ch], 16
	mov	word ptr [s_w], 640
	mov	word ptr [s_h], 480
	call	stripes12
	mov	ax, 0x0602
	mov	bh, 0x0e
	mov	cx, 0x0308
	mov	dx, 0x1a40
	call	scroll_and_check
	mov	si, offset n_up12
	call	report
	call	stripes12
	mov	ax, 0x0701
	mov	bh, 0x09
	mov	cx, 0x0000
	mov	dx, 0x1d4f
	call	scroll_and_check
	mov	si, offset n_down12
	call	report

	mov	ax, 0x0003
	int	0x10
	DONE

n_up13:	  .asciz "10.06.m13.window"
n_down13: .asciz "10.07.m13.window"
n_up12:	  .asciz "10.06.m12.window"
n_down12: .asciz "10.07.m12.window"

p_w:	.word	0
p_h:	.word	0
p_mask:	.byte	0
p_xor:	.byte	0
/* where, and in which colour: x as a fraction of the width (w * a / 8 +
   b), the same for y, and a colour, which is anded with the mode's mask */
ptab:	.byte	0, 0,  0, 0,  1	/* top left */
	.byte	8, -1, 0, 0,  2	/* top right */
	.byte	0, 0,  8, -1, 3	/* bottom left */
	.byte	8, -1, 8, -1, 14 /* bottom right */
	.byte	4, 0,  4, 0,  0x15 /* the middle */
	.byte	0, 7,  0, 1,  9	/* either side of a byte's edge */
	.byte	0, 8,  0, 1,  12
	.byte	2, 3,  6, 5,  0x17
	.byte	0xff

/* x of a table entry at si: ax */
p_x:
	movzx	ax, byte ptr [si]
	mul	word ptr [p_w]
	shr	ax, 3
	movsx	dx, byte ptr [si + 1]
	add	ax, dx
	ret
p_y:
	movzx	ax, byte ptr [si + 2]
	mul	word ptr [p_h]
	shr	ax, 3
	movsx	dx, byte ptr [si + 3]
	add	ax, dx
	ret

/* the table's pixels written and read back, then XOR; cs:si the name's
   start (10.0c.mNN) */
pixels:
	pusha
	mov	[p_name], si
	mov	si, offset ptab
	xor	bp, bp			/* how many were wrong */
1:	cmp	byte ptr [si], 0xff
	je	2f
	call	p_y
	push	ax
	call	p_x
	mov	cx, ax
	pop	dx
	mov	al, [si + 4]
	and	al, [p_mask]
	mov	ah, 0x0c
	xor	bh, bh
	int	0x10
	mov	ah, 0x0d
	xor	bh, bh
	push	ax
	int	0x10
	mov	bl, al
	pop	ax
	cmp	bl, al
	je	3f
	inc	bp
3:	cmp	byte ptr [p_shot], 0
	je	4f
	PUTS	"@gpixel x "
	mov	ax, cx
	call	puthex16
	call	putsp
	mov	ax, dx
	call	puthex16
	call	putsp
	mov	al, [si + 4]
	and	al, [p_mask]
	call	puthex8
	call	putnl
4:	add	si, 5
	jmp	1b
2:	mov	si, [p_name]
	PUTS	"@"
	test	bp, bp
	jz	5f
	PUTS	"bad "
	call	puts
	PUTS	".read-back pixels wrong: "
	mov	ax, bp
	call	puthex16
	call	putnl
	jmp	6f
5:	PUTS	"ok "
	call	puts
	PUTS	".read-back\n"
6:	cmp	byte ptr [p_xor], 0
	je	9f
	/* the first pixel again with XOR 3 (anded with the mask): 1 xor 3 */
	mov	al, 3
	and	al, [p_mask]
	or	al, 0x80
	mov	ah, 0x0c
	xor	bh, bh
	xor	cx, cx
	xor	dx, dx
	int	0x10
	mov	ax, 0x0d00
	xor	bh, bh
	int	0x10
	mov	ah, 1
	xor	ah, 3
	and	ah, [p_mask]
	PUTS	"@"
	cmp	al, ah
	jne	7f
	PUTS	"ok "
	call	puts
	PUTS	".xor\n"
	jmp	8f
7:	PUTS	"bad "
	call	puts
	PUTS	".xor got="
	call	puthex8
	PUTS	" want="
	mov	al, ah
	call	puthex8
	call	putnl
8:	/* and back, so that the picture is the table's */
	mov	al, 3
	and	al, [p_mask]
	or	al, 0x80
	mov	ah, 0x0c
	xor	bh, bh
	xor	cx, cx
	xor	dx, dx
	int	0x10
9:	popa
	ret
p_name:	.word	0
p_shot:	.byte	0

/* ---- scrolling */

s_ch:	.byte	0		/* lines a character row */
s_w:	.word	0
s_h:	.word	0
s_win:	.word	0, 0		/* the window: cx, dx as given */
s_n:	.byte	0
s_fill:	.byte	0
s_down:	.byte	0
s_nbad:	.word	0
s_first: .word	0, 0, 0		/* x, y, got and wanted */

/* mode 13h striped: row r of characters (8 lines) in colour 20h + r */
stripes13:
	pusha
	push	es
	push	0xa000
	pop	es
	xor	di, di
	xor	dx, dx
1:	mov	ax, dx
	shr	ax, 3
	add	al, 0x20
	mov	cx, 320
	rep	stosb
	inc	dx
	cmp	dx, 200
	jb	1b
	pop	es
	popa
	ret

/* mode 12h striped: row r (16 lines) in colour r and 15, anded with 15 */
stripes12:
	pusha
	push	es
	push	0xa000
	pop	es
	mov	dx, 0x3ce
	mov	ax, 0x0205
	out	dx, ax
	mov	ax, 0xff08
	out	dx, ax
	mov	dx, 0x3c4
	mov	ax, 0x0f02
	out	dx, ax
	xor	di, di
	xor	dx, dx
1:	mov	ax, dx
	shr	ax, 4
	and	al, 15
	mov	cx, 80
	rep	stosb
	inc	dx
	cmp	dx, 480
	jb	1b
	mov	dx, 0x3ce
	mov	ax, 0x0005
	out	dx, ax
	pop	es
	popa
	ret

/* the colour that the stripes give line y (dx): al */
stripe_at:
	mov	ax, dx
	cmp	byte ptr [s_ch], 8
	jne	1f
	shr	ax, 3
	add	al, 0x20
	ret
1:	shr	ax, 4
	and	al, 15
	ret

/* AH=06h or 07h as given (ax, bh, cx, dx); then every eighth pixel of
   the screen through 0Dh, against what should be there */
scroll_and_check:
	pusha
	mov	[s_win], cx
	mov	[s_win + 2], dx
	mov	[s_fill], bh
	mov	[s_n], al
	mov	byte ptr [s_down], 0
	cmp	ah, 7
	jne	1f
	mov	byte ptr [s_down], 1
1:	int	0x10
	mov	word ptr [s_nbad], 0
	xor	dx, dx			/* y */
2:	xor	cx, cx			/* x */
3:	call	wanted			/* al */
	push	ax
	mov	ax, 0x0d00
	xor	bh, bh
	int	0x10
	pop	bx
	cmp	al, bl
	je	4f
	cmp	word ptr [s_nbad], 0
	jne	5f
	mov	[s_first], cx
	mov	[s_first + 2], dx
	mov	[s_first + 4], al
	mov	[s_first + 5], bl
5:	inc	word ptr [s_nbad]
4:	add	cx, 8
	cmp	cx, [s_w]
	jb	3b
	add	dx, 3
	cmp	dx, [s_h]
	jb	2b
	popa
	ret

/* the colour that should be at cx, dx after the scroll: al */
wanted:
	push	bx
	push	cx
	push	dx
	push	si
	/* in the window?  rows ch..dh of s_win, columns cl..dl */
	mov	ax, cx
	shr	ax, 3			/* the column */
	mov	si, dx
	mov	bl, [s_ch]
	push	ax
	mov	ax, dx
	div	bl
	movzx	bx, al			/* the row */
	pop	ax
	cmp	al, [s_win]		/* cl: left */
	jb	9f
	cmp	al, [s_win + 2]		/* dl: right */
	ja	9f
	cmp	bl, [s_win + 1]		/* ch: top */
	jb	9f
	cmp	bl, [s_win + 3]		/* dh: bottom */
	ja	9f
	/* inside: which line it comes from */
	movzx	ax, byte ptr [s_n]
	movzx	cx, byte ptr [s_ch]
	imul	ax, cx			/* lines moved; dx kept */
	cmp	byte ptr [s_down], 0
	jne	1f
	add	dx, ax			/* up: from below */
	mov	ax, dx
	movzx	cx, byte ptr [s_ch]
	push	dx
	xor	dx, dx
	div	cx
	pop	dx
	cmp	al, [s_win + 3]
	ja	8f			/* past the bottom: filled */
	jmp	7f
1:	sub	dx, ax			/* down: from above */
	jc	8f
	mov	ax, dx
	movzx	cx, byte ptr [s_ch]
	push	dx
	xor	dx, dx
	div	cx
	pop	dx
	cmp	al, [s_win + 1]
	jb	8f
7:	call	stripe_at
	jmp	6f
8:	mov	al, [s_fill]
	cmp	byte ptr [s_ch], 8
	je	6f
	and	al, 15
	jmp	6f
9:	call	stripe_at
6:	pop	si
	pop	dx
	pop	cx
	pop	bx
	ret

/* @ok or @bad cs:si after a scroll_and_check */
report:
	cmp	word ptr [s_nbad], 0
	jne	1f
	call	say_ok
	call	putnl
	ret
1:	call	say_bad
	PUTS	" pixels wrong: "
	mov	ax, [s_nbad]
	call	puthex16
	PUTS	", the first at "
	mov	ax, [s_first]
	call	puthex16
	mov	al, ','
	call	putc
	mov	ax, [s_first + 2]
	call	puthex16
	PUTS	" got="
	mov	al, [s_first + 4]
	call	puthex8
	PUTS	" want="
	mov	al, [s_first + 5]
	call	puthex8
	call	putnl
	ret
