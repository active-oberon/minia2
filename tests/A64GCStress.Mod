MODULE A64GCStress; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "what the garbage collector, the write barriers and the leave tracking have to survive on AArch64"; *)

(*
	A module that boots is not a module whose garbage collector works: booting allocates little and
	collects less. This one allocates until the collector has to run, and checks afterwards that
	what was alive is still there and still holds what it held.

	It is linked into the AArch64 image rather than loaded into it. That was once the only way --
	a loaded section lands on the heap, far from the kernel, and the 26 bit displacement of BL did
	not reach that far -- and since loading works it is a choice: linked in is how the image itself
	is built, and tests/A64Loader.Mod covers the loaded case.

	The four things being checked, in the order the flags turn them on:

	-	--preciseGC: the collector walks the stack by the metadata the compiler wrote for each
		procedure rather than by guessing what looks like a pointer. A wrong offset there loses a
		live object, and the tree that is rebuilt after every collection is what notices.
	-	--writeBarriers: a pointer written into an object the collector has already seen has to be
		reported, or the collector frees it while it is reachable. The barrier the compiler emits
		is `IF Heaps.marking THEN Heaps.MarkPointer(p)`, so what has to happen for it to matter is
		a store racing another thread's mark phase: the four workers graft chains of fresh nodes
		into an old tree while the others collect, and the main thread does the same while they
		run. Each chain is walked again after the next collection -- not before it, where nothing
		has been decided yet -- and a node the collector took is a wrong answer there.
	-	--trackLeave: a thread that leaves for C has to say so, or the collector waits for it or
		walks its stack while the C library is on it. The file this writes and reads back is in
		libc, and it runs while the other threads allocate.
	-	--cellsAreObjects: not exercised, and not exercisable in this tree on any platform. Every
		use of it in the compiler is under a test for a cell or a cell scope, so it changes what
		an ACTIVE CELL compiles to and nothing else; and a module with a cell in it does not
		compile here at all, for UnixA64 no differently from Unix64, because `ActiveCellsRuntime`
		is not among the sources minia2 carries. The flag stays on so that UnixA64 reads the same
		as Unix64, Win64 and UnixARM, which all carry it.

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
	a concurrent collector never sees them and frees what they point at.

	The nodes are chained rather than written one over the other, so that all of them stay reachable
	and every one of them is reachable only through the store the barrier is on. Reading a node back
	here proves nothing about the barrier -- no collection has run yet -- which is what `Chain` is
	for, after one has. *)
PROCEDURE Graft(root: Node; count: SIGNED32): SIGNED32;
VAR i, bad: SIGNED32; node: Node;
BEGIN
	bad := 0;
	root.left := NIL;                         (* the chain starts empty; what was there is dropped *)
	FOR i := 1 TO count DO
		node := NewNode(i);
		node.left := root.left;               (* into a fresh object, which needs no barrier *)
		root.left := node;                    (* into one the collector has seen: the barrier is here *)
		IF (root.left = NIL) OR (root.left.magic # Magic) OR (root.left.value # i) THEN INC(bad) END
	END;
	RETURN bad
END Graft;

(*	Walks what `Graft` chained and returns the number of nodes that are gone or are not what they
	were written as. This is what a missing write barrier shows up in: the nodes hang off an object
	the collector had already marked, so a collector that was not told about them frees them while
	they are reachable. Iterative, because the chain is thousands of nodes long and a recursion
	that deep would take the stack with it. *)
PROCEDURE Chain(root: Node; count: SIGNED32): SIGNED32;
VAR node: Node; bad, expected, i: SIGNED32;
BEGIN
	bad := 0; expected := count; node := root.left;
	WHILE (node # NIL) & (expected > 0) DO
		IF node.magic # Magic THEN INC(bad) END;
		IF node.value # expected THEN INC(bad) END;
		IF node.payload = NIL THEN INC(bad)
		ELSIF LEN(node.payload) # Payload THEN INC(bad)
		ELSE
			FOR i := 0 TO Payload - 1 DO
				IF node.payload[i] # expected + i THEN INC(bad) END
			END
		END;
		node := node.left; DEC(expected)
	END;
	INC(bad, expected);                       (* the chain ended early: one for each node not there *)
	RETURN bad
END Chain;

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
		INC(bad, Chain(mine, Grafts DIV 4));  (* what the barrier had to keep alive across that *)
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
	is out and not wait for it or walk the stack it is no longer on.

	A trap for whoever runs this: Files.New and Files.Register write into the working directory,
	but Files.Old resolves a bare name against the search path -- and only against the search
	path, once it has any entry at all. With an empty one a bare name falls back to the working
	directory, which is why this passes when the module sits in the directory it is started in
	and fails the moment the caller adds a search path without naming that directory too. The
	failure then has nothing to do with the collector and everything to do with the setup, so it
	says so rather than counting silently. (Same on x86-64; not an AArch64 matter.) *)
PROCEDURE Roundtrip(CONST name: ARRAY OF CHAR; rounds: SIGNED32; out: Streams.Writer): SIGNED32;
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
		IF file = NIL THEN
			INC(bad);
			IF i = 1 THEN
				out.String("  cannot read back what it just wrote -- is the working directory");
				out.Ln; out.String("  on the search path? (Files.AddSearchPath)"); out.Ln; out.Update
			END
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

(*	A collection stops every other thread with a signal, and a thread waiting on a condition variable
	must not be any the worse for it. This counts the threads that are waiting on one, and how many of
	those are still waiting afterwards.

	It is worth its own check because of what the alternative costs. A wait on a condition variable is
	allowed to end without a signal, and a signal delivered to the waiting thread is one way it does;
	glibc resumes the wait itself, Bionic does not. Objects.Await took the first reading and treated
	any return as its condition having come true and the monitor having been handed over -- so on
	Android every collection released every awaiting thread at once, each of them believing it owned
	the monitor and none of them having evaluated its AWAIT. The reference the awaiting frame was
	keeping alive went with it, and the collection after that freed a live active object, whose
	finalizer destroyed the mutex a running thread was still locking. The trap arrived in
	Objects.FindCondition, nowhere near either cause.

	Nothing about that is particular to AArch64 or to Android; it is only that Bionic is where a
	permitted rarity became a certainty. The check runs the same on either C library.

	Two numbers, because one of them has a licensed exception. The count of processes must not fall:
	a collection has no business removing a thread from the system, and the two that went missing on
	Android were live active objects wrongly finalized. The count of waiting threads is allowed to
	fall by one, and does on every C library, because a collection activates the finalizer caller on
	purpose -- so only a second one leaving counts against it. *)
PROCEDURE Census(VAR processes, waiting: SIGNED32);
VAR p: Objects.Process;
BEGIN
	p := Objects.root; processes := 0; waiting := 0;
	WHILE p # NIL DO
		INC(processes);
		IF p.mode = Objects.AwaitingCond THEN INC(waiting) END;
		p := p.nextProcess
	END
END Census;

PROCEDURE Run*(context: Commands.Context);
VAR worker: ARRAY Threads OF Worker; i, bad, failures: SIGNED32; out: Streams.Writer;
	processes, waiting, processesAfter, waitingAfter: SIGNED32;
BEGIN
	out := context.out;
	failures := 0;

	(* the threads a collection must not disturb *)
	Phase(out, "waiting threads");
	Census(processes, waiting);
	Kernel.GC;
	Census(processesAfter, waitingAfter);
	IF processesAfter < processes THEN
		out.String("  the collection removed "); out.Int(processes - processesAfter, 0);
		out.String(" of "); out.Int(processes, 0); out.String(" processes"); out.Ln;
		INC(failures, processes - processesAfter)
	END;
	IF waiting - waitingAfter > 1 THEN
		out.String("  the collection woke "); out.Int(waiting - waitingAfter, 0);
		out.String(" of "); out.Int(waiting, 0); out.String(" threads awaiting a condition"); out.Ln;
		INC(failures, waiting - waitingAfter - 1)
	END;

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

	(*	The workers start here rather than after the grafting, so that the grafting below races
		their collections: the barrier is only reached while some thread is marking, and a store
		that waits for the collector to be done with is a store the barrier never sees. *)
	Phase(out, "starting workers");
	FOR i := 0 TO Threads - 1 DO NEW(worker[i], Rounds) END;

	(* what the write barrier has to catch *)
	Phase(out, "grafting");
	bad := Graft(live, Grafts);
	IF bad # 0 THEN out.String("  grafts lost: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;
	Kernel.GC;
	bad := Chain(live, Grafts);
	IF bad # 0 THEN
		out.String("  grafts the collector took: "); out.Int(bad, 0); out.Ln; INC(failures, bad)
	END;
	bad := Broken(live.right, 3);
	IF bad # 0 THEN out.String("  after grafting: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;

	(* what leaving for C has to survive: threads allocating while this one is in the file system *)
	Phase(out, "file round trips");
	bad := Roundtrip("A64GCStress.Work", FileRounds, out);
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
	bad := Chain(live, Grafts);             (* the grafts have to be there after every collection *)
	IF bad # 0 THEN
		out.String("  grafts gone at the end: "); out.Int(bad, 0); out.Ln; INC(failures, bad)
	END;
	bad := Broken(live.right, 3);
	IF bad # 0 THEN out.String("  at the end: "); out.Int(bad, 0); out.Ln; INC(failures, bad) END;

	IF failures = 0 THEN out.String("A64GCStress: passed")
	ELSE out.String("A64GCStress: FAILED, "); out.Int(failures, 0); out.String(" checks")
	END;
	out.Ln; out.Update
END Run;

END A64GCStress.
