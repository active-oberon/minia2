MODULE A64OnDevice; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "the module that the AArch64 system compiles on itself"; *)

(*
	Compiled by the compiler running on AArch64, and then loaded and run by the same system in the
	same session. Nothing in it is interesting on its own -- what is being checked is that it was
	built where it runs, which is what self hosting is and what `ob run`, the REPL and the language
	server all reduce to.

	`tests/a64-selfhost-check.sh` drives it.
*)

IMPORT Commands, Streams, Strings;

PROCEDURE Total(upto: SIGNED32): SIGNED32;
VAR i, total: SIGNED32;
BEGIN
	total := 0;
	FOR i := 1 TO upto DO INC(total, i * i) END;
	RETURN total
END Total;

PROCEDURE Run*(context: Commands.Context);
VAR out: Streams.Writer; text: ARRAY 32 OF CHAR; number, total: SIGNED32;
BEGIN
	out := context.out;
	total := Total(100);

	(* a round trip through the image, so that the module is not only loaded but talking *)
	Strings.IntToStr(total, text);
	Strings.StrToInt(text, number);

	IF (total = 338350) & (number = total) THEN
		out.String("A64OnDevice: passed")
	ELSE
		out.String("A64OnDevice: "); out.Int(total, 0); out.String(" and "); out.Int(number, 0);
		out.String(" where 338350 was due")
	END;
	out.Ln; out.Update
END Run;

END A64OnDevice.
