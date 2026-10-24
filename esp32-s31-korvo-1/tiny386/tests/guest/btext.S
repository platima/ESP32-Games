/*
 * BTEXT.COM: int 10h in a text mode (03h, 80x25): cursor shape and
 * position (01h to 03h), the active page (05h), scrolling up and down (06h,
 * 07h), reading and writing characters (08h to 0Ah), teletype (0Eh) and
 * write string (13h).
 *
 * The program keeps a copy of the screen of its own (the model), does to it
 * what each call should have done, and compares the two.  The CRT
 * controller's registers are read back through its ports.  Four pictures
 * go to the harness: page 1 shown, the screen at the end against its memory,
 * and the cursor, as a block and as it is after a mode set (the harness
 * looks at the cursor several times, since it blinks).
 *
 * Build:
 *   as --32 -I tests/guest -o btext.o btext.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BTEXT.COM btext.o
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

/* CMP NAME: the screen against the model */
	.macro	CMPSCR name
	push	si
	mov	si, offset .Ln\@
	call	cmp_screen
	pop	si
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* SETPOS ROW, COL[, PAGE] */
	.macro	SETPOS row, col, page=0
	push	ax
	push	bx
	push	dx
	mov	ah, 2
	mov	bh, \page
	mov	dx, (\row << 8) | \col
	int	0x10
	pop	dx
	pop	bx
	pop	ax
	.endm

/* GETPOS [PAGE]: dx the cursor, cx its shape */
	.macro	GETPOS page=0
	push	ax
	push	bx
	mov	ah, 3
	mov	bh, \page
	int	0x10
	pop	bx
	pop	ax
	.endm

main:
	cld
	mov	ax, cs
	add	ax, 0x1000
	mov	[mseg], ax
	mov	ax, 0x0003
	int	0x10
	push	0x40
	pop	es

	/* ---- 01h: the cursor's shape, in the BIOS data area and the CRT
	   controller.  0607h is the shape of CGA, which a VGA with 16 lines
	   a character shows as lines 13 and 14. */
	CK16	10.01.after-mode-bda, es:[0x60], 0x0607
	call	crtc_cursor
	CK16	10.01.after-mode-crtc, ax, 0x0d0e
	mov	ah, 1
	mov	cx, 0x000f
	int	0x10
	CK16	10.01.000f-bda, es:[0x60], 0x000f
	call	crtc_cursor
	CK16	10.01.000f-crtc, ax, 0x000f
	mov	ah, 1
	mov	cx, 0x0607
	int	0x10
	call	crtc_cursor
	CK16	10.01.0607-crtc, ax, 0x0d0e
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	call	crtc_cursor
	and	ah, 0x20
	CK8	10.01.hidden-crtc, ah, 0x20
	mov	ah, 1
	mov	cx, 0x0607
	int	0x10

	/* ---- 02h and 03h: where it is, on two pages */
	SETPOS	5, 10
	CK16	10.02.bda-page0, es:[0x50], 0x050a
	call	crtc_curpos
	CK16	10.02.crtc, ax, 5*80+10
	SETPOS	3, 7, 1
	CK16	10.02.bda-page1, es:[0x52], 0x0307
	call	crtc_curpos
	CK16	10.02.crtc-not-for-page1, ax, 5*80+10
	GETPOS	0
	CK16	10.03.page0, dx, 0x050a
	CK16	10.03.shape, cx, 0x0607
	GETPOS	1
	CK16	10.03.page1, dx, 0x0307

	/* the screens to work on: page 0 as draw_text has it, page 1 the
	   same with other characters in yellow on blue */
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	push	0xb800
	pop	es
	mov	cx, 0x1950
	xor	bl, bl
	call	draw_text
	push	0xb900
	pop	es
	call	draw_text
	xor	di, di
	mov	cx, 2000
1:	mov	al, es:[di]
	sub	al, '!' - 47
	cmp	al, 94
	jb	2f
	sub	al, 94
2:	add	al, '!'
	mov	ah, 0x1e
	stosw
	loop	1b

	/* ---- 05h: page 1 shown, and back */
	mov	ax, 0x0501
	int	0x10
	push	0x40
	pop	es
	CK8	10.05.bda-page, es:[0x62], 1
	CK16	10.05.bda-start, es:[0x4e], 0x1000
	call	crtc_start
	CK16	10.05.crtc-start, ax, 0x0800
	call	crtc_curpos
	CK16	10.05.crtc-cursor, ax, 0x0800+3*80+7
	mov	ah, 0x0f
	int	0x10
	CK8	10.0f.page, bh, 1
	push	0xb900
	pop	es
	mov	si, offset n_page1
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.05.page1
	mov	ax, 0x0500
	int	0x10
	call	crtc_start
	CK16	10.05.back-to-0, ax, 0

	/* ---- 06h: up, in a window, by 2 lines, then clearing one (AL 0),
	   then the whole screen by a line */
	call	save_screen
	mov	ax, 0x0602
	mov	bh, 0x1e
	mov	cx, 0x050a
	mov	dx, 0x0f3c
	int	0x10
	call	model_up
	CMPSCR	10.06.window
	mov	ax, 0x0600
	mov	bh, 0x47
	mov	cx, 0x1400
	mov	dx, 0x164f
	int	0x10
	call	model_up
	CMPSCR	10.06.clear
	mov	ax, 0x0601
	mov	bh, 0x07
	xor	cx, cx
	mov	dx, 0x184f
	int	0x10
	call	model_up
	CMPSCR	10.06.whole

	/* ---- 07h: down, by 3 lines and clearing */
	mov	ax, 0x0703
	mov	bh, 0x2f
	mov	cx, 0x0205
	mov	dx, 0x0a46
	int	0x10
	call	model_down
	CMPSCR	10.07.window
	mov	ax, 0x0700
	mov	bh, 0x5a
	mov	cx, 0x1000
	mov	dx, 0x1104
	int	0x10
	call	model_down
	CMPSCR	10.07.clear

	/* ---- 08h: the character and attribute at the cursor, on each page */
	SETPOS	7, 33
	mov	dx, 0x0721
	call	mget
	mov	ah, 8
	xor	bh, bh
	int	0x10
	CK16	10.08.page0, ax, cx
	push	es
	push	0xb900
	pop	es
	mov	cx, es:[(3 * 80 + 7) * 2]
	pop	es
	mov	ah, 8
	mov	bh, 1
	int	0x10
	CK16	10.08.page1, ax, cx

	/* ---- 09h: 15 of Z in 4Eh from 8,70, over the end of the line; the
	   cursor stays */
	SETPOS	8, 70
	mov	ax, 0x095a
	mov	bx, 0x004e
	mov	cx, 15
	int	0x10
	mov	dx, 0x0846
	mov	cx, 15
	mov	ax, 0x4e5a
1:	call	mset
	call	mnext
	loop	1b
	CMPSCR	10.09.write
	GETPOS
	CK16	10.09.cursor-stays, dx, 0x0846

	/* ---- 0Ah: 5 of Q, keeping each cell's attribute */
	SETPOS	9, 10
	mov	ax, 0x0a51
	xor	bh, bh
	mov	cx, 5
	int	0x10
	mov	dx, 0x090a
	mov	cx, 5
	mov	al, 'Q'
1:	call	mput_char
	call	mnext
	loop	1b
	CMPSCR	10.0a.write

	/* ---- 0Eh: a, b, backspace, c; then CR, LF and BEL */
	SETPOS	3, 10
	mov	si, offset s_abc
	call	tty
	mov	dx, 0x030a
	mov	al, 'a'
	call	mput_char
	inc	dl
	mov	al, 'c'
	call	mput_char
	GETPOS
	CK16	10.0e.backspace, dx, 0x030c
	mov	si, offset s_crlf
	call	tty
	GETPOS
	CK16	10.0e.cr-lf-bel, dx, 0x0400
	CMPSCR	10.0e.control

	/* off the end of the last line: the screen goes up a line, and the
	   new line has the attribute of the cell that was at 24,0 */
	SETPOS	24, 75
	mov	si, offset s_upper
	call	tty
	mov	dx, 0x184b
	mov	al, 'A'
1:	call	mput_char
	inc	al
	inc	dl
	cmp	dl, 80
	jb	1b
	mov	dx, 0x1800
	call	mget
	mov	bh, ch			/* the attribute for the new line */
	xor	cx, cx
	mov	dx, 0x184f
	mov	al, 1
	call	model_up
	mov	dx, 0x1800
	mov	al, 'F'
	call	mput_char
	inc	dl
	mov	al, 'G'
	call	mput_char
	GETPOS
	CK16	10.0e.scroll-cursor, dx, 0x1802
	CMPSCR	10.0e.scroll

	/* BH 1, page 1 not shown: the IBM BIOS writes to the page shown
	   whatever BH says, and so should this */
	push	es
	push	0xb900
	pop	es
	mov	cl, es:[(3*80+7)*2]
	mov	ax, 0x0e50
	mov	bx, 0x0107
	int	0x10
	CK8	10.0e.bh-page1-left-alone, es:[(3*80+7)*2], cl
	push	0x40
	pop	es
	CK16	10.0e.bh-page1-cursor-stays, es:[0x52], 0x0307
	pop	es
	mov	dx, 0x1802
	mov	al, 'P'
	call	mput_char
	GETPOS
	CK16	10.0e.bh-page0-cursor, dx, 0x1803
	CMPSCR	10.0e.bh-page0-written

	/* ---- 13h: the four ways, AL 0 to 3 */
	push	cs
	pop	es
	mov	ax, 0x1300
	mov	bx, 0x001f
	mov	cx, 5
	mov	dx, 0x0c05
	mov	bp, offset s_hello
	int	0x10
	mov	dx, 0x0c05
	mov	si, offset s_hello
	mov	cx, 5
	mov	ah, 0x1f
1:	mov	al, [si]
	call	mset
	inc	si
	inc	dl
	loop	1b
	CMPSCR	10.13.al0
	GETPOS
	CK16	10.13.al0-cursor-stays, dx, 0x1803

	push	cs
	pop	es
	mov	ax, 0x1301
	mov	bx, 0x002e
	mov	cx, 3
	mov	dx, 0x0e4e
	mov	bp, offset s_xyz
	int	0x10
	mov	dx, 0x0e4e
	mov	ax, 0x2e58
	call	mset
	call	mnext
	inc	al
	call	mset
	call	mnext
	inc	al
	call	mset
	CMPSCR	10.13.al1
	GETPOS
	CK16	10.13.al1-cursor, dx, 0x0f01

	push	cs
	pop	es
	mov	ax, 0x1302
	xor	bx, bx
	mov	cx, 3
	mov	dx, 0x1000
	mov	bp, offset s_pairs
	int	0x10
	mov	dx, 0x1000
	mov	si, offset s_pairs
	mov	cx, 3
1:	mov	ax, [si]
	call	mset
	add	si, 2
	inc	dl
	loop	1b
	CMPSCR	10.13.al2
	GETPOS
	CK16	10.13.al2-cursor-stays, dx, 0x0f01

	push	cs
	pop	es
	mov	ax, 0x1303
	xor	bx, bx
	mov	cx, 2
	mov	dx, 0x1100
	mov	bp, offset s_pairs2
	int	0x10
	mov	dx, 0x1100
	mov	ax, [s_pairs2]
	call	mset
	inc	dl
	mov	ax, [s_pairs2 + 2]
	call	mset
	CMPSCR	10.13.al3
	GETPOS
	CK16	10.13.al3-cursor, dx, 0x1102

	/* the screen as it now is, against its memory */
	push	0xb800
	pop	es
	mov	si, offset n_final
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.text-final

	/* the cursor: a block at 10,20, then the shape a mode set leaves,
	   at 12,40 */
	mov	ah, 1
	mov	cx, 0x000f
	int	0x10
	SETPOS	10, 20
	mov	si, offset n_block
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.01.cursor-block
	mov	ax, 0x0003
	int	0x10
	push	0xb800
	pop	es
	mov	cx, 0x1950
	xor	bl, bl
	call	draw_text
	SETPOS	12, 40
	mov	si, offset n_default
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.01.cursor-default
	DONE

n_page1:   .asciz "10.05.page1"
n_final:   .asciz "10.text-final"
n_block:   .asciz "10.01.cursor-block"
n_default: .asciz "10.01.cursor-default"
s_abc:	.asciz	"ab\010c"
s_crlf:	.asciz	"\r\n\007"
s_upper: .asciz	"ABCDEFG"
s_hello: .ascii	"Hello"
s_xyz:	.ascii	"XYZ"
s_pairs: .byte	'a', 0x41, 'b', 0x42, 'c', 0x43
s_pairs2: .byte	'd', 0x5e, 'e', 0x5f

/* ---------------------------------------------------------------- the CRTC */

crtc_read:			/* al the index: al the value */
	push	dx
	mov	dx, 0x3d4
	out	dx, al
	inc	dx
	in	al, dx
	pop	dx
	ret
crtc_cursor:			/* ax: the cursor's start and end lines */
	mov	al, 0x0a
	call	crtc_read
	mov	ah, al
	mov	al, 0x0b
	jmp	crtc_read
crtc_curpos:			/* ax: the cursor's address */
	mov	al, 0x0e
	call	crtc_read
	mov	ah, al
	mov	al, 0x0f
	jmp	crtc_read
crtc_start:			/* ax: the start address */
	mov	al, 0x0c
	call	crtc_read
	mov	ah, al
	mov	al, 0x0d
	jmp	crtc_read

/* the string at cs:si through 0Eh, page 0 */
tty:
	pusha
1:	mov	al, cs:[si]
	or	al, al
	jz	2f
	mov	ah, 0x0e
	mov	bx, 0x0007
	int	0x10
	inc	si
	jmp	1b
2:	popa
	ret

/* ---------------------------------------------------------------- the model */

mseg:	.word	0
m_top:	.byte	0
m_left:	.byte	0
m_bot:	.byte	0
m_right: .byte	0
m_n:	.byte	0
m_attr:	.byte	0

/* page 0 of the screen into the model */
save_screen:
	pusha
	push	ds
	push	es
	push	0xb800
	pop	ds
	xor	si, si
	mov	es, cs:[mseg]
	xor	di, di
	mov	cx, 2000
	rep	movsw
	pop	es
	pop	ds
	popa
	ret

/* di: the model's cell at row dh, column dl */
mcell:
	push	ax
	movzx	ax, dh
	imul	ax, ax, 80
	movzx	di, dl
	add	di, ax
	shl	di, 1
	pop	ax
	ret

/* the cell at dh, dl: cx */
mget:
	push	es
	push	di
	mov	es, cs:[mseg]
	call	mcell
	mov	cx, es:[di]
	pop	di
	pop	es
	ret

/* ax into the cell at dh, dl */
mset:
	push	es
	push	di
	mov	es, cs:[mseg]
	call	mcell
	mov	es:[di], ax
	pop	di
	pop	es
	ret

/* al into the character of the cell at dh, dl, the attribute kept */
mput_char:
	push	es
	push	di
	mov	es, cs:[mseg]
	call	mcell
	mov	es:[di], al
	pop	di
	pop	es
	ret

/* dh, dl to the next cell */
mnext:
	inc	dl
	cmp	dl, 80
	jb	1f
	xor	dl, dl
	inc	dh
1:	ret

/* the window ch,cl to dh,dl, al lines (0 or more than the window: all of
   it), bh the attribute of what comes in */
m_args:
	mov	cs:[m_top], ch
	mov	cs:[m_left], cl
	mov	cs:[m_bot], dh
	mov	cs:[m_right], dl
	mov	cs:[m_attr], bh
	push	ax
	mov	ah, dh
	sub	ah, ch
	inc	ah			/* the window's height */
	test	al, al
	jz	1f
	cmp	al, ah
	jbe	2f
1:	mov	al, ah
2:	mov	cs:[m_n], al
	pop	ax
	ret

/* one cell of a scroll: row al from row ah, column bl, if ah is in the
   window (bp 1), else blank */
m_move:
	push	cx
	push	dx
	push	di
	test	bp, bp
	jz	1f
	mov	dh, ah
	mov	dl, bl
	call	mcell
	mov	cx, es:[di]
	jmp	2f
1:	mov	cl, ' '
	mov	ch, cs:[m_attr]
2:	mov	dh, al
	mov	dl, bl
	call	mcell
	mov	es:[di], cx
	pop	di
	pop	dx
	pop	cx
	ret

model_up:
	pusha
	push	es
	call	m_args
	mov	es, cs:[mseg]
	mov	al, cs:[m_top]
1:	mov	ah, al
	add	ah, cs:[m_n]
	xor	bp, bp
	cmp	ah, cs:[m_bot]
	ja	2f
	inc	bp
2:	mov	bl, cs:[m_left]
3:	call	m_move
	inc	bl
	cmp	bl, cs:[m_right]
	jbe	3b
	inc	al
	cmp	al, cs:[m_bot]
	jbe	1b
	pop	es
	popa
	ret

model_down:
	pusha
	push	es
	call	m_args
	mov	es, cs:[mseg]
	mov	al, cs:[m_bot]
1:	mov	ah, al
	xor	bp, bp
	sub	ah, cs:[m_n]
	jc	2f
	cmp	ah, cs:[m_top]
	jb	2f
	inc	bp
2:	mov	bl, cs:[m_left]
3:	call	m_move
	inc	bl
	cmp	bl, cs:[m_right]
	jbe	3b
	cmp	al, cs:[m_top]
	je	4f
	dec	al
	jmp	1b
4:	pop	es
	popa
	ret

/* page 0 of the screen against the model, as @ok or @bad cs:si */
cmp_screen:
	pusha
	push	ds
	push	es
	push	0xb800
	pop	ds
	mov	es, cs:[mseg]
	xor	bx, bx
	xor	dx, dx
	mov	bp, 0xffff
1:	mov	ax, [bx]
	cmp	ax, es:[bx]
	je	2f
	inc	dx
	cmp	bp, 0xffff
	jne	2f
	mov	bp, bx
2:	add	bx, 2
	cmp	bx, 4000
	jb	1b
	test	dx, dx
	jnz	3f
	call	say_ok
	call	putnl
	jmp	4f
3:	call	say_bad
	PUTS	" cells wrong: "
	mov	ax, dx
	call	puthex16
	PUTS	", the first at "
	mov	ax, bp
	shr	ax, 1
	mov	cl, 80
	div	cl
	call	puthex8			/* the row */
	mov	al, ','
	call	putc
	mov	al, ah
	call	puthex8			/* the column */
	PUTS	" got="
	mov	ax, ds:[bp]
	call	puthex16
	PUTS	" want="
	mov	ax, es:[bp]
	call	puthex16
	call	putnl
4:	pop	es
	pop	ds
	popa
	ret

	.include "draw.inc"
