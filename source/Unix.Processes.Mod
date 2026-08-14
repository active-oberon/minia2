MODULE Processes;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Start another program, and talk to it" *)

(*	A program that drives other programs -- a player, a downloader, a version control system -- is
	most of what a terminal is used for, and A2 could not start one at all: the runtime binds
	posix_spawnp, but nothing above it, and a child that only inherits our descriptors can be run
	and not spoken to.

	What is here is the smallest thing that is honestly useful: start a program with its input and
	its output on pipes, read what it says as a Streams.Reader, write to it as a Streams.Writer,
	ask whether it has finished, wait for it, kill it. `Run` does the common case in one call --
	start it, read everything, wait -- for the many programs whose whole answer is their output.

	Reading blocks the activity that reads, as reading a file does. A program with an event loop
	should therefore ask `Waiting` first, which tells it whether anything is there without
	stopping to find out; that keeps a terminal program answering its keyboard while a child is
	quiet. Where output is wanted as it appears, the reading belongs in an active object of its
	own -- the language has them, and this module deliberately does not choose for the program.

	Unix only, and honestly so: what a process is differs enough on Windows that a twin belongs
	beside this one rather than inside it. *)

IMPORT SYSTEM, Streams, Strings, Pipes, Unix, Machine;

CONST
	FIONREAD = 541BH;                  (* how many bytes are waiting, without reading them *)
	WNOHANG = 1;
	(*	posix_spawn_file_actions_t is opaque and is 80 bytes on the C libraries this runs on. The
		room here is far more than that on purpose: getting it wrong is memory the child's spawn
		writes over, and the cost of the slack is nothing. *)
	ActionsRoom = 256;

TYPE
	(**	A running program. Its standard output and standard error come back through `Output`, and
		what is written to `Input` reaches its standard input. *)
	Process* = OBJECT
	VAR
		pid-: SIGNED32;                (** what the system calls it *)
		Output-: Streams.Reader;       (** what it writes *)
		Input-: Streams.Writer;        (** what it reads *)
		fromChild, toChild: SIGNED32;  (* our ends of the two pipes *)
		reader: Pipes.ReadDecoupler;
		done: BOOLEAN;
		code: SIGNED32;

		(*	Reading goes through a decoupler, which is a thread of its own feeding a pipe, and the
			same thing StdIO does with standard input. Without it a read is a system call made by
			whichever activity asked, and a quiet child stops that activity where it stands --
			which is the one thing an active object reading a child must not do. With it, waiting
			for a child is waiting on a pipe, which in this language is an AWAIT and yields. *)
		PROCEDURE &Init* (child, readFrom, writeTo: SIGNED32);
		BEGIN
			pid := child; fromChild := readFrom; toChild := writeTo;
			done := FALSE; code := 0;
			NEW(reader, ReceiveFrom);
			NEW(Output, reader.Receive, 4096);
			NEW(Input, SendTo, 4096)
		END Init;

		(*	`min = 0` is a poll, and Streams.Reader.Available makes one every time it is asked how
			much there is. A poll may not wait: reading a pipe that nobody has written to yet
			blocks until somebody does, and a program that asked "is there anything" would stop
			there -- which is the opposite of why it asked. So a poll reads what is already
			waiting and not a byte more. *)
		PROCEDURE ReceiveFrom (VAR buffer: ARRAY OF CHAR; offset, size, min: SIZE;
			VAR length: SIZE; VAR result: INTEGER);
		VAR got, waiting: SIZE; ready: SIGNED32;
		BEGIN
			length := 0;
			IF min <= 0 THEN
				ready := 0;
				IF Unix.ioctl(fromChild, FIONREAD, ADDRESSOF(ready)) # 0 THEN ready := 0 END;
				IF ready <= 0 THEN result := Streams.Ok; RETURN END;
				waiting := ready;
				IF waiting < size THEN size := waiting END
			END;
			LOOP
				got := Unix.read(fromChild, ADDRESSOF(buffer[offset]), size);
				IF got > 0 THEN
					INC(offset, got); DEC(size, got); INC(length, got)
				ELSIF got = 0 THEN
					EXIT                                  (* the child closed it, or ended *)
				ELSE
					IF Unix.errno() # Unix.EINTR THEN EXIT END
				END;
				IF (length >= min) OR (size <= 0) THEN EXIT END
			END;
			IF length >= min THEN result := Streams.Ok ELSE result := Streams.EOF END
		END ReceiveFrom;

		PROCEDURE SendTo (CONST buffer: ARRAY OF CHAR; offset, length: SIZE;
			propagate: BOOLEAN; VAR result: INTEGER);
		VAR written: SIZE;
		BEGIN
			result := Streams.Ok;
			WHILE length > 0 DO
				written := Unix.write(toChild, ADDRESSOF(buffer[offset]), length);
				IF written <= 0 THEN
					IF Unix.errno() # Unix.EINTR THEN result := Streams.EOF; RETURN END
				ELSE
					INC(offset, written); DEC(length, written)
				END
			END
		END SendTo;

		(**	Is there output to be had without waiting for it? A program with an event loop asks
			this rather than reading, so that a quiet child does not stop it answering its keys. *)
		PROCEDURE Waiting* (): SIGNED32;
		BEGIN RETURN SIGNED32(Output.Available())
		END Waiting;

		(**	A line, ended the way a Unix program expects one: a single newline. Streams.Writer.Ln
			writes a carriage return before it -- the Oberon convention -- and a child that reads
			lines would take that as part of the line. Programs that want the other thing can still
			write it through `Input`. *)
		PROCEDURE WriteLine* (CONST s: ARRAY OF CHAR);
		BEGIN Input.String(s); Input.Char(0AX)
		END WriteLine;

		(** Nothing more will be written to it. A child reading its input to the end sees that. *)
		PROCEDURE CloseInput*;
		VAR ignore: SIGNED32;
		BEGIN
			Input.Update;
			IF toChild >= 0 THEN ignore := Unix.close(toChild); toChild := -1 END
		END CloseInput;

		(**	Has it finished, without waiting for it? The exit code is what it passed to exit; a
			child killed by a signal reports 128 plus the signal, as a shell does. *)
		PROCEDURE Finished* (VAR exitCode: SIGNED32): BOOLEAN;
		VAR status, result: SIGNED32;
		BEGIN
			IF done THEN exitCode := code; RETURN TRUE END;
			status := 0;
			result := Unix.waitpid(pid, ADDRESSOF(status), WNOHANG);
			IF result # pid THEN RETURN FALSE END;
			done := TRUE; code := Code(status); exitCode := code;
			RETURN TRUE
		END Finished;

		(** Wait for it to finish, and say how it went. *)
		PROCEDURE Wait* (): SIGNED32;
		VAR status, result: SIGNED32;
		BEGIN
			IF done THEN RETURN code END;
			status := 0;
			REPEAT
				result := Unix.waitpid(pid, ADDRESSOF(status), 0)
			UNTIL (result = pid) OR (Unix.errno() # Unix.EINTR);
			done := TRUE; code := Code(status);
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

		(** Kill it and collect it, so that nothing is left behind in the process table. *)
		PROCEDURE Kill*;
		VAR ignore, status: SIGNED32;
		BEGIN
			IF done THEN RETURN END;
			ignore := Unix.kill(pid, Unix.SIGKILL);
			status := 0;
			ignore := Unix.waitpid(pid, ADDRESSOF(status), 0);
			done := TRUE; code := Code(status)
		END Kill;

		(** Let go of the pipes. A process that finished still holds two descriptors until this. *)
		PROCEDURE Close*;
		VAR ignore: SIGNED32;
		BEGIN
			CloseInput;
			IF fromChild >= 0 THEN ignore := Unix.close(fromChild); fromChild := -1 END
		END Close;

	END Process;

	PROCEDURE Code (status: SIGNED32): SIGNED32;
	BEGIN
		IF status MOD 80H = 0 THEN RETURN status DIV 100H MOD 100H
		ELSE RETURN 128 + status MOD 80H
		END
	END Code;

(**	Start `program`, looked up on the PATH as a shell would look it up, with `arguments` -- of
	which the first is the name the program sees as its own, as usual.

	NIL when the start itself failed. A name that is not a program may come back either way, and
	that is the C library's choice, not ours: some report it here, and some let the child be made
	and have it fail to become the program, which is an exit code of 127 -- the number a shell
	uses for the same thing. A caller that must know should look at both. *)
PROCEDURE Start* (CONST program: ARRAY OF CHAR; arguments: Strings.StringArray): Process;
VAR toChild, fromChild: ARRAY 2 OF SIGNED32;
	actions: ARRAY ActionsRoom OF CHAR;
	vector: POINTER TO ARRAY OF ADDRESS; i, count: SIZE;
	pid, ignore, error: SIGNED32; p: Process;
BEGIN
	IF Unix.pipe(ADDRESSOF(toChild[0])) # 0 THEN RETURN NIL END;
	IF Unix.pipe(ADDRESSOF(fromChild[0])) # 0 THEN
		ignore := Unix.close(toChild[0]); ignore := Unix.close(toChild[1]); RETURN NIL
	END;

	(*	What the child does to its own descriptors before it starts: read from our writing pipe,
		write to our reading one, and let go of the ends that are ours. *)
	IF Unix.posix_spawn_file_actions_init(ADDRESSOF(actions[0])) # 0 THEN RETURN NIL END;
	ignore := Unix.posix_spawn_file_actions_adddup2(ADDRESSOF(actions[0]), toChild[0], 0);
	ignore := Unix.posix_spawn_file_actions_adddup2(ADDRESSOF(actions[0]), fromChild[1], 1);
	ignore := Unix.posix_spawn_file_actions_adddup2(ADDRESSOF(actions[0]), fromChild[1], 2);
	ignore := Unix.posix_spawn_file_actions_addclose(ADDRESSOF(actions[0]), toChild[1]);
	ignore := Unix.posix_spawn_file_actions_addclose(ADDRESSOF(actions[0]), fromChild[0]);

	count := 0;
	IF arguments # NIL THEN count := LEN(arguments^) END;
	NEW(vector, count + 1);
	FOR i := 0 TO count-1 DO vector[i] := ADDRESSOF(arguments[i][0]) END;
	vector[count] := 0;

	pid := 0;
	(*	spawnp, not spawn: a program is named the way a shell names it, and an absolute path still
		works. The error is the return value -- posix_spawnp does not touch errno. *)
	error := Unix.posix_spawnp(ADDRESSOF(pid), ADDRESSOF(program), ADDRESSOF(actions[0]), 0,
		ADDRESSOF(vector[0]), Unix.environ);
	ignore := Unix.posix_spawn_file_actions_destroy(ADDRESSOF(actions[0]));

	(* the child's ends are the child's now *)
	ignore := Unix.close(toChild[0]); ignore := Unix.close(fromChild[1]);
	IF error # 0 THEN
		ignore := Unix.close(toChild[1]); ignore := Unix.close(fromChild[0]);
		RETURN NIL
	END;
	NEW(p, pid, fromChild[0], toChild[1]);
	RETURN p
END Start;

(**	Start a program that takes the terminal over -- an editor, a pager -- rather than one that is
	spoken to. It inherits this program's own input and output, so there is nothing to read and
	nothing to write: what it does, it does to the screen. A full-screen program should give the
	terminal back first (Terminal.Close) and take it again afterwards. *)
PROCEDURE StartAttached* (CONST program: ARRAY OF CHAR; arguments: Strings.StringArray): Process;
VAR vector: POINTER TO ARRAY OF ADDRESS; i, count: SIZE; pid, error: SIGNED32; p: Process;
BEGIN
	count := 0;
	IF arguments # NIL THEN count := LEN(arguments^) END;
	NEW(vector, count + 1);
	FOR i := 0 TO count-1 DO vector[i] := ADDRESSOF(arguments[i][0]) END;
	vector[count] := 0;
	pid := 0;
	error := Unix.posix_spawnp(ADDRESSOF(pid), ADDRESSOF(program), 0, 0,
		ADDRESSOF(vector[0]), Unix.environ);
	IF error # 0 THEN RETURN NIL END;
	NEW(p, pid, -1, -1);               (* no pipes: it has the terminal, not us *)
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
VAR address: ADDRESS; i: SIZE; ch: CHAR;
BEGIN
	value := "";
	address := Unix.getenv(ADDRESSOF(name[0]));
	IF address = 0 THEN RETURN FALSE END;
	i := 0;
	LOOP
		SYSTEM.GET(address + i, ch);
		IF (ch = 0X) OR (i >= LEN(value)-1) THEN EXIT END;
		value[i] := ch; INC(i)
	END;
	value[i] := 0X;
	RETURN TRUE
END Environment;

(** The arguments of a program, made from a program name and what follows it. *)
PROCEDURE Arguments* (CONST first, second, third, fourth: ARRAY OF CHAR): Strings.StringArray;
VAR a: Strings.StringArray; n, i: SIZE;
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
