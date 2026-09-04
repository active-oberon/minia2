MODULE TranspilerCases; (** AUTHOR "Andrii Puhachenko"; PURPOSE "One module per hole the C transpiler used to fall into"; *)

(* Every procedure here is a construct FoxTranspilerBackend either refused or wrote wrongly.
	tests/transpiler-check.sh transpiles this module and reads the C back, so a regression shows up
	as a missing shape rather than as a trap somewhere in the stdlib. *)

TYPE
	Box* = OBJECT VAR value*: SIGNED32; END Box;

VAR sink*: SIGNED64;

(* sets of a width other than the address: HALT (1234) in PrintBasicType *)
PROCEDURE Sets* (a: SET8; b: SET16; c: SET32; d: SET64);
BEGIN sink := 0;
END Sets;

(* unsigned integers used to be printed as the signed C type of the same width *)
PROCEDURE Unsigneds* (a: UNSIGNED8; b: UNSIGNED16; c: UNSIGNED32; d: UNSIGNED64);
BEGIN sink := 0;
END Unsigneds;

(* the backslash: printed as '\' -- one quote, one backslash, and a C compiler that stops there *)
PROCEDURE Escapes* (VAR c: CHAR; VAR s: ARRAY OF CHAR);
BEGIN
	c := '\'; c := '"'; c := 0AX;
	COPY ('a\b"c', s);
END Escapes;

(* VAR among the statements: no VisitDeclarationStatement at all, so an abstract HALT (100) *)
PROCEDURE Declared* (): SIGNED32;
BEGIN
	VAR local := 41;
	INC (local);
	RETURN local;
END Declared;

(* RESULT is a designator, and it needs a C variable to stand for *)
PROCEDURE Result* (): Box;
BEGIN
	NEW (RESULT); RESULT.value := 7;
	RETURN RESULT;
END Result;

PROCEDURE Widths* (): SIZE;
BEGIN RETURN SIZE OF SIZE * 8;
END Widths;

(* ROL/ROR/SHL/SHR/ORD32 had no case; ROT shifted by the full width when the count was zero *)
PROCEDURE Rotates* (x: UNSIGNED32; n: SIGNED32): UNSIGNED32;
BEGIN RETURN ROL (x, n) + ROR (x, n) + SHL (x, n) + SHR (x, n) + UNSIGNED32 (ORD32 ('a'));
END Rotates;

(* MIN/MAX of two arguments: the backend printed the folded constant, and there is none *)
PROCEDURE Bounds* (a, b: SIGNED32): SIGNED32;
BEGIN RETURN MAX (a, b) + MIN (a, b);
END Bounds;

(* x(SIGNED32) is written like a type guard and means a conversion *)
PROCEDURE Narrow* (x: SIZE): SIGNED32;
BEGIN RETURN x(SIGNED32);
END Narrow;

(* TRACE goes through the module named by --traceModule, and transpiler-check.sh reads what it
	printed off the running binary's stdout *)
PROCEDURE Say*;
VAR answer: SIGNED32;
BEGIN answer := 6 * 7; TRACE (answer);
END Say;

END TranspilerCases.
