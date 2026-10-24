/*
 * bios.inc: what the BIOS test programs (tests/guest/b*.S) have in common.
 *
 * Each program is a DOS .COM file that calls the BIOS and says what came
 * back on the BIOS's debug port, 0x402, a line at a time.  tiny386-korvo
 * sends that port to its -log file.  The lines that matter begin with @:
 *
 *   @ok NAME [what was seen]
 *   @bad NAME what was seen, and what was wanted
 *   @info NAME what was seen, for the record
 *   @text NAME COLS ROWS HEX   a text screen as it is in video memory
 *   @font NAME HEX             a font out of the BIOS
 *   @shot NAME                 a picture is up: whoever runs the test looks
 *                              at the screen and then presses a key, which
 *                              the program waits for
 *   @done                      the end
 *
 * At @done the byte at 0000:04F0 (the BIOS's "intra-application
 * communication area", as BENCH.COM uses it) becomes 0xAF, which ends
 * tiny386-korvo -marks.  The program then waits there for ever.
 * tests/bioscheck.py reads the lines; tests/bios-tests.sh runs it all.
 *
 * The routines keep every register but those they say they return, and work
 * whatever DS and ES are: their strings are in this program's segment.
 * 386 instructions are used (the emulated machine is a 486).
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */

	.intel_syntax noprefix
	.code16

/* ---------------------------------------------------------------- macros */

/* a string, inline, to the debug port */
	.macro	PUTS str
	push	si
	mov	si, offset .Ls\@
	call	puts
	pop	si
	jmp	.Le\@
.Ls\@:	.asciz	"\str"
.Le\@:
	.endm

/* the start of a result line: @ok, @bad or @info, and the name */
	.macro	HEAD kind, name
	push	si
	mov	si, offset .Ls\@
	call	puts
	pop	si
	jmp	.Le\@
.Ls\@:	.asciz	"@\kind \name"
.Le\@:
	.endm

	.macro	OK name, note=""
	HEAD	ok, "\name \note\n"
	.endm

	.macro	BAD name, note=""
	HEAD	bad, "\name \note\n"
	.endm

/* CK8 NAME, SRC, WANT: ok if SRC (8 bits) is WANT.  SRC is read first, then
   WANT, so WANT may not be al or dl; neither may be si. */
	.macro	CK8 name, src, want
	push	si
	push	ax
	push	dx
	mov	al, \src
	mov	dl, \want
	mov	si, offset .Ln\@
	call	ck8
	pop	dx
	pop	ax
	pop	si
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* CK16 NAME, SRC, WANT: the same with 16 bits (not ax, dx or si for WANT) */
	.macro	CK16 name, src, want
	push	si
	push	ax
	push	dx
	mov	ax, \src
	mov	dx, \want
	mov	si, offset .Ln\@
	call	ck16
	pop	dx
	pop	ax
	pop	si
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* CK32 NAME, SRC, WANT: and with 32 (not eax, edx or esi for WANT) */
	.macro	CK32 name, src, want
	push	si
	push	eax
	push	edx
	mov	eax, \src
	mov	edx, \want
	mov	si, offset .Ln\@
	call	ck32
	pop	edx
	pop	eax
	pop	si
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* CKNC NAME: ok if the carry flag is clear; CKC NAME: ok if it is set;
   CKZ NAME: ok if the zero flag is set.  AX is shown either way. */
	.macro	CKFLAG name, how
	push	si
	mov	si, offset .Ln\@
	call	\how
	pop	si
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm
	.macro	CKNC name
	CKFLAG	"\name", ck_nc
	.endm
	.macro	CKC name
	CKFLAG	"\name", ck_c
	.endm
	.macro	CKZ name
	CKFLAG	"\name", ck_z
	.endm

/* INFO8/16/32 NAME, SRC: a value for the record */
	.macro	INFO8 name, src
	push	ax
	mov	al, \src
	HEAD	info, "\name "
	call	puthex8
	call	putnl
	pop	ax
	.endm
	.macro	INFO16 name, src
	push	ax
	mov	ax, \src
	HEAD	info, "\name "
	call	puthex16
	call	putnl
	pop	ax
	.endm
	.macro	INFO32 name, src
	push	eax
	mov	eax, \src
	HEAD	info, "\name "
	call	puthex32
	call	putnl
	pop	eax
	.endm

/* SHOT NAME: say that a picture is up, and wait for the key that says it
   has been looked at */
	.macro	SHOT name
	PUTS	"@shot \name\n"
	call	waitkey
	.endm

/* the end */
	.macro	DONE
	jmp	alldone
	.endm

/* ---------------------------------------------------------------- output */

/* al to the debug port */
putc:
	push	dx
	mov	dx, 0x402
	out	dx, al
	pop	dx
	ret

/* the string at cs:si */
puts:
	push	ax
	push	si
1:	mov	al, cs:[si]
	or	al, al
	jz	2f
	call	putc
	inc	si
	jmp	1b
2:	pop	si
	pop	ax
	ret

putnl:
	push	ax
	mov	al, 10
	call	putc
	pop	ax
	ret

putsp:
	push	ax
	mov	al, ' '
	call	putc
	pop	ax
	ret

/* the low four bits of al, in hex */
puthex4:
	push	ax
	and	al, 15
	add	al, '0'
	cmp	al, '9'
	jbe	1f
	add	al, 'a' - '0' - 10
1:	call	putc
	pop	ax
	ret

puthex8:
	push	ax
	push	ax
	shr	al, 4
	call	puthex4
	pop	ax
	call	puthex4
	pop	ax
	ret

puthex16:
	xchg	al, ah
	call	puthex8
	xchg	al, ah
	call	puthex8
	ret

puthex32:
	push	eax
	shr	eax, 16
	call	puthex16
	pop	eax
	call	puthex16
	ret

/* cx bytes from ds:si, in hex, nothing between them */
hexdump:
	push	ax
	push	cx
	push	si
	jcxz	2f
1:	lodsb
	call	puthex8
	loop	1b
2:	pop	si
	pop	cx
	pop	ax
	ret

/* the name at cs:si after "@ok " or "@bad " */
say_ok:
	push	si
	mov	si, offset s_ok
	call	puts
	pop	si
	jmp	puts
say_bad:
	push	si
	mov	si, offset s_bad
	call	puts
	pop	si
	jmp	puts
s_ok:	.asciz	"@ok "
s_bad:	.asciz	"@bad "
s_got:	.asciz	" got="
s_want:	.asciz	" want="

/* al got, dl wanted, cs:si the name; ZF set if they are equal */
ck8:
	cmp	al, dl
	jne	1f
	call	say_ok
	call	putsp
	call	puthex8
	call	putnl
	cmp	al, al
	ret
1:	call	say_bad
	push	si
	mov	si, offset s_got
	call	puts
	call	puthex8
	mov	si, offset s_want
	call	puts
	push	ax
	mov	al, dl
	call	puthex8
	pop	ax
	call	putnl
	pop	si
	cmp	al, dl
	ret

ck16:
	cmp	ax, dx
	jne	1f
	call	say_ok
	call	putsp
	call	puthex16
	call	putnl
	cmp	ax, ax
	ret
1:	call	say_bad
	push	si
	mov	si, offset s_got
	call	puts
	call	puthex16
	mov	si, offset s_want
	call	puts
	push	ax
	mov	ax, dx
	call	puthex16
	pop	ax
	call	putnl
	pop	si
	cmp	ax, dx
	ret

ck32:
	cmp	eax, edx
	jne	1f
	call	say_ok
	call	putsp
	call	puthex32
	call	putnl
	cmp	eax, eax
	ret
1:	call	say_bad
	push	si
	mov	si, offset s_got
	call	puts
	call	puthex32
	mov	si, offset s_want
	call	puts
	push	eax
	mov	eax, edx
	call	puthex32
	pop	eax
	call	putnl
	pop	si
	cmp	eax, edx
	ret

/* the flags as the caller left them decide; ax is shown */
ck_nc:
	jc	ck_isbad
	jmp	ck_isok
ck_c:
	jnc	ck_isbad
	jmp	ck_isok
ck_z:
	jnz	ck_isbad
ck_isok:
	call	say_ok
	push	si
	mov	si, offset s_ax
	call	puts
	call	puthex16
	call	putnl
	pop	si
	ret
ck_isbad:
	call	say_bad
	push	si
	mov	si, offset s_ax
	call	puts
	call	puthex16
	call	putnl
	pop	si
	ret
s_ax:	.asciz	" ax="

/* ---------------------------------------------------------------- other */

/* a key from the BIOS, which the test's driver presses */
waitkey:
	push	ax
	xor	ah, ah
	int	0x16
	pop	ax
	ret

/* the end: @done, and the mark */
alldone:
	PUTS	"@done\n"
	push	0
	pop	es
	mov	byte ptr es:[0x4f0], 0xaf
	sti
1:	hlt
	jmp	1b

/* about cx ticks of the BIOS clock (18.2 a second) */
ticks:
	push	ax
	push	cx
	push	ds
	push	0x40
	pop	ds
1:	mov	ax, ds:[0x6c]
2:	cmp	ax, ds:[0x6c]
	je	2b
	loop	1b
	pop	ds
	pop	cx
	pop	ax
	ret

/* the text screen at es:0, cx cells, as @text NAME COLS ROWS HEX: cs:si
   the name, dl the columns and dh the rows */
textdump:
	push	ax
	push	cx
	push	si
	push	ds
	PUTS	"@text "
	call	puts
	call	putsp
	mov	al, dl
	call	puthex8
	call	putsp
	mov	al, dh
	call	puthex8
	call	putsp
	push	es
	pop	ds
	xor	si, si
	shl	cx, 1
	call	hexdump
	call	putnl
	pop	ds
	pop	si
	pop	cx
	pop	ax
	ret
