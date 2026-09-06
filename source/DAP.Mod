MODULE DAP; (** AUTHOR "Andrii Puhachenko"; PURPOSE "The debug adapter: a program that trapped, read where it stopped"; *)

(*	A debugger is three quarters of the way written already, and none of it was ours: Reflection
	walks a stack and formats a value, DebugMap says which line a PC was generated from, and the
	trap handler is where a program stops. What was missing is the wire: an editor speaks the Debug
	Adapter Protocol, which is JSON-RPC in the same Content-Length frames as the language server.

	So this is post-mortem debugging. The program is launched in this process, and when it traps,
	Traps.Trapped hands over the machine context and this holds the dying activity right there --
	after ExitTrap there is no stack left to read. The editor then asks for the frames, the scopes
	and the variables, all of them read out of a stack that is still standing, and lets the program
	die when it detaches.

	A breakpoint is the same thing seen from the other end. The instruction at the line the editor
	asks for is replaced by one the processor traps on, the trap handler hands the activity over
	here, and it is held exactly as a trapped one is -- the difference being that this one is let
	go again, with its own instruction back in place. Stepping needs no more than that: a step is a
	breakpoint on every other statement of the procedure and on the place it returns to, so
	whatever the program does next, it stops.

	ponytail: one thread, and a breakpoint in a module body is missed -- the body has run by the
	time the code exists to patch. Stepping into a call stops at the next statement of the caller
	instead, because that is where the spots are; following the call needs the callee's address,
	which is a read of the instruction, which is a decoder we would rather not have. *)

IMPORT Commands, Machine, Streams, Strings, Trace, JSON, Modules, Reflection, DebugMap, Traps, SYSTEM;

CONST
	TraceCapacity = 32 * 1024;   (* one trap dump, which is what the editor is shown of it *)
	MaxFrames = 64;
	LocalsBase = 1000;   (* variablesReference of frame i is LocalsBase + i, so it is never 0 *)
	MaxValue = 1024;
	MaxSpots = 256;      (* breakpoints and the step spots that go with them, together *)

TYPE
	Name* = ARRAY 256 OF CHAR;

	(**	Ready is called by the launcher once the program's module is loaded and before the program
		starts: the code exists, so this is the one moment a breakpoint can be written into it. *)
	Ready* = PROCEDURE {DELEGATE};

	(**	Launcher compiles the program and runs it, returning when it has ended. `ob dap` passes the
		one that knows about search paths and --debug; a test passes its own. Whatever the program
		writes goes to `out`, never to this process's stdout, which carries the protocol. *)
	Launcher* = PROCEDURE {DELEGATE} (CONST program, procedure: ARRAY OF CHAR; out: Streams.Writer;
		ready: Ready; VAR message: ARRAY OF CHAR): BOOLEAN;

	Frame* = RECORD pc*, fp*: ADDRESS END;

	(* One planted instruction: where it is, what the program had there, and whose it is. *)
	Spot = RECORD adr: ADDRESS; saved: SIGNED32; armed, wanted: BOOLEAN END;

	(** One line the client asked for, and what became of it. *)
	Wish* = RECORD source*: DebugMap.Name; line*, actual*: SIGNED32; adr*: ADDRESS END;

	(**	Stopped is how a Core says the program stands still: why, and the frame it stands on.
		`ob dap` turns it into a stopped event; PET moves the caret there. *)
	Stopped* = PROCEDURE {DELEGATE} (CONST why, description: ARRAY OF CHAR);

VAR
	traced: ARRAY TraceCapacity OF CHAR;
	tracedLength: SIZE;

TYPE
	(**	Core is the debugger with no protocol in it: the two hooks A2's trap handler calls, the
		instructions planted in the program's code, and the stack of the activity being held. What
		to do when it stops is the owner's business, said once through Stopped -- `ob dap` writes a
		stopped event, PET moves the caret. Everything a driver has to read afterwards is a
		read-only field, because a getter per field would be longer than the object. *)
	Core* = OBJECT
	VAR
		frames-: ARRAY MaxFrames OF Frame;
		count-: SIGNED32;                (* frames in use, innermost first *)
		low-, high-: ADDRESS;            (* the stack the frames live on, for reading variables *)
		wishes-: ARRAY MaxSpots OF Wish; wishCount-: SIGNED32;
		stopped-: BOOLEAN;               (* the program is standing still and its stack is readable *)
		armed-: BOOLEAN;                 (* the wishes have been resolved once, so the code is patched *)
		standing-: ADDRESS;              (* the spot being stood on: it cannot be armed while we resume *)
		reason-: Name;                   (* what the trap was, for a stop that was not asked for *)
		spots: ARRAY MaxSpots OF Spot; spotCount: SIGNED32;
		released, stepping: BOOLEAN;
		say: Stopped;

		PROCEDURE &Init* (stop: Stopped);
		BEGIN
			say := stop; count := 0; stopped := FALSE; released := FALSE;
			spotCount := 0; wishCount := 0; armed := FALSE; stepping := FALSE; standing := 0
		END Init;

		(*	Walk collects the frames of the activity that stopped, the way
			Reflection.StackTraceBack does: return address and dynamic link, one word apart. *)
		PROCEDURE Walk (pc, bp, sp, stackHigh: ADDRESS);
		BEGIN
			low := sp; high := stackHigh;
			count := 0;
			WHILE (count < MaxFrames) & (bp # 0) & (bp >= low) & (bp <= high)
					& (bp MOD SIZEOF(ADDRESS) = 0) DO
				frames[count].pc := pc; frames[count].fp := bp; INC(count);
				SYSTEM.GET(bp + SIZEOF(ADDRESS), pc);   (* return address *)
				SYSTEM.GET(bp, bp)                      (* dynamic link *)
			END
		END Walk;

		(*	Traps.Trapped, on the activity that is about to die: it tells the editor where the
			program ended up, and then stands still until the editor is done with it. *)
		PROCEDURE Trapped* (sig, trapno: SIGNED32; pc, bp, sp, stackHigh: ADDRESS);
		BEGIN
			IF stopped THEN RETURN END;         (* a second trap has nowhere to be reported *)
			Disarm;                             (* the program is over: its code is its own again *)
			Walk(pc, bp, sp, stackHigh);
			Cause(sig, trapno, reason);
			standing := 0;
			stopped := TRUE;                    (* the stack is readable from here until Release *)
			say("exception", reason);
			Hold
		END Trapped;

		(*	Traps.Breakpoint, on the activity running the program. An instruction we did not plant
			is a trap the program earned, and is left to the trap handler; one we did plant is a
			place to stand still, and the program resumes on its own instruction afterwards. *)
		PROCEDURE Break* (VAR pc: ADDRESS; bp, sp, stackHigh: ADDRESS): BOOLEAN;
		VAR at: ADDRESS; i: SIGNED32; ours: BOOLEAN;
		BEGIN
			at := Hit(pc);
			i := At(at);
			IF i < 0 THEN RETURN FALSE END;
			pc := at;
			IF ~spots[i].armed THEN
				(*	One of ours, taken out of the code a moment ago -- the client detached, or asked
					for other lines, while the program was running into this one. It carries on. *)
				RETURN TRUE
			END;
			ours := ~spots[i].wanted;
			Disarm;                             (* the code is the program's own while it stands still *)
			Drop(FALSE);                        (* and the spots we planted for one resume are spent *)
			IF ours & ~stepping THEN
				(*	Planted for one reason only: to write the breakpoint just stepped off back in,
					now that the program is no longer standing on it. *)
				standing := 0; ArmAll; RETURN TRUE
			END;
			Walk(at, bp, sp, stackHigh);
			standing := at;
			stopped := TRUE;
			IF ours THEN say("step", "") ELSE say("breakpoint", "") END;
			Hold;
			RETURN TRUE
		END Break;

		(* The stopped activity waits here, so that its stack stays readable. *)
		PROCEDURE Hold;
		BEGIN {EXCLUSIVE}
			AWAIT(released);
			released := FALSE                   (* the next stop holds too, which is what stepping is *)
		END Hold;

		PROCEDURE Release*;
		BEGIN {EXCLUSIVE}
			released := TRUE; stopped := FALSE
		END Release;

		(*	--- breakpoints ---------------------------------------------------------------------
			The client asks for lines. A line is an address only once the module carrying it is
			loaded, which is what Arm is called for; from there on a breakpoint is one instruction
			written into the code and taken back out whenever the program stands still, so that
			what the editor reads is never our own patch. *)

		PROCEDURE At (adr: ADDRESS): SIGNED32;
		VAR i: SIGNED32;
		BEGIN
			FOR i := 0 TO spotCount - 1 DO IF spots[i].adr = adr THEN RETURN i END END;
			RETURN -1
		END At;

		PROCEDURE Add (adr: ADDRESS; wanted: BOOLEAN);
		BEGIN
			IF (adr = 0) OR (At(adr) >= 0) OR (spotCount >= MaxSpots) THEN RETURN END;
			spots[spotCount].adr := adr; spots[spotCount].wanted := wanted;
			spots[spotCount].armed := FALSE; INC(spotCount)
		END Add;

		PROCEDURE ArmAll;
		VAR i: SIGNED32;
		BEGIN
			FOR i := 0 TO spotCount - 1 DO
				IF ~spots[i].armed & (spots[i].adr # standing) THEN
					Plant(spots[i].adr, spots[i].saved); spots[i].armed := TRUE
				END
			END
		END ArmAll;

		PROCEDURE Disarm;
		VAR i: SIGNED32;
		BEGIN
			FOR i := 0 TO spotCount - 1 DO
				IF spots[i].armed THEN Restore(spots[i].adr, spots[i].saved); spots[i].armed := FALSE END
			END
		END Disarm;

		(* Forgets the spots we planted ourselves, or, with `all`, the client's as well. *)
		PROCEDURE Drop (all: BOOLEAN);
		VAR i, kept: SIGNED32;
		BEGIN
			kept := 0;
			FOR i := 0 TO spotCount - 1 DO
				IF ~all & spots[i].wanted THEN spots[kept] := spots[i]; INC(kept) END
			END;
			spotCount := kept
		END Drop;

		(** Forget drops every line asked for; Want adds one back. Together they are setBreakpoints. *)
		PROCEDURE Forget*;
		BEGIN
			wishCount := 0
		END Forget;

		PROCEDURE Want* (CONST source: ARRAY OF CHAR; line: SIGNED32);
		BEGIN
			IF wishCount >= MaxSpots THEN RETURN END;
			COPY(source, wishes[wishCount].source);
			wishes[wishCount].line := line; wishes[wishCount].actual := 0;
			wishes[wishCount].adr := 0; INC(wishCount)
		END Want;

		(**	Arm resolves every line into an address and writes the breakpoints in. Called once the
			module carrying them is loaded, and again whenever the lines change. *)
		PROCEDURE Arm*;
		VAR i: SIGNED32;
		BEGIN
			Disarm; Drop(TRUE);
			FOR i := 0 TO wishCount - 1 DO
				wishes[i].adr := DebugMap.AddressOf(wishes[i].source, wishes[i].line, wishes[i].actual);
				Add(wishes[i].adr, TRUE)
			END;
			armed := TRUE;
			ArmAll
		END Arm;

		(*	Where the program could be a moment from now: every other statement of the procedure it
			is standing in, and the place its own frame returns to. One of them is reached whatever
			the program does next, which is what makes a step out of a breakpoint. Continuing
			plants the same spots for one reason -- to get the breakpoint being stood on back in. *)
		PROCEDURE Steps (at: ADDRESS; leave: BOOLEAN);
		VAR procedure: DebugMap.Procedure; name, file: DebugMap.Name; start, ret: ADDRESS;
			line: SIGNED32; position: SIGNED64; i: SIZE;
		BEGIN
			IF count > 0 THEN
				SYSTEM.GET(frames[0].fp + SIZEOF(ADDRESS), ret);
				(*	Where the outermost procedure of the program returns to is not the program: it is
					the machinery that started it -- Commands.Runner, Objects.BodyStarter -- and that
					code is shared by every command in the system. A breakpoint written there is a
					breakpoint every command in A2 runs into, which in a running desktop means the
					debugger takes hold of the activity behind a hot key instead of the program. The
					line table is the boundary, the same one DAP.Report stops at: what it has no
					record of was compiled without --debug and is none of our business. *)
				IF DebugMap.PositionOf(ret, file, line, position) THEN Add(ret, FALSE) END
			END;
			IF leave THEN RETURN END;
			Reflection.GetProcedureName(at, name, start);
			IF start = 0 THEN RETURN END;
			procedure := DebugMap.Find(name);
			IF procedure = NIL THEN RETURN END;
			IF ~DebugMap.PositionOf(at, file, line, position) THEN line := 0 END;
			FOR i := 0 TO LEN(procedure.sites) - 1 DO
				IF procedure.sites[i].line # line THEN     (* a second spot on this line is not a step *)
					Add(start + procedure.sites[i].offset, FALSE)
				END
			END
		END Steps;

		(* Let the program go: on to the next breakpoint, or as far as the next statement. *)
		PROCEDURE Resume* (step, leave: BOOLEAN);
		BEGIN
			stepping := step;
			IF stopped & (standing # 0) THEN Steps(standing, leave); ArmAll END;
			Release
		END Resume;

		(*	Nothing of ours is left in the program's code once the driver is gone. The addresses are
			kept, disarmed: a program already on its way into one of them has to be told to carry on
			rather than be reported as having trapped. *)
		PROCEDURE Detach*;
		BEGIN
			Disarm; standing := 0; stepping := FALSE
		END Detach;

	END Core;

	(*	Session is the protocol around a Core: it turns requests into calls on it and its stops
		into events. Nothing about breakpoints or stacks lives here any more. *)
	Session = OBJECT
	VAR
		out: Streams.Writer;
		launch: Launcher;
		seq: SIGNED32;
		ended: BOOLEAN;
		program, procedure: Name;
		core-: Core;

		PROCEDURE &Init* (writer: Streams.Writer; launcher: Launcher);
		BEGIN
			out := writer; launch := launcher; seq := 0; ended := FALSE;
			NEW(core, SELF.Announce)
		END Init;

		(* One message out. Two activities write here -- the server and the trapped program. *)
		PROCEDURE Send (msg: JSON.Object);
		BEGIN {EXCLUSIVE}
			INC(seq); msg.Set("seq", JSON.NewNumber(seq));
			JSON.WriteFrame(out, msg)
		END Send;

		PROCEDURE Event (CONST event: ARRAY OF CHAR; body: JSON.Object);
		VAR msg: JSON.Object;
		BEGIN
			msg := JSON.NewObject();
			msg.Set("type", JSON.NewString("event"));
			msg.Set("event", JSON.NewString(event));
			IF body # NIL THEN msg.Set("body", body) END;
			Send(msg)
		END Event;

		PROCEDURE Reply (request: JSON.Object; body: JSON.Value; CONST failure: ARRAY OF CHAR);
		VAR msg: JSON.Object; command: Strings.String; id: SIGNED32;
		BEGIN
			msg := JSON.NewObject();
			msg.Set("type", JSON.NewString("response"));
			IF JSON.GetInteger(request, "seq", id) THEN msg.Set("request_seq", JSON.NewNumber(id)) END;
			IF JSON.GetString(request, "command", command) THEN msg.Set("command", JSON.NewString(command^)) END;
			msg.Set("success", JSON.NewBool(failure = ""));
			IF failure # "" THEN msg.Set("message", JSON.NewString(failure)) END;
			IF body # NIL THEN msg.Set("body", body) END;
			Send(msg)
		END Reply;


		(* The Core's Stopped: one stopped event, the editor's cue to ask about the stack. *)
		PROCEDURE Announce (CONST why, description: ARRAY OF CHAR);
		VAR body: JSON.Object;
		BEGIN
			Dump;                               (* what the program printed, before it is said to have stopped *)
			body := JSON.NewObject();
			body.Set("reason", JSON.NewString(why));
			IF description # "" THEN
				body.Set("description", JSON.NewString(description));
				body.Set("text", JSON.NewString(description))
			END;
			body.Set("threadId", JSON.NewNumber(1));
			body.Set("allThreadsStopped", JSON.NewBool(TRUE));
			Event("stopped", body)
		END Announce;


		(* Wanted replaces the lines the client wants stopped on, which is what setBreakpoints means. *)
		PROCEDURE Wanted (arguments: JSON.Object);
		VAR source: JSON.Object; list: JSON.Array; i: SIZE; line: SIGNED32; path: DebugMap.Name;
		BEGIN
			core.Forget;
			IF arguments = NIL THEN RETURN END;
			path := "";
			source := JSON.AsObject(arguments.Get("source"));
			IF source # NIL THEN
				IF JSON.GetText(source, "path", path) THEN END
			END;
			list := JSON.GetArray(arguments, "breakpoints");
			IF list = NIL THEN RETURN END;
			FOR i := 0 TO list.length - 1 DO
				IF JSON.GetInteger(JSON.AsObject(list.At(i)), "line", line) THEN
					core.Want(path, line)
				END
			END
		END Wanted;

		(* What the client is told about one of the lines it asked for. *)
		PROCEDURE Verdict (i: SIGNED32): JSON.Object;
		VAR item, source: JSON.Object; name: DebugMap.Name;
		BEGIN
			item := JSON.NewObject();
			item.Set("id", JSON.NewNumber(i));
			item.Set("verified", JSON.NewBool(core.wishes[i].adr # 0));
			IF core.wishes[i].actual # 0 THEN item.Set("line", JSON.NewNumber(core.wishes[i].actual))
			ELSE item.Set("line", JSON.NewNumber(core.wishes[i].line))
			END;
			IF core.wishes[i].source # "" THEN
				source := JSON.NewObject();
				source.Set("path", JSON.NewString(core.wishes[i].source));
				DebugMap.BaseName(core.wishes[i].source, name);
				source.Set("name", JSON.NewString(name));
				item.Set("source", source)
			END;
			RETURN item
		END Verdict;

		(**	Loaded is the Ready the launcher calls: the program's module is in, and it has not
			started, so this is the one moment the lines asked for before there was any code can be
			answered. The client hears about each of them, because it asked before we could know. *)
		PROCEDURE Loaded;
		VAR i: SIGNED32; body: JSON.Object;
		BEGIN
			core.Arm;
			FOR i := 0 TO core.wishCount - 1 DO
				body := JSON.NewObject();
				body.Set("reason", JSON.NewString("changed"));
				body.Set("breakpoint", Verdict(i));
				Event("breakpoint", body)
			END
		END Loaded;

		(* The program has ended, one way or the other. *)
		PROCEDURE Finish (ok: BOOLEAN; CONST message: ARRAY OF CHAR);
		VAR body: JSON.Object;
		BEGIN
			IF ended THEN RETURN END;
			ended := TRUE;
			Dump;
			IF ~ok & (message # "") THEN
				body := JSON.NewObject();
				body.Set("category", JSON.NewString("stderr"));
				body.Set("output", JSON.NewString(message));
				Event("output", body)
			END;
			body := JSON.NewObject();
			IF ok THEN body.Set("exitCode", JSON.NewNumber(0)) ELSE body.Set("exitCode", JSON.NewNumber(1)) END;
			Event("exited", body);
			Event("terminated", NIL)
		END Finish;

		(*	The trap dump, which A2 writes to the trace channel -- this process's stdout, where the
			protocol is. It is captured instead (CaptureChar below) and handed to the editor as
			console output, which is where a person reads it anyway. *)
		PROCEDURE Dump;
		VAR body: JSON.Object; text: POINTER TO ARRAY OF CHAR; i: SIZE;
		BEGIN
			IF tracedLength = 0 THEN RETURN END;
			NEW(text, tracedLength + 1);
			FOR i := 0 TO tracedLength - 1 DO text[i] := traced[i] END;
			text[tracedLength] := 0X; tracedLength := 0;
			body := JSON.NewObject();
			body.Set("category", JSON.NewString("stderr"));
			body.Set("output", JSON.NewString(text^));
			Event("output", body)
		END Dump;

		(*	The program's own output. It cannot go to stdout -- that is the protocol channel -- so
			it is forwarded as the events an editor shows in its debug console. *)
		PROCEDURE Write (CONST buffer: ARRAY OF CHAR; offset, length: SIZE; propagate: BOOLEAN;
				VAR result: INTEGER);
		VAR body: JSON.Object; text: POINTER TO ARRAY OF CHAR; i: SIZE;
		BEGIN
			IF length > 0 THEN
				NEW(text, length + 1);
				FOR i := 0 TO length - 1 DO text[i] := buffer[offset + i] END;
				text[length] := 0X;
				body := JSON.NewObject();
				body.Set("category", JSON.NewString("stdout"));
				body.Set("output", JSON.NewString(text^));
				Event("output", body)
			END;
			result := Streams.Ok
		END Write;

		PROCEDURE Frames (): JSON.Value;
		VAR arr: JSON.Array; frame, source: JSON.Object; i: SIGNED32; body: JSON.Object;
			name, base: Name; file: DebugMap.Name; line: SIGNED32; position: SIGNED64; start: ADDRESS;
		BEGIN
			arr := JSON.NewArray();
			i := 0;
			WHILE i < core.count DO
				Reflection.GetProcedureName(core.frames[i].pc, name, start);
				IF name = "" THEN name := "unknown" END;
				(*	Below the program's own frames is the machinery that started it -- the command
					runner, this module, the scheduler. An editor shows a call stack, not ours. *)
				IF (name = "Commands.Runner.@Body") OR (name = "DAP.Debuggee.@Body") THEN
					i := core.count
				ELSE
					frame := JSON.NewObject();
					frame.Set("id", JSON.NewNumber(i));
					frame.Set("name", JSON.NewString(name));
					frame.Set("column", JSON.NewNumber(1));
					IF DebugMap.PositionOf(core.frames[i].pc, file, line, position) THEN
						frame.Set("line", JSON.NewNumber(line));
						source := JSON.NewObject();
						source.Set("path", JSON.NewString(file));
						DebugMap.BaseName(file, base);
						source.Set("name", JSON.NewString(base));
						frame.Set("source", source)
					ELSE
						frame.Set("line", JSON.NewNumber(0))   (* compiled without --debug, or not by us *)
					END;
					arr.Add(frame);
					INC(i)
				END
			END;
			body := JSON.NewObject();
			body.Set("stackFrames", arr);
			body.Set("totalFrames", JSON.NewNumber(arr.length));
			RETURN body
		END Frames;

		(*	The variables of one frame: the parameters, then the locals, exactly where
			Reflection.WriteProc0 finds them in the references section. *)
		PROCEDURE Variables (frame: SIGNED32; arr: JSON.Array);
		VAR module: Modules.Module; refs: Modules.Bytes; offset, refpos: SIZE;
			pc, fp, ignore: ADDRESS;
		BEGIN
			IF ~core.stopped OR (frame < 0) OR (frame >= core.count) THEN RETURN END;
			pc := core.frames[frame].pc; fp := core.frames[frame].fp;
			module := Modules.ThisModuleByAdr0(pc);
			IF module = NIL THEN RETURN END;
			refs := module.refs;
			refpos := Reflection.FindByAdr(refs, 0, pc);
			IF refpos < 0 THEN RETURN END;
			offset := refpos;
			IF Reflection.GetChar(refs, offset) # Reflection.sfProcedure THEN RETURN END;
			Reflection.SkipSize(offset); Reflection.SkipString(refs, offset);
			ignore := Reflection.GetAddress(refs, offset);   (* start *)
			ignore := Reflection.GetAddress(refs, offset);   (* end *)
			Reflection.SkipSet(offset);
			Each(arr, refs, offset, fp);                     (* parameters *)
			Reflection.SkipType(refs, offset);               (* the return type *)
			IF Reflection.GetChar(refs, offset) = Reflection.sfScopeBegin THEN
				Each(arr, refs, offset, fp)                  (* locals *)
			END
		END Variables;

		(*	ponytail: one variable is formatted by Reflection and then split at its "=", because
			Reflection writes "name= value" and nothing in it hands the two over separately. The
			day a client wants structured values (a record opened up, a pointer followed), that
			is a walk of the type stream here rather than a parse of this line. *)
		PROCEDURE Each (arr: JSON.Array; refs: Modules.Bytes; VAR offset: SIZE; base: ADDRESS);
		VAR buffer: Streams.Buffer; writer: Streams.Writer; text: Strings.String;
			item: JSON.Object; name, value: Name;
		BEGIN
			WHILE (refs[offset] = Reflection.sfVariable) & (arr.length < MaxFrames * 16) DO
				NEW(buffer, MaxValue); writer := buffer.GetWriter();
				Reflection.WriteVariable(writer, refs, offset, base, core.low, core.high);
				writer.Update; text := buffer.GetString();
				Split(text^, name, value);
				item := JSON.NewObject();
				item.Set("name", JSON.NewString(name));
				item.Set("value", JSON.NewString(value));
				item.Set("variablesReference", JSON.NewNumber(0));
				arr.Add(item)
			END
		END Each;

		(* The value of a name in a frame, for the editor's hover and watch window. *)
		PROCEDURE Evaluate (frame: SIGNED32; CONST wanted: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
		VAR arr: JSON.Array; item: JSON.Object; i: SIZE; name, found: Strings.String;
		BEGIN
			arr := JSON.NewArray();
			Variables(frame, arr);
			FOR i := 0 TO arr.length - 1 DO
				item := JSON.AsObject(arr.At(i));
				IF JSON.GetString(item, "name", name) & (name^ = wanted)
						& JSON.GetString(item, "value", found) THEN
					COPY(found^, value); RETURN TRUE
				END
			END;
			RETURN FALSE
		END Evaluate;

		(* The whole conversation, until the client disconnects or the input ends. *)
		PROCEDURE Serve (in: Streams.Reader);
		VAR msg: JSON.Value; request, arguments, body: JSON.Object; command: Strings.String;
			alive: BOOLEAN; arr: JSON.Array; thread: JSON.Object; frame: SIGNED32;
			reference: SIGNED32; expression: Strings.String; value: Name; message: Name;
		BEGIN
			LOOP
				msg := JSON.ReadFrame(in, alive);
				IF (msg = NIL) & ~alive THEN EXIT END;
				request := JSON.AsObject(msg);
				IF (request # NIL) & JSON.GetString(request, "command", command) THEN
					arguments := JSON.AsObject(request.Get("arguments"));
					IF command^ = "initialize" THEN
						body := JSON.NewObject();
						body.Set("supportsConfigurationDoneRequest", JSON.NewBool(TRUE));
						body.Set("supportsBreakpointLocationsRequest", JSON.NewBool(FALSE));
						body.Set("supportsEvaluateForHovers", JSON.NewBool(TRUE));
						body.Set("supportsTerminateRequest", JSON.NewBool(TRUE));
						Reply(request, body, "");
						Event("initialized", NIL)
					ELSIF (command^ = "launch") OR (command^ = "attach") THEN
						program := ""; procedure := "Do";
						IF JSON.GetText(arguments, "program", program) THEN END;
						IF JSON.GetText(arguments, "procedure", procedure) THEN END;
						IF program = "" THEN
							Reply(request, NIL, "launch needs a program: the source file to debug")
						ELSE
							Reply(request, NIL, "");
							Start(SELF)
						END
					ELSIF command^ = "configurationDone" THEN
						Reply(request, NIL, "")
					ELSIF command^ = "threads" THEN
						thread := JSON.NewObject();
						thread.Set("id", JSON.NewNumber(1));
						thread.Set("name", JSON.NewString("program"));
						arr := JSON.NewArray(); arr.Add(thread);
						body := JSON.NewObject(); body.Set("threads", arr);
						Reply(request, body, "")
					ELSIF command^ = "stackTrace" THEN
						Reply(request, Frames(), "")
					ELSIF command^ = "scopes" THEN
						frame := 0;
						IF JSON.GetInteger(arguments, "frameId", frame) THEN END;
						body := JSON.NewObject();
						body.Set("name", JSON.NewString("Locals"));
						body.Set("variablesReference", JSON.NewNumber(LocalsBase + frame));
						body.Set("expensive", JSON.NewBool(FALSE));
						arr := JSON.NewArray(); arr.Add(body);
						body := JSON.NewObject(); body.Set("scopes", arr);
						Reply(request, body, "")
					ELSIF command^ = "variables" THEN
						reference := 0;
						IF JSON.GetInteger(arguments, "variablesReference", reference) THEN END;
						arr := JSON.NewArray();
						Variables(reference - LocalsBase, arr);
						body := JSON.NewObject(); body.Set("variables", arr);
						Reply(request, body, "")
					ELSIF command^ = "evaluate" THEN
						frame := 0;
						IF JSON.GetInteger(arguments, "frameId", frame) THEN END;
						IF JSON.GetString(arguments, "expression", expression)
								& Evaluate(frame, expression^, value) THEN
							body := JSON.NewObject();
							body.Set("result", JSON.NewString(value));
							body.Set("variablesReference", JSON.NewNumber(0));
							Reply(request, body, "")
						ELSE
							Reply(request, NIL, "not a variable of this frame")
						END
					ELSIF command^ = "setBreakpoints" THEN
						Wanted(arguments);
						IF core.armed THEN core.Arm END;   (* the code is already in: patch it again *)
						arr := JSON.NewArray();
						FOR frame := 0 TO core.wishCount - 1 DO arr.Add(Verdict(frame)) END;
						body := JSON.NewObject(); body.Set("breakpoints", arr);
						Reply(request, body, "")
					ELSIF command^ = "continue" THEN
						core.Resume(FALSE, FALSE);
						body := JSON.NewObject();
						body.Set("allThreadsContinued", JSON.NewBool(TRUE));
						Reply(request, body, "")
					ELSIF (command^ = "next") OR (command^ = "stepIn") THEN
						(* stepIn is next: where a call goes is in the instruction, not in the map *)
						core.Resume(TRUE, FALSE);
						Reply(request, NIL, "")
					ELSIF command^ = "stepOut" THEN
						core.Resume(TRUE, TRUE);
						Reply(request, NIL, "")
					ELSIF (command^ = "disconnect") OR (command^ = "terminate") THEN
						core.Detach;
						core.Release;
						Reply(request, NIL, "");
						EXIT
					ELSE
						Reply(request, NIL, "")   (* unknown: answered, so no client hangs on it *)
					END
				END
			END;
			core.Detach;
			core.Release;
			message := ""
		END Serve;

	END Session;

	(*	The program under debug runs on an activity of its own: the one that traps is held in the
		trap handler, and the server has to stay free to answer the editor asking about it. *)
	Debuggee = OBJECT
	VAR session: Session; started: BOOLEAN;

		PROCEDURE &Init* (s: Session);
		BEGIN session := s; started := FALSE
		END Init;

	(*	{SAFE} the way Commands.Runner is: a trap re-enters the body, and this is where the editor
		is told that the program is gone -- otherwise a program that trapped outside a command
		would leave the session waiting for an end that never comes. *)
	BEGIN {ACTIVE, SAFE}
		IF ~started THEN
			started := TRUE;
			Run(session)
		ELSE
			session.Finish(FALSE, "the program trapped")
		END
	END Debuggee;

PROCEDURE Run (session: Session);
VAR message: Name; ok: BOOLEAN; out: Streams.Writer;
BEGIN
	message := "";
	NEW(out, session.Write, 256);
	ok := session.launch(session.program, session.procedure, out, session.Loaded, message);
	out.Update;
	session.Finish(ok, message)
END Run;

PROCEDURE Start (session: Session);
VAR debuggee: Debuggee;
BEGIN
	NEW(debuggee, session)
END Start;

(*	One instruction the processor traps on, in place of the program's own: INT 3 on the Intel
	machines, one byte, where the trap reports the address after it; BRK on A64, a word, where it
	reports the instruction itself and the caches have to be told -- writing code and then running
	it is what Modules.Mod flushes for after it copies a section in. *)
(*	A module's code is read and execute once it is initialised (Modules.Initialize), so the two
	places that write an instruction into it have to take the protection off first and put it back
	after. The rounding is outward here, unlike Machine.ProtectCode: what has to be writable is the
	page the instruction sits on, all of it, and an instruction can straddle two. Machine rounds
	inward, so the pages are named exactly and it changes nothing.

	The window is one instruction wide and another thread can be executing on the same page while it
	is open. That is the price of patching code in place, and it is the same price every debugger
	that plants a trap instruction pays. *)
PROCEDURE Around (adr: ADDRESS; len: SIZE; VAR from: ADDRESS; VAR size: SIZE);
VAR to: ADDRESS;
BEGIN
	from := adr - adr MOD Machine.PageSize;
	to := adr + len; INC(to, (-to) MOD Machine.PageSize);
	size := to - from
END Around;

PROCEDURE Writable (adr: ADDRESS; len: SIZE);
VAR from: ADDRESS; size: SIZE;
BEGIN Around(adr, len, from, size); Machine.UnprotectCode(from, size)
END Writable;

PROCEDURE Executable (adr: ADDRESS; len: SIZE);
VAR from: ADDRESS; size: SIZE;
BEGIN Around(adr, len, from, size); Machine.ProtectCode(from, size)
END Executable;

PROCEDURE Plant (adr: ADDRESS; VAR saved: SIGNED32);
#IF ARM64 THEN
BEGIN
	saved := SYSTEM.GET32(adr);
	Writable(adr, 4);
	SYSTEM.PUT32(adr, SIGNED32(0D4200000H));                  (* BRK #0 *)
	Executable(adr, 4);
	Machine.FlushDCacheRange(adr, 4)
#ELSE
VAR byte: CHAR;
BEGIN
	SYSTEM.GET(adr, byte); saved := ORD(byte);
	Writable(adr, 1);
	SYSTEM.PUT(adr, 0CCX);                                     (* INT 3 *)
	Executable(adr, 1)
#END
END Plant;

PROCEDURE Restore (adr: ADDRESS; saved: SIGNED32);
#IF ARM64 THEN
BEGIN
	Writable(adr, 4);
	SYSTEM.PUT32(adr, saved);
	Executable(adr, 4);
	Machine.FlushDCacheRange(adr, 4)
#ELSE
BEGIN
	Writable(adr, 1);
	SYSTEM.PUT(adr, CHR(saved));
	Executable(adr, 1)
#END
END Restore;

(* Where the planted instruction is, given the pc the trap reported. *)
PROCEDURE Hit (pc: ADDRESS): ADDRESS;
#IF ARM64 THEN
BEGIN
	RETURN pc
#ELSE
BEGIN
	RETURN pc - 1
#END
END Hit;

(*	Runs where a trap handler runs, so it allocates nothing and locks nothing: a fixed array and
	an index (sdk/Ob.Mod does the same for the documentation backend). What does not fit is
	dropped, which is what the twentieth page of a trap is worth. *)
PROCEDURE CaptureChar (character: CHAR);
BEGIN {UNCOOPERATIVE, UNCHECKED}
	IF tracedLength < LEN(traced) THEN traced[tracedLength] := character; INC(tracedLength) END
END CaptureChar;

(* How the trap handler spells what happened, in the words Traps uses. *)
PROCEDURE Cause (sig, trapno: SIGNED32; VAR text: ARRAY OF CHAR);
BEGIN
	text := "Trap ";
	Strings.AppendInt(text, sig);
	IF sig = 5 THEN
		Strings.AppendChar(text, ".");
		Strings.AppendInt(text, trapno);
		CASE trapno OF
		| 1: Strings.Append(text, " (WITH guard failed)")
		| 2: Strings.Append(text, " (CASE invalid)")
		| 3: Strings.Append(text, " (RETURN missing)")
		| 5: Strings.Append(text, " (implicit type guard failed)")
		| 6: Strings.Append(text, " (type guard failed)")
		| 7: Strings.Append(text, " (index out of range)")
		| 8: Strings.Append(text, " (ASSERT failed)")
		| 9: Strings.Append(text, " (array dimension error)")
		| 12: Strings.Append(text, " (division error)")
		ELSE
			IF trapno >= 30 THEN Strings.Append(text, " (programmed HALT)")
			ELSE Strings.Append(text, " (unknown exception)") END
		END
	ELSIF sig = 4 THEN Strings.Append(text, " (illegal instruction)")
	ELSIF sig = 11 THEN Strings.Append(text, " (NIL access)")
	END
END Cause;

(* "  name= [@-8] 42" -- what Reflection.WriteVariable writes -- as a name and a value. *)
PROCEDURE Split (CONST line: ARRAY OF CHAR; VAR name, value: ARRAY OF CHAR);
VAR i, j, k: SIZE;
BEGIN
	i := 0;
	WHILE (line[i] = " ") OR (line[i] = 09X) DO INC(i) END;
	j := 0;
	WHILE (line[i] # 0X) & (line[i] # "=") & (j < LEN(name) - 1) DO
		name[j] := line[i]; INC(i); INC(j)
	END;
	name[j] := 0X;
	IF line[i] = "=" THEN INC(i) END;
	WHILE (line[i] = " ") OR (line[i] = 09X) DO INC(i) END;
	IF (line[i] = "[") & (line[i + 1] = "@") THEN     (* where the variable sits: not what was asked *)
		WHILE (line[i] # 0X) & (line[i] # "]") DO INC(i) END;
		IF line[i] = "]" THEN INC(i) END;
		WHILE (line[i] = " ") OR (line[i] = 09X) DO INC(i) END
	END;
	k := 0;
	WHILE (line[i] # 0X) & (line[i] # 0DX) & (line[i] # 0AX) & (k < LEN(value) - 1) DO
		value[k] := line[i]; INC(i); INC(k)
	END;
	WHILE (k > 0) & (value[k - 1] = " ") DO DEC(k) END;
	value[k] := 0X
END Split;

(**	Report writes where the program stands, as text: one line per frame of the program with the
	file and line it is in, and under the innermost one the parameters and locals it holds. A
	driver with no protocol -- PET -- needs exactly this and none of the JSON.

	It stops at the first frame the line table knows nothing about, and that is not a
	shortcoming: below the program's own frames is the machinery that started it
	(Commands.Runner, Objects.BodyStarter), which was not compiled with --debug and has no
	business in a report about the program. Reflection.StackTraceBack, which a trap dump is
	made of, prints all of it and by byte offset rather than by line -- right for a post-mortem
	on the console, wrong for an editor that has just put the caret on the line. *)
PROCEDURE Report* (core: Core; w: Streams.Writer);
VAR i: SIGNED32; procedure, file: Name; line: SIGNED32; position: SIGNED64;
	start, base: ADDRESS; module: Modules.Module; refs: Modules.Bytes; offset, refpos: SIZE;
BEGIN
	FOR i := 0 TO core.count - 1 DO
		IF ~DebugMap.PositionOf(core.frames[i].pc, file, line, position) THEN RETURN END;
		Reflection.GetProcedureName(core.frames[i].pc, procedure, start);
		DebugMap.BaseName(file, file);
		w.String("  "); w.String(procedure);
		w.String("  "); w.String(file); w.Char(":"); w.Int(line, 0); w.Ln;
		IF i = 0 THEN
			(*	The frame being stood in, read the way Session.Variables reads it -- the
				difference is only that Reflection writes the lot in one call here, because
				text is what is wanted and not a value per JSON object. *)
			module := Modules.ThisModuleByAdr0(core.frames[i].pc);
			IF module = NIL THEN RETURN END;
			refs := module.refs;
			refpos := Reflection.FindByAdr(refs, 0, core.frames[i].pc);
			IF refpos < 0 THEN RETURN END;
			offset := refpos;
			IF Reflection.GetChar(refs, offset) # Reflection.sfProcedure THEN RETURN END;
			Reflection.SkipSize(offset); Reflection.SkipString(refs, offset);
			base := Reflection.GetAddress(refs, offset);   (* start *)
			base := Reflection.GetAddress(refs, offset);   (* end *)
			Reflection.SkipSet(offset);
			Reflection.WriteVariables(w, refs, offset, core.frames[i].fp, core.low, core.high);
			Reflection.SkipType(refs, offset);             (* the return type *)
			IF Reflection.GetChar(refs, offset) = Reflection.sfScopeBegin THEN
				Reflection.WriteVariables(w, refs, offset, core.frames[i].fp, core.low, core.high)
			END
		END
	END
END Report;

(**	Serve one debug session over a context, which is how `ob dap` and the tests both drive it:
	the requests come in on its input, the responses and events go out on its output. *)
PROCEDURE Serve* (context: Commands.Context; launcher: Launcher);
VAR session: Session; previous: Trace.CharProc;
BEGIN
	NEW(session, context.out, launcher);
	tracedLength := 0; previous := Trace.Char; Trace.Char := CaptureChar;
	Traps.Trapped := session.core.Trapped;
	Traps.Breakpoint := session.core.Break;
	session.Serve(context.in);
	Traps.Breakpoint := NIL;
	Traps.Trapped := NIL;
	Trace.Char := previous
END Serve;

END DAP.
