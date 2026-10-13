MODULE MDMath; (** AUTHOR "BohdanT"; PURPOSE: : typesetting of TeX formulas (a subset) into an image *)

IMPORT Commands, WMGraphics, WMRectangles, Raster, AAGraphics;

(*
	Typeset parses a formula and measures it; Render draws it into an image with a transparent background.
	Text comes from the fonts, strokes (fraction bars, radicals, big delimiters, sum and integral signs, arrows)
	are drawn anti-aliased with AAGraphics.

	Supported TeX
	- letters (italic), digits and the decimal point or comma between them, + - = < > ( ) [ ] , ; ! | / ' (primes)
	- indices and powers  x_1  x^2  x_{ab}^{2}  e^{j\omega t}
	- \frac{a}{b}  \sqrt{x}  \sqrt[3]{x}
	- Greek letters and symbols: \alpha .. \omega, \Gamma .. \Omega, \cdot \times \pm \leq \geq \neq \approx \to \infty \partial \nabla \circ ...
	- functions  \sin \cos \tan \ln \lg \log \exp \lim \max \min ...
	- \sum \prod \int with limits (_ and ^); in display formulas the limits of \sum and \prod are above and below
	- \left( ... \right) with ( ) [ ] \{ \} | \langle \rangle and . (nothing); the delimiters grow with the content
	- accents \vec \dot \ddot \hat \bar \overline \underline \tilde
	- \text{...} \mathrm{...} \mathbf{...} \mathit{...}
	- spaces \, \: \; \! \quad \qquad and "\ "
	Not supported: matrices, environments, \\ line breaks, \over and similar; a formula with an error is
	given back as NIL and the caller shows its text.

	Sizes: a formula is set in the style T (inline) or D (display); fractions, scripts, limits use smaller
	styles: 100% for D and T, 70% for script, 50% for script of script.
*)

CONST
	Pad* = 2;	(* free pixels around the formula in its image, for the anti-aliasing *)

	(* node kinds *)
	KSym = 0; KRow = 1; KScript = 2; KFrac = 3; KSqrt = 4; KBigOp = 5; KDelim = 6; KAccent = 7; KSpace = 8;

	(* classes of symbols: they decide the space around them *)
	COrd = 0; CBin = 1; CRel = 2; CPunct = 3; COpen = 4; CClose = 5; CFun = 6; COp = 7;

	(* styles of letters *)
	SRoman = 0; SItalic = 1; SBold = 2; SBoldItalic = 3;

	(* big operators *)
	OpSum = 0; OpProd = 1; OpInt = 2;

	(* accents *)
	AccVec = 0; AccDot = 1; AccDDot = 2; AccHat = 3; AccBar = 4; AccTilde = 5; AccUnder = 6;

	(* delimiters that have no character of their own *)
	DLangle = 1000; DRangle = 1001;

	(* symbols: name=code in hex, /b = binary operator, /r = relation *)
	Sym1 = "alpha=3B1 beta=3B2 gamma=3B3 delta=3B4 epsilon=3B5 varepsilon=3B5 zeta=3B6 eta=3B7 theta=3B8 vartheta=3B8";
	Sym2 = "iota=3B9 kappa=3BA lambda=3BB mu=3BC nu=3BD xi=3BE pi=3C0 varpi=3C0 rho=3C1 varrho=3C1 sigma=3C3 varsigma=3C3";
	Sym3 = "tau=3C4 upsilon=3C5 phi=3C6 varphi=3C6 chi=3C7 psi=3C8 omega=3C9 Gamma=393 Delta=394 Theta=398 Lambda=39B";
	Sym4 = "Xi=39E Pi=3A0 Sigma=3A3 Upsilon=3A5 Phi=3A6 Psi=3A8 Omega=3A9 cdot=B7/b times=D7/b div=F7/b pm=B1/b mp=2213/b";
	Sym5 = "ast=2217/b star=22C6/b circ=B0 degree=B0 bullet=2022/b cap=2229/b cup=222A/b setminus=2216/b";
	Sym6 = "leq=2264/r le=2264/r geq=2265/r ge=2265/r neq=2260/r ne=2260/r approx=2248/r equiv=2261/r sim=223C/r";
	Sym7 = "simeq=2243/r propto=221D/r ll=226A/r gg=226B/r in=2208/r subset=2282/r subseteq=2286/r perp=22A5/r parallel=2225/r";
	Sym8 = "to=2192/r rightarrow=2192/r leftarrow=2190/r gets=2190/r leftrightarrow=2194/r Rightarrow=21D2/r Leftarrow=21D0/r";
	Sym9 = "Leftrightarrow=21D4/r iff=21D4/r implies=21D2/r mapsto=21A6/r uparrow=2191 downarrow=2193";
	Sym10 = "infty=221E partial=2202 nabla=2207 angle=2220 ldots=2026 dots=2026 cdots=2026 forall=2200 exists=2203 neg=AC";
	Sym11 = "emptyset=2205 prime=2032 hbar=210F ell=2113 aleph=2135";

	Funcs = "sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh coth ln lg log exp lim max min sup inf det dim ker arg gcd Re Im deg";

	(* the paths of big delimiters and signs: pairs x y in 0..100 of the box (left delimiter; right ones are mirrored) *)
	PathParen = "85 0 50 7 28 20 16 38 12 50 16 62 28 80 50 93 85 100";
	PathBrace = "80 0 58 3 50 12 50 38 38 47 18 50 38 53 50 62 50 88 58 97 80 100";
	PathBracket = "80 0 20 0 20 100 80 100";
	PathAngle = "80 0 20 50 80 100";
	PathBar = "50 0 50 100";
	PathInt = "10 90 18 100 32 95 40 75 50 50 60 25 68 5 78 0 90 6 95 18";
	PathTilde = "5 65 28 25 50 50 72 80 95 40";

TYPE
	String = POINTER TO ARRAY OF CHAR;

	Node = OBJECT
	VAR
		kind, cl, style, op: SIGNED32;	(* op: big operator, accent, delimiter mode or width of a space (1/18 em) *)
		s: String;	(* KSym: the text *)
		next, first: Node;	(* first: children of a row *)
		a, b, c: Node;	(* operands: base / numerator, denominator / body, index; sub, sup of scripts *)
		left, right: SIGNED32;	(* KDelim: the delimiters, 0 = none *)
		font: WMGraphics.Font;	(* KSym *)
		em: SIZE;	(* font size of the node *)
		(* layout: the size of the node and its place in the parent: dx to the right, dy down from the baseline *)
		w, asc, desc, dx, dy: SIZE;
		(* geometry that depends on the kind, see the Layout procedures *)
		x1, y1, x2, y2, w1, w2, t: SIZE;
	END Node;

	(** a typeset formula *)
	Formula* = OBJECT
	VAR
		root: Node;
		width*, ascent*, descent*: SIZE;	(* the box of the formula; the baseline is ascent below its top *)
	END Formula;

	Env = OBJECT	(* fonts of the formula *)
	VAR
		name: ARRAY 128 OF CHAR;
		size: SIZE;
		fonts: ARRAY 12 OF WMGraphics.Font;	(* level * 4 + letter style *)

		PROCEDURE Get(style, level: SIGNED32): WMGraphics.Font;
		VAR st: SET; px: SIZE;
		BEGIN
			IF fonts[level * 4 + style] = NIL THEN
				px := size * Pct(level) DIV 100;
				IF px < 6 THEN px := 6 END;
				st := {};
				IF (style = SBold) OR (style = SBoldItalic) THEN INCL(st, WMGraphics.FontBold) END;
				IF (style = SItalic) OR (style = SBoldItalic) THEN INCL(st, WMGraphics.FontItalic) END;
				fonts[level * 4 + style] := WMGraphics.GetFont(name, px, st)
			END;
			RETURN fonts[level * 4 + style]
		END Get;
	END Env;

	Ctx = OBJECT	(* what Draw draws on *)
	VAR
		img: Raster.Image;
		canvas: WMGraphics.BufferCanvas;
		color: WMGraphics.Color;
	END Ctx;

(* ---------- small helpers ---------- *)

PROCEDURE IsLetter(c: CHAR): BOOLEAN;
BEGIN
	RETURN ((c >= 'a') & (c <= 'z')) OR ((c >= 'A') & (c <= 'Z'))
END IsLetter;

PROCEDURE IsDigit(c: CHAR): BOOLEAN;
BEGIN
	RETURN (c >= '0') & (c <= '9')
END IsDigit;

PROCEDURE IsSpace(c: CHAR): BOOLEAN;
BEGIN
	RETURN (c = ' ') OR (c = 0AX) OR (c = 9X) OR (c = 0DX)
END IsSpace;

PROCEDURE HexVal(c: CHAR): SIGNED32;
VAR r: SIGNED32;
BEGIN
	r := -1;
	IF (c >= '0') & (c <= '9') THEN r := ORD(c) - ORD('0')
	ELSIF (c >= 'A') & (c <= 'F') THEN r := ORD(c) - ORD('A') + 10
	END;
	RETURN r
END HexVal;

(* is word one of the words of list? *)
PROCEDURE InList(CONST list, word: ARRAY OF CHAR): BOOLEAN;
VAR i, j: SIGNED32;
BEGIN
	i := 0;
	WHILE list[i] # 0X DO
		j := 0;
		WHILE (word[j] # 0X) & (list[i + j] = word[j]) DO INC(j) END;
		IF (word[j] = 0X) & ((list[i + j] = ' ') OR (list[i + j] = 0X)) THEN RETURN TRUE END;
		WHILE (list[i] # ' ') & (list[i] # 0X) DO INC(i) END;
		WHILE list[i] = ' ' DO INC(i) END
	END;
	RETURN FALSE
END InList;

(* the entry name=code[/class] in a list of symbols *)
PROCEDURE LookIn(CONST list, name: ARRAY OF CHAR; VAR code, cl: SIGNED32): BOOLEAN;
VAR i, j: SIGNED32;
BEGIN
	i := 0;
	WHILE list[i] # 0X DO
		j := 0;
		WHILE (name[j] # 0X) & (list[i + j] = name[j]) DO INC(j) END;
		IF (name[j] = 0X) & (list[i + j] = '=') THEN
			i := i + j + 1; code := 0;
			WHILE HexVal(list[i]) >= 0 DO code := code * 16 + HexVal(list[i]); INC(i) END;
			cl := COrd;
			IF list[i] = '/' THEN
				IF list[i + 1] = 'b' THEN cl := CBin ELSIF list[i + 1] = 'r' THEN cl := CRel END
			END;
			RETURN TRUE
		END;
		WHILE (list[i] # ' ') & (list[i] # 0X) DO INC(i) END;
		WHILE list[i] = ' ' DO INC(i) END
	END;
	RETURN FALSE
END LookIn;

PROCEDURE LookupSym(CONST name: ARRAY OF CHAR; VAR code, cl: SIGNED32): BOOLEAN;
BEGIN
	RETURN LookIn(Sym1, name, code, cl) OR LookIn(Sym2, name, code, cl) OR LookIn(Sym3, name, code, cl)
		OR LookIn(Sym4, name, code, cl) OR LookIn(Sym5, name, code, cl) OR LookIn(Sym6, name, code, cl)
		OR LookIn(Sym7, name, code, cl) OR LookIn(Sym8, name, code, cl) OR LookIn(Sym9, name, code, cl)
		OR LookIn(Sym10, name, code, cl) OR LookIn(Sym11, name, code, cl)
END LookupSym;

PROCEDURE NewStr(CONST t: ARRAY OF CHAR): String;
VAR r: String; n: SIGNED32;
BEGIN
	n := 0; WHILE t[n] # 0X DO INC(n) END;
	NEW(r, n + 1);
	COPY(t, r^);
	RETURN r
END NewStr;

(* the code point as UTF-8 *)
PROCEDURE PutCode(code: SIGNED32; VAR s: ARRAY OF CHAR);
BEGIN
	IF code < 080H THEN
		s[0] := CHR(code); s[1] := 0X
	ELSIF code < 0800H THEN
		s[0] := CHR(0C0H + code DIV 040H); s[1] := CHR(080H + code MOD 040H); s[2] := 0X
	ELSE
		s[0] := CHR(0E0H + code DIV 01000H); s[1] := CHR(080H + (code DIV 040H) MOD 040H);
		s[2] := CHR(080H + code MOD 040H); s[3] := 0X
	END
END PutCode;

PROCEDURE NewNode(kind: SIGNED32): Node;
VAR n: Node;
BEGIN
	NEW(n); n.kind := kind; n.cl := COrd; n.style := SRoman;
	RETURN n
END NewNode;

PROCEDURE NewSym(CONST text: ARRAY OF CHAR; cl, style: SIGNED32): Node;
VAR n: Node;
BEGIN
	n := NewNode(KSym); n.s := NewStr(text); n.cl := cl; n.style := style;
	RETURN n
END NewSym;

PROCEDURE NewSymCode(code, cl, style: SIGNED32): Node;
VAR t: ARRAY 8 OF CHAR;
BEGIN
	PutCode(code, t);
	RETURN NewSym(t, cl, style)
END NewSymCode;

PROCEDURE NewSpace(units: SIGNED32): Node;
VAR n: Node;
BEGIN
	n := NewNode(KSpace); n.op := units;
	RETURN n
END NewSpace;

(* parses "12 40 ..." into p, returns the number of points *)
PROCEDURE Numbers(CONST s: ARRAY OF CHAR; VAR p: ARRAY OF SIZE): SIGNED32;
VAR i, n: SIGNED32; v: SIZE;
BEGIN
	i := 0; n := 0;
	WHILE s[i] # 0X DO
		WHILE s[i] = ' ' DO INC(i) END;
		IF IsDigit(s[i]) THEN
			v := 0;
			WHILE IsDigit(s[i]) DO v := v * 10 + (ORD(s[i]) - ORD('0')); INC(i) END;
			p[n] := v; INC(n)
		ELSIF s[i] # 0X THEN
			INC(i)
		END
	END;
	RETURN n DIV 2
END Numbers;

(* ---------- sizes ---------- *)

(* the styles: 0 display, 1 text, 2 script, 3 script of script *)
PROCEDURE LevelOf(sty: SIGNED32): SIGNED32;
BEGIN
	IF sty <= 1 THEN RETURN 0 ELSIF sty = 2 THEN RETURN 1 ELSE RETURN 2 END
END LevelOf;

PROCEDURE Pct(level: SIGNED32): SIGNED32;
BEGIN
	IF level = 0 THEN RETURN 100 ELSIF level = 1 THEN RETURN 70 ELSE RETURN 50 END
END Pct;

PROCEDURE ScriptSty(sty: SIGNED32): SIGNED32;
BEGIN
	IF sty <= 1 THEN RETURN 2 ELSE RETURN 3 END
END ScriptSty;

PROCEDURE FracSty(sty: SIGNED32): SIGNED32;
BEGIN
	IF sty = 0 THEN RETURN 1 ELSIF sty = 1 THEN RETURN 2 ELSE RETURN 3 END
END FracSty;

PROCEDURE Em(env: Env; sty: SIGNED32): SIZE;
VAR px: SIZE;
BEGIN
	px := env.size * Pct(LevelOf(sty)) DIV 100;
	IF px < 6 THEN px := 6 END;
	RETURN px
END Em;

(* the class of the left and of the right edge of a node, for the spaces *)
PROCEDURE ClassOf(n: Node): SIGNED32;
VAR r: SIGNED32;
BEGIN
	r := COrd;
	IF n.kind = KSym THEN r := n.cl
	ELSIF n.kind = KScript THEN r := ClassOf(n.a)
	END;
	RETURN r
END ClassOf;

(* space between two neighbours of a row, in 1/18 em *)
PROCEDURE Gap(l, r: SIGNED32): SIGNED32;
VAR u: SIGNED32;
BEGIN
	u := 0;
	IF (l = CBin) OR (r = CBin) THEN u := 4
	ELSIF (l = CRel) OR (r = CRel) THEN u := 5
	ELSIF l = CPunct THEN u := 3
	ELSIF ((l = CFun) OR (l = COp)) & (r # COpen) THEN u := 3
	ELSIF ((r = CFun) OR (r = COp)) & (l # COpen) THEN u := 3
	END;
	RETURN u
END Gap;

(* how far the ink of a node reaches above and below the baseline. A glyph box is taller than its ink,
   and the gaps of fractions, scripts and radicals must be measured from the ink. *)
PROCEDURE InkAsc(n: Node): SIZE;
VAR c: Node; r, v: SIZE;
BEGIN
	r := n.asc;
	CASE n.kind OF
		KSym:
			IF n.s[0] = 0X THEN r := 0
			ELSIF (n.cl = COpen) OR (n.cl = CClose) THEN r := n.em * 78 DIV 100
			ELSE r := n.em * 68 DIV 100
			END
		|KSpace: r := 0
		|KRow:
			r := 0; c := n.first;
			WHILE c # NIL DO
				v := InkAsc(c) - c.dy;
				IF v > r THEN r := v END;
				c := c.next
			END
		|KScript:
			r := InkAsc(n.a);
			IF n.c # NIL THEN
				v := InkAsc(n.c) - n.c.dy;
				IF v > r THEN r := v END
			END
	ELSE
	END;
	RETURN r
END InkAsc;

PROCEDURE InkDesc(n: Node): SIZE;
VAR c: Node; r, v: SIZE;
BEGIN
	r := n.desc;
	CASE n.kind OF
		KSym:
			IF (n.cl = COpen) OR (n.cl = CClose) THEN r := n.em * 22 DIV 100 ELSE r := 0 END
		|KSpace: r := 0
		|KRow:
			r := 0; c := n.first;
			WHILE c # NIL DO
				v := InkDesc(c) + c.dy;
				IF v > r THEN r := v END;
				c := c.next
			END
		|KScript:
			r := InkDesc(n.a);
			IF n.b # NIL THEN
				v := InkDesc(n.b) + n.b.dy;
				IF v > r THEN r := v END
			END
	ELSE
	END;
	RETURN r
END InkDesc;

(* ---------- layout ---------- *)

PROCEDURE LayoutSym(env: Env; n: Node; sty: SIGNED32);
VAR h: SIZE; minus: ARRAY 8 OF CHAR;
BEGIN
	n.em := Em(env, sty);
	n.font := env.Get(n.style, LevelOf(sty));
	IF (n.s[0] = '-') & (n.s[1] = 0X) & n.font.HasChar(02212H) THEN	(* a real minus sign if the font has it *)
		PutCode(02212H, minus); n.s := NewStr(minus)
	END;
	n.font.GetStringSize(n.s^, n.w, h);
	n.asc := n.font.GetAscent(); n.desc := n.font.GetDescent()
END LayoutSym;

PROCEDURE LayoutSpace(env: Env; n: Node; sty: SIGNED32);
BEGIN
	n.em := Em(env, sty);
	n.w := n.em * n.op DIV 18; n.asc := 0; n.desc := 0
END LayoutSpace;

PROCEDURE LayoutRow(env: Env; n: Node; sty: SIGNED32);
VAR c, prev, nx: Node; x, asc, desc, em: SIZE; pcl, ccl: SIGNED32;
BEGIN
	em := Em(env, sty); n.em := em;
	c := n.first;
	WHILE c # NIL DO Layout(env, c, sty); c := c.next END;
	(* a sign at the start, after an operator or before a relation is not a binary operator *)
	prev := NIL; c := n.first;
	WHILE c # NIL DO
		IF (c.kind = KSym) & (c.cl = CBin) THEN
			IF prev = NIL THEN
				c.cl := COrd
			ELSE
				pcl := ClassOf(prev);
				IF (pcl = CBin) OR (pcl = CRel) OR (pcl = COpen) OR (pcl = CPunct) OR (pcl = COp) OR (pcl = CFun) THEN
					c.cl := COrd
				END
			END
		END;
		prev := c; c := c.next
	END;
	c := n.first;
	WHILE c # NIL DO
		nx := c.next;
		IF (c.kind = KSym) & (c.cl = CBin) & (nx # NIL) THEN
			ccl := ClassOf(nx);
			IF (ccl = CRel) OR (ccl = CClose) OR (ccl = CPunct) THEN c.cl := COrd END
		END;
		c := nx
	END;
	x := 0; asc := 0; desc := 0; prev := NIL; c := n.first;
	WHILE c # NIL DO
		IF (prev # NIL) & (sty < 2) THEN INC(x, em * Gap(ClassOf(prev), ClassOf(c)) DIV 18) END;
		c.dx := x; c.dy := 0;
		INC(x, c.w);
		asc := MAX(asc, c.asc); desc := MAX(desc, c.desc);
		prev := c; c := c.next
	END;
	n.w := x; n.asc := asc; n.desc := desc
END LayoutRow;

(* how far a superscript goes up and a subscript down; h and dp: the ink of the base above and below the baseline *)
PROCEDURE ScriptShifts(h, dp: SIZE; sub, sup: Node; emB, emS: SIZE; VAR up, down: SIZE);
VAR gap: SIZE;
BEGIN
	up := 0; down := 0;
	IF sup # NIL THEN
		up := MAX(emB * 41 DIV 100, h - emS * 27 DIV 100);
		up := MAX(up, InkDesc(sup) + emS * 20 DIV 100)
	END;
	IF sub # NIL THEN
		IF sup = NIL THEN
			down := MAX(emB * 15 DIV 100, InkAsc(sub) - emB * 34 DIV 100)
		ELSE
			down := MAX(emB * 25 DIV 100, dp + emS * 10 DIV 100);
			gap := (up - InkDesc(sup)) - (InkAsc(sub) - down);
			IF gap < emB * 20 DIV 100 THEN INC(down, emB * 20 DIV 100 - gap) END
		END;
		down := MAX(down, dp + emS * 5 DIV 100)
	END
END ScriptShifts;

PROCEDURE LayoutScript(env: Env; n: Node; sty: SIGNED32);
VAR ss: SIGNED32; emB, emS, up, down, kern, x, w, asc, desc: SIZE;
BEGIN
	ss := ScriptSty(sty);
	emB := Em(env, sty); emS := Em(env, ss); n.em := emB;
	Layout(env, n.a, sty);
	IF n.b # NIL THEN Layout(env, n.b, ss) END;
	IF n.c # NIL THEN Layout(env, n.c, ss) END;
	ScriptShifts(InkAsc(n.a), InkDesc(n.a), n.b, n.c, emB, emS, up, down);
	kern := MAX(1, emB * 3 DIV 100);
	x := n.a.w + kern;
	n.a.dx := 0; n.a.dy := 0;
	w := n.a.w; asc := n.a.asc; desc := n.a.desc;
	IF n.c # NIL THEN
		n.c.dx := x; n.c.dy := -up;
		w := MAX(w, x + n.c.w); asc := MAX(asc, up + n.c.asc); desc := MAX(desc, n.c.desc - up)
	END;
	IF n.b # NIL THEN
		n.b.dx := x; n.b.dy := down;
		w := MAX(w, x + n.b.w); desc := MAX(desc, down + n.b.desc); asc := MAX(asc, n.b.asc - down)
	END;
	n.w := w; n.asc := asc; n.desc := desc
END LayoutScript;

(* a / b: y1 = the top of the bar, t = its thickness (relative to the baseline) *)
PROCEDURE LayoutFrac(env: Env; n: Node; sty: SIGNED32);
VAR fs: SIGNED32; em, axis, t, gap, pad, y0, w: SIZE;
BEGIN
	fs := FracSty(sty);
	em := Em(env, sty); n.em := em; axis := em * 25 DIV 100;
	Layout(env, n.a, fs); Layout(env, n.b, fs);
	t := MAX(1, em DIV 14);
	IF sty = 0 THEN gap := MAX(2, em * 14 DIV 100) ELSE gap := MAX(2, em * 9 DIV 100) END;
	pad := MAX(1, em * 8 DIV 100);
	y0 := -axis - t DIV 2;
	n.y1 := y0; n.t := t;
	n.a.dy := y0 - gap - InkDesc(n.a);
	n.b.dy := y0 + t + gap + InkAsc(n.b);
	w := MAX(n.a.w, n.b.w) + 2 * pad;
	n.a.dx := (w - n.a.w) DIV 2; n.b.dx := (w - n.b.w) DIV 2;
	n.w := w;
	n.asc := MAX(-n.a.dy + n.a.asc, axis + t);
	n.desc := MAX(n.b.dy + n.b.desc, t)
END LayoutFrac;

(* a radical: x1 = where its sign starts, w1 = the width of the sign, y1 = the top of the bar,
   y2 = the bottom of the sign, t = the thickness of the bar *)
PROCEDURE LayoutSqrt(env: Env; n: Node; sty: SIGNED32);
VAR em, t, gap, rw, pad, xRad, idxW, h: SIZE;
BEGIN
	em := Em(env, sty); n.em := em;
	Layout(env, n.a, sty);
	t := MAX(1, em DIV 14);
	gap := MAX(2, em * 10 DIV 100);
	rw := MAX(8, em * 65 DIV 100);
	pad := MAX(1, em * 5 DIV 100);
	idxW := 0;
	IF n.b # NIL THEN Layout(env, n.b, 3); idxW := n.b.w END;
	xRad := MAX(0, idxW - rw * 40 DIV 100);
	n.x1 := xRad; n.w1 := rw; n.t := t;
	n.a.dx := xRad + rw + pad; n.a.dy := 0;
	n.w := n.a.dx + n.a.w + pad;
	n.y1 := -(InkAsc(n.a) + gap + t);
	n.y2 := n.a.desc;
	n.asc := MAX(-n.y1, n.a.asc); n.desc := n.y2;
	IF n.b # NIL THEN
		h := n.y2 - n.y1;
		n.b.dx := 0; n.b.dy := n.y2 - h * 55 DIV 100 - n.b.desc;
		n.asc := MAX(n.asc, -n.b.dy + n.b.asc)
	END
END LayoutSqrt;

(* a big operator: w1 x y1 is the size of its sign, x1 and y2 its place (relative to the baseline) *)
PROCEDURE LayoutBigOp(env: Env; n: Node; sty: SIGNED32);
VAR ss: SIGNED32; em, axis, h, w, opAsc, opDesc, gap, up, down, kern, x, wt, asc, desc: SIZE; limits: BOOLEAN;
BEGIN
	em := Em(env, sty); n.em := em; axis := em * 25 DIV 100;
	IF sty = 0 THEN h := em * 145 DIV 100 ELSE h := em * 115 DIV 100 END;
	IF n.op = OpInt THEN w := h * 42 DIV 100 ELSE w := h * 68 DIV 100 END;
	opAsc := h DIV 2 + axis; opDesc := h - opAsc;
	n.w1 := w; n.y1 := h; n.y2 := -opAsc; n.x1 := 0;
	ss := ScriptSty(sty);
	IF n.b # NIL THEN Layout(env, n.b, ss) END;
	IF n.c # NIL THEN Layout(env, n.c, ss) END;
	limits := (n.op # OpInt) & (sty = 0) & ((n.b # NIL) OR (n.c # NIL));
	asc := opAsc; desc := opDesc;
	IF limits THEN	(* above and below *)
		gap := MAX(2, em * 12 DIV 100);
		wt := w;
		IF n.b # NIL THEN wt := MAX(wt, n.b.w) END;
		IF n.c # NIL THEN wt := MAX(wt, n.c.w) END;
		n.x1 := (wt - w) DIV 2;
		IF n.c # NIL THEN
			n.c.dx := (wt - n.c.w) DIV 2; n.c.dy := -(opAsc + gap + InkDesc(n.c));
			asc := opAsc + gap + InkDesc(n.c) + n.c.asc
		END;
		IF n.b # NIL THEN
			n.b.dx := (wt - n.b.w) DIV 2; n.b.dy := opDesc + gap + InkAsc(n.b);
			desc := opDesc + gap + InkAsc(n.b) + n.b.desc
		END;
		n.w := wt
	ELSE	(* at the side *)
		kern := MAX(1, em * 5 DIV 100);
		IF n.op = OpInt THEN INC(kern, em * 8 DIV 100) END;
		ScriptShifts(opAsc, opDesc, n.b, n.c, em, Em(env, ss), up, down);
		x := w + kern; wt := w;
		IF n.c # NIL THEN
			n.c.dx := x; n.c.dy := -up;
			wt := MAX(wt, x + n.c.w); asc := MAX(asc, up + n.c.asc)
		END;
		IF n.b # NIL THEN
			n.b.dx := x; n.b.dy := down;
			wt := MAX(wt, x + n.b.w); desc := MAX(desc, down + n.b.desc)
		END;
		n.w := wt
	END;
	n.asc := asc; n.desc := desc
END LayoutBigOp;

PROCEDURE NeedsDrawing(code: SIGNED32): BOOLEAN;
BEGIN
	RETURN (code = DLangle) OR (code = DRangle)
END NeedsDrawing;

PROCEDURE DelimWidth(code: SIGNED32; dh, em: SIZE): SIZE;
VAR w: SIZE;
BEGIN
	w := 0;
	IF code = 0 THEN w := 0
	ELSIF (code = ORD('(')) OR (code = ORD(')')) THEN w := MIN(MAX(em * 30 DIV 100, dh DIV 11), em * 55 DIV 100)
	ELSIF (code = ORD('[')) OR (code = ORD(']')) THEN w := MIN(MAX(em * 28 DIV 100, dh DIV 16), em * 40 DIV 100)
	ELSIF (code = ORD('{')) OR (code = ORD('}')) THEN w := MIN(MAX(em * 40 DIV 100, dh DIV 12), em * 55 DIV 100)
	ELSIF code = ORD('|') THEN w := MAX(3, em * 20 DIV 100)
	ELSE w := MIN(MAX(em * 38 DIV 100, dh DIV 12), em * 55 DIV 100)
	END;
	RETURN w
END DelimWidth;

(* \left ... \right. Small content: the delimiters are glyphs (children b and c); otherwise (op = 1) they are
   drawn: w1, w2 = their widths, x2 = the place of the right one, y1 = their top, t = their height *)
PROCEDURE LayoutDelim(env: Env; n: Node; sty: SIGNED32);
VAR em, axis, h, dh, normal, pd, asc, desc: SIZE;
BEGIN
	em := Em(env, sty); n.em := em; axis := em * 25 DIV 100;
	Layout(env, n.a, sty);
	h := MAX(MAX(InkAsc(n.a) - axis, InkDesc(n.a) + axis), 0);
	dh := 2 * h + em * 8 DIV 100;
	normal := em * 110 DIV 100;
	pd := MAX(1, em * 6 DIV 100);
	n.op := 0;
	IF (dh > normal * 115 DIV 100) OR NeedsDrawing(n.left) OR NeedsDrawing(n.right) THEN n.op := 1 END;
	IF n.op = 1 THEN
		dh := MAX(dh, normal);
		n.w1 := DelimWidth(n.left, dh, em); n.w2 := DelimWidth(n.right, dh, em);
		n.y1 := -axis - dh DIV 2; n.t := dh;
		n.a.dx := n.w1 + pd; n.a.dy := 0;
		n.x2 := n.w1 + pd + n.a.w + pd;
		n.w := n.x2 + n.w2;
		n.asc := MAX(n.a.asc, axis + dh DIV 2);
		n.desc := MAX(n.a.desc, dh - dh DIV 2 - axis)
	ELSE
		n.b := NIL; n.c := NIL;
		IF n.left # 0 THEN n.b := NewSymCode(n.left, COpen, SRoman); Layout(env, n.b, sty) END;
		IF n.right # 0 THEN n.c := NewSymCode(n.right, CClose, SRoman); Layout(env, n.c, sty) END;
		n.a.dx := 0; asc := n.a.asc; desc := n.a.desc;
		IF n.b # NIL THEN n.b.dx := 0; n.b.dy := 0; n.a.dx := n.b.w; asc := MAX(asc, n.b.asc); desc := MAX(desc, n.b.desc) END;
		n.x2 := n.a.dx + n.a.w;
		IF n.c # NIL THEN n.c.dx := n.x2; n.c.dy := 0; n.w := n.x2 + n.c.w; asc := MAX(asc, n.c.asc); desc := MAX(desc, n.c.desc)
		ELSE n.w := n.x2
		END;
		n.asc := asc; n.desc := desc
	END
END LayoutDelim;

(* an accent: y1 = the middle line of the accent above (or the line below), t = its height *)
PROCEDURE LayoutAccent(env: Env; n: Node; sty: SIGNED32);
VAR em, gap, h, ink: SIZE;
BEGIN
	em := Em(env, sty); n.em := em;
	Layout(env, n.a, sty);
	n.a.dx := 0; n.a.dy := 0;
	n.w := n.a.w; n.asc := n.a.asc; n.desc := n.a.desc;
	gap := MAX(2, em * 8 DIV 100);
	IF n.op = AccUnder THEN
		n.y1 := MAX(InkDesc(n.a), 0) + gap;
		n.t := 1;
		n.desc := MAX(n.desc, n.y1 + 2)
	ELSE
		CASE n.op OF
			AccVec: h := em * 22 DIV 100
			|AccDot, AccDDot: h := MAX(2, em * 10 DIV 100)
			|AccHat: h := em * 18 DIV 100
			|AccTilde: h := em * 14 DIV 100
		ELSE
			h := 2
		END;
		h := MAX(h, 2);
		ink := InkAsc(n.a);
		n.t := h;
		n.y1 := -(ink + gap + h DIV 2);
		n.asc := MAX(n.asc, ink + gap + h + 1)
	END
END LayoutAccent;

PROCEDURE Layout(env: Env; n: Node; sty: SIGNED32);
BEGIN
	CASE n.kind OF
		KSym: LayoutSym(env, n, sty)
		|KRow: LayoutRow(env, n, sty)
		|KScript: LayoutScript(env, n, sty)
		|KFrac: LayoutFrac(env, n, sty)
		|KSqrt: LayoutSqrt(env, n, sty)
		|KBigOp: LayoutBigOp(env, n, sty)
		|KDelim: LayoutDelim(env, n, sty)
		|KAccent: LayoutAccent(env, n, sty)
		|KSpace: LayoutSpace(env, n, sty)
	ELSE
	END
END Layout;

(* ---------- drawing ---------- *)

PROCEDURE Light(em: SIZE): FLOAT32;
VAR r: FLOAT32;
BEGIN
	IF em < 18 THEN r := 1.0 ELSIF em < 28 THEN r := 1.3 ELSE r := 1.7 END;
	RETURN r
END Light;

PROCEDURE Heavy(em: SIZE): FLOAT32;
VAR r: FLOAT32;
BEGIN
	IF em < 18 THEN r := 1.6 ELSIF em < 28 THEN r := 2.2 ELSE r := 2.8 END;
	RETURN r
END Heavy;

PROCEDURE Line(ctx: Ctx; x0, y0, x1, y1: SIZE; th: FLOAT32);
BEGIN
	AAGraphics.AALineW(ctx.img, SIGNED32(x0), SIGNED32(y0), SIGNED32(x1), SIGNED32(y1), ctx.color, th)
END Line;

PROCEDURE Box(ctx: Ctx; x0, y0, x1, y1: SIZE);
BEGIN
	ctx.canvas.Fill(WMRectangles.MakeRect(x0, y0, x1, y1), ctx.color, WMGraphics.ModeSrcOverDst)
END Box;

(* a path given by pairs of numbers 0..100, scaled into the box (x, y, w, h); mirror turns it left to right *)
PROCEDURE Path(ctx: Ctx; CONST path: ARRAY OF CHAR; x, y, w, h: SIZE; mirror: BOOLEAN; th: FLOAT32);
VAR p: ARRAY 64 OF SIZE; n, i: SIGNED32; xa, ya, xb, yb, px: SIZE;
BEGIN
	n := Numbers(path, p);
	FOR i := 0 TO n - 2 DO
		px := p[2 * i]; IF mirror THEN px := 100 - px END;
		xa := x + w * px DIV 100; ya := y + h * p[2 * i + 1] DIV 100;
		px := p[2 * i + 2]; IF mirror THEN px := 100 - px END;
		xb := x + w * px DIV 100; yb := y + h * p[2 * i + 3] DIV 100;
		Line(ctx, xa, ya, xb, yb, th)
	END
END Path;

PROCEDURE DrawDelim(ctx: Ctx; code: SIGNED32; x, y, w, h, em: SIZE);
BEGIN
	IF code = ORD('(') THEN Path(ctx, PathParen, x, y, w, h, FALSE, Light(em))
	ELSIF code = ORD(')') THEN Path(ctx, PathParen, x, y, w, h, TRUE, Light(em))
	ELSIF code = ORD('[') THEN Path(ctx, PathBracket, x, y, w, h, FALSE, Light(em))
	ELSIF code = ORD(']') THEN Path(ctx, PathBracket, x, y, w, h, TRUE, Light(em))
	ELSIF code = ORD('{') THEN Path(ctx, PathBrace, x, y, w, h, FALSE, Light(em))
	ELSIF code = ORD('}') THEN Path(ctx, PathBrace, x, y, w, h, TRUE, Light(em))
	ELSIF code = ORD('|') THEN Path(ctx, PathBar, x, y, w, h, FALSE, Light(em))
	ELSIF code = DLangle THEN Path(ctx, PathAngle, x, y, w, h, FALSE, Light(em))
	ELSIF code = DRangle THEN Path(ctx, PathAngle, x, y, w, h, TRUE, Light(em))
	END
END DrawDelim;

PROCEDURE Draw(ctx: Ctx; n: Node; x, y: SIZE);
VAR c: Node; em, ox, oy, w, h, x0, y0, x1, yv, bottom, rw, len, hw, cx, d: SIZE;
BEGIN
	CASE n.kind OF
		KSym:
			IF n.s[0] # 0X THEN
				ctx.canvas.SetFont(n.font); ctx.canvas.SetColor(ctx.color);
				ctx.canvas.DrawString(x, y, n.s^)
			END
		|KRow:
			c := n.first;
			WHILE c # NIL DO Draw(ctx, c, x + c.dx, y + c.dy); c := c.next END
		|KScript:
			Draw(ctx, n.a, x + n.a.dx, y + n.a.dy);
			IF n.b # NIL THEN Draw(ctx, n.b, x + n.b.dx, y + n.b.dy) END;
			IF n.c # NIL THEN Draw(ctx, n.c, x + n.c.dx, y + n.c.dy) END
		|KFrac:
			Draw(ctx, n.a, x + n.a.dx, y + n.a.dy);
			Draw(ctx, n.b, x + n.b.dx, y + n.b.dy);
			Box(ctx, x, y + n.y1, x + n.w, y + n.y1 + n.t)
		|KSqrt:
			em := n.em; rw := n.w1;
			x0 := x + n.x1; yv := y + n.y1 + n.t DIV 2; bottom := y + n.y2; h := bottom - (y + n.y1);
			Line(ctx, x0 + rw * 4 DIV 100, bottom - h * 40 DIV 100, x0 + rw * 20 DIV 100, bottom - h * 46 DIV 100, Light(em));
			Line(ctx, x0 + rw * 20 DIV 100, bottom - h * 46 DIV 100, x0 + rw * 44 DIV 100, bottom - 1, Heavy(em));
			Line(ctx, x0 + rw * 44 DIV 100, bottom - 1, x0 + rw, yv, Light(em));
			Line(ctx, x0 + rw, yv, x + n.w - 1, yv, Heavy(em));
			Draw(ctx, n.a, x + n.a.dx, y + n.a.dy);
			IF n.b # NIL THEN Draw(ctx, n.b, x + n.b.dx, y + n.b.dy) END
		|KBigOp:
			em := n.em; ox := x + n.x1; oy := y + n.y2; w := n.w1; h := n.y1;
			IF n.op = OpSum THEN
				Line(ctx, ox + w, oy, ox, oy, Light(em));
				Line(ctx, ox, oy, ox + w * 55 DIV 100, oy + h DIV 2, Heavy(em));
				Line(ctx, ox + w * 55 DIV 100, oy + h DIV 2, ox, oy + h, Heavy(em));
				Line(ctx, ox, oy + h, ox + w, oy + h, Light(em));
				Line(ctx, ox + w, oy, ox + w, oy + h * 12 DIV 100, Light(em));
				Line(ctx, ox + w, oy + h, ox + w, oy + h - h * 12 DIV 100, Light(em))
			ELSIF n.op = OpProd THEN
				Line(ctx, ox, oy, ox + w, oy, Light(em));
				Line(ctx, ox + w * 15 DIV 100, oy, ox + w * 15 DIV 100, oy + h, Heavy(em));
				Line(ctx, ox + w * 85 DIV 100, oy, ox + w * 85 DIV 100, oy + h, Heavy(em))
			ELSE
				Path(ctx, PathInt, ox, oy, w, h, FALSE, Heavy(em))
			END;
			IF n.b # NIL THEN Draw(ctx, n.b, x + n.b.dx, y + n.b.dy) END;
			IF n.c # NIL THEN Draw(ctx, n.c, x + n.c.dx, y + n.c.dy) END
		|KDelim:
			em := n.em;
			IF n.op = 1 THEN
				DrawDelim(ctx, n.left, x, y + n.y1, n.w1, n.t, em);
				DrawDelim(ctx, n.right, x + n.x2, y + n.y1, n.w2, n.t, em)
			ELSE
				IF n.b # NIL THEN Draw(ctx, n.b, x + n.b.dx, y + n.b.dy) END;
				IF n.c # NIL THEN Draw(ctx, n.c, x + n.c.dx, y + n.c.dy) END
			END;
			Draw(ctx, n.a, x + n.a.dx, y + n.a.dy)
		|KAccent:
			em := n.em; w := n.w; Draw(ctx, n.a, x + n.a.dx, y + n.a.dy);
			yv := y + n.y1; cx := x + w DIV 2; h := n.t;
			CASE n.op OF
				AccVec:
					len := MAX(w * 84 DIV 100, em * 55 DIV 100);
					x0 := cx - len DIV 2; x1 := cx + len DIV 2;
					Line(ctx, x0, yv, x1, yv, Light(em));
					hw := MAX(2, em * 16 DIV 100);
					Line(ctx, x1, yv, x1 - hw, yv - hw DIV 2 - 1, Light(em));
					Line(ctx, x1, yv, x1 - hw, yv + hw DIV 2 + 1, Light(em))
				|AccDot:
					Box(ctx, cx - h DIV 2, yv - h DIV 2, cx - h DIV 2 + h, yv - h DIV 2 + h)
				|AccDDot:
					d := h;
					Box(ctx, cx - d - d DIV 2, yv - h DIV 2, cx - d DIV 2, yv - h DIV 2 + h);
					Box(ctx, cx + d DIV 2, yv - h DIV 2, cx + d + d DIV 2, yv - h DIV 2 + h)
				|AccHat:
					hw := MAX(2, em * 20 DIV 100);
					Line(ctx, cx - hw, yv + h DIV 2, cx, yv - h DIV 2, Light(em));
					Line(ctx, cx, yv - h DIV 2, cx + hw, yv + h DIV 2, Light(em))
				|AccBar:
					Line(ctx, x + w * 5 DIV 100, yv, x + w * 95 DIV 100, yv, Light(em))
				|AccTilde:
					len := MAX(w * 70 DIV 100, em * 40 DIV 100);
					Path(ctx, PathTilde, cx - len DIV 2, yv - h DIV 2, len, h, FALSE, Light(em))
				|AccUnder:
					Line(ctx, x, yv, x + w - 1, yv, Light(em))
			ELSE
			END
		|KSpace:
	ELSE
	END
END Draw;

(* ---------- parser ---------- *)

TYPE
	Parser = OBJECT
	VAR
		s: String;
		pos: SIGNED32;
		err: BOOLEAN;
		style: SIGNED32;	(* style of the letters being read *)

		PROCEDURE SkipSpaces;
		BEGIN
			WHILE IsSpace(s[pos]) DO INC(pos) END
		END SkipSpaces;

		(* a command name after "\": letters, or one other character *)
		PROCEDURE ReadName(VAR name: ARRAY OF CHAR);
		VAR k: SIGNED32;
		BEGIN
			k := 0;
			IF IsLetter(s[pos]) THEN
				WHILE IsLetter(s[pos]) DO
					IF k < LEN(name) - 1 THEN name[k] := s[pos]; INC(k) END;
					INC(pos)
				END
			ELSIF s[pos] # 0X THEN
				name[0] := s[pos]; k := 1; INC(pos)
			END;
			name[k] := 0X
		END ReadName;

		(* is the text at pos "\" followed by the word? *)
		PROCEDURE AtCommand(CONST word: ARRAY OF CHAR): BOOLEAN;
		VAR k: SIGNED32;
		BEGIN
			IF s[pos] # '\' THEN RETURN FALSE END;
			k := 0;
			WHILE (word[k] # 0X) & (s[pos + 1 + k] = word[k]) DO INC(k) END;
			RETURN (word[k] = 0X) & ~IsLetter(s[pos + 1 + k])
		END AtCommand;

		(* a delimiter after \left or \right: its code, 0 for ".", DLangle / DRangle for angle brackets *)
		PROCEDURE ReadDelim(): SIGNED32;
		VAR c: CHAR; name: ARRAY 16 OF CHAR; r: SIGNED32;
		BEGIN
			SkipSpaces;
			c := s[pos]; r := 0;
			IF c = '\' THEN
				INC(pos); ReadName(name);
				IF (name = "{") OR (name = "lbrace") THEN r := ORD('{')
				ELSIF (name = "}") OR (name = "rbrace") THEN r := ORD('}')
				ELSIF (name = "|") OR (name = "lvert") OR (name = "rvert") THEN r := ORD('|')
				ELSIF name = "langle" THEN r := DLangle
				ELSIF name = "rangle" THEN r := DRangle
				ELSE err := TRUE
				END
			ELSIF (c = '(') OR (c = ')') OR (c = '[') OR (c = ']') OR (c = '|') THEN
				r := ORD(c); INC(pos)
			ELSIF c = '<' THEN r := DLangle; INC(pos)
			ELSIF c = '>' THEN r := DRangle; INC(pos)
			ELSIF c = '.' THEN r := 0; INC(pos)
			ELSE err := TRUE
			END;
			RETURN r
		END ReadDelim;

		(* \left D ... \right D *)
		PROCEDURE ParseDelimited(): Node;
		VAR n: Node;
		BEGIN
			n := NewNode(KDelim);
			n.left := ReadDelim();
			n.a := ParseRow(2);
			IF err THEN RETURN n END;
			IF ~AtCommand("right") THEN err := TRUE; RETURN n END;
			INC(pos, 6);
			n.right := ReadDelim();
			RETURN n
		END ParseDelimited;

		(* the text between braces, as it is *)
		PROCEDURE ParseText(): Node;
		VAR start, depth, k: SIGNED32; t: String;
		BEGIN
			SkipSpaces;
			IF s[pos] # '{' THEN err := TRUE; RETURN NIL END;
			INC(pos); start := pos; depth := 1;
			WHILE (s[pos] # 0X) & (depth > 0) DO
				IF s[pos] = '{' THEN INC(depth) ELSIF s[pos] = '}' THEN DEC(depth) END;
				INC(pos)
			END;
			IF depth > 0 THEN err := TRUE; RETURN NIL END;
			NEW(t, pos - start);
			FOR k := start TO pos - 2 DO
				IF IsSpace(s[k]) THEN t[k - start] := ' ' ELSE t[k - start] := s[k] END
			END;
			t[pos - 1 - start] := 0X;
			RETURN NewSym(t^, COrd, SRoman)
		END ParseText;

		(* an argument written in another style of letters *)
		PROCEDURE ParseStyled(st: SIGNED32): Node;
		VAR saved: SIGNED32; n: Node;
		BEGIN
			saved := style; style := st;
			n := ParseArg();
			style := saved;
			RETURN n
		END ParseStyled;

		(* an argument: a group in braces, or the next single atom *)
		PROCEDURE ParseArg(): Node;
		VAR a: Node;
		BEGIN
			SkipSpaces;
			IF s[pos] = 0X THEN err := TRUE; RETURN NewNode(KRow) END;
			IF s[pos] = '{' THEN INC(pos); RETURN ParseRow(1) END;
			a := ParseBase();
			IF a = NIL THEN a := NewNode(KRow) END;
			RETURN a
		END ParseArg;

		PROCEDURE ParseCommand(): Node;
		VAR name: ARRAY 32 OF CHAR; n: Node; code, cl, st: SIGNED32;
		BEGIN
			ReadName(name);
			IF name[0] = 0X THEN err := TRUE; RETURN NIL END;
			IF (name = "frac") OR (name = "dfrac") OR (name = "tfrac") THEN
				n := NewNode(KFrac); n.a := ParseArg(); n.b := ParseArg();
				RETURN n
			ELSIF name = "sqrt" THEN
				n := NewNode(KSqrt); SkipSpaces;
				IF s[pos] = '[' THEN INC(pos); n.b := ParseRow(3) END;
				n.a := ParseArg();
				RETURN n
			ELSIF name = "sum" THEN n := NewNode(KBigOp); n.op := OpSum; RETURN n
			ELSIF name = "prod" THEN n := NewNode(KBigOp); n.op := OpProd; RETURN n
			ELSIF (name = "int") OR (name = "oint") THEN n := NewNode(KBigOp); n.op := OpInt; RETURN n
			ELSIF name = "left" THEN RETURN ParseDelimited()
			ELSIF (name = "text") OR (name = "textrm") OR (name = "mbox") THEN RETURN ParseText()
			ELSIF (name = "mathrm") OR (name = "operatorname") THEN RETURN ParseStyled(SRoman)
			ELSIF (name = "mathbf") OR (name = "boldsymbol") OR (name = "bm") THEN RETURN ParseStyled(SBold)
			ELSIF name = "mathit" THEN RETURN ParseStyled(SItalic)
			ELSIF name = "vec" THEN n := NewNode(KAccent); n.op := AccVec; n.a := ParseArg(); RETURN n
			ELSIF name = "dot" THEN n := NewNode(KAccent); n.op := AccDot; n.a := ParseArg(); RETURN n
			ELSIF name = "ddot" THEN n := NewNode(KAccent); n.op := AccDDot; n.a := ParseArg(); RETURN n
			ELSIF (name = "hat") OR (name = "widehat") THEN n := NewNode(KAccent); n.op := AccHat; n.a := ParseArg(); RETURN n
			ELSIF (name = "bar") OR (name = "overline") THEN n := NewNode(KAccent); n.op := AccBar; n.a := ParseArg(); RETURN n
			ELSIF (name = "tilde") OR (name = "widetilde") THEN n := NewNode(KAccent); n.op := AccTilde; n.a := ParseArg(); RETURN n
			ELSIF name = "underline" THEN n := NewNode(KAccent); n.op := AccUnder; n.a := ParseArg(); RETURN n
			ELSIF name = "," THEN RETURN NewSpace(3)
			ELSIF (name = ":") OR (name = ">") THEN RETURN NewSpace(4)
			ELSIF name = ";" THEN RETURN NewSpace(5)
			ELSIF name = "!" THEN RETURN NewSpace(-3)
			ELSIF name = " " THEN RETURN NewSpace(6)
			ELSIF name = "quad" THEN RETURN NewSpace(18)
			ELSIF name = "qquad" THEN RETURN NewSpace(36)
			ELSIF (name = "displaystyle") OR (name = "textstyle") OR (name = "scriptstyle") OR (name = "limits")
				OR (name = "nolimits") OR (name = "\") THEN
				RETURN NIL	(* accepted and ignored *)
			ELSIF name = "{" THEN RETURN NewSym("{", COpen, SRoman)
			ELSIF name = "}" THEN RETURN NewSym("}", CClose, SRoman)
			ELSIF name = "|" THEN RETURN NewSym("|", COrd, SRoman)
			ELSIF (name = "%") OR (name = "$") OR (name = "#") OR (name = "&") OR (name = "_") THEN
				RETURN NewSym(name, COrd, SRoman)
			ELSIF InList(Funcs, name) THEN
				RETURN NewSym(name, CFun, SRoman)
			ELSIF LookupSym(name, code, cl) THEN
				st := SRoman;
				IF (code >= 03B1H) & (code <= 03C9H) THEN st := SItalic END;	(* small Greek letters are slanted *)
				RETURN NewSymCode(code, cl, st)
			END;
			err := TRUE;
			RETURN NIL
		END ParseCommand;

		(* one atom without its scripts; NIL if the text there has no effect *)
		PROCEDURE ParseBase(): Node;
		VAR c: CHAR; start, k: SIGNED32; t: ARRAY 64 OF CHAR; st: SIGNED32;
		BEGIN
			c := s[pos];
			IF c = '{' THEN
				INC(pos); RETURN ParseRow(1)
			ELSIF c = '\' THEN
				INC(pos); RETURN ParseCommand()
			ELSIF (c = '^') OR (c = '_') THEN
				RETURN NewNode(KRow)	(* a script without a base: it goes on an empty one *)
			ELSIF IsLetter(c) THEN
				t[0] := c; t[1] := 0X; INC(pos);
				RETURN NewSym(t, COrd, style)
			ELSIF IsDigit(c) THEN
				k := 0;
				WHILE IsDigit(s[pos]) OR (((s[pos] = '.') OR (s[pos] = ',')) & IsDigit(s[pos + 1])) DO
					IF k < LEN(t) - 1 THEN t[k] := s[pos]; INC(k) END;
					INC(pos)
				END;
				t[k] := 0X;
				IF style = SBold THEN st := SBold ELSE st := SRoman END;
				RETURN NewSym(t, COrd, st)
			ELSIF c = '+' THEN INC(pos); RETURN NewSym("+", CBin, SRoman)
			ELSIF c = '-' THEN INC(pos); RETURN NewSym("-", CBin, SRoman)
			ELSIF c = '*' THEN INC(pos); RETURN NewSym("*", CBin, SRoman)
			ELSIF (c = '=') OR (c = '<') OR (c = '>') THEN
				t[0] := c; t[1] := 0X; INC(pos); RETURN NewSym(t, CRel, SRoman)
			ELSIF (c = '(') OR (c = '[') THEN
				t[0] := c; t[1] := 0X; INC(pos); RETURN NewSym(t, COpen, SRoman)
			ELSIF (c = ')') OR (c = ']') THEN
				t[0] := c; t[1] := 0X; INC(pos); RETURN NewSym(t, CClose, SRoman)
			ELSIF (c = ',') OR (c = ';') THEN
				t[0] := c; t[1] := 0X; INC(pos); RETURN NewSym(t, CPunct, SRoman)
			ELSIF c = '~' THEN INC(pos); RETURN NewSpace(6)
			ELSIF c = '&' THEN INC(pos); RETURN NIL
			ELSIF c = '%' THEN	(* a comment up to the end of the line *)
				WHILE (s[pos] # 0X) & (s[pos] # 0AX) DO INC(pos) END;
				RETURN NIL
			ELSIF ORD(c) >= 128 THEN	(* a letter of another alphabet: the whole UTF-8 sequence *)
				start := pos; INC(pos);
				WHILE (ORD(s[pos]) >= 080H) & (ORD(s[pos]) < 0C0H) DO INC(pos) END;
				k := 0;
				WHILE (start + k < pos) & (k < LEN(t) - 1) DO t[k] := s[start + k]; INC(k) END;
				t[k] := 0X;
				RETURN NewSym(t, COrd, SRoman)
			ELSIF ORD(c) < 32 THEN
				INC(pos); RETURN NIL
			ELSE	(* | / . : ! ? @ and other signs *)
				t[0] := c; t[1] := 0X; INC(pos); RETURN NewSym(t, COrd, SRoman)
			END
		END ParseBase;

		PROCEDURE AddScript(base, sub, sup: Node): Node;
		VAR n: Node;
		BEGIN
			IF (base.kind = KBigOp) OR (base.kind = KScript) THEN
				IF sub # NIL THEN
					IF base.b # NIL THEN err := TRUE ELSE base.b := sub END
				END;
				IF sup # NIL THEN
					IF base.c # NIL THEN err := TRUE ELSE base.c := sup END
				END;
				RETURN base
			END;
			n := NewNode(KScript); n.a := base; n.b := sub; n.c := sup;
			RETURN n
		END AddScript;

		(* an atom and the indices, powers and primes that follow it *)
		PROCEDURE ParseAtom(): Node;
		VAR a, arg: Node; more: BOOLEAN; primes: SIGNED32;
		BEGIN
			a := ParseBase();
			IF a = NIL THEN RETURN NIL END;
			more := TRUE;
			WHILE more & ~err DO
				SkipSpaces;
				IF s[pos] = '^' THEN
					INC(pos); arg := ParseArg(); a := AddScript(a, NIL, arg)
				ELSIF s[pos] = '_' THEN
					INC(pos); arg := ParseArg(); a := AddScript(a, arg, NIL)
				ELSIF s[pos] = "'" THEN
					primes := 0;
					WHILE s[pos] = "'" DO INC(primes); INC(pos) END;
					IF primes = 1 THEN arg := NewSymCode(02032H, COrd, SRoman) ELSE arg := NewSymCode(02033H, COrd, SRoman) END;
					a := AddScript(a, NIL, arg)
				ELSE
					more := FALSE
				END
			END;
			RETURN a
		END ParseAtom;

		(* the items up to the end of the text (stop = 0), a closing brace (1), \right (2) or "]" (3) *)
		PROCEDURE ParseRow(stop: SIGNED32): Node;
		VAR row, last, atom: Node; done: BOOLEAN; c: CHAR;
		BEGIN
			row := NewNode(KRow); last := NIL; done := FALSE;
			WHILE ~done & ~err DO
				SkipSpaces;
				c := s[pos];
				IF c = 0X THEN
					IF stop # 0 THEN err := TRUE END;
					done := TRUE
				ELSIF c = '}' THEN
					IF stop = 1 THEN INC(pos); done := TRUE ELSE err := TRUE END
				ELSIF (c = ']') & (stop = 3) THEN
					INC(pos); done := TRUE
				ELSIF AtCommand("right") THEN
					IF stop = 2 THEN done := TRUE ELSE err := TRUE END
				ELSE
					atom := ParseAtom();
					IF atom # NIL THEN
						IF last = NIL THEN row.first := atom ELSE last.next := atom END;
						last := atom
					END
				END
			END;
			RETURN row
		END ParseRow;
	END Parser;

(** typesets a formula; display = in a line of its own, else inside a line of text. fontName and size (in pixels)
    are the font of the surrounding text. NIL if the formula has an error. *)
PROCEDURE Typeset*(CONST tex: ARRAY OF CHAR; display: BOOLEAN; CONST fontName: ARRAY OF CHAR; size: SIZE): Formula;
VAR p: Parser; env: Env; f: Formula; root: Node; sty: SIGNED32;
BEGIN
	NEW(p); p.s := NewStr(tex); p.pos := 0; p.err := FALSE; p.style := SItalic;
	root := p.ParseRow(0);
	IF p.err OR (root = NIL) THEN RETURN NIL END;
	NEW(env); COPY(fontName, env.name); env.size := size;
	IF env.size < 8 THEN env.size := 14 END;
	IF display THEN sty := 0 ELSE sty := 1 END;
	Layout(env, root, sty);
	NEW(f); f.root := root;
	f.width := root.w; f.ascent := root.asc; f.descent := root.desc;
	RETURN f
END Typeset;

(** draws the formula into a new image of (width + 2 Pad) x (height + 2 Pad) pixels; the baseline is
    Pad + ascent pixels below its top *)
PROCEDURE Render*(f: Formula; color: WMGraphics.Color): WMGraphics.Image;
VAR img: WMGraphics.Image; ctx: Ctx; w, h: SIZE;
BEGIN
	w := f.width + 2 * Pad; h := f.ascent + f.descent + 2 * Pad;
	NEW(img);
	Raster.Create(img, w, h, Raster.BGRA8888);
	NEW(ctx); ctx.img := img; ctx.canvas := AAGraphics.GenCanvas(img); ctx.color := color;
	ctx.canvas.Fill(WMRectangles.MakeRect(0, 0, w, h), WMGraphics.Transparent, WMGraphics.ModeCopy);
	Draw(ctx, f.root, Pad, Pad + f.ascent);
	RETURN img
END Render;

(* ---------- commands for checking ---------- *)

(** MDMath.Check [fontname size] ~  -- which Greek letters and signs a font has *)
PROCEDURE Check*(context: Commands.Context);
VAR name: ARRAY 128 OF CHAR; size: SIGNED32; font: WMGraphics.Font; codes: ARRAY 20 OF SIGNED32; i: SIGNED32;
BEGIN
	IF context.arg.GetString(name) & context.arg.GetInteger(size, FALSE) THEN
		font := WMGraphics.GetFont(name, size, {})
	ELSE
		font := WMGraphics.GetDefaultFont()
	END;
	context.out.String("font: "); context.out.String(font.name);
	context.out.String(", size "); context.out.Int(font.size, 0); context.out.Ln;
	codes[0] := 03B1H; codes[1] := 03C9H; codes[2] := 03C6H; codes[3] := 0394H; codes[4] := 03A9H;
	codes[5] := 03C0H; codes[6] := 03BCH; codes[7] := 00B1H; codes[8] := 00D7H; codes[9] := 00B7H;
	codes[10] := 02264H; codes[11] := 02265H; codes[12] := 02260H; codes[13] := 02248H; codes[14] := 02192H;
	codes[15] := 0221EH; codes[16] := 02202H; codes[17] := 00B0H; codes[18] := 02212H; codes[19] := 02032H;
	FOR i := 0 TO 19 DO
		context.out.String("U+"); context.out.Hex(codes[i], 4); context.out.String(": ");
		IF font.HasChar(codes[i]) THEN context.out.String("yes") ELSE context.out.String("NO") END;
		context.out.Ln
	END;
	context.out.Update
END Check;

PROCEDURE TestOne(context: Commands.Context; CONST tex: ARRAY OF CHAR; display: BOOLEAN);
VAR f: Formula; base: WMGraphics.Font;
BEGIN
	base := WMGraphics.GetDefaultFont();
	f := Typeset(tex, display, base.name, base.size);
	context.out.String(tex); context.out.String("   ->   ");
	IF f = NIL THEN
		context.out.String("ERROR")
	ELSE
		context.out.String("w "); context.out.Int(f.width, 0);
		context.out.String(", asc "); context.out.Int(f.ascent, 0);
		context.out.String(", desc "); context.out.Int(f.descent, 0)
	END;
	context.out.Ln
END TestOne;

(** MDMath.Test ~  -- typesets a few formulas and prints their sizes, ERROR for a formula that does not parse *)
PROCEDURE Test*(context: Commands.Context);
BEGIN
	TestOne(context, "U = I R", FALSE);
	TestOne(context, "X_L = \omega L, \quad X_C = \frac{1}{\omega C}", FALSE);
	TestOne(context, "Z = \sqrt{R^2 + (X_L - X_C)^2}", TRUE);
	TestOne(context, "\varphi = \arctan\frac{X}{R}", FALSE);
	TestOne(context, "\sum_{k=1}^{n} k^2 = \frac{n(n+1)(2n+1)}{6}", TRUE);
	TestOne(context, "\int_0^T u(t)\,dt", TRUE);
	TestOne(context, "\left( \frac{a}{b} + c \right)^2", TRUE);
	TestOne(context, "\dot{U} = \dot{I}\,Z, \vec{E}, \overline{AB}, \hat{x}", FALSE);
	TestOne(context, "\text{Ом} \cdot \mathrm{m}^{-1}", FALSE);
	TestOne(context, "\unknown{x}", FALSE);
	TestOne(context, "\frac{1}{2", FALSE);
	context.out.Update
END Test;

END MDMath.
MDMath.Test~


