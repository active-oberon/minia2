MODULE Processes;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Start another program, and talk to it through pipes" *)

(*	The Windows twin of Unix.Processes, and the same interface: what a program written against one
	does, it does against the other. What differs is underneath.

	A child is created with CreateProcess and named in the command line rather than in
	lpApplicationName, because that is how a name is looked up on the PATH -- the same lookup
	posix_spawnp does on the other host. The arguments are therefore joined into one line and
	quoted where they contain a space, which is the price Windows charges for having no argument
	vector: the child takes that line apart again, and a program that must control exactly what it
	sees should pass one argument.

	Reading goes through the same decoupler the Unix twin uses -- a thread of its own feeding a
	pipe -- so that a quiet child does not stop the activity that reads it. What a poll asks is
	PeekNamedPipe rather than an ioctl, and it is the one call in this module with no Unix
	counterpart worth naming: an anonymous pipe on Windows is a named pipe with no name.

	The handles a child inherits are made inheritable when the pipe is created; the ends that stay
	here are made not inheritable afterwards, because a second child would otherwise hold the
	writing end open and the reading end would never see the end of the output. *)

IMPORT SYSTEM, Streams, Strings, Pipes, Kernel32;

CONST
	UseStdHandles = 100H;              (* STARTF_USESTDHANDLES *)
	HandleFlagInherit = 1;
	StillActive = 103H;                (* what GetExitCodeProcess says while it runs *)
	NoWait = 0;

TYPE
	(**	A running program. Its standard output and standard error come back through `Output`, and
		what is written to `Input` reaches its standard input. *)
	Process* = OBJECT
	VAR
		pid-: SIGNED32;                (** what the system calls it *)
		Output-: Streams.Reader;       (** what it writes *)
		Input-: Streams.Writer;        (** what it reads *)
		process: Kernel32.HANDLE;      (* the child itself *)
		fromChild, toChild: Kernel32.HANDLE;
		reader: Pipes.ReadDecoupler;
		done: BOOLEAN;
		code: SIGNED32;

		PROCEDURE &Init* (child: Kernel32.HANDLE; id: SIGNED32; readFrom, writeTo: Kernel32.HANDLE);
		BEGIN
			process := child; pid := id; fromChild := readFrom; toChild := writeTo;
			done := FALSE; code := 0;
			NEW(reader, ReceiveFrom);
			NEW(Output, reader.Receive, 4096);
			NEW(Input, SendTo, 4096)
		END Init;

		(*	`min = 0` is a poll, and it may not wait: reading a pipe nobody has written to blocks
			until somebody does, and a program that asked "is there anything" would stop there.
			PeekNamedPipe answers without taking anything. *)
		PROCEDURE ReceiveFrom (VAR buffer: ARRAY OF CHAR; offset, size, min: SIZE;
			VAR length: SIZE; VAR result: INTEGER);
		VAR got, ready: SIGNED32; ok: Kernel32.BOOL;
		BEGIN
			length := 0;
			IF fromChild = 0 THEN result := Streams.EOF; RETURN END;
			IF min <= 0 THEN
				ready := 0;
				ok := Kernel32.PeekNamedPipe(fromChild, NIL, 0, NIL, ready, NIL);
				IF (ok = 0) OR (ready <= 0) THEN result := Streams.Ok; RETURN END;
				IF ready < SIGNED32(size) THEN size := ready END
			END;
			LOOP
				got := 0;
				ok := Kernel32.ReadFileBuffer(fromChild, ADDRESSOF(buffer[offset]),
					SIGNED32(size), got, NIL);
				IF (ok = 0) OR (got <= 0) THEN EXIT END;      (* the child closed it, or ended *)
				INC(offset, got); DEC(size, got); INC(length, got);
				IF (length >= min) OR (size <= 0) THEN EXIT END
			END;
			IF length >= min THEN result := Streams.Ok ELSE result := Streams.EOF END
		END ReceiveFrom;

		PROCEDURE SendTo (CONST buffer: ARRAY OF CHAR; offset, length: SIZE;
			propagate: BOOLEAN; VAR result: INTEGER);
		VAR written: SIGNED32; ok: Kernel32.BOOL;
		BEGIN
			result := Streams.Ok;
			IF toChild = 0 THEN result := Streams.EOF; RETURN END;
			WHILE length > 0 DO
				written := 0;
				ok := Kernel32.WriteFileBuffer(toChild, ADDRESSOF(buffer[offset]),
					SIGNED32(length), written, NIL);
				IF (ok = 0) OR (written <= 0) THEN result := Streams.EOF; RETURN END;
				INC(offset, written); DEC(length, written)
			END
		END SendTo;

		(**	Is there output to be had without waiting for it? A program with an event loop asks
			this rather than reading, so that a quiet child does not stop it answering its keys. *)
		PROCEDURE Waiting* (): SIGNED32;
		BEGIN RETURN SIGNED32(Output.Available())
		END Waiting;

		(**	A line, ended the way a program on this host expects one. Streams.Writer.Ln writes a
			carriage return and a newline, which is what Windows wants -- and it is written out
			here rather than called so that the two twins say the same thing about themselves. *)
		PROCEDURE WriteLine* (CONST s: ARRAY OF CHAR);
		BEGIN Input.String(s); Input.Char(0DX); Input.Char(0AX)
		END WriteLine;

		(** Nothing more will be written to it. A child reading its input to the end sees that. *)
		PROCEDURE CloseInput*;
		VAR ignore: Kernel32.BOOL;
		BEGIN
			Input.Update;
			IF toChild # 0 THEN ignore := Kernel32.CloseHandle(toChild); toChild := 0 END
		END CloseInput;

		(**	Has it finished, without waiting for it? *)
		PROCEDURE Finished* (VAR exitCode: SIGNED32): BOOLEAN;
		VAR status: SIGNED32; ok: Kernel32.BOOL;
		BEGIN
			IF done THEN exitCode := code; RETURN TRUE END;
			status := StillActive;
			ok := Kernel32.GetExitCodeProcess(process, status);
			IF (ok = 0) OR (status = StillActive) THEN RETURN FALSE END;
			done := TRUE; code := status; exitCode := code;
			RETURN TRUE
		END Finished;

		(** Wait for it to finish, and say how it went. *)
		PROCEDURE Wait* (): SIGNED32;
		VAR status, ignore: SIGNED32; ok: Kernel32.BOOL;
		BEGIN
			IF done THEN RETURN code END;
			ignore := Kernel32.WaitForSingleObject(process, Kernel32.Infinite);
			status := 0;
			ok := Kernel32.GetExitCodeProcess(process, status);
			IF ok = 0 THEN status := -1 END;
			done := TRUE; code := status;
			RETURN code
		END Wait;

		(** Everything it has left to say, until it closes its output. *)
		PROCEDURE ReadAll* (): Strings.String;
		VAR buffer: Streams.Buffer; w: Streams.Writer; ch: CHAR;
		BEGIN
			NEW(buffer, 4096); w := buffer.GetWriter();
			LOOP
				ch := Output.Get();
				IF Output.res # Streams.Ok THEN EXIT END;
				w.Char(ch)
			END;
			w.Update; RETURN buffer.GetString()
		END ReadAll;

		(** Kill it and collect it, so that nothing is left behind. *)
		PROCEDURE Kill*;
		VAR ignore: SIGNED32; ok: Kernel32.BOOL;
		BEGIN
			IF done THEN RETURN END;
			ok := Kernel32.TerminateProcess(process, 1);
			ignore := Kernel32.WaitForSingleObject(process, Kernel32.Infinite);
			done := TRUE; code := 1
		END Kill;

		(** Let go of the pipes and of the child. *)
		PROCEDURE Close*;
		VAR ignore: Kernel32.BOOL;
		BEGIN
			CloseInput;
			IF fromChild # 0 THEN ignore := Kernel32.CloseHandle(fromChild); fromChild := 0 END;
			IF process # 0 THEN ignore := Kernel32.CloseHandle(process); process := 0 END
		END Close;

	END Process;

(*	One command line out of an argument vector, which is what this host starts a program with.
	An argument containing a space is quoted; one containing a quote is not escaped, because the
	rules for that are the C runtime's rather than the system's and a caller who needs them should
	build the line itself. *)
PROCEDURE CommandLine (arguments: Strings.StringArray; VAR line: ARRAY OF CHAR);
VAR i, count: SIZE; quoted: BOOLEAN;
BEGIN
	line := "";
	count := 0;
	IF arguments # NIL THEN count := LEN(arguments^) END;
	FOR i := 0 TO count-1 DO
		IF i > 0 THEN Strings.Append(line, " ") END;
		quoted := Strings.Pos(" ", arguments[i]^) >= 0;
		IF quoted THEN Strings.Append(line, '"') END;
		Strings.Append(line, arguments[i]^);
		IF quoted THEN Strings.Append(line, '"') END
	END
END CommandLine;

PROCEDURE Inheritable (VAR sa: Kernel32.SecurityAttributes);
BEGIN
	sa.nLength := SIZEOF(Kernel32.SecurityAttributes);
	sa.lpSecurityDescriptor := 0;
	sa.bInheritHandle := 1
END Inheritable;

(**	Start `program`, looked up on the PATH as a shell would look it up, with `arguments` -- of
	which the first is the name the program sees as its own, as usual.

	NIL when the start itself failed, which on this host includes a name that is not a program:
	CreateProcess reports that here rather than letting a child be made and fail. *)
PROCEDURE Start* (CONST program: ARRAY OF CHAR; arguments: Strings.StringArray): Process;
VAR sa: Kernel32.SecurityAttributes; info: Kernel32.StartupInfo; made: Kernel32.ProcessInformation;
	childIn, childOut, ourIn, ourOut: Kernel32.HANDLE;
	line: ARRAY 1024 OF CHAR; ok, ignore: Kernel32.BOOL; p: Process;
BEGIN
	Inheritable(sa);
	IF Kernel32.CreatePipe(childIn, ourOut, sa, 0) = 0 THEN RETURN NIL END;
	IF Kernel32.CreatePipe(ourIn, childOut, sa, 0) = 0 THEN
		ignore := Kernel32.CloseHandle(childIn); ignore := Kernel32.CloseHandle(ourOut);
		RETURN NIL
	END;
	(*	Our ends must not travel: a child holding the writing end of its own output open is a
		child whose output never ends. *)
	ignore := Kernel32.SetHandleInformation(ourOut, HandleFlagInherit, 0);
	ignore := Kernel32.SetHandleInformation(ourIn, HandleFlagInherit, 0);

	CommandLine(arguments, line);
	IF line = "" THEN COPY(program, line) END;

	info.cb := SIZEOF(Kernel32.StartupInfo);
	info.lpReserved := NIL; info.lpDesktop := NIL; info.lpTitle := NIL;
	info.dwX := 0; info.dwY := 0; info.dwXSize := 0; info.dwYSize := 0;
	info.dwXCountChars := 0; info.dwYCountChars := 0; info.dwFillAttribute := 0;
	info.dwFlags := SYSTEM.VAL(SET32, UseStdHandles);
	info.wShowWindow := 0; info.cbReserved2 := 0; info.lpReserved2 := 0;
	info.hStdInput := childIn; info.hStdOutput := childOut; info.hStdError := childOut;

	ok := Kernel32.CreateProcessLine(NIL, line, NIL, NIL, 1, 0, NIL, NIL, info, made);

	(* the child's ends are the child's now, whether or not it started *)
	ignore := Kernel32.CloseHandle(childIn); ignore := Kernel32.CloseHandle(childOut);
	IF ok = 0 THEN
		ignore := Kernel32.CloseHandle(ourIn); ignore := Kernel32.CloseHandle(ourOut);
		RETURN NIL
	END;
	ignore := Kernel32.CloseHandle(made.hThread);      (* the thread is not ours to keep *)
	NEW(p, made.hProcess, made.dwProcessId, ourIn, ourOut);
	RETURN p
END Start;

(**	Start a program that takes the console over -- an editor, a pager -- rather than one that is
	spoken to. It inherits this program's own input and output, so there is nothing to read and
	nothing to write. A full-screen program should give the console back first (Terminal.Close)
	and take it again afterwards. *)
PROCEDURE StartAttached* (CONST program: ARRAY OF CHAR; arguments: Strings.StringArray): Process;
VAR info: Kernel32.StartupInfo; made: Kernel32.ProcessInformation;
	line: ARRAY 1024 OF CHAR; ok, ignore: Kernel32.BOOL; p: Process;
BEGIN
	CommandLine(arguments, line);
	IF line = "" THEN COPY(program, line) END;
	info.cb := SIZEOF(Kernel32.StartupInfo);
	info.lpReserved := NIL; info.lpDesktop := NIL; info.lpTitle := NIL;
	info.dwX := 0; info.dwY := 0; info.dwXSize := 0; info.dwYSize := 0;
	info.dwXCountChars := 0; info.dwYCountChars := 0; info.dwFillAttribute := 0;
	info.dwFlags := {};                               (* no handles named: it inherits ours *)
	info.wShowWindow := 0; info.cbReserved2 := 0; info.lpReserved2 := 0;
	info.hStdInput := 0; info.hStdOutput := 0; info.hStdError := 0;
	ok := Kernel32.CreateProcessLine(NIL, line, NIL, NIL, 1, 0, NIL, NIL, info, made);
	IF ok = 0 THEN RETURN NIL END;
	ignore := Kernel32.CloseHandle(made.hThread);
	NEW(p, made.hProcess, made.dwProcessId, 0, 0);    (* no pipes: it has the console, not us *)
	RETURN p
END StartAttached;

(**	The common case in one call: start a program, let it say everything it has to say, and wait
	for it. FALSE when it could not be started at all; a program that ran and failed returns TRUE
	with its exit code, because that is a thing it did and not a thing that went wrong here. *)
PROCEDURE Run* (CONST program: ARRAY OF CHAR; arguments: Strings.StringArray;
	VAR output: Strings.String; VAR exitCode: SIGNED32): BOOLEAN;
VAR p: Process;
BEGIN
	p := Start(program, arguments);
	IF p = NIL THEN output := NIL; exitCode := -1; RETURN FALSE END;
	p.CloseInput;
	output := p.ReadAll();
	exitCode := p.Wait();
	p.Close;
	RETURN TRUE
END Run;

(**	What the environment says a name means, as the program was started with it. FALSE when it says
	nothing, which is not the same as saying nothing at all: an empty value is still a value. *)
PROCEDURE Environment* (CONST name: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
VAR got: SIGNED32;
BEGIN
	value := "";
	got := Kernel32.GetEnvironmentVariable(name, value, SIGNED32(LEN(value)));
	(*	Zero is "there is no such variable"; a number at least as large as the buffer is "there
		is one and it did not fit", which is not the same thing and is not a yes. *)
	RETURN (got > 0) & (got < SIGNED32(LEN(value)))
END Environment;

(** The arguments of a program, made from a program name and what follows it. *)
PROCEDURE Arguments* (CONST first, second, third, fourth: ARRAY OF CHAR): Strings.StringArray;
VAR a: Strings.StringArray; n: SIZE;
BEGIN
	n := 1;
	IF second # "" THEN n := 2 END;
	IF third # "" THEN n := 3 END;
	IF fourth # "" THEN n := 4 END;
	NEW(a, n);
	a[0] := Strings.NewString(first);
	IF n > 1 THEN a[1] := Strings.NewString(second) END;
	IF n > 2 THEN a[2] := Strings.NewString(third) END;
	IF n > 3 THEN a[3] := Strings.NewString(fourth) END;
	RETURN a
END Arguments;

END Processes.
