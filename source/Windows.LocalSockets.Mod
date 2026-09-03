MODULE LocalSockets;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Sockets named by a path: talking to a program on this machine" *)

(*	The Windows twin of Unix.LocalSockets, and here the twin is not the same thing underneath: a
	socket in the file system is a named pipe on this host. The interface is kept -- Connect and
	Listen by a path, a connection that is two streams, Accept that waits -- so that a program
	written against one compiles against the other; what changes is where the name lives.

	A path is turned into a pipe name: `/tmp/mpv.sock` becomes `\\.\pipe\tmp_mpv.sock`. Pipe names
	are flat, so the separators become underscores, and a name that is already a pipe name is left
	alone -- a program talking to something Windows-native passes `\\.\pipe\whatever` and gets it
	through untouched.

	AF_UNIX exists on Windows 10 since 1803 and would have kept the two implementations closer,
	but a named pipe is what programs on this host actually listen on, it needs no Winsock, and it
	works on the Windows this SDK still builds for. That is the trade, and it is the reason Listen
	here creates one instance per Accept rather than holding a listening socket: an instance IS
	the connection once somebody opens it.

	`Accept` waits, and there is no asking whether somebody is there, for the same reason as on the
	other host: a program that must not stop should accept in an active object of its own. *)

IMPORT Streams, Strings, Kernel32;

CONST
	(*	Oberon strings carry no escapes, so this is the name as it stands: two backslashes, a
		dot, a backslash, "pipe", a backslash. *)
	Prefix = "\\.\pipe\";
	Duplex = 3;                        (* PIPE_ACCESS_DUPLEX *)
	ByteStream = 0;                    (* PIPE_TYPE_BYTE + PIPE_READMODE_BYTE + PIPE_WAIT *)
	Instances = 255;                   (* PIPE_UNLIMITED_INSTANCES *)
	Room = 4096;                       (* what one instance buffers each way *)
	Forever = 0;                       (* the default time-out, which nothing here waits on *)
	(*	GENERIC_READ + GENERIC_WRITE is 0C0000000H, which does not fit a positive SIGNED32 and is
		that bit pattern read as a negative one. Written out rather than added, because the sum of
		the two constants overflows before it can be converted. *)
	ReadWrite = -1073741824;
	OpenExisting = 3;
	NoHandle = -1;                     (* INVALID_HANDLE_VALUE *)

TYPE
	Name = ARRAY 256 OF CHAR;

	(** A connection to, or from, a program on this machine. *)
	Connection* = OBJECT
	VAR
		Reader-: Streams.Reader;       (** what the other side says *)
		Writer-: Streams.Writer;       (** what it is told *)
		pipe: Kernel32.HANDLE;
		server: BOOLEAN;               (* this end made the instance, so it disconnects it *)

		PROCEDURE &Init* (handle: Kernel32.HANDLE; listening: BOOLEAN);
		BEGIN
			pipe := handle; server := listening;
			NEW(Reader, Receive, 4096);
			NEW(Writer, Send, 4096)
		END Init;

		PROCEDURE Receive (VAR buffer: ARRAY OF CHAR; offset, size, min: SIZE;
			VAR length: SIZE; VAR result: INTEGER);
		VAR got, ready: SIGNED32; ok: Kernel32.BOOL;
		BEGIN
			length := 0;
			IF pipe = 0 THEN result := Streams.EOF; RETURN END;
			IF min <= 0 THEN
				ready := 0;
				ok := Kernel32.PeekNamedPipe(pipe, NIL, 0, NIL, ready, NIL);
				IF (ok = 0) OR (ready <= 0) THEN result := Streams.Ok; RETURN END;
				IF ready < SIGNED32(size) THEN size := ready END
			END;
			LOOP
				got := 0;
				ok := Kernel32.ReadFileBuffer(pipe, ADDRESSOF(buffer[offset]), SIGNED32(size), got, NIL);
				IF (ok = 0) OR (got <= 0) THEN EXIT END;
				INC(offset, got); DEC(size, got); INC(length, got);
				IF (length >= min) OR (size <= 0) THEN EXIT END
			END;
			IF length >= min THEN result := Streams.Ok ELSE result := Streams.EOF END
		END Receive;

		PROCEDURE Send (CONST buffer: ARRAY OF CHAR; offset, length: SIZE;
			propagate: BOOLEAN; VAR result: INTEGER);
		VAR written: SIGNED32; ok: Kernel32.BOOL;
		BEGIN
			result := Streams.Ok;
			IF pipe = 0 THEN result := Streams.EOF; RETURN END;
			WHILE length > 0 DO
				written := 0;
				ok := Kernel32.WriteFileBuffer(pipe, ADDRESSOF(buffer[offset]), SIGNED32(length), written, NIL);
				IF (ok = 0) OR (written <= 0) THEN result := Streams.EOF; RETURN END;
				INC(offset, written); DEC(length, written)
			END
		END Send;

		(** How much can be read without waiting for it. *)
		PROCEDURE Waiting* (): SIGNED32;
		BEGIN RETURN SIGNED32(Reader.Available())
		END Waiting;

		(**	A line ended with one newline, and sent at once. That is what a control socket wants:
			one line is one command, and it is no use sitting in a buffer. *)
		PROCEDURE WriteLine* (CONST s: ARRAY OF CHAR);
		BEGIN Writer.String(s); Writer.Char(0AX); Writer.Update
		END WriteLine;

		(** One line of what came back, without its newline. FALSE when the other side is done. *)
		PROCEDURE ReadLine* (VAR s: ARRAY OF CHAR): BOOLEAN;
		VAR i: SIZE; ch: CHAR;
		BEGIN
			i := 0;
			LOOP
				ch := Reader.Get();
				IF Reader.res # Streams.Ok THEN s[i] := 0X; RETURN i > 0 END;
				IF ch = 0AX THEN s[i] := 0X; RETURN TRUE END;
				IF (ch # 0DX) & (i < LEN(s)-1) THEN s[i] := ch; INC(i) END
			END
		END ReadLine;

		PROCEDURE Close*;
		VAR ignore: Kernel32.BOOL;
		BEGIN
			IF pipe # 0 THEN
				Writer.Update;
				IF server THEN ignore := Kernel32.DisconnectNamedPipe(pipe) END;
				ignore := Kernel32.CloseHandle(pipe);
				pipe := 0
			END
		END Close;

	END Connection;

	(**	A pipe others connect to. Unlike the Unix twin it holds no handle between Accepts: on this
		host an instance is created for each one, and the instance is the connection. *)
	Listener* = OBJECT
	VAR
		name: Name;
		open: BOOLEAN;

		PROCEDURE &InitListener* (CONST pipeName: ARRAY OF CHAR);
		BEGIN COPY(pipeName, name); open := TRUE
		END InitListener;

		(** Wait for somebody to connect, and answer them. NIL when the listener was closed. *)
		PROCEDURE Accept* (): Connection;
		VAR handle: Kernel32.HANDLE; ok: Kernel32.BOOL; c: Connection; ignore: Kernel32.BOOL;
		BEGIN
			IF ~open THEN RETURN NIL END;
			handle := Kernel32.CreateNamedPipe(name, Duplex, ByteStream, Instances,
				Room, Room, Forever, NIL);
			IF handle = NoHandle THEN RETURN NIL END;
			ok := Kernel32.ConnectNamedPipe(handle, NIL);
			(*	Zero with the client already there is not a failure: it means it connected between
				the two calls, which is a race the standard answer to is to carry on. *)
			IF (ok = 0) & (Kernel32.GetLastError() # 535) THEN
				ignore := Kernel32.CloseHandle(handle);
				RETURN NIL
			END;
			NEW(c, handle, TRUE);
			RETURN c
		END Accept;

		(**	Stop answering. A pipe has no name in the file system to remove, so this only says
			that further Accepts are refused. *)
		PROCEDURE Close*;
		BEGIN open := FALSE
		END Close;

	END Listener;

(*	`/tmp/mpv.sock` becomes `\\.\pipe\tmp_mpv.sock`; a name that already begins with the pipe
	prefix is passed through, so that a program talking to something Windows-native can name it. *)
PROCEDURE PipeName (CONST path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, j: SIZE; ch: CHAR;
BEGIN
	IF (path[0] = "\") & (path[1] = "\") THEN COPY(path, name); RETURN END;
	COPY(Prefix, name);
	j := Strings.Length(name);
	i := 0;
	WHILE (path[i] # 0X) & (j < LEN(name)-1) DO
		ch := path[i];
		IF (ch = "/") OR (ch = "\") OR (ch = ":") THEN ch := "_" END;
		IF ~((j = Strings.Length(Prefix)) & (ch = "_")) THEN name[j] := ch; INC(j) END;
		INC(i)
	END;
	name[j] := 0X
END PipeName;

(** Connect to what is listening at `path`. NIL when nothing is. *)
PROCEDURE Connect* (CONST path: ARRAY OF CHAR): Connection;
VAR name: Name; handle: Kernel32.HANDLE; c: Connection;
BEGIN
	PipeName(path, name);
	handle := Kernel32.CreateFileName(name, ReadWrite, 0, NIL, OpenExisting, 0, NIL);
	IF handle = NoHandle THEN RETURN NIL END;
	NEW(c, handle, FALSE);
	RETURN c
END Connect;

(**	Listen at `path`. NIL when the name cannot be had -- on this host that means somebody else is
	already listening on it, since a pipe name is not a file and leaves nothing behind. *)
PROCEDURE Listen* (CONST path: ARRAY OF CHAR): Listener;
VAR name: Name; probe: Kernel32.HANDLE; ignore: Kernel32.BOOL; l: Listener;
BEGIN
	PipeName(path, name);
	(*	Made and let go at once: the answer wanted here is whether the name can be had, and
		Accept makes the instance that is actually used. *)
	probe := Kernel32.CreateNamedPipe(name, Duplex, ByteStream, Instances, Room, Room, Forever, NIL);
	IF probe = NoHandle THEN RETURN NIL END;
	ignore := Kernel32.CloseHandle(probe);
	NEW(l, name);
	RETURN l
END Listen;

END LocalSockets.
