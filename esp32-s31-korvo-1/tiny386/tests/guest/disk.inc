/*
 * disk.inc: the patterns of the disk tests, as tests/bioscheck.py writes
 * them into the images.  A sector at LBA L holds:
 *   read pattern     L (32 bits), "LRDT", then byte k is (k + 7L) & 255
 *   written pattern  L (32 bits), "WRTN", then byte k is (3k + L) & 255
 * The first is what the image has before the test; the second is what the
 * test writes, and says so with @wrote LBA COUNT (hex), which the harness
 * holds against the image afterwards.
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */

TAG_READ  = 0x5444524c		/* "LRDT" */
TAG_WRITE = 0x4e545257		/* "WRTN" */

bufseg:	.word	0		/* 64K for what is read */
wseg:	.word	0		/* 64K for what is written */

/* the two buffers, in the 128K after this program's segment */
disk_init:
	push	ax
	mov	ax, cs
	add	ax, 0x1000
	mov	[bufseg], ax
	add	ax, 0x1000
	mov	[wseg], ax
	pop	ax
	ret

/* byte k (si) of a sector whose LBA's low byte is bl, pattern bh (0 read,
   1 written): al */
pat_byte:
	push	cx
	mov	cx, si
	test	bh, bh
	jnz	1f
	mov	al, bl
	mov	ah, al
	shl	al, 3
	sub	al, ah			/* 7L */
	add	al, cl
	pop	cx
	ret
1:	mov	al, cl
	add	al, al
	add	al, cl			/* 3k */
	add	al, bl
	pop	cx
	ret

/* cx sectors at es:0 filled with pattern bh, the first one LBA eax */
fill_sectors:
	pushad
	xor	bp, bp
1:	mov	es:[bp], eax
	mov	dword ptr es:[bp + 4], TAG_READ
	test	bh, bh
	jz	2f
	mov	dword ptr es:[bp + 4], TAG_WRITE
2:	mov	bl, al
	mov	si, 8
3:	push	ax
	call	pat_byte
	mov	es:[bp + si], al
	pop	ax
	inc	si
	cmp	si, 512
	jb	3b
	add	bp, 512
	inc	eax
	loop	1b
	popad
	ret

/* cx sectors at es:0 against pattern bh from LBA eax: ZF set if they all
   hold it; else [vbad] the first LBA that does not */
verify:
	pushad
	xor	bp, bp
1:	cmp	es:[bp], eax
	jne	8f
	mov	edx, TAG_READ
	test	bh, bh
	jz	2f
	mov	edx, TAG_WRITE
2:	cmp	es:[bp + 4], edx
	jne	8f
	mov	bl, al
	mov	si, 8
3:	push	ax
	call	pat_byte
	cmp	es:[bp + si], al
	pop	ax
	jne	8f
	inc	si
	cmp	si, 512
	jb	3b
	add	bp, 512
	inc	eax
	loop	1b
	popad
	cmp	al, al			/* ZF set */
	ret
8:	mov	cs:[vbad], eax
	popad
	or	sp, sp			/* ZF clear */
	ret
vbad:	.long	0

/* @wrote LBA COUNT: eax and cx */
say_wrote:
	PUTS	"@wrote "
	call	puthex32
	call	putsp
	push	ax
	mov	ax, cx
	call	puthex16
	pop	ax
	call	putnl
	ret

/* the read pattern?  CKZ with the first bad LBA shown */
	.macro	DATA name, lba, count, kind=0
	push	es
	push	eax
	push	bx
	push	cx
	mov	es, [bufseg]
	mov	eax, \lba
	mov	cx, \count
	mov	bh, \kind
	call	verify
	jz	.Lok\@
	BAD	"\name", "not the sector's pattern, from"
	INFO32	"\name\().first-bad-lba", [vbad]
	jmp	.Le\@
.Lok\@:	OK	"\name"
.Le\@:	pop	cx
	pop	bx
	pop	eax
	pop	es
	.endm

/* CHS for int 13h: cx and dh from cylinder, head, sector */
	.macro	CHS c, h, s, drive
	mov	cx, (((\c) & 0xff) << 8) | (((\c) >> 2) & 0xc0) | (\s)
	mov	dx, ((\h) << 8) | (\drive)
	.endm
