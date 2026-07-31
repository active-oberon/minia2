MODULE A64Codegen; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "a module the A64 code generator has to get through"; *)

(*
	Not a test of what the code does -- nothing runs this yet -- but of what the code generator can
	reach the end of. Every procedure here is one shape of intermediate code: a call and a frame, a
	loop and a branch in both directions, integer arithmetic including the division that has to be
	corrected from truncating to flooring, floating point in both widths, the conversions between
	them, narrow integers, sets, records and arrays, and a module body that references symbols and
	builds floating point constants.

	`task a64-codegen` compiles it for UnixA64 and disassembles the result with llvm-mc; a defect
	shows up either as a refusal to encode or as a disassembly that does not read as intended.
*)

TYPE
	Point = RECORD x, y: SIGNED32 END;

VAR
	array: ARRAY 16 OF SIGNED32;
	point: Point;
	flag: BOOLEAN;
	real: FLOAT64;
	small: FLOAT32;
	byte: SIGNED8;
	big: SIGNED64;
	bits: SET;

PROCEDURE Add*(a, b: SIGNED32): SIGNED32;
BEGIN
	RETURN a + b
END Add;

PROCEDURE Sum*(n: SIGNED32): SIGNED32;
VAR i, s: SIGNED32;
BEGIN
	s := 0; i := 0;
	WHILE i < n DO s := Add(s, i); INC(i) END;
	RETURN s
END Sum;

PROCEDURE Arith*(a, b: SIGNED64): SIGNED64;
BEGIN
	RETURN a * b + a DIV b - a MOD b
END Arith;

PROCEDURE Unsigned*(a, b: UNSIGNED32): UNSIGNED32;
BEGIN
	RETURN a DIV b + a MOD b
END Unsigned;

PROCEDURE Floats*(x, y: FLOAT64): FLOAT64;
BEGIN
	RETURN x * y + x / y - ABS(x)
END Floats;

PROCEDURE Mixed*(n: SIGNED32; x: FLOAT32): FLOAT64;
BEGIN
	RETURN LONG(x) * n
END Mixed;

PROCEDURE Truncate*(x: FLOAT64): SIGNED32;
BEGIN
	RETURN ENTIER(x)
END Truncate;

PROCEDURE Bits*(a, b: SET): SET;
BEGIN
	RETURN a * b + a / b - a
END Bits;

PROCEDURE Shifts*(a: SIGNED32; n: SIGNED32): SIGNED32;
BEGIN
	RETURN LSH(a, n) + ASH(a, -n) + ROT(a, n)
END Shifts;

PROCEDURE Narrow*(v: SIGNED8): SIGNED64;
BEGIN
	RETURN LONG(LONG(v))
END Narrow;

PROCEDURE Compare*(a, b: SIGNED32): BOOLEAN;
BEGIN
	RETURN (a < b) OR (a = b) & (a >= 0)
END Compare;

PROCEDURE Loop*(): SIGNED32;
VAR i, s: SIGNED32;
BEGIN
	s := 0;
	FOR i := 0 TO 15 DO array[i] := i; INC(s, array[i]) END;
	point.x := s; point.y := -s;
	flag := s > 0;
	RETURN point.x + point.y
END Loop;

BEGIN
	real := Floats(2.0, 3.0);
	small := 1.5;
	byte := 7;
	big := Arith(100, 7);
	bits := Bits({0, 2}, {1, 2});
	flag := Compare(Sum(10), Loop())
END A64Codegen.
