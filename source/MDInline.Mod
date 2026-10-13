MODULE MDInline; (** AUTHOR "BohdanT"; PURPOSE: Inline parser of MD2AO: text of one block -> inline nodes of MDTree (CommonMark subset) *)

IMPORT MDTree;

(*
	Supported
	- backslash escapes of ASCII punctuation, "\" at the end of a line = hard break
	- code spans `a`, ``a ` b``
	- inline math $...$ and $$...$$ (MathInline; level = 1 or 2). "$" opens a formula only if the next
	  character is not a space; it closes at a "$" that has no space before it and no digit after it,
	  so "costs $5 and $6" stays plain text. Inside a formula nothing else is interpreted.
	- emphasis *a*, _a_, strong **a**, ***a*** (the CommonMark delimiter-run rules, UTF-8 aware)
	- inline links [text](dest "title") and images ![alt](dest "title"); links do not nest
	- autolinks <https://...> and <name@host>
	- soft breaks (line end) and hard breaks (two trailing spaces or "\")

	Not supported, by design: HTML, character entities (&amp;), reference-style links.
	Text is UTF-8 bytes; bytes >= 80X count as letters, except Latin-1 symbols (C2 xx) and
	general punctuation (E2 xx xx) which count as punctuation for the emphasis rules.
*)

TYPE
	Delim = OBJECT	(* one run of * or _ on the delimiter stack *)
	VAR
		node: MDTree.Node;	(* the Text node that holds the run *)
		ch: CHAR;
		count, orig: SIGNED32;	(* characters left / at the start *)
		canOpen, canClose: BOOLEAN;
		prev, next: Delim;
	END Delim;

	Bracket = OBJECT	(* an opening [ or ![ waiting for its ] *)
	VAR
		node: MDTree.Node;	(* the Text node "[" or "![" *)
		delim: Delim;	(* delimiter stack top when the bracket was opened *)
		prev: Bracket;
		image, active: BOOLEAN;
	END Bracket;

(* ---- character helpers ---- *)

PROCEDURE IsPunct(c: CHAR): BOOLEAN;
BEGIN
	RETURN ((c >= '!') & (c <= '/')) OR ((c >= ':') & (c <= '@')) OR ((c >= '[') & (c <= '`')) OR ((c >= '{') & (c <= '~'))
END IsPunct;

PROCEDURE IsSpaceCh(c: CHAR): BOOLEAN;
BEGIN
	RETURN (c = ' ') OR (c = 0AX) OR (c = 9X) OR (c = 0DX)
END IsSpaceCh;

PROCEDURE IsDigit(c: CHAR): BOOLEAN;
BEGIN
	RETURN (c >= '0') & (c <= '9')
END IsDigit;

PROCEDURE IsLetter(c: CHAR): BOOLEAN;
BEGIN
	RETURN ((c >= 'a') & (c <= 'z')) OR ((c >= 'A') & (c <= 'Z'))
END IsLetter;

(* characters that need individual handling; everything else is copied as plain text *)
PROCEDURE IsSpecial(c: CHAR): BOOLEAN;
BEGIN
	RETURN (c = 0AX) OR (c = '\') OR (c = '`') OR (c = '*') OR (c = '_') OR (c = '[') OR (c = ']')
		OR (c = '!') OR (c = '<') OR (c = '$')
END IsSpecial;

(* the character that starts at s[j]: 0 = white space (or end), 1 = punctuation, 2 = anything else *)
PROCEDURE ClassOf(CONST s: ARRAY OF CHAR; j: SIGNED32): SIGNED32;
VAR c: CHAR; r: SIGNED32;
BEGIN
	c := s[j]; r := 2;
	IF c = 0X THEN r := 0
	ELSIF IsSpaceCh(c) THEN r := 0
	ELSIF ORD(c) < 080H THEN
		IF IsPunct(c) THEN r := 1 END
	ELSIF ORD(c) = 0C2H THEN
		IF ORD(s[j + 1]) = 0A0H THEN r := 0 ELSE r := 1 END
	ELSIF ORD(c) = 0E2H THEN
		r := 1
	END;
	RETURN r
END ClassOf;

(* the character that ends just before s[i] *)
PROCEDURE ClassBefore(CONST s: ARRAY OF CHAR; i: SIGNED32): SIGNED32;
VAR j: SIGNED32;
BEGIN
	IF i <= 0 THEN RETURN 0 END;
	j := i - 1;
	WHILE (j > 0) & (ORD(s[j]) >= 080H) & (ORD(s[j]) < 0C0H) DO DEC(j) END;	(* back to the lead byte *)
	RETURN ClassOf(s, j)
END ClassBefore;

PROCEDURE Repeat(ch: CHAR; n: SIGNED32): MDTree.String;
VAR r: MDTree.String; i: SIGNED32;
BEGIN
	NEW(r, n + 1);
	FOR i := 0 TO n - 1 DO r[i] := ch END;
	r[n] := 0X;
	RETURN r
END Repeat;

(* s[from..to-1] as a new string *)
PROCEDURE Sub(CONST s: ARRAY OF CHAR; from, to: SIGNED32): MDTree.String;
VAR r: MDTree.String; i: SIGNED32;
BEGIN
	NEW(r, to - from + 1);
	FOR i := from TO to - 1 DO r[i - from] := s[i] END;
	r[to - from] := 0X;
	RETURN r
END Sub;

PROCEDURE AllSpaces(CONST s: ARRAY OF CHAR): BOOLEAN;
VAR i: SIGNED32;
BEGIN
	i := 0; WHILE s[i] = ' ' DO INC(i) END;
	RETURN s[i] = 0X
END AllSpaces;

PROCEDURE InsertAfter(ref, n: MDTree.Node);
VAR p: MDTree.Node;
BEGIN
	p := ref.parent;
	n.parent := p; n.prev := ref; n.next := ref.next;
	IF ref.next # NIL THEN ref.next.prev := n ELSE p.last := n END;
	ref.next := n
END InsertAfter;

(* joins neighbouring Text nodes and drops empty ones, also inside emphasis and links *)
PROCEDURE MergeText(n: MDTree.Node);
VAR c, nx: MDTree.Node;
BEGIN
	c := n.first;
	WHILE c # NIL DO
		nx := c.next;
		IF c.kind = MDTree.Text THEN
			WHILE (nx # NIL) & (nx.kind = MDTree.Text) DO
				IF nx.text # NIL THEN MDTree.AddText(c.text, nx.text^) END;
				MDTree.Unlink(nx);
				nx := c.next
			END;
			IF (c.text = NIL) OR (c.text[0] = 0X) THEN MDTree.Unlink(c) END
		ELSIF (c.kind = MDTree.Emph) OR (c.kind = MDTree.Strong) OR (c.kind = MDTree.Link) OR (c.kind = MDTree.Image) THEN
			MergeText(c)
		END;
		c := nx
	END
END MergeText;

(* ---- the parser ---- *)

TYPE
	Inliner = OBJECT
	VAR
		s: MDTree.String;
		pos: SIGNED32;
		parent: MDTree.Node;
		delims: Delim;	(* top of the delimiter stack *)
		brackets: Bracket;	(* top of the bracket stack *)

		PROCEDURE AddRun(from, to: SIGNED32);
		VAR n: MDTree.Node;
		BEGIN
			IF to > from THEN
				n := MDTree.NewNode(MDTree.Text); n.text := Sub(s^, from, to);
				MDTree.Append(parent, n)
			END
		END AddRun;

		PROCEDURE AddBreak(hard: BOOLEAN);
		BEGIN
			IF hard THEN MDTree.Append(parent, MDTree.NewNode(MDTree.HardBreak))
			ELSE MDTree.Append(parent, MDTree.NewNode(MDTree.SoftBreak))
			END
		END AddBreak;

		PROCEDURE HandleNewline;
		VAR last: MDTree.Node; n, k: SIGNED32; hard: BOOLEAN;
		BEGIN
			hard := FALSE;
			last := parent.last;
			IF (last # NIL) & (last.kind = MDTree.Text) & (last.text # NIL) THEN
				n := 0; WHILE last.text[n] # 0X DO INC(n) END;
				k := n; WHILE (k > 0) & (last.text[k - 1] = ' ') DO DEC(k) END;
				IF n - k >= 2 THEN hard := TRUE END;
				IF k < n THEN last.text[k] := 0X END	(* strip the trailing spaces *)
			END;
			INC(pos);
			WHILE s[pos] = ' ' DO INC(pos) END;	(* leading spaces of the next line *)
			AddBreak(hard)
		END HandleNewline;

		PROCEDURE HandleBackslash;
		BEGIN
			IF s[pos + 1] = 0AX THEN
				INC(pos, 2);
				WHILE s[pos] = ' ' DO INC(pos) END;
				AddBreak(TRUE)
			ELSIF IsPunct(s[pos + 1]) THEN
				AddRun(pos + 1, pos + 2); INC(pos, 2)
			ELSE
				AddRun(pos, pos + 1); INC(pos)
			END
		END HandleBackslash;

		PROCEDURE HandleBackticks;
		VAR start, n, i, j, k, m: SIGNED32; found: BOOLEAN; cs: MDTree.String; node: MDTree.Node;
		BEGIN
			start := pos; n := 0;
			WHILE s[pos] = '`' DO INC(pos); INC(n) END;
			i := pos; found := FALSE;
			WHILE ~found & (s[i] # 0X) DO	(* look for a closing run of exactly n backticks *)
				IF s[i] = '`' THEN
					j := i; WHILE s[j] = '`' DO INC(j) END;
					IF j - i = n THEN found := TRUE ELSE i := j END
				ELSE
					INC(i)
				END
			END;
			IF found THEN
				NEW(cs, i - pos + 1);
				k := 0;
				FOR m := pos TO i - 1 DO
					IF s[m] = 0AX THEN cs[k] := ' ' ELSE cs[k] := s[m] END;
					INC(k)
				END;
				cs[k] := 0X;
				IF (k >= 2) & (cs[0] = ' ') & (cs[k - 1] = ' ') & ~AllSpaces(cs^) THEN	(* strip one space on each side *)
					FOR m := 1 TO k - 2 DO cs[m - 1] := cs[m] END;
					cs[k - 2] := 0X
				END;
				node := MDTree.NewNode(MDTree.Code); node.text := cs;
				MDTree.Append(parent, node);
				pos := i + n
			ELSE
				AddRun(start, pos)	(* no closing run: the backticks are plain text *)
			END
		END HandleBackticks;

		PROCEDURE HandleDollar;
		VAR n, start, i: SIGNED32; ok: BOOLEAN; cs: MDTree.String; node: MDTree.Node; m: SIGNED32;
		BEGIN
			n := 1; IF s[pos + 1] = '$' THEN n := 2 END;
			start := pos + n;
			ok := FALSE;
			IF (s[start] # 0X) & (s[start] # ' ') & (s[start] # 0AX) THEN
				i := start;
				WHILE ~ok & (s[i] # 0X) DO
					IF (s[i] = '\') & (s[i + 1] # 0X) THEN
						INC(i, 2)
					ELSIF s[i] = '$' THEN
						IF n = 2 THEN
							ok := (i > start) & (s[i + 1] = '$')
						ELSE
							ok := (i > start) & (s[i - 1] # ' ') & (s[i - 1] # 0AX) & ~IsDigit(s[i + 1])
						END;
						IF ~ok THEN INC(i) END
					ELSE
						INC(i)
					END
				END
			END;
			IF ok THEN
				cs := Sub(s^, start, i);
				FOR m := 0 TO i - start - 1 DO IF cs[m] = 0AX THEN cs[m] := ' ' END END;
				node := MDTree.NewNode(MDTree.MathInline); node.text := cs; node.level := n;
				MDTree.Append(parent, node);
				pos := i + n
			ELSE
				AddRun(pos, pos + n); INC(pos, n)	(* a plain dollar sign *)
			END
		END HandleDollar;

		PROCEDURE PushDelim(node: MDTree.Node; ch: CHAR; n: SIGNED32; canOpen, canClose: BOOLEAN);
		VAR d: Delim;
		BEGIN
			NEW(d); d.node := node; d.ch := ch; d.count := n; d.orig := n;
			d.canOpen := canOpen; d.canClose := canClose;
			d.prev := delims; d.next := NIL;
			IF delims # NIL THEN delims.next := d END;
			delims := d
		END PushDelim;

		PROCEDURE RemoveDelim(d: Delim);
		BEGIN
			IF d.prev # NIL THEN d.prev.next := d.next END;
			IF d.next # NIL THEN d.next.prev := d.prev ELSE delims := d.prev END
		END RemoveDelim;

		PROCEDURE HandleDelim(ch: CHAR);
		VAR start, n, before, after: SIGNED32; left, right, canOpen, canClose: BOOLEAN; node: MDTree.Node;
		BEGIN
			start := pos; n := 0;
			WHILE s[pos] = ch DO INC(pos); INC(n) END;
			before := ClassBefore(s^, start); after := ClassOf(s^, pos);
			left := (after # 0) & ((after # 1) OR (before # 2));
			right := (before # 0) & ((before # 1) OR (after # 2));
			IF ch = '*' THEN
				canOpen := left; canClose := right
			ELSE
				canOpen := left & (~right OR (before = 1));
				canClose := right & (~left OR (after = 1))
			END;
			node := MDTree.NewNode(MDTree.Text); node.text := Repeat(ch, n);
			MDTree.Append(parent, node);
			IF canOpen OR canClose THEN PushDelim(node, ch, n, canOpen, canClose) END
		END HandleDelim;

		(* turns matching delimiter pairs above 'bottom' into Emph / Strong nodes (CommonMark algorithm) *)
		PROCEDURE ProcessEmphasis(bottom: Delim);
		VAR closer, opener, tmp: Delim; found, oddMatch: BOOLEAN; use: SIGNED32;
			openN, closeN, em, x, nx: MDTree.Node;
		BEGIN
			closer := delims;
			WHILE (closer # NIL) & (closer.prev # bottom) DO closer := closer.prev END;
			WHILE closer # NIL DO
				IF closer.canClose THEN
					opener := closer.prev; found := FALSE;
					WHILE ~found & (opener # NIL) & (opener # bottom) DO
						oddMatch := (closer.canOpen OR opener.canClose) & (closer.orig MOD 3 # 0)
							& ((opener.orig + closer.orig) MOD 3 = 0);
						IF (opener.ch = closer.ch) & opener.canOpen & ~oddMatch THEN
							found := TRUE
						ELSE
							opener := opener.prev
						END
					END;
					IF ~found THEN
						closer := closer.next
					ELSE
						IF (closer.count >= 2) & (opener.count >= 2) THEN use := 2 ELSE use := 1 END;
						openN := opener.node; closeN := closer.node;
						DEC(opener.count, use); DEC(closer.count, use);
						openN.text := Repeat(opener.ch, opener.count);
						closeN.text := Repeat(closer.ch, closer.count);
						IF use = 1 THEN em := MDTree.NewNode(MDTree.Emph) ELSE em := MDTree.NewNode(MDTree.Strong) END;
						x := openN.next;
						WHILE (x # NIL) & (x # closeN) DO
							nx := x.next; MDTree.Unlink(x); MDTree.Append(em, x); x := nx
						END;
						InsertAfter(openN, em);
						opener.next := closer; closer.prev := opener;	(* delimiters in between are used up *)
						IF opener.count = 0 THEN MDTree.Unlink(openN); RemoveDelim(opener) END;
						IF closer.count = 0 THEN
							MDTree.Unlink(closeN); tmp := closer.next; RemoveDelim(closer); closer := tmp
						END
					END
				ELSE
					closer := closer.next
				END
			END;
			WHILE (delims # NIL) & (delims # bottom) DO RemoveDelim(delims) END
		END ProcessEmphasis;

		(* ---- links and images ---- *)

		PROCEDURE PushBracket(node: MDTree.Node; image: BOOLEAN);
		VAR b: Bracket;
		BEGIN
			NEW(b); b.node := node; b.delim := delims; b.prev := brackets;
			b.image := image; b.active := TRUE;
			brackets := b
		END PushBracket;

		(* skips spaces and at most one line end; TRUE if anything was skipped *)
		PROCEDURE SkipSpnl(): BOOLEAN;
		VAR start: SIGNED32;
		BEGIN
			start := pos;
			WHILE s[pos] = ' ' DO INC(pos) END;
			IF s[pos] = 0AX THEN
				INC(pos);
				WHILE s[pos] = ' ' DO INC(pos) END
			END;
			RETURN pos > start
		END SkipSpnl;

		(* s[from..to-1] without the backslashes of escapes *)
		PROCEDURE Unescape(from, to: SIGNED32): MDTree.String;
		VAR r: MDTree.String; i, k: SIGNED32;
		BEGIN
			NEW(r, to - from + 1);
			k := 0; i := from;
			WHILE i < to DO
				IF (s[i] = '\') & (i + 1 < to) & IsPunct(s[i + 1]) THEN INC(i) END;
				r[k] := s[i]; INC(k); INC(i)
			END;
			r[k] := 0X;
			RETURN r
		END Unescape;

		PROCEDURE ParseDest(VAR dest: MDTree.String): BOOLEAN;
		VAR start, depth: SIGNED32; stop: BOOLEAN;
		BEGIN
			IF s[pos] = '<' THEN
				INC(pos); start := pos;
				WHILE (s[pos] # '>') & (s[pos] # 0X) & (s[pos] # 0AX) & (s[pos] # '<') DO
					IF (s[pos] = '\') & IsPunct(s[pos + 1]) THEN INC(pos, 2) ELSE INC(pos) END
				END;
				IF s[pos] # '>' THEN RETURN FALSE END;
				dest := Unescape(start, pos); INC(pos);
				RETURN TRUE
			END;
			start := pos; depth := 0; stop := FALSE;
			WHILE ~stop & (s[pos] # 0X) & (ORD(s[pos]) > 32) DO
				IF (s[pos] = '\') & IsPunct(s[pos + 1]) THEN
					INC(pos, 2)
				ELSIF s[pos] = '(' THEN
					INC(depth); INC(pos)
				ELSIF s[pos] = ')' THEN
					IF depth = 0 THEN stop := TRUE ELSE DEC(depth); INC(pos) END
				ELSE
					INC(pos)
				END
			END;
			IF depth # 0 THEN RETURN FALSE END;
			IF (pos = start) & (s[pos] # ')') THEN RETURN FALSE END;
			dest := Unescape(start, pos);
			RETURN TRUE
		END ParseDest;

		PROCEDURE ParseTitle(VAR title: MDTree.String): BOOLEAN;
		VAR open, close: CHAR; start: SIGNED32;
		BEGIN
			open := s[pos];
			IF open = '(' THEN close := ')' ELSE close := open END;
			INC(pos); start := pos;
			WHILE (s[pos] # 0X) & (s[pos] # close) DO
				IF (s[pos] = '\') & IsPunct(s[pos + 1]) THEN INC(pos, 2) ELSE INC(pos) END
			END;
			IF s[pos] # close THEN RETURN FALSE END;
			title := Unescape(start, pos); INC(pos);
			RETURN TRUE
		END ParseTitle;

		(* after "(": destination, optional title, ")" *)
		PROCEDURE ParseLinkTail(VAR dest, title: MDTree.String): BOOLEAN;
		VAR sp: BOOLEAN;
		BEGIN
			sp := SkipSpnl();
			IF ~ParseDest(dest) THEN RETURN FALSE END;
			sp := SkipSpnl();
			IF sp & ((s[pos] = '"') OR (s[pos] = "'") OR (s[pos] = '(')) THEN
				IF ~ParseTitle(title) THEN RETURN FALSE END;
				sp := SkipSpnl()
			END;
			IF s[pos] = ')' THEN INC(pos); RETURN TRUE END;
			RETURN FALSE
		END ParseLinkTail;

		PROCEDURE HandleOpenBracket;
		VAR node: MDTree.Node;
		BEGIN
			node := MDTree.NewTextNode(MDTree.Text, "[");
			MDTree.Append(parent, node);
			PushBracket(node, FALSE);
			INC(pos)
		END HandleOpenBracket;

		PROCEDURE HandleBang;
		VAR node: MDTree.Node;
		BEGIN
			IF s[pos + 1] = '[' THEN
				node := MDTree.NewTextNode(MDTree.Text, "![");
				MDTree.Append(parent, node);
				PushBracket(node, TRUE);
				INC(pos, 2)
			ELSE
				AddRun(pos, pos + 1); INC(pos)
			END
		END HandleBang;

		PROCEDURE HandleCloseBracket;
		VAR opener, b: Bracket; start, save: SIGNED32; matched, isImage: BOOLEAN;
			dest, title: MDTree.String; link, x, nx: MDTree.Node;
		BEGIN
			start := pos; INC(pos);
			opener := brackets;
			IF opener = NIL THEN AddRun(start, pos); RETURN END;
			IF ~opener.active THEN brackets := opener.prev; AddRun(start, pos); RETURN END;
			isImage := opener.image;
			matched := FALSE; dest := NIL; title := NIL;
			IF s[pos] = '(' THEN
				save := pos; INC(pos);
				matched := ParseLinkTail(dest, title);
				IF ~matched THEN pos := save END
			END;
			IF matched THEN
				IF isImage THEN link := MDTree.NewNode(MDTree.Image) ELSE link := MDTree.NewNode(MDTree.Link) END;
				link.dest := dest; link.title := title;
				x := opener.node.next;	(* everything after the opener becomes the content *)
				WHILE x # NIL DO
					nx := x.next; MDTree.Unlink(x); MDTree.Append(link, x); x := nx
				END;
				MDTree.Append(parent, link);
				ProcessEmphasis(opener.delim);
				brackets := opener.prev;
				MDTree.Unlink(opener.node);
				IF ~isImage THEN	(* links do not contain links *)
					b := brackets;
					WHILE b # NIL DO
						IF ~b.image THEN b.active := FALSE END;
						b := b.prev
					END
				END
			ELSE
				brackets := opener.prev;
				AddRun(start, pos)	(* plain "]" *)
			END
		END HandleCloseBracket;

		PROCEDURE HandleLess;
		VAR start, i, k: SIGNED32; ok, email: BOOLEAN; link, t: MDTree.Node; d, txt: MDTree.String;
		BEGIN
			start := pos + 1; i := start;
			WHILE (s[i] # 0X) & (s[i] # '>') & (s[i] # '<') & (ORD(s[i]) > 32) DO INC(i) END;
			ok := FALSE; email := FALSE;
			IF (s[i] = '>') & (i > start) THEN
				k := start;
				IF IsLetter(s[k]) THEN	(* scheme of 2..32 characters, then ":" *)
					WHILE IsLetter(s[k]) OR IsDigit(s[k]) OR (s[k] = '+') OR (s[k] = '.') OR (s[k] = '-') DO INC(k) END;
					IF (s[k] = ':') & (k - start >= 2) & (k - start <= 32) THEN ok := TRUE END
				END;
				IF ~ok THEN	(* e-mail: text@text, without ":" *)
					k := start;
					WHILE (k < i) & (s[k] # '@') & (s[k] # ':') DO INC(k) END;
					IF (s[k] = '@') & (k > start) & (k < i - 1) THEN ok := TRUE; email := TRUE END
				END
			END;
			IF ok THEN
				txt := Sub(s^, start, i);
				d := NIL;
				IF email THEN MDTree.AddText(d, "mailto:") END;
				MDTree.AddText(d, txt^);
				link := MDTree.NewNode(MDTree.Link); link.dest := d;
				t := MDTree.NewNode(MDTree.Text); t.text := txt;
				MDTree.Append(link, t);
				MDTree.Append(parent, link);
				pos := i + 1
			ELSE
				AddRun(pos, pos + 1); INC(pos)	(* a plain "<" *)
			END
		END HandleLess;

		(* ---- main loop ---- *)

		PROCEDURE Run;
		VAR c: CHAR; start: SIGNED32;
		BEGIN
			WHILE s[pos] # 0X DO
				c := s[pos];
				IF c = 0AX THEN HandleNewline
				ELSIF c = '\' THEN HandleBackslash
				ELSIF c = '`' THEN HandleBackticks
				ELSIF (c = '*') OR (c = '_') THEN HandleDelim(c)
				ELSIF c = '[' THEN HandleOpenBracket
				ELSIF c = '!' THEN HandleBang
				ELSIF c = ']' THEN HandleCloseBracket
				ELSIF c = '<' THEN HandleLess
				ELSIF c = '$' THEN HandleDollar
				ELSE
					start := pos; INC(pos);
					WHILE (s[pos] # 0X) & ~IsSpecial(s[pos]) DO INC(pos) END;
					AddRun(start, pos)
				END
			END;
			ProcessEmphasis(NIL);
			brackets := NIL
		END Run;

	END Inliner;

(** parses the inline content of a block (heading, paragraph, table cell) and appends the nodes to parent *)
PROCEDURE Parse*(parent: MDTree.Node; CONST text: ARRAY OF CHAR);
VAR p: Inliner;
BEGIN
	IF text[0] = 0X THEN RETURN END;
	NEW(p);
	p.s := MDTree.NewString(text); p.pos := 0; p.parent := parent;
	p.Run;
	MergeText(parent)
END Parse;

END MDInline.
