MODULE Terminal;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "The terminal as a device: raw mode, size, keys and drawing" *)

(*	The terminal a full-screen program needs is one that hands over every key press as it happens
	instead of a line at a time, does not echo what was typed, and can be asked how large it is.
	That is this module, and it is the only platform work in the two: the sequences themselves are
	TerminalCodes, which knows nothing about file descriptors.

	`Open` puts the terminal into that state and `Close` puts it back, and a program that forgets
	Close does not leave a terminal nobody can type into: the settings are restored when the
	process ends, whichever way it ends.

	Reading goes through StdIO's own reader rather than the file descriptor, because A2 already has
	a thread reading standard input and two readers on one descriptor would take each other's
	bytes.

	The size is asked for, not signalled. A2 chains signal handlers of its own, and SIGWINCH is
	worth nothing next to what a handler in the wrong place costs; asking the kernel takes an
	ioctl, and a program with an event loop asks once around it. `Resized` does exactly that. *)

IMPORT Streams, StdIO, Unix, Modules, Objects, TerminalCodes;

CONST
	(** the same events, keys and modifiers TerminalCodes defines, so one import is enough *)
	None* = TerminalCodes.None; Character* = TerminalCodes.Character;
	Key* = TerminalCodes.Key; Mouse* = TerminalCodes.Mouse; Unknown* = TerminalCodes.Unknown;

	Escape* = TerminalCodes.Escape; Enter* = TerminalCodes.Enter; Tab* = TerminalCodes.Tab;
	Backspace* = TerminalCodes.Backspace; Insert* = TerminalCodes.Insert;
	Delete* = TerminalCodes.Delete; Home* = TerminalCodes.Home; End* = TerminalCodes.End;
	PageUp* = TerminalCodes.PageUp; PageDown* = TerminalCodes.PageDown;
	Up* = TerminalCodes.Up; Down* = TerminalCodes.Down;
	Right* = TerminalCodes.Right; Left* = TerminalCodes.Left;
	F1* = TerminalCodes.F1; F2* = TerminalCodes.F2; F3* = TerminalCodes.F3;
	F4* = TerminalCodes.F4; F5* = TerminalCodes.F5; F6* = TerminalCodes.F6;
	F7* = TerminalCodes.F7; F8* = TerminalCodes.F8; F9* = TerminalCodes.F9;
	F10* = TerminalCodes.F10; F11* = TerminalCodes.F11; F12* = TerminalCodes.F12;

	Shift* = TerminalCodes.Shift; Alt* = TerminalCodes.Alt; Ctrl* = TerminalCodes.Ctrl;
	LeftButton* = TerminalCodes.LeftButton; MiddleButton* = TerminalCodes.MiddleButton;
	RightButton* = TerminalCodes.RightButton; Released* = TerminalCodes.Released;
	Moved* = TerminalCodes.Moved; WheelUp* = TerminalCodes.WheelUp;
	WheelDown* = TerminalCodes.WheelDown;

	stdin = 0;
	TCSAFLUSH = 2;                     (* change the settings once what is queued has been read *)
	TIOCGWINSZ = 5413H;                (* ask the kernel how large the window is *)

	(*	tio.lflags: signals from keys, line at a time, echo, and the terminal's own line editing *)
	ISIG = {0}; ICANON = {1}; ECHO = {3}; IEXTEN = {15};
	(*	tio.iflags: flow control by Ctrl-S, return turned into newline, break as an interrupt *)
	IXON = {9}; ICRNL = {8}; BRKINT = {1}; INPCK = {4}; ISTRIP = {5};
	(*	tio.oflags: the terminal's own output processing, which would rewrite what is drawn *)
	OPOST = {0};
	VMIN = 6; VTIME = 5;               (* how little a read may return, and how long it waits *)

	Settle = 2;                        (* milliseconds to let the rest of a sequence arrive *)

TYPE
	Event* = TerminalCodes.Event;
	Char32* = TerminalCodes.Char32;

	WinSize = RECORD
		rows, columns, xpixels, ypixels: UNSIGNED16;
	END;

VAR
	(** Where a program draws. Nothing appears until Flush. *)
	out-: Streams.Writer;
	in: Streams.Reader;
	saved: Unix.Termios;                (* the settings as they were, to put back *)
	raw: BOOLEAN;
	rows, columns: SIGNED32;            (* the size as it was last asked for *)

	tcgetattr: PROCEDURE {C} (fd: SIGNED32; VAR tio: Unix.Termios): SIGNED32;
	tcsetattr: PROCEDURE {C} (fd: SIGNED32; action: SIGNED32; VAR tio: Unix.Termios): SIGNED32;

	(** Is standard input a terminal at all? A program piped into a file is not, and cannot draw. *)
	PROCEDURE IsTerminal* (): BOOLEAN;
	VAR tio: Unix.Termios;
	BEGIN RETURN tcgetattr(stdin, tio) = 0
	END IsTerminal;

	(**	Hand over every key as it is pressed, and stop echoing. FALSE if standard input is not a
		terminal, which is the honest answer for a program with its input redirected. *)
	PROCEDURE Open* (): BOOLEAN;
	VAR tio: Unix.Termios;
	BEGIN
		IF raw THEN RETURN TRUE END;
		IF tcgetattr(stdin, saved) # 0 THEN RETURN FALSE END;
		tio := saved;
		tio.lflags := tio.lflags - ECHO - ICANON - IEXTEN - ISIG;
		tio.iflags := tio.iflags - IXON - ICRNL - BRKINT - INPCK - ISTRIP;
		tio.oflags := tio.oflags - OPOST;
		tio.cc[VMIN] := 1X;             (* a read returns as soon as there is one byte *)
		tio.cc[VTIME] := 0X;            (* and waits for it as long as it takes *)
		IF tcsetattr(stdin, TCSAFLUSH, tio) # 0 THEN RETURN FALSE END;
		raw := TRUE;
		RETURN TRUE
	END Open;

	(** Give the terminal back the way it was found. *)
	PROCEDURE Close*;
	VAR ignore: SIGNED32;
	BEGIN
		IF ~raw THEN RETURN END;
		out.Update;
		ignore := tcsetattr(stdin, TCSAFLUSH, saved);
		raw := FALSE
	END Close;

	(** How large the window is now, in rows and columns. *)
	PROCEDURE Size* (VAR height, width: SIGNED32): BOOLEAN;
	VAR ws: WinSize;
	BEGIN
		IF Unix.ioctl(stdin, TIOCGWINSZ, ADDRESSOF(ws)) # 0 THEN RETURN FALSE END;
		IF (ws.rows = 0) OR (ws.columns = 0) THEN RETURN FALSE END;
		height := ws.rows; width := ws.columns;
		rows := height; columns := width;
		RETURN TRUE
	END Size;

	(**	Has the window changed size since this was last asked? A program asks once around its event
		loop and redraws when the answer is yes. *)
	PROCEDURE Resized* (): BOOLEAN;
	VAR h, w, wasRows, wasColumns: SIGNED32;
	BEGIN
		wasRows := rows; wasColumns := columns;
		IF ~Size(h, w) THEN RETURN FALSE END;
		RETURN (h # wasRows) OR (w # wasColumns)
	END Resized;

	(**	The next thing that happened at the terminal, waiting for it. FALSE when standard input has
		ended, which is how a program is told to stop.

		An escape sequence arrives in one burst but is several bytes, and the escape key is one
		byte that looks like the start of one. So after an escape this waits a moment for the rest
		to turn up, and calls it the escape key only when nothing does. *)
	PROCEDURE Read* (VAR e: Event): BOOLEAN;
	VAR ch: CHAR;
	BEGIN
		IF in.Available() <= 0 THEN
			ch := in.Peek();                                  (* block until something is typed *)
			IF in.res # Streams.Ok THEN RETURN FALSE END
		END;
		IF (in.Available() = 1) & (in.Peek() = TerminalCodes.ESC) THEN Objects.Sleep(Settle) END;
		RETURN TerminalCodes.Read(in, e)
	END Read;

	(** Everything drawn so far, sent to the terminal. *)
	PROCEDURE Flush*;
	BEGIN out.Update
	END Flush;

	(* ---- drawing, which is TerminalCodes with our own writer ---- *)

	PROCEDURE MoveTo* (row, column: SIGNED32);
	BEGIN TerminalCodes.MoveTo(out, row, column)
	END MoveTo;

	PROCEDURE Clear*;
	BEGIN TerminalCodes.Clear(out)
	END Clear;

	PROCEDURE ClearLine*;
	BEGIN TerminalCodes.ClearLine(out)
	END ClearLine;

	PROCEDURE Foreground* (red, green, blue: SIGNED32);
	BEGIN TerminalCodes.Foreground(out, red, green, blue)
	END Foreground;

	PROCEDURE Background* (red, green, blue: SIGNED32);
	BEGIN TerminalCodes.Background(out, red, green, blue)
	END Background;

	PROCEDURE Bold* (on: BOOLEAN);
	BEGIN TerminalCodes.Bold(out, on)
	END Bold;

	PROCEDURE Inverse* (on: BOOLEAN);
	BEGIN TerminalCodes.Inverse(out, on)
	END Inverse;

	PROCEDURE Plain*;
	BEGIN TerminalCodes.Plain(out)
	END Plain;

	PROCEDURE AltScreen* (on: BOOLEAN);
	BEGIN TerminalCodes.AltScreen(out, on)
	END AltScreen;

	PROCEDURE ShowCursor* (on: BOOLEAN);
	BEGIN TerminalCodes.ShowCursor(out, on)
	END ShowCursor;

	PROCEDURE TrackMouse* (on: BOOLEAN);
	BEGIN TerminalCodes.TrackMouse(out, on)
	END TrackMouse;

	(** One character, in UTF-8: box drawing and braille are what a terminal draws pictures with. *)
	PROCEDURE WriteChar* (c: Char32);
	BEGIN TerminalCodes.WriteChar(out, c)
	END WriteChar;

	(** One character as the UTF-8 string it is, for putting it inside a line of text. *)
	PROCEDURE CharTo* (c: Char32; VAR s: ARRAY OF CHAR);
	BEGIN TerminalCodes.CharTo(c, s)
	END CharTo;

	(** A string, as it stands. *)
	PROCEDURE Write* (CONST s: ARRAY OF CHAR);
	BEGIN out.String(s)
	END Write;

	PROCEDURE Cleanup;
	BEGIN Close
	END Cleanup;

BEGIN
	in := StdIO.env.in; out := StdIO.env.out;
	raw := FALSE; rows := 0; columns := 0;
	Unix.Dlsym(Unix.libc, "tcgetattr", ADDRESSOF(tcgetattr));
	Unix.Dlsym(Unix.libc, "tcsetattr", ADDRESSOF(tcsetattr));
	Modules.InstallTermHandler(Cleanup)
END Terminal.
