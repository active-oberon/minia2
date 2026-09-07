MODULE H2ao;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "C headers to Active Oberon bindings"; *)

(*
	`ob bind <header.h>` -- the bindings written out instead of by hand.

	What this is NOT is a translator of C. Bodies stay in C and are called where they are: the
	output is a module of `PROCEDURE {PlatformCC}` variables resolved from the shared library at
	load time, which is the shape `OpenAL.Mod` and `Unix.Sockets.Mod` already have in this tree,
	only written by a machine and complete.

	The header is not parsed here either. `clang -Xclang -ast-dump=json` has already parsed it, and
	every type in that dump comes with its C spelling (`type.qualType`), so the work is a table of
	correspondences and the printing of a module -- not a C front end. Two runs of the compiler are
	made: the AST, and `-E -dM` for the macros, which the AST does not keep.

	What does not carry over is named, not hidden: every declaration this refuses is written into
	the generated module's own header comment with the reason, and counted. That list is the honest
	part of the tool -- varargs, unions, bit fields, `long double`, anything whose type the header
	spells in words rather than in types.
*)

IMPORT Strings, Streams, Files, JSON, Processes, Dates;

CONST
	Tool* = "h2ao 1";

	MaxName* = 256;
	MaxType* = 1024;
	MaxPath* = 1024;

	(*	What a remembered name is. `Alias` and `Emitted` answer "what does this C name mean",
		`Number` and `Text` answer "what did this macro come out as". *)
	Alias = 0;			(* a typedef from anywhere in the translation unit *)
	Emitted = 1;			(* a type this module declares under its own name *)
	Number = 2;			(* a macro that came out an integer *)
	Text = 3;			(* a macro that came out a string *)

	(*	Where a type stands. A C pointer to characters can be an open array in a parameter, where
		a literal is worth passing; it cannot be one in a field or a result. *)
	Parameter = 0; Field = 1; Result = 2;

	Depth = 16;			(* how far a typedef chain is followed before it is called a cycle *)
	MaxFields = 512;		(* members of one record; beyond that the record is refused, not cut *)

TYPE
	Name* = ARRAY MaxName OF CHAR;
	Spelling* = ARRAY MaxType OF CHAR;
	Path* = ARRAY MaxPath OF CHAR;

	Entry = POINTER TO RECORD
		name: Name;
		text: Spelling;			(* Alias: what it stands for. Text: the string, quoted *)
		number: SIGNED64;			(* Number: the value *)
		kind: SIGNED32;
		(*	Emitted: what the type measures, in bytes, on each of the two platforms -- 0 when this
			generator could not work it out. A union member and an array element have to be
			measured, and C `long` makes that two answers rather than one. *)
		sizeWin, sizeUnix, alignWin, alignUnix: SIZE;
		next: Entry
	END;

	(*	One member of a record, after its type has been read. A bit field also carries where it
		landed: which storage word, and which bit of that word is its least significant. *)
	Slot = POINTER TO RECORD
		name: Name;				(* "" for an unnamed bit field, which is padding and nothing else *)
		c: Spelling;				(* the C type as clang spelled it: a run of bit fields must agree on it *)
		ao: Spelling;
		bits: SIGNED32;			(* 0 when it is not a bit field *)
		signed: BOOLEAN;
		unit, shift: SIGNED32;
		storage: Name;			(* the name of the word it lives in *)
		unitType: Name;			(* and that word's type: two runs in one record can differ *)
		next: Slot
	END;

	(* a declaration that did not make it into the module, and the reason it did not *)
	Note = POINTER TO RECORD
		name: Name;
		reason: Spelling;
		next: Note
	END;

	(*	Everything a run is told. The command line fills it, and so does a test: `Generate` takes
		this and a parsed AST, and knows nothing about how either was come by. *)
	Settings* = RECORD
		module*: Name;			(* MODULE name of the output; "" means: from the header's own name *)
		header*: Path;			(* the header as clang was given it *)
		libraries*: Spelling;		(* the shared libraries to try, in order, comma separated *)
		prefixes*: Spelling;		(* C prefixes to drop from names, comma separated *)
		compiler*: Path;			(* the C compiler to ask; "" means: find one *)
		includes*: Spelling;		(* -I directories, comma separated *)
		records*: BOOLEAN;		(* translate complete structs and unions *)
		varargs*: SIGNED32;		(* how many fixed-arity wrappers to write for a variadic function *)
	END;

VAR
	aliases, emitted, macros: Entry;
	notes, lastNote: Note;
	wrapped, lastWrapped: Note;		(* the variadic functions, and what they came out as *)
	functions, typeCount, constants, dataCount, skipped, macroCount, listed: SIGNED32;
	longUsed, wideUsed: BOOLEAN;		(* whether the platform aliases are needed after all *)
	cNames, aoNames: ARRAY 64 OF Name;	(* the builtin table, filled in the body *)
	builtins: SIGNED32;
	depth: SIGNED32;

(* --- strings ----------------------------------------------------------------------------- *)

PROCEDURE IsBlank(character: CHAR): BOOLEAN;
BEGIN
	RETURN (character = ' ') OR (character = 09X) OR (character = 0DX) OR (character = 0AX)
END IsBlank;

PROCEDURE IsLetter(character: CHAR): BOOLEAN;
BEGIN
	RETURN ((character >= 'a') & (character <= 'z')) OR ((character >= 'A') & (character <= 'Z'))
END IsLetter;

PROCEDURE IsDigit(character: CHAR): BOOLEAN;
BEGIN
	RETURN (character >= '0') & (character <= '9')
END IsDigit;

PROCEDURE IsHexDigit(character: CHAR): BOOLEAN;
BEGIN
	RETURN IsDigit(character) OR ((character >= 'a') & (character <= 'f'))
		OR ((character >= 'A') & (character <= 'F'))
END IsHexDigit;

(* Blanks off both ends, in place. *)
PROCEDURE Trim(VAR text: ARRAY OF CHAR);
VAR first, last, index: SIZE;
BEGIN
	last := Strings.Length(text);
	WHILE (last > 0) & IsBlank(text[last - 1]) DO DEC(last) END;
	first := 0;
	WHILE (first < last) & IsBlank(text[first]) DO INC(first) END;
	IF first > 0 THEN
		index := 0;
		WHILE first < last DO text[index] := text[first]; INC(index); INC(first) END;
		text[index] := 0X
	ELSE
		text[last] := 0X
	END
END Trim;

(*	Does `text` begin with `word` as a word of its own -- `const x` and not `constant`? The
	distinction matters: `struct` is a tag to be dropped, `structure` is somebody's type name. *)
PROCEDURE Starts(CONST text, word: ARRAY OF CHAR): BOOLEAN;
VAR length: SIZE;
BEGIN
	length := Strings.Length(word);
	IF Strings.Length(text) < length THEN RETURN FALSE END;
	RETURN (Strings.Pos(word, text) = 0) & ((text[length] = 0X) OR IsBlank(text[length]))
END Starts;

(* `word` off the front of `text`, blanks and all, if it is there. *)
PROCEDURE Cut(VAR text: ARRAY OF CHAR; CONST word: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF ~Starts(text, word) THEN RETURN FALSE END;
	Strings.Delete(text, 0, Strings.Length(word));
	Trim(text);
	RETURN TRUE
END Cut;

(*	A piece of a comma separated list; FALSE when there are no more. `position` walks. *)
PROCEDURE NextPiece(CONST list: ARRAY OF CHAR; VAR position: SIZE; VAR piece: ARRAY OF CHAR): BOOLEAN;
VAR index: SIZE;
BEGIN
	IF position >= Strings.Length(list) THEN RETURN FALSE END;
	index := 0;
	WHILE (position < Strings.Length(list)) & (list[position] # ',') DO
		IF index + 1 < LEN(piece) THEN piece[index] := list[position]; INC(index) END;
		INC(position)
	END;
	piece[index] := 0X;
	IF (position < Strings.Length(list)) & (list[position] = ',') THEN INC(position) END;
	Trim(piece);
	RETURN TRUE
END NextPiece;

(* Would `text` fit in a buffer of `size` characters? A name that does not is refused, not cut. *)
PROCEDURE Fits(CONST text: ARRAY OF CHAR; size: SIZE): BOOLEAN;
BEGIN
	RETURN Strings.Length(text) + 1 < size
END Fits;

(* --- what we know about a name ----------------------------------------------------------- *)

PROCEDURE Find(list: Entry; CONST name: ARRAY OF CHAR): Entry;
BEGIN
	WHILE list # NIL DO
		IF list.name = name THEN RETURN list END;
		list := list.next
	END;
	RETURN NIL
END Find;

PROCEDURE Remember(VAR list: Entry; CONST name, text: ARRAY OF CHAR; number: SIGNED64; kind: SIGNED32);
VAR entry: Entry;
BEGIN
	entry := Find(list, name);
	IF entry = NIL THEN
		NEW(entry); COPY(name, entry.name); entry.next := list; list := entry
	END;
	COPY(text, entry.text); entry.number := number; entry.kind := kind
END Remember;

(*	What an emitted type measures. Kept beside the name because the next union or array over it
	cannot be laid out without these four numbers. *)
PROCEDURE RememberExtent(CONST name: ARRAY OF CHAR; sizeWin, sizeUnix, alignWin, alignUnix: SIZE);
VAR entry: Entry;
BEGIN
	entry := Find(emitted, name);
	IF entry # NIL THEN
		entry.sizeWin := sizeWin; entry.sizeUnix := sizeUnix;
		entry.alignWin := alignWin; entry.alignUnix := alignUnix
	END
END RememberExtent;

(*	The other way round: from the Active Oberon name back to the entry. The tables are keyed by the
	C name, and a type inside a type is met under the name this module gave it. *)
PROCEDURE FindEmitted(CONST ao: ARRAY OF CHAR): Entry;
VAR entry: Entry;
BEGIN
	entry := emitted;
	WHILE entry # NIL DO
		IF (entry.kind = Emitted) & (entry.text = ao) THEN RETURN entry END;
		entry := entry.next
	END;
	RETURN NIL
END FindEmitted;

(*	Something the module will not contain. Kept in the order it was found, because that is the
	order of the header, and printed into the generated module's own comment. *)
PROCEDURE Complain(CONST name, reason: ARRAY OF CHAR);
VAR note: Note;
BEGIN
	NEW(note); COPY(name, note.name); COPY(reason, note.reason); note.next := NIL;
	IF lastNote = NIL THEN notes := note ELSE lastNote.next := note END;
	lastNote := note;
	INC(skipped)
END Complain;

(*	A variadic function, and the wrappers it came out as. Kept apart from the refusals: this is
	not a loss, it is a translation with a condition on it, and the two lists say different
	things. *)
PROCEDURE Wrap(CONST name, wrappers: ARRAY OF CHAR);
VAR note: Note;
BEGIN
	NEW(note); COPY(name, note.name); COPY(wrappers, note.reason); note.next := NIL;
	IF lastWrapped = NIL THEN wrapped := note ELSE lastWrapped.next := note END;
	lastWrapped := note
END Wrap;

(* --- Active Oberon names ----------------------------------------------------------------- *)

(*	A C name that Active Oberon cannot spell. Underscores and digits it can (this compiler takes
	`sqlite3_open` as an identifier, which is why nothing is renamed here); a leading underscore
	or digit it cannot, and a keyword it will not. Keywords are upper case in this language and C
	names are not, so the second case is nearly theory -- nearly. *)
PROCEDURE Keyword(CONST name: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN (name = "ARRAY") OR (name = "BEGIN") OR (name = "BY") OR (name = "CASE") OR (name = "CODE")
		OR (name = "CONST") OR (name = "DIV") OR (name = "DO") OR (name = "ELSE") OR (name = "ELSIF")
		OR (name = "END") OR (name = "EXIT") OR (name = "FALSE") OR (name = "FOR") OR (name = "IF")
		OR (name = "IMPORT") OR (name = "IN") OR (name = "IS") OR (name = "LOOP") OR (name = "MOD")
		OR (name = "MODULE") OR (name = "NIL") OR (name = "OBJECT") OR (name = "OF") OR (name = "OR")
		OR (name = "POINTER") OR (name = "PROCEDURE") OR (name = "RECORD") OR (name = "REPEAT")
		OR (name = "RETURN") OR (name = "THEN") OR (name = "TO") OR (name = "TRUE") OR (name = "TYPE")
		OR (name = "UNTIL") OR (name = "VAR") OR (name = "WHILE") OR (name = "WITH")
END Keyword;

PROCEDURE Spellable(CONST name: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF (name = "") OR ~IsLetter(name[0]) THEN RETURN FALSE END;
	RETURN ~Keyword(name)
END Spellable;

(*	The name as the module will carry it: the C name, with any of the prefixes the caller named
	taken off -- but only when what is left is still a name. `sqlite3_` off `sqlite3_open` leaves
	`open`; off `sqlite3_int64` it leaves `int64`, which is a name too; a prefix that leaves a
	digit or nothing at all is not applied. *)
PROCEDURE Exported(CONST name, prefixes: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
VAR prefix: Name; position, length: SIZE;
BEGIN
	COPY(name, result);
	position := 0;
	WHILE NextPiece(prefixes, position, prefix) DO
		length := Strings.Length(prefix);
		IF (prefix # "") & (length < Strings.Length(name)) & (Strings.Pos(prefix, name) = 0) THEN
			IF IsLetter(name[length]) THEN
				Strings.Copy(name, length, Strings.Length(name) - length, result);
				RETURN Spellable(result)
			END
		END
	END;
	RETURN Spellable(result)
END Exported;

(* --- how much room a type takes ----------------------------------------------------------- *)

(*
	The size and the alignment of a type this module emits -- two of each, because C `long` is four
	bytes on Windows and eight on Unix, and one generated file serves both. Only 64-bit targets are
	described: this is where ADDRESS is eight bytes, and the SDK ships no 32-bit binding.

	FALSE means "this generator cannot say", and the caller must then refuse whatever needed the
	answer rather than guess it. Nothing here is assumed: the numbers were checked against C's own
	`sizeof` and `offsetof` on both hosts.
*)
PROCEDURE Extent(CONST ao: ARRAY OF CHAR; VAR sizeWin, sizeUnix, alignWin, alignUnix: SIZE): BOOLEAN;
VAR work, element: Spelling; count: SIGNED64; position: SIZE; entry: Entry; ok: BOOLEAN;
BEGIN
	IF depth > Depth THEN RETURN FALSE END;
	COPY(ao, work); Trim(work);
	IF (work = "ADDRESS") OR (work = "SIZE") OR (work = "SIGNED64") OR (work = "UNSIGNED64")
		OR (work = "FLOAT64") OR Starts(work, "PROCEDURE") THEN
		sizeWin := 8; sizeUnix := 8
	ELSIF (work = "SIGNED32") OR (work = "UNSIGNED32") OR (work = "FLOAT32") THEN
		sizeWin := 4; sizeUnix := 4
	ELSIF (work = "SIGNED16") OR (work = "UNSIGNED16") THEN
		sizeWin := 2; sizeUnix := 2
	ELSIF (work = "CHAR") OR (work = "SIGNED8") OR (work = "UNSIGNED8") OR (work = "BOOLEAN") THEN
		sizeWin := 1; sizeUnix := 1
	ELSIF (work = "SignedLong") OR (work = "UnsignedLong") THEN
		sizeWin := 4; sizeUnix := 8
	ELSIF work = "WideChar" THEN
		sizeWin := 2; sizeUnix := 4
	ELSIF Starts(work, "ARRAY") THEN
		(* `ARRAY n OF T`: n elements in place, aligned as one of them *)
		Strings.Delete(work, 0, 5); Trim(work);
		position := Strings.Pos(" OF ", work);
		IF position = -1 THEN RETURN FALSE END;
		Strings.Copy(work, 0, position, element); Trim(element);
		IF ~Strings.TryParseInt64(element, count) OR (count <= 0) THEN RETURN FALSE END;
		Strings.Delete(work, 0, position + 4); Trim(work);
		INC(depth); ok := Extent(work, sizeWin, sizeUnix, alignWin, alignUnix); DEC(depth);
		IF ~ok THEN RETURN FALSE END;
		sizeWin := sizeWin * SIZE(count); sizeUnix := sizeUnix * SIZE(count);
		RETURN TRUE			(* the alignment is the element's, and it is already set *)
	ELSE
		entry := FindEmitted(work);
		IF (entry = NIL) OR (entry.sizeWin = 0) OR (entry.sizeUnix = 0) THEN RETURN FALSE END;
		sizeWin := entry.sizeWin; sizeUnix := entry.sizeUnix;
		alignWin := entry.alignWin; alignUnix := entry.alignUnix;
		RETURN TRUE
	END;
	(* everything above but the two aggregates is aligned as wide as it is *)
	alignWin := sizeWin; alignUnix := sizeUnix;
	RETURN TRUE
END Extent;

(*	A value SYSTEM.GET and SYSTEM.PUT can move in one go. An array or a record cannot, and a
	procedure variable is not worth the argument, so those are reached by address instead. *)
PROCEDURE IsScalar(CONST ao: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN (ao = "ADDRESS") OR (ao = "SIZE") OR (ao = "CHAR") OR (ao = "BOOLEAN")
		OR (ao = "SIGNED8") OR (ao = "SIGNED16") OR (ao = "SIGNED32") OR (ao = "SIGNED64")
		OR (ao = "UNSIGNED8") OR (ao = "UNSIGNED16") OR (ao = "UNSIGNED32") OR (ao = "UNSIGNED64")
		OR (ao = "FLOAT32") OR (ao = "FLOAT64")
		OR (ao = "SignedLong") OR (ao = "UnsignedLong") OR (ao = "WideChar")
END IsScalar;

(* Two to the power of, for the shifts and masks a bit field is read with. *)
PROCEDURE Power(exponent: SIGNED32): SIGNED64;
VAR value: SIGNED64; index: SIGNED32;
BEGIN
	value := 1;
	FOR index := 1 TO exponent DO value := value * 2 END;
	RETURN value
END Power;

(*	The unsigned type of that many bytes. A bit field's storage word is a width and not a
	signedness: the extraction below is arithmetic, and a top bit that means minus would break it.
	The sign of the field itself is put back by its own reader. *)
PROCEDURE Storage(size: SIZE; VAR ao: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF size = 1 THEN ao := "UNSIGNED8"
	ELSIF size = 2 THEN ao := "UNSIGNED16"
	ELSIF size = 4 THEN ao := "UNSIGNED32"
	ELSIF size = 8 THEN ao := "UNSIGNED64"
	ELSE RETURN FALSE
	END;
	RETURN TRUE
END Storage;

(* The signed type of that many bytes, for a bit field declared signed. *)
PROCEDURE Signed(size: SIZE; VAR ao: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF size = 1 THEN ao := "SIGNED8"
	ELSIF size = 2 THEN ao := "SIGNED16"
	ELSIF size = 4 THEN ao := "SIGNED32"
	ELSIF size = 8 THEN ao := "SIGNED64"
	ELSE RETURN FALSE
	END;
	RETURN TRUE
END Signed;

(* The type of the array that gives a union its room and its alignment in one. *)
PROCEDURE Alignment(align: SIZE; VAR ao: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF align = 1 THEN ao := "CHAR"
	ELSIF align = 2 THEN ao := "UNSIGNED16"
	ELSIF align = 4 THEN ao := "UNSIGNED32"
	ELSIF align = 8 THEN ao := "UNSIGNED64"
	ELSE RETURN FALSE
	END;
	RETURN TRUE
END Alignment;

(* Up to the next multiple of `to`, which is what C does to an offset before it puts a field there. *)
PROCEDURE RoundUp(value, to: SIZE): SIZE;
BEGIN
	IF to <= 1 THEN RETURN value END;
	IF value MOD to # 0 THEN INC(value, to - value MOD to) END;
	RETURN value
END RoundUp;

PROCEDURE Bigger(one, other: SIZE): SIZE;
BEGIN
	IF one > other THEN RETURN one ELSE RETURN other END
END Bigger;

(* --- C types to Active Oberon types ------------------------------------------------------ *)

(*	One parameter, into a text. `CONST` stands before the name in this language and after the colon
	in the answer the mapper gives, so it is moved -- here, and in one place. *)
PROCEDURE AppendParameter(VAR text: ARRAY OF CHAR; CONST name, mapped: ARRAY OF CHAR);
VAR rest: Spelling;
BEGIN
	IF Starts(mapped, "CONST") THEN
		Strings.Copy(mapped, 6, Strings.Length(mapped) - 6, rest); Trim(rest);
		Strings.AppendX(text, "CONST "); Strings.AppendX(text, name);
		Strings.AppendX(text, ": "); Strings.AppendX(text, rest)
	ELSE
		Strings.AppendX(text, name); Strings.AppendX(text, ": "); Strings.AppendX(text, mapped)
	END
END AppendParameter;

PROCEDURE DefineBuiltin(CONST c, ao: ARRAY OF CHAR);
BEGIN
	ASSERT(builtins < LEN(cNames));
	COPY(c, cNames[builtins]); COPY(ao, aoNames[builtins]); INC(builtins)
END DefineBuiltin;

PROCEDURE Builtin(CONST c: ARRAY OF CHAR; VAR ao: ARRAY OF CHAR): BOOLEAN;
VAR index: SIGNED32;
BEGIN
	FOR index := 0 TO builtins - 1 DO
		IF cNames[index] = c THEN
			COPY(aoNames[index], ao);
			IF (ao = "SignedLong") OR (ao = "UnsignedLong") THEN longUsed := TRUE END;
			IF ao = "WideChar" THEN wideUsed := TRUE END;
			RETURN TRUE
		END
	END;
	RETURN FALSE
END Builtin;

(*	The parameter list of a function spelling. Commas inside a nested list belong to that list and
	do not split here. *)
PROCEDURE NextParameter(CONST list: ARRAY OF CHAR; VAR position: SIZE; VAR piece: ARRAY OF CHAR): BOOLEAN;
VAR level, index: SIZE;
BEGIN
	IF position >= Strings.Length(list) THEN RETURN FALSE END;
	level := 0; index := 0;
	WHILE (position < Strings.Length(list)) & ((list[position] # ',') OR (level > 0)) DO
		IF list[position] = '(' THEN INC(level)
		ELSIF list[position] = ')' THEN DEC(level)
		END;
		IF index + 1 < LEN(piece) THEN piece[index] := list[position]; INC(index) END;
		INC(position)
	END;
	piece[index] := 0X;
	IF (position < Strings.Length(list)) & (list[position] = ',') THEN INC(position) END;
	Trim(piece);
	RETURN TRUE
END NextParameter;

(*	A function pointer as C spells it -- `int ( * )(void *, int)` with no blanks -- and every other
	spelling that has a parameter list in it.
	The result is a whole `PROCEDURE {PlatformCC}` type, which is what such a thing is here.

	Parameter names are made up (`a`, `b`, ...): a type spelling carries none. Where the caller has
	real ones -- a FunctionDecl and its ParmVarDecls -- it prints them itself and does not come
	here. *)
PROCEDURE MapProcedure(CONST c: ARRAY OF CHAR; VAR ao: ARRAY OF CHAR; VAR reason: ARRAY OF CHAR): BOOLEAN;
VAR work, returns, parameters, one, mapped: Spelling; letter: ARRAY 4 OF CHAR;
	open, close, first, position: SIZE; index, level: SIGNED32; ok: BOOLEAN;
BEGIN
	COPY(c, work); Trim(work);
	(* the parameter list is the last parenthesised group, and it must end the spelling *)
	close := Strings.Length(work);
	IF (close = 0) OR (work[close - 1] # ')') THEN reason := "a type this cannot read"; RETURN FALSE END;
	open := close - 1; level := 0; ok := FALSE;
	WHILE (open > 0) & ~ok DO
		DEC(open);
		IF work[open] = ')' THEN INC(level)
		ELSIF work[open] = '(' THEN
			IF level = 0 THEN ok := TRUE ELSE DEC(level) END
		END
	END;
	IF ~ok THEN reason := "a type this cannot read"; RETURN FALSE END;

	first := Strings.Pos("(", work);
	Strings.Copy(work, 0, first, returns); Trim(returns);
	Strings.Copy(work, open + 1, close - open - 2, parameters); Trim(parameters);

	(*	Between the return type and the parameter list there stands the pointer star in its own
		parentheses, and nothing else may stand there. A function that returns a function pointer
		spells two of them into each other, and it is refused rather than half read. *)
	IF first < open THEN
		Strings.Copy(work, first, open - first, one); Trim(one);
		IF one # "(*)" THEN reason := "a function type this cannot read"; RETURN FALSE END
	END;

	ao := "PROCEDURE {PlatformCC} (";
	position := 0; index := 0;
	WHILE NextParameter(parameters, position, one) DO
		IF (one = "void") & (index = 0) & (position >= Strings.Length(parameters)) THEN
			(* `(void)` is C for no parameters at all *)
		ELSIF one = "..." THEN
			reason := "varargs"; RETURN FALSE
		ELSE
			IF ~MapType(one, Parameter, mapped, reason) THEN RETURN FALSE END;
			IF index > 0 THEN Strings.AppendX(ao, "; ") END;
			letter[0] := CHR(ORD('a') + index MOD 26); letter[1] := 0X;
			IF index >= 26 THEN letter[1] := '1'; letter[2] := 0X END;
			AppendParameter(ao, letter, mapped);
			INC(index)
		END
	END;
	Strings.AppendX(ao, ")");
	IF returns # "void" THEN
		IF ~MapType(returns, Result, mapped, reason) THEN RETURN FALSE END;
		Strings.AppendX(ao, ": "); Strings.AppendX(ao, mapped)
	END;
	RETURN TRUE
END MapProcedure;

(*	`T[16]` and `T[2][3]` where they stand in a record: C puts the elements in place and so does
	this. The leftmost bracket is the outer dimension in C, and the outer one here too, so the
	groups are read left to right and printed in that order.

	A flexible array member -- `T[]`, the last field of a struct with no size of its own -- is
	refused: it has no size, and a record that claims one would be a record of the wrong length. *)
PROCEDURE MapArray(CONST c: ARRAY OF CHAR; VAR ao: ARRAY OF CHAR; VAR reason: ARRAY OF CHAR): BOOLEAN;
VAR work, element, count, mapped: Spelling; open, close, position, length: SIZE; number: SIGNED64;
BEGIN
	COPY(c, work); Trim(work);
	length := Strings.Length(work);
	open := Strings.Pos("[", work);
	IF (open = -1) OR (work[length - 1] # ']') THEN
		reason := "an array type this cannot read"; RETURN FALSE
	END;
	Strings.Copy(work, 0, open, element); Trim(element);
	IF ~MapType(element, Field, mapped, reason) THEN RETURN FALSE END;

	ao := "";
	position := open;
	WHILE position < length DO
		IF work[position] # '[' THEN reason := "an array type this cannot read"; RETURN FALSE END;
		close := Strings.Find(work, position, ']');
		IF close = -1 THEN reason := "an array type this cannot read"; RETURN FALSE END;
		Strings.Copy(work, position + 1, close - position - 1, count); Trim(count);
		IF count = "" THEN
			reason := "an array with no size of its own (a flexible array member)"; RETURN FALSE
		END;
		IF ~Strings.TryParseInt64(count, number) OR (number <= 0) THEN
			reason := "an array whose size is not a plain number: "; Strings.AppendX(reason, count);
			RETURN FALSE
		END;
		Strings.AppendX(ao, "ARRAY "); Strings.AppendX(ao, count); Strings.AppendX(ao, " OF ");
		position := close + 1
	END;
	Strings.AppendX(ao, mapped);
	RETURN TRUE
END MapArray;

(*	One C type spelling as clang wrote it, in Active Oberon. FALSE, with a reason, for the ones
	that have no honest answer -- and a reason is what the generated module then prints instead of
	the declaration.

	The rules, in the order they are tried:
	-  a parameter list in it makes it a procedure type;
	-  an array decays to what C decays it to, an address;
	-  a pointer is an ADDRESS, except `const char *` in a parameter, which is an open array of
	   characters, so that a literal can be passed;
	-  `const`, `volatile`, `struct`, `union` and `enum` are dropped: they say nothing about the
	   machine;
	-  the builtin table answers, or a type this module has already declared answers for itself,
	   or a typedef from the translation unit is resolved and the question asked again.
*)
PROCEDURE MapType(CONST c: ARRAY OF CHAR; place: SIGNED32; VAR ao: ARRAY OF CHAR;
	VAR reason: ARRAY OF CHAR): BOOLEAN;
VAR work: Spelling; entry: Entry; length: SIZE; stars: SIGNED32; ok: BOOLEAN;
BEGIN
	IF depth > Depth THEN reason := "a typedef that leads back to itself"; RETURN FALSE END;
	IF ~Fits(c, MaxType) THEN reason := "a type spelling too long to read"; RETURN FALSE END;
	COPY(c, work); Trim(work);
	IF work = "" THEN reason := "no type at all"; RETURN FALSE END;

	IF Strings.Pos("(", work) # -1 THEN
		INC(depth); ok := MapProcedure(work, ao, reason); DEC(depth); RETURN ok
	END;

	length := Strings.Length(work);
	IF work[length - 1] = ']' THEN
		(*	`T[8]`: as a parameter C hands over the first element's address, and a field of that
			type is that many elements in place. Both are said here in the language's own words. *)
		IF place # Field THEN ao := "ADDRESS"; RETURN TRUE END;
		INC(depth); ok := MapArray(work, ao, reason); DEC(depth); RETURN ok
	END;

	IF work[length - 1] = '*' THEN
		stars := 0;
		WHILE (length > 0) & ((work[length - 1] = '*') OR IsBlank(work[length - 1])) DO
			IF work[length - 1] = '*' THEN INC(stars) END;
			DEC(length)
		END;
		work[length] := 0X; Trim(work);
		IF (stars = 1) & (place = Parameter) & ((work = "const char") OR (work = "char const")) THEN
			ao := "CONST ARRAY OF CHAR"; RETURN TRUE
		END;
		ao := "ADDRESS"; RETURN TRUE
	END;

	ok := TRUE;
	WHILE ok DO
		ok := Cut(work, "const") OR Cut(work, "volatile") OR Cut(work, "restrict")
			OR Cut(work, "_Atomic") OR Cut(work, "struct") OR Cut(work, "union") OR Cut(work, "enum")
	END;

	IF Builtin(work, ao) THEN RETURN TRUE END;

	entry := Find(emitted, work);
	IF (entry # NIL) & (entry.kind = Emitted) THEN COPY(entry.text, ao); RETURN TRUE END;

	entry := Find(aliases, work);
	IF (entry # NIL) & (entry.text # work) THEN
		INC(depth); ok := MapType(entry.text, place, ao, reason); DEC(depth); RETURN ok
	END;

	reason := "no Active Oberon type for "; Strings.AppendX(reason, work);
	RETURN FALSE
END MapType;

(* --- macros ------------------------------------------------------------------------------ *)

(*
	The AST has no macros: they are gone before the parser sees anything, and `SQLITE_OK` is a
	macro. So they are read a second way, from `clang -E -dM`, which prints the definitions that
	survived to the end of the translation unit -- comments already removed, continuation lines
	already joined.

	Which of them belong to this header is a separate question, and the answer is the header's own
	text: `-dM` says nothing about where a macro came from. Only names the header itself defines
	are taken; the rest of the machine's headers stay out of the module.

	What can be translated is an integer. The value is worked out here rather than left to the
	compiler, because a C flag is `(0x1|0x2)` and Active Oberon does not have `|` for integers.
	Everything else -- a cast, a call, a type name, a string beyond a plain literal -- is listed by
	name and translated by nobody.
*)

CONST
	MaxTokens = 256;
	(* tokens *)
	TokenNumber = 0; TokenOperator = 1;

TYPE
	Expression = RECORD
		kind: ARRAY MaxTokens OF SIGNED32;
		value: ARRAY MaxTokens OF SIGNED64;
		operator: ARRAY MaxTokens OF ARRAY 4 OF CHAR;
		count, at: SIGNED32
	END;

PROCEDURE Push(VAR e: Expression; kind: SIGNED32; value: SIGNED64; CONST operator: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF e.count >= MaxTokens THEN RETURN FALSE END;
	e.kind[e.count] := kind; e.value[e.count] := value;
	COPY(operator, e.operator[e.count]); INC(e.count);
	RETURN TRUE
END Push;

(*	The body of a macro as tokens, with every name already replaced by the value of the constant it
	names. A name that is not a constant we have makes the whole body untranslatable, which is the
	honest answer: we would otherwise be guessing. *)
PROCEDURE Tokenise(CONST body: ARRAY OF CHAR; VAR e: Expression): BOOLEAN;
VAR name: Name; number: SIGNED64; position, start, length: SIZE; entry: Entry; digit: SIGNED32;
	character: CHAR; text: ARRAY 4 OF CHAR;
BEGIN
	e.count := 0; e.at := 0;
	position := 0; length := Strings.Length(body);
	WHILE position < length DO
		character := body[position];
		IF IsBlank(character) THEN INC(position)
		ELSIF IsDigit(character) THEN
			number := 0;
			IF (character = '0') & (position + 1 < length)
				& ((body[position + 1] = 'x') OR (body[position + 1] = 'X')) THEN
				INC(position, 2);
				IF (position >= length) OR ~IsHexDigit(body[position]) THEN RETURN FALSE END;
				WHILE (position < length) & IsHexDigit(body[position]) DO
					character := body[position];
					IF IsDigit(character) THEN digit := ORD(character) - ORD('0')
					ELSIF (character >= 'a') & (character <= 'f') THEN digit := ORD(character) - ORD('a') + 10
					ELSE digit := ORD(character) - ORD('A') + 10
					END;
					number := number * 16 + digit; INC(position)
				END
			ELSE
				WHILE (position < length) & IsDigit(body[position]) DO
					number := number * 10 + (ORD(body[position]) - ORD('0')); INC(position)
				END
			END;
			(* the suffixes C writes on a literal say nothing this needs *)
			WHILE (position < length) & ((body[position] = 'u') OR (body[position] = 'U')
				OR (body[position] = 'l') OR (body[position] = 'L')) DO INC(position) END;
			IF ~Push(e, TokenNumber, number, "") THEN RETURN FALSE END
		ELSIF character = "'" THEN
			(* a character literal, the plain kind: an escape is somebody else's problem *)
			INC(position);
			IF (position + 1 >= length) OR (body[position] = '\') OR (body[position + 1] # "'") THEN
				RETURN FALSE
			END;
			IF ~Push(e, TokenNumber, ORD(body[position]), "") THEN RETURN FALSE END;
			INC(position, 2)
		ELSIF IsLetter(character) OR (character = '_') THEN
			start := position;
			WHILE (position < length) & (IsLetter(body[position]) OR IsDigit(body[position])
				OR (body[position] = '_')) DO INC(position) END;
			IF position - start >= MaxName THEN RETURN FALSE END;
			Strings.Copy(body, start, position - start, name);
			entry := Find(macros, name);
			IF (entry = NIL) OR (entry.kind # Number) THEN RETURN FALSE END;
			IF ~Push(e, TokenNumber, entry.number, "") THEN RETURN FALSE END
		ELSE
			text[0] := character; text[1] := 0X;
			IF ((character = '<') OR (character = '>')) & (position + 1 < length)
				& (body[position + 1] = character) THEN
				text[1] := character; text[2] := 0X; INC(position)
			ELSIF (character = '+') OR (character = '-') OR (character = '*') OR (character = '/')
				OR (character = '%') OR (character = '|') OR (character = '&') OR (character = '^')
				OR (character = '~') OR (character = '(') OR (character = ')') THEN
				(* one of ours *)
			ELSE
				RETURN FALSE
			END;
			IF ~Push(e, TokenOperator, 0, text) THEN RETURN FALSE END;
			INC(position)
		END
	END;
	RETURN e.count > 0
END Tokenise;

PROCEDURE Ahead(VAR e: Expression; CONST operator: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN (e.at < e.count) & (e.kind[e.at] = TokenOperator) & (e.operator[e.at] = operator)
END Ahead;

PROCEDURE Take(VAR e: Expression; CONST operator: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF Ahead(e, operator) THEN INC(e.at); RETURN TRUE END;
	RETURN FALSE
END Take;

PROCEDURE Unary(VAR e: Expression; VAR value: SIGNED64): BOOLEAN;
BEGIN
	IF Take(e, "-") THEN
		IF ~Unary(e, value) THEN RETURN FALSE END;
		value := -value; RETURN TRUE
	ELSIF Take(e, "+") THEN RETURN Unary(e, value)
	ELSIF Take(e, "~") THEN
		IF ~Unary(e, value) THEN RETURN FALSE END;
		value := -value - 1; RETURN TRUE
	ELSIF Take(e, "(") THEN
		IF ~Or(e, value) THEN RETURN FALSE END;
		RETURN Take(e, ")")
	ELSIF (e.at < e.count) & (e.kind[e.at] = TokenNumber) THEN
		value := e.value[e.at]; INC(e.at); RETURN TRUE
	END;
	RETURN FALSE
END Unary;

PROCEDURE Product(VAR e: Expression; VAR value: SIGNED64): BOOLEAN;
VAR right: SIGNED64;
BEGIN
	IF ~Unary(e, value) THEN RETURN FALSE END;
	LOOP
		IF Take(e, "*") THEN
			IF ~Unary(e, right) THEN RETURN FALSE END; value := value * right
		ELSIF Take(e, "/") THEN
			IF ~Unary(e, right) OR (right = 0) THEN RETURN FALSE END; value := value DIV right
		ELSIF Take(e, "%") THEN
			IF ~Unary(e, right) OR (right = 0) THEN RETURN FALSE END; value := value MOD right
		ELSE EXIT
		END
	END;
	RETURN TRUE
END Product;

PROCEDURE Sum(VAR e: Expression; VAR value: SIGNED64): BOOLEAN;
VAR right: SIGNED64;
BEGIN
	IF ~Product(e, value) THEN RETURN FALSE END;
	LOOP
		IF Take(e, "+") THEN
			IF ~Product(e, right) THEN RETURN FALSE END; INC(value, right)
		ELSIF Take(e, "-") THEN
			IF ~Product(e, right) THEN RETURN FALSE END; DEC(value, right)
		ELSE EXIT
		END
	END;
	RETURN TRUE
END Sum;

PROCEDURE Shift(VAR e: Expression; VAR value: SIGNED64): BOOLEAN;
VAR right: SIGNED64;
BEGIN
	IF ~Sum(e, value) THEN RETURN FALSE END;
	LOOP
		IF Take(e, "<<") THEN
			IF ~Sum(e, right) OR (right < 0) OR (right > 62) THEN RETURN FALSE END;
			value := LSH(value, right)
		ELSIF Take(e, ">>") THEN
			IF ~Sum(e, right) OR (right < 0) OR (right > 62) THEN RETURN FALSE END;
			value := ASH(value, -right)
		ELSE EXIT
		END
	END;
	RETURN TRUE
END Shift;

(*	Bit for bit, on values that Active Oberon has no bitwise operator for. A SET would be the
	language's answer and a SET is 32 bits wide, so the arithmetic is done by hand, one bit at a
	time, and it is done on the generator's side once rather than in the generated module for
	ever. *)
PROCEDURE Bits(left, right: SIGNED64; what: CHAR): SIGNED64;
VAR result, bit: SIGNED64; index: SIGNED32; one, other, keep: BOOLEAN;
BEGIN
	result := 0; bit := 1;
	FOR index := 0 TO 62 DO
		one := (left DIV bit) MOD 2 # 0; other := (right DIV bit) MOD 2 # 0;
		IF what = '&' THEN keep := one & other
		ELSIF what = '|' THEN keep := one OR other
		ELSE keep := one # other
		END;
		IF keep THEN INC(result, bit) END;
		IF index < 62 THEN bit := bit * 2 END
	END;
	RETURN result
END Bits;

PROCEDURE And(VAR e: Expression; VAR value: SIGNED64): BOOLEAN;
VAR right: SIGNED64;
BEGIN
	IF ~Shift(e, value) THEN RETURN FALSE END;
	WHILE Take(e, "&") DO
		IF ~Shift(e, right) THEN RETURN FALSE END;
		value := Bits(value, right, '&')
	END;
	RETURN TRUE
END And;

PROCEDURE Xor(VAR e: Expression; VAR value: SIGNED64): BOOLEAN;
VAR right: SIGNED64;
BEGIN
	IF ~And(e, value) THEN RETURN FALSE END;
	WHILE Take(e, "^") DO
		IF ~And(e, right) THEN RETURN FALSE END;
		value := Bits(value, right, '^')
	END;
	RETURN TRUE
END Xor;

PROCEDURE Or(VAR e: Expression; VAR value: SIGNED64): BOOLEAN;
VAR right: SIGNED64;
BEGIN
	IF ~Xor(e, value) THEN RETURN FALSE END;
	WHILE Take(e, "|") DO
		IF ~Xor(e, right) THEN RETURN FALSE END;
		value := Bits(value, right, '|')
	END;
	RETURN TRUE
END Or;

(* The whole body, and nothing left over. *)
PROCEDURE Evaluate(CONST body: ARRAY OF CHAR; VAR value: SIGNED64): BOOLEAN;
VAR e: Expression;
BEGIN
	IF ~Tokenise(body, e) THEN RETURN FALSE END;
	IF ~Or(e, value) THEN RETURN FALSE END;
	RETURN e.at = e.count
END Evaluate;

(* A body that is one plain string literal, which a CONST can be as well as a number. *)
PROCEDURE IsLiteral(CONST body: ARRAY OF CHAR): BOOLEAN;
VAR length, index: SIZE;
BEGIN
	length := Strings.Length(body);
	IF (length < 2) OR (body[0] # '"') OR (body[length - 1] # '"') THEN RETURN FALSE END;
	FOR index := 1 TO length - 2 DO
		IF (body[index] = '"') OR (body[index] = '\') THEN RETURN FALSE END
	END;
	RETURN TRUE
END IsLiteral;

(* --- files -------------------------------------------------------------------------------- *)

PROCEDURE ReadWhole(CONST file: ARRAY OF CHAR; VAR text: Strings.String): BOOLEAN;
VAR handle: Files.File; reader: Files.Reader; length: SIZE; read: SIZE;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN FALSE END;
	length := handle.Length();
	NEW(text, length + 1);
	NEW(reader, handle, 0);
	reader.Bytes(text^, 0, length, read);
	text[read] := 0X;
	RETURN TRUE
END ReadWhole;

(* --- the pieces of the module, while it is being written --------------------------------- *)

VAR
	taken: Entry;					(* every name the module will export, before anything is printed *)
	constBuffer, typeBuffer, varBuffer, loadBuffer, procBuffer: Streams.Buffer;
	constWriter, typeWriter, varWriter, loadWriter, procWriter: Streams.Writer;
	nameLibrary, nameAvailable, nameMissing, nameLoad, nameOpen, nameText, nameResolve: Name;

(* A parameter, printed -- through the one place that knows where `CONST` goes. *)
PROCEDURE WriteParameter(writer: Streams.Writer; CONST name, mapped: ARRAY OF CHAR);
VAR text: Spelling;
BEGIN
	text := ""; AppendParameter(text, name, mapped); writer.String(text)
END WriteParameter;

(* A name of ours that no name of the library's has taken. *)
PROCEDURE Free(VAR name: ARRAY OF CHAR);
BEGIN
	WHILE Find(taken, name) # NIL DO Strings.AppendX(name, "_") END
END Free;

(* --- the abstract syntax tree ------------------------------------------------------------- *)

PROCEDURE Member(node: JSON.Object; CONST key: ARRAY OF CHAR; VAR text: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF node = NIL THEN RETURN FALSE END;
	RETURN JSON.GetText(node, key, text)
END Member;

(*	A member clang writes as a JSON true. It leaves the whole member out when it is false, so the
	absence and the FALSE are the same answer. *)
PROCEDURE Flag(node: JSON.Object; CONST key: ARRAY OF CHAR): BOOLEAN;
VAR value: JSON.Value;
BEGIN
	IF node = NIL THEN RETURN FALSE END;
	value := node.Get(key);
	IF value = NIL THEN RETURN FALSE END;
	IF value IS JSON.Bool THEN RETURN value(JSON.Bool).value END;
	RETURN TRUE
END Flag;

PROCEDURE Sub(node: JSON.Object; CONST key: ARRAY OF CHAR): JSON.Object;
BEGIN
	IF node = NIL THEN RETURN NIL END;
	RETURN JSON.GetObject(node, key)
END Sub;

PROCEDURE Inner(node: JSON.Object): JSON.Array;
BEGIN
	IF node = NIL THEN RETURN NIL END;
	RETURN JSON.GetArray(node, "inner")
END Inner;

(*	The C spelling of a declaration's type. `qualType` is what the header wrote; `desugaredQualType`
	is there as well when the two differ, and it is the one that reaches a builtin. *)
PROCEDURE Spelled(node: JSON.Object; VAR qual, desugared: ARRAY OF CHAR): BOOLEAN;
VAR type: JSON.Object;
BEGIN
	qual := ""; desugared := "";
	type := Sub(node, "type");
	IF type = NIL THEN RETURN FALSE END;
	IF ~Member(type, "qualType", qual) THEN RETURN FALSE END;
	IF ~Member(type, "desugaredQualType", desugared) THEN desugared := "" END;
	RETURN TRUE
END Spelled;

(*	Which file a declaration came from. clang leaves `file` out when it has not changed since the
	last one, so the answer is carried forward -- and that carrying is the whole reason a header
	can be told apart from the eighty it includes. *)
PROCEDURE FileOf(node: JSON.Object; VAR file: ARRAY OF CHAR);
VAR location: JSON.Object; named: Path;
BEGIN
	location := Sub(node, "loc");
	IF location = NIL THEN RETURN END;
	IF Member(location, "file", named) THEN COPY(named, file) END
END FileOf;

(*	Same file, whatever the two spellings do with separators and however one of them was reached.
	clang answers with the path it was given, and a header named on the command line as
	`./sqlite3.h` is the same file as the `sqlite3.h` in the dump. *)
PROCEDURE SameFile(CONST one, other: ARRAY OF CHAR): BOOLEAN;
VAR a, b: Path; index: SIZE;
BEGIN
	COPY(one, a); COPY(other, b);
	FOR index := 0 TO Strings.Length(a) - 1 DO
		IF a[index] = '\' THEN a[index] := '/' END
	END;
	FOR index := 0 TO Strings.Length(b) - 1 DO
		IF b[index] = '\' THEN b[index] := '/' END
	END;
	IF a = b THEN RETURN TRUE END;
	(* one of them may be the tail of the other *)
	IF Strings.Length(a) > Strings.Length(b) THEN
		RETURN (Strings.Length(b) > 0) & (Strings.Pos(b, a) = Strings.Length(a) - Strings.Length(b))
			& (a[Strings.Length(a) - Strings.Length(b) - 1] = '/')
	ELSIF Strings.Length(b) > Strings.Length(a) THEN
		RETURN (Strings.Length(a) > 0) & (Strings.Pos(a, b) = Strings.Length(b) - Strings.Length(a))
			& (b[Strings.Length(b) - Strings.Length(a) - 1] = '/')
	END;
	RETURN FALSE
END SameFile;

(*	How many bits a bit field was declared with. clang puts the width in the declaration's own
	subtree, as a constant expression it has already folded. A width of zero is C's way of forcing
	the next field to a fresh storage word, and it is refused rather than guessed at. *)
PROCEDURE BitWidth(node: JSON.Object; VAR bits: SIGNED32): BOOLEAN;
VAR items: JSON.Array; item: JSON.Item; child: JSON.Object; text: Spelling; value: SIGNED64;
BEGIN
	items := Inner(node);
	IF items = NIL THEN RETURN FALSE END;
	item := items.items;
	WHILE item # NIL DO
		child := JSON.AsObject(item.value);
		IF (child # NIL) & Member(child, "value", text) & Strings.TryParseInt64(text, value)
			& (value > 0) & (value <= 62) THEN
			bits := SIGNED32(value); RETURN TRUE
		END;
		item := item.next
	END;
	RETURN FALSE
END BitWidth;

(* --- the declarations, one kind at a time ------------------------------------------------- *)

(*	`typedef long long sqlite3_int64;` and its like. A typedef of an incomplete struct --
	`typedef struct sqlite3 sqlite3;` -- is not a type this can declare and not a failure either:
	such a name only ever appears behind a pointer, and a pointer is an ADDRESS. It is passed over
	in silence, which is why `quiet` exists. *)
PROCEDURE EmitTypedef(node: JSON.Object; CONST prefixes: ARRAY OF CHAR);
VAR name, exported: Name; qual, desugared, mapped, reason, bare: Spelling; quiet, ignore: BOOLEAN;
BEGIN
	IF ~Member(node, "name", name) THEN RETURN END;
	IF ~Spelled(node, qual, desugared) THEN RETURN END;
	IF ~Fits(name, MaxName) OR ~Exported(name, prefixes, exported) THEN
		Complain(name, "a name Active Oberon cannot spell"); RETURN
	END;
	IF Find(emitted, name) # NIL THEN RETURN END;

	IF ~MapType(qual, Field, mapped, reason) & (desugared # "") THEN
		IF ~MapType(desugared, Field, mapped, reason) THEN mapped := "" END
	END;
	IF mapped = "" THEN
		(*	An incomplete struct or union -- `typedef struct sqlite3 sqlite3;`. Such a name is only
			ever used behind a pointer and a pointer is an ADDRESS, so there is nothing to declare
			and nothing was lost. *)
		COPY(qual, bare); Trim(bare);
		ignore := Cut(bare, "const") OR Cut(bare, "volatile");
		quiet := Cut(bare, "struct") OR Cut(bare, "union") OR Cut(bare, "enum");
		IF quiet & (Strings.Pos(" ", bare) = -1) & (Strings.Pos("*", bare) = -1) THEN RETURN END;
		Complain(name, reason); RETURN
	END;
	typeWriter.String("	"); typeWriter.String(exported); typeWriter.String("* = ");
	typeWriter.String(mapped); typeWriter.String(";");
	IF exported # name THEN typeWriter.String("	(* "); typeWriter.String(name); typeWriter.String(" *)") END;
	typeWriter.Ln;
	Remember(emitted, name, exported, 0, Emitted);
	INC(typeCount)
END EmitTypedef;

(*	A union member, as the pair of procedures that read and write the room the union is. The
	address is the union's own: every member of a C union starts where the union starts. *)
PROCEDURE WriteUnionMember(CONST record, accessor: ARRAY OF CHAR; slot: Slot);
BEGIN
	IF IsScalar(slot.ao) THEN
		procWriter.String("(** `"); WriteSafe(procWriter, slot.c); procWriter.String(" ");
		procWriter.String(slot.name); procWriter.String("` of the union *)"); procWriter.Ln;
		procWriter.String("PROCEDURE "); procWriter.String(accessor);
		procWriter.String("*(CONST u: "); procWriter.String(record);
		procWriter.String("): "); procWriter.String(slot.ao); procWriter.String(";"); procWriter.Ln;
		procWriter.String("VAR value: "); procWriter.String(slot.ao); procWriter.String(";"); procWriter.Ln;
		procWriter.String("BEGIN"); procWriter.Ln;
		procWriter.String("	SYSTEM.GET(ADDRESSOF(u.storage[0]), value); RETURN value"); procWriter.Ln;
		procWriter.String("END "); procWriter.String(accessor); procWriter.String(";"); procWriter.Ln;
		procWriter.Ln;
		procWriter.String("PROCEDURE "); procWriter.String(accessor);
		procWriter.String("_set*(VAR u: "); procWriter.String(record);
		procWriter.String("; value: "); procWriter.String(slot.ao); procWriter.String(");"); procWriter.Ln;
		procWriter.String("BEGIN"); procWriter.Ln;
		procWriter.String("	SYSTEM.PUT(ADDRESSOF(u.storage[0]), value)"); procWriter.Ln;
		procWriter.String("END "); procWriter.String(accessor); procWriter.String("_set;"); procWriter.Ln;
		procWriter.Ln
	ELSE
		(*	An array, a record or a procedure variable does not move in one instruction, so what is
			handed over is where it is. *)
		procWriter.String("(** where `"); WriteSafe(procWriter, slot.c); procWriter.String(" ");
		procWriter.String(slot.name); procWriter.String("` of the union is -- a `");
		WriteSafe(procWriter, slot.ao); procWriter.String("` in place *)"); procWriter.Ln;
		procWriter.String("PROCEDURE "); procWriter.String(accessor);
		procWriter.String("*(VAR u: "); procWriter.String(record);
		procWriter.String("): ADDRESS;"); procWriter.Ln;
		procWriter.String("BEGIN"); procWriter.Ln;
		procWriter.String("	RETURN ADDRESSOF(u.storage[0])"); procWriter.Ln;
		procWriter.String("END "); procWriter.String(accessor); procWriter.String(";"); procWriter.Ln;
		procWriter.Ln
	END
END WriteUnionMember;

(*	A bit field, as the pair of procedures that take it out of its storage word and put it back.
	The arithmetic is DIV and MOD rather than a shift and a mask because this language has no
	bitwise operators for integers -- and MOD here is Oberon's, which is never negative, so the
	same expression masks a negative value into its two's complement bits. *)
PROCEDURE WriteBitField(CONST record, accessor: ARRAY OF CHAR; slot: Slot; CONST unit: ARRAY OF CHAR);
VAR outer: Name; whole, half, shift: SIGNED64;
	sizeWin, sizeUnix, alignWin, alignUnix: SIZE;
BEGIN
	shift := Power(slot.shift); whole := Power(slot.bits); half := Power(slot.bits - 1);
	(*	The word is read as unsigned, whatever the field was declared: the arithmetic below wants a
		top bit that means a bit. A field declared signed gets its sign put back by hand, and its
		procedures speak the signed type of the same width. *)
	COPY(unit, outer);
	IF slot.signed & Extent(unit, sizeWin, sizeUnix, alignWin, alignUnix) THEN
		IF ~Signed(sizeWin, outer) THEN COPY(unit, outer) END
	END;

	procWriter.String("(** bit field `"); WriteSafe(procWriter, slot.c); procWriter.String(" ");
	procWriter.String(slot.name); procWriter.String(" : "); procWriter.Int(slot.bits, 0);
	procWriter.String("`, bit "); procWriter.Int(slot.shift, 0);
	procWriter.String(" of "); procWriter.String(slot.storage); procWriter.String(" *)"); procWriter.Ln;
	procWriter.String("PROCEDURE "); procWriter.String(accessor);
	procWriter.String("*(CONST r: "); procWriter.String(record);
	procWriter.String("): "); procWriter.String(outer); procWriter.String(";"); procWriter.Ln;
	IF slot.signed THEN
		procWriter.String("VAR value: "); procWriter.String(outer); procWriter.String(";"); procWriter.Ln;
		procWriter.String("BEGIN"); procWriter.Ln;
		procWriter.String("	value := "); procWriter.String(outer); procWriter.String("((r.");
		procWriter.String(slot.storage);
		IF slot.shift > 0 THEN procWriter.String(" DIV "); procWriter.Int(shift, 0) END;
		procWriter.String(") MOD "); procWriter.Int(whole, 0); procWriter.String(");"); procWriter.Ln;
		procWriter.String("	IF value >= "); procWriter.Int(half, 0);
		procWriter.String(" THEN DEC(value, "); procWriter.Int(whole, 0); procWriter.String(") END;"); procWriter.Ln;
		procWriter.String("	RETURN value"); procWriter.Ln
	ELSE
		procWriter.String("BEGIN"); procWriter.Ln;
		procWriter.String("	RETURN (r."); procWriter.String(slot.storage);
		IF slot.shift > 0 THEN procWriter.String(" DIV "); procWriter.Int(shift, 0) END;
		procWriter.String(") MOD "); procWriter.Int(whole, 0); procWriter.Ln
	END;
	procWriter.String("END "); procWriter.String(accessor); procWriter.String(";"); procWriter.Ln;
	procWriter.Ln;

	procWriter.String("PROCEDURE "); procWriter.String(accessor);
	procWriter.String("_set*(VAR r: "); procWriter.String(record);
	procWriter.String("; value: "); procWriter.String(outer); procWriter.String(");"); procWriter.Ln;
	procWriter.String("BEGIN"); procWriter.Ln;
	procWriter.String("	r."); procWriter.String(slot.storage); procWriter.String(" := ");
	procWriter.String(unit); procWriter.String("(r."); procWriter.String(slot.storage);
	procWriter.String(" - ((r."); procWriter.String(slot.storage);
	IF slot.shift > 0 THEN procWriter.String(" DIV "); procWriter.Int(shift, 0) END;
	procWriter.String(") MOD "); procWriter.Int(whole, 0); procWriter.String(")");
	IF slot.shift > 0 THEN procWriter.String(" * "); procWriter.Int(shift, 0) END;
	procWriter.Ln;
	procWriter.String("		+ (value MOD "); procWriter.Int(whole, 0); procWriter.String(")");
	IF slot.shift > 0 THEN procWriter.String(" * "); procWriter.Int(shift, 0) END;
	procWriter.String(")"); procWriter.Ln;
	procWriter.String("END "); procWriter.String(accessor); procWriter.String("_set;"); procWriter.Ln;
	procWriter.Ln
END WriteBitField;

(*
	`struct z_stream_s { ... }` as a RECORD, `union either { ... }` as the room a union occupies,
	and a run of bit fields as one storage word with a pair of procedures each.

	The layout has to be the C one, and it is: this compiler lays a record out in order with
	natural alignment, which is what both platform ABIs say. Measured, not assumed -- `z_stream` is
	88 bytes with `zalloc` at 48 and `adler` at 76, the same three numbers C's `sizeof` and
	`offsetof` give on the same machine.

	A union has no Active Oberon spelling, so it becomes the room it takes: an array of the type its
	alignment asks for, which gives it the right size and the right alignment in one, and members
	that are procedures over that room. That is what a hand-written binding does with a union, and
	it is what makes a struct that CONTAINS one usable at all -- which is the whole point, because
	a struct with a union in it used to be refused entire.

	Bit fields are packed here rather than declared, because the language cannot declare them.
	Only a run whose fields all have one C type and none of which crosses a storage word is
	translated: those are the two cases where the Windows and the Unix rule agree. Windows starts a
	fresh word when the type changes and Unix does not; Unix lets a field straddle a word and
	Windows does not. A layout that differs between the two cannot be one generated file, so it is
	refused with that sentence rather than written down twice.

	A record that cannot be laid out honestly is refused whole, not half.
*)
PROCEDURE EmitRecord(node: JSON.Object; CONST prefixes: ARRAY OF CHAR);
VAR name, exported, field, kind, unitType, valueType, accessor: Name;
	c, desugared, mapped, reason, members: Spelling;
	fields: JSON.Array; item: JSON.Item; child: JSON.Object;
	list, last, slot, run, one: Slot;
	body: Streams.Buffer; writer: Streams.Writer; text: Strings.String;
	count, units, used, wide: SIGNED32;
	sizeWin, sizeUnix, alignWin, alignUnix: SIZE;
	partWin, partUnix, partAlignWin, partAlignUnix: SIZE;
	union, measurable: BOOLEAN;
BEGIN
	IF ~Member(node, "name", name) THEN RETURN END;
	IF ~Flag(node, "completeDefinition") THEN RETURN END;
	union := Member(node, "tagUsed", kind) & (kind = "union");
	IF ~Fits(name, MaxName) OR ~Exported(name, prefixes, exported) THEN
		Complain(name, "a name Active Oberon cannot spell"); RETURN
	END;
	IF Find(emitted, name) # NIL THEN RETURN END;

	(* --- what the members are, and what their types come out as --------------------------- *)
	fields := Inner(node);
	IF fields = NIL THEN Complain(name, "a record with no members"); RETURN END;
	list := NIL; last := NIL; count := 0;
	item := fields.items;
	WHILE item # NIL DO
		child := JSON.AsObject(item.value);
		IF (child # NIL) & Member(child, "kind", kind) & (kind = "FieldDecl") THEN
			IF count >= MaxFields THEN
				Complain(name, "more members than this generator lays out"); RETURN
			END;
			IF ~Spelled(child, c, desugared) THEN Complain(name, "a member with no type"); RETURN END;
			NEW(slot); slot.next := NIL; slot.bits := 0; slot.unit := 0; slot.shift := 0;
			slot.signed := FALSE; slot.storage := ""; slot.name := "";
			COPY(c, slot.c);
			IF Member(child, "name", field) THEN
				IF ~Fits(field, MaxName) OR ~Spellable(field) THEN
					Complain(name, "a member name Active Oberon cannot spell"); RETURN
				END;
				COPY(field, slot.name)
			END;
			IF ~MapType(c, Field, mapped, reason) THEN
				IF (desugared = "") OR ~MapType(desugared, Field, mapped, reason) THEN
					Complain(name, reason); RETURN
				END
			END;
			COPY(mapped, slot.ao);
			IF Flag(child, "isBitfield") THEN
				IF ~BitWidth(child, slot.bits) THEN
					Complain(name, "a bit field whose width this could not read (a zero width forces a word boundary)");
					RETURN
				END;
				IF (slot.ao = "SIGNED8") OR (slot.ao = "SIGNED16") OR (slot.ao = "SIGNED32")
					OR (slot.ao = "SIGNED64") THEN
					slot.signed := TRUE
				ELSIF (slot.ao = "UNSIGNED8") OR (slot.ao = "UNSIGNED16") OR (slot.ao = "UNSIGNED32")
					OR (slot.ao = "UNSIGNED64") OR (slot.ao = "BOOLEAN") THEN
					slot.signed := FALSE
				ELSE
					reason := "a bit field of "; Strings.AppendX(reason, c);
					Strings.AppendX(reason, ", which is not one width on both platforms");
					Complain(name, reason); RETURN
				END
			ELSIF slot.name = "" THEN
				Complain(name, "a member with no name"); RETURN
			END;
			IF last = NIL THEN list := slot ELSE last.next := slot END;
			last := slot; INC(count)
		END;
		item := item.next
	END;
	IF count = 0 THEN Complain(name, "a record with no members"); RETURN END;

	NEW(body, 1024); writer := body.GetWriter();
	sizeWin := 0; sizeUnix := 0; alignWin := 1; alignUnix := 1; measurable := TRUE;

	IF union THEN
		(* --- a union is the room its widest member needs, aligned as its strictest ---------- *)
		members := "";
		slot := list;
		WHILE slot # NIL DO
			IF slot.bits # 0 THEN Complain(name, "a bit field inside a union"); RETURN END;
			IF ~Extent(slot.ao, partWin, partUnix, partAlignWin, partAlignUnix) THEN
				reason := "a union member this cannot measure: "; Strings.AppendX(reason, slot.c);
				Complain(name, reason); RETURN
			END;
			sizeWin := Bigger(sizeWin, partWin); sizeUnix := Bigger(sizeUnix, partUnix);
			alignWin := Bigger(alignWin, partAlignWin);
			alignUnix := Bigger(alignUnix, partAlignUnix);
			IF members # "" THEN Strings.AppendX(members, "; ") END;
			Strings.AppendX(members, slot.c); Strings.AppendX(members, " ");
			Strings.AppendX(members, slot.name);
			slot := slot.next
		END;
		sizeWin := RoundUp(sizeWin, alignWin); sizeUnix := RoundUp(sizeUnix, alignUnix);
		IF ~Alignment(alignWin, unitType) OR ~Alignment(alignUnix, valueType) THEN
			Complain(name, "a union whose alignment this cannot express"); RETURN
		END;
		IF (sizeWin = sizeUnix) & (alignWin = alignUnix) THEN
			writer.String("		storage*: ARRAY "); writer.Int(sizeWin DIV alignWin, 0);
			writer.String(" OF "); writer.String(unitType); writer.String(";"); writer.Ln
		ELSE
			(* a member of C `long`: the room differs, and the difference is a compile-time one *)
			writer.String("#IF WIN THEN"); writer.Ln;
			writer.String("		storage*: ARRAY "); writer.Int(sizeWin DIV alignWin, 0);
			writer.String(" OF "); writer.String(unitType); writer.String(";"); writer.Ln;
			writer.String("#ELSE"); writer.Ln;
			writer.String("		storage*: ARRAY "); writer.Int(sizeUnix DIV alignUnix, 0);
			writer.String(" OF "); writer.String(valueType); writer.String(";"); writer.Ln;
			writer.String("#END"); writer.Ln
		END
	ELSE
		(* --- a struct: its members in order, bit fields packed into words ------------------- *)
		units := 0;
		slot := list;
		WHILE slot # NIL DO
			IF slot.bits = 0 THEN
				writer.String("		"); writer.String(slot.name); writer.String("*: ");
				writer.String(slot.ao); writer.String(";"); writer.Ln;
				IF measurable & Extent(slot.ao, partWin, partUnix, partAlignWin, partAlignUnix) THEN
					sizeWin := RoundUp(sizeWin, partAlignWin) + partWin;
					sizeUnix := RoundUp(sizeUnix, partAlignUnix) + partUnix;
					alignWin := Bigger(alignWin, partAlignWin);
					alignUnix := Bigger(alignUnix, partAlignUnix)
				ELSE
					measurable := FALSE
				END;
				slot := slot.next
			ELSE
				run := slot;
				IF ~Extent(run.ao, partWin, partUnix, partAlignWin, partAlignUnix) THEN
					Complain(name, "a bit field this cannot measure"); RETURN
				END;
				IF partWin # partUnix THEN
					Complain(name, "a bit field of a type that is not one width on both platforms");
					RETURN
				END;
				IF ~Storage(partWin, unitType) THEN
					Complain(name, "a bit field this cannot place"); RETURN
				END;
				wide := SIGNED32(8 * partWin);
				used := 0;
				WHILE (slot # NIL) & (slot.bits > 0) & (slot.c = run.c) DO
					IF used + slot.bits > wide THEN
						IF used # wide THEN
							Complain(name, "a bit field that crosses a storage word, which Windows and Unix place differently");
							RETURN
						END;
						INC(units); used := 0
					END;
					slot.unit := units; slot.shift := used;
					COPY(unitType, slot.unitType);
					slot.storage := "bits"; Strings.AppendInt(slot.storage, units);
					INC(used, slot.bits);
					slot := slot.next
				END;
				(*	A bit field of another type right after this run is where the two ABIs part:
					Windows starts a fresh word at the type change, Unix carries on packing. There
					is no one layout to write down, so the record is refused. *)
				IF (slot # NIL) & (slot.bits > 0) THEN
					Complain(name, "bit fields of two different types in a row, which Windows and Unix pack differently");
					RETURN
				END;

				(*	One word per unit, declared where its first field stands. A name of ours must
					not take a name of the record's, so it steps aside if it has. *)
				one := run;
				WHILE one # slot DO
					IF one.shift = 0 THEN
						last := list;
						WHILE last # NIL DO
							IF (last.bits = 0) & (last.name = one.storage) THEN
								Strings.AppendX(one.storage, "_"); last := list
							ELSE
								last := last.next
							END
						END;
						writer.String("		"); writer.String(one.storage); writer.String("*: ");
						writer.String(unitType); writer.String(";	(* bit fields:");
						last := one;
						WHILE last # slot DO
							IF last.unit = one.unit THEN
								writer.String(" ");
								IF last.name = "" THEN writer.String("(padding)")
								ELSE writer.String(last.name)
								END;
								writer.String(":"); writer.Int(last.bits, 0)
							END;
							last := last.next
						END;
						writer.String(" *)"); writer.Ln;
						IF measurable THEN
							sizeWin := RoundUp(sizeWin, partAlignWin) + partWin;
							sizeUnix := RoundUp(sizeUnix, partAlignUnix) + partUnix;
							alignWin := Bigger(alignWin, partAlignWin);
							alignUnix := Bigger(alignUnix, partAlignUnix)
						END
					END;
					one := one.next
				END;
				INC(units)
			END
		END
	END;

	writer.Update; text := body.GetString();
	typeWriter.String("	"); typeWriter.String(exported); typeWriter.String("* = RECORD");
	IF union THEN
		typeWriter.String("	(* a C union: "); WriteSafe(typeWriter, members); typeWriter.String(" *)")
	ELSIF exported # name THEN
		typeWriter.String("	(* "); typeWriter.String(name); typeWriter.String(" *)")
	END;
	typeWriter.Ln;
	typeWriter.String(text^);
	typeWriter.String("	END;"); typeWriter.Ln;
	Remember(emitted, name, exported, 0, Emitted);
	IF measurable THEN
		sizeWin := RoundUp(sizeWin, alignWin); sizeUnix := RoundUp(sizeUnix, alignUnix);
		RememberExtent(name, sizeWin, sizeUnix, alignWin, alignUnix)
	END;
	INC(typeCount);

	(* --- and the procedures its members are reached through ------------------------------- *)
	slot := list;
	WHILE slot # NIL DO
		IF slot.name # "" THEN
			COPY(exported, accessor); Strings.AppendX(accessor, "_");
			Strings.AppendX(accessor, slot.name);
			WHILE Find(taken, accessor) # NIL DO Strings.AppendX(accessor, "_") END;
			IF union THEN WriteUnionMember(exported, accessor, slot)
			ELSIF slot.bits > 0 THEN WriteBitField(exported, accessor, slot, slot.unitType)
			END
		END;
		slot := slot.next
	END
END EmitRecord;

(*	An enumeration, as constants. The type itself is an `int` and says nothing more; the names are
	the point, and they are remembered as numbers so that a macro written over them can be worked
	out too. *)
PROCEDURE EmitEnum(node: JSON.Object; CONST prefixes: ARRAY OF CHAR);
VAR name, exported: Name; items, values: JSON.Array; item, valueItem: JSON.Item;
	child, value: JSON.Object; kind: Name; text: Spelling; number, next: SIGNED64; read: BOOLEAN;
BEGIN
	items := Inner(node);
	IF items = NIL THEN RETURN END;
	next := 0; item := items.items;
	WHILE item # NIL DO
		child := JSON.AsObject(item.value);
		IF (child # NIL) & Member(child, "kind", kind) & (kind = "EnumConstantDecl")
			& Member(child, "name", name) THEN
			number := next;
			values := Inner(child);
			IF values # NIL THEN
				valueItem := values.items;
				WHILE valueItem # NIL DO
					value := JSON.AsObject(valueItem.value);
					IF (value # NIL) & Member(value, "value", text) THEN
						read := Strings.TryParseInt64(text, number)
					END;
					valueItem := valueItem.next
				END
			END;
			IF Fits(name, MaxName) & Exported(name, prefixes, exported) THEN
				constWriter.String("	"); constWriter.String(exported); constWriter.String("* = ");
				constWriter.Int(number, 0); constWriter.String(";");
				IF exported # name THEN
					constWriter.String("	(* "); constWriter.String(name); constWriter.String(" *)")
				END;
				constWriter.Ln;
				Remember(macros, name, "", number, Number);
				INC(constants)
			ELSE
				Complain(name, "a name Active Oberon cannot spell")
			END;
			next := number + 1
		END;
		item := item.next
	END;
	(* the enumeration's own name, when it has one, is an int as far as a call is concerned *)
	IF Member(node, "name", name) & Fits(name, MaxName) & Exported(name, prefixes, exported)
		& (Find(emitted, name) = NIL) THEN
		typeWriter.String("	"); typeWriter.String(exported); typeWriter.String("* = SIGNED32;"); typeWriter.Ln;
		Remember(emitted, name, exported, 0, Emitted);
		INC(typeCount)
	END
END EmitEnum;

(*	A function: one procedure variable, and one line in the loader that fills it. The parameter
	names are the header's own where the header gave them, because they are what the library's
	documentation calls them. *)
PROCEDURE EmitFunction(node: JSON.Object; CONST prefixes: ARRAY OF CHAR; varargs: SIGNED32);
VAR name, exported, parameter, wrapper: Name; qual, desugared, mapped, reason, returns: Spelling;
	parameters: JSON.Array; item: JSON.Item; child: JSON.Object; kind: Name;
	body: Streams.Buffer; writer: Streams.Writer; text: Strings.String;
	first: SIZE; count, extra, index: SIGNED32; ok, variadic: BOOLEAN;
BEGIN
	IF ~Member(node, "name", name) THEN RETURN END;
	IF ~Spelled(node, qual, desugared) THEN RETURN END;
	IF Flag(node, "isImplicit") THEN RETURN END;
	IF ~Fits(name, MaxName) OR ~Exported(name, prefixes, exported) THEN
		Complain(name, "a name Active Oberon cannot spell"); RETURN
	END;
	IF Find(emitted, name) # NIL THEN RETURN END;

	(*	A variadic function is not refused any more, it is wrapped: see below. What it cannot be is
		declared, because Active Oberon has no `...` and no `va_list`. *)
	variadic := Strings.Pos("...", qual) # -1;
	IF variadic & (varargs <= 0) THEN Complain(name, "varargs, and no wrappers were asked for"); RETURN END;

	first := Strings.Pos("(", qual);
	IF first = -1 THEN Complain(name, "a type this cannot read"); RETURN END;
	Strings.Copy(qual, 0, first, returns); Trim(returns);

	NEW(body, 256); writer := body.GetWriter();
	count := 0; ok := TRUE;
	parameters := Inner(node);
	IF parameters # NIL THEN
		item := parameters.items;
		WHILE (item # NIL) & ok DO
			child := JSON.AsObject(item.value);
			IF (child # NIL) & Member(child, "kind", kind) & (kind = "ParmVarDecl") THEN
				IF ~Spelled(child, qual, desugared) THEN
					Complain(name, "a parameter with no type"); ok := FALSE
				ELSE
					IF ~MapType(qual, Parameter, mapped, reason) THEN
						IF (desugared = "") OR ~MapType(desugared, Parameter, mapped, reason) THEN
							Complain(name, reason); ok := FALSE
						END
					END;
					IF ok THEN
						IF ~Member(child, "name", parameter) OR ~Fits(parameter, MaxName)
							OR ~Spellable(parameter) THEN
							parameter := "p"; Strings.AppendInt(parameter, count)
						END;
						IF count > 0 THEN writer.String("; ") END;
						WriteParameter(writer, parameter, mapped);
						INC(count)
					END
				END
			END;
			item := item.next
		END
	END;
	IF ~ok THEN RETURN END;
	writer.Update; text := body.GetString();

	(*	The result before a character is printed. It used to be mapped after the declaration had
		been written, so a function whose result has no answer -- `long double` -- left half a
		declaration in the module and the module did not compile. A refusal has to happen before
		the printing, not during it. *)
	mapped := "";
	IF returns # "void" THEN
		IF ~MapType(returns, Result, mapped, reason) THEN Complain(name, reason); RETURN END
	END;

	IF variadic THEN
		(*	One entry per arity, each a procedure variable of its own resolved from the same C
			symbol. That is the whole trick: C allows a call to pass more arguments than the format
			asks for, so a fixed prototype of the right shape is a legal call to a variadic
			function -- measured on both hosts, not assumed. The extra parameters are ADDRESS, and
			that is deliberate: it is what stops a FLOAT64 from being passed where the ABI would
			carry it in a register the callee does not look in. *)
		reason := "";
		FOR extra := 1 TO varargs DO
			COPY(exported, wrapper); Strings.AppendInt(wrapper, extra);
			WHILE Find(taken, wrapper) # NIL DO Strings.AppendX(wrapper, "_") END;
			varWriter.String("	"); varWriter.String(wrapper);
			varWriter.String("-: PROCEDURE {PlatformCC} (");
			varWriter.String(text^);
			IF count > 0 THEN varWriter.String("; ") END;
			FOR index := 1 TO extra DO
				IF index > 1 THEN varWriter.String(", ") END;
				varWriter.String("a"); varWriter.Int(index, 0)
			END;
			varWriter.String(": ADDRESS)");
			IF mapped # "" THEN varWriter.String(": "); varWriter.String(mapped) END;
			varWriter.String(";	(* "); varWriter.String(name);
			varWriter.String(" with "); varWriter.Int(extra, 0);
			IF extra = 1 THEN varWriter.String(" variable argument *)")
			ELSE varWriter.String(" variable arguments *)")
			END;
			varWriter.Ln;
			loadWriter.String("	"); loadWriter.String(nameResolve); loadWriter.String("(handle, ");
			loadWriter.Char('"'); loadWriter.String(name); loadWriter.Char('"');
			loadWriter.String(", ADDRESSOF("); loadWriter.String(wrapper); loadWriter.String("));");
			loadWriter.Ln;
			IF reason # "" THEN Strings.AppendX(reason, ", ") END;
			Strings.AppendX(reason, wrapper)
		END;
		Wrap(name, reason);
		Remember(emitted, name, exported, 0, Emitted);
		INC(functions, varargs);
		RETURN
	END;

	varWriter.String("	"); varWriter.String(exported); varWriter.String("-: PROCEDURE {PlatformCC} (");
	varWriter.String(text^); varWriter.String(")");
	IF mapped # "" THEN varWriter.String(": "); varWriter.String(mapped) END;
	varWriter.String(";");
	IF exported # name THEN varWriter.String("	(* "); varWriter.String(name); varWriter.String(" *)") END;
	varWriter.Ln;

	loadWriter.String("	"); loadWriter.String(nameResolve); loadWriter.String("(handle, ");
	loadWriter.Char('"'); loadWriter.String(name); loadWriter.Char('"');
	loadWriter.String(", ADDRESSOF("); loadWriter.String(exported); loadWriter.String("));"); loadWriter.Ln;
	Remember(emitted, name, exported, 0, Emitted);
	INC(functions)
END EmitFunction;

(*	`extern const char sqlite3_version[];` -- a symbol that is data. What the loader can hand over
	is where it is, so that is what is declared: an ADDRESS, with the C type in a comment beside
	it. *)
PROCEDURE EmitVariable(node: JSON.Object; CONST prefixes: ARRAY OF CHAR);
VAR name, exported: Name; qual, desugared: Spelling; storage: Name;
BEGIN
	IF ~Member(node, "name", name) THEN RETURN END;
	IF ~Member(node, "storageClass", storage) OR (storage # "extern") THEN RETURN END;
	IF ~Spelled(node, qual, desugared) THEN RETURN END;
	IF ~Fits(name, MaxName) OR ~Exported(name, prefixes, exported) THEN
		Complain(name, "a name Active Oberon cannot spell"); RETURN
	END;
	IF Find(emitted, name) # NIL THEN RETURN END;
	varWriter.String("	"); varWriter.String(exported); varWriter.String("-: ADDRESS;	(* ");
	varWriter.String(qual);
	IF exported # name THEN varWriter.String(" "); varWriter.String(name) END;
	varWriter.String(" *)"); varWriter.Ln;
	loadWriter.String("	"); loadWriter.String(nameResolve); loadWriter.String("(handle, ");
	loadWriter.Char('"'); loadWriter.String(name); loadWriter.Char('"');
	loadWriter.String(", ADDRESSOF("); loadWriter.String(exported); loadWriter.String("));"); loadWriter.Ln;
	Remember(emitted, name, exported, 0, Emitted);
	INC(dataCount)
END EmitVariable;

(* --- the macros of one header, in the order the header defines them ---------------------- *)

VAR defines: Entry;			(* what `-E -dM` said: name -> body, as Alias entries *)

(*	`#define` after `#define` in a text, in order. `functionLike` is the distinction C makes with
	nothing but the absence of a space: `#define F(x)` takes arguments, `#define F (x)` does not,
	and only the second is a constant. *)
PROCEDURE NextDefine(CONST text: ARRAY OF CHAR; VAR position: SIZE; VAR name: ARRAY OF CHAR;
	VAR functionLike: BOOLEAN): BOOLEAN;
VAR length, start: SIZE; word: ARRAY 8 OF CHAR; index: SIZE; found: BOOLEAN;
BEGIN
	word := "define";
	length := Strings.Length(text);
	WHILE position < length DO
		WHILE (position < length) & (text[position] # 0AX) & IsBlank(text[position]) DO INC(position) END;
		found := FALSE;
		IF (position < length) & (text[position] = '#') THEN
			INC(position);
			WHILE (position < length) & (text[position] # 0AX) & IsBlank(text[position]) DO INC(position) END;
			IF position + 6 <= length THEN
				found := TRUE;
				index := 0;
				WHILE found & (index < 6) DO
					IF text[position + index] # word[index] THEN found := FALSE END;
					INC(index)
				END
			END
		END;
		IF found THEN
			INC(position, 6);
			IF (position < length) & ~IsBlank(text[position]) THEN found := FALSE END
		END;
		IF found THEN
			WHILE (position < length) & (text[position] # 0AX) & IsBlank(text[position]) DO INC(position) END;
			start := position;
			WHILE (position < length) & (IsLetter(text[position]) OR IsDigit(text[position])
				OR (text[position] = '_')) DO INC(position) END;
			IF (position > start) & (position - start < MaxName) THEN
				Strings.Copy(text, start, position - start, name);
				functionLike := (position < length) & (text[position] = '(');
				(* on past the rest of the line, continuations and all *)
				WHILE (position < length) & (text[position] # 0AX) DO
					IF (text[position] = '\') & (position + 1 < length) THEN INC(position) END;
					INC(position)
				END;
				INC(position);
				RETURN TRUE
			END
		END;
		WHILE (position < length) & (text[position] # 0AX) DO INC(position) END;
		INC(position)
	END;
	RETURN FALSE
END NextDefine;

(*	What the preprocessor says every macro is, at the end of the translation unit: one
	`#define NAME body` a line, comments already gone and continuations already joined. Where a
	name is defined twice the last one is what the compiler would have used, and it is what is
	kept here. *)
PROCEDURE ReadDefines(CONST text: ARRAY OF CHAR);
VAR position, length, from, cut: SIZE; name: Name; line, body: Spelling; functionLike: BOOLEAN;
BEGIN
	defines := NIL;
	position := 0; length := Strings.Length(text);
	WHILE position < length DO
		from := position;
		WHILE (position < length) & (text[position] # 0AX) DO INC(position) END;
		IF position - from < MaxType THEN
			Strings.Copy(text, from, position - from, line); Trim(line);
			IF Starts(line, "#define") THEN
				Strings.Delete(line, 0, 7); Trim(line);
				cut := 0;
				WHILE (cut < Strings.Length(line)) & (IsLetter(line[cut]) OR IsDigit(line[cut])
					OR (line[cut] = '_')) DO INC(cut) END;
				IF (cut > 0) & (cut < MaxName) THEN
					Strings.Copy(line, 0, cut, name);
					functionLike := (cut < Strings.Length(line)) & (line[cut] = '(');
					COPY(line, body); Strings.Delete(body, 0, cut); Trim(body);
					IF functionLike THEN Remember(defines, name, "", 1, Alias)
					ELSE Remember(defines, name, body, 0, Alias)
					END
				END
			END
		END;
		INC(position)
	END
END ReadDefines;

(*	The header's own macros as constants. Two things decide what comes out: the header text says
	which names are the header's (`-dM` does not say where a macro came from), and the
	preprocessor says what they stand for on this machine.

	Three rounds, because a flag is written over another flag and the other one has to be known
	first; three is not a proof, it is enough for every header measured and it terminates. *)
PROCEDURE EmitMacros(CONST header, prefixes: ARRAY OF CHAR);
VAR name, exported: Name; position: SIZE; functionLike: BOOLEAN; entry: Entry;
	value: SIGNED64; round: SIGNED32; written: Entry;
BEGIN
	FOR round := 1 TO 3 DO
		position := 0;
		WHILE NextDefine(header, position, name, functionLike) DO
			IF ~functionLike & (Find(macros, name) = NIL) THEN
				entry := Find(defines, name);
				IF (entry # NIL) & (entry.number = 0) & (entry.text # "") THEN
					IF Evaluate(entry.text, value) THEN
						Remember(macros, name, "", value, Number)
					ELSIF IsLiteral(entry.text) THEN
						Remember(macros, name, entry.text, 0, Text)
					END
				END
			END
		END
	END;
	(* and now once through the header, in its own order, printing what came out *)
	written := NIL;
	position := 0;
	WHILE NextDefine(header, position, name, functionLike) DO
		IF Find(written, name) = NIL THEN
			Remember(written, name, "", 0, Alias);
			entry := Find(macros, name);
			IF functionLike THEN
				INC(listed)
			ELSIF entry = NIL THEN
				IF Find(defines, name) = NIL THEN
					(* this platform's preprocessor never defined it: it is not a loss *)
				ELSE
					INC(listed)
				END
			ELSIF ~Fits(name, MaxName) OR ~Exported(name, prefixes, exported) THEN
				Complain(name, "a name Active Oberon cannot spell")
			ELSIF Find(emitted, name) # NIL THEN
				(* a declaration of the same name won; a macro is the weaker claim *)
			ELSE
				constWriter.String("	"); constWriter.String(exported); constWriter.String("* = ");
				IF entry.kind = Text THEN constWriter.String(entry.text)
				ELSE constWriter.Int(entry.number, 0)
				END;
				constWriter.String(";");
				IF exported # name THEN
					constWriter.String("	(* "); constWriter.String(name); constWriter.String(" *)")
				END;
				constWriter.Ln;
				INC(constants); INC(macroCount)
			END
		END
	END
END EmitMacros;

(* --- the module, written out -------------------------------------------------------------- *)

(* A module name out of a header's file name: `sqlite3.h` is `Sqlite3`. *)
PROCEDURE ModuleName*(CONST header: ARRAY OF CHAR; VAR module: ARRAY OF CHAR);
VAR base: Path; index, start, length: SIZE; out: SIZE;
BEGIN
	COPY(header, base);
	length := Strings.Length(base);
	start := 0;
	FOR index := 0 TO length - 1 DO
		IF (base[index] = '/') OR (base[index] = '\') THEN start := index + 1 END
	END;
	out := 0; module := "";
	index := start;
	WHILE (index < length) & (base[index] # '.') DO
		IF IsLetter(base[index]) OR IsDigit(base[index]) THEN
			IF (out = 0) & ~IsLetter(base[index]) THEN module[out] := 'C'; INC(out) END;
			module[out] := base[index];
			IF out = 0 THEN module[out] := Strings.UP(base[index]) END;
			INC(out)
		END;
		INC(index)
	END;
	module[out] := 0X;
	IF module = "" THEN module := "Binding" END
END ModuleName;

(* The libraries the generated module will try, in order, when the caller named none. *)
PROCEDURE LibraryGuess(CONST header: ARRAY OF CHAR; VAR libraries: ARRAY OF CHAR);
VAR base: Path; index, start, length, out: SIZE;
BEGIN
	COPY(header, base); length := Strings.Length(base); start := 0;
	FOR index := 0 TO length - 1 DO
		IF (base[index] = '/') OR (base[index] = '\') THEN start := index + 1 END
	END;
	out := 0;
	index := start;
	WHILE (index < length) & (base[index] # '.') DO
		IF IsLetter(base[index]) OR IsDigit(base[index]) THEN base[out] := base[index]; INC(out) END;
		INC(index)
	END;
	base[out] := 0X;
	libraries := "";
	Strings.AppendX(libraries, base); Strings.AppendX(libraries, ".dll,lib");
	Strings.AppendX(libraries, base); Strings.AppendX(libraries, "-0.dll,");
	Strings.AppendX(libraries, base); Strings.AppendX(libraries, "1.dll,lib");
	Strings.AppendX(libraries, base); Strings.AppendX(libraries, ".so.0,lib");
	Strings.AppendX(libraries, base); Strings.AppendX(libraries, ".so,lib");
	Strings.AppendX(libraries, base); Strings.AppendX(libraries, ".dylib")
END LibraryGuess;

(* Text that has to sit inside an Active Oberon comment, and cannot be allowed to end it. *)
PROCEDURE WriteSafe(writer: Streams.Writer; CONST text: ARRAY OF CHAR);
VAR index, length: SIZE;
BEGIN
	length := Strings.Length(text);
	FOR index := 0 TO length - 1 DO
		IF (text[index] = '*') & (index + 1 < length) & (text[index + 1] = ')') THEN
			writer.String("* ")
		ELSIF (text[index] = '(') & (index + 1 < length) & (text[index + 1] = '*') THEN
			writer.String("( ")
		ELSIF (text[index] = 0DX) OR (text[index] = 0AX) THEN writer.Char(' ')
		ELSE writer.Char(text[index])
		END
	END
END WriteSafe;

PROCEDURE Assemble(writer: Streams.Writer; CONST settings: Settings; CONST module: ARRAY OF CHAR);
VAR now: Dates.DateTime; note: Note; text: Strings.String; library: Name; position: SIZE;
	first: BOOLEAN;
BEGIN
	now := Dates.Now();
	writer.String("MODULE "); writer.String(module);
	writer.String(";	(** GENERATED by "); writer.String(Tool);
	writer.String(" -- do not edit *)"); writer.Ln;
	writer.Ln;
	writer.String("(*"); writer.Ln;
	writer.String("	Bindings to "); WriteSafe(writer, settings.header); writer.String(", written by ");
	writer.String(Tool); writer.String(" on ");
	writer.Int(now.year, 0); writer.Char('-');
	IF now.month < 10 THEN writer.Char('0') END; writer.Int(now.month, 0); writer.Char('-');
	IF now.day < 10 THEN writer.Char('0') END; writer.Int(now.day, 0);
	writer.Char('.'); writer.Ln;
	writer.String("	The header was read by clang; the bodies are still C and are called where they are."); writer.Ln;
	writer.Ln;
	writer.String("	"); writer.Int(functions, 0); writer.String(" functions, ");
	writer.Int(typeCount, 0); writer.String(" types, ");
	writer.Int(constants, 0); writer.String(" constants (");
	writer.Int(macroCount, 0); writer.String(" of them macros), ");
	writer.Int(dataCount, 0); writer.String(" data symbols."); writer.Ln;
	writer.Ln;
	writer.String("	How to read it:"); writer.Ln;
	writer.String("	-  every entry is a procedure variable of the platform's C calling convention,"); writer.Ln;
	writer.String("	   resolved from the shared library when this module is loaded. `"); writer.String(nameAvailable);
	writer.String("` says"); writer.Ln;
	writer.String("	   the library was found and opened, `"); writer.String(nameLibrary);
	writer.String("` names the file that answered, and"); writer.Ln;
	writer.String("	   `"); writer.String(nameMissing);
	writer.String("` counts the entries that library does not have -- which is not an error:"); writer.Ln;
	writer.String("	   a header declares what the library can be built with, and a build can leave a"); writer.Ln;
	writer.String("	   feature out. Check the entry you mean to call against NIL, or check `");
	writer.String(nameMissing); writer.String("` = 0."); writer.Ln;
	writer.String("	-  a C pointer is an ADDRESS. An out-parameter is passed as ADDRESSOF(x)."); writer.Ln;
	writer.String("	-  `const char *` in a parameter is CONST ARRAY OF CHAR, so a literal can be passed"); writer.Ln;
	writer.String("	   straight in. A C NULL cannot go there: for that, declare the entry again by hand"); writer.Ln;
	writer.String("	   with ADDRESS."); writer.Ln;
	writer.String("	-  `"); writer.String(nameText);
	writer.String("` copies a C string out of the address a function returned."); writer.Ln;
	IF longUsed THEN
		writer.String("	-  C `long` is 32 bits on Windows and 64 on Unix, so it is SignedLong below, and"); writer.Ln;
		writer.String("	   that type is the one thing in this file that is decided at compile time."); writer.Ln
	END;
	IF wrapped # NIL THEN
		writer.Ln;
		writer.String("	Variadic functions are here as fixed-arity wrappers: `<name>1` takes one variable"); writer.Ln;
		writer.String("	argument, `<name>2` two, and so on, each resolved from the same C symbol. A C call may"); writer.Ln;
		writer.String("	pass more arguments than the format asks for, so a wrapper wider than the call needs is"); writer.Ln;
		writer.String("	still a correct call. The extra parameters are ADDRESS on purpose: an integer or a"); writer.Ln;
		writer.String("	pointer goes straight in, and a FLOAT64 cannot -- the C ABI carries a floating-point"); writer.Ln;
		writer.String("	variable argument in a register this call does not announce, so the type system refuses"); writer.Ln;
		writer.String("	what the ABI would get wrong. For those, write the entry again by hand."); writer.Ln;
		note := wrapped;
		WHILE note # NIL DO
			writer.String("	   "); WriteSafe(writer, note.name);
			writer.String(" -- "); WriteSafe(writer, note.reason); writer.Ln;
			note := note.next
		END
	END;
	IF listed > 0 THEN
		writer.Ln;
		writer.String("	"); writer.Int(listed, 0);
		writer.String(" more of the header's macros are not here: they take arguments, or stand for"); writer.Ln;
		writer.String("	something that is not a constant. A macro is text, and text is not translated."); writer.Ln
	END;
	IF notes # NIL THEN
		writer.Ln;
		writer.String("	Not translated -- "); writer.Int(skipped, 0);
		writer.String(" declarations, with the reason for each. Nothing here was left out"); writer.Ln;
		writer.String("	quietly:"); writer.Ln;
		note := notes;
		WHILE note # NIL DO
			writer.String("	   "); WriteSafe(writer, note.name);
			writer.String(" -- "); WriteSafe(writer, note.reason); writer.Ln;
			note := note.next
		END
	END;
	writer.String("*)"); writer.Ln;
	writer.Ln;
	writer.String("IMPORT SYSTEM, HostLibs;"); writer.Ln;
	writer.Ln;

	constWriter.Update; text := constBuffer.GetString();
	IF (text # NIL) & (text[0] # 0X) THEN
		writer.String("CONST"); writer.Ln; writer.String(text^); writer.Ln
	END;

	writer.String("TYPE"); writer.Ln;
	IF longUsed THEN
		writer.String("	(* C `long`: 32 bits where Windows is LLP64, 64 where Unix is LP64 *)"); writer.Ln;
		writer.String("#IF WIN THEN"); writer.Ln;
		writer.String("	SignedLong* = SIGNED32; UnsignedLong* = UNSIGNED32;"); writer.Ln;
		writer.String("#ELSE"); writer.Ln;
		writer.String("	SignedLong* = SIGNED64; UnsignedLong* = UNSIGNED64;"); writer.Ln;
		writer.String("#END"); writer.Ln
	END;
	IF wideUsed THEN
		writer.String("#IF WIN THEN"); writer.Ln;
		writer.String("	WideChar* = UNSIGNED16;"); writer.Ln;
		writer.String("#ELSE"); writer.Ln;
		writer.String("	WideChar* = SIGNED32;"); writer.Ln;
		writer.String("#END"); writer.Ln
	END;
	typeWriter.Update; text := typeBuffer.GetString();
	IF (text # NIL) & (text[0] # 0X) THEN writer.String(text^) END;
	IF ~longUsed & ~wideUsed & ((text = NIL) OR (text[0] = 0X)) THEN
		writer.String("	Unused* = SIGNED32;	(* this header declared no type of its own *)"); writer.Ln
	END;
	writer.Ln;

	writer.String("VAR"); writer.Ln;
	varWriter.Update; text := varBuffer.GetString();
	IF (text # NIL) & (text[0] # 0X) THEN writer.String(text^) END;
	writer.Ln;
	writer.String("	"); writer.String(nameLibrary);
	writer.String("-: ARRAY 256 OF CHAR;	(** the library file that answered, or "); writer.Char('"');
	writer.Char('"'); writer.String(" *)"); writer.Ln;
	writer.String("	"); writer.String(nameAvailable);
	writer.String("-: BOOLEAN;	(** the library was found and opened *)"); writer.Ln;
	writer.String("	"); writer.String(nameMissing);
	writer.String("-: SIGNED32;	(** entries this build of the library does not have *)"); writer.Ln;
	writer.Ln;

	(*	What a union member and a bit field are reached through: the language cannot declare either,
		so each gets a pair of procedures instead of a field. *)
	procWriter.Update; text := procBuffer.GetString();
	IF (text # NIL) & (text[0] # 0X) THEN writer.String(text^); writer.Ln END;

	writer.String("(** A C string, from where it is to an Active Oberon array. Stops at the array's end. *)"); writer.Ln;
	writer.String("PROCEDURE "); writer.String(nameText);
	writer.String("*(address: ADDRESS; VAR text: ARRAY OF CHAR);"); writer.Ln;
	writer.String("VAR index: SIZE; character: CHAR;"); writer.Ln;
	writer.String("BEGIN"); writer.Ln;
	writer.String("	text := "); writer.Char('"'); writer.Char('"'); writer.String(";"); writer.Ln;
	writer.String("	IF address = 0 THEN RETURN END;"); writer.Ln;
	writer.String("	index := 0;"); writer.Ln;
	writer.String("	LOOP"); writer.Ln;
	writer.String("		SYSTEM.GET(address + index, character);"); writer.Ln;
	writer.String("		IF (character = 0X) OR (index + 1 >= LEN(text)) THEN EXIT END;"); writer.Ln;
	writer.String("		text[index] := character; INC(index)"); writer.Ln;
	writer.String("	END;"); writer.Ln;
	writer.String("	text[index] := 0X"); writer.Ln;
	writer.String("END "); writer.String(nameText); writer.String(";"); writer.Ln;
	writer.Ln;

	writer.String("PROCEDURE "); writer.String(nameResolve);
	writer.String("(handle: HostLibs.LibHandle; CONST name: ARRAY OF CHAR; address: ADDRESS);"); writer.Ln;
	writer.String("BEGIN"); writer.Ln;
	writer.String("	IF ~HostLibs.GetProcedureOptional(handle, name, address) THEN INC(");
	writer.String(nameMissing); writer.String(") END"); writer.Ln;
	writer.String("END "); writer.String(nameResolve); writer.String(";"); writer.Ln;
	writer.Ln;

	writer.String("(** One named library, and every entry out of it. *)"); writer.Ln;
	writer.String("PROCEDURE "); writer.String(nameLoad);
	writer.String("*(CONST file: ARRAY OF CHAR): BOOLEAN;"); writer.Ln;
	writer.String("VAR handle: HostLibs.LibHandle;"); writer.Ln;
	writer.String("BEGIN"); writer.Ln;
	writer.String("	IF ~HostLibs.LoadLibraryOptional(file, handle) THEN RETURN FALSE END;"); writer.Ln;
	writer.String("	"); writer.String(nameMissing); writer.String(" := 0;"); writer.Ln;
	loadWriter.Update; text := loadBuffer.GetString();
	IF (text # NIL) & (text[0] # 0X) THEN writer.String(text^) END;
	writer.String("	COPY(file, "); writer.String(nameLibrary); writer.String(");"); writer.Ln;
	writer.String("	"); writer.String(nameAvailable); writer.String(" := TRUE;"); writer.Ln;
	writer.String("	RETURN TRUE"); writer.Ln;
	writer.String("END "); writer.String(nameLoad); writer.String(";"); writer.Ln;
	writer.Ln;

	writer.String("(** The library under any of the names this platform or another gives it. *)"); writer.Ln;
	writer.String("PROCEDURE "); writer.String(nameOpen); writer.String("*(): BOOLEAN;"); writer.Ln;
	writer.String("BEGIN"); writer.Ln;
	writer.String("	RETURN ");
	position := 0; first := TRUE;
	WHILE NextPiece(settings.libraries, position, library) DO
		IF library # "" THEN
			IF ~first THEN writer.Ln; writer.String("		OR ") END;
			writer.String(nameLoad); writer.String("("); writer.Char('"');
			writer.String(library); writer.Char('"'); writer.String(")");
			first := FALSE
		END
	END;
	IF first THEN writer.String("FALSE") END;
	writer.Ln;
	writer.String("END "); writer.String(nameOpen); writer.String(";"); writer.Ln;
	writer.Ln;
	writer.String("BEGIN"); writer.Ln;
	writer.String("	IF ~"); writer.String(nameOpen); writer.String("() THEN ");
	writer.String(nameLibrary); writer.String(" := "); writer.Char('"'); writer.Char('"');
	writer.String(" END"); writer.Ln;
	writer.String("END "); writer.String(module); writer.String("."); writer.Ln
END Assemble;

(* --- the whole of it --------------------------------------------------------------------- *)

PROCEDURE Reset;
BEGIN
	aliases := NIL; emitted := NIL; macros := NIL; taken := NIL; defines := NIL;
	notes := NIL; lastNote := NIL; wrapped := NIL; lastWrapped := NIL;
	functions := 0; typeCount := 0; constants := 0; dataCount := 0; skipped := 0;
	macroCount := 0; listed := 0;
	longUsed := FALSE; wideUsed := FALSE; depth := 0;
	NEW(constBuffer, 4096); constWriter := constBuffer.GetWriter();
	NEW(typeBuffer, 4096); typeWriter := typeBuffer.GetWriter();
	NEW(varBuffer, 16384); varWriter := varBuffer.GetWriter();
	NEW(loadBuffer, 16384); loadWriter := loadBuffer.GetWriter();
	NEW(procBuffer, 16384); procWriter := procBuffer.GetWriter();
	nameLibrary := "Library"; nameAvailable := "Available"; nameMissing := "Missing";
	nameLoad := "Load"; nameOpen := "Open"; nameText := "Text"; nameResolve := "Resolve"
END Reset;

(*
	The module, out of a parsed AST, the header's own text (which says which macros are the
	header's) and the preprocessor's macro list. Everything the command line worked out is in
	`settings`; nothing here starts a process or reads a file, so a test can hand it three strings
	and read the module back.
*)
PROCEDURE Generate*(CONST settings: Settings; root: JSON.Value; CONST header, preprocessed: ARRAY OF CHAR;
	writer: Streams.Writer; VAR module: ARRAY OF CHAR): BOOLEAN;
VAR unit: JSON.Object; nodes: JSON.Array; item: JSON.Item; node: JSON.Object;
	kind, name, exported: Name; file, qual, desugared: Spelling; mine: BOOLEAN;
BEGIN
	Reset;
	unit := JSON.AsObject(root);
	IF unit = NIL THEN RETURN FALSE END;
	nodes := Inner(unit);
	IF nodes = NIL THEN RETURN FALSE END;

	IF settings.module # "" THEN COPY(settings.module, module)
	ELSE ModuleName(settings.header, module)
	END;

	(*	First pass: every typedef of the translation unit, wherever it came from. A parameter
		spelled `size_t` is answered by the machine's own header, not by ours. *)
	file := ""; item := nodes.items;
	WHILE item # NIL DO
		node := JSON.AsObject(item.value);
		IF node # NIL THEN
			IF Member(node, "kind", kind) & (kind = "TypedefDecl") & Member(node, "name", name)
				& Spelled(node, qual, desugared) & Fits(name, MaxName) THEN
				IF desugared # "" THEN Remember(aliases, name, desugared, 0, Alias)
				ELSE Remember(aliases, name, qual, 0, Alias)
				END
			END
		END;
		item := item.next
	END;

	(*	Second pass: the names this module will export, before a line is printed -- so that the
		few names of our own (`Load`, `Open`, `Text`) can step aside where the library has them. *)
	file := ""; item := nodes.items;
	WHILE item # NIL DO
		node := JSON.AsObject(item.value);
		IF node # NIL THEN
			FileOf(node, file);
			IF SameFile(file, settings.header) & Member(node, "name", name) & Fits(name, MaxName)
				& Exported(name, settings.prefixes, exported) THEN
				Remember(taken, exported, "", 0, Alias)
			END
		END;
		item := item.next
	END;
	Free(nameLibrary); Free(nameAvailable); Free(nameMissing);
	Free(nameLoad); Free(nameOpen); Free(nameText); Free(nameResolve);

	(*	Third pass: the declarations of this header, in the order the header has them -- which is
		C's own order, so a type is declared before whatever uses it. *)
	file := ""; item := nodes.items;
	WHILE item # NIL DO
		node := JSON.AsObject(item.value);
		IF node # NIL THEN
			FileOf(node, file);
			mine := SameFile(file, settings.header);
			IF mine & Member(node, "kind", kind) THEN
				IF kind = "TypedefDecl" THEN EmitTypedef(node, settings.prefixes)
				ELSIF kind = "RecordDecl" THEN
					IF settings.records THEN EmitRecord(node, settings.prefixes) END
				ELSIF kind = "EnumDecl" THEN EmitEnum(node, settings.prefixes)
				ELSIF kind = "FunctionDecl" THEN
					EmitFunction(node, settings.prefixes, settings.varargs)
				ELSIF kind = "VarDecl" THEN EmitVariable(node, settings.prefixes)
				END
			END
		END;
		item := item.next
	END;

	(*	And the macros, which are not in the AST at all. Last, so that a macro written over an
		enumeration constant can be worked out, and so that a macro cannot take a name a
		declaration has. *)
	ReadDefines(preprocessed);
	EmitMacros(header, settings.prefixes);

	Assemble(writer, settings, module);
	writer.Update;
	RETURN functions + typeCount + constants + dataCount > 0
END Generate;

(* --- asking clang ------------------------------------------------------------------------- *)

VAR compilerUsed: Path;

(*	One run of the C compiler, with the arguments given, and everything it said. Its diagnostics
	come back mixed into the same text on one of the two hosts, which is why the caller looks for
	the start of the JSON rather than assuming the first character is it. *)
PROCEDURE Ask(CONST program: ARRAY OF CHAR; CONST first, second, third: ARRAY OF CHAR;
	CONST includes, header: ARRAY OF CHAR; VAR output: Strings.String; VAR exitCode: SIGNED32): BOOLEAN;
VAR arguments: Strings.StringArray; include: Path; position: SIZE; count, index: SIGNED32;
	fixed: SIGNED32; run: Path;
BEGIN
	(* how many -I there are *)
	count := 0; position := 0;
	WHILE NextPiece(includes, position, include) DO
		IF include # "" THEN INC(count) END
	END;
	(*	`zig cc` is clang, and it is the one compiler here that needs a word before its options.
		Anything else is called as it stands. *)
	fixed := 1;
	IF Strings.Pos("zig", program) # -1 THEN INC(fixed) END;
	NEW(arguments, fixed + 4 + count);
	index := 0;
	arguments[index] := Strings.NewString(program); INC(index);
	IF fixed = 2 THEN arguments[index] := Strings.NewString("cc"); INC(index) END;
	arguments[index] := Strings.NewString(first); INC(index);
	arguments[index] := Strings.NewString(second); INC(index);
	arguments[index] := Strings.NewString(third); INC(index);
	position := 0;
	WHILE NextPiece(includes, position, include) DO
		IF include # "" THEN
			run := "-I"; Strings.AppendX(run, include);
			arguments[index] := Strings.NewString(run); INC(index)
		END
	END;
	arguments[index] := Strings.NewString(header);
	RETURN Processes.Run(program, arguments, output, exitCode)
END Ask;

(*	A C compiler that can dump an AST. `clang` if the machine has one; `zig cc`, which is clang,
	if it has that instead -- and nothing else, because no other compiler answers
	`-ast-dump=json`. *)
PROCEDURE FindCompiler(CONST named: ARRAY OF CHAR; VAR program: ARRAY OF CHAR): BOOLEAN;
VAR output: Strings.String; exitCode: SIGNED32; arguments: Strings.StringArray;
BEGIN
	IF named # "" THEN COPY(named, program); RETURN TRUE END;
	NEW(arguments, 2);
	arguments[0] := Strings.NewString("clang");
	arguments[1] := Strings.NewString("--version");
	IF Processes.Run("clang", arguments, output, exitCode) & (exitCode = 0) THEN
		program := "clang"; RETURN TRUE
	END;
	NEW(arguments, 2);
	arguments[0] := Strings.NewString("zig");
	arguments[1] := Strings.NewString("version");
	IF Processes.Run("zig", arguments, output, exitCode) & (exitCode = 0) THEN
		program := "zig"; RETURN TRUE
	END;
	RETURN FALSE
END FindCompiler;

(*	Where the JSON begins in what the compiler said. Diagnostics come first -- the dump is written
	after the whole unit is parsed -- so the first brace is the start of the tree. *)
PROCEDURE StartOfJson(CONST text: ARRAY OF CHAR): SIZE;
BEGIN
	RETURN Strings.Pos("{", text)
END StartOfJson;

(*	Did the compiler report an error about the header? The question is asked of the text BEFORE the
	tree and of nothing else, for two reasons: an error is printed before the dump, and the one
	thing printed after it is `zig cc` complaining that a syntax-only run produced no object file,
	which is not about the header at all. The exit code is not the measure either, for the same
	reason -- `zig cc` answers 1 for a header it read perfectly. *)
PROCEDURE Diagnosed(CONST text: ARRAY OF CHAR; upTo: SIZE): BOOLEAN;
VAR word: ARRAY 8 OF CHAR; at, index: SIZE; same: BOOLEAN;
BEGIN
	word := "error:";
	IF upTo < 0 THEN upTo := Strings.Length(text) END;
	at := 0;
	WHILE at + 6 <= upTo DO
		same := TRUE;
		FOR index := 0 TO 5 DO
			IF text[at + index] # word[index] THEN same := FALSE END
		END;
		IF same THEN RETURN TRUE END;
		INC(at)
	END;
	RETURN FALSE
END Diagnosed;

(*
	The tool, end to end: run the compiler twice, parse, generate, and write the module out.
	`error` gets a sentence when it fails, and nothing when it does not.
*)
PROCEDURE Bind*(VAR settings: Settings; writer: Streams.Writer; error: Streams.Writer;
	VAR module: ARRAY OF CHAR): BOOLEAN;
VAR program: Path; ast, dm, headerText: Strings.String; exitCode: SIGNED32;
	value: JSON.Value; reader: Streams.StringReader; start: SIZE; parser: JSON.Parser;
BEGIN
	IF ~FindCompiler(settings.compiler, program) THEN
		error.String("h2ao: no C compiler that can dump an AST -- install clang, or zig"); error.Ln;
		RETURN FALSE
	END;
	COPY(program, compilerUsed);
	IF ~ReadWhole(settings.header, headerText) THEN
		error.String("h2ao: cannot read "); error.String(settings.header); error.Ln;
		RETURN FALSE
	END;
	IF settings.libraries = "" THEN LibraryGuess(settings.header, settings.libraries) END;

	IF ~Ask(program, "-Xclang", "-ast-dump=json", "-fsyntax-only", settings.includes,
		settings.header, ast, exitCode) OR (ast = NIL) THEN
		error.String("h2ao: could not run "); error.String(program); error.Ln;
		RETURN FALSE
	END;
	start := StartOfJson(ast^);

	(*	A header that did not parse is refused, not bound. clang dumps the tree it managed to build
		even after an error -- an unfound `#include` leaves out whole types -- and a binding made of
		that would blame the types: every function using one would be listed as having no Active
		Oberon type, and the real reason would be a line the tool had swallowed. *)
	IF Diagnosed(ast^, start) THEN
		error.String("h2ao: "); error.String(program);
		error.String(" could not read "); error.String(settings.header);
		error.String(", and a header that did not parse is not bound:"); error.Ln;
		IF start = -1 THEN error.String(ast^) ELSE error.Bytes(ast^, 0, start) END;
		error.Ln;
		RETURN FALSE
	END;
	IF start = -1 THEN
		error.String("h2ao: "); error.String(program); error.String(" gave no AST:"); error.Ln;
		error.String(ast^); error.Ln;
		RETURN FALSE
	END;

	NEW(reader, LEN(ast^) - start);
	reader.SetRaw(ast^, start, LEN(ast^) - start);
	NEW(parser, reader);
	value := parser.ParseValue();
	IF parser.error OR (value = NIL) THEN
		error.String("h2ao: the AST could not be read: "); error.String(parser.errorMsg); error.Ln;
		RETURN FALSE
	END;
	ast := NIL;

	IF ~Ask(program, "-E", "-dM", "-w", settings.includes, settings.header, dm, exitCode) THEN
		error.String("h2ao: could not run "); error.String(program); error.Ln;
		RETURN FALSE
	END;
	IF dm = NIL THEN NEW(dm, 1); dm[0] := 0X END;

	IF ~Generate(settings, value, headerText^, dm^, writer, module) THEN
		error.String("h2ao: nothing in "); error.String(settings.header);
		error.String(" came out as a declaration"); error.Ln;
		RETURN FALSE
	END;
	RETURN TRUE
END Bind;

(** What was found, for whoever asks -- the command line prints it and so does a test. *)
PROCEDURE Counts*(VAR proceduresOut, typesOut, constantsOut, dataOut, skippedOut: SIGNED32);
BEGIN
	proceduresOut := functions; typesOut := typeCount; constantsOut := constants;
	dataOut := dataCount; skippedOut := skipped
END Counts;

PROCEDURE Compiler*(VAR program: ARRAY OF CHAR);
BEGIN COPY(compilerUsed, program)
END Compiler;

BEGIN
	builtins := 0;
	DefineBuiltin("void", "");
	DefineBuiltin("_Bool", "BOOLEAN");
	DefineBuiltin("bool", "BOOLEAN");
	DefineBuiltin("char", "CHAR");
	DefineBuiltin("signed char", "SIGNED8");
	DefineBuiltin("unsigned char", "UNSIGNED8");
	DefineBuiltin("short", "SIGNED16");
	DefineBuiltin("short int", "SIGNED16");
	DefineBuiltin("signed short", "SIGNED16");
	DefineBuiltin("unsigned short", "UNSIGNED16");
	DefineBuiltin("unsigned short int", "UNSIGNED16");
	DefineBuiltin("int", "SIGNED32");
	DefineBuiltin("signed", "SIGNED32");
	DefineBuiltin("signed int", "SIGNED32");
	DefineBuiltin("unsigned", "UNSIGNED32");
	DefineBuiltin("unsigned int", "UNSIGNED32");
	DefineBuiltin("long", "SignedLong");
	DefineBuiltin("long int", "SignedLong");
	DefineBuiltin("signed long", "SignedLong");
	DefineBuiltin("unsigned long", "UnsignedLong");
	DefineBuiltin("unsigned long int", "UnsignedLong");
	DefineBuiltin("long long", "SIGNED64");
	DefineBuiltin("long long int", "SIGNED64");
	DefineBuiltin("signed long long", "SIGNED64");
	DefineBuiltin("unsigned long long", "UNSIGNED64");
	DefineBuiltin("unsigned long long int", "UNSIGNED64");
	DefineBuiltin("float", "FLOAT32");
	DefineBuiltin("double", "FLOAT64");
	DefineBuiltin("int8_t", "SIGNED8");
	DefineBuiltin("uint8_t", "UNSIGNED8");
	DefineBuiltin("int16_t", "SIGNED16");
	DefineBuiltin("uint16_t", "UNSIGNED16");
	DefineBuiltin("int32_t", "SIGNED32");
	DefineBuiltin("uint32_t", "UNSIGNED32");
	DefineBuiltin("int64_t", "SIGNED64");
	DefineBuiltin("uint64_t", "UNSIGNED64");
	DefineBuiltin("size_t", "SIZE");
	DefineBuiltin("ssize_t", "SIZE");
	DefineBuiltin("ptrdiff_t", "SIZE");
	DefineBuiltin("intptr_t", "ADDRESS");
	DefineBuiltin("uintptr_t", "ADDRESS");
	DefineBuiltin("wchar_t", "WideChar");
	Reset
END H2ao.
