MODULE FoxDocumentationHtml; (** AUTHOR ""; PURPOSE ""; *)

IMPORT Tree := FoxDocumentationTree, Scanner := FoxDocumentationScanner, Streams,Strings,  SYSTEM;

CONST MaxLevel=256;

TYPE
	ParagraphType=Tree.ParagraphType;
	ElementType= Tree.ElementType;
	Printer*= OBJECT
	VAR writer: Streams.Writer;
		chars: ARRAY MaxLevel OF CHAR; listLevel: SIGNED32;
		currentLevel: SIGNED32; printLabels: BOOLEAN;
		preformatted: BOOLEAN;   (* inside <pre>, where a line ending is a line ending *)

		PROCEDURE &InitPrinter*(writer: Streams.Writer);
		BEGIN SELF.writer := writer; listLevel := 0; currentLevel := 0; printLabels := FALSE;
			preformatted := FALSE;
		END InitPrinter;

		(*	The value of an `id` attribute, which is a name and not a reference: the hash belongs to
			the `href` that points at it, and every heading in the document used to carry one. *)
		PROCEDURE PrintLabel(section: Tree.Section);
		BEGIN
			writer.String('"'); IF section.label = NIL THEN writer.String("_"); writer.Hex(SYSTEM.VAL(ADDRESS,section),-8); ELSE WriteString(writer,section.label); END; writer.String('"')
		END PrintLabel;

		PROCEDURE Section*(section: Tree.Section);
		BEGIN
			IF section.label # NIL THEN
				writer.String('<a name="'); WriteString(writer, section.label); writer.String('"></a>');
			END;
			writer.String("<hr>");
			writer.String("<h"); writer.Int(section.level,0); writer.String(" id="); PrintLabel(section); writer.String(">");
			Text(section.title); writer.Ln;
			writer.String("</h"); writer.Int(section.level,1); writer.String(">");
			ParagraphList(section.contents);
			(*
			writer.String('<p><a href="#top"> Top of page </a></p>');
			*)
		END Section;

		PROCEDURE SectionList*(sections: Tree.Sections);
		VAR i: SIZE;
		BEGIN
			FOR i := 0 TO sections.Length()-1 DO
				Section(sections.GetSection(i));
			END;
		END SectionList;

		PROCEDURE EndItem*(level: SIGNED32);
		BEGIN
			WHILE listLevel > level DO
				ASSERT(chars[listLevel] # 0X);
				writer.String("</"); writer.Char(chars[listLevel]); writer.String("l>");writer.Ln;
				chars[listLevel] := 0X;
				DEC(listLevel)
			END;
		END EndItem;

		PROCEDURE BeginItem*(level: SIGNED32; c: CHAR);
		BEGIN
			IF (c # chars[level]) & (level > 0) THEN (* change from bullet to numbers or vice versa *)
				EndItem(level-1)
			ELSE
				EndItem(level);
			END;
			WHILE listLevel<level DO
				writer.String("<"); writer.Char(c); writer.String("l>");writer.Ln;
				INC(listLevel);
				chars[listLevel] := c;
			END;
		END BeginItem;

		PROCEDURE Paragraph*(paragraph: Tree.Paragraph);
		BEGIN
			writer.Ln;
			CASE paragraph.type OF
			ParagraphType.Heading:
				EndItem(0);
				IF paragraph.label # NIL THEN
					writer.String('<a name="'); WriteString(writer, paragraph.label); writer.String('"></a>');
				END;
				writer.String("<h"); writer.Int(currentLevel + paragraph.level,0); writer.String(">"); Text(paragraph.text);
				writer.String("</h"); writer.Int(currentLevel + paragraph.level,0); writer.String(">");
			|ParagraphType.TextBlock:
				EndItem(0);
				writer.String("<p>"); Text(paragraph.text); writer.String("</p>");
			|ParagraphType.Number:
				BeginItem(paragraph.level, 'o');
				writer.String("<li>");
				Text(paragraph.text);
				writer.String("</li>");
			|ParagraphType.Description:
				BeginItem(listLevel+1(*paragraph.level*), 'd');
				writer.String("<dt><strong>"); Text(paragraph.description); writer.String("</strong></dt>");writer.Ln;
				writer.String("<dd>"); Text(paragraph.text); writer.String("</dd>");writer.Ln;
				EndItem(listLevel);
			|ParagraphType.Bullet:
				BeginItem(paragraph.level, 'u');
				writer.String("<li>");
				Text(paragraph.text);
				writer.String("</li>");
			|ParagraphType.Code:
				(*	`<pre>` keeps the line endings it is given, so they are not turned into breaks
					here -- doing both put an empty line between every two lines of an example.
					(An element was fetched here and never used; it would have halted on a code
					block with nothing in it.) *)
				EndItem(0);
				writer.String("<pre>"); preformatted := TRUE;
				Text(paragraph.text);
				preformatted := FALSE; writer.String("</pre>");
			|ParagraphType.Table:
				EndItem(0);
				writer.String('<table>'); Text(paragraph.text); writer.String("</table>");
			|ParagraphType.Line:
				EndItem(0);
				writer.String("<hr/>");
			ELSE HALT(200)
			END;
			writer.Ln;
		END Paragraph;

		PROCEDURE ParagraphList*(paragraphs: Tree.Paragraphs);
		VAR i: SIZE;
		BEGIN
			FOR i := 0 TO paragraphs.Length()-1 DO
				Paragraph(paragraphs.GetParagraph(i))
			END;
			EndItem(0);
		END ParagraphList;

		(*	Text into the document, with the characters that mean something in it escaped. The
			document declares itself XHTML 1.0 Strict and opens with an XML declaration, and in XML
			an entity without its semicolon is not something to recover from -- it is a fatal
			error. `&lt` and `&gt` were written without one, an ampersand was not escaped at all,
			and this procedure also writes attribute values, where a quotation mark ends the
			attribute. So: five characters, and a line break that closes itself. *)
		PROCEDURE WriteString(writer: Streams.Writer; string: Strings.String);
		VAR i: SIGNED32; c: CHAR;
		BEGIN
			IF string = NIL THEN RETURN END;
			i := 0;
			WHILE string[i] # 0X DO
				c := string[i];
				IF c = '&' THEN writer.String("&amp;")
				ELSIF c = '<' THEN writer.String("&lt;")
				ELSIF c = '>' THEN writer.String("&gt;")
				ELSIF c = '"' THEN writer.String("&quot;")
				ELSIF c = "'" THEN writer.String("&apos;")
				ELSIF (c = Scanner.LF) & ~preformatted THEN writer.String("<br />")
				ELSE
					writer.Char(c);
				END;
				INC(i);
			END;
		END WriteString;

		PROCEDURE PrintText*(textElement: Tree.TextElement);
		BEGIN
			IF textElement.text.Length() = 0 THEN
				WriteString(writer,textElement.string)
			ELSE
				Text(textElement.text);
			END;
		END PrintText;

		PROCEDURE TextElement*(textElement: Tree.TextElement);
		VAR type: ElementType;
		BEGIN
			type := textElement.type;
			(*
			IF separator # 0X THEN
				writer.Char(separator)
			END;
			*)
			CASE textElement.type OF
			ElementType.Default : PrintText(textElement);
			|ElementType.Whitespace: writer.String(" ");
			|ElementType.Italic : writer.String("<em>"); PrintText(textElement); writer.String("</em>");
			|ElementType.Bold : writer.String("<strong>"); PrintText(textElement); writer.String("</strong>");
			|ElementType.Underline : writer.String("<u>"); PrintText(textElement); writer.String("</u>");
			|ElementType.HeaderCell : writer.String("<th align='left'>"); PrintText(textElement); writer.String("</th>");
			|ElementType.DataCell : writer.String("<td>"); PrintText(textElement); writer.String("</td>");
			|ElementType.Row : writer.String("<tr>"); PrintText(textElement); writer.String("</tr>"); writer.Ln;
			|ElementType.Link:
				writer.String('<a href="'); writer.String("#"); WriteString(writer,textElement.string);  writer.String('">');
				IF textElement.text.Length()#0 THEN
					Text(textElement.text);
				ELSE WriteString( writer, textElement.string);
				END;
				writer.String("</a>");
			|ElementType.Label :
				writer.String('<a name="'); WriteString(writer, textElement.string); writer.String('"></a>');
			|ElementType.Code : writer.String("<code>"); PrintText(textElement); writer.String("</code>");
			|ElementType.LineBreak : writer.String("<br>");
			END;
		END TextElement;

		PROCEDURE Text*(text: Tree.Text);
		VAR element: Tree.TextElement; i: SIZE;
		BEGIN
			FOR i := 0 TO text.Length()-1 DO
				element := text.GetElement(i);
				TextElement(element);
			END;
		END Text;

		PROCEDURE Document*(document: Tree.Document);
		BEGIN
			currentLevel := 0;
			writer.String(
				\"<?xml version=\"1.0\" encoding=\"UTF-8\" ?> \n"\
				\"<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\"> \n"\
				\"<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title></title> \n"\);
			writer.String(
				\"<style>
				normal {
				font-family: Helvetica, Sans-Serif;
				}
			.bold {
				font-family: Helvetica, Sans-Serif;
				}
			H1 {
				color: #550088
				}
			H2 {
				font-family: Helvetica, Sans-Serif;
				color: #550088
				}
			H3 {
				font-family: Helvetica, Sans-Serif;
				color: #550088
				}
			H4 {
				font-family: Helvetica, Sans-Serif;
				color: #550088
				}
			A {
				color: #550088
				}
				</style>
				</head>
				<body>
			"\);

			currentLevel := 1; printLabels := FALSE;
			(*
			writer.String("<h"); writer.Int(currentLevel+1,1); writer.String(">Contents</h"); writer.Int(currentLevel+1,0); writer.String(">");
			*)
			ParagraphList(document.description);
			printLabels := TRUE; EndItem(0);
			SectionList(document.sections);
			writer.String("</body></html>"); writer.Ln;
		END Document;

	END Printer;

END FoxDocumentationHtml.
