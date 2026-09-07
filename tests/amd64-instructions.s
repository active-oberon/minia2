# The instructions the AMD64 disassembler is measured on, in the syntax of the assembler that
# decides what they mean: llvm-mc assembles this file, tests/amd64-decoder-check.sh feeds the bytes
# to Decoder/AMD64Decoder and to objdump, and compares what the two of them read back.
#
# What is here is chosen for the encoder's sake rather than the arithmetic's: immediates at every
# width boundary, every addressing form of ModRM and SIB, RIP-relative and absolute, the extended
# registers and the byte registers that need a REX to be named, every condition code in both jump
# widths and in setcc and cmovcc, the prefixes that mean a repeat and the ones that are part of the
# instruction, the SSE and SSE2 pairs that differ only by a 66 prefix, and enough x87 to reach the
# escape opcodes. Every condition code is written out rather than sampled: three tables of them had
# S standing where NS belongs, and a sampled one would have missed all three.
#
# Add instructions freely -- the check is a comparison and needs no expected output. Two things to
# know: a line whose target is a symbol gets a relocation and is decoded from bytes that are not
# there yet, so jumps go to `.+0x10` and the like; and objdump folds a 9BH wait prefix into the x87
# instruction after it, so `fwait` stays at the end of the file with nothing behind it.

	movq	%rsp, %rbp
	movl	%eax, %edx
	movw	%ax, %dx
	movb	%al, %dl
	movq	%r15, %r8
	movb	%spl, %dil
	movq	$1, %rax
	movl	$0x7fffffff, %eax
	movl	$0x80000000, %eax
	movq	$0x7fffffff, %rax
	movabsq	$0x80000000, %rax
	movabsq	$0xffffffff, %rax
	movabsq	$0x123456789abcdef, %rax
	movq	(%rax), %rbx
	movq	8(%rax), %rbx
	movq	0x12345678(%rax), %rbx
	movq	(%rax,%rcx,4), %rbx
	movq	0x40(%rax,%rcx,8), %rbx
	movq	(,%rcx,2), %rbx
	movq	0x1234(%rip), %rbx
	movq	%rbx, 0x10(%r13)
	movq	%rbx, (%r12,%r9,4)
	leaq	0x20(%rsp), %rdi
	addq	%rcx, %rax
	addq	$0x7f, %rax
	addq	$0x80, %rax
	addl	$0x1234, %ecx
	adcq	%rcx, %rax
	subq	%rdx, %r10
	sbbl	%eax, %ebx
	cmpq	$0, %rax
	cmpb	$0x41, (%rdi)
	testq	%rax, %rax
	testb	$1, %al
	andq	%rsi, %rdi
	orl	%eax, %ecx
	xorq	%rax, %rax
	notq	%rbx
	negl	%esi
	incq	%rax
	decw	%bx
	imulq	%rcx
	imulq	%rcx, %rax
	imulq	$3, %rcx, %rax
	mulq	%rbx
	divq	%rcx
	idivl	%esi
	cqto
	cltq
	shlq	$1, %rax
	shlq	$7, %rax
	shrq	%cl, %rbx
	sarl	$31, %eax
	rolw	$3, %ax
	rorb	$1, %dl
	shldq	$4, %rcx, %rax
	movzbl	%al, %ecx
	movzwq	%ax, %rcx
	movsbl	%dl, %eax
	movswq	%ax, %rdx
	movslq	%eax, %rdx
	cmovel	%eax, %ecx
	cmovneq	%rax, %rcx
	setg	%al
	setae	(%rdi)
	btq	$5, %rax
	btsq	%rcx, (%rdx)
	bsfq	%rax, %rcx
	bsrl	%eax, %ecx
	bswapq	%rax
	xchgq	%rax, %rbx
	xaddl	%eax, (%rdi)
	cmpxchgq	%rcx, (%rdx)
	lock cmpxchgq	%rcx, (%rdx)
	lock incq	(%rax)
	pushq	%rbp
	pushq	$0x10
	popq	%rbp
	leave
	ret
	retq	$8
	int3
	nop
	nopw	%ax
	nopl	(%rax)
	hlt
	cpuid
	rdtsc
	syscall
	pause
	mfence
	sfence
	lfence
	callq	*%rax
	callq	*(%rdi)
	jmpq	*%rcx
	cld
	std
	rep movsb %ds:(%rsi), %es:(%rdi)
	rep stosq %rax, %es:(%rdi)
	repne scasb %es:(%rdi), %al
	movss	%xmm1, %xmm0
	movsd	(%rax), %xmm3
	movaps	%xmm2, (%rdi)
	movapd	%xmm5, %xmm6
	movdqa	(%rsi), %xmm7
	movdqu	%xmm8, (%r9)
	movd	%eax, %xmm0
	movq	%rax, %xmm1
	movq	%xmm2, %rdx
	addss	%xmm1, %xmm0
	addsd	%xmm3, %xmm2
	subps	%xmm1, %xmm0
	mulpd	%xmm4, %xmm5
	divsd	%xmm1, %xmm0
	sqrtsd	%xmm2, %xmm3
	minss	%xmm1, %xmm0
	maxsd	%xmm1, %xmm0
	xorps	%xmm0, %xmm0
	andpd	%xmm1, %xmm2
	pxor	%xmm3, %xmm3
	paddd	%xmm1, %xmm0
	pcmpeqb	%xmm1, %xmm0
	punpcklbw	%xmm1, %xmm0
	pshufd	$0x1b, %xmm1, %xmm0
	cvtsi2sdl	%eax, %xmm0
	cvtsi2sdq	%rax, %xmm0
	cvtsd2ss	%xmm1, %xmm0
	cvttsd2si	%xmm0, %eax
	cvttss2siq	%xmm0, %rax
	ucomisd	%xmm1, %xmm0
	comiss	%xmm1, %xmm0
	unpcklps	%xmm1, %xmm0
	cmpsd	$0, %xmm1, %xmm0
	fldl	(%rax)
	fstpl	(%rax)
	fildl	(%rax)
	faddp	%st, %st(1)
	fmul	%st(2), %st
	fchs
	fsqrt
	fnstcw	(%rax)
	rolq	%cl, %rax
	rorq	$8, %rbx
	rclb	$1, %al
	rcrl	%cl, %ecx
	sall	$4, %eax
	shrdq	%cl, %rcx, %rax
	testl	$0x1234, %eax
	notb	(%rdi)
	negq	(%rax,%rbx,2)
	mulb	%dl
	imulb	%dl
	divb	%dl
	idivq	(%rcx)
	addb	$0x7f, %al
	orq	$0x1234, (%rax)
	adcl	$-1, %ecx
	sbbq	$0x10, %rdx
	andw	$0x8000, %ax
	xorb	$0xff, (%rsi)
	cmpl	$0x100, 0x8(%rbp)
	incl	(%rbx)
	decq	8(%rsp)
	callq	*8(%rax,%rcx,8)
	pushq	(%rdi)
	btrq	$63, %rax
	btcl	$7, (%rdi)
	cmpxchg8b	(%rdi)
	cmpxchg16b	(%rdi)
	movb	%ah, %al
	movb	%ch, %dh
	movb	%bh, %bl
	movq	%fs:0x28, %rax
	movl	%gs:0x10, %eax
	movabsq	0x123456789abcdef, %rax
	movabsq	%rax, 0x123456789abcdef
	xchgq	%rbx, %rax
	xchgl	%ecx, %eax
	cbtw
	cwtd
	cwtl
	clc
	stc
	cmc
	sahf
	lahf
	jo	.+0x10
	jno	.+0x10
	jb	.+0x10
	jae	.+0x10
	je	.+0x10
	jne	.+0x10
	jbe	.+0x10
	ja	.+0x10
	js	.+0x10
	jns	.+0x10
	jp	.+0x10
	jnp	.+0x10
	jl	.+0x10
	jge	.+0x10
	jle	.+0x10
	jg	.+0x10
	je	.+0x1000
	jmp	.+0x2000
	jmp	.+0x10
	callq	.+0x400
	loop	.+0x8
	loope	.+0x8
	loopne	.+0x8
	jrcxz	.+0x8
	seto	%al
	setno	%bl
	sets	%cl
	setns	%dl
	setp	(%rax)
	setnp	%sil
	enter	$0x20, $0
	movw	$0x1234, %ax
	movw	(%rax), %bx
	addw	%cx, %dx
	pushw	%ax
	incw	%cx
	movzbw	%al, %cx
	xchgw	%bx, %ax
	movdqu	(%rdi), %xmm0
	movddup	%xmm1, %xmm0
	lddqu	(%rdi), %xmm0
	haddpd	%xmm1, %xmm0
	hsubps	%xmm1, %xmm0
	cvtps2pd	%xmm1, %xmm0
	cvtpd2ps	%xmm1, %xmm0
	cvtdq2ps	%xmm1, %xmm0
	cvtps2dq	%xmm1, %xmm0
	cvttps2dq	%xmm1, %xmm0
	cvtss2sd	%xmm1, %xmm0
	pmovmskb	%xmm0, %eax
	movmskps	%xmm0, %eax
	movmskpd	%xmm0, %eax
	psrldq	$4, %xmm0
	pslldq	$8, %xmm1
	psrlq	$16, %xmm2
	psllw	%xmm1, %xmm0
	psraw	$3, %xmm0
	shufps	$0x39, %xmm1, %xmm0
	unpckhpd	%xmm1, %xmm0
	packuswb	%xmm1, %xmm0
	pmullw	%xmm1, %xmm0
	pmuludq	%xmm1, %xmm0
	pavgb	%xmm1, %xmm0
	psadbw	%xmm1, %xmm0
	pmaxub	%xmm1, %xmm0
	pminsw	%xmm1, %xmm0
	pandn	%xmm1, %xmm0
	por	%xmm1, %xmm0
	psubusb	%xmm1, %xmm0
	paddsw	%xmm1, %xmm0
	pcmpgtd	%xmm1, %xmm0
	pextrw	$2, %xmm0, %eax
	pinsrw	$1, %eax, %xmm0
	prefetcht0	(%rdi)
	movnti	%eax, (%rdi)
	movntdq	%xmm0, (%rdi)
	ldmxcsr	(%rdi)
	stmxcsr	(%rdi)
	fld	%st(1)
	fstp	%st(2)
	fadds	(%rax)
	fsubl	(%rax)
	fmulp	%st, %st(1)
	fdivrp	%st, %st(3)
	fcomp	%st(1)
	fucomip	%st(1), %st
	fisttpl	(%rax)
	fists	(%rax)
	fabs
	fld1
	fldz
	fldpi
	fpatan
	fyl2x
	fprem
	frndint
	fscale
	fxch	%st(1)
	fincstp
	fnclex
	fninit
	fnstsw	%ax
	fldcw	(%rax)
	jo	.+0x1000
	jno	.+0x1000
	jb	.+0x1000
	jae	.+0x1000
	je	.+0x1000
	jne	.+0x1000
	jbe	.+0x1000
	ja	.+0x1000
	js	.+0x1000
	jns	.+0x1000
	jp	.+0x1000
	jnp	.+0x1000
	jl	.+0x1000
	jge	.+0x1000
	jle	.+0x1000
	jg	.+0x1000
	seto	%al
	setno	%al
	setb	%al
	setae	%al
	sete	%al
	setne	%al
	setbe	%al
	seta	%al
	sets	%al
	setns	%al
	setp	%al
	setnp	%al
	setl	%al
	setge	%al
	setle	%al
	setg	%al
	cmovol	%eax, %ecx
	cmovnol	%eax, %ecx
	cmovbl	%eax, %ecx
	cmovael	%eax, %ecx
	cmovel	%eax, %ecx
	cmovnel	%eax, %ecx
	cmovbel	%eax, %ecx
	cmoval	%eax, %ecx
	cmovsl	%eax, %ecx
	cmovnsl	%eax, %ecx
	cmovpl	%eax, %ecx
	cmovnpl	%eax, %ecx
	cmovll	%eax, %ecx
	cmovgel	%eax, %ecx
	cmovlel	%eax, %ecx
	cmovgl	%eax, %ecx
	fnop
	jrcxz	.+0x4
	movq	%cr0, %rax
	movq	%rax, %dr0
	fwait
