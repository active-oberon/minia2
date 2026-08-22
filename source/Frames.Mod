MODULE Frames;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Oberon's model of a screen, drawn into a terminal" *)

(*	Tiled frames of text, a caret in one of them, and any line in any of them runnable as a
	command. That is the whole of the Oberon interface, and it is what btop and lazygit look
	like from a distance -- with the difference that matters: there, the keys are the ones the
	author chose, and here the text itself is what is run, so a program's log is a list of
	commands somebody can edit and run again.

	Nothing here knows it is talking to a terminal. A frame draws into a Streams.Writer and is
	given events; what turns key presses into events and a writer into a screen is Terminal, and
	what a program writes is the loop between them -- some twenty lines, and the place its own
	behaviour goes. Because of that split a screen can be laid out, typed into and asked what it
	drew inside one process, which is what tests/Frames.Test does.

	A text here is a list of lines, not a rope: the frames this is for hold a screenful of a log
	or a list of commands. Where a real editor is wanted, this is not it. *)

IMPORT Streams, Strings, Commands, TerminalCodes, UTF8Strings;

CONST
	MaxFrames* = 8;                    (** how many frames one screen holds *)
	Chrome = 2;                        (* the two rows and columns the border takes *)

TYPE
	(** A text as frames use it: lines, numbered from zero. *)
	Text* = OBJECT
	VAR
		line: POINTER TO ARRAY OF Strings.String;
		count-: SIGNED32;              (** how many lines it has *)

		PROCEDURE &Init*;
		BEGIN NEW(line, 64); count := 0
		END Init;

		PROCEDURE Grow;
		VAR bigger: POINTER TO ARRAY OF Strings.String; i: SIGNED32;
		BEGIN
			NEW(bigger, LEN(line) * 2);
			FOR i := 0 TO count-1 DO bigger[i] := line[i] END;
			line := bigger
		END Grow;

		(** The text of a line, or NIL when there is no such line. *)
		PROCEDURE Get* (i: SIGNED32): Strings.String;
		BEGIN
			IF (i < 0) OR (i >= count) THEN RETURN NIL END;
			RETURN line[i]
		END Get;

		PROCEDURE Set* (i: SIGNED32; CONST s: ARRAY OF CHAR);
		BEGIN
			IF (i >= 0) & (i < count) THEN line[i] := Strings.NewString(s) END
		END Set;

		(** Put a line in at i; i = count appends. *)
		PROCEDURE Insert* (i: SIGNED32; CONST s: ARRAY OF CHAR);
		VAR k: SIGNED32;
		BEGIN
			IF (i < 0) OR (i > count) THEN RETURN END;
			IF count = SIGNED32(LEN(line)) THEN Grow END;
			FOR k := count TO i+1 BY -1 DO line[k] := line[k-1] END;
			line[i] := Strings.NewString(s); INC(count)
		END Insert;

		PROCEDURE Add* (CONST s: ARRAY OF CHAR);
		BEGIN Insert(count, s)
		END Add;

		PROCEDURE Delete* (i: SIGNED32);
		VAR k: SIGNED32;
		BEGIN
			IF (i < 0) OR (i >= count) THEN RETURN END;
			FOR k := i TO count-2 DO line[k] := line[k+1] END;
			DEC(count)
		END Delete;

		PROCEDURE Clear*;
		BEGIN count := 0
		END Clear;

		(** Every line of a piece of text at once, split where the newlines are. *)
		PROCEDURE AddText* (CONST s: ARRAY OF CHAR);
		VAR one: ARRAY 1024 OF CHAR; i, n: SIZE;
		BEGIN
			i := 0; n := 0;
			WHILE s[i] # 0X DO
				IF (s[i] = 0AX) OR (n = LEN(one)-1) THEN
					one[n] := 0X; Add(one); n := 0
				ELSIF s[i] # 0DX THEN
					one[n] := s[i]; INC(n)
				END;
				INC(i)
			END;
			IF n > 0 THEN one[n] := 0X; Add(one) END
		END AddText;

	END Text;

	(**	A frame: a rectangle of the screen showing a text, with a caret in it. Where it is drawn
		is set by the screen that holds it; what it shows and where the caret is are its own. *)
	Frame* = OBJECT
	VAR
		title*: ARRAY 128 OF CHAR;
		text*: Text;
		top*: SIGNED32;                (** the first line drawn *)
		caret*: SIGNED32;              (** the line the caret is on *)
		column*: SIGNED32;             (** and where in it *)
		editable*: BOOLEAN;            (** whether typing changes the text *)
		row-, col-, height-, width-: SIGNED32;   (** where the screen last put it *)

		PROCEDURE &InitFrame* (CONST name: ARRAY OF CHAR; t: Text);
		BEGIN
			COPY(name, title); text := t;
			top := 0; caret := 0; column := 0; editable := TRUE;
			row := 1; col := 1; height := 1; width := 1
		END InitFrame;

		(** Where on the screen this frame is, counted from one, border included. *)
		PROCEDURE Place* (atRow, atColumn, rows, columns: SIGNED32);
		BEGIN row := atRow; col := atColumn; height := rows; width := columns
		END Place;

		(** How many lines of text fit inside the border. *)
		PROCEDURE Room* (): SIGNED32;
		BEGIN RETURN height - Chrome
		END Room;

		(** The line the caret is on. *)
		PROCEDURE Line* (): Strings.String;
		BEGIN RETURN text.Get(caret)
		END Line;

		(* Keep the caret inside the text, and the text under the caret in view. *)
		PROCEDURE Follow;
		VAR s: Strings.String; length: SIGNED32;
		BEGIN
			IF caret >= text.count THEN caret := text.count - 1 END;
			IF caret < 0 THEN caret := 0 END;
			s := text.Get(caret);
			IF s = NIL THEN length := 0 ELSE length := SIGNED32(Strings.Length(s^)) END;
			IF column > length THEN column := length END;
			IF column < 0 THEN column := 0 END;
			IF caret < top THEN top := caret END;
			IF caret >= top + Room() THEN top := caret - Room() + 1 END;
			IF top < 0 THEN top := 0 END
		END Follow;

		(** Show the last line, which is what a log wants after something is added to it. *)
		PROCEDURE ToEnd*;
		BEGIN caret := text.count - 1; column := 0; Follow
		END ToEnd;

		(**	Draw the border, the title and the lines that fit. The caret is drawn as an inverted
			character, not as the terminal's own cursor: a screen has one cursor and several
			frames, and a frame that is not the focused one still has a caret to show. *)
		PROCEDURE Draw* (w: Streams.Writer; focused: BOOLEAN);
		VAR i, y: SIGNED32; s: Strings.String;
		BEGIN
			Follow;
			Border(w, row, col, height, width, title, focused);
			FOR i := 0 TO Room()-1 DO
				y := row + 1 + i;
				TerminalCodes.MoveTo(w, y, col + 1);
				s := text.Get(top + i);
				IF s # NIL THEN
					IF (top + i = caret) & focused THEN TerminalCodes.Inverse(w, TRUE) END;
					Fitted(w, s^, width - Chrome);
					IF (top + i = caret) & focused THEN TerminalCodes.Inverse(w, FALSE) END
				ELSE
					Blanks(w, width - Chrome)
				END
			END
		END Draw;

		(**	What the frame makes of an event. TRUE when it used it, so that a program can give an
			event to the frame first and keep for itself whatever the frame did not want. *)
		PROCEDURE Handle* (CONST e: TerminalCodes.Event): BOOLEAN;
		VAR s: Strings.String; text1, text2: ARRAY 1024 OF CHAR; length: SIGNED32;
		BEGIN
			IF e.kind = TerminalCodes.Key THEN
				CASE e.key OF
					  TerminalCodes.Up: DEC(caret); Follow; RETURN TRUE
					| TerminalCodes.Down: INC(caret); Follow; RETURN TRUE
					| TerminalCodes.Left: DEC(column); Follow; RETURN TRUE
					| TerminalCodes.Right: INC(column); Follow; RETURN TRUE
					| TerminalCodes.PageUp: DEC(caret, Room()); Follow; RETURN TRUE
					| TerminalCodes.PageDown: INC(caret, Room()); Follow; RETURN TRUE
					| TerminalCodes.Home: column := 0; RETURN TRUE
					| TerminalCodes.End:
						s := Line();
						IF s # NIL THEN column := SIGNED32(Strings.Length(s^)) END;
						RETURN TRUE
				ELSE
				END;
				IF ~editable THEN RETURN FALSE END;
				CASE e.key OF
					  TerminalCodes.Enter:
						Split(text1, text2); text.Set(caret, text1);
						text.Insert(caret + 1, text2); INC(caret); column := 0; Follow;
						RETURN TRUE
					| TerminalCodes.Backspace:
						IF column > 0 THEN
							s := Line(); COPY(s^, text1);
							Remove(text1, column - 1); text.Set(caret, text1); DEC(column)
						ELSIF caret > 0 THEN
							s := text.Get(caret - 1); COPY(s^, text1);
							length := SIGNED32(Strings.Length(text1));
							s := Line(); Strings.Append(text1, s^);
							text.Set(caret - 1, text1); text.Delete(caret);
							DEC(caret); column := length
						END;
						Follow; RETURN TRUE
					| TerminalCodes.Delete:
						s := Line();
						IF (s # NIL) & (column < SIGNED32(Strings.Length(s^))) THEN
							COPY(s^, text1); Remove(text1, column); text.Set(caret, text1)
						END;
						RETURN TRUE
				ELSE RETURN FALSE
				END
			ELSIF (e.kind = TerminalCodes.Character) & editable & (e.modifiers = {}) THEN
				s := Line(); IF s = NIL THEN RETURN FALSE END;
				COPY(s^, text1);
				TerminalCodes.CharTo(e.char, text2);
				IF Insert(text1, column, text2) THEN
					text.Set(caret, text1); INC(column); RETURN TRUE
				END;
				RETURN FALSE
			END;
			RETURN FALSE
		END Handle;

		(* The line under the caret, cut in two where the caret is. *)
		PROCEDURE Split (VAR before, after: ARRAY OF CHAR);
		VAR s: Strings.String; i: SIGNED32;
		BEGIN
			s := Line();
			IF s = NIL THEN before := ""; after := ""; RETURN END;
			i := 0;
			WHILE (i < column) & (s[i] # 0X) DO before[i] := s[i]; INC(i) END;
			before[i] := 0X;
			i := 0;
			WHILE s[column + i] # 0X DO after[i] := s[column + i]; INC(i) END;
			after[i] := 0X
		END Split;

	END Frame;

	(**	A screen, as Oberon divides one: vertical tracks side by side, and in each track the frames
		stacked one above the other. Tiled throughout -- no frame is ever hidden behind another,
		which is the whole reason the model needs no window manager.

		A screen with one frame in each of two tracks is two columns; a screen with two frames in
		one track is two rows; and the arrangement most programs want -- a narrow list beside a
		pair of frames -- is what neither of those alone could say. *)
	Screen* = OBJECT
	VAR
		frame: ARRAY MaxFrames OF Frame;
		inTrack: ARRAY MaxFrames OF SIGNED32;      (* which track each frame is in *)
		share: ARRAY MaxFrames OF SIGNED32;        (* how wide each track is, in shares *)
		count-: SIGNED32;
		tracks-: SIGNED32;
		focus-: SIGNED32;              (** which frame the keys go to *)

		PROCEDURE &InitScreen*;
		BEGIN count := 0; focus := 0; tracks := 0
		END InitScreen;

		(** Another column, this many shares of the width wide. Frames added next go in it. *)
		PROCEDURE NewTrack* (width: SIGNED32);
		BEGIN
			IF tracks < MaxFrames THEN
				IF width < 1 THEN width := 1 END;
				share[tracks] := width; INC(tracks)
			END
		END NewTrack;

		(** Add a frame to the track being filled; the first one starts a track of its own. *)
		PROCEDURE Add* (f: Frame);
		BEGIN
			IF tracks = 0 THEN NewTrack(1) END;
			IF count < MaxFrames THEN
				frame[count] := f; inTrack[count] := tracks - 1; INC(count)
			END
		END Add;

		PROCEDURE At* (i: SIGNED32): Frame;
		BEGIN
			IF (i < 0) OR (i >= count) THEN RETURN NIL END;
			RETURN frame[i]
		END At;

		PROCEDURE Focused* (): Frame;
		BEGIN RETURN At(focus)
		END Focused;

		PROCEDURE Focus* (i: SIGNED32);
		BEGIN
			IF (i >= 0) & (i < count) THEN focus := i END
		END Focus;

		PROCEDURE InTrack (t: SIGNED32): SIGNED32;
		VAR i, n: SIGNED32;
		BEGIN
			n := 0;
			FOR i := 0 TO count-1 DO IF inTrack[i] = t THEN INC(n) END END;
			RETURN n
		END InTrack;

		(**	Divide a terminal of that size between the tracks, and each track between its frames.
			What does not divide evenly goes to the last, which is where a leftover column shows
			least. *)
		PROCEDURE Layout* (rows, columns: SIGNED32);
		VAR t, i, shares, wide, left, high, top, here, done: SIGNED32;
		BEGIN
			IF count = 0 THEN RETURN END;
			shares := 0;
			FOR t := 0 TO tracks-1 DO INC(shares, share[t]) END;
			IF shares = 0 THEN RETURN END;
			left := 1;
			FOR t := 0 TO tracks-1 DO
				wide := columns * share[t] DIV shares;
				IF t = tracks-1 THEN wide := columns - left + 1 END;
				here := InTrack(t);
				IF here > 0 THEN
					top := 1; done := 0;
					FOR i := 0 TO count-1 DO
						IF inTrack[i] = t THEN
							INC(done);
							high := rows DIV here;
							IF done = here THEN high := rows - top + 1 END;
							frame[i].Place(top, left, high, wide);
							INC(top, high)
						END
					END
				END;
				INC(left, wide)
			END
		END Layout;

		(**	Draw the frames over what is already there. Nothing is cleared first: every frame
			paints every cell it owns, borders and blanks included, so clearing would only mean
			the screen spends a moment empty -- which is what flicker is. *)
		PROCEDURE Draw* (w: Streams.Writer);
		VAR i: SIGNED32;
		BEGIN
			FOR i := 0 TO count-1 DO frame[i].Draw(w, i = focus) END
		END Draw;

		(**	Clear first, then draw. For after a resize, where the frames no longer cover what the
			old ones did, and once at the start. *)
		PROCEDURE Refresh* (w: Streams.Writer);
		BEGIN TerminalCodes.Clear(w); Draw(w)
		END Refresh;

		(**	Tab moves the caret to the next frame and Shift-Tab to the one before; everything else
			is the focused frame's, and what it does not want comes back to the program. *)
		PROCEDURE Handle* (CONST e: TerminalCodes.Event): BOOLEAN;
		BEGIN
			IF (e.kind = TerminalCodes.Key) & (e.key = TerminalCodes.Tab) & (count > 1) THEN
				IF TerminalCodes.Shift IN e.modifiers THEN
					focus := (focus + count - 1) MOD count
				ELSE
					focus := (focus + 1) MOD count
				END;
				RETURN TRUE
			END;
			IF Focused() = NIL THEN RETURN FALSE END;
			RETURN Focused().Handle(e)
		END Handle;

	END Screen;

(* ---- running a line ---- *)

(**	Any line is a command: the first word names it, in the form Module.Procedure, and the rest
	are its arguments. What it writes goes into `into`, line by line, which is how a log in one
	frame is filled by a command run from another -- and, being a text like any other, is itself
	a list of lines somebody can run again. FALSE when there is no such command; the reason is
	appended to `into` either way. *)
PROCEDURE Execute* (CONST line: ARRAY OF CHAR; into: Text): BOOLEAN;
VAR command: ARRAY 128 OF CHAR; arguments: ARRAY 1024 OF CHAR;
	i, n: SIZE; context: Commands.Context; arg: Streams.StringReader;
	buffer: Streams.Buffer; w: Streams.Writer; result: INTEGER;
	message: ARRAY 256 OF CHAR; said: Strings.String;
BEGIN
	i := 0;
	WHILE (line[i] = " ") OR (line[i] = 09X) DO INC(i) END;
	n := 0;
	WHILE (line[i] # 0X) & (line[i] # " ") & (line[i] # 09X) & (n < LEN(command)-1) DO
		command[n] := line[i]; INC(n); INC(i)
	END;
	command[n] := 0X;
	IF command[0] = 0X THEN RETURN TRUE END;                (* an empty line runs nothing *)
	n := 0;
	WHILE (line[i] # 0X) & (n < LEN(arguments)-1) DO arguments[n] := line[i]; INC(n); INC(i) END;
	arguments[n] := 0X;

	NEW(arg, LEN(arguments) + 1); arg.Set(arguments);
	NEW(buffer, 1024); w := buffer.GetWriter();
	NEW(context, NIL, arg, w, w, NIL);
	Commands.Activate(command, context, {Commands.Wait}, result, message);
	w.Update;
	said := buffer.GetString();
	IF (said # NIL) & (said^ # "") THEN into.AddText(said^) END;
	IF result # Commands.Ok THEN into.Add(message) END;
	RETURN result = Commands.Ok
END Execute;

(* ---- drawing, the parts a frame is made of ---- *)

PROCEDURE Blanks (w: Streams.Writer; n: SIGNED32);
VAR i: SIGNED32;
BEGIN FOR i := 1 TO n DO w.Char(" ") END
END Blanks;

(*	As much of a line as the width allows, and blanks for the rest of it. Counted in characters,
	not in bytes: a Cyrillic letter is one column and two bytes, so counting bytes both ended the
	line early and could cut a sequence in half -- which a terminal draws as a replacement glyph.
	Found on a phone, where the catalogue of a radio program is in Ukrainian.
	ponytail: one column per code point. Wrong for the wide characters of CJK and for combining
	marks; a width table is the upgrade, and nothing here needs one yet. *)
PROCEDURE Fitted (w: Streams.Writer; CONST s: ARRAY OF CHAR; width: SIGNED32);
VAR i, next: SIZE; columns: SIGNED32; ucs: UTF8Strings.Char32;
BEGIN
	i := 0; columns := 0;
	WHILE (columns < width) & (s[i] # 0X) DO
		next := i;
		(* a byte that decodes as nothing is written as itself, so that a malformed line still
			appears and still ends -- the alternative is a loop that never advances *)
		IF ~UTF8Strings.DecodeChar(s, next, ucs) OR (next <= i) THEN next := i + 1 END;
		WHILE i < next DO w.Char(s[i]); INC(i) END;
		INC(columns)
	END;
	Blanks(w, width - columns)
END Fitted;

(*	The box around a frame, with its name in the top edge. Rounded corners, because that is what
	the terminals people use draw well, and one colour for the frame with the caret in it. *)
PROCEDURE Border (w: Streams.Writer; row, col, height, width: SIGNED32;
	CONST title: ARRAY OF CHAR; focused: BOOLEAN);
VAR i: SIGNED32;
BEGIN
	IF focused THEN TerminalCodes.Foreground(w, 120, 170, 240)
	ELSE TerminalCodes.Foreground(w, 90, 90, 90)
	END;
	TerminalCodes.MoveTo(w, row, col); TerminalCodes.WriteChar(w, 256DH);
	FOR i := 2 TO width-1 DO TerminalCodes.WriteChar(w, 2500H) END;
	TerminalCodes.WriteChar(w, 256EH);
	FOR i := 1 TO height-2 DO
		TerminalCodes.MoveTo(w, row + i, col); TerminalCodes.WriteChar(w, 2502H);
		TerminalCodes.MoveTo(w, row + i, col + width - 1); TerminalCodes.WriteChar(w, 2502H)
	END;
	TerminalCodes.MoveTo(w, row + height - 1, col); TerminalCodes.WriteChar(w, 2570H);
	FOR i := 2 TO width-1 DO TerminalCodes.WriteChar(w, 2500H) END;
	TerminalCodes.WriteChar(w, 256FH);
	IF title # "" THEN
		TerminalCodes.MoveTo(w, row, col + 2);
		IF focused THEN TerminalCodes.Bold(w, TRUE) END;
		w.Char(" "); Fitted(w, title, width - 6); w.Char(" ");
		IF focused THEN TerminalCodes.Bold(w, FALSE) END
	END;
	TerminalCodes.Plain(w)
END Border;

(* ---- editing a line ---- *)

PROCEDURE Remove (VAR s: ARRAY OF CHAR; at: SIGNED32);
VAR i: SIZE;
BEGIN
	i := at;
	WHILE s[i] # 0X DO s[i] := s[i+1]; INC(i) END
END Remove;

PROCEDURE Insert (VAR s: ARRAY OF CHAR; at: SIGNED32; CONST what: ARRAY OF CHAR): BOOLEAN;
VAR length, added, i: SIZE;
BEGIN
	length := Strings.Length(s); added := Strings.Length(what);
	IF length + added >= LEN(s) THEN RETURN FALSE END;
	FOR i := length TO at BY -1 DO s[i + added] := s[i] END;
	FOR i := 0 TO added-1 DO s[at + i] := what[i] END;
	RETURN TRUE
END Insert;

END Frames.
