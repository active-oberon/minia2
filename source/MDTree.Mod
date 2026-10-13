MODULE MDTree; (** AUTHOR "BohdanT"; PURPOSE: Document tree of MD2AO: output of MDParser, input of the renderer *)

IMPORT Streams, Commands;

(*
	Tree layout (one Node type, the meaning of the fields depends on kind)

	-- blocks --
	Document        children: blocks
	Heading         level 1..6; id = anchor (see AssignHeadingId); children: inlines
	Paragraph       children: inlines
	Quote           children: blocks
	BulletList      tight; children: Item
	OrderedList     tight, start; children: Item
	Item            children: blocks
	CodeBlock       text = code lines joined with LF; info = text after the opening fence
	MathBlock       text = formula lines joined with LF ($$ ... $$)
	Rule
	Table           children: Row
	Row             header = TRUE for the header row; children: Cell
	Cell            align = Align*; children: inlines

	-- inlines --
	Text, Code, MathInline    text
	Emph, Strong              children: inlines
	Link            dest, title (title may be NIL); children: inlines (links do not nest)
	Image           dest, title; children: inlines = alternative text (take it with PlainText)
	SoftBreak, HardBreak

	Strings are UTF-8 bytes stored in CHAR, exactly as MDScanner delivers them.
*)

CONST
	(* block nodes *)
	Document* = 0; Heading* = 1; Paragraph* = 2; Quote* = 3; BulletList* = 4; OrderedList* = 5;
	Item* = 6; CodeBlock* = 7; MathBlock* = 8; Rule* = 9; Table* = 10; Row* = 11; Cell* = 12;
	(* inline nodes *)
	Text* = 20; Emph* = 21; Strong* = 22; Code* = 23; MathInline* = 24; Link* = 25; Image* = 26;
	SoftBreak* = 27; HardBreak* = 28;

	(* table cell alignment *)
	AlignNone* = 0; AlignLeft* = 1; AlignCenter* = 2; AlignRight* = 3;

	(* kinds of link destination, see LinkKind *)
	LinkAnchor* = 0;	(* #id : heading of the same document *)
	LinkPage* = 1;	(* file.md or file.md#id : another help page, relative to the current one *)
	LinkExternal* = 2;	(* scheme:... : http, https, mailto, ... *)

TYPE
	String* = POINTER TO ARRAY OF CHAR;

	Node* = OBJECT
	VAR
		kind*: SIGNED32;
		parent*, first*, last*, next*, prev*: Node;
		level*: SIGNED32;	(* Heading: 1..6 *)
		start*: SIGNED32;	(* OrderedList: number of the first item *)
		align*: SIGNED32;	(* Cell *)
		tight*: BOOLEAN;	(* lists *)
		header*: BOOLEAN;	(* Row *)
		text*: String;
		dest*, title*: String;	(* Link, Image *)
		info*: String;	(* CodeBlock *)
		id*: String;	(* Heading anchor *)
	END Node;

(* ---- strings ---- *)

PROCEDURE NewString*(CONST s: ARRAY OF CHAR): String;
VAR r: String; n: SIGNED32;
BEGIN
	n := 0; WHILE s[n] # 0X DO INC(n) END;
	NEW(r, n + 1);
	COPY(s, r^);
	RETURN r
END NewString;

(* appends add to s; if sep # 0X and s is not empty (NIL), sep is inserted first *)
PROCEDURE Join(VAR s: String; CONST add: ARRAY OF CHAR; sep: CHAR);
VAR n, m, i, k: SIGNED32; r: String;
BEGIN
	m := 0; WHILE add[m] # 0X DO INC(m) END;
	n := 0; IF s # NIL THEN WHILE s[n] # 0X DO INC(n) END END;
	k := 0; IF (sep # 0X) & (s # NIL) THEN k := 1 END;
	NEW(r, n + k + m + 1);
	FOR i := 0 TO n - 1 DO r[i] := s[i] END;
	IF k = 1 THEN r[n] := sep END;
	FOR i := 0 TO m - 1 DO r[n + k + i] := add[i] END;
	r[n + k + m] := 0X;
	s := r
END Join;

(** s := s + add (s may be NIL) *)
PROCEDURE AddText*(VAR s: String; CONST add: ARRAY OF CHAR);
BEGIN
	Join(s, add, 0X)
END AddText;

(** adds a line: s := s + LF + line; the first line of an empty (NIL) s is added without LF *)
PROCEDURE AddLine*(VAR s: String; CONST line: ARRAY OF CHAR);
BEGIN
	Join(s, line, 0AX)
END AddLine;

(* ---- nodes ---- *)

PROCEDURE NewNode*(kind: SIGNED32): Node;
VAR n: Node;
BEGIN
	NEW(n);
	n.kind := kind; n.level := 0; n.start := 1; n.align := AlignNone;
	n.tight := TRUE; n.header := FALSE;
	RETURN n
END NewNode;

PROCEDURE NewTextNode*(kind: SIGNED32; CONST s: ARRAY OF CHAR): Node;
VAR n: Node;
BEGIN
	n := NewNode(kind); n.text := NewString(s);
	RETURN n
END NewTextNode;

(** adds child as the last child of parent; child must not be in a tree (use Unlink first) *)
PROCEDURE Append*(parent, child: Node);
BEGIN
	child.parent := parent; child.next := NIL; child.prev := parent.last;
	IF parent.last # NIL THEN parent.last.next := child ELSE parent.first := child END;
	parent.last := child
END Append;

(** removes n from its parent (its own children stay with it) *)
PROCEDURE Unlink*(n: Node);
BEGIN
	IF n.parent # NIL THEN
		IF n.prev # NIL THEN n.prev.next := n.next ELSE n.parent.first := n.next END;
		IF n.next # NIL THEN n.next.prev := n.prev ELSE n.parent.last := n.prev END
	END;
	n.parent := NIL; n.prev := NIL; n.next := NIL
END Unlink;

PROCEDURE IsInline*(n: Node): BOOLEAN;
BEGIN
	RETURN n.kind >= Text
END IsInline;

(** appends the plain text of all inline descendants of n to s (no markup, no link destinations) *)
PROCEDURE PlainText*(n: Node; VAR s: String);
VAR c: Node;
BEGIN
	c := n.first;
	WHILE c # NIL DO
		CASE c.kind OF
			Text, Code, MathInline: IF c.text # NIL THEN AddText(s, c.text^) END
			|SoftBreak, HardBreak: AddText(s, " ")
		ELSE
			PlainText(c, s)
		END;
		c := c.next
	END
END PlainText;

(* ---- heading anchors ---- *)

PROCEDURE Skip(CONST s: ARRAY OF CHAR; VAR i: SIGNED32; n: SIGNED32);
BEGIN
	WHILE (n > 0) & (s[i] # 0X) DO INC(i); DEC(n) END
END Skip;

(* UTF-8 pair (a, b) of a Cyrillic capital letter -> the same pair of the lowercase letter *)
PROCEDURE Fold(VAR a, b: CHAR);
VAR v: SIGNED32;
BEGIN
	v := ORD(b);
	IF ORD(a) = 0D0H THEN
		IF (v >= 090H) & (v <= 09FH) THEN b := CHR(v + 32)	(* U+0410..U+041F *)
		ELSIF (v >= 0A0H) & (v <= 0AFH) THEN a := CHR(0D1H); b := CHR(v - 32)	(* U+0420..U+042F *)
		ELSIF (v >= 080H) & (v <= 08FH) THEN a := CHR(0D1H); b := CHR(v + 16)	(* U+0400..U+040F, incl. Є І Ї *)
		END
	ELSIF (ORD(a) = 0D2H) & (v = 090H) THEN
		b := CHR(091H)	(* Ґ -> ґ *)
	END
END Fold;

(** GitHub-style anchor: lowercase, spaces -> '-', letters/digits/'-'/'_' kept, punctuation dropped.
    Cyrillic letters are kept and lowercased (input is UTF-8). *)
PROCEDURE Slugify*(CONST s: ARRAY OF CHAR; VAR slug: ARRAY OF CHAR);
VAR i, j, k, len: SIGNED32; c: CHAR;
BEGIN
	i := 0; j := 0;
	WHILE (s[i] # 0X) & (j < LEN(slug) - 5) DO
		c := s[i];
		IF (c >= 'A') & (c <= 'Z') THEN
			slug[j] := CHR(ORD(c) + 32); INC(j); INC(i)
		ELSIF ((c >= 'a') & (c <= 'z')) OR ((c >= '0') & (c <= '9')) OR (c = '-') OR (c = '_') THEN
			slug[j] := c; INC(j); INC(i)
		ELSIF c = ' ' THEN
			slug[j] := '-'; INC(j); INC(i)
		ELSIF ORD(c) < 128 THEN
			INC(i)	(* other ASCII punctuation is dropped *)
		ELSIF ORD(c) = 0C2H THEN Skip(s, i, 2)	(* Latin-1 symbols: << >> etc. *)
		ELSIF ORD(c) = 0E2H THEN Skip(s, i, 3)	(* general punctuation: dashes, ellipsis, ... *)
		ELSIF ORD(c) >= 0F0H THEN Skip(s, i, 4)	(* emoji and other 4-byte symbols *)
		ELSE
			(* a letter of another script: copy the whole UTF-8 sequence *)
			len := 2; IF ORD(c) >= 0E0H THEN len := 3 END;
			k := 0;
			WHILE (k < len) & (s[i] # 0X) DO slug[j + k] := s[i]; INC(k); INC(i) END;
			IF k = 2 THEN Fold(slug[j], slug[j + 1]) END;
			INC(j, k)
		END
	END;
	slug[j] := 0X
END Slugify;

PROCEDURE IntToStr(v: SIGNED32; VAR s: ARRAY OF CHAR);
VAR digits: ARRAY 12 OF CHAR; n, i: SIGNED32;
BEGIN
	n := 0;
	REPEAT digits[n] := CHR(ORD('0') + v MOD 10); INC(n); v := v DIV 10 UNTIL v = 0;
	i := 0;
	WHILE n > 0 DO DEC(n); s[i] := digits[n]; INC(i) END;
	s[i] := 0X
END IntToStr;

(** the heading of the tree with this anchor, or NIL *)
PROCEDURE FindById*(root: Node; CONST id: ARRAY OF CHAR): Node;
VAR c, r: Node;
BEGIN
	IF (root.kind = Heading) & (root.id # NIL) & (root.id^ = id) THEN RETURN root END;
	c := root.first;
	WHILE c # NIL DO
		r := FindById(c, id);
		IF r # NIL THEN RETURN r END;
		c := c.next
	END;
	RETURN NIL
END FindById;

(** sets h.id from the plain text of h; a repeated anchor gets the suffix -1, -2, ... as on GitHub
    (an empty anchor becomes "section"). Call it when h is already in the tree below root,
    and in document order, so that the first heading keeps the plain anchor. *)
PROCEDURE AssignHeadingId*(root, h: Node);
VAR plain: String; base: ARRAY 200 OF CHAR; id: ARRAY 256 OF CHAR; num: ARRAY 12 OF CHAR;
	suffix, k, j: SIGNED32;
BEGIN
	h.id := NIL;
	plain := NIL; PlainText(h, plain);
	base[0] := 0X;
	IF plain # NIL THEN Slugify(plain^, base) END;
	IF base[0] = 0X THEN COPY("section", base) END;
	COPY(base, id); suffix := 0;
	WHILE FindById(root, id) # NIL DO
		INC(suffix); IntToStr(suffix, num);
		k := 0; WHILE base[k] # 0X DO id[k] := base[k]; INC(k) END;
		id[k] := '-'; INC(k);
		j := 0; WHILE num[j] # 0X DO id[k] := num[j]; INC(k); INC(j) END;
		id[k] := 0X
	END;
	h.id := NewString(id)
END AssignHeadingId;

(* ---- links ---- *)

(** classifies a link destination (see Link* constants). A scheme is 2 or more letters followed by ':',
    so that "C:\file" is a path, not a scheme. *)
PROCEDURE LinkKind*(CONST dest: ARRAY OF CHAR): SIGNED32;
VAR i: SIGNED32; c: CHAR;
BEGIN
	IF dest[0] = '#' THEN RETURN LinkAnchor END;
	i := 0; c := dest[0];
	WHILE ((c >= 'a') & (c <= 'z')) OR ((c >= 'A') & (c <= 'Z')) DO INC(i); c := dest[i] END;
	IF (c = ':') & (i >= 2) THEN RETURN LinkExternal END;
	RETURN LinkPage
END LinkKind;

(** "help.md#usage" -> path = "help.md", frag = "usage"; "#usage" -> path = "", frag = "usage" *)
PROCEDURE SplitDest*(CONST dest: ARRAY OF CHAR; VAR path, frag: ARRAY OF CHAR);
VAR i, j: SIGNED32;
BEGIN
	i := 0;
	WHILE (dest[i] # 0X) & (dest[i] # '#') & (i < LEN(path) - 1) DO path[i] := dest[i]; INC(i) END;
	path[i] := 0X;
	frag[0] := 0X;
	IF dest[i] = '#' THEN
		INC(i); j := 0;
		WHILE (dest[i] # 0X) & (j < LEN(frag) - 1) DO frag[j] := dest[i]; INC(i); INC(j) END;
		frag[j] := 0X
	END
END SplitDest;

(* ---- debugging ---- *)

PROCEDURE KindName(k: SIGNED32; VAR name: ARRAY OF CHAR);
BEGIN
	CASE k OF
		Document: COPY("Document", name)
		|Heading: COPY("Heading", name)
		|Paragraph: COPY("Paragraph", name)
		|Quote: COPY("Quote", name)
		|BulletList: COPY("BulletList", name)
		|OrderedList: COPY("OrderedList", name)
		|Item: COPY("Item", name)
		|CodeBlock: COPY("CodeBlock", name)
		|MathBlock: COPY("MathBlock", name)
		|Rule: COPY("Rule", name)
		|Table: COPY("Table", name)
		|Row: COPY("Row", name)
		|Cell: COPY("Cell", name)
		|Text: COPY("Text", name)
		|Emph: COPY("Emph", name)
		|Strong: COPY("Strong", name)
		|Code: COPY("Code", name)
		|MathInline: COPY("MathInline", name)
		|Link: COPY("Link", name)
		|Image: COPY("Image", name)
		|SoftBreak: COPY("SoftBreak", name)
		|HardBreak: COPY("HardBreak", name)
	ELSE
		COPY("?", name)
	END
END KindName;

(* writes  label="string"  (nothing if s = NIL); LF is shown as \n *)
PROCEDURE WriteStr(w: Streams.Writer; CONST label: ARRAY OF CHAR; s: String);
VAR i: SIGNED32;
BEGIN
	IF s # NIL THEN
		w.String(label); w.String('="');
		i := 0;
		WHILE s[i] # 0X DO
			IF s[i] = 0AX THEN w.String("\n") ELSE w.Char(s[i]) END;
			INC(i)
		END;
		w.Char('"')
	END
END WriteStr;

(** prints the tree, one node per line, indented by depth *)
PROCEDURE Dump*(w: Streams.Writer; n: Node; depth: SIGNED32);
VAR i: SIGNED32; kn: ARRAY 16 OF CHAR; c: Node;
BEGIN
	FOR i := 1 TO depth DO w.String("  ") END;
	KindName(n.kind, kn); w.String(kn);
	CASE n.kind OF
		Heading: w.String(" level="); w.Int(n.level, 0); w.Char(' '); WriteStr(w, "id", n.id)
		|BulletList, OrderedList:
			IF n.kind = OrderedList THEN w.String(" start="); w.Int(n.start, 0) END;
			IF n.tight THEN w.String(" tight") ELSE w.String(" loose") END
		|Row: IF n.header THEN w.String(" header") END
		|Cell: w.String(" align="); w.Int(n.align, 0)
		|CodeBlock: w.Char(' '); WriteStr(w, "info", n.info)
		|Link, Image: w.Char(' '); WriteStr(w, "dest", n.dest); w.Char(' '); WriteStr(w, "title", n.title)
	ELSE
	END;
	IF n.text # NIL THEN w.Char(' '); WriteStr(w, "text", n.text) END;
	w.Ln;
	c := n.first;
	WHILE c # NIL DO Dump(w, c, depth + 1); c := c.next END
END Dump;

(* ---- self-test: MDTree.Test ~  (builds a small tree by hand; no parser needed) ---- *)

PROCEDURE TestHeading(root: Node; level: SIGNED32; CONST text: ARRAY OF CHAR);
VAR h: Node;
BEGIN
	h := NewNode(Heading); h.level := level;
	Append(h, NewTextNode(Text, text));
	Append(root, h);
	AssignHeadingId(root, h)
END TestHeading;

PROCEDURE TestLink(p: Node; CONST dest, label: ARRAY OF CHAR);
VAR l: Node;
BEGIN
	l := NewNode(Link); l.dest := NewString(dest);
	Append(l, NewTextNode(Text, label));
	Append(p, l)
END TestLink;

PROCEDURE Test*(context: Commands.Context);
VAR w: Streams.Writer; doc, p, l: Node; a, e, s: ARRAY 32 OF CHAR;
BEGIN
	w := context.out;
	doc := NewNode(Document);
	TestHeading(doc, 1, "Intro");
	TestHeading(doc, 2, "Hello, World!");
	TestHeading(doc, 2, "Intro");
	p := NewNode(Paragraph); Append(doc, p);
	TestLink(p, "#intro", "see intro");
	TestLink(p, "help.md#usage", "usage");
	TestLink(p, "https://example.org", "site");
	Dump(w, doc, 0);
	w.Ln;
	l := p.first;
	WHILE l # NIL DO
		w.String(l.dest^); w.String(" -> kind "); w.Int(LinkKind(l.dest^), 0); w.Ln;
		l := l.next
	END;
	IF FindById(doc, "intro-1") # NIL THEN w.String("FindById intro-1: found") ELSE w.String("FindById intro-1: NOT FOUND") END;
	w.Ln;
	(* Cyrillic: UTF-8 bytes of "Vstup" in Ukrainian, capital first letter, must become all lowercase *)
	a[0] := 0D0X; a[1] := 092X; a[2] := 0D1X; a[3] := 081X; a[4] := 0D1X;
	a[5] := 082X; a[6] := 0D1X; a[7] := 083X; a[8] := 0D0X; a[9] := 0BFX; a[10] := 0X;
	e[0] := 0D0X; e[1] := 0B2X; e[2] := 0D1X; e[3] := 081X; e[4] := 0D1X;
	e[5] := 082X; e[6] := 0D1X; e[7] := 083X; e[8] := 0D0X; e[9] := 0BFX; e[10] := 0X;
	Slugify(a, s);
	IF s = e THEN w.String("Cyrillic slug: OK") ELSE w.String("Cyrillic slug: FAIL") END;
	w.Ln;
	w.Update
END Test;

END MDTree.
