MODULE Keys;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Show what the terminal sends, and what it can draw" *)

(*	A full-screen program in about a hundred lines: no ncurses, no terminfo, no toolkit. It takes
	the terminal over, draws a framed panel, and names every key press, mouse click and resize as
	it happens.

	It is also how the terminal is checked by hand, since a decoder can be asked what a sequence
	means (tests/Terminal.Test) but only a real terminal can be asked what it sends.

	    ob run examples/Keys.Mod        -- q or Escape leaves.
*)

IMPORT Terminal, Strings, Commands;

CONST
	Title = " Keys -- press anything, q to leave ";

VAR
	rows, columns: SIGNED32;
	log: ARRAY 64 OF ARRAY 80 OF CHAR;      (* the last events, newest last *)
	entries: SIGNED32;

	(* --- drawing --- *)

	PROCEDURE Box (top, left, height, width: SIGNED32; CONST title: ARRAY OF CHAR);
	VAR i: SIGNED32;
	BEGIN
		Terminal.Foreground(90, 130, 190);
		Terminal.MoveTo(top, left); Terminal.WriteChar(256DH);            (* ┌ *)
		FOR i := 2 TO width-1 DO Terminal.WriteChar(2500H) END;           (* ─ *)
		Terminal.WriteChar(256EH);                                        (* ┐ *)
		FOR i := 1 TO height-2 DO
			Terminal.MoveTo(top + i, left); Terminal.WriteChar(2502H);        (* │ *)
			Terminal.MoveTo(top + i, left + width - 1); Terminal.WriteChar(2502H)
		END;
		Terminal.MoveTo(top + height - 1, left); Terminal.WriteChar(2570H);   (* ╰ *)
		FOR i := 2 TO width-1 DO Terminal.WriteChar(2500H) END;
		Terminal.WriteChar(256FH);                                        (* ╯ *)
		Terminal.MoveTo(top, left + 2);
		Terminal.Bold(TRUE); Terminal.Foreground(230, 230, 230);
		Terminal.Write(title);
		Terminal.Bold(FALSE); Terminal.Plain
	END Box;

	PROCEDURE Draw;
	VAR i, first, line: SIGNED32; size: ARRAY 32 OF CHAR;
	BEGIN
		Terminal.Clear;
		Box(1, 1, rows, columns, Title);
		Terminal.MoveTo(2, 3); Terminal.Foreground(140, 140, 140);
		size := "terminal is "; Strings.AppendInt(size, columns);
		Strings.Append(size, " by "); Strings.AppendInt(size, rows);
		Terminal.Write(size); Terminal.Plain;

		(* the last events that fit, oldest first, so the newest is always at the bottom *)
		line := rows - 2;
		first := entries - (rows - 5); IF first < 0 THEN first := 0 END;
		FOR i := entries-1 TO first BY -1 DO
			Terminal.MoveTo(line, 3);
			IF i = entries-1 THEN Terminal.Bold(TRUE) ELSE Terminal.Foreground(160, 160, 160) END;
			Terminal.Write(log[i MOD LEN(log)]);
			Terminal.Plain;
			DEC(line)
		END;
		Terminal.Flush
	END Draw;

	(* --- what happened, in words --- *)

	PROCEDURE Note (CONST what: ARRAY OF CHAR);
	BEGIN
		COPY(what, log[entries MOD LEN(log)]); INC(entries)
	END Note;

	PROCEDURE AppendHex (VAR s: ARRAY OF CHAR; n: SIGNED32);
	CONST digits = "0123456789ABCDEF";
	VAR d: ARRAY 12 OF CHAR; i, k: SIGNED32; one: ARRAY 2 OF CHAR;
	BEGIN
		i := 0;
		REPEAT d[i] := digits[n MOD 16]; n := n DIV 16; INC(i) UNTIL n = 0;
		one[1] := 0X;
		FOR k := i-1 TO 0 BY -1 DO one[0] := d[k]; Strings.Append(s, one) END
	END AppendHex;

	PROCEDURE AppendModifiers (VAR s: ARRAY OF CHAR; modifiers: SET);
	BEGIN
		IF Terminal.Ctrl IN modifiers THEN Strings.Append(s, "Ctrl-") END;
		IF Terminal.Alt IN modifiers THEN Strings.Append(s, "Alt-") END;
		IF Terminal.Shift IN modifiers THEN Strings.Append(s, "Shift-") END
	END AppendModifiers;

	PROCEDURE KeyName (key: SIGNED32; VAR s: ARRAY OF CHAR);
	BEGIN
		CASE key OF
			  Terminal.Escape: COPY("Escape", s)
			| Terminal.Enter: COPY("Enter", s)
			| Terminal.Tab: COPY("Tab", s)
			| Terminal.Backspace: COPY("Backspace", s)
			| Terminal.Insert: COPY("Insert", s)
			| Terminal.Delete: COPY("Delete", s)
			| Terminal.Home: COPY("Home", s)
			| Terminal.End: COPY("End", s)
			| Terminal.PageUp: COPY("PageUp", s)
			| Terminal.PageDown: COPY("PageDown", s)
			| Terminal.Up: COPY("Up", s)
			| Terminal.Down: COPY("Down", s)
			| Terminal.Right: COPY("Right", s)
			| Terminal.Left: COPY("Left", s)
		ELSE
			IF (key >= Terminal.F1) & (key <= Terminal.F12) THEN
				COPY("F", s); Strings.AppendInt(s, key - Terminal.F1 + 1)
			ELSE
				COPY("?", s)
			END
		END
	END KeyName;

	PROCEDURE Describe (CONST e: Terminal.Event; VAR s: ARRAY OF CHAR);
	VAR name: ARRAY 32 OF CHAR;
	BEGIN
		s := "";
		AppendModifiers(s, e.modifiers);
		CASE e.kind OF
			  Terminal.Character:
				Strings.Append(s, "character  ");
				IF e.char >= 20H THEN Terminal.CharTo(e.char, name); Strings.Append(s, name) END;
				Strings.Append(s, "  U+"); AppendHex(s, SIGNED32(e.char))
			| Terminal.Key:
				KeyName(e.key, name); Strings.Append(s, "key  "); Strings.Append(s, name)
			| Terminal.Mouse:
				CASE e.button OF
					  Terminal.LeftButton: Strings.Append(s, "mouse  left")
					| Terminal.MiddleButton: Strings.Append(s, "mouse  middle")
					| Terminal.RightButton: Strings.Append(s, "mouse  right")
					| Terminal.Released: Strings.Append(s, "mouse  released")
					| Terminal.Moved: Strings.Append(s, "mouse  moved")
					| Terminal.WheelUp: Strings.Append(s, "wheel  up")
					| Terminal.WheelDown: Strings.Append(s, "wheel  down")
				ELSE Strings.Append(s, "mouse")
				END;
				Strings.Append(s, "  at "); Strings.AppendInt(s, e.x);
				Strings.Append(s, ","); Strings.AppendInt(s, e.y)
		ELSE
			Strings.Append(s, "a sequence this does not name")
		END
	END Describe;

	(* `ob run Keys.Mod` invokes the exported command Do. *)
	PROCEDURE Do*(context: Commands.Context);
	VAR e: Terminal.Event; said: ARRAY 80 OF CHAR; leave: BOOLEAN;
	BEGIN
		IF ~Terminal.Open() THEN
			context.error.String("Keys: standard input is not a terminal"); context.error.Ln;
			RETURN
		END;
		IF ~Terminal.Size(rows, columns) THEN rows := 24; columns := 80 END;
		Terminal.AltScreen(TRUE); Terminal.ShowCursor(FALSE); Terminal.TrackMouse(TRUE);
		entries := 0;
		Note("waiting");
		Draw;
		leave := FALSE;
		WHILE ~leave & Terminal.Read(e) DO
			IF (e.kind = Terminal.Character) & ((e.char = ORD("q")) OR (e.char = ORD("Q")))
					& (e.modifiers = {}) THEN
				leave := TRUE
			ELSIF (e.kind = Terminal.Key) & (e.key = Terminal.Escape) THEN
				leave := TRUE
			ELSE
				Describe(e, said); Note(said);
				IF Terminal.Resized() THEN
					IF Terminal.Size(rows, columns) THEN Note("the window changed size") END
				END;
				Draw
			END
		END;
		Terminal.TrackMouse(FALSE); Terminal.ShowCursor(TRUE); Terminal.AltScreen(FALSE);
		Terminal.Flush;
		Terminal.Close
	END Do;

BEGIN
	entries := 0
END Keys.
