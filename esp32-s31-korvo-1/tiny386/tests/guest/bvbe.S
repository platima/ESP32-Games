/*
 * BVBE.COM: the VESA BIOS Extension, int 10h AX=4F00h to 4F0Ah.
 *
 * 4F00h and the mode list, 4F01h for every mode in it; then mode 101h
 * (640x480, 256 colours) set with 4F02h and drawn through the 64K window
 * at A000h, moving it with 4F05h; 4F03h, 4F06h (the logical line), 4F07h
 * (the display start), 4F08h and 4F09h (an 8-bit DAC), 4F04h (save and
 * restore), 4F0Ah (the protected mode interface); mode 101h again with its
 * linear frame buffer, drawn through int 15h AH=87h, and mode 111h (640x480,
 * 16 bits a pixel) the same way.  Then 800x600, three ways: 103h (256
 * colours, through the window), 114h (16 bits a pixel, linear) and 102h (16
 * colours in four planes); the screen here is 800x480, so 103h is looked at
 * a second time with the display start 120 lines down.  Pictures as BMODES
 * draws them.
 *
 * Built with V256 defined (BVBE256.COM) it only asks 4F00h and looks at
 * the list, for the configuration as handed over, with 256K of video
 * memory.
 *
 * Build:
 *   as --32 -I tests/guest -o bvbe.o bvbe.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BVBE.COM bvbe.o
 *   as --32 -I tests/guest --defsym V256=1 -o bvbe256.o bvbe.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BVBE256.COM bvbe256.o
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

info	= 0x9000		/* 4F00h: 512 bytes */
minfo	= 0x9200		/* 4F01h: 256 bytes */
pal	= 0x9300		/* 4F09h: 16 entries of 4 */
palrd	= 0x9340
gdt	= 0x9380		/* int 15h AH=87h: 48 bytes */
state	= 0x9400		/* 4F04h: up to 2K */
list	= 0x9c00		/* the mode list, copied: up to 512 bytes */

	.macro	AXOK name
	CK16	"\name", ax, 0x004f
	.endm

main:
	cld
	push	cs
	pop	es
	/* ---- 4F00h, asking for VBE 2.0 information */
	mov	dword ptr [info], 0x32454256	/* "VBE2" */
	mov	ax, 0x4f00
	mov	di, info
	int	0x10
.ifdef V256
	AXOK	10.4f.256k.00.ax
	CK32	10.4f.256k.00.signature, [info], 0x41534556
	INFO16	10.4f.256k.00.version, [info+4]
	INFO16	10.4f.256k.00.memory-64k, [info+0x12]
	call	copy_list
	INFO16	10.4f.256k.00.modes, [nmodes]
	mov	si, list
	xor	cx, cx
1:	mov	ax, [si]
	cmp	ax, 0xffff
	je	2f
	cmp	ax, 0x100
	jb	3f
	inc	cx
	PUTS	"@info 10.4f.256k.00.vbe-mode "
	call	puthex16
	call	putnl
3:	add	si, 2
	jmp	1b
2:	INFO16	10.4f.256k.00.vbe-modes, cx
	mov	cx, 0x100
	call	in_list
	CKNC	10.4f.256k.list.has-100-640x400x8
	DONE
.else
	AXOK	10.4f.00.ax
	CK32	10.4f.00.signature, [info], 0x41534556
	INFO16	10.4f.00.version, [info+4]
	CK16	10.4f.00.memory-1m, [info+0x12], 16
	INFO32	10.4f.00.capabilities, [info+0x0a]
	push	si
	mov	si, offset n_oem
	mov	bx, 0x06
	call	farstring
	mov	si, offset n_vendor
	mov	bx, 0x16
	call	farstring
	mov	si, offset n_product
	mov	bx, 0x1a
	call	farstring
	pop	si
	call	copy_list
	INFO16	10.4f.00.modes, [nmodes]

	/* ---- 4F01h for each */
	mov	si, list
	xor	bp, bp			/* how many 4F01h refused */
1:	mov	cx, [si]
	cmp	cx, 0xffff
	je	2f
	push	si
	mov	ax, 0x4f01
	mov	di, minfo
	int	0x10
	cmp	ax, 0x004f
	je	3f
	inc	bp
3:	call	say_mode
	pop	si
	add	si, 2
	jmp	1b
2:	CK16	10.4f.01.every-mode, bp, 0
	mov	cx, 0x101
	call	in_list
	CKNC	10.4f.list.has-101-640x480x8
	mov	cx, 0x111
	call	in_list
	CKNC	10.4f.list.has-111-640x480x16
	mov	cx, 0x100
	call	in_list
	CKNC	10.4f.list.has-100-640x400x8
	mov	cx, 0x103
	call	in_list
	CKNC	10.4f.list.has-103-800x600x8

	/* ---- 4F02h: 101h, a refused mode, and 4F03h */
	mov	ax, 0x4f01
	mov	cx, 0x101
	mov	di, minfo
	int	0x10
	AXOK	10.4f.01.m101
	CK16	10.4f.01.m101.width, [minfo+0x12], 640
	CK16	10.4f.01.m101.height, [minfo+0x14], 480
	CK8	10.4f.01.m101.bpp, [minfo+0x19], 8
	CK16	10.4f.01.m101.window-segment, [minfo+0x08], 0xa000
	CK16	10.4f.01.m101.granularity-64k, [minfo+0x04], 64
	mov	ax, [minfo+0x10]
	mov	[bpl], ax
	CK16	10.4f.01.m101.bytes-a-line, ax, 640
	mov	ax, 0x4f02
	mov	bx, 0x0101
	int	0x10
	AXOK	10.4f.02.m101
	mov	ax, 0x4f03
	int	0x10
	AXOK	10.4f.03.ax
	and	bx, 0x3fff
	CK16	10.4f.03.mode, bx, 0x0101
	call	draw_banked
	/* 4F05h: where the window is, after moving it to 3 */
	mov	ax, 0x4f05
	xor	bx, bx
	mov	dx, 3
	int	0x10
	AXOK	10.4f.05.set
	mov	ax, 0x4f05
	mov	bx, 0x0100
	int	0x10
	AXOK	10.4f.05.get
	CK16	10.4f.05.position, dx, 3
	SHOT	10.4f.02.m101

	/* ---- 4F06h: the logical line, read, then made 1024 pixels */
	mov	ax, 0x4f06
	mov	bl, 1
	int	0x10
	AXOK	10.4f.06.get
	CK16	10.4f.06.get-bytes, bx, 640
	CK16	10.4f.06.get-pixels, cx, 640
	INFO16	10.4f.06.get-lines, dx
	mov	ax, 0x4f06
	xor	bl, bl
	mov	cx, 1024
	int	0x10
	AXOK	10.4f.06.set
	CK16	10.4f.06.set-bytes, bx, 1024
	CK16	10.4f.06.set-pixels, cx, 1024
	mov	word ptr [bpl], 1024
	mov	word ptr [nlines], 481	/* and a black line under it */
	call	draw_banked
	mov	word ptr [nlines], 480
	/* ---- 4F07h: the display start a line down */
	mov	ax, 0x4f07
	xor	bx, bx
	xor	cx, cx
	mov	dx, 1
	int	0x10
	AXOK	10.4f.07.set
	mov	ax, 0x4f07
	mov	bx, 1
	int	0x10
	AXOK	10.4f.07.get
	CK16	10.4f.07.get-x, cx, 0
	CK16	10.4f.07.get-y, dx, 1
	SHOT	10.4f.07.start-line-1

	/* ---- 4F08h and 4F09h: an 8-bit DAC, sixteen colours set in it */
	mov	ax, 0x4f02
	mov	bx, 0x0101
	int	0x10
	mov	word ptr [bpl], 640
	call	draw_banked
	mov	ax, 0x4f08
	mov	bx, 0x0800
	int	0x10
	AXOK	10.4f.08.set
	CK8	10.4f.08.set-8, bh, 8
	mov	ax, 0x4f08
	mov	bx, 0x0001
	int	0x10
	AXOK	10.4f.08.get
	CK8	10.4f.08.get-8, bh, 8
	/* a DAC of another width leaves video memory alone on a VGA: pixel
	   100 of line 100 is bar 2 */
	mov	ax, 0x4f05
	xor	bx, bx
	mov	dx, 0
	int	0x10
	mov	word ptr [bank], 0
	push	es
	push	0xa000
	pop	es
	CK8	10.4f.08.picture-kept, es:[100*640+100], 2
	pop	es
	call	draw_banked
	mov	ax, 0x4f09
	xor	bl, bl
	mov	cx, 16
	xor	dx, dx
	mov	di, offset pal8
	int	0x10
	AXOK	10.4f.09.set
	mov	ax, 0x4f09
	mov	bl, 1
	mov	cx, 16
	xor	dx, dx
	mov	di, palrd
	int	0x10
	AXOK	10.4f.09.get
	push	si
	mov	si, offset pal8
	mov	di, palrd
	mov	cx, 64
	repe	cmpsb
	pop	si
	CKZ	10.4f.09.read-back
	/* what the bars should be: @pal8 */
	PUTS	"@pal8 10.4f.09.dac8 "
	mov	si, offset pal8
	mov	cx, 16
4:	mov	al, [si + 2]
	call	puthex8
	mov	al, [si + 1]
	call	puthex8
	mov	al, [si]
	call	puthex8
	add	si, 4
	loop	4b
	call	putnl
	SHOT	10.4f.09.dac8
	mov	ax, 0x4f08
	mov	bx, 0x0600
	int	0x10
	CK8	10.4f.08.back-to-6, bh, 6

	/* ---- 4F04h: the state saved in mode 101h, mode 03h set, put back */
	mov	ax, 0x4f04
	xor	dl, dl
	mov	cx, 0x000f
	int	0x10
	AXOK	10.4f.04.size
	INFO16	10.4f.04.blocks, bx
	cmp	bx, 32
	jbe	5f
	BAD	10.4f.04.fits, "more than 2K"
	jmp	6f
5:	mov	ax, 0x4f04
	mov	dl, 1
	mov	cx, 0x000f
	mov	bx, state
	int	0x10
	AXOK	10.4f.04.save
	mov	ax, 0x0003
	int	0x10
	push	cs
	pop	es
	mov	ax, 0x4f04
	mov	dl, 2
	mov	cx, 0x000f
	mov	bx, state
	int	0x10
	AXOK	10.4f.04.restore
	mov	ax, 0x4f03
	int	0x10
	and	bx, 0x3fff
	CK16	10.4f.04.mode-back, bx, 0x0101
6:
	/* ---- 4F0Ah: the protected mode interface */
	mov	ax, 0x4f0a
	xor	bl, bl
	int	0x10
	AXOK	10.4f.0a.ax
	INFO16	10.4f.0a.length, cx

	/* ---- 4F02h with a mode not in the list: 105h, 1024x768 */
	mov	cx, 0x105
	call	in_list
	jnc	8f
	mov	ax, 0x4f02
	mov	bx, 0x0105
	int	0x10
	push	cs
	pop	es
	cmp	ax, 0x004f
	je	7f
	OK	10.4f.02.refuses-105, "not in the list"
	jmp	8f
7:	BAD	10.4f.02.refuses-105, "set it, though it is not in the list"
8:
	/* ---- 101h with its linear frame buffer, drawn through int 15h */
	mov	ax, 0x4f01
	mov	cx, 0x101
	mov	di, minfo
	int	0x10
	mov	eax, [minfo+0x28]
	mov	[lfb], eax
	INFO32	10.4f.01.m101.lfb, eax
	test	byte ptr [minfo], 0x80
	jnz	9f
	BAD	10.4f.01.m101.lfb-attribute, "bit 7 of the attributes not set"
9:	mov	ax, 0x4f02
	mov	bx, 0x4101
	int	0x10
	AXOK	10.4f.02.m101-lfb
	call	draw_lfb8
	SHOT	10.4f.02.m101-lfb

	/* ---- 111h, 16 bits a pixel, linear: red on the left, blue on the
	   right */
	mov	cx, 0x111
	call	in_list
	jc	10f
	mov	ax, 0x4f02
	mov	bx, 0x4111
	int	0x10
	AXOK	10.4f.02.m111-lfb
	call	draw_lfb16
	SHOT	10.4f.02.m111-lfb
10:
	/* ---- 800x600 in 256 colours through the window: the bars, white
	   lines across at 200 and 400 as well, and the bottom 120 lines seen
	   by moving the display start down */
	mov	cx, 0x103
	call	in_list
	jnc	11f
	BAD	10.4f.list.has-103-800x600x8, "not offered"
	jmp	12f
11:	mov	ax, 0x4f01
	mov	cx, 0x103
	mov	di, minfo
	int	0x10
	AXOK	10.4f.01.m103
	CK16	10.4f.01.m103.width, [minfo+0x12], 800
	CK16	10.4f.01.m103.height, [minfo+0x14], 600
	mov	ax, [minfo+0x10]
	mov	[bpl], ax
	CK16	10.4f.01.m103.bytes-a-line, ax, 800
	mov	ax, 0x4f02
	mov	bx, 0x0103
	int	0x10
	AXOK	10.4f.02.m103
	mov	word ptr [vw], 800
	mov	word ptr [vh], 600
	mov	word ptr [nlines], 600
	mov	word ptr [mark1], 200
	mov	word ptr [mark2], 400
	call	draw_banked
	SHOT	10.4f.02.m103
	mov	ax, 0x4f07
	xor	bx, bx
	xor	cx, cx
	mov	dx, 120
	int	0x10
	AXOK	10.4f.07.m103-set
	SHOT	10.4f.07.m103-start-120
	mov	word ptr [mark1], 0xffff
	mov	word ptr [mark2], 0xffff
12:
	/* ---- 800x600, 16 bits a pixel, linear */
	mov	cx, 0x114
	call	in_list
	jnc	13f
	BAD	10.4f.list.has-114-800x600x16, "not offered"
	jmp	14f
13:	mov	ax, 0x4f01
	mov	cx, 0x114
	mov	di, minfo
	int	0x10
	mov	eax, [minfo+0x28]
	mov	[lfb], eax
	mov	ax, 0x4f02
	mov	bx, 0x4114
	int	0x10
	AXOK	10.4f.02.m114-lfb
	mov	word ptr [vw], 800
	mov	word ptr [vh], 600
	call	draw_lfb16
	SHOT	10.4f.02.m114-lfb
14:
	/* ---- 800x600 in 16 colours, four planes, 100 bytes a line: drawn as
	   BMODES draws mode 12h */
	mov	cx, 0x102
	call	in_list
	jnc	15f
	BAD	10.4f.list.has-102-800x600x4, "not offered"
	jmp	16f
15:	mov	ax, 0x4f02
	mov	bx, 0x0102
	int	0x10
	AXOK	10.4f.02.m102
	mov	bx, 100
	mov	cx, 600
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	SHOT	10.4f.02.m102
16:
	mov	ax, 0x0003
	int	0x10
	DONE
.endif

n_oem:	   .asciz "10.4f.00.oem"
n_vendor:  .asciz "10.4f.00.vendor"
n_product: .asciz "10.4f.00.product"
nmodes:	.word	0
bpl:	.word	640
lfb:	.long	0
bank:	.word	0xffff
/* sixteen colours for the 8-bit DAC: blue, green, red, 0 */
pal8:	.byte	0, 0, 0, 0,        255, 0, 0, 0,      0, 255, 0, 0,     255, 255, 0, 0
	.byte	0, 0, 255, 0,      255, 0, 255, 0,    0, 128, 255, 0,   192, 192, 192, 0
	.byte	64, 64, 64, 0,     255, 128, 128, 0,  128, 255, 128, 0, 255, 255, 128, 0
	.byte	128, 128, 255, 0,  255, 128, 255, 0,  128, 255, 255, 0, 255, 255, 255, 0

/* @info NAME "the string at the far pointer at info+bx" */
farstring:
	pusha
	push	ds
	HEAD	info, ""
	call	puts
	call	putsp
	lds	si, [info + bx]
	mov	cx, 64
1:	lodsb
	or	al, al
	jz	2f
	cmp	al, ' '
	jb	2f
	call	putc
	loop	1b
2:	call	putnl
	pop	ds
	popa
	ret

/* the mode list from info into list, and how many in nmodes */
copy_list:
	pusha
	push	ds
	lds	si, [info + 0x0e]
	mov	di, list
	xor	bx, bx
1:	lodsw
	stosw
	cmp	ax, 0xffff
	je	2f
	inc	bx
	cmp	bx, 250
	jb	1b
	mov	word ptr es:[di], 0xffff
2:	pop	ds
	mov	[nmodes], bx
	popa
	ret

/* CF clear if mode cx is in the list */
in_list:
	push	si
	mov	si, list
1:	cmp	word ptr [si], 0xffff
	je	2f
	cmp	[si], cx
	je	3f
	add	si, 2
	jmp	1b
2:	stc
	pop	si
	ret
3:	clc
	pop	si
	ret

/* @info 10.4f.01.mode-NNNN W H BPP MODEL ATTRIBUTES, from minfo; cx the mode */
say_mode:
	pusha
	PUTS	"@info 10.4f.01.mode-"
	mov	ax, cx
	call	puthex16
	call	putsp
	mov	ax, [minfo + 0x12]
	call	puthex16
	mov	al, 'x'
	call	putc
	mov	ax, [minfo + 0x14]
	call	puthex16
	mov	al, 'x'
	call	putc
	mov	al, [minfo + 0x19]
	call	puthex8
	PUTS	" model "
	mov	al, [minfo + 0x1b]
	call	puthex8
	PUTS	" attributes "
	mov	ax, [minfo]
	call	puthex16
	call	putnl
	popa
	ret

/* the window at A000 moved to bank dx (64K a bank), if it is not there */
setbank:
	cmp	dx, [bank]
	je	1f
	pusha
	mov	[bank], dx
	mov	ax, 0x4f05
	xor	bx, bx
	int	0x10
	popa
1:	ret

/* the bars of BMODES, 16 colours of vw / 16 pixels, and a border in
   colour 15, in a mode of vw x vh a byte a pixel, bpl bytes a line,
   through the window; lines mark1 and mark2 white as well, and any line
   from vh to nlines black */
draw_banked:
	pusha
	push	es
	mov	word ptr [bank], 0xffff
	call	bars_line
	push	0xa000
	pop	es
	xor	bp, bp			/* the line */
1:	mov	si, offset blackline
	cmp	bp, [vh]
	jae	3f
	mov	si, offset whiteline
	test	bp, bp
	jz	3f
	mov	ax, [vh]
	dec	ax
	cmp	bp, ax
	je	3f
	cmp	bp, [mark1]
	je	3f
	cmp	bp, [mark2]
	je	3f
	mov	si, offset linebuf
3:	mov	ax, bp
	mul	word ptr [bpl]		/* dx:ax the line's address */
	mov	di, ax
	mov	cx, [vw]
4:	call	setbank
	movsb
	test	di, di
	jnz	5f
	inc	dx			/* into the next bank */
5:	loop	4b
	inc	bp
	cmp	bp, [nlines]
	jb	1b
	pop	es
	popa
	ret
nlines:	.word	480
vw:	.word	640
vh:	.word	480
mark1:	.word	0xffff
mark2:	.word	0xffff

/* linebuf: one line of the bars with the border; whiteline: vw of 15;
   blackline: vw of 0 */
bars_line:
	pusha
	mov	ax, [vw]
	shr	ax, 4
	mov	cl, al			/* a bar's width */
	xor	bx, bx
1:	mov	ax, bx
	div	cl
	mov	[linebuf + bx], al
	mov	byte ptr [whiteline + bx], 15
	mov	byte ptr [blackline + bx], 0
	inc	bx
	cmp	bx, [vw]
	jb	1b
	mov	byte ptr [linebuf], 15
	mov	byte ptr [linebuf + bx - 1], 15
	popa
	ret

/* cx words from cs:si to the linear address in edi, through int 15h
   AH=87h; ok if it says so */
move_up:
	pushad
	push	es
	push	cs
	pop	es
	push	cx
	push	edi
	mov	di, gdt
	mov	cx, 24
	xor	ax, ax
	rep	stosw
	pop	edi
	pop	cx
	/* the source, here */
	xor	eax, eax
	mov	ax, cs
	shl	eax, 4
	movzx	esi, si
	add	eax, esi
	mov	word ptr [gdt + 0x10], 0xffff
	mov	[gdt + 0x12], eax	/* base 0-23 and the access byte after */
	mov	byte ptr [gdt + 0x15], 0x93
	shr	eax, 24
	mov	[gdt + 0x17], al
	/* the destination */
	mov	eax, edi
	mov	word ptr [gdt + 0x18], 0xffff
	mov	[gdt + 0x1a], eax
	mov	byte ptr [gdt + 0x1d], 0x93
	shr	eax, 24
	mov	[gdt + 0x1f], al
	mov	ah, 0x87
	mov	si, gdt
	int	0x15
	jnc	1f
	inc	word ptr [movebad]
1:	pop	es
	popad
	ret
movebad: .word	0

/* the bars in mode 101h's linear frame buffer: 24 lines at a time */
draw_lfb8:
	pushad
	mov	word ptr [movebad], 0
	call	bars_line
	/* 24 copies of the line */
	push	es
	push	cs
	pop	es
	mov	di, offset block
	mov	cx, 24
1:	mov	si, offset linebuf
	push	cx
	mov	cx, 640
	rep	movsb
	pop	cx
	loop	1b
	pop	es
	mov	edi, [lfb]
	mov	bp, 20			/* 480 lines */
2:	mov	si, offset block
	mov	cx, 24 * 640 / 2
	call	move_up
	add	edi, 24 * 640
	dec	bp
	jnz	2b
	/* the top and bottom lines */
	mov	edi, [lfb]
	mov	si, offset whiteline
	mov	cx, 320
	call	move_up
	mov	edi, [lfb]
	add	edi, 479 * 640
	call	move_up
	CK16	10.4f.lfb.int15-87, [movebad], 0
	popad
	ret

/* 16 bits a pixel, vw x vh: red (F800h) on the left half, blue (001Fh)
   on the right; 12 lines at a time */
draw_lfb16:
	pushad
	mov	word ptr [movebad], 0
	push	es
	push	cs
	pop	es
	mov	di, offset block
	mov	dx, [vw]
	shr	dx, 1
	mov	cx, 12			/* 12 lines */
1:	push	cx
	mov	ax, 0xf800
	mov	cx, dx
	rep	stosw
	mov	ax, 0x001f
	mov	cx, dx
	rep	stosw
	pop	cx
	loop	1b
	pop	es
	mov	ax, [vh]
	mov	bl, 12
	div	bl
	movzx	bp, al			/* how many times 12 lines */
	movzx	ebx, word ptr [vw]
	imul	ebx, ebx, 24		/* the bytes of 12 lines */
	mov	edi, [lfb]
2:	mov	si, offset block
	mov	cx, bx
	shr	cx, 1
	call	move_up
	add	edi, ebx
	dec	bp
	jnz	2b
	CK16	10.4f.lfb16.int15-87, [movebad], 0
	popad
	ret

	.include "draw.inc"
whiteline = linebuf + 1024
blackline = linebuf + 2048
block	= 0x0a000		/* 24 lines of 640 bytes, past the program */
