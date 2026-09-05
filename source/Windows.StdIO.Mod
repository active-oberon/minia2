MODULE StdIO;	(** AUTHOR gf;  PURPOSE "Unix standard IO and argument channels *)

(* Commands.Context for programs running outside Aos *)

IMPORT S := SYSTEM, Modules, Commands, Streams, Pipes, WinTrace, Kernel32;

CONST
	Echo* = FALSE;
TYPE
	String=POINTER TO ARRAY OF CHAR;
VAR
	env-: Commands.Context;

	hin-, hout-, herr-: Kernel32.HANDLE;
	stdInDecoupler: Pipes.ReadDecoupler;


(*
	The command line, split the way Windows expects a program to split it and then joined with single
	spaces -- which is exactly what the Unix twin hands over, because there the shell has done the
	splitting and argv arrives with the quotes already gone.

	Until 05.09.2026 this handed over `Kernel32.GetCommandLine()` **verbatim**, quotes and all. An
	argument with a space in it therefore arrived as several, with the quote characters still in
	them: `oberon.exe do "System.DoFile x ~"` was read as a command named `"`. That is what stops
	`task Win64` on Windows -- it runs the compiler with a multi-line argument -- and it is why no A2
	program on Windows could take an argument containing a space.

	The rules are the ones CommandLineToArgvW documents: whitespace separates arguments outside
	quotes; a quote toggles quoting; 2n backslashes before a quote are n backslashes and a toggle,
	2n+1 are n backslashes and a literal quote. A backslash anywhere else is literal, which is what
	keeps a Windows path a Windows path.
*)
PROCEDURE Args(): String;
CONST Quote = 22X; Backslash = 5CX;
VAR length, pos, out, slashes, i: SIZE; quoted: BOOLEAN; ch: CHAR; str: String;
	cmdLine {UNTRACED}: POINTER {UNSAFE} TO ARRAY MAX(SIZE) OF CHAR;

	PROCEDURE Put(c: CHAR);
	BEGIN
		IF out < LEN(str^) - 1 THEN str[out] := c; INC(out) END
	END Put;

BEGIN
	cmdLine := Kernel32.GetCommandLine();
	length := 0;
	WHILE cmdLine[length] # 0X DO INC(length) END;
	(*	One more than the line itself: every argument is followed by a space, and a single argument
		with nothing after it is the one case where that is a byte longer than the input. *)
	NEW(str, length + 2);
	pos := 0; out := 0;
	LOOP
		WHILE (cmdLine[pos] # 0X) & (cmdLine[pos] <= " ") DO INC(pos) END;
		IF cmdLine[pos] = 0X THEN EXIT END;
		quoted := FALSE;
		LOOP
			ch := cmdLine[pos];
			IF ch = 0X THEN EXIT END;
			IF ~quoted & (ch <= " ") THEN EXIT END;
			IF ch = Backslash THEN
				slashes := 0;
				WHILE cmdLine[pos] = Backslash DO INC(slashes); INC(pos) END;
				IF cmdLine[pos] = Quote THEN
					FOR i := 1 TO slashes DIV 2 DO Put(Backslash) END;
					INC(pos);
					IF ODD(slashes) THEN Put(Quote) ELSE quoted := ~quoted END
				ELSE
					FOR i := 1 TO slashes DO Put(Backslash) END
				END
			ELSIF ch = Quote THEN
				quoted := ~quoted; INC(pos)
			ELSE
				Put(ch); INC(pos)
			END
		END;
		Put(" ")	(* a space after every argument, the way the Unix side writes it *)
	END;
	str[out] := 0X;
	RETURN str;
END Args;

PROCEDURE Cleanup;
BEGIN
	env.error.Update;
	env.out.Update
END Cleanup;

PROCEDURE Setup;
VAR
	arg: Streams.StringReader;
	stdin: Streams.Reader;
	stdout: Streams.Writer;
	errout: Streams.Writer;
	str: String;
BEGIN
	WinTrace.OpenConsole;
	str := Args();
	NEW( arg, LEN(str) ); arg.Set(str^);
	NEW(stdInDecoupler, WinTrace.Receive);
	NEW( stdin, stdInDecoupler.Receive, 1024 );
	NEW( stdout, WinTrace.Send, 1024 );
	NEW( errout, WinTrace.SendError, 512 );
	NEW( env, stdin, arg, stdout, errout, NIL );
	Modules.InstallTermHandler( Cleanup )
END Setup

BEGIN
	Setup
END  StdIO.

System.DoCommands

	Compiler.Compile  -b=AMD --bits=32 --objectFileExtension=.Gox --symbolFileExtension=.Syx --mergeSections
		I386.Builtins.Mod Trace.Mod Windows.I386.Kernel32.Mod Windows.I386.Machine.Mod Heaps.Mod
		Modules.Mod Windows.I386.Objects.Mod Windows.Kernel.Mod KernelLog.Mod Streams.Mod Commands.Mod
		I386.Reals.Mod Reflection.Mod Locks.Mod Windows.Clock.Mod Files.Mod Dates.Mod Strings.Mod

		Windows.WinTrace.Mod Windows.WinFS.Mod

		Diagnostics.Mod StringPool.Mod BitSets.Mod ObjectFile.Mod
		GenericLinker.Mod Loader.Mod Options.Mod Debugging.Mod

		Windows.StdIO.Mod 		Pipes.Mod Shell.Mod TestStdIO.Mod



		~


	Linker.Link --fileFormat=PE32CUI --fileName=fox.exe --extension=Gox --displacement=401000H
		Builtins Trace Kernel32 Machine Heaps Modules Objects Kernel KernelLog Streams Commands Files
		WinFS Clock Dates Reals Strings Diagnostics BitSets StringPool ObjectFile GenericLinker Reflection Loader
		WinTrace StdIO Pipes Shell TestStdIO ~

		FSTools.CloseFiles fox.exe ~

	~

