MODULE LocalSockets;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Sockets named by a path: talking to a program on this machine" *)

(*	A socket in the file system, which is how programs on one machine talk when a port would be
	the wrong thing: mpv's control socket, a session bus, a daemon's own. A2 has sockets, but
	Sockets.Mod is built around an IP address and a port, and a local socket has neither -- it has
	a path. Bending that module into this shape would be worse than a small one beside it.

	A connection is two streams and a descriptor: read it as a Streams.Reader, write it as a
	Streams.Writer, ask `Waiting` whether anything is there before reading, as with Processes and
	for the same reason -- an event loop may not stop to find out.

	Listening is here as well, and not for symmetry: without it nothing could answer, and a check
	would need some other program to talk to. With it, this talks to itself.

	`Accept` waits, and there is no asking whether somebody is there: what answers that for a
	listening socket is poll, not the count of bytes waiting, and offering an answer that is only
	right on some systems is worse than not offering one. A program that must not stop should
	accept in an active object of its own.

	Unix only; on Windows the same idea is a named pipe, which is a different call sequence and
	belongs in a module of its own. *)

IMPORT Streams, Strings, Unix;

CONST
	AFUNIX = 1;                        (* PF_UNIX: a socket named by a path *)
	SOCKSTREAM = 1;
	FIONREAD = 541BH;
	PathRoom = 108;                    (* what sun_path holds, and the reason paths here are short *)
	AddressRoom = 2 + PathRoom;        (* the family, then the path *)

TYPE
	Address = ARRAY AddressRoom OF CHAR;

	(** A connection to, or from, a program on this machine. *)
	Connection* = OBJECT
	VAR
		Reader-: Streams.Reader;       (** what the other side says *)
		Writer-: Streams.Writer;       (** what it is told *)
		fd: SIGNED32;

		PROCEDURE &Init* (descriptor: SIGNED32);
		BEGIN
			fd := descriptor;
			NEW(Reader, Receive, 4096);
			NEW(Writer, Send, 4096)
		END Init;

		(*	`min = 0` is a poll and may not wait: Streams.Reader.Available makes one whenever it is
			asked how much there is, and reading a quiet socket blocks until the other side says
			something. See Processes, where the same trap was found by a test. *)
		PROCEDURE Receive (VAR buffer: ARRAY OF CHAR; offset, size, min: SIZE;
			VAR length: SIZE; VAR result: INTEGER);
		VAR got: SIZE; ready: SIGNED32;
		BEGIN
			length := 0;
			IF min <= 0 THEN
				ready := 0;
				IF Unix.ioctl(fd, FIONREAD, ADDRESSOF(ready)) # 0 THEN ready := 0 END;
				IF ready <= 0 THEN result := Streams.Ok; RETURN END;
				IF ready < size THEN size := ready END
			END;
			LOOP
				got := Unix.read(fd, ADDRESSOF(buffer[offset]), size);
				IF got > 0 THEN
					INC(offset, got); DEC(size, got); INC(length, got)
				ELSIF got = 0 THEN
					EXIT                                  (* the other side closed it *)
				ELSE
					IF Unix.errno() # Unix.EINTR THEN EXIT END
				END;
				IF (length >= min) OR (size <= 0) THEN EXIT END
			END;
			IF length >= min THEN result := Streams.Ok ELSE result := Streams.EOF END
		END Receive;

		PROCEDURE Send (CONST buffer: ARRAY OF CHAR; offset, length: SIZE;
			propagate: BOOLEAN; VAR result: INTEGER);
		VAR written: SIZE;
		BEGIN
			result := Streams.Ok;
			WHILE length > 0 DO
				written := Unix.write(fd, ADDRESSOF(buffer[offset]), length);
				IF written <= 0 THEN
					IF Unix.errno() # Unix.EINTR THEN result := Streams.EOF; RETURN END
				ELSE
					INC(offset, written); DEC(length, written)
				END
			END
		END Send;

		(** How much can be read without waiting for it. *)
		PROCEDURE Waiting* (): SIGNED32;
		BEGIN RETURN SIGNED32(Reader.Available())
		END Waiting;

		(**	A line ended with one newline, and sent at once. That is what a control socket wants:
			one line is one command, and it is no use sitting in a buffer. Streams.Writer.Ln would
			put a carriage return in front of it. *)
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
		VAR ignore: SIGNED32;
		BEGIN
			IF fd >= 0 THEN Writer.Update; ignore := Unix.close(fd); fd := -1 END
		END Close;

	END Connection;

	(** A socket others connect to. The path is a name in the file system and is removed with it. *)
	Listener* = OBJECT
	VAR
		fd: SIGNED32;
		path: Strings.String;

		PROCEDURE &InitListener* (descriptor: SIGNED32; CONST name: ARRAY OF CHAR);
		BEGIN fd := descriptor; path := Strings.NewString(name)
		END InitListener;

		(** Wait for somebody to connect, and answer them. NIL if the socket has been closed. *)
		PROCEDURE Accept* (): Connection;
		VAR accepted: SIGNED32; c: Connection;
		BEGIN
			IF fd < 0 THEN RETURN NIL END;
			REPEAT
				accepted := accept(fd, 0, 0)
			UNTIL (accepted >= 0) OR (Unix.errno() # Unix.EINTR);
			IF accepted < 0 THEN RETURN NIL END;
			NEW(c, accepted); RETURN c
		END Accept;

		(** Stop listening, and take the name out of the file system. *)
		PROCEDURE Close*;
		VAR ignore: SIGNED32;
		BEGIN
			IF fd >= 0 THEN ignore := Unix.close(fd); fd := -1 END;
			IF path # NIL THEN ignore := Unix.unlink(ADDRESSOF(path[0])); path := NIL END
		END Close;

	END Listener;

VAR
	socket: PROCEDURE {C} (family, kind, protocol: SIGNED32): SIGNED32;
	connect: PROCEDURE {C} (fd: SIGNED32; address: ADDRESS; length: SIGNED32): SIGNED32;
	bind: PROCEDURE {C} (fd: SIGNED32; address: ADDRESS; length: SIGNED32): SIGNED32;
	listen: PROCEDURE {C} (fd: SIGNED32; backlog: SIGNED32): SIGNED32;
	accept: PROCEDURE {C} (fd: SIGNED32; address: ADDRESS; length: ADDRESS): SIGNED32;

	(*	sockaddr_un: the family in the first two bytes, then the path, ended by a zero byte. *)
	PROCEDURE Named (CONST path: ARRAY OF CHAR; VAR address: Address): BOOLEAN;
	VAR i: SIZE;
	BEGIN
		IF Strings.Length(path) >= PathRoom THEN RETURN FALSE END;
		FOR i := 0 TO LEN(address)-1 DO address[i] := 0X END;
		address[0] := CHR(AFUNIX MOD 100H); address[1] := CHR(AFUNIX DIV 100H);
		i := 0;
		WHILE path[i] # 0X DO address[2 + i] := path[i]; INC(i) END;
		RETURN TRUE
	END Named;

(**	Talk to whatever is listening at that path. NIL when there is nothing there, which is what a
	program that is not running looks like from here. *)
PROCEDURE Connect* (CONST path: ARRAY OF CHAR): Connection;
VAR address: Address; fd, ignore: SIGNED32; c: Connection;
BEGIN
	IF ~Named(path, address) THEN RETURN NIL END;
	fd := socket(AFUNIX, SOCKSTREAM, 0);
	IF fd < 0 THEN RETURN NIL END;
	IF connect(fd, ADDRESSOF(address[0]), AddressRoom) # 0 THEN
		ignore := Unix.close(fd); RETURN NIL
	END;
	NEW(c, fd); RETURN c
END Connect;

(**	Listen at that path, so that others can connect to it. The name must be free: a socket left
	behind by something that died is removed first, which is what every program that does this
	ends up doing. NIL when it cannot be had. *)
PROCEDURE Listen* (CONST path: ARRAY OF CHAR): Listener;
VAR address: Address; fd, ignore: SIGNED32; l: Listener;
BEGIN
	IF ~Named(path, address) THEN RETURN NIL END;
	fd := socket(AFUNIX, SOCKSTREAM, 0);
	IF fd < 0 THEN RETURN NIL END;
	ignore := Unix.unlink(ADDRESSOF(address[2]));
	IF bind(fd, ADDRESSOF(address[0]), AddressRoom) # 0 THEN
		ignore := Unix.close(fd); RETURN NIL
	END;
	IF listen(fd, 8) # 0 THEN
		ignore := Unix.close(fd); RETURN NIL
	END;
	NEW(l, fd, path); RETURN l
END Listen;

BEGIN
	Unix.Dlsym(Unix.libc, "socket", ADDRESSOF(socket));
	Unix.Dlsym(Unix.libc, "connect", ADDRESSOF(connect));
	Unix.Dlsym(Unix.libc, "bind", ADDRESSOF(bind));
	Unix.Dlsym(Unix.libc, "listen", ADDRESSOF(listen));
	Unix.Dlsym(Unix.libc, "accept", ADDRESSOF(accept))
END LocalSockets.
