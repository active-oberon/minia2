MODULE AMD64Codegen; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "a module the AMD64 code generator has to encode correctly"; *)

(*
	The AMD64 twin of A64Codegen. The reason it is worth having even though AMD64 code runs here and
	the execution suites already run it: an instruction can execute correctly on every path a test
	takes and still be encoded wrongly on a path no test takes. That is exactly how the immediate
	defect got in -- `x MOD 100000000H` returned `x`, because a 64-bit immediate above
	MAX(SIGNED32) was written as a sign-extended 32-bit one, and no execution case used a constant
	in that range.

	So the shapes here lean on what the encoder decides rather than on what the arithmetic means:
	immediates at every width boundary, narrow rotations, shifts by a variable, sign and zero
	extension, and the same frames, loops and floating point as the A64 module.

	`task amd64-codegen` compiles it for Unix64 and disassembles what came out with llvm-mc; a word
	llvm-mc cannot place is a wrong encoding, and the listing `--verbose` prints is for reading the
	rest by eye.
*)

IMPORT SYSTEM;

CONST
	(* The four boundaries a 64-bit immediate is encoded across. Above MAX(SIGNED32) an immediate no
		longer fits the sign-extended 32-bit form the instruction set prefers, and that is where the
		encoder went wrong. *)
	Signed32Max = 07FFFFFFFH;
	Signed32Over = 080000000H;
	Unsigned32Max = 0FFFFFFFFH;
	Wide = 0123456789ABCDEFH;

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
	huge: UNSIGNED64;
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

PROCEDURE Unsigned64*(a, b: UNSIGNED64): UNSIGNED64;
BEGIN
	RETURN a DIV b + a MOD b
END Unsigned64;

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

PROCEDURE Shifts64*(a: SIGNED64; n: SIGNED32): SIGNED64;
BEGIN
	RETURN LSH(a, n) + ASH(a, -n) + ROT(a, n)
END Shifts64;

(* A rotation narrower than a register: the answer depends on the width of the type, not on the
	width of the register it is computed in. AMD64 has ROL/ROR at 8 and 16 bits, so the encoder has
	to pick the narrow form rather than compute in 32. *)

PROCEDURE Swap16*(v: UNSIGNED16): UNSIGNED16;
BEGIN
	RETURN ROL(v, 8)
END Swap16;

PROCEDURE Rotate16*(v: UNSIGNED16; n: SIGNED32): UNSIGNED16;
BEGIN
	RETURN ROL(v, n)
END Rotate16;

PROCEDURE Rotate8*(v: UNSIGNED8): UNSIGNED8;
BEGIN
	RETURN ROR(v, 4)
END Rotate8;

PROCEDURE Narrow*(v: SIGNED8): SIGNED64;
BEGIN
	RETURN LONG(LONG(v))
END Narrow;

PROCEDURE Widen*(v: UNSIGNED8; w: UNSIGNED16): UNSIGNED64;
BEGIN
	RETURN LONG(LONG(v)) + LONG(LONG(w))
END Widen;

PROCEDURE Compare*(a, b: SIGNED32): BOOLEAN;
BEGIN
	RETURN (a < b) OR (a = b) & (a >= 0)
END Compare;

(* The immediate boundaries, one procedure each so a wrong encoding names itself in the listing. *)

PROCEDURE MaskLow*(x: SIGNED64): SIGNED64;
BEGIN
	RETURN x MOD (Signed32Max + 1)
END MaskLow;

PROCEDURE MaskWide*(x: SIGNED64): SIGNED64;
BEGIN
	RETURN x MOD (Unsigned32Max + 1)
END MaskWide;

PROCEDURE AddBoundaries*(x: SIGNED64): SIGNED64;
BEGIN
	RETURN x + Signed32Max + Signed32Over + Unsigned32Max
END AddBoundaries;

PROCEDURE MulWide*(x: SIGNED64): SIGNED64;
BEGIN
	RETURN x * Unsigned32Max
END MulWide;

PROCEDURE CompareWide*(x: SIGNED64): BOOLEAN;
BEGIN
	RETURN (x > Signed32Max) & (x < Wide) OR (x = Unsigned32Max)
END CompareWide;

PROCEDURE AssignWide*(): SIGNED64;
VAR v: SIGNED64;
BEGIN
	v := Unsigned32Max; v := v + Wide; v := v - Signed32Over;
	RETURN v
END AssignWide;

PROCEDURE UnsignedWide*(x: UNSIGNED64): UNSIGNED64;
BEGIN
	RETURN x DIV Unsigned32Max + x MOD Unsigned32Max
END UnsignedWide;

(* SYSTEM.VAL between a set and an integer of the same width, which is a reinterpretation and must
	emit no conversion at all -- the place where a spurious sign extension would show up. *)

PROCEDURE Reinterpret*(s: SET): SIGNED64;
BEGIN
	RETURN SYSTEM.VAL(SIGNED64, s)
END Reinterpret;

PROCEDURE HighBits*(): SET;
BEGIN
	RETURN SYSTEM.VAL(SET, Wide)
END HighBits;

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
	huge := UnsignedWide(Unsigned32Max);
	bits := Bits({0, 2}, {1, 2}) + HighBits();
	flag := Compare(Sum(10), Loop()) OR CompareWide(AssignWide())
END AMD64Codegen.
