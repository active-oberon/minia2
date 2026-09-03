MODULE Format;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "Messages written as one template with holes, in a language that has no varargs";
	LIMITATIONS
		"- the holes are positional and take no spec: {} and nothing else, because the way a
		   number is written is chosen by the method that fills the hole (Int, Hex, Float),
		   not by a second little language inside the string;
		 - a template is filled once, left to right; there is no going back to a hole."
*)
(*	Every other language spells this printf, and printf needs varargs, which Active Oberon does
	not have and should not grow for this. What it does have is objects, so the template is an
	object and the arguments arrive as calls on it:

		f := Format.To(w, "{} of {} tests failed after {}s");
		f.Int(failed, 0); f.Int(total, 0); f.Float(seconds, 1); f.Done;

	The shape of the message stays in one string -- greppable, translatable, reviewable -- and
	each argument keeps the type the compiler checked. A hole nobody filled is written out as
	{} rather than silently swallowed, and Complete says so. *)

IMPORT Streams;

TYPE
	Formatter* = OBJECT
	VAR
		w: Streams.Writer;
		template: POINTER TO ARRAY OF CHAR;
		pos, len: SIZE;
		holes-: SIGNED32;			(** holes filled so far *)
		extra-: BOOLEAN;			(** TRUE when an argument arrived with no hole left for it *)
		missing-: BOOLEAN;			(** TRUE when Done had to write a hole out because nobody filled it *)
		done: BOOLEAN;

		(*	Not a constructor: StringFormatter extends this one and has to make its stream
			before it can hand it over, and a base constructor cannot be called with different
			arguments than its own. *)
		PROCEDURE Set*(writer: Streams.Writer; CONST t: ARRAY OF CHAR);
		VAR i: SIZE;
		BEGIN
			w := writer;
			len := 0;
			WHILE t[len] # 0X DO INC(len) END;
			NEW(template, len + 1);
			FOR i := 0 TO len DO template[i] := t[i] END;
			pos := 0; holes := 0; extra := FALSE; missing := FALSE; done := FALSE
		END Set;

		(*	Writes the template up to the next hole and leaves the position after it. FALSE when
			there is no hole left, which is what makes an extra argument visible instead of
			appended to the end of the message. *)
		PROCEDURE Hole(): BOOLEAN;
		BEGIN
			WHILE pos < len DO
				IF (template[pos] = "{") & (template[pos + 1] = "{") THEN
					w.Char("{"); INC(pos, 2)
				ELSIF (template[pos] = "}") & (template[pos + 1] = "}") THEN
					w.Char("}"); INC(pos, 2)
				ELSIF (template[pos] = "{") & (template[pos + 1] = "}") THEN
					INC(pos, 2); INC(holes);
					RETURN TRUE
				ELSE
					w.Char(template[pos]); INC(pos)
				END
			END;
			extra := TRUE;
			RETURN FALSE
		END Hole;

		PROCEDURE Str*(CONST s: ARRAY OF CHAR);
		BEGIN
			IF SELF.Hole() THEN w.String(s) END
		END Str;

		PROCEDURE Char*(c: CHAR);
		BEGIN
			IF SELF.Hole() THEN w.Char(c) END
		END Char;

		(** width is the minimum field width, 0 for none -- the same argument Streams.Writer takes. *)
		PROCEDURE Int*(x: SIGNED64; width := 0: INTEGER);
		BEGIN
			IF SELF.Hole() THEN w.Int(x, width) END
		END Int;

		PROCEDURE Hex*(x: SIGNED64; digits := -16: INTEGER);
		BEGIN
			IF SELF.Hole() THEN w.Hex(x, digits) END
		END Hex;

		(** width is what Streams.Writer.Float means by it: the whole field, decimals included. *)
		PROCEDURE Float*(x: FLOAT64; width := 16: INTEGER);
		BEGIN
			IF SELF.Hole() THEN w.Float(x, width) END
		END Float;

		PROCEDURE Bool*(b: BOOLEAN);
		BEGIN
			IF SELF.Hole() THEN
				IF b THEN w.String("true") ELSE w.String("false") END
			END
		END Bool;

		(** The rest of the template, holes and all: a hole nobody filled shows as {}. *)
		PROCEDURE Done*;
		BEGIN
			IF done THEN RETURN END;
			done := TRUE;
			WHILE pos < len DO
				IF ((template[pos] = "{") & (template[pos + 1] = "{"))
					OR ((template[pos] = "}") & (template[pos + 1] = "}")) THEN
					w.Char(template[pos]); INC(pos, 2)
				ELSE
					IF (template[pos] = "{") & (template[pos + 1] = "}") THEN missing := TRUE END;
					w.Char(template[pos]); INC(pos)
				END
			END;
			w.Update
		END Done;

		(** Every hole filled, no argument left over -- ask before trusting the message. *)
		(*	Asked after Done as often as before it, so an unfilled hole is remembered rather
			than read off a position that Done has already run past. *)
		PROCEDURE Complete*(): BOOLEAN;
		VAR i: SIZE;
		BEGIN
			IF extra OR missing THEN RETURN FALSE END;
			i := pos;
			WHILE i < len DO
				IF (template[i] = "{") & (template[i + 1] = "}") THEN RETURN FALSE END;
				INC(i)
			END;
			RETURN TRUE
		END Complete;

	END Formatter;

	(*	A formatter that keeps what it wrote, so a message can be built without a stream in
		hand. Get after Done. *)
	StringFormatter* = OBJECT(Formatter)
	VAR
		buffer: Streams.StringWriter;

		PROCEDURE & InitString*(size: SIZE; CONST t: ARRAY OF CHAR);
		VAR sw: Streams.StringWriter;
		BEGIN
			NEW(sw, size);
			buffer := sw;
			SELF.Set(sw, t)
		END InitString;

		(** The message, truncated if it did not fit the size this was made with. *)
		PROCEDURE Get*(VAR s: ARRAY OF CHAR);
		BEGIN
			SELF.Done;
			buffer.Get(s)
		END Get;

	END StringFormatter;

(** A template written to a stream. *)
PROCEDURE To*(w: Streams.Writer; CONST template: ARRAY OF CHAR): Formatter;
VAR f: Formatter;
BEGIN
	NEW(f); f.Set(w, template);
	RETURN f
END To;

(** A template written into a string of at most size characters. *)
PROCEDURE Into*(size: SIZE; CONST template: ARRAY OF CHAR): StringFormatter;
VAR f: StringFormatter;
BEGIN
	NEW(f, size, template);
	RETURN f
END Into;

END Format.
