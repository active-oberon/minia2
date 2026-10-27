MODULE ObDebug; (** AUTHOR "Andrii Puhachenko"; PURPOSE "Windows debug adapter with an independent target process"; *)

(* Only Publish runs in the child, before its entry procedure. The parent owns every breakpoint,
	reads memory through ReadProcessMemory and holds Windows debug events instead of entering
	the child's exception handler. CreateProcess, WaitForDebugEvent and ContinueDebugEvent all
	run on the same activity. The input activity only queues immutable DAP requests. *)
IMPORT SYSTEM, Kernel32, Kernel, Commands, Streams, Strings, Files, JSON, Modules, Reflection,
	DebugMap, ObHost;

CONST
	MaxSpots = 512; MaxThreads = 256; MaxFrames = 64;
	Continue = 00010002H; NotHandled = SIGNED32(080010001H);
	ReadyMarker = "miniA2:debug-ready:v1";
TYPE
	Path = ObHost.Path;
	DebugEvent = RECORD
		kind, pid, tid, padding: SIGNED32;
		data: ARRAY 160 OF CHAR             (* Win64 DEBUG_EVENT union, aligned to 8 bytes *)
	END;
	Link = POINTER TO RECORD next: Link; value: JSON.Object END;
	Inbox = OBJECT
	VAR head, tail: Link; closed, ended: BOOLEAN;
		PROCEDURE Put(value: JSON.Object);
		VAR item: Link;
		BEGIN {EXCLUSIVE}
			NEW(item); item.value := value;
			IF tail = NIL THEN head := item ELSE tail.next := item END; tail := item
		END Put;
		PROCEDURE Take(): JSON.Object;
		VAR item: Link;
		BEGIN {EXCLUSIVE}
			item := head; IF item = NIL THEN RETURN NIL END;
			head := item.next; IF head = NIL THEN tail := NIL END; RETURN item.value
		END Take;
		PROCEDURE Close;
		BEGIN {EXCLUSIVE} closed := TRUE END Close;
		PROCEDURE Closed(): BOOLEAN;
		BEGIN {EXCLUSIVE} RETURN closed END Closed;
		PROCEDURE Finish;
		BEGIN {EXCLUSIVE} ended := TRUE END Finish;
		PROCEDURE Wait;
		BEGIN {EXCLUSIVE} AWAIT(ended) END Wait;
	END Inbox;
	Spot = RECORD adr: ADDRESS; saved: CHAR; armed, wanted: BOOLEAN END;
	Wish = RECORD source: Path; line, actual: SIGNED32; adr: ADDRESS END;
	Frame = RECORD pc, fp: ADDRESS; symbol: JSON.Object END;
VAR
	waitEvent: PROCEDURE {WINAPI}(VAR event: DebugEvent; timeout: SIGNED32): Kernel32.BOOL;
	continueEvent: PROCEDURE {WINAPI}(pid, tid, status: SIGNED32): Kernel32.BOOL;
	readMemory, writeMemory: PROCEDURE {WINAPI}(process, adr, buffer: ADDRESS; size: SIZE;
		VAR transferred: SIZE): Kernel32.BOOL;
	protectMemory: PROCEDURE {WINAPI}(process, adr: ADDRESS; size: SIZE; protection: SIGNED32;
		VAR old: SIGNED32): Kernel32.BOOL;
	flushCode: PROCEDURE {WINAPI}(process, adr: ADDRESS; size: SIZE): Kernel32.BOOL;
	getContext, setContext: PROCEDURE {WINAPI}(thread, context: ADDRESS): Kernel32.BOOL;
	breakProcess: PROCEDURE {WINAPI}(process: ADDRESS): Kernel32.BOOL;
	available: BOOLEAN;

PROCEDURE Number(obj: JSON.Object; CONST key: ARRAY OF CHAR; value: SIGNED64);
BEGIN obj.Set(key, JSON.NewNumber(value)) END Number;

PROCEDURE Integer(obj: JSON.Object; CONST key: ARRAY OF CHAR): SIGNED64;
VAR value: JSON.Value;
BEGIN
	IF obj = NIL THEN RETURN 0 END;
	value := obj.Get(key);
	IF (value # NIL) & (value IS JSON.Number) THEN RETURN ENTIER(value(JSON.Number).value) END;
	RETURN 0
END Integer;

PROCEDURE Text(obj: JSON.Object; CONST key: ARRAY OF CHAR; VAR value: ARRAY OF CHAR);
BEGIN value := ""; IF JSON.GetText(obj, key, value) THEN END END Text;

(* Save location and type descriptors, never variable values. The external reader applies these
	descriptors to the stopped target's frame, including indirect VAR parameters. *)
PROCEDURE Variables(refs: Modules.Bytes; VAR offset: SIZE; list: JSON.Array);
VAR item: JSON.Object; name: ARRAY 256 OF CHAR; mode, type: CHAR; where: ADDRESS; at, depth: SIZE;
BEGIN
	WHILE (offset >= 0) & (offset < LEN(refs)) & (refs[offset] = Reflection.sfVariable) DO
		Reflection.SkipChar(offset); Reflection.SkipSize(offset); Reflection.GetString(refs, offset, name);
		mode := Reflection.GetChar(refs, offset); where := Reflection.GetAddress(refs, offset);
		at := offset; depth := 0; type := Reflection.GetChar(refs, at);
		WHILE (type = Reflection.sfTypeIndirect) & (depth < 16) DO
			at := Reflection.GetSize(refs, at); type := Reflection.GetChar(refs, at); INC(depth)
		END;
		item := JSON.NewObject(); item.Set("name", JSON.NewString(name));
		Number(item, "mode", ORD(mode)); Number(item, "offset", where); Number(item, "type", ORD(type));
		list.Add(item); Reflection.SkipType(refs, offset)
	END
END Variables;

(** Publish a versioned snapshot of the exact modules loaded in this process. OutputDebugString
	provides an OS debug event: all child threads are stopped while the parent reads the file. *)
PROCEDURE Publish*(CONST path: ARRAY OF CHAR): BOOLEAN;
VAR root, item, site: JSON.Object; list, sites, locals: JSON.Array; p: DebugMap.Procedure;
	m: Modules.Module; refs: Modules.Bytes; offset, i: SIZE; start, finish: ADDRESS;
	file: Files.File; writer: Files.Writer; head: ARRAY 256 OF CHAR;
BEGIN
	root := JSON.NewObject(); Number(root, "version", 1); Number(root, "pid", ObHost.ProcessId());
	list := JSON.NewArray(); p := DebugMap.First();
	WHILE p # NIL DO
		start := DebugMap.StartOf(p.name);
		m := Modules.ThisModuleByAdr0(start);
		IF (start # 0) & (m # NIL) THEN
			refs := m.refs; offset := Reflection.FindByAdr(refs, 0, start);
			IF (offset >= 0) & (Reflection.GetChar(refs, offset) = Reflection.sfProcedure) THEN
				Reflection.SkipSize(offset); Reflection.SkipString(refs, offset);
				start := Reflection.GetAddress(refs, offset); finish := Reflection.GetAddress(refs, offset);
				Reflection.SkipSet(offset); locals := JSON.NewArray(); Variables(refs, offset, locals);
				Reflection.SkipType(refs, offset);
				IF Reflection.GetChar(refs, offset) = Reflection.sfScopeBegin THEN Variables(refs, offset, locals) END;
				item := JSON.NewObject(); item.Set("name", JSON.NewString(p.name));
				item.Set("source", JSON.NewString(p.source)); Number(item, "start", start); Number(item, "end", finish);
				sites := JSON.NewArray();
				FOR i := 0 TO LEN(p.sites)-1 DO
					site := JSON.NewObject(); Number(site, "address", start + p.sites[i].offset);
					Number(site, "line", p.sites[i].line); sites.Add(site)
				END;
				item.Set("sites", sites); item.Set("variables", locals); list.Add(item)
			END
		END;
		p := p.next
	END;
	root.Set("procedures", list); file := Files.New(path); IF file = NIL THEN RETURN FALSE END;
	Files.OpenWriter(writer, file, 0); JSON.Write(writer, root); writer.Update; Files.Register(file); file.Close;
	COPY(ReadyMarker, head); Kernel32.OutputDebugString(head);
	RETURN TRUE
END Publish;

TYPE
	Session = OBJECT
	VAR
		inbox: Inbox; out: Streams.Writer; seq: SIGNED32; done, launched, configured: BOOLEAN;
		process, pipe: ADDRESS; pid: SIGNED32; symbolFile: Path; symbols: JSON.Array;
		event: DebugEvent; pending, stopped, ready, initialBreak, pauseAsked: BOOLEAN;
		status: SIGNED32;
		threadId: ARRAY MaxThreads OF SIGNED32; thread: ARRAY MaxThreads OF ADDRESS;
		frozen: ARRAY MaxThreads OF BOOLEAN;
		contextBuffer: ARRAY 1328 OF CHAR; context: ADDRESS;
		spots: ARRAY MaxSpots OF Spot; wishes: ARRAY MaxSpots OF Wish; wishCount: SIGNED32;
		frames: ARRAY MaxFrames OF Frame; frameCount: SIGNED32;
		rearm: SIGNED32; stepping: BOOLEAN;

		PROCEDURE &Init(queue: Inbox; writer: Streams.Writer);
		BEGIN
			inbox := queue; out := writer; rearm := -1;
			context := ADDRESSOF(contextBuffer[0]) + 15; DEC(context, context MOD 16)
		END Init;

		PROCEDURE Send(msg: JSON.Object);
		BEGIN INC(seq); Number(msg, "seq", seq); JSON.WriteFrame(out, msg) END Send;
		PROCEDURE Event(CONST name: ARRAY OF CHAR; body: JSON.Value);
		VAR msg: JSON.Object;
		BEGIN
			msg := JSON.NewObject(); msg.Set("type", JSON.NewString("event")); msg.Set("event", JSON.NewString(name));
			IF body # NIL THEN msg.Set("body", body) END; Send(msg)
		END Event;
		PROCEDURE Reply(request: JSON.Object; body: JSON.Value; CONST failure: ARRAY OF CHAR);
		VAR msg: JSON.Object; command: Path;
		BEGIN
			msg := JSON.NewObject(); msg.Set("type", JSON.NewString("response"));
			Number(msg, "request_seq", Integer(request, "seq")); Text(request, "command", command);
			msg.Set("command", JSON.NewString(command)); msg.Set("success", JSON.NewBool(failure = ""));
			IF failure # "" THEN msg.Set("message", JSON.NewString(failure)) END;
			IF body # NIL THEN msg.Set("body", body) END; Send(msg)
		END Reply;
		PROCEDURE Output(CONST category, text: ARRAY OF CHAR);
		VAR body: JSON.Object;
		BEGIN
			body := JSON.NewObject(); body.Set("category", JSON.NewString(category));
			body.Set("output", JSON.NewString(text)); Event("output", body)
		END Output;
		PROCEDURE Read(adr, buffer: ADDRESS; size: SIZE): BOOLEAN;
		VAR got: SIZE;
		BEGIN
			RETURN (adr > 0) & (size > 0) & (size <= 65536)
				& (readMemory(process, adr, buffer, size, got) # 0) & (got = size)
		END Read;
		PROCEDURE Patch(adr: ADDRESS; byte: CHAR): BOOLEAN;
		VAR old, ignored: SIGNED32; wrote: SIZE; ok: BOOLEAN;
		BEGIN
			IF protectMemory(process, adr, 1, 40H, old) = 0 THEN RETURN FALSE END;
			ok := (writeMemory(process, adr, ADDRESSOF(byte), 1, wrote) # 0) & (wrote = 1);
			IF protectMemory(process, adr, 1, old, ignored) = 0 THEN ok := FALSE END;
			IF flushCode(process, adr, 1) = 0 THEN ok := FALSE END;
			RETURN ok
		END Patch;
		PROCEDURE Thread(id: SIGNED32): ADDRESS;
		VAR i: SIGNED32;
		BEGIN
			FOR i := 0 TO MaxThreads-1 DO IF threadId[i] = id THEN RETURN thread[i] END END;
			RETURN 0
		END Thread;
		PROCEDURE Context(): BOOLEAN;
		BEGIN
			SYSTEM.PUT32(context + 48, 100003H);   (* CONTEXT_AMD64 | CONTROL | INTEGER *)
			RETURN getContext(Thread(event.tid), context) # 0
		END Context;
		PROCEDURE Symbol(pc: ADDRESS): JSON.Object;
		VAR i: SIZE; item: JSON.Object;
		BEGIN
			IF symbols = NIL THEN RETURN NIL END;
			FOR i := 0 TO symbols.length-1 DO
				item := JSON.AsObject(symbols.At(i));
				IF (pc >= Integer(item, "start")) & (pc < Integer(item, "end")) THEN RETURN item END
			END;
			RETURN NIL
		END Symbol;
		PROCEDURE Line(symbol: JSON.Object; pc: ADDRESS): SIGNED32;
		VAR sites: JSON.Array; i: SIZE; line: SIGNED32; site: JSON.Object;
		BEGIN
			IF symbol = NIL THEN RETURN 0 END;
			sites := JSON.GetArray(symbol, "sites"); line := 0;
			IF sites # NIL THEN
				FOR i := 0 TO sites.length-1 DO
					site := JSON.AsObject(sites.At(i));
					IF Integer(site, "address") <= pc THEN line := SHORT(Integer(site, "line")) END
				END
			END;
			RETURN line
		END Line;
		PROCEDURE Walk;
		VAR pc, fp, sp, next, ret: ADDRESS;
		BEGIN
			frameCount := 0;
			SYSTEM.GET(context + 248, pc); SYSTEM.GET(context + 160, fp); SYSTEM.GET(context + 152, sp);
			WHILE frameCount < MaxFrames DO
				frames[frameCount].pc := pc; frames[frameCount].fp := fp;
				frames[frameCount].symbol := Symbol(pc); INC(frameCount);
				IF (fp < sp) OR (fp > sp + 64*1024*1024) OR (fp MOD 8 # 0)
					OR ~Read(fp, ADDRESSOF(next), 8) OR ~Read(fp+8, ADDRESSOF(ret), 8) OR (next <= fp) THEN RETURN END;
				pc := ret - 1; fp := next
			END
		END Walk;
		PROCEDURE Stop(CONST reason, description: ARRAY OF CHAR);
		VAR body: JSON.Object; i: SIGNED32;
		BEGIN
			FOR i := 0 TO MaxSpots-1 DO
				IF (spots[i].adr # 0) & ~spots[i].wanted THEN
					IF spots[i].armed & ~Patch(spots[i].adr, spots[i].saved) THEN Output("stderr", "cannot remove step breakpoint") END;
					spots[i].adr := 0; spots[i].armed := FALSE
				END
			END;
			stopped := TRUE; Walk;
			body := JSON.NewObject(); body.Set("reason", JSON.NewString(reason));
			body.Set("description", JSON.NewString(description)); Number(body, "threadId", event.tid);
			body.Set("allThreadsStopped", JSON.NewBool(TRUE)); Event("stopped", body)
		END Stop;
		PROCEDURE SpotAt(adr: ADDRESS): SIGNED32;
		VAR i: SIGNED32;
		BEGIN
			FOR i := 0 TO MaxSpots-1 DO IF spots[i].adr = adr THEN RETURN i END END; RETURN -1
		END SpotAt;
		PROCEDURE Plant(adr: ADDRESS; wanted: BOOLEAN): BOOLEAN;
		VAR i: SIGNED32;
		BEGIN
			IF adr = 0 THEN RETURN FALSE END;
			i := SpotAt(adr);
			IF i >= 0 THEN IF wanted THEN spots[i].wanted := TRUE END; RETURN TRUE END;
			i := 0; WHILE (i < MaxSpots) & (spots[i].adr # 0) DO INC(i) END;
			IF (i = MaxSpots) OR ~Read(adr, ADDRESSOF(spots[i].saved), 1) THEN RETURN FALSE END;
			IF ~Patch(adr, 0CCX) THEN RETURN FALSE END;
			spots[i].adr := adr; spots[i].wanted := wanted; spots[i].armed := TRUE; RETURN TRUE
		END Plant;
		PROCEDURE Resolve(VAR wish: Wish);
		VAR i, j: SIZE; symbol, site: JSON.Object; sites: JSON.Array; source: Path; line: SIGNED32;
		BEGIN
			wish.adr := 0; wish.actual := 0; IF symbols = NIL THEN RETURN END;
			FOR i := 0 TO symbols.length-1 DO
				symbol := JSON.AsObject(symbols.At(i)); Text(symbol, "source", source);
				IF source = wish.source THEN
					sites := JSON.GetArray(symbol, "sites");
					FOR j := 0 TO sites.length-1 DO
						site := JSON.AsObject(sites.At(j)); line := SHORT(Integer(site, "line"));
						IF (line >= wish.line) & ((wish.adr = 0) OR (line < wish.actual)) THEN
							wish.adr := Integer(site, "address"); wish.actual := line
						END
					END
				END
			END
		END Resolve;
		PROCEDURE Verdict(i: SIGNED32): JSON.Object;
		VAR item: JSON.Object;
		BEGIN
			item := JSON.NewObject(); Number(item, "id", i+1);
			item.Set("verified", JSON.NewBool(wishes[i].adr # 0));
			IF wishes[i].actual # 0 THEN Number(item, "line", wishes[i].actual) ELSE Number(item, "line", wishes[i].line) END;
			RETURN item
		END Verdict;
		PROCEDURE Arm;
		VAR i: SIGNED32; body: JSON.Object;
		BEGIN
			FOR i := 0 TO wishCount-1 DO
				Resolve(wishes[i]);
				IF (wishes[i].adr # 0) & ~Plant(wishes[i].adr, TRUE) THEN wishes[i].adr := 0 END;
				body := JSON.NewObject(); body.Set("reason", JSON.NewString("changed"));
				body.Set("breakpoint", Verdict(i)); Event("breakpoint", body)
			END
		END Arm;
		PROCEDURE LoadSymbols(): BOOLEAN;
		VAR file: Files.File; reader: Files.Reader; value: JSON.Value; root: JSON.Object;
		BEGIN
			file := Files.Old(symbolFile); IF file = NIL THEN RETURN FALSE END;
			Files.OpenReader(reader, file, 0);
			IF ~JSON.ParseStream(reader, value) THEN file.Close; RETURN FALSE END;
			file.Close; root := JSON.AsObject(value);
			IF (Integer(root, "version") # 1) OR (Integer(root, "pid") # pid) THEN RETURN FALSE END;
			symbols := JSON.GetArray(root, "procedures"); RETURN symbols # NIL
		END LoadSymbols;
		PROCEDURE Proceed;
		BEGIN
			IF pending THEN
				IF continueEvent(event.pid, event.tid, status) = 0 THEN
					Output("stderr", "ContinueDebugEvent failed"); done := TRUE
				END;
				pending := FALSE; stopped := FALSE
			END
		END Proceed;
		PROCEDURE Thaw;
		VAR i, ignored: SIGNED32;
		BEGIN
			FOR i := 0 TO MaxThreads-1 DO
				IF frozen[i] THEN ignored := Kernel32.ResumeThread(thread[i]); frozen[i] := FALSE END
			END
		END Thaw;
		PROCEDURE Resume(CONST mode: ARRAY OF CHAR): BOOLEAN;
		VAR pc, ret: ADDRESS; symbol, site: JSON.Object; sites: JSON.Array; i: SIZE; ignored: SIGNED32; line: SIGNED32; added: BOOLEAN;
		BEGIN
			IF ~stopped OR ~pending THEN RETURN FALSE END;
			IF mode # "continue" THEN
				IF frameCount = 0 THEN RETURN FALSE END;
				pc := frames[0].pc; symbol := frames[0].symbol; line := Line(symbol, pc); added := FALSE;
				IF Read(frames[0].fp+8, ADDRESSOF(ret), 8) & (Symbol(ret) # NIL) THEN added := Plant(ret, FALSE) END;
				IF (mode = "next") & (symbol # NIL) THEN
					sites := JSON.GetArray(symbol, "sites");
					FOR i := 0 TO sites.length-1 DO
						site := JSON.AsObject(sites.At(i));
						IF Integer(site, "line") # line THEN
							IF Plant(Integer(site, "address"), FALSE) THEN added := TRUE END
						END
					END
				END;
				IF ~added THEN RETURN FALSE END
			END;
			IF rearm >= 0 THEN
				(* Only the thread stepping over the restored instruction may run until it is rearmed. *)
				FOR i := 0 TO MaxThreads-1 DO
					IF (thread[i] # 0) & (threadId[i] # event.tid) THEN
						ignored := Kernel32.SuspendThread(thread[i]); frozen[i] := ignored # -1
					END
				END;
				SYSTEM.PUT32(context + 68, SYSTEM.GET32(context + 68) + 100H);
				IF setContext(Thread(event.tid), context) = 0 THEN Thaw; RETURN FALSE END
			END;
			Proceed; RETURN ~done
		END Resume;
		PROCEDURE PumpOutput;
		VAR data: ARRAY 4097 OF CHAR; got, remaining: SIGNED32; ignore: Kernel32.BOOL;
		BEGIN
			IF pipe = 0 THEN RETURN END;
			IF (Kernel32.PeekNamedPipe(pipe, NIL, 0, NIL, remaining, NIL) # 0) & (remaining > 0) THEN
				IF remaining > 4096 THEN remaining := 4096 END;
				ignore := Kernel32.ReadFileBuffer(pipe, ADDRESSOF(data[0]), remaining, got, NIL);
				IF got > 0 THEN data[got] := 0X; Output("stdout", data) END
			END
		END PumpOutput;
		PROCEDURE Pump;
		VAR i, code, count, ignored: SIGNED32; adr, handle: ADDRESS; body: JSON.Object;
			data: ARRAY 4097 OF CHAR; unicode: SIGNED16;
		BEGIN
			PumpOutput;
			IF (process = 0) OR pending OR (waitEvent(event, 10) = 0) THEN RETURN END;
			pending := TRUE; status := Continue;
			CASE event.kind OF
			| 2, 3:
				i := 0; WHILE (i < MaxThreads) & (thread[i] # 0) DO INC(i) END;
				IF i = MaxThreads THEN Output("stderr", "too many target threads"); done := TRUE; RETURN END;
				IF event.kind = 3 THEN
					SYSTEM.GET(ADDRESSOF(event.data[0]), handle);
					IF handle # 0 THEN ignored := Kernel32.CloseHandle(handle) END;
					SYSTEM.GET(ADDRESSOF(event.data[16]), thread[i])
				ELSE SYSTEM.GET(ADDRESSOF(event.data[0]), thread[i])
				END;
				threadId[i] := event.tid
			| 4:
				FOR i := 0 TO MaxThreads-1 DO
					IF threadId[i] = event.tid THEN threadId[i] := 0; thread[i] := 0; frozen[i] := FALSE END
				END
			| 5:
				PumpOutput; body := JSON.NewObject(); Number(body, "exitCode", SYSTEM.GET32(ADDRESSOF(event.data[0])));
				Event("exited", body); Event("terminated", NIL); Proceed;
				ignored := Kernel32.CloseHandle(process); process := 0;
				ignored := Kernel32.CloseHandle(pipe); pipe := 0;
				IF ObHost.Remove(symbolFile) THEN END; RETURN
			| 6:
				SYSTEM.GET(ADDRESSOF(event.data[0]), handle);
				IF handle # 0 THEN ignored := Kernel32.CloseHandle(handle) END
			| 8:
				SYSTEM.GET(ADDRESSOF(event.data[0]), adr);
				(* The length is a WORD; copy it without signed truncation. *)
				count := SYSTEM.GET16(ADDRESSOF(event.data[10])); IF count < 0 THEN INC(count, 65536) END;
				IF count > 4096 THEN count := 4096 END;
				IF (count > 0) & Read(adr, ADDRESSOF(data[0]), count) THEN
					data[count] := 0X;
					IF data = ReadyMarker THEN
						IF ~LoadSymbols() THEN Output("stderr", "invalid target symbol snapshot"); done := TRUE; RETURN END;
						ready := TRUE; Arm; IF ~configured THEN RETURN END
					ELSE Output("console", data)
					END
				END
			| 1:
				code := SYSTEM.GET32(ADDRESSOF(event.data[0]));
				SYSTEM.GET(ADDRESSOF(event.data[16]), adr);
				IF (code = Kernel32.ExceptionBreakPoint) & ~initialBreak THEN initialBreak := TRUE
				ELSIF (code = Kernel32.ExceptionSingleStep) & (rearm >= 0) THEN
					IF ~Patch(spots[rearm].adr, 0CCX) THEN Output("stderr", "cannot rearm breakpoint"); done := TRUE; RETURN END;
					spots[rearm].armed := TRUE; rearm := -1; Thaw
				ELSIF Context() THEN
					i := SpotAt(adr);
					IF (code = Kernel32.ExceptionBreakPoint) & (i >= 0) & spots[i].armed THEN
						IF ~Patch(adr, spots[i].saved) THEN done := TRUE; RETURN END;
						spots[i].armed := FALSE; SYSTEM.PUT(context + 248, adr);
						IF setContext(Thread(event.tid), context) = 0 THEN done := TRUE; RETURN END;
						IF spots[i].wanted THEN rearm := i ELSE rearm := -1 END;
						IF stepping THEN stepping := FALSE; Stop("step", "") ELSE Stop("breakpoint", "") END;
						RETURN
					ELSIF pauseAsked & (code = Kernel32.ExceptionBreakPoint) THEN
						pauseAsked := FALSE; Stop("pause", ""); RETURN
					ELSE
						status := NotHandled;
						IF ready & ((Symbol(adr) # NIL) OR (SYSTEM.GET32(ADDRESSOF(event.data[152])) = 0)) THEN
							Stop("exception", "target exception"); RETURN
						END
					END
				ELSE status := NotHandled
				END
			ELSE
			END;
			Proceed
		END Pump;

		PROCEDURE Launch(arguments: JSON.Object; VAR failure: ARRAY OF CHAR): BOOLEAN;
		VAR source, procedure, executable, directory, temporary: Path; line: ARRAY 16384 OF CHAR;
			startup: Kernel32.StartupInfo; info: Kernel32.ProcessInformation;
			security: Kernel32.SecurityAttributes; input, writePipe: ADDRESS; ignored: SIGNED32;
		BEGIN
			failure := "";
			IF launched THEN failure := "one launch per debug session"; RETURN FALSE END;
			Text(arguments, "program", source); Text(arguments, "procedure", procedure);
			IF source = "" THEN failure := "launch needs a source file"; RETURN FALSE END;
			IF procedure = "" THEN procedure := "Do" END;
			IF ~ObHost.RealPath(source, source) OR ~ObHost.ExecutablePath(executable)
				OR ~ObHost.CurrentDirectory(directory) THEN failure := "cannot resolve launch paths"; RETURN FALSE END;
			IF ~ObHost.Env("TMPDIR", temporary) OR (temporary = "") THEN
				IF ~ObHost.Env("TEMP", temporary) THEN temporary := directory END
			END;
			COPY(temporary, symbolFile); Strings.Append(symbolFile, "/a2-debug-");
			Strings.AppendInt(symbolFile, ObHost.ProcessId()); Strings.Append(symbolFile, ".json");
			line := ""; Quote(executable, line); Strings.Append(line, " debug-run ");
			Quote(source, line); Strings.AppendChar(line, ' '); Quote(procedure, line);
			Strings.AppendChar(line, ' '); Quote(symbolFile, line);
			security.nLength := SIZEOF(Kernel32.SecurityAttributes); security.lpSecurityDescriptor := 0; security.bInheritHandle := 1;
			IF Kernel32.CreatePipe(pipe, writePipe, security, 0) = 0 THEN failure := "cannot create target output pipe"; RETURN FALSE END;
			ignored := Kernel32.SetHandleInformation(pipe, 1, 0);
			input := Kernel32.CreateFileName("NUL", MIN(SIGNED32), 3, SYSTEM.VAL(ANY, ADDRESSOF(security)), Kernel32.OpenExisting, 0, NIL);
			startup.cb := SIZEOF(Kernel32.StartupInfo); startup.dwFlags := {8};
			startup.lpReserved := 0; startup.lpDesktop := 0; startup.lpTitle := 0;
			startup.dwX := 0; startup.dwY := 0; startup.dwXSize := 0; startup.dwYSize := 0;
			startup.dwXCountChars := 0; startup.dwYCountChars := 0; startup.dwFillAttribute := 0;
			startup.wShowWindow := 0; startup.cbReserved2 := 0; startup.lpReserved2 := 0;
			startup.hStdInput := input; startup.hStdOutput := writePipe; startup.hStdError := writePipe;
			IF Kernel32.CreateProcess(executable, line, NIL, NIL, 1, 08000002H, NIL, directory, startup, info) = 0 THEN
				failure := "CreateProcess failed: "; Strings.AppendInt(failure, Kernel32.GetLastError());
				ignored := Kernel32.CloseHandle(writePipe); ignored := Kernel32.CloseHandle(input);
				ignored := Kernel32.CloseHandle(pipe); pipe := 0; RETURN FALSE
			END;
			ignored := Kernel32.CloseHandle(writePipe); ignored := Kernel32.CloseHandle(input);
			ignored := Kernel32.CloseHandle(info.hThread); process := info.hProcess; pid := info.dwProcessId;
			launched := TRUE; RETURN TRUE
		END Launch;

		PROCEDURE Frames(): JSON.Object;
		VAR body, item, source: JSON.Object; list: JSON.Array; i: SIGNED32; name, path: Path;
		BEGIN
			list := JSON.NewArray();
			IF stopped THEN
				FOR i := 0 TO frameCount-1 DO
					IF frames[i].symbol # NIL THEN
						item := JSON.NewObject(); Number(item, "id", i); Number(item, "column", 1);
						Text(frames[i].symbol, "name", name); item.Set("name", JSON.NewString(name));
						Number(item, "line", Line(frames[i].symbol, frames[i].pc));
						Text(frames[i].symbol, "source", path); source := JSON.NewObject();
						source.Set("path", JSON.NewString(path)); item.Set("source", source); list.Add(item)
					END
				END
			END;
			body := JSON.NewObject(); body.Set("stackFrames", list); Number(body, "totalFrames", list.length); RETURN body
		END Frames;
		PROCEDURE Locals(frame: SIGNED32): JSON.Array;
		VAR list, descriptors: JSON.Array; variable, item: JSON.Object; i: SIZE; type, mode: SIGNED32;
			adr: ADDRESS; data: ARRAY 32 OF CHAR; size: SIZE; buffer: Streams.Buffer; writer: Streams.Writer;
			name: Path; value: Strings.String;
		BEGIN
			list := JSON.NewArray();
			IF ~stopped OR (frame < 0) OR (frame >= frameCount) OR (frames[frame].symbol = NIL) THEN RETURN list END;
			descriptors := JSON.GetArray(frames[frame].symbol, "variables");
			FOR i := 0 TO descriptors.length-1 DO
				variable := JSON.AsObject(descriptors.At(i)); type := SHORT(Integer(variable, "type"));
				mode := SHORT(Integer(variable, "mode")); adr := Integer(variable, "offset");
				IF mode # ORD(Reflection.sfAbsolute) THEN INC(adr, frames[frame].fp) END;
				IF mode = ORD(Reflection.sfIndirect) THEN IF ~Read(adr, ADDRESSOF(adr), 8) THEN adr := 0 END END;
				NEW(buffer, 256); writer := buffer.GetWriter(); size := BasicSize(type);
				IF size = 0 THEN writer.String("<unsupported type>")
				ELSIF Read(adr, ADDRESSOF(data[0]), size) THEN Reflection.WriteBasicValue(writer, CHR(type), ADDRESSOF(data[0]), size)
				ELSE writer.String("<unreadable>")
				END;
				writer.Update; value := buffer.GetString(); Text(variable, "name", name);
				item := JSON.NewObject(); item.Set("name", JSON.NewString(name));
				item.Set("value", JSON.NewString(value^)); Number(item, "variablesReference", 0); list.Add(item)
			END;
			RETURN list
		END Locals;
		PROCEDURE Request(request: JSON.Object);
		VAR command, source, path, failure, expression, name: Path; arguments, body, item: JSON.Object;
			list, values: JSON.Array; i, j, frame, first: SIGNED32; ok: BOOLEAN;
		BEGIN
			Text(request, "command", command); arguments := JSON.AsObject(request.Get("arguments"));
			IF command = "initialize" THEN
				body := JSON.NewObject(); body.Set("supportsConfigurationDoneRequest", JSON.NewBool(TRUE));
				body.Set("supportsTerminateRequest", JSON.NewBool(TRUE)); body.Set("supportsEvaluateForHovers", JSON.NewBool(TRUE));
				Reply(request, body, ""); Event("initialized", NIL)
			ELSIF command = "launch" THEN
				ok := Launch(arguments, failure); Reply(request, NIL, failure);
				IF ok THEN body := JSON.NewObject(); Number(body, "systemProcessId", pid);
					body.Set("isLocalProcess", JSON.NewBool(TRUE)); body.Set("name", JSON.NewString("miniA2 target")); Event("process", body) END
			ELSIF command = "attach" THEN Reply(request, NIL, "attach is not supported; use launch")
			ELSIF command = "configurationDone" THEN
				configured := TRUE; Reply(request, NIL, ""); IF ready & pending & ~stopped THEN Proceed END
			ELSIF command = "setBreakpoints" THEN
				IF launched & ready & ~pending THEN Reply(request, NIL, "pause before changing breakpoints"); RETURN END;
				item := JSON.AsObject(arguments.Get("source")); Text(item, "path", path);
				IF ~ObHost.RealPath(path, source) THEN Reply(request, NIL, "invalid breakpoint source"); RETURN END;
				i := 0;
				WHILE i < wishCount DO
					IF wishes[i].source = source THEN
						j := SpotAt(wishes[i].adr);
						IF j >= 0 THEN
							IF spots[j].armed & ~Patch(spots[j].adr, spots[j].saved) THEN Reply(request, NIL, "cannot restore breakpoint"); RETURN END;
							spots[j].adr := 0; spots[j].armed := FALSE;
							IF rearm = j THEN rearm := -1 END
						END;
						DEC(wishCount); wishes[i] := wishes[wishCount]
					ELSE INC(i)
					END
				END;
				first := wishCount; list := JSON.GetArray(arguments, "breakpoints");
				IF list # NIL THEN
					FOR i := 0 TO SIGNED32(list.length)-1 DO
						IF wishCount < MaxSpots THEN
							wishes[wishCount].source := source; wishes[wishCount].line := SHORT(Integer(JSON.AsObject(list.At(i)), "line"));
							wishes[wishCount].adr := 0; wishes[wishCount].actual := 0; INC(wishCount)
						END
					END
				END;
				IF ready THEN Arm END;
				list := JSON.NewArray(); FOR i := first TO wishCount-1 DO list.Add(Verdict(i)) END;
				body := JSON.NewObject(); body.Set("breakpoints", list); Reply(request, body, "")
			ELSIF command = "threads" THEN
				list := JSON.NewArray();
				FOR i := 0 TO MaxThreads-1 DO
					IF thread[i] # 0 THEN item := JSON.NewObject(); Number(item, "id", threadId[i]);
						item.Set("name", JSON.NewString("target thread")); list.Add(item) END
				END;
				body := JSON.NewObject(); body.Set("threads", list); Reply(request, body, "")
			ELSIF command = "stackTrace" THEN
				IF Integer(arguments, "threadId") # event.tid THEN Reply(request, NIL, "select the stopped thread")
				ELSE Reply(request, Frames(), "") END
			ELSIF command = "scopes" THEN
				frame := SHORT(Integer(arguments, "frameId")); list := JSON.NewArray();
				IF stopped & (frame >= 0) & (frame < frameCount) THEN
					item := JSON.NewObject(); item.Set("name", JSON.NewString("Locals")); Number(item, "variablesReference", 1000+frame);
					item.Set("expensive", JSON.NewBool(FALSE)); list.Add(item)
				END;
				body := JSON.NewObject(); body.Set("scopes", list); Reply(request, body, "")
			ELSIF command = "variables" THEN
				body := JSON.NewObject(); body.Set("variables", Locals(SHORT(Integer(arguments, "variablesReference"))-1000)); Reply(request, body, "")
			ELSIF command = "evaluate" THEN
				Text(arguments, "expression", expression); values := Locals(SHORT(Integer(arguments, "frameId")));
				FOR i := 0 TO SIGNED32(values.length)-1 DO
					item := JSON.AsObject(values.At(i)); Text(item, "name", name);
					IF name = expression THEN
						body := JSON.NewObject(); body.Set("result", item.Get("value")); Number(body, "variablesReference", 0); Reply(request, body, ""); RETURN
					END
				END;
				Reply(request, NIL, "not a variable of this frame")
			ELSIF (command = "continue") OR (command = "next") OR (command = "stepOut") THEN
				IF Resume(command) THEN
					stepping := command # "continue"; body := JSON.NewObject(); body.Set("allThreadsContinued", JSON.NewBool(TRUE)); Reply(request, body, "")
				ELSE Reply(request, NIL, "cannot resume or no source location for this step") END
			ELSIF command = "pause" THEN
				IF (process # 0) & ~pending & (breakProcess(process) # 0) THEN pauseAsked := TRUE; Reply(request, NIL, "")
				ELSE Reply(request, NIL, "cannot pause target") END
			ELSIF (command = "disconnect") OR (command = "terminate") THEN Reply(request, NIL, ""); done := TRUE
			ELSE Reply(request, NIL, "unsupported request")
			END
		END Request;
		PROCEDURE Run;
		VAR request: JSON.Object; timer: Kernel.Timer; ignored: SIGNED32;
		BEGIN
			NEW(timer);
			WHILE ~done DO
				request := inbox.Take(); IF request # NIL THEN Request(request) END;
				IF (request = NIL) & inbox.Closed() THEN done := TRUE END;
				IF ~done THEN Pump END;
				IF (process = 0) OR pending THEN timer.Sleep(10) END
			END;
			IF process # 0 THEN
				(* A launched target belongs to this session. EOF and disconnect terminate it, so no
					patched instruction or suspended thread survives the owner of the debug events. *)
				ignored := Kernel32.TerminateProcess(process, 1); status := Continue; Proceed;
				ignored := Kernel32.WaitForSingleObject(process, 5000);
				ignored := Kernel32.CloseHandle(process); process := 0
			END;
			IF pipe # 0 THEN ignored := Kernel32.CloseHandle(pipe) END;
			IF symbolFile # "" THEN IF ObHost.Remove(symbolFile) THEN END END;
			inbox.Finish
		END Run;
	BEGIN {ACTIVE}
		Run
	END Session;

(* Quote an argument according to the Windows CRT rules, including trailing backslashes. *)
PROCEDURE Quote(CONST value: ARRAY OF CHAR; VAR line: ARRAY OF CHAR);
VAR i, slashes, j: SIZE;
BEGIN
	Strings.AppendChar(line, '"'); i := 0;
	WHILE value[i] # 0X DO
		slashes := 0;
		WHILE value[i] = 5CX DO INC(slashes); INC(i) END;
		IF (value[i] = '"') OR (value[i] = 0X) THEN slashes := slashes * 2 END;
		FOR j := 1 TO slashes DO Strings.AppendChar(line, 5CX) END;
		IF value[i] = '"' THEN Strings.AppendChar(line, 5CX) END;
		IF value[i] # 0X THEN Strings.AppendChar(line, value[i]); INC(i) END
	END;
	Strings.AppendChar(line, '"')
END Quote;

PROCEDURE BasicSize(type: SIGNED32): SIZE;
BEGIN
	CASE CHR(type) OF
	| Reflection.sfTypeCHAR, Reflection.sfTypeBOOLEAN, Reflection.sfTypeSHORTINT, Reflection.sfTypeSIGNED8,
		Reflection.sfTypeUNSIGNED8, Reflection.sfTypeBYTE, Reflection.sfTypeSET8: RETURN 1
	| Reflection.sfTypeINTEGER, Reflection.sfTypeSIGNED16, Reflection.sfTypeUNSIGNED16, Reflection.sfTypeSET16: RETURN 2
	| Reflection.sfTypeLONGINT, Reflection.sfTypeSIGNED32, Reflection.sfTypeUNSIGNED32, Reflection.sfTypeREAL,
		Reflection.sfTypeSET32: RETURN 4
	| Reflection.sfTypeHUGEINT, Reflection.sfTypeSIGNED64, Reflection.sfTypeUNSIGNED64, Reflection.sfTypeLONGREAL,
		Reflection.sfTypeADDRESS, Reflection.sfTypeSIZE, Reflection.sfTypeANY, Reflection.sfTypeOBJECT,
		Reflection.sfTypePointerToRecord, Reflection.sfTypeSET64: RETURN 8
	| Reflection.sfTypeWORD: RETURN SIZEOF(INTEGER)
	| Reflection.sfTypeLONGWORD: RETURN SIZEOF(LONGINTEGER)
	| Reflection.sfTypeSET: RETURN SIZEOF(SET)
	ELSE RETURN 0
	END
END BasicSize;

PROCEDURE Serve*(context: Commands.Context);
VAR queue: Inbox; session: Session; value: JSON.Value; alive: BOOLEAN; request: JSON.Object; command: Path;
BEGIN
	IF ~available THEN RETURN END;
	NEW(queue); NEW(session, queue, context.out);
	LOOP
		value := JSON.ReadFrame(context.in, alive); IF (value = NIL) & ~alive THEN EXIT END;
		request := JSON.AsObject(value);
		IF request # NIL THEN
			queue.Put(request);
			Text(request, "command", command);
			IF (command = "disconnect") OR (command = "terminate") THEN EXIT END
		END
	END;
	queue.Close; queue.Wait
END Serve;

PROCEDURE Init;
VAR module: ADDRESS;
BEGIN
	module := Kernel32.GetModuleHandle("kernel32.dll");
	Kernel32.GetProcAddress(module, "WaitForDebugEvent", SYSTEM.VAL(ADDRESS, waitEvent));
	Kernel32.GetProcAddress(module, "ContinueDebugEvent", SYSTEM.VAL(ADDRESS, continueEvent));
	Kernel32.GetProcAddress(module, "ReadProcessMemory", SYSTEM.VAL(ADDRESS, readMemory));
	Kernel32.GetProcAddress(module, "WriteProcessMemory", SYSTEM.VAL(ADDRESS, writeMemory));
	Kernel32.GetProcAddress(module, "VirtualProtectEx", SYSTEM.VAL(ADDRESS, protectMemory));
	Kernel32.GetProcAddress(module, "FlushInstructionCache", SYSTEM.VAL(ADDRESS, flushCode));
	Kernel32.GetProcAddress(module, "GetThreadContext", SYSTEM.VAL(ADDRESS, getContext));
	Kernel32.GetProcAddress(module, "SetThreadContext", SYSTEM.VAL(ADDRESS, setContext));
	Kernel32.GetProcAddress(module, "DebugBreakProcess", SYSTEM.VAL(ADDRESS, breakProcess));
	available := (waitEvent # NIL) & (continueEvent # NIL) & (readMemory # NIL) & (writeMemory # NIL)
		& (protectMemory # NIL) & (flushCode # NIL) & (getContext # NIL) & (setContext # NIL) & (breakProcess # NIL)
END Init;

BEGIN
	Init
END ObDebug.
