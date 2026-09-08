MODULE FoxDocumentationScanner; (** AUTHOR ""; PURPOSE ""; *)

IMPORT Streams, Diagnostics, D := Debugging;

CONST
	(* scanner constants *)
	EOT* = 0X; LF* = 0AX; CR* = 0DX;
	Trace=FALSE;
TYPE

	Token*= ENUM
		EndOfText*, NewLine*, Header*, Pipe*, LeftItalic*, RightItalic*, LeftBold*, RightBold*, LeftUnderline*, RightUnderline*,
		LinkBegin*, LinkEnd*, Heading*, Number*, LeftDescription*, RightDescription*, Description*,
		Bullet*, Line*, CodeBegin*, CodeEnd*, LabelBegin*, LabelEnd*,
		LineBreak*, Section*, String*
	END;

	String*= POINTER TO ARRAY OF CHAR;

	Symbol*= RECORD
		position*: SIGNED32;
		token*: Token;
		level*: SIGNED32;
		string*: String;
		stringLength*: SIGNED32;
		hasWhitespace*: BOOLEAN;
	END;

	(** scanner reflects the following EBNF
	**)
	Scanner* = OBJECT
	VAR
		(* helper state information *)
		reader: Streams.Reader;   (* source *)
		diagnostics: Diagnostics.Diagnostics;   (* error logging *)

		ch: CHAR;   (* look-ahead character *)
		position-: SIGNED32;   (* current position *)
		prevToken: Token;

		(*
			source: name of the source code for reference in error outputs
			reader: input stream
			position: reference position (offset) of the input stream , for error output
			diagnostics: error output object
		*)
		PROCEDURE & InitializeScanner*(reader: Streams.Reader; position: SIGNED32; diagnostics: Diagnostics.Diagnostics);
		BEGIN
			SELF.reader := reader;
			SELF.diagnostics := diagnostics;
			(*	A text begins at the start of a line. prevToken was left unset, which is the first
				member of the enumeration -- EndOfText -- so `firstInLine` was FALSE on the first
				line and every construction that is only a construction there was something else:
				`= Title` was the literal `=`, `* item` was a closing bold, `----` was four dashes,
				`Note:` was a word with a colon. The first line of a doc comment is exactly where a
				heading goes. *)
			prevToken := Token.NewLine;
			ch := " ";
			IF reader = NIL THEN ch := EOT ELSE GetNextCharacter END;
			SELF.position := position;
		END InitializeScanner;

		(** get next character, end of text results in ch = EOT **)
		PROCEDURE GetNextCharacter;
		BEGIN
			ASSERT(ch # EOT);
			reader.Char(ch); INC(position);
		END GetNextCharacter;

		PROCEDURE Peek(): CHAR;
		BEGIN
			RETURN reader.Peek()
		END Peek;

		(*	Whether the character under the cursor ends the word being read. The end of the text
			ends it too: a comment whose last word is `*bold*` had its closing star read into the
			word, because IsWhitespace says no to EOT and nothing else asked. *)
		PROCEDURE BreaksLiteral(): BOOLEAN;
		BEGIN
			CASE ch OF
				"*", "_", "/","#":
					IF IsWhitespace(Peek(),TRUE) OR (Peek() = EOT) THEN RETURN TRUE END; (* right of bold, underline, italics and description *)
				|"]",">","\":
					IF ch = Peek() THEN RETURN TRUE END; (* right of link or label *)
				|"|": RETURN TRUE (* pipe in link or table *)
			ELSE
				RETURN FALSE
			END;
			RETURN FALSE
		END BreaksLiteral;

		PROCEDURE IdentifierStart(ch: CHAR): BOOLEAN;
		BEGIN
			CASE ch OF
				| 'a' .. 'z', 'A' .. 'Z', '_': RETURN TRUE
			ELSE RETURN FALSE
			END;
		END IdentifierStart;

		PROCEDURE AppendCharacter(VAR symbol: Symbol; ch: CHAR);
		VAR s: String;  i: SIGNED32;
		BEGIN
			IF symbol.string = NIL THEN NEW(symbol.string,32); symbol.stringLength := 0; END;
			IF symbol.stringLength = LEN(symbol.string)-1 THEN
				s := symbol.string;
				NEW(symbol.string, symbol.stringLength*2);
				FOR i := 0 TO symbol.stringLength DO
					symbol.string[i] := s[i];
				END;
			END;
			symbol.string[symbol.stringLength] := ch;
			INC(symbol.stringLength);
		END AppendCharacter;

		PROCEDURE AppendCharacters(VAR symbol: Symbol; ch: CHAR; number: SIGNED32);
		BEGIN
			WHILE number > 0 DO
				AppendCharacter(symbol,ch); DEC(number)
			END;
		END AppendCharacters;

		PROCEDURE ReadLiteral(VAR symbol: Symbol; token: Token);
		BEGIN
			symbol.token := token;
			REPEAT (* consumes at least one character *)
				AppendCharacter(symbol, ch);
				GetNextCharacter;
			UNTIL (ch <= " ") OR BreaksLiteral();
		END ReadLiteral;

		PROCEDURE ReadLiteralWS(VAR symbol: Symbol; token: Token);
		BEGIN
			symbol.token := token;
			REPEAT (* consumes at least one character *)
				AppendCharacter(symbol, ch);
				GetNextCharacter;
			UNTIL (ch <= " ");
		END ReadLiteralWS;

		(*	A run of the same character, and how many of them the construction needs. The two
			bounds were joined with OR, and one of them always holds -- a level below the minimum
			is below the maximum too -- so every run was accepted whatever its length and the
			branch below was unreachable. That is why a single `<` was a label, a single `[` a
			link, a single `{` a code block and one dash a horizontal rule. *)
		PROCEDURE ReadCharacters(this: CHAR; min,max: SIGNED32; VAR symbol: Symbol; token: Token);
		BEGIN
			symbol.level := 0;
			WHILE (ch = this) DO INC(symbol.level); GetNextCharacter END;
			IF (symbol.level >= min) & (symbol.level <= max) THEN
				symbol.token := token;
			ELSE
				(*	Not a construction after all, so the characters are text. `ch` already stands
					past the run, and ReadLiteral consumes at least one character whatever it is --
					which would eat the line ending after `---` into the word. So it is only asked
					for a character that can be part of a word. The level belonged to the
					construction that this turned out not to be. *)
				AppendCharacters(symbol, this, symbol.level);
				symbol.level := 0;
				IF (ch > " ") & ~BreaksLiteral() THEN
					ReadLiteral(symbol, Token.String)
				ELSE
					symbol.token := Token.String
				END
			END;
		END ReadCharacters;

		PROCEDURE IsWhitespace(ch: CHAR; includeNewLine: BOOLEAN): BOOLEAN;
		BEGIN
			RETURN (ch <= " ") & (ch # EOT) & (includeNewLine OR (ch # CR) & (ch # LF))
		END IsWhitespace;

		(** get next symbol **)
		PROCEDURE GetNextSymbol*(VAR symbol: Symbol);
		VAR s: Token; prev: CHAR; firstInLine: BOOLEAN;

			PROCEDURE SkipBlanks;
			BEGIN
				WHILE IsWhitespace(ch,FALSE) DO  (*ignore control characters*)
					prev := ch;
					GetNextCharacter
				END;
			END SkipBlanks;

			(*	Everything up to the three braces that close the block. The decision used to be
				made on the character AFTER them -- which read that character into the string and
				then took four off the length to lose it again -- so a block that ended the text
				had no character after it, fell out of the loop as end of text, and took the code
				with it. A doc comment very often ends with its example. *)
			PROCEDURE ReadCode;
			VAR ending: SIGNED32; end: BOOLEAN;
			BEGIN
				ending := 0; end := FALSE;
				LOOP
					IF ch = EOT THEN EXIT END;
					AppendCharacter(symbol, ch);
					IF ch = "}" THEN INC(ending) ELSE ending := 0 END;
					GetNextCharacter;
					(*	`'}}}'` and `"}}}"` are how the documentation of this markup refers to the
						braces themselves, so they do not close a block. *)
					IF (ending = 3) & (ch # "'") & (ch # '"') THEN end := TRUE; EXIT END
				END;
				IF end THEN
					symbol.token := Token.CodeEnd;
					DEC(symbol.stringLength,3);
					symbol.string[symbol.stringLength] := 0X
				ELSE
					symbol.token := Token.EndOfText
				END;
			END ReadCode;

			(* return if the current character is preceded by a whitespace and next character is not a whitespace, such as in the beginning of *b o l d*  *)
			PROCEDURE IsLeft(): BOOLEAN;
			BEGIN
				RETURN IsWhitespace(prev,FALSE) & ~IsWhitespace(Peek(),FALSE)
			END IsLeft;

			(*	return if the current character is preceded by a non-whitespace and next character is
				a whitespace, such as at the end of *b o l d*. The end of the text closes as well:
				IsWhitespace says no to EOT on purpose, and without this a comment ending in
				`*bold*` kept the last star as a letter. *)
			PROCEDURE IsRight(): BOOLEAN;
			BEGIN
				RETURN ~IsWhitespace(prev,TRUE) & (IsWhitespace(Peek(),TRUE) OR (Peek() = EOT))
			END IsRight;

		BEGIN
			symbol.stringLength := 0;
			symbol.string := NIL;
			symbol.level := 0;
			symbol.position := position;

			prev := ch;
			SkipBlanks;
			firstInLine := prevToken = Token.NewLine;

			symbol.hasWhitespace := IsWhitespace(prev, FALSE);

			IF symbol.token = Token.CodeBegin THEN
				ReadCode;
				RETURN
			END;

			CASE ch OF  (* ch > " " *)
			EOT: symbol.token := Token.EndOfText
			| CR: symbol.token := Token.NewLine; GetNextCharacter; IF ch = LF THEN GetNextCharacter END;
			| LF: symbol.token := Token.NewLine; GetNextCharacter; IF ch = CR THEN GetNextCharacter END;
			|  '|': GetNextCharacter;
				IF (ch = "=") THEN symbol.token := Token.Header; GetNextCharacter ELSE symbol.token := Token.Pipe END;
			|  '/':
				IF IsLeft() THEN  symbol.token := Token.LeftItalic; GetNextCharacter;
				ELSIF IsRight() THEN symbol.token := Token.RightItalic; GetNextCharacter;
				ELSE ReadLiteral( symbol, Token.String)
				END
			|  '_':
				IF IsLeft() THEN  symbol.token := Token.LeftUnderline;GetNextCharacter;
				ELSIF IsRight() THEN symbol.token := Token.RightUnderline;GetNextCharacter;
				ELSE ReadLiteral( symbol, Token.String)
				END
			|  '[': ReadCharacters (ch, 2, 2, symbol, Token.LinkBegin);
			|  ']': ReadCharacters (ch, 2, 2, symbol, Token.LinkEnd);
			|  '=':
				IF firstInLine THEN
					ReadCharacters (ch, 1, 3, symbol, Token.Heading);
					IF IdentifierStart(ch) THEN
						WHILE ~IsWhitespace(ch,TRUE) & (ch#EOT) DO
							AppendCharacter(symbol,ch);
							GetNextCharacter;
						END;
					END;
				ELSE ReadLiteral(symbol, Token.String);
				END;
			|  '#':
				IF firstInLine THEN (* number *)
					ReadCharacters(ch, 1, 3, symbol, Token.Number);
					IF IsWhitespace(ch,FALSE) THEN
						symbol.token := Token.Number;
					ELSIF symbol.level = 1 THEN
						symbol.token := Token.LeftDescription;
					ELSE
						ReadLiteral(symbol, Token.String);
					END;
				ELSE
					IF IsLeft() THEN symbol.token := Token.LeftDescription; symbol.level := 1; GetNextCharacter;
					ELSIF IsRight() THEN symbol.token := Token.RightDescription;GetNextCharacter;
					ELSE ReadLiteral(symbol, Token.String);
					END;
				END;
			|  '*':
				IF firstInLine THEN
					ReadCharacters(ch, 1, 3, symbol, Token.Bullet);
					IF IsWhitespace(ch,FALSE) THEN
						symbol.token := Token.Bullet;
					ELSIF symbol.level = 1 THEN
						symbol.token := Token.LeftBold;
					ELSE
						AppendCharacters(symbol, '*', symbol.level);
						ReadLiteral(symbol, Token.String);
					END;
				ELSE
					IF IsLeft() THEN symbol.token := Token.LeftBold;GetNextCharacter;
					ELSIF  IsRight() THEN symbol.token := Token.RightBold;GetNextCharacter;
					ELSE ReadLiteral(symbol, Token.String);
					END;
				END;
			|  '-':
				IF firstInLine THEN ReadCharacters (ch, 4, MAX(SIGNED32), symbol, Token.Line)
				ELSE ReadLiteral(symbol, Token.String);
				END;
			|  '{': ReadCharacters (ch, 3, 3, symbol, Token.CodeBegin);
			|  '}': ReadCharacters (ch, 3, 3, symbol, Token.CodeEnd);
			|  '<':
				ReadCharacters (ch, 2, 2, symbol, Token.LabelBegin);
				IF IsWhitespace(ch, TRUE) & (symbol.level = 2) THEN
					AppendCharacters(symbol,'<',2);
					symbol.token := Token.String
				END;
			|  '>':
				ReadCharacters (ch, 2, 2, symbol, Token.LabelEnd);
				IF IsWhitespace(prev, FALSE) & (symbol.level = 2) THEN
					AppendCharacters(symbol,'>',2);
					ReadLiteral(symbol, Token.String);
				END;
			|  '\':
				ReadCharacters (ch, 2, 2, symbol, Token.LineBreak);
			|  '@': ReadCharacters (ch, 1, 10, symbol, Token.Section);
				IF IdentifierStart(ch) THEN
					WHILE ~IsWhitespace(ch,TRUE) & (ch#EOT) DO
						AppendCharacter(symbol,ch);
						GetNextCharacter;
					END;
				END;
			ELSE
				ReadLiteral(symbol,Token.String)
			END;
			prevToken := symbol.token;

			IF (firstInLine) & (symbol.token = Token.String) & (symbol.stringLength>0) & (symbol.string[symbol.stringLength-1] = ":") THEN
				DEC(symbol.stringLength);
				symbol.string[symbol.stringLength] := 0X;
				symbol.token := Token.Description;
			END;

			IF Trace THEN DumpSymbol(D.Log, symbol); D.Ln END;
		END GetNextSymbol;

	END Scanner;

	PROCEDURE DumpSymbol(w: Streams.Writer; CONST symbol: Symbol);
	BEGIN
		w.String("token: ");
		CASE symbol.token OF
			Token.EndOfText: w.String("EndOfText");
			|Token.NewLine: w.String("NewLine");
			|Token.Header:w.String("Header");
			|Token.Pipe:w.String("Pipe");
			|Token.LeftItalic:w.String("LeftItalic");
			|Token.RightItalic:w.String("RightItalic");
			|Token.LinkBegin:w.String("LinkBegin");
			|Token.LinkEnd:w.String("LinkEnd");
			|Token.Heading:w.String("Heading");
			|Token.Number:w.String("Number");
			|Token.Bullet:w.String("Bullet");
			|Token.LeftBold:w.String("LeftBold");
			|Token.RightBold:w.String("RightBold");
			|Token.LeftUnderline:w.String("LeftUnderline");
			|Token.RightUnderline:w.String("RightUnderline");
			|Token.Line:w.String("Line");
			|Token.CodeBegin:w.String("CodeBegin");
			|Token.CodeEnd:w.String("CodeEnd");
			|Token.LabelBegin:w.String("LabelBegin");
			|Token.LabelEnd:w.String("LabelEnd");
			|Token.LineBreak:w.String("LineBreak");
			|Token.Section:w.String("Section");
			|Token.String:w.String("String");
		END;
	END DumpSymbol;

END FoxDocumentationScanner.
