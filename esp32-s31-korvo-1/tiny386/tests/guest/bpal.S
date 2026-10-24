/*
 * BPAL.COM: the palette and the DAC through int 10h AH=10h (subfunctions
 * 00h to 03h, 07h to 09h, 10h, 12h, 13h, 15h, 17h to 1Bh), the palette
 * options of AH=12h (BL=31h, default palette loading; BL=33h, summing to
 * grey) and the CGA palette of AH=0Bh.
 *
 * Mode 12h with the bars of BMODES.  What is set is read back, and the
 * program keeps its own copy of the palette registers and the DAC, from
 * which it works out the colour each bar should have and sends it as
 * @pal NAME before each picture.  Blinking, in mode 03h, is looked at
 * several times.
 *
 * Build:
 *   as --32 -I tests/guest -o bpal.o bpal.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BPAL.COM bpal.o
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

m_ar	= 0x9000		/* the palette registers and the overscan: 17 */
m_dac	= 0x9100		/* the DAC: 768 */
buf	= 0x9400		/* what is read back */

/* SAME NAME, COUNT: COUNT bytes at buf against WANT (offsets in this segment) */
	.macro	SAME name, want, count
	push	si
	push	di
	push	cx
	mov	si, offset .Ln\@
	mov	di, \want
	mov	cx, \count
	call	same
	pop	cx
	pop	di
	pop	si
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* PAL NAME: the bars' colours as @pal, then the picture */
	.macro	PICTURE name
	push	si
	mov	si, offset .Ln\@
	call	emit_pal
	pop	si
	SHOT	\name
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* RDAC INDEX: one DAC register through 1015h into dh, ch, cl */
	.macro	RDAC index
	mov	ax, 0x1015
	mov	bx, \index
	int	0x10
	.endm

main:
	cld
	push	cs
	pop	es
	call	model_init
	call	mode12

	/* ---- what a mode set leaves */
	mov	bl, 0
1:	mov	ax, 0x1007
	push	bx
	int	0x10
	mov	al, bh
	pop	bx
	movzx	di, bl
	mov	[buf + di], al
	inc	bl
	cmp	bl, 16
	jb	1b
	SAME	10.10.07.after-mode, m_ar, 16
	mov	ax, 0x1008
	int	0x10
	CK8	10.10.08.after-mode, bh, 0
	mov	ax, 0x1009
	mov	dx, buf
	int	0x10
	SAME	10.10.09.after-mode, m_ar, 17
	mov	ax, 0x1017
	xor	bx, bx
	mov	cx, 64
	mov	dx, buf
	int	0x10
	SAME	10.10.17.after-mode, m_dac, 64*3
	RDAC	63
	CK16	10.10.15.after-mode-rg, dx, 0x3f00
	CK16	10.10.15.after-mode-gb, cx, 0x3f3f

	/* ---- 00h: one palette register; 01h: the overscan */
	mov	ax, 0x1000
	mov	bx, 0x3c01
	int	0x10
	mov	byte ptr [m_ar + 1], 0x3c
	mov	ax, 0x1007
	mov	bl, 1
	int	0x10
	CK8	10.10.00.read-back, bh, 0x3c
	mov	ax, 0x1001
	mov	bh, 5
	int	0x10
	mov	byte ptr [m_ar + 16], 5
	mov	ax, 0x1008
	int	0x10
	CK8	10.10.01.read-back, bh, 5
	PICTURE	10.10.00

	/* ---- 02h: all of them at once */
	mov	ax, 0x1002
	mov	dx, offset allpal
	int	0x10
	mov	si, offset allpal
	mov	di, m_ar
	mov	cx, 17
	rep	movsb
	mov	ax, 0x1009
	mov	dx, buf
	int	0x10
	SAME	10.10.02.read-back, m_ar, 17
	PICTURE	10.10.02

	/* ---- 10h: one DAC register; 12h: a block; 15h and 17h back */
	mov	ax, 0x1010
	mov	bx, 63
	mov	dh, 63
	mov	cx, 0x2000
	int	0x10
	mov	word ptr [m_dac + 63 * 3], 0x203f
	mov	byte ptr [m_dac + 63 * 3 + 2], 0
	RDAC	63
	CK16	10.10.10.read-back-rg, dx, 0x3f00
	CK16	10.10.10.read-back-gb, cx, 0x2000
	mov	ax, 0x1012
	mov	bx, 8
	mov	cx, 8
	mov	dx, offset block
	int	0x10
	mov	si, offset block
	mov	di, m_dac + 8 * 3
	mov	cx, 24
	rep	movsb
	mov	ax, 0x1017
	mov	bx, 8
	mov	cx, 8
	mov	dx, buf
	int	0x10
	SAME	10.10.12.read-back, m_dac+8*3, 24
	PICTURE	10.10.12

	/* ---- 13h: sixteen pages of sixteen colours, page 2; 1Ah back */
	mov	ax, 0x1013
	mov	bx, 0x0100
	int	0x10
	mov	ax, 0x1013
	mov	bx, 0x0201
	int	0x10
	mov	byte ptr [m_p16], 1
	mov	byte ptr [m_page], 2
	mov	ax, 0x101a
	int	0x10
	CK8	10.10.1a.mode16, bl, 1
	CK8	10.10.1a.page2, bh, 2
	mov	al, 0x10
	call	ar_read
	and	al, 0x80
	CK8	10.10.13.ar10-bit7, al, 0x80
	mov	al, 0x14
	call	ar_read
	CK8	10.10.13.ar14, al, 2
	PICTURE	10.10.13
	mov	ax, 0x1013
	mov	bx, 0x0001
	int	0x10
	mov	ax, 0x1013
	mov	bx, 0x0000
	int	0x10
	mov	byte ptr [m_p16], 0
	mov	byte ptr [m_page], 0
	mov	ax, 0x101a
	int	0x10
	CK16	10.10.1a.back, bx, 0

	/* ---- 18h and 19h: the PEL mask */
	mov	ax, 0x1018
	mov	bl, 0x0f
	int	0x10
	mov	ax, 0x1019
	int	0x10
	CK8	10.10.19.mask, bl, 0x0f
	mov	dx, 0x3c6
	in	al, dx
	INFO8	10.10.18.port-3c6, al
	mov	ax, 0x1018
	mov	bl, 0xff
	int	0x10

	/* ---- 03h: intensity or blinking, as bit 3 of AR10 */
	mov	ax, 0x1003
	mov	bl, 0
	int	0x10
	mov	al, 0x10
	call	ar_read
	and	al, 0x08
	CK8	10.10.03.intensity-ar10, al, 0
	mov	ax, 0x1003
	mov	bl, 1
	int	0x10
	mov	al, 0x10
	call	ar_read
	and	al, 0x08
	CK8	10.10.03.blink-ar10, al, 0x08

	/* ---- 1Bh: entries 20h to 2Fh summed to grey */
	mov	ax, 0x101b
	mov	bx, 0x20
	mov	cx, 16
	int	0x10
	mov	ax, 0x1017
	mov	bx, 0x20
	mov	cx, 16
	mov	dx, buf
	int	0x10
	mov	si, offset n_sum
	mov	di, m_dac + 0x20 * 3
	mov	cx, 16
	call	greys

	/* ---- 12h BL=33h: summing to grey as the palette is loaded */
	mov	ax, 0x1200
	mov	bl, 0x33
	int	0x10
	CK8	10.12.33.enable, al, 0x12
	mov	ax, 0x1010
	mov	bx, 0x30
	mov	dh, 63
	xor	cx, cx
	int	0x10
	RDAC	0x30
	mov	byte ptr [buf], dh
	mov	byte ptr [buf + 1], ch
	mov	byte ptr [buf + 2], cl
	mov	byte ptr [red], 63
	mov	si, offset n_summed
	mov	di, offset red
	mov	cx, 1
	call	greys
	mov	ax, 0x1201
	mov	bl, 0x33
	int	0x10
	mov	ax, 0x1010
	mov	bx, 0x31
	mov	dh, 63
	xor	cx, cx
	int	0x10
	RDAC	0x31			/* red in dh, green and blue in cx */
	CK8	10.12.33.disabled-r, dh, 63
	CK16	10.12.33.disabled-gb, cx, 0

	/* ---- 12h BL=31h: no default palette on a mode set */
	mov	ax, 0x1201
	mov	bl, 0x31
	int	0x10
	CK8	10.12.31.disable, al, 0x12
	mov	ax, 0x1010
	mov	bx, 1
	mov	dh, 1
	mov	cx, 0x0203
	int	0x10
	mov	ax, 0x0012
	int	0x10
	RDAC	1
	CK8	10.12.31.kept-r, dh, 1
	CK16	10.12.31.kept-gb, cx, 0x0203
	mov	ax, 0x1200
	mov	bl, 0x31
	int	0x10
	mov	ax, 0x0012
	int	0x10
	RDAC	1
	CK8	10.12.31.loaded-r, dh, 0
	CK16	10.12.31.loaded-gb, cx, 0x002a

	/* ---- blinking, in text: every cell a red B on light grey with the
	   blink bit set (F4h).  Blinking: the B comes and goes on light grey;
	   intensity: it stays, on white. */
	mov	ax, 0x0003
	int	0x10
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	push	0xb800
	pop	es
	xor	di, di
	mov	ax, 0xf442
	mov	cx, 2000
	rep	stosw
	mov	si, offset n_blink
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.10.03.blink
	mov	ax, 0x1003
	mov	bl, 0
	int	0x10
	mov	si, offset n_intens
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.10.03.intensity

	/* ---- 0Bh, in mode 04h: palette 0 and 1, and the background */
	mov	ax, 0x0004
	int	0x10
	mov	ah, 0x0b
	mov	bx, 0x0100
	int	0x10
	call	ar123
	CK16	10.0b.palette0-12, ax, 0x0204
	CK8	10.0b.palette0-3, dl, 6
	mov	ah, 0x0b
	mov	bx, 0x0101
	int	0x10
	call	ar123
	CK16	10.0b.palette1-12, ax, 0x0305
	CK8	10.0b.palette1-3, dl, 7
	mov	ah, 0x0b
	mov	bx, 0x0001
	int	0x10
	mov	ax, 0x1007
	mov	bl, 0
	int	0x10
	INFO8	10.0b.ar0, bh
	and	bh, 0x0f
	CK8	10.0b.background, bh, 1

	mov	ax, 0x0003
	int	0x10
	DONE

n_sum:	  .asciz "10.10.1b.sum"
n_summed: .asciz "10.12.33.summed"
n_blink:  .asciz "10.10.03.blink"
n_intens: .asciz "10.10.03.intensity"
red:	.byte	0, 0, 0
/* for 02h: a palette with the bars in other colours, and overscan 1 */
allpal:	.byte	0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38
	.byte	0x07, 0x0f, 0x17, 0x1f, 0x27, 0x2f, 0x37, 0x3f, 0x01
/* for 12h: DAC 8 to 15 */
block:	.byte	63, 0, 0,   0, 63, 0,   0, 0, 63,   63, 63, 0
	.byte	0, 63, 63,  63, 0, 63,  32, 32, 32, 10, 20, 30
m_p16:	.byte	0
m_page:	.byte	0
/* mode 12h's palette registers after a mode set, as on a VGA */
ar12:	.byte	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
	.byte	0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x00

/* mode 12h and its bars */
mode12:
	pusha
	mov	ax, 0x0012
	int	0x10
	mov	bx, 80
	mov	cx, 480
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	popa
	ret

/* the model as a mode set leaves it: the palette registers above, and the
   DAC's first 64 the colours of EGA, rgbRGB */
model_init:
	pusha
	mov	si, offset ar12
	mov	di, m_ar
	mov	cx, 17
	rep	movsb
	mov	di, m_dac
	xor	cx, cx
1:	mov	al, cl
	call	ega64
	mov	[di], al
	mov	[di + 1], ah
	mov	[di + 2], bl
	add	di, 3
	inc	cx
	cmp	cx, 64
	jb	1b
	mov	cx, (256 - 64) * 3
	xor	al, al
	rep	stosb
	popa
	ret

/* al an EGA colour, rgbRGB: al red, ah green, bl blue, in 6 bits */
ega64:
	push	cx
	mov	cl, al
	xor	ax, ax
	xor	bl, bl
	test	cl, 4
	jz	1f
	add	al, 42
1:	test	cl, 32
	jz	2f
	add	al, 21
2:	test	cl, 2
	jz	3f
	add	ah, 42
3:	test	cl, 16
	jz	4f
	add	ah, 21
4:	test	cl, 1
	jz	5f
	add	bl, 42
5:	test	cl, 8
	jz	6f
	add	bl, 21
6:	pop	cx
	ret

/* cx bytes at buf against those at di; cs:si the name */
same:
	pusha
	mov	bx, buf
	xor	bp, bp
1:	mov	al, [bx]
	cmp	al, [di]
	jne	2f
	inc	bx
	inc	di
	inc	bp
	loop	1b
	call	say_ok
	call	putnl
	popa
	ret
2:	call	say_bad
	PUTS	" byte "
	mov	ax, bp
	call	puthex16
	PUTS	" got="
	mov	al, [bx]
	call	puthex8
	PUTS	" want="
	mov	al, [di]
	call	puthex8
	call	putnl
	popa
	ret

/* cx DAC entries at buf, each R G B, should be the grey of those at di:
   (30 R + 59 G + 11 B) / 100, give or take 1.  cs:si the name. */
greys:
	pusha
	mov	bx, buf
1:	movzx	ax, byte ptr [di]
	imul	ax, ax, 30
	movzx	dx, byte ptr [di + 1]
	imul	dx, dx, 59
	add	ax, dx
	movzx	dx, byte ptr [di + 2]
	imul	dx, dx, 11
	add	ax, dx
	add	ax, 50
	xor	dx, dx
	push	cx
	mov	cx, 100
	div	cx
	pop	cx			/* al: the grey */
	push	cx
	mov	cx, 3
2:	mov	ah, [bx]
	sub	ah, al
	jns	3f
	neg	ah
3:	cmp	ah, 1
	ja	9f
	inc	bx
	loop	2b
	pop	cx
	add	di, 3
	loop	1b
	call	say_ok
	call	putnl
	popa
	ret
9:	pop	cx
	call	say_bad
	PUTS	" got="
	mov	ah, al
	mov	al, [bx]
	call	puthex8
	PUTS	" want="
	mov	al, ah
	call	puthex8
	call	putnl
	popa
	ret

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

/* palette registers 1 to 3 through 1007h, each and 7: ah, al, dl */
ar123:
	push	bx
	mov	ax, 0x1007
	mov	bl, 3
	int	0x10
	mov	dl, bh
	and	dl, 7
	mov	ax, 0x1007
	mov	bl, 2
	int	0x10
	push	bx
	mov	ax, 0x1007
	mov	bl, 1
	int	0x10
	mov	ah, bh
	pop	bx
	mov	al, bh
	and	ax, 0x0707
	pop	bx
	ret

/* @pal NAME: the colour of each of the sixteen bars, from the model: the
   DAC entry that its palette register, the colour select register and AR10
   bit 7 together pick */
emit_pal:
	pusha
	PUTS	"@pal "
	call	puts
	call	putsp
	xor	bx, bx
1:	mov	al, [m_ar + bx]
	cmp	byte ptr [m_p16], 0
	je	2f
	and	al, 0x0f
	mov	ah, [m_page]
	shl	ah, 4
	or	al, ah
	jmp	3f
2:	and	al, 0x3f
	mov	ah, [m_page]
	shl	ah, 6
	or	al, ah
3:	movzx	si, al
	imul	si, si, 3
	mov	al, [m_dac + si]
	call	puthex8
	mov	al, [m_dac + si + 1]
	call	puthex8
	mov	al, [m_dac + si + 2]
	call	puthex8
	inc	bx
	cmp	bx, 16
	jb	1b
	call	putnl
	popa
	ret

	.include "draw.inc"
