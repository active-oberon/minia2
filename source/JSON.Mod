MODULE JSON;
(**
	AUTHOR "minia2 SDK";
	PURPOSE "RFC 8259 JSON parser and serializer for Active Oberon";
	LIMITATIONS
		"- \uXXXX escapes are decoded to UTF-8 for the Basic Multilingual Plane only
		   (surrogate pairs are not combined);
		 - numbers are represented as FLOAT64;
		 - duplicate object keys: the last one wins."
*)

IMPORT Streams, Strings;

TYPE
	(** Abstract JSON value. Concrete kinds are the extensions below;
		dispatch on them with a type guard (WITH v: Object DO ...). *)
	Value* = OBJECT
	END Value;

	Null* = OBJECT (Value)
	END Null;

	Bool* = OBJECT (Value)
	VAR value*: BOOLEAN;
	END Bool;

	Number* = OBJECT (Value)
	VAR value*: FLOAT64;
	END Number;

	String* = OBJECT (Value)
	VAR value*: Strings.String;
	END String;

	Item* = OBJECT
	VAR next-: Item; value-: Value;
	END Item;

	Array* = OBJECT (Value)
	VAR items-: Item; tail: Item; length-: SIZE;

		PROCEDURE Add* (v: Value);
		VAR it: Item;
		BEGIN
			NEW(it); it.value := v; it.next := NIL;
			IF tail = NIL THEN items := it ELSE tail.next := it END;
			tail := it; INC(length)
		END Add;

		(** 0-based index; NIL if out of range. *)
		PROCEDURE At* (i: SIZE): Value;
		VAR it: Item;
		BEGIN
			(* a negative index would otherwise fall straight through the loop below and
				hand back the first element *)
			IF (i < 0) OR (i >= length) THEN RETURN NIL END;
			it := items;
			WHILE (it # NIL) & (i > 0) DO it := it.next; DEC(i) END;
			IF it = NIL THEN RETURN NIL ELSE RETURN it.value END
		END At;
	END Array;

	Member* = OBJECT
	VAR next-: Member; key-: Strings.String; value-: Value;
	END Member;

	Object* = OBJECT (Value)
	VAR members-: Member; tail: Member; size-: SIZE;

		PROCEDURE Set* (CONST key: ARRAY OF CHAR; v: Value);
		VAR m: Member;
		BEGIN
			m := members;
			WHILE m # NIL DO
				IF m.key^ = key THEN m.value := v; RETURN END;
				m := m.next
			END;
			NEW(m); m.key := Strings.NewString(key); m.value := v; m.next := NIL;
			IF tail = NIL THEN members := m ELSE tail.next := m END;
			tail := m; INC(size)
		END Set;

		(** Value for key, or NIL if absent. *)
		PROCEDURE Get* (CONST key: ARRAY OF CHAR): Value;
		VAR m: Member;
		BEGIN
			m := members;
			WHILE m # NIL DO
				IF m.key^ = key THEN RETURN m.value END;
				m := m.next
			END;
			RETURN NIL
		END Get;
	END Object;

	Parser* = OBJECT
	VAR
		r: Streams.Reader;
		ch: CHAR;
		atEnd: BOOLEAN;
		error*: BOOLEAN;
		errorMsg*: ARRAY 128 OF CHAR;

		PROCEDURE &Init* (reader: Streams.Reader);
		BEGIN
			r := reader; error := FALSE; errorMsg := ""; Advance
		END Init;

		PROCEDURE Advance;
		BEGIN
			ch := r.Get(); atEnd := (r.res # Streams.Ok)
		END Advance;

		PROCEDURE Fail (CONST msg: ARRAY OF CHAR);
		BEGIN
			IF ~error THEN error := TRUE; COPY(msg, errorMsg) END
		END Fail;

		PROCEDURE SkipWS;
		BEGIN
			WHILE ~atEnd & ((ch = " ") OR (ch = 09X) OR (ch = 0DX) OR (ch = 0AX)) DO Advance END
		END SkipWS;

		PROCEDURE Match (CONST word: ARRAY OF CHAR): BOOLEAN;
		VAR i: SIZE;
		BEGIN
			i := 0;
			WHILE word[i] # 0X DO
				IF atEnd OR (ch # word[i]) THEN RETURN FALSE END;
				Advance; INC(i)
			END;
			RETURN TRUE
		END Match;

		PROCEDURE EmitUTF8 (w: Streams.Writer; cp: SIGNED32);
		BEGIN
			IF cp < 80H THEN
				w.Char(CHR(cp))
			ELSIF cp < 800H THEN
				w.Char(CHR(0C0H + cp DIV 40H)); w.Char(CHR(80H + cp MOD 40H))
			ELSE
				w.Char(CHR(0E0H + cp DIV 1000H));
				w.Char(CHR(80H + (cp DIV 40H) MOD 40H));
				w.Char(CHR(80H + cp MOD 40H))
			END
		END EmitUTF8;

		PROCEDURE Unicode (w: Streams.Writer);
		VAR cp, d, i: SIGNED32;
		BEGIN
			cp := 0; i := 0;
			WHILE i < 4 DO
				Advance;
				IF atEnd OR ~Strings.IsDigit(ch, 16, d) THEN Fail("bad \u escape"); RETURN END;
				cp := cp * 16 + d; INC(i)
			END;
			EmitUTF8(w, cp)
		END Unicode;

		(** Parse a "..." string literal into a fresh Strings.String. *)
		PROCEDURE RawString (): Strings.String;
		VAR buf: Streams.Buffer; w: Streams.Writer;
		BEGIN
			NEW(buf, 64); w := buf.GetWriter();
			Advance; (* opening quote *)
			WHILE ~atEnd & (ch # 22X) DO
				IF ch = 5CX THEN
					Advance;
					IF atEnd THEN Fail("unterminated escape"); RETURN NIL END;
					CASE ch OF
						  22X: w.Char(22X)
						| 5CX: w.Char(5CX)
						| "/": w.Char("/")
						| "b": w.Char(08X)
						| "f": w.Char(0CX)
						| "n": w.Char(0AX)
						| "r": w.Char(0DX)
						| "t": w.Char(09X)
						| "u": Unicode(w); IF error THEN RETURN NIL END
					ELSE
						Fail("invalid escape"); RETURN NIL
					END;
					Advance
				ELSE
					w.Char(ch); Advance
				END
			END;
			IF atEnd THEN Fail("unterminated string"); RETURN NIL END;
			Advance; (* closing quote *)
			w.Update;
			RETURN buf.GetString()
		END RawString;

		PROCEDURE ParseNumber (): Value;
		VAR buf: Streams.Buffer; w: Streams.Writer; s: Strings.String; x: FLOAT64; n: Number;
		BEGIN
			NEW(buf, 32); w := buf.GetWriter();
			IF ch = "-" THEN w.Char(ch); Advance END;
			WHILE ~atEnd & (ch >= "0") & (ch <= "9") DO w.Char(ch); Advance END;
			IF ~atEnd & (ch = ".") THEN
				w.Char(ch); Advance;
				WHILE ~atEnd & (ch >= "0") & (ch <= "9") DO w.Char(ch); Advance END
			END;
			IF ~atEnd & ((ch = "e") OR (ch = "E")) THEN
				w.Char(ch); Advance;
				IF ~atEnd & ((ch = "+") OR (ch = "-")) THEN w.Char(ch); Advance END;
				WHILE ~atEnd & (ch >= "0") & (ch <= "9") DO w.Char(ch); Advance END
			END;
			w.Update; s := buf.GetString();
			Strings.StrToFloat(s^, x);
			NEW(n); n.value := x; RETURN n
		END ParseNumber;

		PROCEDURE ParseArray (): Value;
		VAR a: Array; v: Value;
		BEGIN
			NEW(a); Advance; SkipWS;
			IF ~atEnd & (ch = "]") THEN Advance; RETURN a END;
			LOOP
				v := ParseValue(); IF error THEN RETURN NIL END;
				a.Add(v); SkipWS;
				IF atEnd THEN Fail("unterminated array"); RETURN NIL END;
				IF ch = "," THEN Advance; SkipWS
				ELSIF ch = "]" THEN Advance; EXIT
				ELSE Fail("expected ',' or ']'"); RETURN NIL END
			END;
			RETURN a
		END ParseArray;

		PROCEDURE ParseObject (): Value;
		VAR o: Object; key: Strings.String; v: Value;
		BEGIN
			NEW(o); Advance; SkipWS;
			IF ~atEnd & (ch = "}") THEN Advance; RETURN o END;
			LOOP
				SkipWS;
				IF atEnd OR (ch # 22X) THEN Fail("expected string key"); RETURN NIL END;
				key := RawString(); IF error THEN RETURN NIL END;
				SkipWS;
				IF atEnd OR (ch # ":") THEN Fail("expected ':'"); RETURN NIL END;
				Advance;
				v := ParseValue(); IF error THEN RETURN NIL END;
				o.Set(key^, v); SkipWS;
				IF atEnd THEN Fail("unterminated object"); RETURN NIL END;
				IF ch = "," THEN Advance
				ELSIF ch = "}" THEN Advance; EXIT
				ELSE Fail("expected ',' or '}'"); RETURN NIL END
			END;
			RETURN o
		END ParseObject;

		(** Parse a single JSON value at the current position. *)
		PROCEDURE ParseValue* (): Value;
		VAR s: Strings.String; str: String; b: Bool; nl: Null;
		BEGIN
			SkipWS;
			IF atEnd THEN Fail("unexpected end of input"); RETURN NIL END;
			CASE ch OF
				  "{": RETURN ParseObject()
				| "[": RETURN ParseArray()
				| 22X:
					s := RawString(); IF error THEN RETURN NIL END;
					NEW(str); str.value := s; RETURN str
				| "t":
					IF Match("true") THEN NEW(b); b.value := TRUE; RETURN b
					ELSE Fail("expected 'true'"); RETURN NIL END
				| "f":
					IF Match("false") THEN NEW(b); b.value := FALSE; RETURN b
					ELSE Fail("expected 'false'"); RETURN NIL END
				| "n":
					IF Match("null") THEN NEW(nl); RETURN nl
					ELSE Fail("expected 'null'"); RETURN NIL END
			ELSE
				IF (ch = "-") OR ((ch >= "0") & (ch <= "9")) THEN RETURN ParseNumber()
				ELSE Fail("unexpected character"); RETURN NIL END
			END
		END ParseValue;
	END Parser;

(* ---- serialization helpers (non-recursive, declared before Write) ---- *)

PROCEDURE HexDigit (n: SIGNED32): CHAR;
BEGIN
	IF n < 10 THEN RETURN CHR(ORD("0") + n) ELSE RETURN CHR(ORD("a") + n - 10) END
END HexDigit;

PROCEDURE WriteString (w: Streams.Writer; CONST s: ARRAY OF CHAR);
VAR i: SIZE; c: CHAR;
BEGIN
	w.Char(22X); i := 0;
	WHILE s[i] # 0X DO
		c := s[i];
		CASE c OF
			  22X: w.Char(5CX); w.Char(22X)
			| 5CX: w.Char(5CX); w.Char(5CX)
			| 08X: w.Char(5CX); w.Char("b")
			| 0CX: w.Char(5CX); w.Char("f")
			| 0AX: w.Char(5CX); w.Char("n")
			| 0DX: w.Char(5CX); w.Char("r")
			| 09X: w.Char(5CX); w.Char("t")
		ELSE
			IF c < " " THEN
				w.Char(5CX); w.Char("u"); w.Char("0"); w.Char("0");
				w.Char(HexDigit(ORD(c) DIV 16)); w.Char(HexDigit(ORD(c) MOD 16))
			ELSE
				w.Char(c)
			END
		END;
		INC(i)
	END;
	w.Char(22X)
END WriteString;

PROCEDURE WriteNumber (w: Streams.Writer; x: FLOAT64);
VAR n: SIGNED64;
BEGIN
	IF (ABS(x) < 1.0E15) & (x = FLOAT64(ENTIER(x))) THEN
		n := SIGNED64(ENTIER(x)); w.Int(n, 0)
	ELSE
		w.Float(x, 0)
	END
END WriteNumber;

(** Serialize a value to a writer (compact, no whitespace). *)
PROCEDURE Write* (w: Streams.Writer; v: Value);
VAR it: Item; m: Member; first: BOOLEAN;
BEGIN
	IF v = NIL THEN w.String("null"); RETURN END;
	WITH v:
		  Null DO w.String("null")
		| Bool DO IF v.value THEN w.String("true") ELSE w.String("false") END
		| Number DO WriteNumber(w, v.value)
		| String DO WriteString(w, v.value^)
		| Array DO
			w.Char("["); first := TRUE; it := v.items;
			WHILE it # NIL DO
				IF ~first THEN w.Char(",") END;
				Write(w, it.value); first := FALSE; it := it.next
			END;
			w.Char("]")
		| Object DO
			w.Char("{"); first := TRUE; m := v.members;
			WHILE m # NIL DO
				IF ~first THEN w.Char(",") END;
				WriteString(w, m.key^); w.Char(":"); Write(w, m.value);
				first := FALSE; m := m.next
			END;
			w.Char("}")
	ELSE
		w.String("null")
	END
END Write;

(** Serialize a value to a fresh string. *)
PROCEDURE ToString* (v: Value): Strings.String;
VAR buf: Streams.Buffer; w: Streams.Writer;
BEGIN
	NEW(buf, 128); w := buf.GetWriter();
	Write(w, v); w.Update;
	RETURN buf.GetString()
END ToString;

(** Parse from a reader. Returns TRUE on success; on failure `v` may be partial. *)
PROCEDURE ParseStream* (r: Streams.Reader; VAR v: Value): BOOLEAN;
VAR p: Parser;
BEGIN
	NEW(p, r); v := p.ParseValue(); RETURN ~p.error
END ParseStream;

(** Parse from an in-memory string. *)
PROCEDURE Parse* (CONST text: ARRAY OF CHAR; VAR v: Value): BOOLEAN;
VAR sr: Streams.StringReader;
BEGIN
	NEW(sr, Strings.Length(text) + 1);
	Streams.OpenStringReader(sr, text);
	RETURN ParseStream(sr, v)
END Parse;

(* ---- constructors ---- *)

PROCEDURE NewNull* (): Null;
VAR x: Null;
BEGIN NEW(x); RETURN x END NewNull;

PROCEDURE NewBool* (b: BOOLEAN): Bool;
VAR x: Bool;
BEGIN NEW(x); x.value := b; RETURN x END NewBool;

PROCEDURE NewNumber* (n: FLOAT64): Number;
VAR x: Number;
BEGIN NEW(x); x.value := n; RETURN x END NewNumber;

PROCEDURE NewString* (CONST s: ARRAY OF CHAR): String;
VAR x: String;
BEGIN NEW(x); x.value := Strings.NewString(s); RETURN x END NewString;

PROCEDURE NewArray* (): Array;
VAR x: Array;
BEGIN NEW(x); RETURN x END NewArray;

PROCEDURE NewObject* (): Object;
VAR x: Object;
BEGIN NEW(x); RETURN x END NewObject;

(* --- reading a value out of an object ---------------------------------------------------
	Every caller wrote these: LSP.Mod had GetStr, GetInt and AsObject, sdk/Ob.Mod had JsonText and
	the same `IS JSON.Object` dance around it. A member is absent, or null, or of another type than
	the reader hoped -- that is three answers to distinguish and one line to write, so it belongs
	here rather than in each reader. NIL objects are allowed through: reading a field of something
	that was not there is the common case, not an error. *)

PROCEDURE AsObject* (v: Value): Object;
BEGIN
	IF (v # NIL) & (v IS Object) THEN RETURN v(Object) ELSE RETURN NIL END
END AsObject;

PROCEDURE AsArray* (v: Value): Array;
BEGIN
	IF (v # NIL) & (v IS Array) THEN RETURN v(Array) ELSE RETURN NIL END
END AsArray;

PROCEDURE GetObject* (o: Object; CONST key: ARRAY OF CHAR): Object;
BEGIN
	IF o = NIL THEN RETURN NIL ELSE RETURN AsObject(o.Get(key)) END
END GetObject;

PROCEDURE GetArray* (o: Object; CONST key: ARRAY OF CHAR): Array;
BEGIN
	IF o = NIL THEN RETURN NIL ELSE RETURN AsArray(o.Get(key)) END
END GetArray;

(** The string itself, shared -- do not modify what comes back. *)
PROCEDURE GetString* (o: Object; CONST key: ARRAY OF CHAR; VAR s: Strings.String): BOOLEAN;
VAR v: Value;
BEGIN
	IF o = NIL THEN RETURN FALSE END;
	v := o.Get(key);
	IF (v # NIL) & (v IS String) THEN s := v(String).value; RETURN TRUE END;
	RETURN FALSE
END GetString;

(** A copy, for a caller that has a buffer rather than a pointer. *)
PROCEDURE GetText* (o: Object; CONST key: ARRAY OF CHAR; VAR text: ARRAY OF CHAR): BOOLEAN;
VAR s: Strings.String;
BEGIN
	IF ~GetString(o, key, s) THEN RETURN FALSE END;
	COPY(s^, text); RETURN TRUE
END GetText;

(** JSON has one number type; this is the integer a caller expects to find there. *)
PROCEDURE GetInteger* (o: Object; CONST key: ARRAY OF CHAR; VAR n: SIGNED32): BOOLEAN;
VAR v: Value;
BEGIN
	IF o = NIL THEN RETURN FALSE END;
	v := o.Get(key);
	IF (v # NIL) & (v IS Number) THEN n := SIGNED32(ENTIER(v(Number).value)); RETURN TRUE END;
	RETURN FALSE
END GetInteger;

(* --- Content-Length framing ---------------------------------------------------------------
	Every JSON-RPC server over a pipe frames its messages this way: LSP does, DAP does, and both
	are spoken by this SDK. The frame is not JSON, but it is where JSON begins and ends on a
	stream, and one copy of it is better than one per protocol. *)

CONST CR = 0DX; LF = 0AX;

(** WriteFrame sends one message, header and body, and flushes it. *)
PROCEDURE WriteFrame* (w: Streams.Writer; v: Value);
VAR body: Strings.String;
BEGIN
	body := ToString(v);
	w.String("Content-Length: "); w.Int(Strings.Length(body^), 0);
	w.Char(CR); w.Char(LF); w.Char(CR); w.Char(LF);
	w.String(body^); w.Update
END WriteFrame;

PROCEDURE ContentLength (CONST line: ARRAY OF CHAR): SIGNED32;
CONST prefix = "Content-Length:";
VAR i, j: SIZE; n: SIGNED32;
BEGIN
	i := 0;
	WHILE (prefix[i] # 0X) & (line[i] = prefix[i]) DO INC(i) END;
	IF prefix[i] # 0X THEN RETURN -1 END;
	WHILE (line[i] = " ") DO INC(i) END;
	n := 0; j := i;
	WHILE (line[j] >= "0") & (line[j] <= "9") DO n := n * 10 + (ORD(line[j]) - ORD("0")); INC(j) END;
	RETURN n
END ContentLength;

(**	ReadFrame reads one framed message. `alive` says whether the stream is still usable: it is
	FALSE only for end of input or a header we cannot make sense of, and TRUE with a NIL result
	for a message whose body is not JSON -- the frame gave its length, so exactly that many bytes
	were consumed and the next message is still where it should be. One bad message from an
	editor is not a reason to drop the session. *)
PROCEDURE ReadFrame* (in: Streams.Reader; VAR alive: BOOLEAN): Value;
VAR line: ARRAY 256 OF CHAR; n, got: SIGNED32; len: SIZE;
	buf: POINTER TO ARRAY OF CHAR; v: Value;
BEGIN
	alive := FALSE; n := -1;
	LOOP
		in.Ln(line);
		IF (line[0] = 0X) THEN
			IF in.res # Streams.Ok THEN RETURN NIL END;   (* EOF on the blank/again *)
			EXIT   (* blank line ends the header block *)
		END;
		IF ContentLength(line) >= 0 THEN n := ContentLength(line) END
	END;
	IF n < 0 THEN RETURN NIL END;
	NEW(buf, n + 1); got := 0;
	WHILE got < n DO
		in.Bytes(buf^, got, n - got, len);
		IF len <= 0 THEN RETURN NIL END;
		got := got + SIGNED32(len)
	END;
	buf[n] := 0X;
	alive := TRUE;                                (* the frame was whole, whatever it held *)
	IF ~Parse(buf^, v) THEN RETURN NIL END;
	RETURN v
END ReadFrame;

END JSON.
