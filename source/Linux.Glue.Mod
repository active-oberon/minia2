(* Minimal ELF header for self contained linux Oberon programs *)
(* Copyright (c) Felix Friedrich, ETH Zürich *)

MODULE Glue;

IMPORT SYSTEM, Trace;

CONST
	#IF ARM THEN
		base* = 10000H;
	#ELSIF ARM64 THEN
		(* a whole 64 kilobyte page: an AArch64 kernel may be built with a page size of 4, 16 or 64
			kilobytes, and the loader only maps a segment whose virtual address and file offset agree
			modulo the page size. 08048000H does not, on a 64 kilobyte page. *)
		base* = 400000H;
	#ELSE
		base* = 08048000H;
	#END
	debug* = {};
VAR
	last-: RECORD END; (* empty variable linked to end of kernel *)

	baseAdr*: ADDRESS;
	endAdr*: ADDRESS;

	dlsym-	: PROCEDURE {C} ( handle: ADDRESS; name: ADDRESS): ADDRESS;
	dlopen-	: PROCEDURE {C} ( pathname: ADDRESS; mode: INTEGER ): ADDRESS;
	dlclose-	: PROCEDURE {C} ( handle: ADDRESS );
	exit-		: PROCEDURE {C} (status: INTEGER);

	stackBottom-	: ADDRESS;	(* of main thread *)


	argc-: INTEGER;
	argv-: ADDRESS;
	environ-: ADDRESS;

	PROCEDURE {OPENING} EntryPoint;
	CODE
	#IF I386 OR ARM THEN
		; ELF header
		DB 07FH, 'ELF', 1, 1, 1, 0
		DD 0, 0
		DW 02
		#IF ARM THEN
			DW 40
		#ELSE
			DW 03
		#END
		DD 01
		DD entry + base; program entry point
		DD elfheadersize ; poffset
		DD 0 ; soffset
		#IF ARM THEN
		DD 0x5000400 ; flags: SYS 5 ABI + Hardware Float Support 0x400
		#ELSE
		DD 0
		#END;
		DW elfheadersize
		DW 20H
		DW 4 ; #program header table entries
		DW 0 ; section header table entry size
		DW 0 ; section header number of entries
		DW 0 ; section header names offset

		elfheadersize:

		; program header
		DD 1
		DD 0
		DD base ; vadr
		DD base ; padr
		#IF ARM THEN
		DD last - base; segment size (file)
		DD last - base; segment size (memory)
		#ELSE
		DD @last - base; segment size (file)
		DD @last - base; segment size (memory)
		#END
		DD 07
		DD 1000H; alignment
		
		; interpreter header
		DD 3
		DD interpretername; interpreter name offset
		DD interpretername + base; interpreter name
		DD interpretername + base; interpreter name
		DD interpretername_end - interpretername ; interpreter name length
		DD interpretername_end - interpretername ; interpreter name length
		DD 4H
		DD 1H

		; dynamic header
		DD 02H
		DD dynamicsection
		DD dynamicsection + base
		DD dynamicsection + base
		DD dynamicsection_end - dynamicsection ; size of dynamic section
		DD dynamicsection_end - dynamicsection ; size of dynamic section
		DD 06H
		DD 04H

		; The stack is not executable, and until 06.09.2026 nothing here said so. A Linux
		; kernel reads the absence of PT_GNU_STACK as a file built before the question was
		; asked, and grants the stack execute permission for compatibility -- so saying
		; nothing was not neutral, it asked for the old behaviour. Nothing in this runtime
		; executes from the stack: code arrives as loaded modules, in the heap.
		DD 6474E551H ; PT_GNU_STACK
		DD 0 ; offset
		DD 0 ; vaddr
		DD 0 ; paddr
		DD 0 ; segment size (file)
		DD 0 ; segment size (memory)
		DD 06H ; PF_R + PF_W, and deliberately no PF_X
		DD 10H ; alignment

		dynamicsection:
		DD 05H, base + stringtable
		DD 06H, symboltablebegin + base
		; DT_REL (11H) and not DT_RELA (07H): ELF32 on i386 and on ARM relocates through
		; Elf32_Rel, and glibc's loader for both defines ELF_MACHINE_NO_RELA -- a DT_RELA table
		; is read and then ignored, without a word. The symbol below stays NIL, and the first
		; thing Init does about it is ASSERT(dlsym # NIL), which is an INT 3 and reaches the
		; shell as "Trace/breakpoint trap". The addend is implicit: R_386_32 adds what is
		; already at the target, and the target is a variable, so it is zero.
		DD 11H, dlsymrelocation + base
		DD 12H, dlsymrelocation_end-dlsymrelocation ; size (relocationtable)
		DD 13H, 08H
		DD 0AH, stringtable_end - stringtable; size (stringtable)
		DD 0BH, 10H

		DD 01H, libname - stringtable; position of libname
		DD 0H, 0H ; sentinel
		dynamicsection_end:

	 	dlsymrelocation:
		#IF ARM THEN
		DD dlsym
		DB 02H ; relocation type 
		#ELSE
		DD @dlsym
		DB 01H ; relocation type 
		#END
		DB 01H, 00H, 00H; index of the symbol
		; no addend field here: an Elf32_Rel entry is eight bytes, not twelve
		dlsymrelocation_end:

		stringtable:
		DB 0H ; sentinel

		libname:
		DB 'libdl.so.2', 0

		dlsymname:
		DB 'dlsym', 0


		stringtable_end:

		ALIGN 4
		symboltablebegin:
		DD	0
		DD	0
		DD	0
		DB	0
		DB	0
		DW 0

		; dlsym symbol
		DD dlsymname - stringtable; position of dlsymname
		DD	0
		DD	0
		DB	12H ; info: global + function
		DB 0
		DW	0

		interpretername:
		#IF ARM THEN
		DB '/lib/ld-linux-armhf.so.3', 0
		#ELSE
		DB '/lib/ld-linux.so.2', 0
		#END
		interpretername_end:

		ALIGN 4

		entry:
	#ELSIF AMD64 THEN
		; ELF header
		DB 07FH, 'ELF', 2, 1, 1, 0
		DD 0, 0
		DW 02, 62
		DD 01
		DQ entry + base; program entry point
		DQ elfheadersize
		DQ 0
		DD 0
		DW elfheadersize
		DW 38H
		DW 4 ; #program header table entries
		DW 0
		DW 0
		DW 0

		elfheadersize:

		; program header
		DD 1
		DD 07
		DQ 0
		DQ base;
		DQ base;
		DQ @last - base; segment size (file)
		DQ @last - base; segment size (memory)
		DQ 1000H; alignment

		; interpreter header
		DD 3
		DD 4H
		DQ interpretername; interpreter name offset
		DQ interpretername + base; interpreter name
		DQ interpretername + base; interpreter name
		DQ interpretername_end - interpretername ; interpreter name length
		DQ interpretername_end - interpretername ; interpreter name length
		DQ 1H

		; dynamic header
		DD 02H
		DD 06H
		DQ dynamicsection
		DQ dynamicsection + base
		DQ dynamicsection + base
		DQ dynamicsection_end - dynamicsection ; size of dynamic section
		DQ dynamicsection_end - dynamicsection ; size of dynamic section
		DQ 08H

		; The stack is not executable, and until 06.09.2026 nothing here said so. A Linux
		; kernel reads the absence of PT_GNU_STACK as a file built before the question was
		; asked, and grants the stack execute permission for compatibility -- so saying
		; nothing was not neutral, it asked for the old behaviour. Nothing in this runtime
		; executes from the stack: code arrives as loaded modules, in the heap.
		DD 6474E551H ; PT_GNU_STACK
		DD 06H ; PF_R + PF_W, and deliberately no PF_X
		DQ 0 ; offset
		DQ 0 ; vaddr
		DQ 0 ; paddr
		DQ 0 ; segment size (file)
		DQ 0 ; segment size (memory)
		DQ 10H ; alignment

		dynamicsection:
		DQ 05H, base + stringtable
		DQ 06H, symboltablebegin + base
		DQ 07H, dlsymrelocation + base
		DQ 08H, dlsymrelocation_end-dlsymrelocation ; size (relocationtable)
		DQ 09H, 18H
		DQ 0AH, stringtable_end - stringtable; size (stringtable)
		DQ 0BH, 18H

		DQ 01H, libname - stringtable; position of libname
		DQ 0H, 0H ; sentinel
		dynamicsection_end:

	 	dlsymrelocation:
		DQ @dlsym
		DD 01H
		DD 01H ; index of the symbol
		DQ 0H
		dlsymrelocation_end:

		stringtable:
		DB 0H ; sentinel

		libname:
		DB 'libdl.so.2', 0

		dlsymname:
		DB 'dlsym', 0


		stringtable_end:

		ALIGN 8
		symboltablebegin:
		DD	0;
		DB	0
		DB	0
		DW 0
		DQ	0
		DQ	0

		; dlsym symbol
		DD dlsymname - stringtable; position of dlsymname
		DB	12H ; info: global + function
		DB 0
		DW	0
		DQ	0
		DQ	0

		interpretername:
		DB '/lib64/ld-linux-x86-64.so.2', 0
		interpretername_end:

		ALIGN 8

		entry:
	#ELSIF ARM64 THEN
		(* the same 64 bit ELF the AMD64 branch writes, differing in the three places the
			architecture appears: the machine number, the relocation type of the one dynamic symbol,
			and the name of the interpreter that resolves it *)
		; ELF header
		DB 07FH, 'ELF', 2, 1, 1, 0
		DD 0, 0
		DW 02, 183 ; EM_AARCH64
		DD 01
		DQ entry + base; program entry point
		DQ elfheadersize
		DQ 0
		DD 0
		DW elfheadersize
		DW 38H
		DW 5 ; #program header table entries
		DW 0
		DW 0
		DW 0

		elfheadersize:

		(*	PT_PHDR, the table describing itself. glibc's loader does without it -- it is handed the
			same thing in the auxiliary vector as AT_PHDR -- but Bionic looks for the header and
			refuses the file outright without it ("Could not find a PHDR: broken executable?"), which
			is the first thing an image for Android runs into. Every real linker emits it, so it is
			written for both. It has to precede the loadable segments, and it lies inside the one
			below, whose offset is zero and which therefore maps the headers along with the rest. *)
		DD 6
		DD 4H
		DQ elfheadersize
		DQ base + elfheadersize
		DQ base + elfheadersize
		DQ 5 * 38H; segment size (file)
		DQ 5 * 38H; segment size (memory)
		DQ 8H; alignment

		; program header
		DD 1
		DD 07
		DQ 0
		DQ base;
		DQ base;
		(* `last` rather than `@last`: the '@' of the AMD64 assembler resolves the identifier in the
			scope around the code block and writes the module qualified name of it, and the shared
			assembler behind the A64 one makes a linker symbol out of the bare text instead, which
			nothing defines. The ARM branch writes it without the '@' for the same reason. *)
		DQ last - base; segment size (file)
		DQ last - base; segment size (memory)
		DQ 1000H; alignment

		; interpreter header
		DD 3
		DD 4H
		DQ interpretername; interpreter name offset
		DQ interpretername + base; interpreter name
		DQ interpretername + base; interpreter name
		DQ interpretername_end - interpretername ; interpreter name length
		DQ interpretername_end - interpretername ; interpreter name length
		DQ 1H

		; dynamic header
		DD 02H
		DD 06H
		DQ dynamicsection
		DQ dynamicsection + base
		DQ dynamicsection + base
		DQ dynamicsection_end - dynamicsection ; size of dynamic section
		DQ dynamicsection_end - dynamicsection ; size of dynamic section
		DQ 08H

		; The stack is not executable, and until 06.09.2026 nothing here said so. A Linux
		; kernel reads the absence of PT_GNU_STACK as a file built before the question was
		; asked, and grants the stack execute permission for compatibility -- so saying
		; nothing was not neutral, it asked for the old behaviour. Nothing in this runtime
		; executes from the stack: code arrives as loaded modules, in the heap.
		DD 6474E551H ; PT_GNU_STACK
		DD 06H ; PF_R + PF_W, and deliberately no PF_X
		DQ 0 ; offset
		DQ 0 ; vaddr
		DQ 0 ; paddr
		DQ 0 ; segment size (file)
		DQ 0 ; segment size (memory)
		DQ 10H ; alignment

		dynamicsection:
		DQ 05H, base + stringtable
		DQ 06H, symboltablebegin + base
		DQ 07H, dlsymrelocation + base
		DQ 08H, dlsymrelocation_end-dlsymrelocation ; size (relocationtable)
		DQ 09H, 18H
		DQ 0AH, stringtable_end - stringtable; size (stringtable)
		DQ 0BH, 18H

		DQ 01H, libname - stringtable; position of libname
		DQ 0H, 0H ; sentinel
		dynamicsection_end:

	 	dlsymrelocation:
		DQ dlsym
		DD 0101H ; R_AARCH64_ABS64
		DD 01H ; index of the symbol
		DQ 0H
		dlsymrelocation_end:

		stringtable:
		DB 0H ; sentinel

		libname:
		(*	The one library this image asks the dynamic linker for, and `dlsym` out of it is the one
			symbol: everything else the system resolves for itself through that. Bionic, the C
			library of Android, drops the version from these names and puts its dynamic linker
			somewhere else entirely. Unlike the library names in Unix, neither string can be tried
			and retried -- the loader reads them before any of our code runs -- which is why Android
			needs an image compiled with --define=ANDROID rather than the same one. *)
		#IF ANDROID THEN
			DB 'libdl.so', 0
		#ELSE
			DB 'libdl.so.2', 0
		#END

		dlsymname:
		DB 'dlsym', 0


		stringtable_end:

		ALIGN 8
		symboltablebegin:
		DD	0;
		DB	0
		DB	0
		DW 0
		DQ	0
		DQ	0

		; dlsym symbol
		DD dlsymname - stringtable; position of dlsymname
		DB	12H ; info: global + function
		DB 0
		DW	0
		DQ	0
		DQ	0

		interpretername:
		#IF ANDROID THEN
			DB '/system/bin/linker64', 0
		#ELSE
			DB '/lib/ld-linux-aarch64.so.1', 0
		#END
		interpretername_end:

		ALIGN 8

		entry:
	#ELSE
		unimplemented
	#END
	END EntryPoint;

	(*
	PROCEDURE {CLOSING} ExitPoint;
	BEGIN
		Trace.String("exiting"); Trace.Ln;
		exit(0);
	END ExitPoint;
	*)

	PROCEDURE putc*(file: ADDRESS; c: CHAR);
	CODE
	#IF I386 THEN
		MOV EAX, 4
		MOV EBX, [EBP + file]
		LEA ECX, [EBP + c]
		MOV EDX, 1
		INT 80H
	#ELSIF AMD64 THEN
		MOV EAX, 1
		MOV RDI, [RBP + file]
		LEA RSI, [RBP + c]
		MOV RDX, 1
		SYSCALL
	#ELSIF ARM THEN
		ldr	r0, [fp, #+file]
		add r1, fp, #c
		mov	r2, #1
		mov	r7, #4
		swi	#0	; sys_write
	#ELSIF ARM64 THEN
		ldr x0, [fp, #file]
		add x1, fp, #c
		mov x2, #1
		mov x8, #64	; __NR_write
		svc #0
	#ELSE
		unimplemented
	#END
	END putc;

	PROCEDURE Dlsym*(handle: ADDRESS; CONST name: ARRAY OF CHAR; adr: ADDRESS);
	VAR val: ADDRESS;
	BEGIN {UNCOOPERATIVE, UNCHECKED}
		val := dlsym(handle, ADDRESS OF name[0]);
		SYSTEM.PUT(adr, val);
	END Dlsym;

	PROCEDURE Char(c: CHAR);
	BEGIN {UNCOOPERATIVE, UNCHECKED}
		putc(1, c);
	END Char;

	PROCEDURE Init;
	VAR i: ADDRESS;
	BEGIN {UNCOOPERATIVE, UNCHECKED}
		baseAdr := ADDRESS OF EntryPoint;
		endAdr := ADDRESS OF last;

		Trace.Init;
		Trace.Char := Char;

		stackBottom := ADDRESSOF( i ) + 2*SIZEOF(ADDRESS);

		ASSERT(dlsym # NIL);
		Dlsym(0,"dlopen", ADDRESS OF dlopen);
		ASSERT(dlopen # NIL);
		Dlsym( 0, "dlclose", ADDRESS OF dlclose);
		ASSERT(dlclose # NIL);
		Dlsym(0,"exit", ADDRESS OF exit);
		ASSERT(exit # NIL);
	END Init;

	PROCEDURE {OPENING} Init0;
	BEGIN {UNCOOPERATIVE, UNCHECKED}
		CODE
		#IF I386 THEN
			; argc at esp
			; argv at esp+4
			; 0 at esp+4+argc*4
			; env at esp+4+argc*4+4 = (2+argc)<<2 + esp
			MOV EAX, [ESP]
			MOV [argc], EAX
			LEA EAX, [ESP+4]
			MOV [argv], EAX
			MOV EAX, [ESP]
			ADD EAX, 2
			SHL EAX, 2
			ADD EAX, ESP
			MOV [environ], EAX
		#ELSIF AMD64 THEN
			; argc at rsp
			; argv at rsp+8
			; 0 at rsp+8+argc*8
			; env at rsp+8+argc*8+8 = (2+argc)<<3 + rsp
			MOV EAX, [RSP]
			MOV [argc], EAX
			LEA RAX, [RSP+8]
			MOV [argv], RAX
			MOV RAX, [RSP]
			ADD RAX, 2
			SHL RAX, 3
			ADD RAX, RSP
			MOV [environ], RAX
		#ELSIF ARM THEN
			ldr r0, [sp, #0]
			ldr r7, [pc, #Aargc-$-8]
			str r0, [r7, #0]
			add r1, sp, #4
			ldr r7, [pc, #Aargv-$-8]
			str r1, [r7, #0]
			add r2, sp, #8
;			lsl r0, r0, #2
			add r2, r2, r0, LSL #2
			ldr r7, [pc, #Aenv-$-8]
			str r2, [r7, #0]
			b cont
			Aargc: 		DD argc
			Aargv: 		DD argv
			Aenv: 		DD environ ;
			cont:
		#ELSIF ARM64 THEN
			; argc at sp
			; argv at sp+8
			; 0 at sp+8+argc*8
			; env at sp+16+argc*8
			;
			; An {OPENING} procedure has no prologue -- the intermediate backend emits none -- so this
			; runs on the stack the kernel built, with sp still pointing at argc and every register
			; free. The addresses of the three variables cannot be built by an instruction, so they
			; are read out of a literal behind the branch, which is how the code generator does it too.
			ldr x0, [sp, #0]
			ldr x7, Aargc
			str w0, [x7, #0]
			add x1, sp, #8
			ldr x7, Aargv
			str x1, [x7, #0]
			add x2, sp, #16
			add x2, x2, x0, lsl #3
			ldr x7, Aenv
			str x2, [x7, #0]
			b cont
			Aargc:		DQ argc
			Aargv:		DQ argv
			Aenv:		DQ environ
			cont:
	 #ELSE
			unimplemented
		#END
		END;
		Init;
	END Init0;

END Glue.



System.FreeDownTo FoxIntermediateBackend ~

System.DoCommands
	Compiler.Compile -p=Unix32
		I386.Builtins.Mod Trace.Mod Linux.Glue.Mod Linux.I386.Unix.Mod Unix.I386.Machine.Mod Heaps.Mod  Modules.Mod
		Unix.Objects.Mod
		Unix.Kernel.Mod KernelLog.Mod Plugins.Mod Streams.Mod
		Pipes.Mod Commands.Mod I386.Reals.Mod Reflection.Mod TrapWriters.Mod CRC.Mod SystemVersion.Mod
		Unix.StdIO.Mod Unix.Traps.Mod Locks.Mod Unix.Clock.Mod Disks.Mod Files.Mod Dates.Mod Strings.Mod
		UTF8Strings.Mod FileTrapWriter.Mod Caches.Mod DiskVolumes.Mod OldDiskVolumes.Mod RAMVolumes.Mod
		DiskFS.Mod OldDiskFS.Mod OberonFS.Mod FATVolumes.Mod FATFiles.Mod ISO9660Volumes.Mod
		ISO9660Files.Mod Unix.UnixFiles.Mod RelativeFileSystem.Mod BitSets.Mod StringPool.Mod DIagnostics.Mod
		ObjectFile.Mod GenericLinker.Mod Loader.Mod Unix.BootConsole.Mod
	~

	Linker.Link --fileFormat=Raw --fileName=simple_elf --extension=.GofU --displacement=08048000H
		Builtins Trace Glue Unix Machine Heaps Modules Objects Kernel KernelLog
Streams Commands StdIO TrapWriters Traps
Files UnixFiles Clock Dates Reals Strings Diagnostics
BitSets StringPool ObjectFile GenericLinker Reflection  Loader
BootConsole
 ~

	FSTools.CloseFiles simple_elf ~
~

MODULE Test;

IMPORT StdIO, Commands, Streams, Modules;

PROCEDURE Execute(context: Commands.Context);
VAR str, msg: ARRAY 256 OF CHAR;  res: INTEGER;
BEGIN
	IF ~context.arg.GetString(str) THEN RETURN END;
	IF ~context.arg.GetString(str) THEN
		context.out.String("no command"); context.out.Ln;
		RETURN
	END;
	Commands.Activate(str, context, {Commands.Wait}, res, msg);
END Execute;

BEGIN
	Execute(StdIO.env);
	Modules.Shutdown(1);
END Test.
