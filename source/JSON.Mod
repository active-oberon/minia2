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

END JSON.
