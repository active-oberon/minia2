MODULE A64GCStress; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "what the garbage collector, the write barriers and the leave tracking have to survive on AArch64"; *)

(*
	A module that boots is not a module whose garbage collector works: booting allocates little and
	collects less. This one allocates until the collector has to run, and checks afterwards that
	what was alive is still there and still holds what it held.

	It is linked into the AArch64 image rather than loaded into it, because loading a module there
	does not work yet: a dynamically loaded section lands on the heap, far from the code of the
	kernel, and the 26 bit displacement of BL does not reach that far.

	The four things being checked, in the order the flags turn them on:

	-	--preciseGC: the collector walks the stack by the metadata the compiler wrote for each
		procedure rather than by guessing what looks like a pointer. A wrong offset there loses a
		live object, and the tree that is rebuilt after every collection is what notices.
	-	--writeBarriers: a pointer written into an object the collector has already seen has to be
		reported, or the concurrent collector frees it while it is reachable. Grafting fresh nodes
		into an old tree between collections is what asks for that.
	-	--trackLeave: a thread that leaves for C has to say so, or the collector waits for it or
		walks its stack while the C library is on it. The file this writes and reads back is in
		libc, and it runs while the other threads allocate.
	-	--cellsAreObjects: not exercised here -- it changes what an ACTIVE CELL compiles to, and
		there are no cells in the runtime.

	`tests/a64-gc-check.sh` links it into the image and runs it under qemu.
*)

IMPORT Commands, Files, Kernel, Objects, Streams;

CONST
	Magic = 0A64C0DEH;      (* every node carries it; a collector that moves or frees wrongly loses it *)
	Depth = 12;             (* 8191 nodes a tree *)
	Payload = 24;           (* elements of the array each node points to *)
	Rounds = 16;            (* collections the live tree has to survive *)
	Garbage = 150;          (* trees dropped between two collections *)
	Grafts = 8000;          (* pointers written into an old object between two collections *)
	Threads = 4;
	FileRounds = 120;

TYPE
	Node = POINTER TO RECORD
		left, right: Node;
		payload: POINTER TO ARRAY OF SIGNED32;
		magic, value: SIGNED32
	END;

VAR
	live: Node;             (* the tree that has to be there after every collection *)

PROCEDURE NewNode(value: SIGNED32): Node;
VAR node: Node; i: SIGNED32;
BEGIN
	NEW(node); node.magic := Magic; node.value := value;
	NEW(node.payload, Payload);
	FOR i := 0 TO Payload - 1 DO node.payload[i] := value + i END;
	RETURN node
END NewNode;

PROCEDURE Build(depth, value: SIGNED32): Node;
VAR node: Node;
BEGIN
	node := NewNode(value);
	IF depth > 0 THEN
		node.left := Build(depth - 1, value * 2);
		node.right := Build(depth - 1, value * 2 + 1)
	END;
	RETURN node
END Build;

(* Walks the tree and returns the number of nodes that are not what they were built as. *)
PROCEDURE Broken(node: Node; value: SIGNED32): SIGNED32;
VAR bad, i: SIGNED32;
BEGIN
	IF node = NIL THEN RETURN 1 END;
	bad := 0;
	IF node.magic # Magic THEN INC(bad) END;
	IF node.value # value THEN INC(bad) END;
	IF node.payload = NIL THEN INC(bad)
	ELSIF LEN(node.payload) # Payload THEN INC(bad)
	ELSE
		FOR i := 0 TO Payload - 1 DO
			IF node.payload[i] # value + i THEN INC(bad) END
		END
	END;
	IF node.left # NIL THEN
		INC(bad, Broken(node.left, value * 2));
		INC(bad, Broken(node.right, value * 2 + 1))
	END;
	RETURN bad
END Broken;

(* Drops trees on the floor: what the collector is meant to take. *)
PROCEDURE Drop(trees: SIGNED32);
VAR i: SIGNED32; garbage: Node;
BEGIN
	FOR i := 1 TO trees DO
		garbage := Build(6, i);
		IF garbage.magic # Magic THEN garbage := NIL END  (* uses it, so nothing optimises it away *)
	END;
	garbage := NIL
END Drop;

(*	Writes fresh pointers into an object the collector has already marked. Without a write barrier
	a concurrent collector never sees them and frees what they point at. The nodes are read back
	afterwards, so a lost one is a wrong answer rather than a silent one. *)
PROCEDURE Graft(root: Node; count: SIGNED32): SIGNED32;
VAR i, bad: SIGNED32; node: Node;
BEGIN
	bad := 0;
	FOR i := 1 TO count DO
		node := NewNode(i);
		root.left := node;                    (* the barrier is on this store *)
		IF (root.left = NIL) OR (root.left.magic # Magic) OR (root.left.value # i) THEN INC(bad) END
	END;
	RETURN bad
END Graft;

(* One worker's share: allocate, collect, verify, and do it again. *)
PROCEDURE Cycle(rounds: SIGNED32): SIGNED32;
VAR mine: Node; i, bad: SIGNED32;
BEGIN
	bad := 0;
	mine := Build(Depth - 2, 1);
	FOR i := 1 TO rounds DO
		Drop(Garbage);
		INC(bad, Graft(mine, Grafts DIV 4));
		Kernel.GC;
		INC(bad, Broken(mine.right, 3));      (* the half of the tree the grafts do not touch *)
		Objects.Yield
	END;
	RETURN bad
END Cycle;

TYPE
	(* One worker: the same allocation and verification loop, run concurrently with the others. *)
	Worker = OBJECT
	VAR
		rounds, failures: SIGNED32;
		done: BOOLEAN;

		PROCEDURE &Init*(rounds: SIGNED32);
		BEGIN
			SELF.rounds := rounds; failures := 0; done := FALSE
		END Init;

		PROCEDURE Finished;
		BEGIN {EXCLUSIVE}
			done := TRUE
		END Finished;

		PROCEDURE Wait*(): SIGNED32;
		BEGIN {EXCLUSIVE}
			AWAIT(done);
			RETURN failures
		END Wait;

	BEGIN {ACTIVE}
		failures := Cycle(rounds);
		Finished
	END Worker;

(*	A round trip through the C library, run while the other threads allocate. What it is after is
	the state a thread leaves behind when it goes into C: the collector has to see that the thread
	is out and not wait for it or walk the stack it is no longer on. *)
PROCEDURE Roundtrip(CONST name: ARRAY OF CHAR; rounds: SIGNED32): SIGNED32;
VAR file: Files.File; writer: Files.Writer; reader: Files.Reader; bad, i, value: SIGNED32;
BEGIN
	bad := 0;
	FOR i := 1 TO rounds DO
		file := Files.New(name);
		IF file = NIL THEN RETURN rounds END;
		Files.OpenWriter(writer, file, 0);
		writer.RawLInt(i); writer.RawLInt(i * 3); writer.Update;
		Files.Register(file);

		file := Files.Old(name);
		IF file = NIL THEN INC(bad)
		ELSE
			Files.OpenReader(reader, file, 0);
			reader.RawLInt(value); IF value # i THEN INC(bad) END;
			reader.RawLInt(value); IF value # i * 3 THEN INC(bad) END
		END;
		Drop(2)
	END;
	RETURN bad
END Roundtrip;

(*	Says where it is before it goes there: what hangs is then read off the last line printed,
	which is the only way to tell one blocked thread from another under an emulator. *)
PROCEDURE Phase(out: Streams.Writer; CONST name: ARRAY OF CHAR);
BEGIN
	out.String("  "); out.String(name); out.Ln; out.Update
END Phase;

PROCEDURE Run*(context: Commands.Context);
VAR worker: ARRAY Threads OF Worker; i, bad, failures: SIGNED32; out: Streams.Writer;
BEGIN
	out := context.out;
	failures := 0;

	(* the tree that is alive from here to the end *)
	Phase(out, "building");
	live := Build(Depth, 1);
	bad := Broken(live, 1);
	IF bad # 0 THEN out.String("  built wrong: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;

	(* what one thread does: allocate, collect, and find the tree unchanged *)
	Phase(out, "collecting");
	FOR i := 1 TO Rounds DO
		Drop(Garbage);
		Kernel.GC;
		bad := Broken(live, 1);
		IF bad # 0 THEN
			out.String("  round "); out.Int(i, 0); out.String(": "); out.Int(bad, 0);
			out.String(" nodes lost or changed"); out.Ln; INC(failures, bad)
		END
	END;

	(* what the write barrier has to catch *)
	Phase(out, "grafting");
	bad := Graft(live, Grafts);
	IF bad # 0 THEN out.String("  grafts lost: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;
	Kernel.GC;
	bad := Broken(live.right, 3);
	IF bad # 0 THEN out.String("  after grafting: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;

	(* what leaving for C has to survive: threads allocating while this one is in the file system *)
	Phase(out, "starting workers");
	FOR i := 0 TO Threads - 1 DO NEW(worker[i], Rounds) END;
	Phase(out, "file round trips");
	bad := Roundtrip("A64GCStress.Work", FileRounds);
	IF bad # 0 THEN out.String("  file round trips wrong: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;
	Phase(out, "waiting for workers");
	FOR i := 0 TO Threads - 1 DO
		bad := worker[i].Wait();
		IF bad # 0 THEN
			out.String("  worker "); out.Int(i, 0); out.String(": "); out.Int(bad, 0);
			out.String(" nodes lost or changed"); out.Ln; INC(failures, bad)
		END
	END;

	Phase(out, "last collection");
	Kernel.GC;
	bad := Broken(live.right, 3);
	IF bad # 0 THEN out.String("  at the end: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;

	IF failures = 0 THEN out.String("A64GCStress: passed")
	ELSE out.String("A64GCStress: FAILED, "); out.Int(failures, 0); out.String(" checks")
	END;
	out.Ln; out.Update
END Run;

END A64GCStress.
