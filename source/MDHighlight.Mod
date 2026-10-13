MODULE MDHighlight; (** AUTHOR "BohdanT"; PURPOSE:  syntax highlighting of Active Oberon source code, line by line *)

(*
	Line splits one line of source code into Spans, each of one kind (keyword, comment, ...); the spans
	cover the whole line. The state (nesting depth of a comment) is carried from line to line, so the caller
	calls Reset before the first line of a code block and passes the same State to every Line.

	Recognized: keywords (upper case, Oberon is case sensitive), predeclared types and procedures,
	strings "..." and '...', numbers (also 0FFH, 0DX, 1.5E-3), comments (* ... *) that nest and may span lines,
	and the name of a procedure after PROCEDURE.
*)

CONST
	Plain* = 0; Keyword* = 1; Builtin* = 2; String* = 3; Number* = 4; Comment* = 5; ProcName* = 6;

	Keywords1 = "ARRAY AWAIT BEGIN BY CASE CELL CELLNET CODE CONST DEFINITION DIV DO ELSE ELSIF END ENUM EXIT FALSE";
	Keywords2 = "FINAL FOR FROM IF IGNORE IMAGINARY IMPORT IN IS LOOP MOD MODULE NIL OBJECT OF OPERATOR OR OUT PORT";
	Keywords3 = "POINTER PROCEDURE RECORD REPEAT RETURN SELF THEN THIS TO TRUE TYPE UNTIL VAR WHILE WITH";
	Builtins1 = "ANY BOOLEAN CHAR CHAR8 CHAR16 CHAR32 BYTE SHORTINT INTEGER LONGINT HUGEINT REAL LONGREAL SET";
	Builtins2 = "SIGNED8 SIGNED16 SIGNED32 SIGNED64 UNSIGNED8 UNSIGNED16 UNSIGNED32 UNSIGNED64 FLOAT32 FLOAT64 SIZE ADDRESS";
	Builtins3 = "ABS ASH ASSERT CAP CHR COPY DEC ENTIER EXCL FLOOR HALT INC INCL LEN LONG LSH MAX MIN NEW ODD ORD ROL ROR ROT SHORT SIZEOF";

TYPE
	Span* = OBJECT
	VAR
		start*, end*: SIGNED32;	(* the characters start .. end-1 of the line *)
		kind*: SIGNED32;
		next*: Span;
	END Span;

	State* = RECORD
		depth*: SIGNED32;	(* inside this many open comments *)
		afterProc: BOOLEAN;	(* the last word was PROCEDURE: the next name is a procedure name *)
	END;

PROCEDURE Reset*(VAR st: State);
BEGIN
	st.depth := 0; st.afterProc := FALSE
END Reset;

(** is this the language of a code block (the first word of its info string)? *)
PROCEDURE IsOberon*(CONST info: ARRAY OF CHAR): BOOLEAN;
VAR w: ARRAY 24 OF CHAR; i: SIGNED32; c: CHAR;
BEGIN
	i := 0;
	WHILE (info[i] # 0X) & (info[i] # ' ') & (i < LEN(w) - 1) DO
		c := info[i];
		IF (c >= 'A') & (c <= 'Z') THEN c := CHR(ORD(c) + 32) END;
		w[i] := c; INC(i)
	END;
	w[i] := 0X;
	RETURN (w = "oberon") OR (w = "ao") OR (w = "activeoberon") OR (w = "a2")
END IsOberon;

(* is word one of the words of list (separated by single spaces)? *)
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

PROCEDURE IsDigit(c: CHAR): BOOLEAN;
BEGIN
	RETURN (c >= '0') & (c <= '9')
END IsDigit;

PROCEDURE IsAlnum(c: CHAR): BOOLEAN;
BEGIN
	RETURN ((c >= '0') & (c <= '9')) OR ((c >= 'A') & (c <= 'Z')) OR ((c >= 'a') & (c <= 'z'))
END IsAlnum;

(* letters, digits, '_' and the bytes of UTF-8 characters *)
PROCEDURE IsIdentChar(c: CHAR): BOOLEAN;
BEGIN
	RETURN IsAlnum(c) OR (c = '_') OR (ORD(c) >= 128)
END IsIdentChar;

(* appends the span [from, to) to the list, joining it with the last span if that has the same kind *)
PROCEDURE Emit(VAR first, last: Span; from, to, kind: SIGNED32);
VAR sp: Span;
BEGIN
	IF to <= from THEN RETURN END;
	IF (last # NIL) & (last.kind = kind) & (last.end = from) THEN
		last.end := to
	ELSE
		NEW(sp); sp.start := from; sp.end := to; sp.kind := kind; sp.next := NIL;
		IF last # NIL THEN last.next := sp ELSE first := sp END;
		last := sp
	END
END Emit;

(* moves j over the rest of a comment; stops at its end or at the end of the line *)
PROCEDURE SkipComment(CONST s: ARRAY OF CHAR; VAR j: SIGNED32; VAR depth: SIGNED32);
BEGIN
	WHILE (s[j] # 0X) & (depth > 0) DO
		IF (s[j] = '(') & (s[j + 1] = '*') THEN
			INC(depth); INC(j, 2)
		ELSIF (s[j] = '*') & (s[j + 1] = ')') THEN
			DEC(depth); INC(j, 2)
		ELSE
			INC(j)
		END
	END
END SkipComment;

(** the spans of a line, in order, covering all of it; NIL for an empty line *)
PROCEDURE Line*(CONST s: ARRAY OF CHAR; VAR st: State): Span;
VAR first, last: Span; i, j, k, kind: SIGNED32; c: CHAR; word: ARRAY 64 OF CHAR;
BEGIN
	first := NIL; last := NIL; i := 0;
	WHILE s[i] # 0X DO
		c := s[i];
		IF st.depth > 0 THEN	(* the line goes on inside a comment *)
			j := i; SkipComment(s, j, st.depth);
			Emit(first, last, i, j, Comment); i := j
		ELSIF (c = '(') & (s[i + 1] = '*') THEN
			st.depth := 1; j := i + 2; SkipComment(s, j, st.depth);
			Emit(first, last, i, j, Comment); i := j
		ELSIF (c = '"') OR (c = "'") THEN
			j := i + 1;
			WHILE (s[j] # 0X) & (s[j] # c) DO INC(j) END;
			IF s[j] = c THEN INC(j) END;
			Emit(first, last, i, j, String); i := j
		ELSIF IsDigit(c) THEN
			j := i;
			WHILE IsAlnum(s[j]) DO INC(j) END;	(* 12, 0FFH, 0DX *)
			IF (s[j] = '.') & IsDigit(s[j + 1]) THEN	(* a real number; "1..5" is a range *)
				INC(j);
				WHILE IsAlnum(s[j]) DO INC(j) END;
				IF ((s[j - 1] = 'E') OR (s[j - 1] = 'D')) & ((s[j] = '+') OR (s[j] = '-')) THEN
					INC(j);
					WHILE IsDigit(s[j]) DO INC(j) END
				END
			END;
			Emit(first, last, i, j, Number); i := j
		ELSIF IsIdentChar(c) THEN
			j := i;
			WHILE IsIdentChar(s[j]) DO INC(j) END;
			k := 0;
			WHILE (i + k < j) & (k < LEN(word) - 1) DO word[k] := s[i + k]; INC(k) END;
			word[k] := 0X;
			kind := Plain;
			IF InList(Keywords1, word) OR InList(Keywords2, word) OR InList(Keywords3, word) THEN
				kind := Keyword; st.afterProc := (word = "PROCEDURE")
			ELSIF InList(Builtins1, word) OR InList(Builtins2, word) OR InList(Builtins3, word) THEN
				kind := Builtin; st.afterProc := FALSE
			ELSE
				IF st.afterProc THEN kind := ProcName END;
				st.afterProc := FALSE
			END;
			Emit(first, last, i, j, kind); i := j
		ELSE	(* spaces, operators, punctuation *)
			IF (c = '(') OR (c = '{') OR (c = ';') OR (c = ':') THEN st.afterProc := FALSE END;
			Emit(first, last, i, i + 1, Plain); INC(i)
		END
	END;
	RETURN first
END Line;

END MDHighlight.
