MODULE YAML;

IMPORT JSON, Streams, Strings, Files, RealConversions;

CONST MaximumBytes* = 1024 * 1024;
	MaximumLine = 4096;
	MaximumDepth = 32;
	MaximumNodes = 4096;

TYPE
	(* shortcut: configuration YAML excludes tags, anchors, aliases and multiline scalars; extend against the YAML test suite when needed. *)
	Parser = OBJECT
	VAR reader: Streams.Reader;
		line: ARRAY MaximumLine + 1 OF CHAR;
		row, indent, pos, length, bytes, nodes: SIGNED32;
		active, failed: BOOLEAN;
		message: ARRAY 256 OF CHAR;

		PROCEDURE &Init(r: Streams.Reader);
		BEGIN
			reader := r;
			row := 0;
			bytes := 0;
			nodes := 0;
			failed := FALSE;
			message[0] := 0X;
			Next
		END Init;

		PROCEDURE Fail(CONST reason: ARRAY OF CHAR);
		VAR number: ARRAY 32 OF CHAR;
		BEGIN
			IF ~failed THEN
				failed := TRUE;
				COPY("line ", message);
				Strings.IntToStr(row, number);
				Strings.Append(message, number);
				Strings.Append(message, ": ");
				Strings.AppendX(message, reason)
			END
		END Fail;

		PROCEDURE Next;
		VAR ch: CHAR;
			i: SIGNED32;
		BEGIN
			active := FALSE;
			WHILE ~failed DO
				length := 0;
				INC(row);
				LOOP
					ch := reader.Get();
					IF reader.res # Streams.Ok THEN
						IF reader.res # Streams.EOF THEN
							Fail("Cannot read YAML stream")
						END;
						EXIT
					END;
					INC(bytes);
					IF bytes > MaximumBytes THEN
						Fail("YAML exceeds the input budget");
						RETURN
					END;
					IF ch = 0AX THEN
						EXIT
					END;
					IF (length = MaximumLine) OR ((ch < 20X) & (ch # 09X) & (ch # 0DX)) THEN
						Fail("YAML line is too long or contains a control character");
						RETURN
					END;
					line[length] := ch;
					INC(length)
				END;
				IF (length > 0) & (line[length - 1] = 0DX) THEN
					DEC(length)
				END;
				IF (row = 1) & (length >= 3) & (line[0] = 0EFX) & (line[1] = 0BBX) & (line[2] = 0BFX) THEN
					DEC(length, 3);
					FOR i := 0 TO length - 1 DO
						line[i] := line[i + 3]
					END
				END;
				line[length] := 0X;
				indent := 0;
				WHILE line[indent] = " " DO
					INC(indent)
				END;
				pos := indent;
				IF line[pos] = 09X THEN
					Fail("Tabs are not allowed in YAML indentation");
					RETURN
				END;
				IF (line[pos] # 0X) & (line[pos] # "#") THEN
					active := TRUE;
					RETURN
				END;
				IF reader.res = Streams.EOF THEN
					RETURN
				END
			END
		END Next;

		PROCEDURE Space;
		BEGIN
			WHILE (line[pos] = " ") OR (line[pos] = 09X) DO
				INC(pos)
			END
		END Space;

		PROCEDURE EndLine;
		BEGIN
			Space;
			IF (line[pos] # 0X) & (line[pos] # "#") THEN
				Fail("Unexpected content after YAML value")
			END
		END EndLine;

		PROCEDURE Quoted(): Strings.String;
		VAR quote, ch: CHAR;
			buffer: Streams.Buffer;
			writer: Streams.Writer;
			count, i, digit, cp: SIGNED32;
		BEGIN
			quote := line[pos];
			INC(pos);
			NEW(buffer, 64);
			writer := buffer.GetWriter();
			WHILE (pos < length) & ~failed DO
				ch := line[pos];
				INC(pos);
				IF ch = quote THEN
					IF (quote = 27X) & (line[pos] = quote) THEN
						writer.Char(quote);
						INC(pos)
					ELSE
						writer.Update;
						RETURN buffer.GetString()
					END
				ELSIF (quote = 22X) & (ch = 5CX) THEN
					ch := line[pos];
					INC(pos);
					CASE ch OF
					22X, 5CX, "/", " ":
						writer.Char(ch)
					| "n":
						writer.Char(0AX)
					| "r":
						writer.Char(0DX)
					| "t":
						writer.Char(09X)
					| "b":
						writer.Char(08X)
					| "f":
						writer.Char(0CX)
					| "x", "u", "U":
						count := 2;
						IF ch = "u" THEN
							count := 4
						ELSIF ch = "U" THEN
							count := 8
						END;
						cp := 0;
						FOR i := 1 TO count DO
							IF (pos >= length) OR ~Strings.IsDigit(line[pos], 16, digit) OR (cp > 10FFFFH DIV 16) THEN
								Fail("Invalid Unicode escape");
								RETURN NIL
							END;
							cp := cp * 16 + digit;
							INC(pos)
						END;
						IF (cp = 0) OR (cp > 10FFFFH) OR ((cp >= 0D800H) & (cp <= 0DFFFH)) THEN
							Fail("Invalid or unsupported Unicode code point");
							RETURN NIL
						END;
						IF cp < 80H THEN
							writer.Char(CHR(cp))
						ELSIF cp < 800H THEN
							writer.Char(CHR(0C0H + cp DIV 40H));
							writer.Char(CHR(80H + cp MOD 40H))
						ELSIF cp < 10000H THEN
							writer.Char(CHR(0E0H + cp DIV 1000H));
							writer.Char(CHR(80H + cp DIV 40H MOD 40H));
							writer.Char(CHR(80H + cp MOD 40H))
						ELSE
							writer.Char(CHR(0F0H + cp DIV 40000H));
							writer.Char(CHR(80H + cp DIV 1000H MOD 40H));
							writer.Char(CHR(80H + cp DIV 40H MOD 40H));
							writer.Char(CHR(80H + cp MOD 40H))
						END
					ELSE
						Fail("Unsupported YAML escape");
						RETURN NIL
					END
				ELSE
					writer.Char(ch)
				END
			END;
			Fail("Unterminated quoted scalar");
			RETURN NIL
		END Quoted;

		PROCEDURE Colon(flow: BOOLEAN): SIGNED32;
		VAR i: SIGNED32;
			quote: CHAR;
		BEGIN
			i := pos;
			quote := 0X;
			WHILE i < length DO
				IF quote # 0X THEN
					IF (quote = 22X) & (line[i] = 5CX) THEN
						INC(i)
					ELSIF line[i] = quote THEN
						IF (quote = 27X) & (line[i + 1] = quote) THEN
							INC(i)
						ELSE
							quote := 0X
						END
					END
				ELSIF (i = pos) & ((line[i] = 22X) OR (line[i] = 27X)) THEN
					quote := line[i]
				ELSIF (line[i] = "#") & ((i = pos) OR (line[i - 1] = " ")) THEN
					RETURN -1
				ELSIF (line[i] = ":") & ((line[i + 1] = 0X) OR (line[i + 1] = " ") OR (line[i + 1] = 09X) OR (flow & ((line[pos] = 22X) OR (line[pos] = 27X)))) THEN
					RETURN i
				END;
				INC(i)
			END;
			RETURN -1
		END Colon;

		PROCEDURE Key(colon: SIGNED32): Strings.String;
		VAR key: Strings.String;
			last, i: SIGNED32;
		BEGIN
			IF (line[pos] = 22X) OR (line[pos] = 27X) THEN
				key := Quoted();
				Space;
				IF pos # colon THEN
					Fail("Invalid quoted mapping key")
				END
			ELSE
				last := colon;
				WHILE (last > pos) & (line[last - 1] = " ") DO
					DEC(last)
				END;
				IF (last = pos) OR Strings.ContainsChar("?&*!|>{[},%@`", line[pos], FALSE) THEN
					Fail("Unsupported YAML mapping key");
					RETURN NIL
				END;
				NEW(key, last - pos + 1);
				FOR i := pos TO last - 1 DO
					IF Strings.ContainsChar(",{}[]", line[i], FALSE) THEN
						Fail("Unsupported YAML mapping key");
						RETURN NIL
					END;
					key[i - pos] := line[i]
				END;
				key[last - pos] := 0X;
				IF ~(Scalar(key^) IS JSON.String) THEN
					Fail("Mapping keys must be strings; quote typed scalar keys");
					RETURN NIL
				END
			END;
			pos := colon + 1;
			Space;
			RETURN key
		END Key;

		PROCEDURE Scalar(CONST text: ARRAY OF CHAR): JSON.Value;
		VAR i, digits, base, digit: SIGNED32;
			number: FLOAT64;
		BEGIN
			IF (text = "") OR (text = "~") OR (text = "null") OR (text = "Null") OR (text = "NULL") THEN
				RETURN JSON.NewNull()
			ELSIF (text = "true") OR (text = "True") OR (text = "TRUE") THEN
				RETURN JSON.NewBool(TRUE)
			ELSIF (text = "false") OR (text = "False") OR (text = "FALSE") THEN
				RETURN JSON.NewBool(FALSE)
			END;
			IF (text = ".inf") OR (text = ".Inf") OR (text = ".INF") OR
				(text = "+.inf") OR (text = "-.inf") OR (text = "+.Inf") OR (text = "-.Inf") OR
				(text = "+.INF") OR (text = "-.INF") OR (text = ".nan") OR (text = ".NaN") OR (text = ".NAN") THEN
				Fail("Nonfinite YAML numbers are unsupported");
				RETURN NIL
			END;
			i := 0;
			IF (text[i] = "+") OR (text[i] = "-") THEN
				INC(i)
			END;
			IF (text[i] = "0") & ((text[i + 1] = "x") OR (text[i + 1] = "o")) THEN
				base := 16;
				IF text[i + 1] = "o" THEN
					base := 8
				END;
				INC(i, 2);
				digits := i;
				number := 0;
				WHILE Strings.IsDigit(text[i], base, digit) DO
					IF number > MAX(FLOAT64) / base THEN
						Fail("YAML number is out of range");
						RETURN NIL
					END;
					number := number * base + digit;
					INC(i)
				END;
				IF (i > digits) & (text[i] = 0X) THEN
					IF text[0] = "-" THEN
						number := -number
					END;
					RETURN JSON.NewNumber(number)
				END;
				RETURN JSON.NewString(text)
			END;
			digits := 0;
			WHILE (text[i] >= "0") & (text[i] <= "9") DO
				INC(i);
				INC(digits)
			END;
			IF text[i] = "." THEN
				INC(i);
				WHILE (text[i] >= "0") & (text[i] <= "9") DO
					INC(i);
					INC(digits)
				END
			END;
			IF digits = 0 THEN
				RETURN JSON.NewString(text)
			END;
			IF (text[i] = "e") OR (text[i] = "E") THEN
				INC(i);
				IF (text[i] = "+") OR (text[i] = "-") THEN
					INC(i)
				END;
				digits := i;
				WHILE (text[i] >= "0") & (text[i] <= "9") DO
					INC(i)
				END;
				IF i = digits THEN
					RETURN JSON.NewString(text)
				END
			END;
			IF text[i] # 0X THEN
				RETURN JSON.NewString(text)
			END;
			IF ~RealConversions.StringToReal(text, number) OR ~(ABS(number) <= MAX(FLOAT64)) THEN
				Fail("YAML number is out of range");
				RETURN NIL
			END;
			RETURN JSON.NewNumber(number)
		END Scalar;

		PROCEDURE Inline(depth: SIGNED32; flow: BOOLEAN): JSON.Value;
		VAR text: Strings.String;
			value: JSON.Value;
			array: JSON.Array;
			object: JSON.Object;
			first, last, i, colon: SIGNED32;
			close: CHAR;
		BEGIN
			INC(nodes);
			IF (depth > MaximumDepth) OR (nodes > MaximumNodes) THEN
				Fail("YAML nesting or node budget exceeded");
				RETURN NIL
			END;
			Space;
			IF (line[pos] = 22X) OR (line[pos] = 27X) THEN
				text := Quoted();
				IF text = NIL THEN
					RETURN NIL
				END;
				RETURN JSON.NewString(text^)
			ELSIF (line[pos] = "[") OR (line[pos] = "{") THEN
				close := "]";
				object := NIL;
				array := NIL;
				IF line[pos] = "{" THEN
					close := "}";
					object := JSON.NewObject()
				ELSE
					array := JSON.NewArray()
				END;
				INC(pos);
				Space;
				WHILE (line[pos] # close) & ~failed DO
					IF (line[pos] = 0X) OR (line[pos] = "#") OR (line[pos] = ",") THEN
						Fail("Flow collections must fit on one line");
						RETURN NIL
					END;
					IF object # NIL THEN
						colon := Colon(TRUE);
						IF colon < 0 THEN
							Fail("Expected a mapping key followed by ': '");
							RETURN NIL
						END;
						text := Key(colon);
						IF failed THEN
							RETURN NIL
						END;
						IF object.Get(text^) # NIL THEN
							Fail("Duplicate YAML mapping key");
							RETURN NIL
						END
					END;
					value := Inline(depth + 1, TRUE);
					IF failed THEN
						RETURN NIL
					END;
					IF object # NIL THEN
						object.Set(text^, value)
					ELSE
						array.Add(value)
					END;
					Space;
					IF line[pos] = "," THEN
						INC(pos);
						Space
					ELSIF line[pos] # close THEN
						Fail("Expected ',' or closing flow delimiter");
						RETURN NIL
					END
				END;
				INC(pos);
				IF object # NIL THEN
					RETURN object
				END;
				RETURN array
			END;
			IF flow & ((line[pos] = "]") OR (line[pos] = "}") OR (line[pos] = ",")) THEN
				RETURN JSON.NewNull()
			END;
			first := pos;
			IF Strings.ContainsChar("&*!|>%@`,]}", line[pos], FALSE) OR
				(((line[pos] = "-") OR (line[pos] = "?") OR (line[pos] = ":")) & (line[pos + 1] = " ")) THEN
				Fail("Unsupported YAML value indicator");
				RETURN NIL
			END;
			LOOP
				IF pos >= length THEN
					EXIT
				END;
				IF (line[pos] = "#") & ((pos = first) OR (line[pos - 1] = " ") OR (line[pos - 1] = 09X)) THEN
					EXIT
				ELSIF flow & Strings.ContainsChar(",[]{}", line[pos], FALSE) THEN
					EXIT
				ELSIF (line[pos] = ":") & ((line[pos + 1] = " ") OR (line[pos + 1] = 0X)) THEN
					Fail("Unexpected mapping inside a plain scalar");
					RETURN NIL
				END;
				INC(pos)
			END;
			last := pos;
			WHILE (last > first) & ((line[last - 1] = " ") OR (line[last - 1] = 09X)) DO
				DEC(last)
			END;
			NEW(text, last - first + 1);
			FOR i := first TO last - 1 DO
				text[i - first] := line[i]
			END;
			text[last - first] := 0X;
			RETURN Scalar(text^)
		END Inline;

		PROCEDURE Marker(CONST word: ARRAY OF CHAR): BOOLEAN;
		BEGIN
			RETURN (indent = 0) & (length >= 3) & (line[0] = word[0]) & (line[1] = word[1]) &
				(line[2] = word[2]) & ((line[3] = 0X) OR (line[3] = " ") OR (line[3] = 09X))
		END Marker;

		PROCEDURE Sequence(): BOOLEAN;
		BEGIN
			RETURN (line[pos] = "-") & ((line[pos + 1] = " ") OR (line[pos + 1] = 0X))
		END Sequence;

		PROCEDURE Block(level, depth: SIGNED32): JSON.Value;
		VAR object: JSON.Object;
			array: JSON.Array;
			value: JSON.Value;
			key: Strings.String;
			colon: SIGNED32;
			empty, compact: BOOLEAN;
		BEGIN
			INC(nodes);
			IF (depth > MaximumDepth) OR (nodes > MaximumNodes) THEN
				Fail("YAML nesting or node budget exceeded");
				RETURN NIL
			END;
			object := NIL;
			array := NIL;
			IF Sequence() THEN
				array := JSON.NewArray()
			ELSIF (line[pos] # "{") & (line[pos] # "[") & (Colon(FALSE) >= 0) THEN
				object := JSON.NewObject()
			ELSE
				value := Inline(depth, FALSE);
				EndLine;
				Next;
				RETURN value
			END;
			LOOP
				IF ~active OR (indent # level) OR failed THEN
					EXIT
				END;
				IF Marker("...") THEN
					EXIT
				END;
				compact := FALSE;
				IF array # NIL THEN
					IF ~Sequence() THEN
						Fail("Cannot mix a block sequence and mapping");
						RETURN NIL
					END;
					INC(pos);
					Space;
					IF (line[pos] # "{") & (line[pos] # "[") & (Colon(FALSE) >= 0) THEN
						indent := pos;
						value := Block(indent, depth + 1);
						array.Add(value);
						compact := TRUE
					END
				ELSE
					colon := Colon(FALSE);
					IF colon < 0 THEN
						Fail("Expected a mapping key followed by ': '");
						RETURN NIL
					END;
					key := Key(colon);
					IF failed THEN
						RETURN NIL
					END;
					IF object.Get(key^) # NIL THEN
						Fail("Duplicate YAML mapping key");
						RETURN NIL
					END
				END;
				IF ~compact THEN
					empty := (line[pos] = 0X) OR (line[pos] = "#");
					value := Inline(depth + 1, FALSE);
					EndLine;
					Next;
					IF active & (indent > level) THEN
						IF ~empty THEN
							Fail("Multiline scalars are unsupported");
							RETURN NIL
						END;
						value := Block(indent, depth + 1)
					END;
					IF object # NIL THEN
						object.Set(key^, value)
					ELSE
						array.Add(value)
					END
				END
			END;
			IF object # NIL THEN
				RETURN object
			END;
			RETURN array
		END Block;

		PROCEDURE Read(): JSON.Value;
		VAR value: JSON.Value;
		BEGIN
			IF active & Marker("---") THEN
				pos := 3;
				EndLine;
				Next
			END;
			value := JSON.NewNull();
			IF active & ~Marker("...") THEN
				value := Block(indent, 0)
			END;
			IF active & Marker("...") THEN
				pos := 3;
				EndLine;
				Next
			END;
			IF active THEN
				Fail("Invalid indentation or multiple YAML documents")
			END;
			RETURN value
		END Read;
	END Parser;

(* ParseStream reads one configuration document and clears the output on any syntax or resource error. *)
PROCEDURE ParseStream*(reader: Streams.Reader; VAR value: JSON.Value; VAR error: ARRAY OF CHAR): BOOLEAN;
VAR parser: Parser;
BEGIN
	value := NIL;
	error[0] := 0X;
	IF reader = NIL THEN
		COPY("Cannot read YAML stream", error);
		RETURN FALSE
	END;
	NEW(parser, reader);
	value := parser.Read();
	IF parser.failed THEN
		value := NIL;
		COPY(parser.message, error);
		RETURN FALSE
	END;
	RETURN TRUE
END ParseStream;

(* Parse accepts the same bounded configuration YAML from an in-memory string. *)
PROCEDURE Parse*(CONST text: ARRAY OF CHAR; VAR value: JSON.Value; VAR error: ARRAY OF CHAR): BOOLEAN;
VAR reader: Streams.StringReader;
BEGIN
	IF Strings.Length(text) > MaximumBytes THEN
		value := NIL;
		COPY("YAML exceeds the input budget", error);
		RETURN FALSE
	END;
	NEW(reader, Strings.Length(text) + 1);
	reader.Set(text);
	RETURN ParseStream(reader, value, error)
END Parse;

(* Load rejects missing or oversized files before allocating a YAML tree. *)
PROCEDURE Load*(CONST path: ARRAY OF CHAR; VAR value: JSON.Value; VAR error: ARRAY OF CHAR): BOOLEAN;
VAR file: Files.File;
	reader: Files.Reader;
BEGIN
	value := NIL;
	file := Files.Old(path);
	IF (file = NIL) OR (file.Length() > MaximumBytes) THEN
		COPY("Cannot read YAML file or file exceeds 1 MiB", error);
		RETURN FALSE
	END;
	Files.OpenReader(reader, file, 0);
	RETURN ParseStream(reader, value, error)
END Load;

PROCEDURE {TEST} Configuration*;
VAR value: JSON.Value;
	error: ARRAY 256 OF CHAR;
	text: ARRAY 256 OF CHAR;
BEGIN
	COPY("---", text);
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "player:");
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "  speed: 0.09 # comment");
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "  enabled: TRUE");
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "  name: 'O''Brien #1'");
	ASSERT(Parse(text, value, error));
	value := value(JSON.Object).Get("player");
	ASSERT(value(JSON.Object).Get("speed")(JSON.Number).value = 0.09);
	ASSERT(value(JSON.Object).Get("enabled")(JSON.Bool).value);
	ASSERT(value(JSON.Object).Get("name")(JSON.String).value^ = "O'Brien #1")
END Configuration;

PROCEDURE {TEST} Collections*;
VAR value: JSON.Value;
	error: ARRAY 256 OF CHAR;
	text: ARRAY 256 OF CHAR;
BEGIN
	COPY("- name: first", text);
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "  ammo: [0x10, 0o10, +1.5e2, null]");
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "- {name: second, ammo: []}");
	ASSERT(Parse(text, value, error));
	ASSERT(value(JSON.Array).length = 2);
	value := value(JSON.Array).At(0)(JSON.Object).Get("ammo");
	ASSERT(value(JSON.Array).At(0)(JSON.Number).value = 16);
	ASSERT(value(JSON.Array).At(1)(JSON.Number).value = 8);
	ASSERT(value(JSON.Array).At(2)(JSON.Number).value = 150);
	ASSERT(value(JSON.Array).At(3) IS JSON.Null)
END Collections;

PROCEDURE {TEST} QuotesAndPlainScalars*;
VAR value: JSON.Value;
	error: ARRAY 256 OF CHAR;
BEGIN
	ASSERT(Parse('"\u0041\U0001F600"', value, error));
	ASSERT(Strings.Length(value(JSON.String).value^) = 5);
	ASSERT(Parse("yes", value, error));
	ASSERT(value IS JSON.String);
	ASSERT(Parse("1e", value, error));
	ASSERT(value IS JSON.String);
	ASSERT(Parse("http://example/#anchor", value, error));
	ASSERT(value(JSON.String).value^ = "http://example/#anchor");
	ASSERT(Parse('{"quoted":1}', value, error));
	ASSERT(value(JSON.Object).Get("quoted")(JSON.Number).value = 1);
	ASSERT(Parse("{'O''Brien: key': 1}", value, error));
	ASSERT(value(JSON.Object).Get("O'Brien: key")(JSON.Number).value = 1);
	ASSERT(Parse("...", value, error));
	ASSERT(value IS JSON.Null);
	ASSERT(Parse("# comment", value, error));
	ASSERT(value IS JSON.Null)
END QuotesAndPlainScalars;

PROCEDURE {TEST} RejectMalformed*;
VAR value: JSON.Value;
	error: ARRAY 256 OF CHAR;
	text: ARRAY 128 OF CHAR;
BEGIN
	COPY("a: 1", text);
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "a: 2");
	ASSERT(~Parse(text, value, error));
	ASSERT((value = NIL) & (error[0] # 0X));
	ASSERT(~Parse("{a: 1, a: 2}", value, error));
	ASSERT(~Parse("[1, 2", value, error));
	ASSERT(~Parse("--- extra", value, error));
	ASSERT(~Parse("... extra", value, error));
	ASSERT(Parse("--- # comment", value, error));
	ASSERT(~Parse("[1,,2]", value, error));
	ASSERT(~Parse("{bad,key: 1}", value, error));
	ASSERT(~Parse("{1: one, 01: two}", value, error));
	ASSERT(Parse("{a: }", value, error));
	ASSERT(~Parse('"bad\q"', value, error));
	ASSERT(~Parse("a: &shared 2", value, error));
	ASSERT(~Parse("a: |", value, error));
	ASSERT(~Parse(".nan", value, error));
	ASSERT(~Parse("1e99999", value, error));
	COPY("a: 1", text);
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "  b: 2");
	ASSERT(~Parse(text, value, error));
	COPY("---", text);
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "a: 1");
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "---");
	ASSERT(~Parse(text, value, error))
END RejectMalformed;

PROCEDURE {TEST} BudgetsAndLineEndings*;
VAR value: JSON.Value;
	error: ARRAY 256 OF CHAR;
	text: ARRAY MaximumLine + 2 OF CHAR;
	i: SIGNED32;
BEGIN
	FOR i := 0 TO MaximumDepth + 1 DO
		text[i] := "["
	END;
	FOR i := MaximumDepth + 2 TO (MaximumDepth + 2) * 2 - 1 DO
		text[i] := "]"
	END;
	text[(MaximumDepth + 2) * 2] := 0X;
	ASSERT(~Parse(text, value, error));
	FOR i := 0 TO MaximumLine DO
		text[i] := "a"
	END;
	text[MaximumLine + 1] := 0X;
	ASSERT(~Parse(text, value, error));
	COPY("a: 1", text);
	Strings.AppendChar(text, 0DX);
	Strings.AppendChar(text, 0AX);
	Strings.Append(text, "b: 2");
	ASSERT(Parse(text, value, error));
	ASSERT(value(JSON.Object).size = 2);
	text[0] := 0EFX;
	text[1] := 0BBX;
	text[2] := 0BFX;
	text[3] := "a";
	text[4] := ":";
	text[5] := " ";
	text[6] := "1";
	text[7] := 0X;
	ASSERT(Parse(text, value, error));
	ASSERT(value(JSON.Object).Get("a")(JSON.Number).value = 1)
END BudgetsAndLineEndings;

PROCEDURE {TEST} StreamsAndFiles*;
VAR file: Files.File;
	writer: Files.Writer;
	reader: Files.Reader;
	value: JSON.Value;
	error: ARRAY 256 OF CHAR;
	result: SIGNED32;
BEGIN
	ASSERT(~ParseStream(NIL, value, error));
	ASSERT((value = NIL) & (error[0] # 0X));
	file := Files.New("yaml-reader-test.yaml");
	ASSERT(file # NIL);
	Files.OpenWriter(writer, file, 0);
	writer.String("speed: 2");
	writer.Char(0AX);
	writer.Update;
	file.Register0(result);
	ASSERT(result = Files.Ok);
	ASSERT(Load("yaml-reader-test.yaml", value, error));
	ASSERT(value(JSON.Object).Get("speed")(JSON.Number).value = 2);
	file := Files.New("yaml-control-test.yaml");
	Files.OpenWriter(writer, file, 0);
	writer.Char(0X);
	writer.Update;
	Files.OpenReader(reader, file, 0);
	ASSERT(~ParseStream(reader, value, error));
	ASSERT((value = NIL) & (error[0] # 0X))
END StreamsAndFiles;

PROCEDURE {TEST} ResourceLimits*;
VAR file: Files.File;
	writer: Files.Writer;
	bufferWriter: Streams.Writer;
	buffer: Streams.Buffer;
	text: Strings.String;
	bytes: POINTER TO ARRAY OF CHAR;
	value: JSON.Value;
	error: ARRAY 256 OF CHAR;
	i, result: SIGNED32;
BEGIN
	NEW(buffer, 64);
	bufferWriter := buffer.GetWriter();
	FOR i := 1 TO MaximumNodes + 1 DO
		bufferWriter.String("- 0");
		bufferWriter.Char(0AX)
	END;
	bufferWriter.Update;
	text := buffer.GetString();
	ASSERT(~Parse(text^, value, error));
	ASSERT((value = NIL) & (Strings.Pos("node budget", error) >= 0));
	NEW(bytes, MaximumBytes + 1);
	file := Files.New("yaml-oversized-test.yaml");
	ASSERT(file # NIL);
	Files.OpenWriter(writer, file, 0);
	writer.Bytes(bytes^, 0, LEN(bytes^));
	writer.Update;
	file.Register0(result);
	ASSERT(result = Files.Ok);
	ASSERT(~Load("yaml-oversized-test.yaml", value, error));
	ASSERT((value = NIL) & (Strings.Pos("exceeds 1 MiB", error) >= 0))
END ResourceLimits;

END YAML.
