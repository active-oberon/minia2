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

	ponytail: no breakpoints, no stepping, one thread. A breakpoint is 0CCX written into the code
	and the same handshake as here, which is worth doing the day this is not enough. Reading a
	program that has already crashed is what an editor cannot do at all today. *)

IMPORT Commands, Streams, Strings, Trace, JSON, Modules, Reflection, DebugMap, Traps, SYSTEM;

CONST
	TraceCapacity = 32 * 1024;   (* one trap dump, which is what the editor is shown of it *)
	MaxFrames = 64;
	LocalsBase = 1000;   (* variablesReference of frame i is LocalsBase + i, so it is never 0 *)
	MaxValue = 1024;

TYPE
	Name* = ARRAY 256 OF CHAR;

	(**	Launcher compiles the program and runs it, returning when it has ended. `ob dap` passes the
		one that knows about search paths and --debug; a test passes its own. Whatever the program
		writes goes to `out`, never to this process's stdout, which carries the protocol. *)
	Launcher* = PROCEDURE {DELEGATE} (CONST program, procedure: ARRAY OF CHAR; out: Streams.Writer;
		VAR message: ARRAY OF CHAR): BOOLEAN;

	Frame = RECORD pc, fp: ADDRESS END;

VAR
	traced: ARRAY TraceCapacity OF CHAR;
	tracedLength: SIZE;

TYPE
	Session = OBJECT
	VAR
		out: Streams.Writer;
		launch: Launcher;
		seq: SIGNED32;
		frames: ARRAY MaxFrames OF Frame;
		count: SIGNED32;
		low, high: ADDRESS;             (* the stack the frames live on, for reading variables *)
		reason: Name;
		stopped-, released, ended: BOOLEAN;
		program, procedure: Name;

		PROCEDURE &Init* (writer: Streams.Writer; launcher: Launcher);
		BEGIN
			out := writer; launch := launcher; seq := 0; count := 0; stopped := FALSE;
			released := FALSE; ended := FALSE
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

		(*	Traps.Trapped, on the activity that is about to die. It walks the frames the way
			Reflection.StackTraceBack does -- return address and dynamic link, one word apart --
			tells the editor, and then stands still until the editor is done with it. *)
		PROCEDURE Trapped (sig, trapno: SIGNED32; pc, bp, sp, stackHigh: ADDRESS);
		VAR body: JSON.Object;
		BEGIN
			IF stopped THEN RETURN END;         (* a second trap has nowhere to be reported *)
			low := sp; high := stackHigh;
			count := 0;
			WHILE (count < MaxFrames) & (bp # 0) & (bp >= low) & (bp <= high)
					& (bp MOD SIZEOF(ADDRESS) = 0) DO
				frames[count].pc := pc; frames[count].fp := bp; INC(count);
				SYSTEM.GET(bp + SIZEOF(ADDRESS), pc);   (* return address *)
				SYSTEM.GET(bp, bp)                      (* dynamic link *)
			END;
			Cause(sig, trapno, reason);
			stopped := TRUE;
			Dump;                               (* what the trap printed, before it is said to have stopped *)
			body := JSON.NewObject();
			body.Set("reason", JSON.NewString("exception"));
			body.Set("description", JSON.NewString(reason));
			body.Set("text", JSON.NewString(reason));
			body.Set("threadId", JSON.NewNumber(1));
			body.Set("allThreadsStopped", JSON.NewBool(TRUE));
			Event("stopped", body);
			Hold
		END Trapped;

		(* The trapped activity waits here, so that its stack stays readable. *)
		PROCEDURE Hold;
		BEGIN {EXCLUSIVE}
			AWAIT(released)
		END Hold;

		PROCEDURE Release;
		BEGIN {EXCLUSIVE}
			released := TRUE; stopped := FALSE
		END Release;

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
			WHILE i < count DO
				Reflection.GetProcedureName(frames[i].pc, name, start);
				IF name = "" THEN name := "unknown" END;
				(*	Below the program's own frames is the machinery that started it -- the command
					runner, this module, the scheduler. An editor shows a call stack, not ours. *)
				IF (name = "Commands.Runner.@Body") OR (name = "DAP.Debuggee.@Body") THEN
					i := count
				ELSE
					frame := JSON.NewObject();
					frame.Set("id", JSON.NewNumber(i));
					frame.Set("name", JSON.NewString(name));
					frame.Set("column", JSON.NewNumber(1));
					IF DebugMap.PositionOf(frames[i].pc, file, line, position) THEN
						frame.Set("line", JSON.NewNumber(line));
						source := JSON.NewObject();
						source.Set("path", JSON.NewString(file));
						BaseName(file, base);
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
			IF ~stopped OR (frame < 0) OR (frame >= count) THEN RETURN END;
			pc := frames[frame].pc; fp := frames[frame].fp;
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
				Reflection.WriteVariable(writer, refs, offset, base, low, high);
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
					ELSIF (command^ = "continue") OR (command^ = "next") OR (command^ = "stepIn")
							OR (command^ = "stepOut") THEN
						(*	There is nowhere to continue to: the program trapped, and stepping is
							the next thing to build. Letting it go is all that is left. *)
						Release;
						body := JSON.NewObject();
						body.Set("allThreadsContinued", JSON.NewBool(TRUE));
						Reply(request, body, "")
					ELSIF (command^ = "disconnect") OR (command^ = "terminate") THEN
						Release;
						Reply(request, NIL, "");
						EXIT
					ELSE
						Reply(request, NIL, "")   (* unknown: answered, so no client hangs on it *)
					END
				END
			END;
			Release;
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
	ok := session.launch(session.program, session.procedure, out, message);
	out.Update;
	session.Finish(ok, message)
END Run;

PROCEDURE Start (session: Session);
VAR debuggee: Debuggee;
BEGIN
	NEW(debuggee, session)
END Start;

(* The file a path ends in, which is the name an editor puts on a tab. *)
PROCEDURE BaseName (CONST path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, start: SIZE;
BEGIN
	i := 0; start := 0;
	WHILE path[i] # 0X DO
		IF (path[i] = "/") OR (path[i] = 5CX) THEN start := i + 1 END;
		INC(i)
	END;
	i := 0;
	WHILE (path[start + i] # 0X) & (i < LEN(name) - 1) DO name[i] := path[start + i]; INC(i) END;
	name[i] := 0X
END BaseName;

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

(**	Serve one debug session over a context, which is how `ob dap` and the tests both drive it:
	the requests come in on its input, the responses and events go out on its output. *)
PROCEDURE Serve* (context: Commands.Context; launcher: Launcher);
VAR session: Session; previous: Trace.CharProc;
BEGIN
	NEW(session, context.out, launcher);
	tracedLength := 0; previous := Trace.Char; Trace.Char := CaptureChar;
	Traps.Trapped := session.Trapped;
	session.Serve(context.in);
	Traps.Trapped := NIL;
	Trace.Char := previous
END Serve;

END DAP.
