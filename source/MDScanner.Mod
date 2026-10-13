MODULE MDScanner; (** AUTHOR "BohdanT"; PURPOSE: Block-level line scanner for a CommonMark subset (no HTML, no reference links) *)

IMPORT Streams, Files, Commands;

CONST
	MaxLine* = 1024;
	TabSize = 4;

	(* token kinds *)
	Blank* = 0; Heading* = 1; Rule* = 2; Fence* = 3; Quote* = 4;
	Bullet* = 5; Ordered* = 6; Indented* = 7; Text* = 8; EOF* = 9;
	Math* = 10;	(* line starting with $$ : opens a display formula *)
	TableSep* = 11;	(* table delimiter row like |---|:--:|--:| ; text = the row, trimmed *)

TYPE
	Token* = RECORD
		kind*: SIGNED32;
		level*: SIGNED32;	(* Heading: 1..6; Fence: fence length *)
		indent*: SIGNED32;	(* leading spaces (tabs already expanded) *)
		num*: SIGNED32;	(* Ordered: start number; Bullet: ORD(marker); Fence: ORD(fence char) *)
		content*: SIGNED32;	(* Bullet/Ordered: column where item content starts *)
		text*: ARRAY MaxLine OF CHAR;	(* line without block markers *)
		raw*: ARRAY MaxLine OF CHAR	(* whole line, tabs expanded; needed inside code fences *)
	END;

PROCEDURE SetEOF(VAR t: Token);
BEGIN
	t.kind := EOF; t.level := 0; t.indent := 0; t.num := 0; t.content := 0;
	t.text[0] := 0X; t.raw[0] := 0X
END SetEOF;

PROCEDURE ExpandTabs(CONST s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
VAR i, j: SIGNED32;
BEGIN
	i := 0; j := 0;
	WHILE (s[i] # 0X) & (j < LEN(d)-1) DO
		IF s[i] = 9X THEN
			REPEAT d[j] := ' '; INC(j) UNTIL (j MOD TabSize = 0) OR (j >= LEN(d)-1)
		ELSE
			d[j] := s[i]; INC(j)
		END;
		INC(i)
	END;
	d[j] := 0X
END ExpandTabs;

PROCEDURE Copy(CONST s: ARRAY OF CHAR; from: SIGNED32; VAR d: ARRAY OF CHAR);
VAR j: SIGNED32;
BEGIN
	j := 0;
	WHILE (s[from] # 0X) & (j < LEN(d)-1) DO d[j] := s[from]; INC(from); INC(j) END;
	d[j] := 0X
END Copy;

PROCEDURE TrimRight(VAR s: ARRAY OF CHAR);
VAR n: SIGNED32;
BEGIN
	n := 0; WHILE s[n] # 0X DO INC(n) END;
	WHILE (n > 0) & (s[n-1] = ' ') DO DEC(n) END;
	s[n] := 0X
END TrimRight;

PROCEDURE Has(CONST s: ARRAY OF CHAR; from: SIGNED32; ch: CHAR): BOOLEAN;
BEGIN
	WHILE s[from] # 0X DO
		IF s[from] = ch THEN RETURN TRUE END;
		INC(from)
	END;
	RETURN FALSE
END Has;

(** thematic break: >= 3 of the same char from {-,*,_}, only spaces between *)
PROCEDURE IsBreak(CONST s: ARRAY OF CHAR; i: SIGNED32): BOOLEAN;
VAR c: CHAR; n: SIGNED32;
BEGIN
	c := s[i]; n := 0;
	IF (c # '-') & (c # '*') & (c # '_') THEN RETURN FALSE END;
	WHILE s[i] # 0X DO
		IF s[i] = c THEN INC(n)
		ELSIF s[i] # ' ' THEN RETURN FALSE
		END;
		INC(i)
	END;
	RETURN n >= 3
END IsBreak;

(** column where list item content starts, given the position right after the marker *)
PROCEDURE ItemContent(CONST s: ARRAY OF CHAR; afterMarker: SIGNED32): SIGNED32;
VAR j: SIGNED32;
BEGIN
	j := afterMarker;
	WHILE s[j] = ' ' DO INC(j) END;
	IF (s[j] = 0X) OR (j - afterMarker > 4) THEN j := afterMarker + 1 END;	(* empty item or code inside *)
	RETURN j
END ItemContent;

(** table delimiter row: only '|', '-', ':' and spaces; at least one '|' and one '-' *)
PROCEDURE IsTableSep(CONST s: ARRAY OF CHAR; i: SIGNED32): BOOLEAN;
VAR pipe, dash: BOOLEAN;
BEGIN
	pipe := FALSE; dash := FALSE;
	WHILE s[i] # 0X DO
		IF s[i] = '|' THEN pipe := TRUE
		ELSIF s[i] = '-' THEN dash := TRUE
		ELSIF (s[i] # ':') & (s[i] # ' ') THEN RETURN FALSE
		END;
		INC(i)
	END;
	RETURN pipe & dash
END IsTableSep;

PROCEDURE Classify*(VAR t: Token);
VAR i, n, j, v: SIGNED32; c: CHAR;
BEGIN
	t.kind := Text; t.level := 0; t.num := 0; t.content := 0; t.text[0] := 0X;
	i := 0; WHILE t.raw[i] = ' ' DO INC(i) END;
	t.indent := i;
	IF t.raw[i] = 0X THEN t.kind := Blank; RETURN END;
	IF i >= 4 THEN t.kind := Indented; Copy(t.raw, 4, t.text); RETURN END;
	c := t.raw[i];

	(* ATX heading *)
	IF c = '#' THEN
		n := 0; j := i;
		WHILE t.raw[j] = '#' DO INC(n); INC(j) END;
		IF (n <= 6) & ((t.raw[j] = 0X) OR (t.raw[j] = ' ')) THEN
			WHILE t.raw[j] = ' ' DO INC(j) END;
			Copy(t.raw, j, t.text); TrimRight(t.text);
			n := 0; WHILE t.text[n] # 0X DO INC(n) END;	(* n = length; strip closing #'s *)
			v := n; WHILE (v > 0) & (t.text[v-1] = '#') DO DEC(v) END;
			IF (v < n) & ((v = 0) OR (t.text[v-1] = ' ')) THEN t.text[v] := 0X; TrimRight(t.text) END;
			t.kind := Heading;
			t.level := 0; j := i; WHILE t.raw[j] = '#' DO INC(t.level); INC(j) END;
			RETURN
		END
	END;

	(* fenced code *)
	IF (c = '`') OR (c = '~') THEN
		n := 0; j := i;
		WHILE t.raw[j] = c DO INC(n); INC(j) END;
		IF (n >= 3) & ~((c = '`') & Has(t.raw, j, '`')) THEN
			WHILE t.raw[j] = ' ' DO INC(j) END;
			Copy(t.raw, j, t.text); TrimRight(t.text);
			t.kind := Fence; t.level := n; t.num := ORD(c);
			RETURN
		END
	END;

	(* display math: "$$" opens a formula block. text = the rest of the line after "$$".
	   The parser closes it at the line whose trimmed end is "$$" (may be the same line)
	   and must take lines inside from t.raw, exactly like a code fence. *)
	IF (c = '$') & (t.raw[i+1] = '$') THEN
		j := i + 2;
		WHILE t.raw[j] = ' ' DO INC(j) END;
		Copy(t.raw, j, t.text); TrimRight(t.text);
		t.kind := Math; t.level := 2;
		RETURN
	END;

	(* block quote *)
	IF c = '>' THEN
		j := i + 1;
		IF t.raw[j] = ' ' THEN INC(j) END;
		Copy(t.raw, j, t.text);
		t.kind := Quote;
		RETURN
	END;

	(* thematic break must be checked before bullets ("- - -", "***") *)
	IF IsBreak(t.raw, i) THEN t.kind := Rule; RETURN END;

	(* table delimiter row; the parser treats a Text line followed by TableSep as a table header *)
	IF IsTableSep(t.raw, i) THEN
		Copy(t.raw, i, t.text); TrimRight(t.text);
		t.kind := TableSep;
		RETURN
	END;

	(* bullet list item *)
	IF ((c = '-') OR (c = '*') OR (c = '+')) & ((t.raw[i+1] = ' ') OR (t.raw[i+1] = 0X)) THEN
		t.content := ItemContent(t.raw, i + 1);
		Copy(t.raw, t.content, t.text); TrimRight(t.text);
		t.kind := Bullet; t.num := ORD(c);
		RETURN
	END;

	(* ordered list item: 1-9 digits, then '.' or ')' *)
	IF (c >= '0') & (c <= '9') THEN
		j := i; v := 0;
		WHILE (t.raw[j] >= '0') & (t.raw[j] <= '9') & (j - i < 9) DO
			v := v * 10 + (ORD(t.raw[j]) - ORD('0')); INC(j)
		END;
		IF ((t.raw[j] = '.') OR (t.raw[j] = ')')) & ((t.raw[j+1] = ' ') OR (t.raw[j+1] = 0X)) THEN
			t.content := ItemContent(t.raw, j + 1);
			Copy(t.raw, t.content, t.text); TrimRight(t.text);
			t.kind := Ordered; t.num := v;
			RETURN
		END
	END;

	(* paragraph text (also setext underline candidates "===" and "---": the parser decides) *)
	Copy(t.raw, i, t.text); TrimRight(t.text)
END Classify;

TYPE
	Scanner* = OBJECT
	VAR
		r: Streams.Reader;
		atEnd: BOOLEAN;

		PROCEDURE &Init*(r: Streams.Reader);
		BEGIN
			SELF.r := r; atEnd := FALSE
		END Init;

		PROCEDURE Next*(VAR t: Token);
		VAR s: ARRAY MaxLine OF CHAR;
		BEGIN
			IF atEnd THEN SetEOF(t); RETURN END;
			r.Ln(s);
			IF (r.res # Streams.Ok) & (s[0] = 0X) THEN
				atEnd := TRUE; SetEOF(t); RETURN
			END;
			IF r.res # Streams.Ok THEN atEnd := TRUE END;	(* last line without line terminator *)
			ExpandTabs(s, t.raw);
			Classify(t)
		END Next;

	END Scanner;

(* ---- test command ---- *)

PROCEDURE KindName(k: SIGNED32; VAR name: ARRAY OF CHAR);
BEGIN
	CASE k OF
		Blank: COPY("Blank", name)
		|Heading: COPY("Heading", name)
		|Rule: COPY("Rule", name)
		|Fence: COPY("Fence", name)
		|Quote: COPY("Quote", name)
		|Bullet: COPY("Bullet", name)
		|Ordered: COPY("Ordered", name)
		|Indented: COPY("Indented", name)
		|Text: COPY("Text", name)
		|EOF: COPY("EOF", name)
		|Math: COPY("Math", name)
		|TableSep: COPY("TableSep", name)
	ELSE COPY("?", name)
	END
END KindName;

(** MDScanner.Test file.md ~  -- prints the block tokens of a file *)
PROCEDURE Test*(context: Commands.Context);
VAR
	name: ARRAY 256 OF CHAR;
	kn: ARRAY 16 OF CHAR;
	f: Files.File;
	fr: Files.Reader;
	sc: Scanner;
	t: Token;
BEGIN
	IF context.arg.GetString(name) THEN
		f := Files.Old(name);
		IF f # NIL THEN
			Files.OpenReader(fr, f, 0);
			NEW(sc, fr);
			REPEAT
				sc.Next(t);
				KindName(t.kind, kn);
				context.out.String(kn);
				context.out.String(" lvl="); context.out.Int(t.level, 0);
				context.out.String(" ind="); context.out.Int(t.indent, 0);
				context.out.String(" num="); context.out.Int(t.num, 0);
				context.out.String(" | "); context.out.String(t.text);
				context.out.Ln
			UNTIL t.kind = EOF
		ELSE
			context.error.String("file not found: "); context.error.String(name); context.error.Ln
		END
	ELSE
		context.error.String("usage: MDScanner.Test file.md ~"); context.error.Ln
	END;
	context.out.Update; context.error.Update
END Test;

END MDScanner.
