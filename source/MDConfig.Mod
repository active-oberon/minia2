MODULE MDConfig; (** AUTHOR "BohdanT"; PURPOSE:  reads the style file (fonts, colors, spacing) from XML into MDLayout.Styles *)

IMPORT Streams, Codecs, KernelLog, Strings, XML, XMLScanner, XMLParser, WMGraphics, MDLayout;

(*
	Style file, everything is optional; what is missing keeps its built-in value:

	<?xml version="1.0" encoding="UTF-8"?>
	<MDStyles fontName="Vera" fontSize="14" codeFont="Courier">
		<Font id="text"/>
		<Font id="code" name="Courier" size="13"/>
		<Font id="h1" scale="220"/>
		<Color id="link" value="0000C0FF"/>
		<Spacing margin="10" indent="22" gap="8" leading="2"/>
	</MDStyles>

	Root attributes: fontName, fontSize (pixels) = the base of all fonts, codeFont = family of the code font.
	Without them the default font of the system is the base.
	<Font id="...">  id: text, bold, italic, bolditalic, code, h1 .. h6
	                 name = family, size = pixels, scale = percent of the current size, style = "bold italic"
	<Color id="...">  id: text, link, code, codeBg, codeHead, math, rule, quote and, for highlighted code,
	                 keyword, builtin, string, number, comment; value = RRGGBB or RRGGBBAA in hex
	<Spacing>        margin, indent, gap, leading in pixels

	Apply is the only place that reads settings, so another source (for example the system configuration)
	can replace it later without touching the viewer.
*)

VAR
	hasErrors: BOOLEAN;	(* accessed only from Apply (EXCLUSIVE) *)

PROCEDURE Error(pos, line, row: Streams.Position; CONST msg: ARRAY OF CHAR);
BEGIN
	KernelLog.String("MDConfig: parse error in line "); KernelLog.Int(line, 0);
	KernelLog.String(" - "); KernelLog.String(msg); KernelLog.Ln;
	hasErrors := TRUE
END Error;

PROCEDURE Load(in: Streams.Reader): XML.Content;
VAR scanner: XMLScanner.Scanner; parser: XMLParser.Parser; doc: XML.Document;
BEGIN
	hasErrors := FALSE;
	IF in = NIL THEN RETURN NIL END;
	NEW(scanner, in); scanner.reportError := Error;
	NEW(parser, scanner); parser.reportError := Error;
	doc := parser.Parse();
	IF hasErrors THEN RETURN NIL END;
	RETURN doc.GetRoot()
END Load;

(* ---- small helpers ---- *)

PROCEDURE Contains(CONST s, word: ARRAY OF CHAR): BOOLEAN;
VAR i, j: SIZE;
BEGIN
	i := 0;
	WHILE s[i] # 0X DO
		j := 0;
		WHILE (word[j] # 0X) & (s[i + j] = word[j]) DO INC(j) END;
		IF word[j] = 0X THEN RETURN TRUE END;
		INC(i)
	END;
	RETURN FALSE
END Contains;

(* the integer attribute; FALSE if it is absent *)
PROCEDURE IntAttr(e: XML.Element; CONST name: ARRAY OF CHAR; VAR v: SIGNED32): BOOLEAN;
VAR s: Strings.String;
BEGIN
	s := e.GetAttributeValue(name);
	IF s = NIL THEN RETURN FALSE END;
	Strings.StrToInt32(s^, v);
	RETURN TRUE
END IntAttr;

PROCEDURE HexDigit(c: CHAR): SIGNED32;
VAR r: SIGNED32;
BEGIN
	r := -1;
	IF (c >= '0') & (c <= '9') THEN r := ORD(c) - ORD('0')
	ELSIF (c >= 'a') & (c <= 'f') THEN r := ORD(c) - ORD('a') + 10
	ELSIF (c >= 'A') & (c <= 'F') THEN r := ORD(c) - ORD('A') + 10
	END;
	RETURN r
END HexDigit;

(* RRGGBB or RRGGBBAA *)
PROCEDURE ParseColor(CONST s: ARRAY OF CHAR; VAR color: WMGraphics.Color): BOOLEAN;
VAR v: ARRAY 8 OF SIGNED32; n, d, a: SIGNED32;
BEGIN
	n := 0;
	WHILE (n < 8) & (s[n] # 0X) DO
		d := HexDigit(s[n]);
		IF d < 0 THEN RETURN FALSE END;
		v[n] := d; INC(n)
	END;
	IF (s[n] # 0X) OR ((n # 6) & (n # 8)) THEN RETURN FALSE END;
	a := 255;
	IF n = 8 THEN a := v[6] * 16 + v[7] END;
	color := WMGraphics.RGBAToColor(v[0] * 16 + v[1], v[2] * 16 + v[3], v[4] * 16 + v[5], a);
	RETURN TRUE
END ParseColor;

(* heading sizes in percent of the base size *)
PROCEDURE HeadScale(k: SIGNED32): SIGNED32;
VAR p: SIGNED32;
BEGIN
	CASE k OF
		1: p := 200
		|2: p := 160
		|3: p := 135
		|4: p := 115
		|5: p := 105
	ELSE
		p := 100
	END;
	RETURN p
END HeadScale;

(* all fonts from one family and size, as in MDLayout.Styles.Init *)
PROCEDURE Defaults(st: MDLayout.Styles; CONST name: ARRAY OF CHAR; size: SIZE; CONST codeName: ARRAY OF CHAR);
VAR k: SIGNED32;
BEGIN
	st.text[0] := WMGraphics.GetFont(name, size, {});
	st.text[1] := WMGraphics.GetFont(name, size, {WMGraphics.FontBold});
	st.text[2] := WMGraphics.GetFont(name, size, {WMGraphics.FontItalic});
	st.text[3] := WMGraphics.GetFont(name, size, {WMGraphics.FontBold, WMGraphics.FontItalic});
	st.code := WMGraphics.GetFont(codeName, size, {});
	st.codeBold := WMGraphics.GetFont(codeName, size, {WMGraphics.FontBold});
	st.codeItalic := WMGraphics.GetFont(codeName, size, {WMGraphics.FontItalic});
	FOR k := 1 TO 6 DO
		st.head[k] := WMGraphics.GetFont(name, size * HeadScale(k) DIV 100, {WMGraphics.FontBold})
	END
END Defaults;

(* ---- elements ---- *)

PROCEDURE DoFont(st: MDLayout.Styles; e: XML.Element; CONST baseName: ARRAY OF CHAR; baseSize: SIZE;
		CONST codeName: ARRAY OF CHAR);
VAR id, s: Strings.String; name: ARRAY 256 OF CHAR; size: SIZE; v, head: SIGNED32; style: SET;
	font: WMGraphics.Font;
BEGIN
	id := e.GetAttributeValue("id");
	IF id = NIL THEN RETURN END;
	COPY(baseName, name); size := baseSize; style := {}; head := 0;
	IF id^ = "code" THEN
		COPY(codeName, name)
	ELSIF id^ = "bold" THEN
		style := {WMGraphics.FontBold}
	ELSIF id^ = "italic" THEN
		style := {WMGraphics.FontItalic}
	ELSIF id^ = "bolditalic" THEN
		style := {WMGraphics.FontBold, WMGraphics.FontItalic}
	ELSIF (id^[0] = 'h') & (id^[1] >= '1') & (id^[1] <= '6') & (id^[2] = 0X) THEN
		head := ORD(id^[1]) - ORD('0');
		style := {WMGraphics.FontBold};
		size := size * HeadScale(head) DIV 100
	END;
	s := e.GetAttributeValue("name");
	IF (s # NIL) & (s^ # "") THEN COPY(s^, name) END;
	IF IntAttr(e, "size", v) & (v > 0) THEN size := v END;
	IF IntAttr(e, "scale", v) & (v > 0) THEN size := size * v DIV 100 END;
	s := e.GetAttributeValue("style");
	IF s # NIL THEN
		style := {};
		IF Contains(s^, "bold") THEN INCL(style, WMGraphics.FontBold) END;
		IF Contains(s^, "italic") THEN INCL(style, WMGraphics.FontItalic) END
	END;
	font := WMGraphics.GetFont(name, size, style);
	IF id^ = "text" THEN st.text[0] := font
	ELSIF id^ = "bold" THEN st.text[1] := font
	ELSIF id^ = "italic" THEN st.text[2] := font
	ELSIF id^ = "bolditalic" THEN st.text[3] := font
	ELSIF id^ = "code" THEN
		st.code := font;
		st.codeBold := WMGraphics.GetFont(name, size, {WMGraphics.FontBold});
		st.codeItalic := WMGraphics.GetFont(name, size, {WMGraphics.FontItalic})
	ELSIF head > 0 THEN st.head[head] := font
	END
END DoFont;

PROCEDURE DoColor(st: MDLayout.Styles; e: XML.Element);
VAR id, s: Strings.String; color: WMGraphics.Color;
BEGIN
	id := e.GetAttributeValue("id"); s := e.GetAttributeValue("value");
	IF (id = NIL) OR (s = NIL) THEN RETURN END;
	IF ~ParseColor(s^, color) THEN
		KernelLog.String("MDConfig: bad color "); KernelLog.String(s^); KernelLog.Ln;
		RETURN
	END;
	IF id^ = "text" THEN st.colText := color
	ELSIF id^ = "link" THEN st.colLink := color
	ELSIF id^ = "code" THEN st.colCode := color
	ELSIF id^ = "codeBg" THEN st.colCodeBg := color
	ELSIF id^ = "math" THEN st.colMath := color
	ELSIF id^ = "rule" THEN st.colRule := color
	ELSIF id^ = "quote" THEN st.colQuote := color
	ELSIF id^ = "codeHead" THEN st.colCodeHead := color
	ELSIF id^ = "keyword" THEN st.colKeyword := color
	ELSIF id^ = "builtin" THEN st.colBuiltin := color
	ELSIF id^ = "string" THEN st.colString := color
	ELSIF id^ = "number" THEN st.colNumber := color
	ELSIF id^ = "comment" THEN st.colComment := color
	END
END DoColor;

PROCEDURE DoSpacing(st: MDLayout.Styles; e: XML.Element);
VAR v: SIGNED32;
BEGIN
	IF IntAttr(e, "margin", v) THEN st.margin := v END;
	IF IntAttr(e, "indent", v) THEN st.indent := v END;
	IF IntAttr(e, "gap", v) THEN st.gap := v END;
	IF IntAttr(e, "leading", v) THEN st.leading := v END
END DoSpacing;

(** reads a style file from a stream into st; FALSE if it is not valid XML (st is then unchanged) *)
PROCEDURE ApplyReader*(st: MDLayout.Styles; in: Streams.Reader): BOOLEAN;
VAR content, c: XML.Content; root, e: XML.Element; s, nm: Strings.String; base: WMGraphics.Font;
	name, codeName: ARRAY 256 OF CHAR; size: SIZE; v: SIGNED32;
BEGIN {EXCLUSIVE}
	content := Load(in);
	IF (content = NIL) OR ~(content IS XML.Element) THEN RETURN FALSE END;
	root := content(XML.Element);
	base := WMGraphics.GetDefaultFont();
	COPY(base.name, name);
	size := base.size; IF size <= 0 THEN size := 12 END;
	COPY(MDLayout.codeFontName, codeName);
	s := root.GetAttributeValue("fontName");
	IF (s # NIL) & (s^ # "") THEN COPY(s^, name) END;
	IF IntAttr(root, "fontSize", v) & (v > 0) THEN size := v END;
	s := root.GetAttributeValue("codeFont");
	IF (s # NIL) & (s^ # "") THEN COPY(s^, codeName) END;
	Defaults(st, name, size, codeName);
	c := root.GetFirst();
	WHILE c # NIL DO
		IF c IS XML.Element THEN
			e := c(XML.Element);
			nm := e.GetName();
			IF nm # NIL THEN
				IF nm^ = "Font" THEN DoFont(st, e, name, size, codeName)
				ELSIF nm^ = "Color" THEN DoColor(st, e)
				ELSIF nm^ = "Spacing" THEN DoSpacing(st, e)
				END
			END
		END;
		c := root.GetNext(c)
	END;
	RETURN TRUE
END ApplyReader;

(** reads the style file into st; FALSE if the file is missing or not valid XML (st is then unchanged) *)
PROCEDURE Apply*(st: MDLayout.Styles; CONST file: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN ApplyReader(st, Codecs.OpenInputStream(file))
END Apply;

END MDConfig.
