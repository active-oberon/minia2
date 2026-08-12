MODULE TerminalCodes;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "What a terminal sends and understands: keys in, escape sequences out" *)

(*	Everything a full-screen program does through a terminal is bytes in a stream, and this module
	is the two directions of that: reading what was typed, and writing what should be drawn. It
	knows nothing about a terminal being a device -- no file descriptor, no raw mode, no size --
	which is Terminal's business, one module up, and the only part of this that is platform work.

	The split is not tidiness. A decoder that reads from any Streams.Reader can be given a string
	of bytes and asked what it made of them, so what a key press means is checked in a test rather
	than in front of a terminal (tests/Terminal.Test).

	The sequences are the ones xterm defines and every terminal since has followed, which is what
	btop and lazygit use as well: CSI for keys and mouse, SGR 1006 for mouse reporting, 24-bit
	colour. No terminfo, no ncurses: the strings below are the whole of it. *)

IMPORT Streams, UTF8Strings;

CONST
	ESC* = 1BX;

	(** what an event is *)
	None* = 0;         (** nothing was read *)
	Character* = 1;    (** a character was typed: `char` *)
	Key* = 2;          (** a key with no character of its own: `key` *)
	Mouse* = 3;        (** the pointer did something: `button`, `x`, `y` *)
	Unknown* = 4;      (** a sequence this module does not name; a program may ignore it *)

	(** keys, for events of kind Key *)
	Escape* = 1; Enter* = 2; Tab* = 3; Backspace* = 4;
	Insert* = 5; Delete* = 6; Home* = 7; End* = 8; PageUp* = 9; PageDown* = 10;
	Up* = 11; Down* = 12; Right* = 13; Left* = 14;
	F1* = 21; F2* = 22; F3* = 23; F4* = 24; F5* = 25; F6* = 26;
	F7* = 27; F8* = 28; F9* = 29; F10* = 30; F11* = 31; F12* = 32;

	(** modifiers, as reported for keys and for the mouse *)
	Shift* = 0; Alt* = 1; Ctrl* = 2;

	(** what the mouse did, in `button` *)
	LeftButton* = 0; MiddleButton* = 1; RightButton* = 2;
	Released* = 3; Moved* = 4; WheelUp* = 5; WheelDown* = 6;

TYPE
	Char32* = UTF8Strings.Char32;

	(**	One thing that happened at the terminal. `kind` says which of the other fields mean
		anything: Character uses `char`, Key uses `key`, Mouse uses `button` and `x`, `y` -- which
		count from one, as the terminal reports them. `modifiers` holds Shift, Alt and Ctrl. *)
	Event* = RECORD
		kind*: SIGNED32;
		char*: Char32;
		key*: SIGNED32;
		modifiers*: SET;
		button*, x*, y*: SIGNED32;
	END;

(* ---- reading what was typed ---- *)

	PROCEDURE SetKey (VAR e: Event; key: SIGNED32);
	BEGIN e.kind := Key; e.key := key
	END SetKey;

	PROCEDURE Bit (n, i: SIGNED32): BOOLEAN;
	BEGIN RETURN ODD(n DIV ASH(1, i))
	END Bit;

	(*	A CSI parameter list is numbers separated by semicolons. The second one, where a key has
		one, is the modifier state plus one -- 2 is Shift, 3 is Alt, 5 is Ctrl, and the rest are
		those added together. *)
	PROCEDURE Modifiers (n: SIGNED32): SET;
	VAR s: SET;
	BEGIN
		s := {};
		IF n <= 1 THEN RETURN s END;
		DEC(n);
		IF Bit(n, 0) THEN INCL(s, Shift) END;
		IF Bit(n, 1) THEN INCL(s, Alt) END;
		IF Bit(n, 2) THEN INCL(s, Ctrl) END;
		RETURN s
	END Modifiers;

	(*	The key a "CSI <n> ~" sequence names. The numbering is xterm's and has holes in it, which
		is why it is a list and not arithmetic. *)
	PROCEDURE Tilde (n: SIGNED32): SIGNED32;
	BEGIN
		CASE n OF
			  1: RETURN Home
			| 2: RETURN Insert
			| 3: RETURN Delete
			| 4: RETURN End
			| 5: RETURN PageUp
			| 6: RETURN PageDown
			| 7: RETURN Home
			| 8: RETURN End
			| 11: RETURN F1
			| 12: RETURN F2
			| 13: RETURN F3
			| 14: RETURN F4
			| 15: RETURN F5
			| 17: RETURN F6
			| 18: RETURN F7
			| 19: RETURN F8
			| 20: RETURN F9
			| 21: RETURN F10
			| 23: RETURN F11
			| 24: RETURN F12
		ELSE RETURN 0
		END
	END Tilde;

	(*	The letter that ends a CSI sequence, where it names a key by itself. *)
	PROCEDURE Final (ch: CHAR): SIGNED32;
	BEGIN
		CASE ch OF
			  "A": RETURN Up
			| "B": RETURN Down
			| "C": RETURN Right
			| "D": RETURN Left
			| "H": RETURN Home
			| "F": RETURN End
		ELSE RETURN 0
		END
	END Final;

	(*	The same for SS3, which is the only place P, Q, R and S are the first four function keys.
		After CSI those letters are something else entirely -- "CSI 6;1R" is a terminal answering
		where its cursor is, and reading that as a function key would be a key nobody pressed. *)
	PROCEDURE Ss3Final (ch: CHAR): SIGNED32;
	BEGIN
		CASE ch OF
			  "P": RETURN F1
			| "Q": RETURN F2
			| "R": RETURN F3
			| "S": RETURN F4
		ELSE RETURN Final(ch)
		END
	END Ss3Final;

	(*	The mouse, as SGR 1006 reports it: "CSI < b ; x ; y" ended by M for a press or m for a
		release. Bit 5 of b means the pointer moved, bit 6 that the wheel turned, and bits 2 to 4
		are the modifiers -- the same three, in a different order than the keys use. *)
	PROCEDURE SetMouse (VAR e: Event; b, x, y: SIGNED32; press: BOOLEAN);
	BEGIN
		e.kind := Mouse; e.x := x; e.y := y; e.modifiers := {};
		IF Bit(b, 2) THEN INCL(e.modifiers, Shift) END;
		IF Bit(b, 3) THEN INCL(e.modifiers, Alt) END;
		IF Bit(b, 4) THEN INCL(e.modifiers, Ctrl) END;
		IF Bit(b, 6) THEN
			IF Bit(b, 0) THEN e.button := WheelDown ELSE e.button := WheelUp END
		ELSIF Bit(b, 5) THEN
			e.button := Moved
		ELSIF ~press THEN
			e.button := Released
		ELSE
			e.button := b MOD 4
		END
	END SetMouse;

	(*	A control byte is a letter with Ctrl held, except for the four that mean something older
		and are still typed for it: return, tab and the two backspaces. *)
	PROCEDURE Control (VAR e: Event; ch: CHAR);
	VAR n: SIGNED32;
	BEGIN
		n := ORD(ch);
		IF (ch = 0DX) OR (ch = 0AX) THEN SetKey(e, Enter)
		ELSIF ch = 09X THEN SetKey(e, Tab)
		ELSIF (ch = 7FX) OR (ch = 08X) THEN SetKey(e, Backspace)
		ELSE
			e.kind := Character; e.modifiers := {Ctrl};
			IF n = 0 THEN e.char := ORD(" ") ELSE e.char := n + ORD("a") - 1 END
		END
	END Control;

	(*	The rest of a UTF-8 character, the first byte of which said how many bytes there are. *)
	PROCEDURE Continue (r: Streams.Reader; first: CHAR; VAR c: Char32): BOOLEAN;
	VAR n, i: SIGNED32; b: SIGNED32;
	BEGIN
		b := ORD(first);
		IF b < 0E0H THEN n := 1; c := b MOD 20H
		ELSIF b < 0F0H THEN n := 2; c := b MOD 10H
		ELSE n := 3; c := b MOD 8
		END;
		FOR i := 1 TO n DO
			IF r.Available() <= 0 THEN RETURN FALSE END;
			b := ORD(r.Get());
			IF b DIV 40H # 2 THEN RETURN FALSE END;     (* not a continuation byte *)
			c := c * 40H + (b MOD 40H)
		END;
		RETURN TRUE
	END Continue;

	(*	Everything after "ESC [": the parameters, then the byte that says what it was. *)
	PROCEDURE CSI (r: Streams.Reader; VAR e: Event);
	VAR par: ARRAY 8 OF SIGNED32; n, i: SIGNED32; ch: CHAR; mouse: BOOLEAN; key: SIGNED32;
	BEGIN
		FOR i := 0 TO LEN(par)-1 DO par[i] := 0 END;
		n := 0; mouse := FALSE;
		IF (r.Available() > 0) & (r.Peek() = "<") THEN mouse := TRUE; ch := r.Get() END;
		LOOP
			IF r.Available() <= 0 THEN e.kind := Unknown; RETURN END;
			ch := r.Get();
			IF (ch >= "0") & (ch <= "9") THEN
				par[n] := par[n] * 10 + (ORD(ch) - ORD("0"))
			ELSIF ch = ";" THEN
				IF n < LEN(par)-1 THEN INC(n) END
			ELSE
				EXIT                                     (* the final byte *)
			END
		END;
		IF mouse THEN
			SetMouse(e, par[0], par[1], par[2], ch = "M"); RETURN
		END;
		IF ch = "~" THEN
			key := Tilde(par[0])
		ELSIF ch = "Z" THEN
			SetKey(e, Tab); e.modifiers := {Shift}; RETURN
		ELSE
			key := Final(ch)
		END;
		IF key = 0 THEN e.kind := Unknown; RETURN END;
		SetKey(e, key);
		e.modifiers := Modifiers(par[1])                 (* "CSI 1 ; 5 C" is Ctrl and the right arrow *)
	END CSI;

	(**	The next event, read from whatever the terminal (or a test) is sending. FALSE when there is
		nothing more to read.

		A lone escape is the Escape key, and an escape with more behind it starts a sequence: the
		difference is whether anything follows, which is why this asks the reader what it has. A
		terminal sends a sequence in one burst, so a caller reading a real one should let the bytes
		arrive before deciding -- Terminal.Read does that waiting. *)
	PROCEDURE Read* (r: Streams.Reader; VAR e: Event): BOOLEAN;
	VAR ch: CHAR;
	BEGIN
		e.kind := None; e.char := 0; e.key := 0; e.modifiers := {};
		e.button := 0; e.x := 0; e.y := 0;
		IF r.Available() <= 0 THEN
			ch := r.Peek();                              (* let the reader fetch, then ask again *)
			IF r.Available() <= 0 THEN RETURN FALSE END
		END;
		ch := r.Get();
		IF ch = ESC THEN
			IF r.Available() <= 0 THEN SetKey(e, Escape); RETURN TRUE END;
			ch := r.Get();
			IF ch = "[" THEN
				CSI(r, e)
			ELSIF ch = "O" THEN
				IF r.Available() <= 0 THEN e.kind := Unknown; RETURN TRUE END;
				ch := r.Get();
				IF Ss3Final(ch) = 0 THEN e.kind := Unknown ELSE SetKey(e, Ss3Final(ch)) END
			ELSIF ch = ESC THEN
				SetKey(e, Escape)                        (* escape, and something else behind it *)
			ELSE
				(* escape and a character is that character with Alt held *)
				IF ORD(ch) < 20H THEN Control(e, ch) ELSE e.kind := Character; e.char := ORD(ch) END;
				INCL(e.modifiers, Alt)
			END
		ELSIF (ORD(ch) < 20H) OR (ch = 7FX) THEN
			Control(e, ch)
		ELSIF ORD(ch) < 80H THEN
			e.kind := Character; e.char := ORD(ch)
		ELSE
			e.kind := Character;
			IF ~Continue(r, ch, e.char) THEN e.kind := Unknown END
		END;
		RETURN TRUE
	END Read;

(* ---- writing what should be drawn ---- *)

	PROCEDURE Number (w: Streams.Writer; n: SIGNED32);
	BEGIN w.Int(n, 0)
	END Number;

	(** Put the cursor there. Rows and columns count from one, as the terminal counts them. *)
	PROCEDURE MoveTo* (w: Streams.Writer; row, column: SIGNED32);
	BEGIN
		w.Char(ESC); w.Char("["); Number(w, row); w.Char(";"); Number(w, column); w.Char("H")
	END MoveTo;

	(** Erase the whole screen. *)
	PROCEDURE Clear* (w: Streams.Writer);
	BEGIN w.Char(ESC); w.String("[2J")
	END Clear;

	(** Erase from the cursor to the end of its line. *)
	PROCEDURE ClearLine* (w: Streams.Writer);
	BEGIN w.Char(ESC); w.String("[K")
	END ClearLine;

	(** Colour the characters that follow, as red, green and blue from 0 to 255. *)
	PROCEDURE Foreground* (w: Streams.Writer; red, green, blue: SIGNED32);
	BEGIN
		w.Char(ESC); w.String("[38;2;"); Number(w, red); w.Char(";"); Number(w, green);
		w.Char(";"); Number(w, blue); w.Char("m")
	END Foreground;

	(** Colour the ground behind them. *)
	PROCEDURE Background* (w: Streams.Writer; red, green, blue: SIGNED32);
	BEGIN
		w.Char(ESC); w.String("[48;2;"); Number(w, red); w.Char(";"); Number(w, green);
		w.Char(";"); Number(w, blue); w.Char("m")
	END Background;

	(** Bold, and off again. *)
	PROCEDURE Bold* (w: Streams.Writer; on: BOOLEAN);
	BEGIN
		w.Char(ESC); IF on THEN w.String("[1m") ELSE w.String("[22m") END
	END Bold;

	(** Swap the two colours, and back. *)
	PROCEDURE Inverse* (w: Streams.Writer; on: BOOLEAN);
	BEGIN
		w.Char(ESC); IF on THEN w.String("[7m") ELSE w.String("[27m") END
	END Inverse;

	(** Plain characters again: no colour, no attribute. *)
	PROCEDURE Plain* (w: Streams.Writer);
	BEGIN w.Char(ESC); w.String("[0m")
	END Plain;

	(**	Draw on a screen of its own, and give the one underneath back when done. A program that
		does this leaves the terminal looking as it did before it started. *)
	PROCEDURE AltScreen* (w: Streams.Writer; on: BOOLEAN);
	BEGIN
		w.Char(ESC); IF on THEN w.String("[?1049h") ELSE w.String("[?1049l") END
	END AltScreen;

	(** Show the cursor, or hide it while drawing. *)
	PROCEDURE ShowCursor* (w: Streams.Writer; on: BOOLEAN);
	BEGIN
		w.Char(ESC); IF on THEN w.String("[?25h") ELSE w.String("[?25l") END
	END ShowCursor;

	(**	Ask for the mouse: presses, releases, motion while pressed, and the wheel, reported the
		way SGR 1006 reports them -- which is the only way that works past column 223. *)
	PROCEDURE TrackMouse* (w: Streams.Writer; on: BOOLEAN);
	BEGIN
		w.Char(ESC);
		IF on THEN w.String("[?1002h"); w.Char(ESC); w.String("[?1006h")
		ELSE w.String("[?1006l"); w.Char(ESC); w.String("[?1002l")
		END
	END TrackMouse;

	(** One character as the string of UTF-8 bytes it is, for putting it inside a line of text. *)
	PROCEDURE CharTo* (c: Char32; VAR s: ARRAY OF CHAR);
	VAR i: SIZE;
	BEGIN
		i := 0;
		IF UTF8Strings.EncodeChar(c, s, i) THEN s[i] := 0X ELSE s[0] := 0X END
	END CharTo;

	(** One character, in UTF-8, which is what a terminal expects and what box drawing needs. *)
	PROCEDURE WriteChar* (w: Streams.Writer; c: Char32);
	VAR s: ARRAY 8 OF CHAR; i: SIZE;
	BEGIN
		i := 0;
		IF UTF8Strings.EncodeChar(c, s, i) THEN s[i] := 0X; w.String(s) END
	END WriteChar;

END TerminalCodes.
