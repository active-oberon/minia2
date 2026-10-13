MODULE MDParser; (** AUTHOR "BohdanT"; PURPOSE: Block-level parser of MD2AO: lines -> MDTree. Inline parsing is the next step (ParseInline is a placeholder) *)

IMPORT Streams, Files, Commands, MDScanner, MDTree, MDInline;

(*
	Method: the whole input is read into memory as lines (tabs already expanded by MDScanner).
	ParseLines classifies line after line with MDScanner.Classify and builds blocks. Container blocks
	(quote, list item) collect their own lines with the container markers removed and parse them
	recursively, so nesting needs no special cases.

	Known simplifications (on purpose, to keep the project light):
	- a list is "loose" if there is a blank line between its items or inside one of its items;
	- '.' and ')' ordered markers are not told apart, and bullet markers '-', '*', '+' are;
	- lazy continuation lines are supported for paragraphs in quotes and list items;
	- a table starts only at the first line of a paragraph; rows are Text lines up to the first other line.
*)

TYPE
	StringArray = POINTER TO ARRAY OF MDTree.String;
	IntArray = POINTER TO ARRAY OF SIGNED32;

	(* growable list of strings *)
	Lines = OBJECT
	VAR
		a: StringArray;
		n: SIGNED32;

		PROCEDURE &Init*;
		BEGIN
			NEW(a, 32); n := 0
		END Init;

		PROCEDURE Add(CONST s: ARRAY OF CHAR);
		VAR b: StringArray; i: SIGNED32;
		BEGIN
			IF n = LEN(a) THEN
				NEW(b, 2 * LEN(a));
				FOR i := 0 TO n - 1 DO b[i] := a[i] END;
				a := b
			END;
			a[n] := MDTree.NewString(s); INC(n)
		END Add;

	END Lines;

(* ---- small string helpers ---- *)

(* d := s from column 'from' on (empty if s is shorter) *)
PROCEDURE Tail(CONST s: ARRAY OF CHAR; from: SIGNED32; VAR d: ARRAY OF CHAR);
VAR n, j: SIGNED32;
BEGIN
	n := 0;
	WHILE (n < from) & (s[n] # 0X) DO INC(n) END;
	j := 0;
	IF n = from THEN
		WHILE (s[n] # 0X) & (j < LEN(d) - 1) DO d[j] := s[n]; INC(n); INC(j) END
	END;
	d[j] := 0X
END Tail;

(* d := s without up to n leading spaces *)
PROCEDURE StripCols(CONST s: ARRAY OF CHAR; n: SIGNED32; VAR d: ARRAY OF CHAR);
VAR i: SIGNED32;
BEGIN
	i := 0;
	WHILE (i < n) & (s[i] = ' ') DO INC(i) END;
	Tail(s, i, d)
END StripCols;

(* removes leading and trailing spaces *)
PROCEDURE Trim(VAR s: ARRAY OF CHAR);
VAR i, j: SIGNED32;
BEGIN
	i := 0; WHILE s[i] = ' ' DO INC(i) END;
	j := 0; WHILE s[i] # 0X DO s[j] := s[i]; INC(i); INC(j) END;
	WHILE (j > 0) & (s[j-1] = ' ') DO DEC(j) END;
	s[j] := 0X
END Trim;

(* removes trailing spaces and LFs of a tree string, in place *)
PROCEDURE TrimEnd(s: MDTree.String);
VAR n: SIGNED32;
BEGIN
	n := 0; WHILE s[n] # 0X DO INC(n) END;
	WHILE (n > 0) & ((s[n-1] = ' ') OR (s[n-1] = 0AX)) DO DEC(n) END;
	s[n] := 0X
END TrimEnd;

(* ---- line classification ---- *)

PROCEDURE Load(src: Lines; i: SIGNED32; VAR t: MDScanner.Token);
BEGIN
	COPY(src.a[i]^, t.raw);
	MDScanner.Classify(t)
END Load;

(* a non-blank line that is plain paragraph text *)
PROCEDURE IsParaLine(CONST s: ARRAY OF CHAR): BOOLEAN;
VAR t: MDScanner.Token;
BEGIN
	COPY(s, t.raw);
	MDScanner.Classify(t);
	RETURN t.kind = MDScanner.Text
END IsParaLine;

(* 1 for "====", 2 for "----" (setext underline), 0 otherwise *)
PROCEDURE SetextLevel(CONST s: ARRAY OF CHAR; indent: SIGNED32): SIGNED32;
VAR i: SIGNED32; c: CHAR;
BEGIN
	IF indent >= 4 THEN RETURN 0 END;
	i := indent; c := s[i];
	IF (c # '=') & (c # '-') THEN RETURN 0 END;
	WHILE s[i] = c DO INC(i) END;
	WHILE s[i] = ' ' DO INC(i) END;
	IF s[i] # 0X THEN RETURN 0 END;
	IF c = '=' THEN RETURN 1 ELSE RETURN 2 END
END SetextLevel;

(* does this line end the paragraph that is being collected? *)
PROCEDURE EndsParagraph(CONST u: MDScanner.Token): BOOLEAN;
VAR r: BOOLEAN;
BEGIN
	r := FALSE;
	CASE u.kind OF
		MDScanner.Blank, MDScanner.Heading, MDScanner.Rule, MDScanner.Fence,
		MDScanner.Quote, MDScanner.Math: r := TRUE
		|MDScanner.Bullet: r := u.text[0] # 0X
		|MDScanner.Ordered: r := (u.num = 1) & (u.text[0] # 0X)
	ELSE
	END;
	RETURN r
END EndsParagraph;

(* if the line ends with "$$": cuts it off (and trailing spaces) and returns TRUE *)
PROCEDURE CloseMath(VAR s: ARRAY OF CHAR): BOOLEAN;
VAR n: SIGNED32;
BEGIN
	n := 0; WHILE s[n] # 0X DO INC(n) END;
	WHILE (n > 0) & (s[n-1] = ' ') DO DEC(n) END;
	s[n] := 0X;
	IF (n >= 2) & (s[n-1] = '$') & (s[n-2] = '$') THEN
		DEC(n, 2);
		WHILE (n > 0) & (s[n-1] = ' ') DO DEC(n) END;
		s[n] := 0X;
		RETURN TRUE
	END;
	RETURN FALSE
END CloseMath;

(* ---- tables ---- *)

(* delimiter cell ":---:" -> alignment, -1 if it is not a delimiter cell *)
PROCEDURE CellAlign(CONST s: ARRAY OF CHAR): SIGNED32;
VAR i, n: SIGNED32; l, r: BOOLEAN;
BEGIN
	i := 0; l := FALSE; r := FALSE;
	IF s[0] = ':' THEN l := TRUE; INC(i) END;
	n := 0; WHILE s[i] = '-' DO INC(i); INC(n) END;
	IF n = 0 THEN RETURN -1 END;
	IF s[i] = ':' THEN r := TRUE; INC(i) END;
	IF s[i] # 0X THEN RETURN -1 END;
	IF l & r THEN RETURN MDTree.AlignCenter
	ELSIF l THEN RETURN MDTree.AlignLeft
	ELSIF r THEN RETURN MDTree.AlignRight
	ELSE RETURN MDTree.AlignNone
	END
END CellAlign;

(* splits "| a | b \| c |" into the trimmed cells "a", "b | c"; the outer pipes are optional *)
PROCEDURE SplitRow(CONST s: ARRAY OF CHAR; cells: Lines);
VAR i, j, k: SIGNED32; c: ARRAY MDScanner.MaxLine OF CHAR; closed: BOOLEAN;
BEGIN
	i := 0; WHILE s[i] = ' ' DO INC(i) END;
	IF s[i] = '|' THEN INC(i) END;
	j := 0; closed := FALSE;
	WHILE s[i] # 0X DO
		IF (s[i] = '\') & (s[i+1] = '|') THEN
			c[j] := '|'; INC(j); INC(i, 2)
		ELSIF s[i] = '|' THEN
			c[j] := 0X; Trim(c); cells.Add(c); j := 0; INC(i);
			k := i; WHILE s[k] = ' ' DO INC(k) END;
			IF s[k] = 0X THEN i := k; closed := TRUE END	(* trailing pipe: no more cells *)
		ELSE
			c[j] := s[i]; INC(j); INC(i)
		END
	END;
	IF ~closed THEN c[j] := 0X; Trim(c); cells.Add(c) END
END SplitRow;

(* ---- inline stage ---- *)

PROCEDURE ParseInline(parent: MDTree.Node; CONST s: ARRAY OF CHAR);
BEGIN
	MDInline.Parse(parent, s)
END ParseInline;

(* ---- blocks ---- *)

PROCEDURE AddRow(tbl: MDTree.Node; cells: Lines; al: IntArray; header: BOOLEAN);
VAR row, cell: MDTree.Node; k: SIGNED32;
BEGIN
	row := MDTree.NewNode(MDTree.Row); row.header := header; MDTree.Append(tbl, row);
	FOR k := 0 TO SIGNED32(LEN(al)) - 1 DO
		cell := MDTree.NewNode(MDTree.Cell); cell.align := al[k]; MDTree.Append(row, cell);
		IF k < cells.n THEN ParseInline(cell, cells.a[k]^) END
	END
END AddRow;

(* line i is a header row and line i+1 a delimiter row with the same number of cells *)
PROCEDURE IsTableStart(src: Lines; i: SIGNED32): BOOLEAN;
VAR u: MDScanner.Token; hc, dc: Lines; k: SIGNED32; ok: BOOLEAN;
BEGIN
	IF i + 1 >= src.n THEN RETURN FALSE END;
	Load(src, i + 1, u);
	IF u.kind # MDScanner.TableSep THEN RETURN FALSE END;
	NEW(hc); SplitRow(src.a[i]^, hc);
	NEW(dc); SplitRow(src.a[i + 1]^, dc);
	ok := hc.n = dc.n;
	k := 0;
	WHILE ok & (k < dc.n) DO
		IF CellAlign(dc.a[k]^) < 0 THEN ok := FALSE END;
		INC(k)
	END;
	RETURN ok
END IsTableStart;

PROCEDURE DoTable(parent: MDTree.Node; src: Lines; VAR i: SIGNED32);
VAR tbl: MDTree.Node; hc, dc, rc: Lines; al: IntArray; k: SIGNED32; u: MDScanner.Token; more: BOOLEAN;
BEGIN
	tbl := MDTree.NewNode(MDTree.Table); MDTree.Append(parent, tbl);
	NEW(hc); SplitRow(src.a[i]^, hc);
	NEW(dc); SplitRow(src.a[i + 1]^, dc);
	NEW(al, dc.n);
	FOR k := 0 TO dc.n - 1 DO al[k] := CellAlign(dc.a[k]^) END;
	AddRow(tbl, hc, al, TRUE);
	INC(i, 2);
	more := TRUE;
	WHILE more & (i < src.n) DO
		Load(src, i, u);
		IF (u.kind = MDScanner.Text) OR (u.kind = MDScanner.TableSep) THEN
			NEW(rc); SplitRow(src.a[i]^, rc); AddRow(tbl, rc, al, FALSE); INC(i)
		ELSE
			more := FALSE
		END
	END
END DoTable;

PROCEDURE DoHeading(root, parent: MDTree.Node; CONST t: MDScanner.Token);
VAR h: MDTree.Node;
BEGIN
	h := MDTree.NewNode(MDTree.Heading); h.level := t.level;
	MDTree.Append(parent, h);	(* attach first: AssignHeadingId needs the heading to be in the tree *)
	ParseInline(h, t.text);
	MDTree.AssignHeadingId(root, h)
END DoHeading;

PROCEDURE DoFence(parent: MDTree.Node; src: Lines; VAR i: SIGNED32);
VAR t, u: MDScanner.Token; cb: MDTree.Node; code: MDTree.String;
	s: ARRAY MDScanner.MaxLine OF CHAR; closed: BOOLEAN;
BEGIN
	Load(src, i, t);
	cb := MDTree.NewNode(MDTree.CodeBlock); MDTree.Append(parent, cb);
	IF t.text[0] # 0X THEN cb.info := MDTree.NewString(t.text) END;
	code := NIL; closed := FALSE;
	INC(i);
	WHILE ~closed & (i < src.n) DO
		Load(src, i, u);
		IF (u.kind = MDScanner.Fence) & (u.num = t.num) & (u.level >= t.level) & (u.text[0] = 0X) THEN
			closed := TRUE
		ELSE
			StripCols(src.a[i]^, t.indent, s); MDTree.AddLine(code, s)
		END;
		INC(i)
	END;
	IF code = NIL THEN code := MDTree.NewString("") END;
	cb.text := code
END DoFence;

PROCEDURE DoMath(parent: MDTree.Node; src: Lines; VAR i: SIGNED32);
VAR t: MDScanner.Token; m: MDTree.Node; text: MDTree.String;
	s: ARRAY MDScanner.MaxLine OF CHAR; done: BOOLEAN;
BEGIN
	Load(src, i, t);
	m := MDTree.NewNode(MDTree.MathBlock); MDTree.Append(parent, m);
	text := NIL;
	COPY(t.text, s);
	done := CloseMath(s);
	IF s[0] # 0X THEN MDTree.AddLine(text, s) END;
	INC(i);
	WHILE ~done & (i < src.n) DO
		COPY(src.a[i]^, s);
		done := CloseMath(s);
		IF ~done OR (s[0] # 0X) THEN MDTree.AddLine(text, s) END;
		INC(i)
	END;
	IF text = NIL THEN text := MDTree.NewString("") END;
	m.text := text
END DoMath;

PROCEDURE DoIndented(parent: MDTree.Node; src: Lines; VAR i: SIGNED32);
VAR t: MDScanner.Token; cb: MDTree.Node; code: MDTree.String; blanks, j: SIGNED32; more: BOOLEAN;
BEGIN
	cb := MDTree.NewNode(MDTree.CodeBlock); MDTree.Append(parent, cb);
	code := NIL; blanks := 0; more := TRUE;
	WHILE more & (i < src.n) DO
		Load(src, i, t);
		IF t.kind = MDScanner.Indented THEN
			FOR j := 1 TO blanks DO MDTree.AddLine(code, "") END;
			blanks := 0;
			MDTree.AddLine(code, t.text); INC(i)
		ELSIF t.kind = MDScanner.Blank THEN
			INC(blanks); INC(i)	(* blank lines count only if more code follows *)
		ELSE
			more := FALSE
		END
	END;
	IF code = NIL THEN code := MDTree.NewString("") END;
	cb.text := code
END DoIndented;

PROCEDURE DoParagraph(root, parent: MDTree.Node; src: Lines; VAR i: SIGNED32);
VAR t, u: MDScanner.Token; text: MDTree.String; s: ARRAY MDScanner.MaxLine OF CHAR;
	more: BOOLEAN; setext: SIGNED32; n: MDTree.Node;
BEGIN
	Load(src, i, t);
	text := NIL;
	Tail(src.a[i]^, t.indent, s); MDTree.AddLine(text, s);	(* trailing spaces stay: hard line break *)
	INC(i);
	setext := 0; more := TRUE;
	WHILE more & (i < src.n) DO
		Load(src, i, u);
		setext := SetextLevel(src.a[i]^, u.indent);
		IF setext > 0 THEN
			INC(i); more := FALSE
		ELSIF EndsParagraph(u) THEN
			more := FALSE
		ELSE
			Tail(src.a[i]^, u.indent, s); MDTree.AddLine(text, s); INC(i)
		END
	END;
	TrimEnd(text);
	IF setext > 0 THEN
		n := MDTree.NewNode(MDTree.Heading); n.level := setext;
		MDTree.Append(parent, n);
		ParseInline(n, text^);
		MDTree.AssignHeadingId(root, n)
	ELSE
		n := MDTree.NewNode(MDTree.Paragraph); MDTree.Append(parent, n);
		ParseInline(n, text^)
	END
END DoParagraph;

PROCEDURE DoQuote(root, parent: MDTree.Node; src: Lines; VAR i: SIGNED32);
VAR q: MDTree.Node; sub: Lines; t: MDScanner.Token;
	s: ARRAY MDScanner.MaxLine OF CHAR; more, lastText: BOOLEAN;
BEGIN
	q := MDTree.NewNode(MDTree.Quote); MDTree.Append(parent, q);
	NEW(sub);
	more := TRUE; lastText := FALSE;
	WHILE more & (i < src.n) DO
		Load(src, i, t);
		IF t.kind = MDScanner.Quote THEN
			sub.Add(t.text); lastText := IsParaLine(t.text); INC(i)
		ELSIF lastText & (t.kind = MDScanner.Text) THEN
			Tail(src.a[i]^, t.indent, s); sub.Add(s); INC(i)	(* lazy continuation *)
		ELSE
			more := FALSE
		END
	END;
	ParseLines(root, q, sub)
END DoQuote;

PROCEDURE DoList(root, parent: MDTree.Node; src: Lines; VAR i: SIGNED32);
VAR
	list, item: MDTree.Node; sub: Lines; t, u: MDScanner.Token;
	s: ARRAY MDScanner.MaxLine OF CHAR;
	fk, fn, c, blanks, j: SIGNED32;
	more, ended, blankInside, lastText: BOOLEAN;
BEGIN
	Load(src, i, t);
	fk := t.kind; fn := t.num;	(* the kind and marker of the first item decide which lines are siblings *)
	IF fk = MDScanner.Bullet THEN
		list := MDTree.NewNode(MDTree.BulletList)
	ELSE
		list := MDTree.NewNode(MDTree.OrderedList); list.start := t.num
	END;
	MDTree.Append(parent, list);
	more := TRUE;
	WHILE more DO
		(* here: t = marker line of the next item = src line i *)
		c := t.content;
		NEW(sub);
		Tail(src.a[i]^, c, s); sub.Add(s);
		lastText := IsParaLine(s);
		INC(i);
		blanks := 0; ended := FALSE; blankInside := FALSE;
		WHILE ~ended & (i < src.n) DO
			Load(src, i, u);
			IF u.kind = MDScanner.Blank THEN
				INC(blanks); INC(i)
			ELSIF u.indent >= c THEN
				FOR j := 1 TO blanks DO sub.Add("") END;
				IF blanks > 0 THEN blankInside := TRUE END;
				blanks := 0;
				StripCols(src.a[i]^, c, s); sub.Add(s);
				lastText := IsParaLine(s);
				INC(i)
			ELSIF (blanks = 0) & lastText & (u.kind = MDScanner.Text) THEN
				Tail(src.a[i]^, u.indent, s); sub.Add(s); INC(i)	(* lazy continuation *)
			ELSE
				ended := TRUE
			END
		END;
		item := MDTree.NewNode(MDTree.Item); MDTree.Append(list, item);
		ParseLines(root, item, sub);
		IF blankInside THEN list.tight := FALSE END;
		(* does the list go on with another item? *)
		more := FALSE;
		IF i < src.n THEN
			Load(src, i, t);
			IF (t.kind = fk) & ((fk = MDScanner.Ordered) OR (t.num = fn)) THEN
				more := TRUE;
				IF blanks > 0 THEN list.tight := FALSE END
			END
		END
	END
END DoList;

PROCEDURE ParseLines(root, parent: MDTree.Node; src: Lines);
VAR i: SIGNED32; t: MDScanner.Token;
BEGIN
	i := 0;
	WHILE i < src.n DO
		Load(src, i, t);
		CASE t.kind OF
			MDScanner.Blank: INC(i)
			|MDScanner.Heading: DoHeading(root, parent, t); INC(i)
			|MDScanner.Rule: MDTree.Append(parent, MDTree.NewNode(MDTree.Rule)); INC(i)
			|MDScanner.Fence: DoFence(parent, src, i)
			|MDScanner.Math: DoMath(parent, src, i)
			|MDScanner.Quote: DoQuote(root, parent, src, i)
			|MDScanner.Bullet, MDScanner.Ordered: DoList(root, parent, src, i)
			|MDScanner.Indented: DoIndented(parent, src, i)
			|MDScanner.Text:
				IF IsTableStart(src, i) THEN DoTable(parent, src, i) ELSE DoParagraph(root, parent, src, i) END
		ELSE
			DoParagraph(root, parent, src, i)	(* a delimiter row without a header is plain text *)
		END
	END
END ParseLines;

(** parses a whole document; the result is a Document node *)
PROCEDURE Parse*(r: Streams.Reader): MDTree.Node;
VAR sc: MDScanner.Scanner; t: MDScanner.Token; src: Lines; doc: MDTree.Node;
BEGIN
	NEW(sc, r); NEW(src);
	REPEAT
		sc.Next(t);
		IF t.kind # MDScanner.EOF THEN src.Add(t.raw) END
	UNTIL t.kind = MDScanner.EOF;
	doc := MDTree.NewNode(MDTree.Document);
	ParseLines(doc, doc, src);
	RETURN doc
END Parse;

(** MDParser.Test file.md ~  -- prints the tree of a file *)
PROCEDURE Test*(context: Commands.Context);
VAR name: ARRAY 256 OF CHAR; f: Files.File; fr: Files.Reader; doc: MDTree.Node;
BEGIN
	IF context.arg.GetString(name) THEN
		f := Files.Old(name);
		IF f # NIL THEN
			Files.OpenReader(fr, f, 0);
			doc := Parse(fr);
			MDTree.Dump(context.out, doc, 0)
		ELSE
			context.error.String("file not found: "); context.error.String(name); context.error.Ln
		END
	ELSE
		context.error.String("usage: MDParser.Test file.md ~"); context.error.Ln
	END;
	context.out.Update; context.error.Update
END Test;

END MDParser.
