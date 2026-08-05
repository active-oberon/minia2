MODULE A64Loader; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "what a dynamically loaded module has to survive on AArch64"; *)

(*
	A module that is loaded rather than linked. Loading one on AArch64 did not work at all: the
	code of a loaded section is allocated on the heap while the image it calls lies where it was
	loaded, and `BL` carries a 26 bit displacement, which reaches 128 megabytes and not the 70
	terabytes between the two. Underneath that sat a second reason, and it was the harder one --
	`Loader.Arrangement.Patch` wrote whole bytes and asserted that a fixup was whole bytes, so a
	displacement inside an instruction word could not have been patched even in range.

	Without loading there is no `ob run`, no REPL and no language server on AArch64, and no
	compiling on the machine itself, which is what self hosting means.

	What is checked, and why each of it is here:

	-	calls into the image, which is what the address of a kernel procedure being far away broke;
	-	calls into another loaded module (A64LoaderAux, loaded because this one imports it): both
		ends on the heap, which is a different distance and the same instruction;
	-	calls inside this module, backwards and forwards, which stay relative and are therefore the
		fixups that the loader had to learn to patch bit by bit;
	-	the module body, the body of an active object, and a method through a type descriptor, none
		of which is reached by a plain call at all;
	-	a procedure variable, i.e. the address of loaded code taken as data;
	-	a collection with loaded procedures on the stack, because the metadata the collector walks
		is written by the compiler and relocated by the loader.

	`tests/a64-loader-check.sh` compiles it for UnixA64, leaves it out of the image, and loads it
	from the shell of the system running under qemu.
*)

IMPORT Commands, Kernel, Objects, Streams, Strings, A64LoaderAux;

CONST
	Chain = 20000;                   (* nodes allocated, enough that the collector has to run *)
	Magic = 55555;

TYPE
	Node = POINTER TO RECORD
		next: Node;
		value: SIGNED32
	END;

	(* A method and a method that overrides it: the call goes through the type descriptor, which is
		data of the loaded module and holds addresses of its code. *)
	Shape = OBJECT
		PROCEDURE Value*(): SIGNED32;
		BEGIN RETURN 1
		END Value;
	END Shape;

	Doubled = OBJECT(Shape)
		PROCEDURE Value*(): SIGNED32;
		BEGIN RETURN 2 * Value^()
		END Value;
	END Doubled;

	(* An active object declared in a loaded module: its body is code that nothing calls, reached
		from the runtime instead. *)
	Ticker = OBJECT
	VAR
		ticks: SIGNED32;
		done: BOOLEAN;

		PROCEDURE Finished;
		BEGIN {EXCLUSIVE}
			done := TRUE
		END Finished;

		PROCEDURE Wait*(): SIGNED32;
		BEGIN {EXCLUSIVE}
			AWAIT(done);
			RETURN ticks
		END Wait;

	BEGIN {ACTIVE}
		ticks := Count(1000);
		Finished
	END Ticker;

VAR
	greeting: ARRAY 32 OF CHAR;      (* module data, i.e. an absolute fixup, filled in by the body *)
	indirect: PROCEDURE (value: SIGNED32): SIGNED32;

PROCEDURE Count(upto: SIGNED32): SIGNED32;
VAR i, total: SIGNED32;
BEGIN
	total := 0;
	FOR i := 1 TO upto DO INC(total, i) END;
	RETURN total
END Count;

(* A call backwards, to a procedure already declared. *)
PROCEDURE Backwards(upto: SIGNED32): SIGNED32;
BEGIN
	RETURN Count(upto)
END Backwards;

(* A call forwards, to a procedure declared further down: the same instruction, the other sign of
	displacement, and a fixup that is only resolved once both sections have an address. *)
PROCEDURE Forwards(value: SIGNED32): SIGNED32;
BEGIN
	RETURN Square(value)
END Forwards;

PROCEDURE Square(value: SIGNED32): SIGNED32;
BEGIN
	RETURN value * value
END Square;

PROCEDURE Build(count: SIGNED32): Node;
VAR head, node: Node; i: SIGNED32;
BEGIN
	head := NIL;
	FOR i := 1 TO count DO
		NEW(node); node.value := i; node.next := head; head := node
	END;
	RETURN head
END Build;

(* How many of the nodes are gone or changed. Called with the chain on the stack of the caller and
	after a collection, so a wrong stack map in loaded code is what this reports. *)
PROCEDURE Broken(head: Node; count: SIGNED32): SIGNED32;
VAR node: Node; bad, expected: SIGNED32;
BEGIN
	bad := 0; expected := count; node := head;
	WHILE (node # NIL) & (expected > 0) DO
		IF node.value # expected THEN INC(bad) END;
		node := node.next; DEC(expected)
	END;
	INC(bad, expected);
	RETURN bad
END Broken;

PROCEDURE Check(out: Streams.Writer; CONST what: ARRAY OF CHAR; got, want: SIGNED32; VAR failures: SIGNED32);
BEGIN
	IF got # want THEN
		out.String("  "); out.String(what); out.String(": "); out.Int(got, 0);
		out.String(" where "); out.Int(want, 0); out.String(" was due"); out.Ln; out.Update;
		INC(failures)
	END
END Check;

PROCEDURE Run*(context: Commands.Context);
VAR out: Streams.Writer; counter: A64LoaderAux.Counter; shape: Shape; doubled: Doubled;
	ticker: Ticker; head: Node; failures, number: SIGNED32; text: ARRAY 32 OF CHAR;
BEGIN
	out := context.out;
	failures := 0;

	(* the image, which is what being far away broke *)
	out.String("  calling the image"); out.Ln; out.Update;
	Strings.IntToStr(Magic, text);
	Strings.StrToInt(text, number);
	Check(out, "a round trip through Strings", number, Magic, failures);
	Check(out, "the greeting the body wrote", SIGNED32(Strings.Length(greeting)), 9, failures);

	(* another loaded module *)
	out.String("  calling the other loaded module"); out.Ln; out.Update;
	IF ~A64LoaderAux.ran THEN
		out.String("  the body of A64LoaderAux did not run"); out.Ln; out.Update; INC(failures)
	END;
	Check(out, "A64LoaderAux.Magic", A64LoaderAux.Magic, 0A64F00DH, failures);
	Check(out, "A64LoaderAux.Sum", A64LoaderAux.Sum(1000), 500500, failures);
	Check(out, "A64LoaderAux.Fibonacci", A64LoaderAux.Fibonacci(20), 6765, failures);
	NEW(counter);
	counter.Add(5); counter.Twice(10);
	Check(out, "a method of the other loaded module", counter.total, 25, failures);
	A64LoaderAux.Write(out, "  the other loaded module writes this line");
	out.Ln; out.Update;

	(* this module *)
	out.String("  calling itself"); out.Ln; out.Update;
	Check(out, "a call backwards", Backwards(100), 5050, failures);
	Check(out, "a call forwards", Forwards(7), 49, failures);
	indirect := Square;
	Check(out, "a procedure variable", indirect(9), 81, failures);
	NEW(shape); NEW(doubled);
	Check(out, "a method", shape.Value(), 1, failures);
	Check(out, "an overriding method", doubled.Value(), 2, failures);

	(* code of this module reached from the runtime rather than by a call *)
	out.String("  running an active object"); out.Ln; out.Update;
	NEW(ticker);
	Check(out, "the body of an active object", ticker.Wait(), 500500, failures);

	(* the collector, with this module's procedures on the stack *)
	out.String("  collecting"); out.Ln; out.Update;
	head := Build(Chain);
	Kernel.GC;
	Objects.Yield;
	Check(out, "nodes lost or changed across a collection", Broken(head, Chain), 0, failures);

	IF failures = 0 THEN
		out.String("A64Loader: passed")
	ELSE
		out.String("A64Loader: "); out.Int(failures, 0); out.String(" failed")
	END;
	out.Ln; out.Update
END Run;

BEGIN
	greeting := "A64Loader"
END A64Loader.
