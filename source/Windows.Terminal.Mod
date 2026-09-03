MODULE Terminal;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "The terminal as a device: raw mode, size, keys and drawing" *)

(*	The Windows twin of Unix.Terminal, and it is a twin rather than a second design: the sequences
	are TerminalCodes, the same module the Unix side draws with, because since Windows 10 the
	console understands them. What differs is only how the console is put into the state a
	full-screen program needs.

	Where Unix clears bits of termios, here two console modes are set: the input handle stops doing
	line editing, echoing and Ctrl-C, and starts handing over virtual terminal sequences; the
	output handle starts interpreting them. Both are put back by Close, and by the termination
	handler if a program forgets.

	The size comes from the console screen buffer's window rather than from an ioctl, and it is the
	window and not the buffer: a console buffer is usually taller than what is shown, and drawing
	to the buffer's height would scroll everything that was drawn off the top.

	What this does NOT do is the old console API -- SetConsoleCursorPosition, character attributes,
	a screen buffer written cell by cell. That is a second terminal model, it does not exist on the
	Unix side, and a program written against it would not compile there. A console without virtual
	terminal support -- Windows 8 and older, or a redirected handle -- makes Open answer FALSE, the
	same answer a Unix program gets when its input is a pipe. *)

IMPORT Streams, StdIO, Kernel32, Kernel, Modules, TerminalCodes;

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

	(*	Input modes. The three that are cleared are what the console does instead of handing the
		key over: ProcessedInput is Ctrl-C and friends, LineInput waits for Enter, EchoInput
		prints what was typed. VirtualTerminalInput is what makes the arrow keys arrive as the
		escape sequences TerminalCodes reads. *)
	ProcessedInput = 1; LineInput = 2; EchoInput = 4; VirtualTerminalInput = 200H;
	(*	Output modes. VirtualTerminalProcessing is the whole reason this module is short.
		NewlineAutoReturn is disabled so that a line drawn to the last column does not scroll. *)
	ProcessedOutput = 1; VirtualTerminalProcessing = 4; DisableNewlineAutoReturn = 8;

	(*	The console reads and writes bytes through a code page, and the default one is not UTF-8:
		the box drawing a full-screen program is made of arrives as whatever those bytes mean in
		CP437, which is how the demo looked when it was first run here. TerminalCodes writes
		UTF-8, so the console is told to expect it, and told back afterwards. *)
	UTF8Page = 65001;

	Settle = 2;                        (* milliseconds to let the rest of a sequence arrive *)

TYPE
	Event* = TerminalCodes.Event;
	Char32* = TerminalCodes.Char32;

VAR
	(** Where a program draws. Nothing appears until Flush. *)
	out-: Streams.Writer;
	in: Streams.Reader;
	input, output: Kernel32.HANDLE;
	savedIn, savedOut: SIGNED32;        (* the modes as they were, to put back *)
	savedInPage, savedOutPage: SIGNED32;
	raw: BOOLEAN;
	rows, columns: SIGNED32;            (* the size as it was last asked for *)
	(*	Objects.Sleep is the Unix twin's, and this host has no such procedure -- the timer object
		of Kernel is what both of them do have. *)
	settle: Kernel.Timer;

	(** Is standard input a console at all? A program piped into a file is not, and cannot draw. *)
	PROCEDURE IsTerminal* (): BOOLEAN;
	VAR mode: SIGNED32;
	BEGIN
		RETURN Kernel32.GetConsoleMode(input, mode) # 0
	END IsTerminal;

	(**	Hand over every key as it is pressed, and stop echoing. FALSE if standard input is not a
		console, or if the console cannot do virtual terminal sequences -- which is the honest
		answer for a program whose drawing would arrive as gibberish. *)
	PROCEDURE Open* (): BOOLEAN;
	VAR mode: SIGNED32; ignore: Kernel32.BOOL;
	BEGIN
		IF raw THEN RETURN TRUE END;
		IF Kernel32.GetConsoleMode(input, savedIn) = 0 THEN RETURN FALSE END;
		IF Kernel32.GetConsoleMode(output, savedOut) = 0 THEN RETURN FALSE END;
		mode := savedIn;
		mode := SIGNED32(SET32(mode) - SET32(ProcessedInput) - SET32(LineInput) - SET32(EchoInput));
		mode := SIGNED32(SET32(mode) + SET32(VirtualTerminalInput));
		IF Kernel32.SetConsoleMode(input, mode) = 0 THEN RETURN FALSE END;
		mode := SIGNED32(SET32(savedOut) + SET32(ProcessedOutput)
			+ SET32(VirtualTerminalProcessing) + SET32(DisableNewlineAutoReturn));
		IF Kernel32.SetConsoleMode(output, mode) = 0 THEN
			(*	An older console refuses the flag rather than ignoring it, and leaving the input
				handle in raw mode after that would be a console nobody can type into. *)
			mode := Kernel32.SetConsoleMode(input, savedIn);
			RETURN FALSE
		END;
		savedInPage := Kernel32.GetConsoleCP();
		savedOutPage := Kernel32.GetConsoleOutputCP();
		ignore := Kernel32.SetConsoleOutputCP(UTF8Page);
		ignore := Kernel32.SetConsoleCP(UTF8Page);
		raw := TRUE;
		RETURN TRUE
	END Open;

	(** Give the console back the way it was found. *)
	PROCEDURE Close*;
	VAR ignore: Kernel32.BOOL;
	BEGIN
		IF ~raw THEN RETURN END;
		out.Update;
		ignore := Kernel32.SetConsoleMode(input, savedIn);
		ignore := Kernel32.SetConsoleMode(output, savedOut);
		IF savedOutPage # 0 THEN ignore := Kernel32.SetConsoleOutputCP(savedOutPage) END;
		IF savedInPage # 0 THEN ignore := Kernel32.SetConsoleCP(savedInPage) END;
		raw := FALSE
	END Close;

	(** How large the window is now, in rows and columns. *)
	PROCEDURE Size* (VAR height, width: SIGNED32): BOOLEAN;
	VAR info: Kernel32.ConsoleScreenBufferInfo;
	BEGIN
		IF Kernel32.GetConsoleScreenBufferInfo(output, info) = 0 THEN RETURN FALSE END;
		(* the window, not the buffer: the buffer is usually the taller of the two *)
		height := info.window.bottom - info.window.top + 1;
		width := info.window.right - info.window.left + 1;
		IF (height <= 0) OR (width <= 0) THEN RETURN FALSE END;
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
		ended, which is how a program is told to stop. *)
	PROCEDURE Read* (VAR e: Event): BOOLEAN;
	VAR ch: CHAR;
	BEGIN
		IF in.Available() <= 0 THEN
			ch := in.Peek();                                  (* block until something is typed *)
			IF in.res # Streams.Ok THEN RETURN FALSE END
		END;
		IF (in.Available() = 1) & (in.Peek() = TerminalCodes.ESC) THEN settle.Sleep(Settle) END;
		RETURN TerminalCodes.Read(in, e)
	END Read;

	(**	Has something been typed? A program with more than the keyboard to watch asks this instead
		of reading, and gets on with the rest when the answer is no. *)
	PROCEDURE Pending* (): BOOLEAN;
	BEGIN RETURN in.Available() > 0
	END Pending;

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
	raw := FALSE; rows := 0; columns := 0; savedInPage := 0; savedOutPage := 0;
	NEW(settle);
	input := Kernel32.GetStdHandle(Kernel32.STDInput);
	output := Kernel32.GetStdHandle(Kernel32.STDOutput);
	Modules.InstallTermHandler(Cleanup)
END Terminal.
