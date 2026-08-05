MODULE A64LoaderAux; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "the module that a loaded module calls, itself loaded"; *)

(*
	The second half of tests/A64Loader.Mod. It exists so that the check covers a call from one
	loaded module into another and not only calls from a loaded module into the linked image: the
	two are different distances -- both of these end up on the heap, the image does not -- and the
	compiler cannot tell them apart, so both have to go the same way.

	Loading this one is not asked for anywhere. It happens because A64Loader imports it, which is
	the same reason every module of a compiler loads when the compiler runs.
*)

IMPORT Streams;

CONST
	Magic* = 0A64F00DH;              (* a constant read from the other module, i.e. no fixup at all *)

TYPE
	(* An object whose methods are called from the other module: the call goes through the type
		descriptor, which is data the loader has to have patched. *)
	Counter* = OBJECT
	VAR
		total-: SIGNED32;

		PROCEDURE &Init*;
		BEGIN total := 0
		END Init;

		PROCEDURE Add*(value: SIGNED32);
		BEGIN INC(total, value)
		END Add;

		PROCEDURE Twice*(value: SIGNED32);
		BEGIN Add(value); Add(value)      (* a method calling a method of the same object *)
		END Twice;

	END Counter;

VAR
	ran-: BOOLEAN;                   (* the body of a loaded module has to run, and this says it did *)

PROCEDURE Sum*(upto: SIGNED32): SIGNED32;
VAR i, total: SIGNED32;
BEGIN
	total := 0;
	FOR i := 1 TO upto DO INC(total, i) END;
	RETURN total
END Sum;

(* Recursion, i.e. the link register saved and restored across a call inside a loaded module. *)
PROCEDURE Fibonacci*(n: SIGNED32): SIGNED32;
BEGIN
	IF n < 2 THEN RETURN n END;
	RETURN Fibonacci(n - 1) + Fibonacci(n - 2)
END Fibonacci;

(* A call from a loaded module into the image, made from the module that was itself only loaded
	because another loaded module imports it. *)
PROCEDURE Write*(out: Streams.Writer; CONST what: ARRAY OF CHAR);
BEGIN
	out.String(what); out.Update
END Write;

BEGIN
	ran := TRUE
END A64LoaderAux.
