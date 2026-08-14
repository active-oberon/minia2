MODULE FP1616;	(** AUTHOR "PL"; PURPOSE "FixPoint 16.16 Module"; *)

CONST
	FIXPOINT = 65536;						(* 2^16 *)

TYPE
(* converts a 16.16 fixpoint integer to float *)
PROCEDURE FixpToFloat*(x: SIZE): FLOAT32;
BEGIN
	RETURN (x / FIXPOINT);
END FixpToFloat;

(* converts a float into a 16.16 fixpoint integer *)
PROCEDURE FloatToFixp*(x: FLOAT32): SIGNED32;
BEGIN
	(*	What does not fit has to come back as the largest that does. This used to compare the
		number in whole units and answer in fixed-point ones, so anything above 65536 came back as
		FIXPOINT itself -- which is not a huge number but exactly one. The largest a signed 32-bit
		word holds in 16.16 is a shade under 32768. *)
	IF x >= 32768.0 THEN RETURN MAX(SIGNED32);
	ELSIF x < -32768.0 THEN RETURN MIN(SIGNED32)
	ELSE RETURN ENTIER(x * (FIXPOINT));
	END;
END FloatToFixp;

PROCEDURE Int*(fp1616: SIGNED32) : SIGNED32;
BEGIN
	RETURN fp1616 DIV FIXPOINT
END Int;

(* addition / subtraction just do it *)

(* mulitplicates 2 Fixpoint Numbers *)
PROCEDURE Mult*(x, y: SIGNED32): SIGNED32;
BEGIN
	RETURN (ENTIER(FixpToFloat(x)*y));
END Mult;

(* division of 2 fixpoint NUmbers *)
PROCEDURE Div*(x, y: SIGNED32): SIGNED32;
BEGIN
	RETURN (ENTIER(x/FixpToFloat(y)));
END Div;

END FP1616.
