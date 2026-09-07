# The instructions the IA-32 disassembler is measured on, in the syntax of the assembler that
# decides what they mean. The 32-bit twin of tests/amd64-instructions.s, and the same rules apply:
# llvm-mc assembles it, tests/decoder-check.sh compares what I386Decoder reads back against what
# objdump reads. I386Decoder is here for the objects of a target this tree no longer builds, which
# is exactly why nothing had ever read its output.
#
# What is here and not in the AMD64 corpus: the instructions long mode dropped -- PUSHA, POPA, the
# 32-bit absolute address as a whole operand -- and what the two decoders share is written out
# again rather than assumed, because they are two separate tables of the same instruction set.
#
# What is deliberately absent: everything SSE. This decoder's tables stop at the 387, and a byte it
# does not know stops the sweep rather than being skipped, so an SSE instruction here would hide
# every line after it. Both of those are recorded findings, not something this corpus works around.
#
# Two things to know before adding lines: a target that is a symbol gets a relocation and would be
# decoded from bytes that are not there yet, so jumps go to `.+0x10`; and objdump folds a 9BH wait
# prefix into the x87 instruction after it, so `fwait` stays last with nothing behind it.

	movl	%esp, %ebp
	movw	%ax, %dx
	movb	%al, %dl
	movl	$1, %eax
	movl	$0x7fffffff, %eax
	movl	$0x80000000, %eax
	movl	(%eax), %ebx
	movl	8(%eax), %ebx
	movl	0x12345678(%eax), %ebx
	movl	(%eax,%ecx,4), %ebx
	movl	0x40(%eax,%ecx,8), %ebx
	movl	(,%ecx,2), %ebx
	movl	0x1234, %ebx
	leal	0x20(%esp), %edi
	movl	%ebx, 0x10(%ebp)
	addl	%ecx, %eax
	addl	$0x7f, %eax
	addl	$0x80, %eax
	adcl	%ecx, %eax
	subl	%edx, %esi
	sbbl	%eax, %ebx
	cmpl	$0, %eax
	cmpb	$0x41, (%edi)
	testl	%eax, %eax
	testb	$1, %al
	andl	%esi, %edi
	orl	%eax, %ecx
	xorl	%eax, %eax
	notl	%ebx
	negl	%esi
	incl	%eax
	decw	%bx
	imull	%ecx
	imull	%ecx, %eax
	imull	$3, %ecx, %eax
	mull	%ebx
	divl	%ecx
	idivl	%esi
	cltd
	cwtl
	shll	$1, %eax
	shll	$7, %eax
	shrl	%cl, %ebx
	sarl	$31, %eax
	rolw	$3, %ax
	rorb	$1, %dl
	shldl	$4, %ecx, %eax
	shrdl	%cl, %ecx, %eax
	movzbl	%al, %ecx
	movzwl	%ax, %ecx
	movsbl	%dl, %eax
	movswl	%ax, %edx
	cmovel	%eax, %ecx
	cmovnel	%eax, %ecx
	cmovsl	%eax, %ecx
	cmovnsl	%eax, %ecx
	cmoval	%eax, %ecx
	cmovbl	%eax, %ecx
	sete	%al
	setne	%bl
	sets	%cl
	setns	%dl
	seta	%al
	setb	%bl
	setg	%al
	setle	%bl
	btl	$5, %eax
	btsl	%ecx, (%edx)
	btrl	$31, %eax
	btcl	$7, (%edi)
	bsfl	%eax, %ecx
	bsrl	%eax, %ecx
	bswapl	%eax
	xchgl	%eax, %ebx
	xaddl	%eax, (%edi)
	cmpxchgl	%ecx, (%edx)
	lock cmpxchgl	%ecx, (%edx)
	lock incl	(%eax)
	pushl	%ebp
	pushl	$0x10
	popl	%ebp
	pusha
	popa
	pushf
	popf
	leave
	ret
	ret	$8
	int3
	int	$0x21
	nop
	hlt
	cpuid
	rdtsc
	cld
	std
	clc
	stc
	cmc
	sahf
	lahf
	calll	*%eax
	calll	*(%edi)
	jmpl	*%ecx
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
	js	.+0x1000
	jns	.+0x1000
	jmp	.+0x2000
	loop	.+0x8
	loope	.+0x8
	loopne	.+0x8
	jecxz	.+0x8
	rep movsb %ds:(%esi), %es:(%edi)
	rep stosl %eax, %es:(%edi)
	repne scasb %es:(%edi), %al
	flds	(%eax)
	fldl	(%eax)
	fstpl	(%eax)
	fildl	(%eax)
	faddp	%st, %st(1)
	fmul	%st(2), %st
	fchs
	fsqrt
	fld1
	fldz
	fnstcw	(%eax)
	fnstsw	%ax
	movl	%cr0, %eax
	movl	%eax, %dr0
	movl	%fs:0x10, %eax
	movl	%gs:(%eax), %ebx
	fwait
