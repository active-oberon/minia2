MODULE MDLayout; (** AUTHOR "BohdanT"; PURPOSE: Layout of an MDTree document for a given width: positioned text items and boxes, link regions, heading anchors *)

IMPORT WMGraphics, MDTree, MDHighlight, MDMath, MDSearch;

(*
	Layout.Build turns a document into a flat list of Items in document coordinates (x to the right,
	y downwards, origin at the top left of the document). The viewer draws the items that are visible.
	- ItemText: a piece of text, x, y = top left of its box, the baseline is y + font.GetAscent().
	  Items with link # NIL are the clickable regions of links.
	- ItemRect: a filled rectangle (rule, quote bar, code background).
	Items are in drawing order: a background rectangle always comes before the text on it.

	Tables are laid out as a grid (column widths from the content, cell alignment, header row).
	Code blocks have a header strip with the language and a Copy button; Active Oberon code
	(info string oberon, ao, activeoberon or a2) is highlighted.
	Images are drawn inline on the baseline of the line and scaled down to the column width; if a picture
	cannot be loaded its alt text is shown as [alt]. Formulas (MDMath) are typeset into images: inline ones sit on
	the baseline of the line, $$ blocks are centered; a formula with an error is shown as its TeX text.
*)

CONST
	ItemText* = 0;
	ItemRect* = 1;
	ItemImage* = 2;
	ItemCopy* = 3;	(* the Copy button of a code block; text = the code to copy *)

	AtomWord = 0; AtomSpace = 1; AtomBreak = 2; AtomImage = 3; AtomFormula = 4;

VAR
	codeFontName*: ARRAY 64 OF CHAR;	(* font family for code; the default font is used when it is not installed *)

PROCEDURE Sub(CONST s: ARRAY OF CHAR; from, to: SIGNED32): MDTree.String;
VAR r: MDTree.String; i: SIGNED32;
BEGIN
	NEW(r, to - from + 1);
	FOR i := from TO to - 1 DO r[i - from] := s[i] END;
	r[to - from] := 0X;
	RETURN r
END Sub;

(* does the string contain anything but spaces? *)
PROCEDURE NonBlank(CONST s: ARRAY OF CHAR): BOOLEAN;
VAR i: SIGNED32;
BEGIN
	i := 0; WHILE s[i] = ' ' DO INC(i) END;
	RETURN s[i] # 0X
END NonBlank;

TYPE
	(** loads the picture for the destination of an Image node; NIL if there is none *)
	ImageProvider* = PROCEDURE {DELEGATE} (CONST src: ARRAY OF CHAR): WMGraphics.Image;

	(* fonts, colors and spacing *)
	Styles* = OBJECT
	VAR
		text*: ARRAY 4 OF WMGraphics.Font;	(* index = bold (1) + italic (2) *)
		code*, codeBold*, codeItalic*: WMGraphics.Font;
		head*: ARRAY 7 OF WMGraphics.Font;	(* headings 1..6 *)
		colText*, colLink*, colCode*, colCodeBg*, colMath*, colRule*, colQuote*: WMGraphics.Color;
		colCodeHead*, colKeyword*, colBuiltin*, colString*, colNumber*, colComment*: WMGraphics.Color;
		margin*, indent*, gap*, leading*: SIZE;

		PROCEDURE &Init*;
		VAR base: WMGraphics.Font; name: ARRAY 256 OF CHAR; size: SIZE; k, p: SIGNED32;
		BEGIN
			base := WMGraphics.GetDefaultFont();
			COPY(base.name, name);
			size := base.size; IF size <= 0 THEN size := 12 END;
			text[0] := base;
			text[1] := WMGraphics.GetFont(name, size, {WMGraphics.FontBold});
			text[2] := WMGraphics.GetFont(name, size, {WMGraphics.FontItalic});
			text[3] := WMGraphics.GetFont(name, size, {WMGraphics.FontBold, WMGraphics.FontItalic});
			code := WMGraphics.GetFont(codeFontName, size, {});
			codeBold := WMGraphics.GetFont(codeFontName, size, {WMGraphics.FontBold});
			codeItalic := WMGraphics.GetFont(codeFontName, size, {WMGraphics.FontItalic});
			FOR k := 1 TO 6 DO
				CASE k OF
					1: p := 200
					|2: p := 160
					|3: p := 135
					|4: p := 115
					|5: p := 105
				ELSE
					p := 100
				END;
				head[k] := WMGraphics.GetFont(name, size * p DIV 100, {WMGraphics.FontBold})
			END;
			colText := WMGraphics.Black;
			colLink := WMGraphics.RGBAToColor(0, 0, 192, 255);
			colCode := WMGraphics.RGBAToColor(40, 40, 40, 255);
			colCodeBg := WMGraphics.RGBAToColor(236, 236, 236, 255);
			colMath := WMGraphics.RGBAToColor(0, 96, 0, 255);
			colRule := WMGraphics.RGBAToColor(160, 160, 160, 255);
			colQuote := WMGraphics.RGBAToColor(170, 170, 200, 255);
			colCodeHead := WMGraphics.RGBAToColor(220, 220, 220, 255);
			colKeyword := WMGraphics.RGBAToColor(0, 0, 160, 255);
			colBuiltin := WMGraphics.RGBAToColor(0, 112, 112, 255);
			colString := WMGraphics.RGBAToColor(170, 40, 40, 255);
			colNumber := WMGraphics.RGBAToColor(150, 0, 130, 255);
			colComment := WMGraphics.RGBAToColor(90, 130, 90, 255);
			margin := 10; indent := 22; gap := 8; leading := 2
		END Init;
	END Styles;

	Item* = OBJECT
	VAR
		kind*: SIGNED32;
		x*, y*, w*, h*: SIZE;
		text*: MDTree.String;
		font*: WMGraphics.Font;
		color*: WMGraphics.Color;
		link*: MDTree.Node;	(* the Link node, if this text or picture belongs to a link *)
		image*: WMGraphics.Image;	(* ItemImage: drawn scaled into x, y, w, h *)
		next*: Item;
	END Item;

	Anchor = OBJECT
	VAR
		id: MDTree.String;
		y: SIZE;
		next: Anchor;
	END Anchor;

	(* a word, a space or a forced break of an inline flow *)
	Atom = OBJECT
	VAR
		kind: SIGNED32;
		text: MDTree.String;
		font: WMGraphics.Font;
		color: WMGraphics.Color;
		link: MDTree.Node;
		img: WMGraphics.Image;
		w, asc, desc: SIZE;	(* a picture: w = width, asc = height, desc = 0 *)
	END Atom;

	AtomArray = POINTER TO ARRAY OF Atom;
	SizeArray = POINTER TO ARRAY OF SIZE;
	ItemArray = POINTER TO ARRAY OF Item;

	(** a place where a searched text was found: the text items from first to last (the others in between are
	    spaces), y = the top of the first one *)
	Match* = OBJECT
	VAR
		first*, last*: Item;
		y*: SIZE;
		next*: Match;
	END Match;

	Atoms = OBJECT
	VAR
		a: AtomArray;
		n: SIGNED32;

		PROCEDURE &Init*;
		BEGIN
			NEW(a, 32); n := 0
		END Init;

		PROCEDURE Add(kind: SIGNED32; s: MDTree.String; font: WMGraphics.Font; color: WMGraphics.Color; link: MDTree.Node);
		VAR x: Atom; b: AtomArray; i: SIGNED32; th: SIZE;
		BEGIN
			IF n = LEN(a) THEN
				NEW(b, 2 * LEN(a));
				FOR i := 0 TO n - 1 DO b[i] := a[i] END;
				a := b
			END;
			NEW(x); x.kind := kind; x.text := s; x.font := font; x.color := color; x.link := link;
			x.asc := font.GetAscent(); x.desc := font.GetDescent();
			x.w := 0;
			IF (kind # AtomBreak) & (s # NIL) THEN font.GetStringSize(s^, x.w, th) END;
			a[n] := x; INC(n)
		END Add;

		PROCEDURE AddImage(img: WMGraphics.Image; link: MDTree.Node);
		VAR x: Atom; b: AtomArray; i: SIGNED32;
		BEGIN
			IF n = LEN(a) THEN
				NEW(b, 2 * LEN(a));
				FOR i := 0 TO n - 1 DO b[i] := a[i] END;
				a := b
			END;
			NEW(x); x.kind := AtomImage; x.img := img; x.link := link;
			x.w := img.width; x.asc := img.height; x.desc := 0;
			a[n] := x; INC(n)
		END AddImage;

		(* a typeset formula: the picture, and how far it reaches above and below the baseline of the text *)
		PROCEDURE AddFormula(img: WMGraphics.Image; asc, desc: SIZE; link: MDTree.Node);
		VAR x: Atom; b: AtomArray; i: SIGNED32;
		BEGIN
			IF n = LEN(a) THEN
				NEW(b, 2 * LEN(a));
				FOR i := 0 TO n - 1 DO b[i] := a[i] END;
				a := b
			END;
			NEW(x); x.kind := AtomFormula; x.img := img; x.link := link;
			x.w := img.width; x.asc := asc; x.desc := desc;
			a[n] := x; INC(n)
		END AddFormula;
	END Atoms;

	Layout* = OBJECT
	VAR
		provider*: ImageProvider;	(* set by the viewer before Build; may stay NIL *)
		first-, last-: Item;
		height-: SIZE;
		anchors: Anchor;
		st: Styles;
		cy: SIZE;	(* top of the free space below what is laid out *)
		tight: BOOLEAN;	(* inside an item of a tight list: no space between paragraphs *)
		boldBase: BOOLEAN;	(* inline text is bold from the start (header cells of tables) *)

		PROCEDURE &Init*;
		BEGIN
			first := NIL; last := NIL; anchors := NIL; height := 0; tight := FALSE; boldBase := FALSE; cy := 0; provider := NIL
		END Init;

		(* ---- items ---- *)

		PROCEDURE Add(it: Item);
		BEGIN
			it.next := NIL;
			IF last # NIL THEN last.next := it ELSE first := it END;
			last := it
		END Add;

		PROCEDURE AddRect(rx, ry, rw, rh: SIZE; color: WMGraphics.Color): Item;
		VAR it: Item;
		BEGIN
			NEW(it); it.kind := ItemRect; it.x := rx; it.y := ry; it.w := rw; it.h := rh; it.color := color;
			Add(it);
			RETURN it
		END AddRect;

		PROCEDURE AddText(tx, ty: SIZE; s: MDTree.String; font: WMGraphics.Font; color: WMGraphics.Color;
				link: MDTree.Node; tw: SIZE);
		VAR it: Item;
		BEGIN
			NEW(it); it.kind := ItemText; it.x := tx; it.y := ty; it.w := tw; it.h := font.GetHeight();
			it.text := s; it.font := font; it.color := color; it.link := link;
			Add(it)
		END AddText;

		PROCEDURE AddImageItem(ix, iy, iw, ih: SIZE; img: WMGraphics.Image; link: MDTree.Node);
		VAR it: Item;
		BEGIN
			NEW(it); it.kind := ItemImage; it.x := ix; it.y := iy; it.w := iw; it.h := ih;
			it.image := img; it.link := link;
			Add(it)
		END AddImageItem;

		(* ---- inline flow ---- *)

		PROCEDURE FontFor(bold, italic: BOOLEAN; head: SIGNED32): WMGraphics.Font;
		VAR k: SIGNED32;
		BEGIN
			IF head > 0 THEN RETURN st.head[head] END;
			k := 0;
			IF bold THEN k := 1 END;
			IF italic THEN INC(k, 2) END;
			RETURN st.text[k]
		END FontFor;

		(* splits s into words and spaces; a run of spaces is one space *)
		PROCEDURE Words(list: Atoms; CONST s: ARRAY OF CHAR; font: WMGraphics.Font; color: WMGraphics.Color; link: MDTree.Node);
		VAR i, j: SIGNED32;
		BEGIN
			i := 0;
			WHILE s[i] # 0X DO
				j := i;
				IF s[i] = ' ' THEN
					WHILE s[j] = ' ' DO INC(j) END;
					list.Add(AtomSpace, MDTree.NewString(" "), font, color, link)
				ELSE
					WHILE (s[j] # 0X) & (s[j] # ' ') DO INC(j) END;
					list.Add(AtomWord, Sub(s, i, j), font, color, link)
				END;
				i := j
			END
		END Words;

		PROCEDURE Collect(list: Atoms; n: MDTree.Node; bold, italic: BOOLEAN; head: SIGNED32; link: MDTree.Node);
		VAR c: MDTree.Node; font: WMGraphics.Font; color: WMGraphics.Color; s, alt: MDTree.String;
			img: WMGraphics.Image; f: MDMath.Formula;
		BEGIN
			c := n.first;
			WHILE c # NIL DO
				font := FontFor(bold, italic, head);
				IF link # NIL THEN color := st.colLink ELSE color := st.colText END;
				CASE c.kind OF
					MDTree.Text:
						IF c.text # NIL THEN Words(list, c.text^, font, color, link) END
					|MDTree.Code:
						IF link = NIL THEN color := st.colCode END;
						IF c.text # NIL THEN Words(list, c.text^, st.code, color, link) END
					|MDTree.MathInline:
						f := NIL;
						IF c.text # NIL THEN f := MDMath.Typeset(c.text^, c.level = 2, font.name, font.size) END;
						IF f # NIL THEN
							list.AddFormula(MDMath.Render(f, color), MDMath.Pad + f.ascent, MDMath.Pad + f.descent, link)
						ELSE	(* an error in the formula: its TeX text *)
							s := NIL; MDTree.AddText(s, "$");
							IF c.text # NIL THEN MDTree.AddText(s, c.text^) END;
							MDTree.AddText(s, "$");
							IF link = NIL THEN color := st.colMath END;
							list.Add(AtomWord, s, st.code, color, link)
						END
					|MDTree.Emph:
						Collect(list, c, bold, TRUE, head, link)
					|MDTree.Strong:
						Collect(list, c, TRUE, italic, head, link)
					|MDTree.Link:
						Collect(list, c, bold, italic, head, c)
					|MDTree.Image:
						img := NIL;
						IF (provider # NIL) & (c.dest # NIL) THEN img := provider(c.dest^) END;
						IF img # NIL THEN
							list.AddImage(img, link)
						ELSE	(* no picture: its alt text in brackets *)
							alt := NIL; MDTree.PlainText(c, alt);
							s := NIL; MDTree.AddText(s, "[");
							IF alt # NIL THEN MDTree.AddText(s, alt^) END;
							MDTree.AddText(s, "]");
							list.Add(AtomWord, s, st.text[2], color, link)
						END
					|MDTree.SoftBreak:
						list.Add(AtomSpace, MDTree.NewString(" "), font, color, link)
					|MDTree.HardBreak:
						list.Add(AtomBreak, NIL, font, color, link)
				ELSE
				END;
				c := c.next
			END
		END Collect;

		(* lays out the inline content of n in the column [x, x + w) from the current position, line by line *)
		PROCEDURE Flow(n: MDTree.Node; x, w: SIZE; head, align: SIGNED32);
		VAR list: Atoms; atom: Atom; i, j, end, k: SIGNED32; cx, a, d, lw: SIZE;
			hasWord, done: BOOLEAN; base: WMGraphics.Font;
		BEGIN
			NEW(list);
			Collect(list, n, boldBase, FALSE, head, NIL);
			base := FontFor(boldBase, FALSE, head);
			FOR k := 0 TO list.n - 1 DO	(* a picture wider than the column is scaled down *)
				atom := list.a[k];
				IF (atom.kind = AtomImage) & (w > 0) & (atom.w > w) THEN
					atom.asc := MAX(1, atom.asc * w DIV atom.w); atom.w := w
				END
			END;
			i := 0;
			WHILE i < list.n DO
				WHILE (i < list.n) & (list.a[i].kind = AtomSpace) DO INC(i) END;	(* no spaces at the start of a line *)
				IF i < list.n THEN
					(* the atoms i .. j-1 form one line; i .. end-1 are drawn, the rest are trailing spaces *)
					j := i; end := i; cx := 0; hasWord := FALSE; done := FALSE;
					WHILE ~done & (j < list.n) DO
						atom := list.a[j];
						IF atom.kind = AtomBreak THEN
							done := TRUE; INC(j)
						ELSIF (atom.kind # AtomSpace) & hasWord & (cx + atom.w > w) THEN
							done := TRUE
						ELSE
							INC(cx, atom.w); INC(j);
							IF atom.kind # AtomSpace THEN hasWord := TRUE; end := j END
						END
					END;
					a := 0; d := 0; lw := 0;
					FOR k := i TO end - 1 DO
						a := MAX(a, list.a[k].asc); d := MAX(d, list.a[k].desc); INC(lw, list.a[k].w)
					END;
					IF end = i THEN a := base.GetAscent(); d := base.GetDescent() END;
					cx := x;
					IF align = MDTree.AlignCenter THEN cx := x + (w - lw) DIV 2
					ELSIF align = MDTree.AlignRight THEN cx := x + w - lw
					END;
					IF cx < x THEN cx := x END;
					FOR k := i TO end - 1 DO
						atom := list.a[k];
						IF atom.kind = AtomImage THEN
							AddImageItem(cx, cy + a - atom.asc, atom.w, atom.asc, atom.img, atom.link)
						ELSIF atom.kind = AtomFormula THEN
							AddImageItem(cx, cy + a - atom.asc, atom.w, atom.asc + atom.desc, atom.img, atom.link)
						ELSIF atom.text # NIL THEN
							AddText(cx, cy + a - atom.asc, atom.text, atom.font, atom.color, atom.link, atom.w)
						END;
						INC(cx, atom.w)
					END;
					INC(cy, a + d + st.leading);
					i := j
				END
			END
		END Flow;

		(* ---- blocks ---- *)

		PROCEDURE Children(n: MDTree.Node; x, w: SIZE);
		VAR c: MDTree.Node;
		BEGIN
			c := n.first;
			WHILE c # NIL DO Block(c, x, w); c := c.next END
		END Children;

		PROCEDURE Heading(n: MDTree.Node; x, w: SIZE);
		VAR a: Anchor;
		BEGIN
			IF cy > st.margin THEN INC(cy, st.gap) END;
			IF n.id # NIL THEN
				NEW(a); a.id := n.id; a.y := cy; a.next := anchors; anchors := a
			END;
			Flow(n, x, w, n.level, 0);
			INC(cy, st.gap DIV 2)
		END Heading;

		PROCEDURE Quote(n: MDTree.Node; x, w: SIZE);
		VAR bar: Item; y0: SIZE;
		BEGIN
			y0 := cy;
			bar := AddRect(x, cy, 3, 0, st.colQuote);
			Children(n, x + st.indent, MAX(w - st.indent, 40));
			bar.h := MAX(cy - y0 - st.gap, 1)
		END Quote;

		PROCEDURE MarkerOf(n: MDTree.Node; num: SIGNED32): MDTree.String;
		VAR b: ARRAY 24 OF CHAR; digits: ARRAY 12 OF CHAR; k, i: SIGNED32;
		BEGIN
			IF n.kind = MDTree.BulletList THEN
				b[0] := 0E2X; b[1] := 080X; b[2] := 0A2X; b[3] := 0X	(* a bullet, UTF-8 *)
			ELSE
				k := 0;
				REPEAT digits[k] := CHR(ORD('0') + num MOD 10); INC(k); num := num DIV 10 UNTIL num = 0;
				i := 0;
				WHILE k > 0 DO DEC(k); b[i] := digits[k]; INC(i) END;
				b[i] := '.'; b[i + 1] := 0X
			END;
			RETURN MDTree.NewString(b)
		END MarkerOf;

		PROCEDURE List(n: MDTree.Node; x, w: SIZE);
		VAR it: MDTree.Node; num: SIGNED32; marker: MDTree.String; col, tw, th, y0: SIZE; wasTight: BOOLEAN;
			font: WMGraphics.Font;
		BEGIN
			font := st.text[0];
			col := 0; num := n.start; it := n.first;
			WHILE it # NIL DO	(* the marker column is as wide as the widest marker *)
				marker := MarkerOf(n, num);
				font.GetStringSize(marker^, tw, th);
				col := MAX(col, tw);
				INC(num); it := it.next
			END;
			col := MAX(col + 10, st.indent);
			wasTight := tight; tight := n.tight;
			num := n.start; it := n.first;
			WHILE it # NIL DO
				y0 := cy;
				marker := MarkerOf(n, num);
				font.GetStringSize(marker^, tw, th);
				AddText(x + col - 6 - tw, cy, marker, font, st.colText, NIL, tw);
				Children(it, x + col, MAX(w - col, 40));
				IF cy = y0 THEN INC(cy, font.GetHeight() + st.leading) END;	(* an empty item *)
				INC(num); it := it.next
			END;
			tight := wasTight;
			IF ~tight THEN INC(cy, st.gap) END
		END List;

		PROCEDURE AddCopy(bx, by, bw, bh: SIZE; code: MDTree.String);
		VAR it: Item;
		BEGIN
			NEW(it); it.kind := ItemCopy; it.x := bx; it.y := by; it.w := bw; it.h := bh;
			it.text := code; it.font := st.text[0]; it.color := st.colText;
			Add(it)
		END AddCopy;

		(* the font and the color of a highlighted span *)
		PROCEDURE SpanStyle(kind: SIGNED32; VAR font: WMGraphics.Font; VAR color: WMGraphics.Color);
		BEGIN
			font := st.code; color := st.colCode;
			CASE kind OF
				MDHighlight.Keyword: font := st.codeBold; color := st.colKeyword
				|MDHighlight.Builtin: color := st.colBuiltin
				|MDHighlight.String: color := st.colString
				|MDHighlight.Number: color := st.colNumber
				|MDHighlight.Comment: font := st.codeItalic; color := st.colComment
				|MDHighlight.ProcName: font := st.codeBold
			ELSE
			END
		END SpanStyle;

		(* a code block: a header strip with the language and the Copy button, then the lines *)
		PROCEDURE CodeBlockBox(n: MDTree.Node; x, w: SIZE);
		VAR bg, hdr: Item; i, j, k: SIGNED32; line, seg, label: MDTree.String; y0, lh, pad, hh, tw, th, bw, cx: SIZE;
			font: WMGraphics.Font; color: WMGraphics.Color; highlight, finished: BOOLEAN;
			hs: MDHighlight.State; sp: MDHighlight.Span; lang: ARRAY 32 OF CHAR;
		BEGIN
			pad := 4; lh := st.code.GetHeight();
			highlight := (n.info # NIL) & MDHighlight.IsOberon(n.info^);
			bg := AddRect(x, cy, w, 0, st.colCodeBg);
			y0 := cy;
			hh := st.text[0].GetHeight() + 6;
			hdr := AddRect(x, cy, w, hh, st.colCodeHead);
			IF n.info # NIL THEN	(* the language: the first word of the info string *)
				k := 0;
				WHILE (n.info[k] # 0X) & (n.info[k] # ' ') & (k < 31) DO lang[k] := n.info[k]; INC(k) END;
				lang[k] := 0X;
				IF k > 0 THEN
					label := MDTree.NewString(lang);
					st.text[0].GetStringSize(label^, tw, th);
					AddText(x + pad + 2, cy + 3, label, st.text[0], WMGraphics.RGBAToColor(100, 100, 100, 255), NIL, tw)
				END
			END;
			st.text[0].GetStringSize("Copied", bw, th); INC(bw, 16);	(* as wide as the longer caption *)
			AddCopy(x + w - bw - 4, cy + 3, bw, hh - 6, n.text);
			INC(cy, hh + pad);
			MDHighlight.Reset(hs);
			IF n.text # NIL THEN
				i := 0; finished := FALSE;
				WHILE ~finished DO
					j := i;
					WHILE (n.text[j] # 0X) & (n.text[j] # 0AX) DO INC(j) END;
					line := Sub(n.text^, i, j);
					IF highlight THEN
						cx := x + pad;
						sp := MDHighlight.Line(line^, hs);
						WHILE sp # NIL DO
							seg := Sub(line^, sp.start, sp.end);
							SpanStyle(sp.kind, font, color);
							font.GetStringSize(seg^, tw, th);
							IF NonBlank(seg^) THEN AddText(cx, cy, seg, font, color, NIL, tw) END;
							INC(cx, tw);
							sp := sp.next
						END
					ELSE
						st.code.GetStringSize(line^, tw, th);
						AddText(x + pad, cy, line, st.code, st.colCode, NIL, tw)
					END;
					INC(cy, lh);
					IF n.text[j] = 0X THEN finished := TRUE ELSE i := j + 1 END
				END
			END;
			INC(cy, pad);
			bg.h := cy - y0;
			INC(cy, st.gap)
		END CodeBlockBox;

		(* a display formula: typeset and centered; with an error in it, its TeX text *)
		PROCEDURE MathBlockBox(n: MDTree.Node; x, w: SIZE);
		VAR f: MDMath.Formula; img: WMGraphics.Image; ix: SIZE; font: WMGraphics.Font;
		BEGIN
			font := st.text[0]; f := NIL;
			IF n.text # NIL THEN f := MDMath.Typeset(n.text^, TRUE, font.name, font.size) END;
			IF f = NIL THEN
				CodeLines(n, x, w, st.colMath, FALSE)
			ELSE
				img := MDMath.Render(f, st.colText);
				ix := x + MAX(0, (w - img.width) DIV 2);
				INC(cy, st.gap DIV 2);
				AddImageItem(ix, cy, img.width, img.height, img, NIL);
				INC(cy, img.height + st.gap)
			END
		END MathBlockBox;

		(* plain code and the text of a formula with an error: lines are not wrapped *)
		PROCEDURE CodeLines(n: MDTree.Node; x, w: SIZE; color: WMGraphics.Color; box: BOOLEAN);
		VAR bg: Item; i, j: SIGNED32; line: MDTree.String; y0, lh, pad, tw, th: SIZE; finished: BOOLEAN;
			font: WMGraphics.Font;
		BEGIN
			font := st.code; pad := 4; lh := font.GetHeight();
			bg := NIL;
			IF box THEN bg := AddRect(x, cy, w, 0, st.colCodeBg) END;
			y0 := cy; INC(cy, pad);
			IF n.text # NIL THEN
				i := 0; finished := FALSE;
				WHILE ~finished DO
					j := i;
					WHILE (n.text[j] # 0X) & (n.text[j] # 0AX) DO INC(j) END;
					line := Sub(n.text^, i, j);
					font.GetStringSize(line^, tw, th);
					AddText(x + pad, cy, line, font, color, NIL, tw);
					INC(cy, lh);
					IF n.text[j] = 0X THEN finished := TRUE ELSE i := j + 1 END
				END
			END;
			INC(cy, pad);
			IF bg # NIL THEN bg.h := cy - y0 END;
			INC(cy, st.gap)
		END CodeLines;

		PROCEDURE Rule(x, w: SIZE);
		VAR r: Item;
		BEGIN
			INC(cy, st.gap DIV 2);
			r := AddRect(x, cy, w, 1, st.colRule);
			INC(cy, 1 + st.gap)
		END Rule;

		(* natural width (all on one line) and minimal width (the longest word) of the inline content of n *)
		PROCEDURE Measure(n: MDTree.Node; VAR natural, minw: SIZE);
		VAR list: Atoms; k: SIGNED32; cur: SIZE;
		BEGIN
			NEW(list);
			Collect(list, n, boldBase, FALSE, 0, NIL);
			natural := 0; minw := 0; cur := 0;
			FOR k := 0 TO list.n - 1 DO
				IF list.a[k].kind = AtomBreak THEN
					natural := MAX(natural, cur); cur := 0
				ELSE
					INC(cur, list.a[k].w);
					IF list.a[k].kind = AtomWord THEN
						minw := MAX(minw, list.a[k].w)
					ELSIF list.a[k].kind = AtomImage THEN
						minw := MAX(minw, MIN(list.a[k].w, 48))	(* a picture can be scaled down *)
					ELSIF list.a[k].kind = AtomFormula THEN
						minw := MAX(minw, list.a[k].w)	(* a formula cannot *)
					END
				END
			END;
			natural := MAX(natural, cur)
		END Measure;

		(* a grid: column widths follow the content, cells wrap, header row is bold on a gray background *)
		PROCEDURE Table(n: MDTree.Node; x, w: SIZE);
		VAR row, cell: MDTree.Node; cols, c, k: SIGNED32; nat, mn, cw: SizeArray;
			pad, tw, top, rowTop, rowBottom, bottom, cx, nw, mw, sumNat, sumMin, sumDiff, lx: SIZE;
			bg, line: Item;
		BEGIN
			IF n.first = NIL THEN RETURN END;
			pad := 6;
			cols := 0; cell := n.first.first;
			WHILE cell # NIL DO INC(cols); cell := cell.next END;
			IF cols = 0 THEN RETURN END;
			NEW(nat, cols); NEW(mn, cols); NEW(cw, cols);
			row := n.first;
			WHILE row # NIL DO	(* content widths *)
				boldBase := row.header;
				c := 0; cell := row.first;
				WHILE (cell # NIL) & (c < cols) DO
					Measure(cell, nw, mw);
					nat[c] := MAX(nat[c], nw); mn[c] := MAX(mn[c], mw);
					INC(c); cell := cell.next
				END;
				row := row.next
			END;
			boldBase := FALSE;
			sumNat := 0; sumMin := 0; sumDiff := 0;
			FOR c := 0 TO cols - 1 DO
				INC(sumNat, nat[c] + 2 * pad); INC(sumMin, mn[c] + 2 * pad); INC(sumDiff, nat[c] - mn[c])
			END;
			FOR c := 0 TO cols - 1 DO
				IF sumNat <= w THEN
					cw[c] := nat[c] + 2 * pad	(* everything fits on one line *)
				ELSIF (sumMin >= w) OR (sumDiff = 0) THEN
					cw[c] := mn[c] + 2 * pad	(* narrower is impossible; the table may stick out *)
				ELSE
					cw[c] := mn[c] + 2 * pad + (w - sumMin) * (nat[c] - mn[c]) DIV sumDiff
				END
			END;
			tw := 0;
			FOR c := 0 TO cols - 1 DO INC(tw, cw[c]) END;
			top := cy;
			line := AddRect(x, top, tw, 1, st.colRule);	(* top border *)
			rowTop := top + 1;
			row := n.first;
			WHILE row # NIL DO
				IF row.header THEN bg := AddRect(x, rowTop, tw, 0, st.colCodeBg) ELSE bg := NIL END;
				boldBase := row.header;
				bottom := rowTop;
				cx := x; c := 0; cell := row.first;
				WHILE (cell # NIL) & (c < cols) DO
					cy := rowTop + pad;
					Flow(cell, cx + pad, cw[c] - 2 * pad, 0, cell.align);
					bottom := MAX(bottom, cy);
					INC(cx, cw[c]); INC(c); cell := cell.next
				END;
				boldBase := FALSE;
				rowBottom := MAX(bottom - st.leading + pad, rowTop + st.text[0].GetHeight() + 2 * pad);
				IF bg # NIL THEN bg.h := rowBottom - rowTop END;
				line := AddRect(x, rowBottom, tw, 1, st.colRule);	(* line below the row *)
				rowTop := rowBottom + 1;
				row := row.next
			END;
			lx := x;	(* vertical lines *)
			FOR k := 0 TO cols DO
				IF k = cols THEN line := AddRect(lx - 1, top, 1, rowTop - top, st.colRule)
				ELSE line := AddRect(lx, top, 1, rowTop - top, st.colRule); INC(lx, cw[k])
				END
			END;
			cy := rowTop + st.gap
		END Table;

		PROCEDURE Block(n: MDTree.Node; x, w: SIZE);
		BEGIN
			CASE n.kind OF
				MDTree.Document, MDTree.Item: Children(n, x, w)
				|MDTree.Heading: Heading(n, x, w)
				|MDTree.Paragraph:
					Flow(n, x, w, 0, 0);
					IF ~tight THEN INC(cy, st.gap) END
				|MDTree.Quote: Quote(n, x, w)
				|MDTree.BulletList, MDTree.OrderedList: List(n, x, w)
				|MDTree.CodeBlock: CodeBlockBox(n, x, w)
				|MDTree.MathBlock: MathBlockBox(n, x, w)
				|MDTree.Rule: Rule(x, w)
				|MDTree.Table: Table(n, x, w)
			ELSE
			END
		END Block;

		(* ---- interface ---- *)

		(** lays out the whole document for the given width in pixels *)
		PROCEDURE Build*(doc: MDTree.Node; styles: Styles; width: SIZE);
		BEGIN
			first := NIL; last := NIL; anchors := NIL; st := styles; tight := FALSE; boldBase := FALSE;
			cy := st.margin;
			Block(doc, st.margin, MAX(width - 2 * st.margin, 40));
			height := cy + st.margin
		END Build;

		(** all places of the laid out text where the query is found, in document order; case does not matter.
		    Words that wrap to the next line still match. *)
		PROCEDURE Find*(CONST query: ARRAY OF CHAR): Match;
		VAR it: Item; items: ItemArray; offs, ends: SizeArray; n, k, a, b, qlen, p: SIGNED32; total, pos, base, prevBase: SIZE;
			stream: MDTree.String; low, q: MDTree.String; mFirst, mLast, m: Match; i: SIGNED32;
		BEGIN
			q := MDSearch.Lower(query);
			qlen := 0; WHILE q[qlen] # 0X DO INC(qlen) END;
			IF qlen = 0 THEN RETURN NIL END;
			n := 0; total := 0; it := SELF.first;
			WHILE it # NIL DO
				IF (it.kind = ItemText) & (it.text # NIL) THEN
					INC(n); i := 0; WHILE it.text[i] # 0X DO INC(i) END; INC(total, i + 1)
				END;
				it := it.next
			END;
			IF n = 0 THEN RETURN NIL END;
			NEW(items, n); NEW(offs, n); NEW(ends, n); NEW(stream, total + 1);
			(* the text of the page in one string: a space is put where the next item starts a new line *)
			k := 0; pos := 0; prevBase := -1; it := SELF.first;
			WHILE it # NIL DO
				IF (it.kind = ItemText) & (it.text # NIL) THEN
					base := it.y + it.font.GetAscent();
					IF (pos > 0) & (base # prevBase) & (stream[pos - 1] # ' ') & (it.text[0] # ' ') THEN
						stream[pos] := ' '; INC(pos)
					END;
					prevBase := base;
					items[k] := it; offs[k] := pos;
					i := 0; WHILE it.text[i] # 0X DO stream[pos] := it.text[i]; INC(pos); INC(i) END;
					ends[k] := pos;
					INC(k)
				END;
				it := it.next
			END;
			stream[pos] := 0X;
			low := MDSearch.Lower(stream^);
			mFirst := NIL; mLast := NIL; a := 0;
			p := MDSearch.IndexOf(low^, q^, 0);
			WHILE p >= 0 DO
				WHILE (a < k - 1) & (ends[a] <= p) DO INC(a) END;
				b := a;
				WHILE (b < k - 1) & (ends[b] < p + qlen) DO INC(b) END;
				NEW(m); m.first := items[a]; m.last := items[b]; m.y := items[a].y; m.next := NIL;
				IF mLast # NIL THEN mLast.next := m ELSE mFirst := m END;
				mLast := m;
				p := MDSearch.IndexOf(low^, q^, p + qlen)
			END;
			RETURN mFirst
		END Find;

		(** the y position of the heading with this anchor *)
		PROCEDURE FindAnchor*(CONST id: ARRAY OF CHAR; VAR top: SIZE): BOOLEAN;
		VAR a: Anchor;
		BEGIN
			a := anchors;
			WHILE (a # NIL) & ~(a.id^ = id) DO a := a.next END;
			IF a # NIL THEN top := a.y END;
			RETURN a # NIL
		END FindAnchor;

		(** the Copy button under a document point, or NIL *)
		PROCEDURE CopyAt*(px, py: SIZE): Item;
		VAR it: Item;
		BEGIN
			it := first;
			WHILE it # NIL DO
				IF (it.kind = ItemCopy) & (px >= it.x) & (px < it.x + it.w) & (py >= it.y) & (py < it.y + it.h) THEN
					RETURN it
				END;
				it := it.next
			END;
			RETURN NIL
		END CopyAt;

		(** the Link node under a document point, or NIL *)
		PROCEDURE LinkAt*(px, py: SIZE): MDTree.Node;
		VAR it: Item;
		BEGIN
			it := first;
			WHILE it # NIL DO
				IF (it.link # NIL) & (px >= it.x) & (px < it.x + it.w) & (py >= it.y) & (py < it.y + it.h) THEN
					RETURN it.link
				END;
				it := it.next
			END;
			RETURN NIL
		END LinkAt;
	END Layout;

BEGIN
	codeFontName := "Courier"
END MDLayout.
