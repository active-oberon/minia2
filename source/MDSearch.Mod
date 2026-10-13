MODULE MDSearch; (** AUTHOR "BohdanT"; PURPOSE:  case-insensitive search in a text and in all pages of a help source *)

IMPORT Streams, MDTree, MDParser, MDSource;

(*
	Lower and IndexOf work on UTF-8 text; Latin and Cyrillic letters are folded to lower case, and the lower
	case copy has the same length in bytes as the original, so a position found in the copy is a position in the
	original text.

	Run searches every page of a source and gives the result back as a document (headings, lists, links), which
	the viewer shows like any other page. A source that can list its pages (a ZIP archive) is searched
	completely; for a directory the search follows the links of the pages, starting at the start page.
*)

CONST
	MaxHits = 300;

TYPE
	Ctx = OBJECT
	VAR
		src: MDSource.Source;
		q: MDTree.String; qlen: SIGNED32;
		out, list: MDTree.Node;	(* the result document; the list of the hits of the current page *)
		path: ARRAY 256 OF CHAR;
		title, sectionTitle: MDTree.String;
		sectionId: ARRAY 128 OF CHAR;
		hits, pages: SIGNED32;
	END Ctx;

(* ---------- text ---------- *)

(** a copy of s with Latin and Cyrillic capitals turned to small letters (same length in bytes) *)
PROCEDURE Lower*(CONST s: ARRAY OF CHAR): MDTree.String;
VAR r: MDTree.String; n, i, b: SIGNED32; c: SIGNED32;
BEGIN
	n := 0; WHILE s[n] # 0X DO INC(n) END;
	NEW(r, n + 1);
	COPY(s, r^);
	i := 0;
	WHILE i < n DO
		c := ORD(s[i]);
		IF (c >= ORD('A')) & (c <= ORD('Z')) THEN
			r[i] := CHR(c + 32); INC(i)
		ELSIF (c = 0D0H) & (i + 1 < n) THEN
			b := ORD(s[i + 1]);
			IF (b >= 090H) & (b <= 09FH) THEN r[i + 1] := CHR(b + 32)	(* A..P *)
			ELSIF (b >= 0A0H) & (b <= 0AFH) THEN r[i] := CHR(0D1H); r[i + 1] := CHR(b - 32)	(* R..Ya *)
			ELSIF (b >= 080H) & (b <= 08FH) THEN r[i] := CHR(0D1H); r[i + 1] := CHR(b + 16)	(* the Yo, Ye, I, Yi group *)
			END;
			INC(i, 2)
		ELSIF (c = 0D2H) & (i + 1 < n) THEN
			IF ORD(s[i + 1]) = 090H THEN r[i + 1] := CHR(091H) END;	(* G with an upturn *)
			INC(i, 2)
		ELSE
			INC(i)
		END
	END;
	RETURN r
END Lower;

(** the position of needle in hay at or after from, or -1 *)
PROCEDURE IndexOf*(CONST hay, needle: ARRAY OF CHAR; from: SIGNED32): SIGNED32;
VAR i, j: SIGNED32;
BEGIN
	IF needle[0] = 0X THEN RETURN -1 END;
	i := from;
	WHILE hay[i] # 0X DO
		j := 0;
		WHILE (needle[j] # 0X) & (hay[i + j] = needle[j]) DO INC(j) END;
		IF needle[j] = 0X THEN RETURN i END;
		INC(i)
	END;
	RETURN -1
END IndexOf;

PROCEDURE IntToStr(v: SIGNED32; VAR s: ARRAY OF CHAR);
VAR digits: ARRAY 12 OF CHAR; n, i: SIGNED32;
BEGIN
	n := 0;
	REPEAT digits[n] := CHR(ORD('0') + v MOD 10); INC(n); v := v DIV 10 UNTIL v = 0;
	i := 0;
	WHILE n > 0 DO DEC(n); s[i] := digits[n]; INC(i) END;
	s[i] := 0X
END IntToStr;

PROCEDURE Sub(CONST s: ARRAY OF CHAR; from, to: SIGNED32): MDTree.String;
VAR r: MDTree.String; i: SIGNED32;
BEGIN
	NEW(r, to - from + 1);
	FOR i := from TO to - 1 DO
		IF s[i] = 0AX THEN r[i - from] := ' ' ELSE r[i - from] := s[i] END
	END;
	r[to - from] := 0X;
	RETURN r
END Sub;

PROCEDURE EndsMd(CONST s: ARRAY OF CHAR): BOOLEAN;
VAR n: SIGNED32;
BEGIN
	n := 0; WHILE s[n] # 0X DO INC(n) END;
	RETURN (n > 3) & (s[n - 3] = '.') & ((s[n - 2] = 'm') OR (s[n - 2] = 'M')) & ((s[n - 1] = 'd') OR (s[n - 1] = 'D'))
END EndsMd;

(* ---------- the result document ---------- *)

(* "/page.md#anchor": the link is relative to the root of the source, so it works from any page *)
PROCEDURE Dest(CONST path, anchor: ARRAY OF CHAR): MDTree.String;
VAR d: MDTree.String;
BEGIN
	d := NIL;
	MDTree.AddText(d, "/"); MDTree.AddText(d, path);
	IF anchor[0] # 0X THEN MDTree.AddText(d, "#"); MDTree.AddText(d, anchor) END;
	RETURN d
END Dest;

PROCEDURE TextNode(CONST s: ARRAY OF CHAR): MDTree.Node;
BEGIN
	RETURN MDTree.NewTextNode(MDTree.Text, s)
END TextNode;

(* a hit: a list item with a link to the section, the section name and the text around the place found *)
PROCEDURE AddHit(c: Ctx; text: MDTree.String; p: SIGNED32);
VAR from, to, len: SIGNED32; head, pl, item, par, link, em, st: MDTree.Node; seg: MDTree.String;
BEGIN
	IF c.hits >= MaxHits THEN RETURN END;
	len := 0; WHILE text[len] # 0X DO INC(len) END;
	from := p - 50; IF from < 0 THEN from := 0 END;
	WHILE (from > 0) & (ORD(text[from]) DIV 64 = 2) DO DEC(from) END;	(* start of a character *)
	to := p + c.qlen + 70; IF to > len THEN to := len END;
	WHILE (to < len) & (ORD(text[to]) DIV 64 = 2) DO INC(to) END;
	IF c.list = NIL THEN	(* the first hit of this page: its heading and its list *)
		head := MDTree.NewNode(MDTree.Heading); head.level := 2;
		pl := MDTree.NewNode(MDTree.Link); pl.dest := Dest(c.path, "");
		MDTree.Append(pl, TextNode(c.title^)); MDTree.Append(head, pl);
		MDTree.Append(c.out, head);
		c.list := MDTree.NewNode(MDTree.BulletList); c.list.tight := TRUE;
		MDTree.Append(c.out, c.list);
		INC(c.pages)
	END;
	item := MDTree.NewNode(MDTree.Item); MDTree.Append(c.list, item);
	par := MDTree.NewNode(MDTree.Paragraph); MDTree.Append(item, par);
	link := MDTree.NewNode(MDTree.Link); link.dest := Dest(c.path, c.sectionId);
	MDTree.Append(par, link);
	IF c.sectionTitle # NIL THEN
		em := MDTree.NewNode(MDTree.Emph); MDTree.Append(em, TextNode(c.sectionTitle^));
		MDTree.Append(link, em); MDTree.Append(link, TextNode(": "))
	END;
	IF from > 0 THEN MDTree.Append(link, TextNode("...")) END;
	seg := Sub(text^, from, p); MDTree.Append(link, TextNode(seg^));
	st := MDTree.NewNode(MDTree.Strong);
	seg := Sub(text^, p, p + c.qlen); MDTree.Append(st, TextNode(seg^));
	MDTree.Append(link, st);
	seg := Sub(text^, p + c.qlen, to); MDTree.Append(link, TextNode(seg^));
	IF to < len THEN MDTree.Append(link, TextNode("...")) END;
	INC(c.hits)
END AddHit;

PROCEDURE Check(c: Ctx; text: MDTree.String);
VAR low: MDTree.String; p: SIGNED32;
BEGIN
	IF text = NIL THEN RETURN END;
	low := Lower(text^);
	p := IndexOf(low^, c.q^, 0);
	IF p >= 0 THEN AddHit(c, text, p) END
END Check;

(* the blocks that hold text are searched one by one; one hit per block *)
PROCEDURE Walk(c: Ctx; n: MDTree.Node);
VAR ch: MDTree.Node; text: MDTree.String;
BEGIN
	CASE n.kind OF
		MDTree.Heading:
			text := NIL; MDTree.PlainText(n, text);
			IF n.id # NIL THEN COPY(n.id^, c.sectionId) ELSE c.sectionId[0] := 0X END;
			c.sectionTitle := text;
			Check(c, text)
		|MDTree.Paragraph, MDTree.Cell:
			text := NIL; MDTree.PlainText(n, text);
			Check(c, text)
		|MDTree.CodeBlock:
			Check(c, n.text)
	ELSE
		ch := n.first;
		WHILE ch # NIL DO Walk(c, ch); ch := ch.next END
	END
END Walk;

(* the text of the first heading of the page, or NIL *)
PROCEDURE FirstTitle(n: MDTree.Node): MDTree.String;
VAR c: MDTree.Node; r, text: MDTree.String;
BEGIN
	IF n.kind = MDTree.Heading THEN
		text := NIL; MDTree.PlainText(n, text);
		RETURN text
	END;
	r := NIL;
	c := n.first;
	WHILE (c # NIL) & (r = NIL) DO
		IF c.kind # MDTree.Paragraph THEN r := FirstTitle(c) END;
		c := c.next
	END;
	RETURN r
END FirstTitle;

(* ---------- the pages ---------- *)

PROCEDURE AddName(VAR first, last: MDSource.NameList; CONST name: ARRAY OF CHAR);
VAR n, c: MDSource.NameList;
BEGIN
	c := first;
	WHILE (c # NIL) & ~(c.name = name) DO c := c.next END;
	IF c # NIL THEN RETURN END;
	NEW(n); COPY(name, n.name); n.next := NIL;
	IF last # NIL THEN last.next := n ELSE first := n END;
	last := n
END AddName;

(* the pages that page `from` links to *)
PROCEDURE CollectLinks(n: MDTree.Node; CONST from: ARRAY OF CHAR; VAR first, last: MDSource.NameList);
VAR c: MDTree.Node; path, frag, full: ARRAY 256 OF CHAR;
BEGIN
	IF (n.kind = MDTree.Link) & (n.dest # NIL) THEN
		IF MDTree.LinkKind(n.dest^) = MDTree.LinkPage THEN
			MDTree.SplitDest(n.dest^, path, frag);
			IF EndsMd(path) THEN
				MDSource.Resolve(from, path, full);
				AddName(first, last, full)
			END
		END
	END;
	c := n.first;
	WHILE c # NIL DO CollectLinks(c, from, first, last); c := c.next END
END CollectLinks;

(** searches the pages of src for the query; the result is a document with a link to every place found *)
PROCEDURE Run*(src: MDSource.Source; CONST start, query: ARRAY OF CHAR): MDTree.Node;
VAR c: Ctx; first, last, cur: MDSource.NameList; r: Streams.Reader; doc, h, par, summary: MDTree.Node;
	crawl: BOOLEAN; s, num: ARRAY 64 OF CHAR; text: MDTree.String;
BEGIN
	NEW(c); c.src := src; c.q := Lower(query); c.qlen := 0;
	WHILE c.q[c.qlen] # 0X DO INC(c.qlen) END;
	c.out := MDTree.NewNode(MDTree.Document);
	h := MDTree.NewNode(MDTree.Heading); h.level := 1;
	MDTree.Append(h, TextNode("Search results")); MDTree.Append(c.out, h);
	par := MDTree.NewNode(MDTree.Paragraph); MDTree.Append(c.out, par);
	summary := TextNode(""); MDTree.Append(par, summary);
	IF c.qlen = 0 THEN
		summary.text := MDTree.NewString("Type a word or a phrase in the field first.");
		RETURN c.out
	END;
	first := src.Pages();
	crawl := first = NIL;
	IF crawl THEN NEW(first); COPY(start, first.name); first.next := NIL END;
	last := first; WHILE last.next # NIL DO last := last.next END;
	cur := first;
	WHILE cur # NIL DO
		c.list := NIL; COPY(cur.name, c.path); c.sectionTitle := NIL; c.sectionId[0] := 0X;
		r := src.Open(cur.name);
		IF r # NIL THEN
			doc := MDParser.Parse(r);
			c.title := FirstTitle(doc);
			IF c.title = NIL THEN c.title := MDTree.NewString(cur.name) END;
			Walk(c, doc);
			IF crawl THEN CollectLinks(doc, cur.name, first, last) END
		END;
		cur := cur.next
	END;
	text := NIL;
	IF c.hits = 0 THEN
		MDTree.AddText(text, "Nothing found for: "); MDTree.AddText(text, query)
	ELSE
		MDTree.AddText(text, "Found ");
		IntToStr(c.hits, num); MDTree.AddText(text, num);
		IF c.hits = 1 THEN MDTree.AddText(text, " place in ") ELSE MDTree.AddText(text, " places in ") END;
		IntToStr(c.pages, num); MDTree.AddText(text, num);
		IF c.pages = 1 THEN MDTree.AddText(text, " page for: ") ELSE MDTree.AddText(text, " pages for: ") END;
		MDTree.AddText(text, query);
		IF c.hits >= MaxHits THEN MDTree.AddText(text, " (only the first ones are shown)") END
	END;
	summary.text := text;
	RETURN c.out
END Run;

END MDSearch.
