MODULE LSP;
(**
	AUTHOR "minia2 SDK";
	PURPOSE "Minimal Language Server (LSP) for Active Oberon — diagnostics over JSON-RPC/stdio";
	LIMITATIONS
		"- Diagnostics on open/change/save, hover, and go-to-definition. No completion yet.
		 - Go-to-definition crosses modules: project modules resolve to a sibling of the
		   current document; stdlib modules only when the client mounts a source tree at
		   /libsrc and names its host path in initializationOptions.stdlibSrc.
		 - Positions assume the source is ASCII/UTF-8 with 1 char = 1 UTF-16 unit."
*)

IMPORT Streams, Strings, JSON, Diagnostics, Compiler, SyntaxTree := FoxSyntaxTree, Commands,
	FoxScanner, FoxParser, FoxSemanticChecker, FoxGlobal, FoxBasic, Printout := FoxPrintout;

CONST
	CR = 0DX; LF = 0AX;

TYPE
	Document = OBJECT
	VAR next: Document; uri: Strings.String; text: Strings.String;
	END Document;

	(* Locates the innermost resolved use-site (SymbolDesignator) whose token span
	   contains a byte offset. The designator's .end position is unreliable, so the
	   token length is taken from the symbol name. *)
	Finder = OBJECT
	VAR best: SyntaxTree.SymbolDesignator; bestSpan: SIZE; target: SIGNED64;

		PROCEDURE Consider (d: SyntaxTree.SymbolDesignator);
		VAR span: SIZE; nm: ARRAY 128 OF CHAR;
		BEGIN
			IF d.symbol = NIL THEN RETURN END;
			d.symbol.GetName(nm); span := Strings.Length(nm);
			IF (d.position.start >= 0) & (target >= d.position.start) & (target < d.position.start + span) THEN
				IF (best = NIL) OR (span < bestSpan) THEN best := d; bestSpan := span END
			END
		END Consider;

		PROCEDURE WList (l: SyntaxTree.ExpressionList);
		VAR i: SIZE;
		BEGIN IF l # NIL THEN FOR i := 0 TO l.Length()-1 DO WExpr(l.GetExpression(i)) END END
		END WList;

		PROCEDURE WExpr (e: SyntaxTree.Expression);
		BEGIN
			IF e = NIL THEN RETURN END;
			WITH e:
				  SyntaxTree.SymbolDesignator DO Consider(e); WExpr(e.left)
				| SyntaxTree.ProcedureCallDesignator DO WExpr(e.left); WList(e.parameters)
				| SyntaxTree.BuiltinCallDesignator DO WExpr(e.left); WList(e.parameters)
				| SyntaxTree.ParameterDesignator DO WExpr(e.left); WList(e.parameters)
				| SyntaxTree.IndexDesignator DO WExpr(e.left); WList(e.parameters)
				| SyntaxTree.BracketDesignator DO WExpr(e.left); WList(e.parameters)
				| SyntaxTree.ArrowDesignator DO WExpr(e.left)
				| SyntaxTree.SelectorDesignator DO WExpr(e.left)
				| SyntaxTree.Designator DO WExpr(e.left)
				| SyntaxTree.BinaryExpression DO WExpr(e.left); WExpr(e.right)
				| SyntaxTree.UnaryExpression DO WExpr(e.left)
			ELSE
			END
		END WExpr;

		PROCEDURE WSeq (s: SyntaxTree.StatementSequence);
		VAR i: SIZE;
		BEGIN IF s # NIL THEN FOR i := 0 TO s.Length()-1 DO WStmt(s.GetStatement(i)) END END
		END WSeq;

		PROCEDURE WStmt (s: SyntaxTree.Statement);
		VAR i: SIZE; cp: SyntaxTree.CasePart;
		BEGIN
			IF s = NIL THEN RETURN END;
			WITH s:
				  SyntaxTree.Assignment DO WExpr(s.left); WExpr(s.right)
				| SyntaxTree.CommunicationStatement DO WExpr(s.left); WExpr(s.right)
				| SyntaxTree.ProcedureCallStatement DO WExpr(s.call)
				| SyntaxTree.IfStatement DO
					WExpr(s.ifPart.condition); WSeq(s.ifPart.statements);
					FOR i := 0 TO s.ElsifParts()-1 DO
						WExpr(s.GetElsifPart(i).condition); WSeq(s.GetElsifPart(i).statements)
					END;
					WSeq(s.elsePart)
				| SyntaxTree.WhileStatement DO WExpr(s.condition); WSeq(s.statements)
				| SyntaxTree.RepeatStatement DO WExpr(s.condition); WSeq(s.statements)
				| SyntaxTree.ForStatement DO WExpr(s.variable); WExpr(s.from); WExpr(s.to); WExpr(s.by); WSeq(s.statements)
				| SyntaxTree.ReturnStatement DO WExpr(s.returnValue)
				| SyntaxTree.AwaitStatement DO WExpr(s.condition)
				| SyntaxTree.CaseStatement DO
					WExpr(s.variable);
					IF s.caseParts # NIL THEN
						FOR i := 0 TO s.caseParts.Length()-1 DO
							cp := s.GetCasePart(i); WList(cp.elements); WSeq(cp.statements)
						END
					END;
					WSeq(s.elsePart)
				| SyntaxTree.StatementBlock DO WSeq(s.statements)
			ELSE
			END
		END WStmt;

		(* Recurse the whole scope tree, walking every procedure/method body — this
		   covers module procedures, nested procedures, AND methods declared inside
		   OBJECT/RECORD types (whose ProcedureScopes are nested scopes). *)
		PROCEDURE WScope (scope: SyntaxTree.Scope);
		VAR ns: SyntaxTree.Scope;
		BEGIN
			IF scope = NIL THEN RETURN END;
			WITH scope: SyntaxTree.ProcedureScope DO
				IF scope.body # NIL THEN WSeq(scope.body.statements) END
			ELSE
			END;
			ns := scope.firstScope;
			WHILE ns # NIL DO WScope(ns); ns := ns.nextScope END
		END WScope;

		PROCEDURE Find (module: SyntaxTree.Module; offset: SIGNED64): SyntaxTree.SymbolDesignator;
		VAR ms: SyntaxTree.ModuleScope;
		BEGIN
			best := NIL; bestSpan := 0; target := offset;
			IF module = NIL THEN RETURN NIL END;
			ms := module.moduleScope;
			WScope(ms);
			IF (ms.bodyProcedure # NIL) & (ms.bodyProcedure.procedureScope # NIL)
				& (ms.bodyProcedure.procedureScope.body # NIL) THEN
				WSeq(ms.bodyProcedure.procedureScope.body.statements)
			END;
			RETURN best
		END Find;
	END Finder;

	(* Locates a declaration by (simple) name anywhere in a freshly-analyzed module's
	   scope tree. Used for cross-module go-to-definition: positions read back from a
	   .SymUu are NOT reliable, but re-analyzing the owning module's source yields the
	   real name position. Module-level declarations win (searched first), then nested
	   ones (type/object members). *)
	DeclScan = OBJECT
	VAR target: ARRAY 128 OF CHAR; found: SyntaxTree.Symbol;

		PROCEDURE Scan (scope: SyntaxTree.Scope);
		VAR sym: SyntaxTree.Symbol; ns: SyntaxTree.Scope; nm: ARRAY 128 OF CHAR;
		BEGIN
			IF (scope = NIL) OR (found # NIL) THEN RETURN END;
			sym := scope.firstSymbol;
			WHILE (sym # NIL) & (found = NIL) DO
				sym.GetName(nm);
				IF (nm = target) & (sym.position.line > 0) THEN found := sym; RETURN END;
				sym := sym.nextSymbol
			END;
			ns := scope.firstScope;
			WHILE (ns # NIL) & (found = NIL) DO Scan(ns); ns := ns.nextScope END
		END Scan;

		PROCEDURE Find (module: SyntaxTree.Module; CONST name: ARRAY OF CHAR): SyntaxTree.Symbol;
		BEGIN
			found := NIL; COPY(name, target);
			IF module # NIL THEN Scan(module.moduleScope) END;
			RETURN found
		END Find;
	END DeclScan;

VAR
	documents: Document;
	initialized: BOOLEAN;
	(* host directory of a standard-library source tree, as sent by the client in
	   initialize.initializationOptions.stdlibSrc (a plain absolute path, no trailing
	   slash). The client also mounts that same tree at /libsrc so the server can read
	   it. Empty => go-to-definition into stdlib modules is disabled. *)
	stdlibSrcHost: ARRAY 512 OF CHAR;

	PROCEDURE FindDoc (CONST uri: ARRAY OF CHAR): Document;
	VAR d: Document;
	BEGIN
		d := documents;
		WHILE d # NIL DO IF d.uri^ = uri THEN RETURN d END; d := d.next END;
		RETURN NIL
	END FindDoc;

	PROCEDURE PutDoc (CONST uri, text: ARRAY OF CHAR);
	VAR d: Document;
	BEGIN
		d := FindDoc(uri);
		IF d = NIL THEN
			NEW(d); d.uri := Strings.NewString(uri); d.next := documents; documents := d
		END;
		d.text := Strings.NewString(text)
	END PutDoc;

	PROCEDURE RemoveDoc (CONST uri: ARRAY OF CHAR);
	VAR d, p: Document;
	BEGIN
		d := documents; p := NIL;
		WHILE d # NIL DO
			IF d.uri^ = uri THEN
				IF p = NIL THEN documents := d.next ELSE p.next := d.next END; RETURN
			END;
			p := d; d := d.next
		END
	END RemoveDoc;

	(* ---- byte offset -> LSP 0-based (line, character) ---- *)
	PROCEDURE OffsetToPos (text: Strings.String; offset: SIGNED64; VAR line, char: SIGNED32);
	VAR i: SIZE;
	BEGIN
		line := 0; char := 0; i := 0;
		WHILE (text # NIL) & (i < offset) & (text[i] # 0X) DO
			IF text[i] = LF THEN INC(line); char := 0 ELSE INC(char) END;
			INC(i)
		END
	END OffsetToPos;

	(* Drop the "  in line X, col Y" tail the compiler appends (we set our own range). *)
	PROCEDURE TrimMessage (VAR msg: ARRAY OF CHAR);
	VAR i: SIZE;
	BEGIN
		i := 0;
		WHILE msg[i] # 0X DO
			IF (msg[i] = " ") & (msg[i+1] = "i") & (msg[i+2] = "n") & (msg[i+3] = " ")
				& (msg[i+4] = "l") & (msg[i+5] = "i") & (msg[i+6] = "n") & (msg[i+7] = "e") THEN
				msg[i] := 0X; RETURN
			END;
			INC(i)
		END
	END TrimMessage;

	PROCEDURE Position (line, char: SIGNED32): JSON.Object;
	VAR o: JSON.Object;
	BEGIN
		o := JSON.NewObject();
		o.Set("line", JSON.NewNumber(line));
		o.Set("character", JSON.NewNumber(char));
		RETURN o
	END Position;

	(* ---- on-demand import-closure build (project-aware resolution) ----
	   The server runs in a work dir seeded with the stdlib .SymUu and symlinks to
	   the project's .Mod sources. To resolve a module M we ensure M.SymUu exists:
	   if not, and M.Mod is available, parse M, ensure its imports first (deps-first),
	   then compile M to a .SymUu. Import cycles are illegal in Oberon, so the
	   recursion terminates; the .SymUu file itself is the memo. *)

	PROCEDURE FileExists (CONST fn: ARRAY OF CHAR): BOOLEAN;
	BEGIN RETURN FoxBasic.GetFileReader(fn) # NIL
	END FileExists;

	(* Read a whole source file into a string (NIL if it can't be opened). *)
	PROCEDURE ReadFile (CONST fn: ARRAY OF CHAR): Strings.String;
	VAR reader: Streams.Reader; buf: Streams.Buffer; w: Streams.Writer; ch: CHAR;
	BEGIN
		reader := FoxBasic.GetFileReader(fn); IF reader = NIL THEN RETURN NIL END;
		NEW(buf, 4096); w := buf.GetWriter();
		LOOP ch := reader.Get(); IF reader.res # Streams.Ok THEN EXIT END; w.Char(ch) END;
		w.Update; RETURN buf.GetString()
	END ReadFile;

	(* Compile modFile with symbol-file export to the cwd (no code generation). *)
	PROCEDURE CompileToSym (CONST modFile: ARRAY OF CHAR);
	VAR optR: Streams.StringReader; opts: Compiler.CompilerOptions; reader: Streams.Reader;
		diag: Diagnostics.DiagnosticsList; logbuf: Streams.Buffer; log: Streams.Writer;
		importCache: SyntaxTree.ModuleScope; ignore: BOOLEAN;
	BEGIN
		reader := FoxBasic.GetFileReader(modFile); IF reader = NIL THEN RETURN END;
		NEW(diag); NEW(logbuf, 128); log := logbuf.GetWriter();
		Streams.OpenStringReader(optR, "-p=Unix64 --destPath=./");
		IF ~Compiler.GetOptions(optR, log, diag, opts) THEN RETURN END;
		opts.objectFile := NIL;   (* symbolFile.Export still runs -> writes <M>.SymUu *)
		importCache := NIL;
		ignore := Compiler.Modules(modFile, reader, 0, diag, log, opts, importCache)
	END CompileToSym;

	PROCEDURE EnsureSymbols (CONST name: ARRAY OF CHAR);
	VAR modFile, symFile, iname: ARRAY 256 OF CHAR; reader: Streams.Reader;
		diag: Diagnostics.DiagnosticsList; scanner: FoxScanner.Scanner; parser: FoxParser.Parser;
		module: SyntaxTree.Module; imp: SyntaxTree.Import;
	BEGIN
		COPY(name, symFile); Strings.Append(symFile, ".SymUu");
		IF FileExists(symFile) THEN RETURN END;           (* already have symbols *)
		COPY(name, modFile); Strings.Append(modFile, ".Mod");
		reader := FoxBasic.GetFileReader(modFile);
		IF reader = NIL THEN RETURN END;                  (* no source -> leave unresolved *)
		NEW(diag);
		scanner := FoxScanner.NewScanner(name, reader, 0, diag);
		parser := FoxParser.NewParser(scanner, diag, "");
		module := parser.Module();
		IF (module # NIL) & ~parser.error THEN
			imp := module.moduleScope.firstImport;
			WHILE imp # NIL DO
				IF imp.moduleName # FoxGlobal.SystemName THEN
					FoxBasic.GetString(imp.moduleName, iname); EnsureSymbols(iname)
				END;
				imp := imp.nextImport
			END
		END;
		CompileToSym(modFile)
	END EnsureSymbols;

	(* Parse `text`, then ensure symbols for each of its imports exist in the cwd. *)
	PROCEDURE EnsureImportsOf (text: Strings.String);
	VAR srcR: Streams.StringReader; diag: Diagnostics.DiagnosticsList;
		scanner: FoxScanner.Scanner; parser: FoxParser.Parser; module: SyntaxTree.Module;
		imp: SyntaxTree.Import; iname: ARRAY 256 OF CHAR;
	BEGIN
		NEW(diag);
		Streams.OpenStringReader(srcR, text^);
		scanner := FoxScanner.NewScanner("source", srcR, 0, diag);
		parser := FoxParser.NewParser(scanner, diag, "");
		module := parser.Module();
		IF (module = NIL) OR parser.error THEN RETURN END;
		imp := module.moduleScope.firstImport;
		WHILE imp # NIL DO
			IF imp.moduleName # FoxGlobal.SystemName THEN
				FoxBasic.GetString(imp.moduleName, iname); EnsureSymbols(iname)
			END;
			imp := imp.nextImport
		END
	END EnsureImportsOf;

	(* Compile `text` and return a JSON array of LSP Diagnostic objects. *)
	PROCEDURE Diagnose (text: Strings.String): JSON.Array;
	VAR
		optR, srcR: Streams.StringReader; opts: Compiler.CompilerOptions;
		diag: Diagnostics.DiagnosticsList; importCache: SyntaxTree.ModuleScope;
		logbuf: Streams.Buffer; log: Streams.Writer; ignore: BOOLEAN;
		e: Diagnostics.Entry; arr: JSON.Array; d, range: JSON.Object;
		line, char, sev: SIGNED32; msg: ARRAY 256 OF CHAR;
	BEGIN
		arr := JSON.NewArray();
		EnsureImportsOf(text);   (* build project import-closure symbols first *)
		NEW(diag); NEW(logbuf, 256); log := logbuf.GetWriter();
		Streams.OpenStringReader(optR, "-p=Unix64 --warnings");
		IF ~Compiler.GetOptions(optR, log, diag, opts) THEN RETURN arr END;
		opts.objectFile := NIL;   (* skip codegen; keep symbolFile so imports resolve *)
		Streams.OpenStringReader(srcR, text^); importCache := NIL;
		ignore := Compiler.Modules("source", srcR, 0, diag, log, opts, importCache);

		e := diag.entries;
		WHILE e # NIL DO
			IF e.position >= 0 THEN
				OffsetToPos(text, e.position, line, char);
				COPY(e.message, msg); TrimMessage(msg);
				IF e.type = Diagnostics.TypeError THEN sev := 1
				ELSIF e.type = Diagnostics.TypeWarning THEN sev := 2
				ELSE sev := 3 END;
				d := JSON.NewObject();
				range := JSON.NewObject();
				range.Set("start", Position(line, char));
				range.Set("end", Position(line, char + 1));
				d.Set("range", range);
				d.Set("severity", JSON.NewNumber(sev));
				d.Set("source", JSON.NewString("oberon"));
				d.Set("message", JSON.NewString(msg));
				arr.Add(d)
			END;
			e := e.next
		END;
		RETURN arr
	END Diagnose;

	(* ---- JSON-RPC transport (Content-Length framed) ---- *)

	PROCEDURE WriteMessage (out: Streams.Writer; msg: JSON.Value);
	VAR body: Strings.String;
	BEGIN
		body := JSON.ToString(msg);
		out.String("Content-Length: "); out.Int(Strings.Length(body^), 0);
		out.Char(CR); out.Char(LF); out.Char(CR); out.Char(LF);
		out.String(body^); out.Update
	END WriteMessage;

	PROCEDURE ContentLength (CONST line: ARRAY OF CHAR): SIGNED32;
	CONST prefix = "Content-Length:";
	VAR i, j: SIZE; n: SIGNED32;
	BEGIN
		i := 0;
		WHILE (prefix[i] # 0X) & (line[i] = prefix[i]) DO INC(i) END;
		IF prefix[i] # 0X THEN RETURN -1 END;
		WHILE (line[i] = " ") DO INC(i) END;
		n := 0; j := i;
		WHILE (line[j] >= "0") & (line[j] <= "9") DO n := n * 10 + (ORD(line[j]) - ORD("0")); INC(j) END;
		RETURN n
	END ContentLength;

	(* Read one framed message body; returns NIL on EOF/parse failure. *)
	PROCEDURE ReadMessage (in: Streams.Reader): JSON.Value;
	VAR line: ARRAY 256 OF CHAR; n, got: SIGNED32; len: SIZE;
		buf: POINTER TO ARRAY OF CHAR; v: JSON.Value; ok: BOOLEAN;
	BEGIN
		n := -1;
		LOOP
			in.Ln(line);
			IF (line[0] = 0X) THEN
				IF in.res # Streams.Ok THEN RETURN NIL END;   (* EOF on the blank/again *)
				EXIT   (* blank line ends the header block *)
			END;
			IF ContentLength(line) >= 0 THEN n := ContentLength(line) END
		END;
		IF n < 0 THEN RETURN NIL END;
		NEW(buf, n + 1); got := 0;
		WHILE got < n DO
			in.Bytes(buf^, got, n - got, len);
			IF len <= 0 THEN RETURN NIL END;
			got := got + SIGNED32(len)
		END;
		buf[n] := 0X;
		ok := JSON.Parse(buf^, v);
		IF ~ok THEN RETURN NIL END;
		RETURN v
	END ReadMessage;

	(* ---- helpers to extract fields ---- *)

	PROCEDURE GetStr (o: JSON.Object; CONST key: ARRAY OF CHAR; VAR s: Strings.String): BOOLEAN;
	VAR v: JSON.Value;
	BEGIN
		IF o = NIL THEN RETURN FALSE END;
		v := o.Get(key);
		IF (v # NIL) & (v IS JSON.String) THEN s := v(JSON.String).value; RETURN TRUE END;
		RETURN FALSE
	END GetStr;

	PROCEDURE AsObject (v: JSON.Value): JSON.Object;
	BEGIN
		IF (v # NIL) & (v IS JSON.Object) THEN RETURN v(JSON.Object) ELSE RETURN NIL END
	END AsObject;

	(* textDocument uri + text from params (didOpen has textDocument.text;
	   didChange has contentChanges[0].text with full sync). *)
	PROCEDURE PublishFor (out: Streams.Writer; uri: Strings.String);
	VAR note, params: JSON.Object; d: Document; arr: JSON.Array;
	BEGIN
		d := FindDoc(uri^);
		IF d = NIL THEN arr := JSON.NewArray() ELSE arr := Diagnose(d.text) END;
		note := JSON.NewObject();
		note.Set("jsonrpc", JSON.NewString("2.0"));
		note.Set("method", JSON.NewString("textDocument/publishDiagnostics"));
		params := JSON.NewObject();
		params.Set("uri", JSON.NewString(uri^));
		params.Set("diagnostics", arr);
		note.Set("params", params);
		WriteMessage(out, note)
	END PublishFor;

	PROCEDURE Respond (out: Streams.Writer; id: JSON.Value; result: JSON.Value);
	VAR resp: JSON.Object;
	BEGIN
		IF id = NIL THEN RETURN END;
		resp := JSON.NewObject();
		resp.Set("jsonrpc", JSON.NewString("2.0"));
		resp.Set("id", id);
		IF result = NIL THEN resp.Set("result", JSON.NewNull()) ELSE resp.Set("result", result) END;
		WriteMessage(out, resp)
	END Respond;

	(* ---- hover / go-to-definition (frontend + checker, then AST lookup) ---- *)

	PROCEDURE GetInt (o: JSON.Object; CONST key: ARRAY OF CHAR; VAR n: SIGNED32): BOOLEAN;
	VAR v: JSON.Value;
	BEGIN
		IF o = NIL THEN RETURN FALSE END;
		v := o.Get(key);
		IF (v # NIL) & (v IS JSON.Number) THEN n := SIGNED32(ENTIER(v(JSON.Number).value)); RETURN TRUE END;
		RETURN FALSE
	END GetInt;

	(* LSP 0-based (line, character) -> byte offset in text *)
	PROCEDURE PosToOffset (text: Strings.String; line, char: SIGNED32): SIGNED64;
	VAR i: SIZE; l, c: SIGNED32;
	BEGIN
		IF text = NIL THEN RETURN 0 END;
		i := 0; l := 0; c := 0;
		WHILE text[i] # 0X DO
			IF (l = line) & (c = char) THEN RETURN i END;
			IF text[i] = LF THEN
				IF l = line THEN RETURN i END;   (* target char past end of line *)
				INC(l); c := 0
			ELSE INC(c) END;
			INC(i)
		END;
		RETURN i
	END PosToOffset;

	PROCEDURE Kind (sym: SyntaxTree.Symbol; VAR k: ARRAY OF CHAR);
	BEGIN
		WITH sym:
			  SyntaxTree.Module DO COPY("module", k)
			| SyntaxTree.TypeDeclaration DO COPY("type", k)
			| SyntaxTree.Constant DO COPY("const", k)
			| SyntaxTree.Parameter DO COPY("parameter", k)
			| SyntaxTree.Property DO COPY("field", k)
			| SyntaxTree.Variable DO COPY("variable", k)
			| SyntaxTree.Operator DO COPY("operator", k)
			| SyntaxTree.Procedure DO COPY("procedure", k)
			| SyntaxTree.Alias DO COPY("alias", k)
			| SyntaxTree.Builtin DO COPY("builtin", k)
			| SyntaxTree.Import DO COPY("import", k)
		ELSE COPY("symbol", k)
		END
	END Kind;

	PROCEDURE TypeStr (sym: SyntaxTree.Symbol): Strings.String;
	VAR buf: Streams.Buffer; w: Streams.Writer; p: Printout.Printer;
	BEGIN
		IF (sym.type = NIL) OR (sym.type.resolvedType = NIL) THEN RETURN NIL END;
		NEW(buf, 256); w := buf.GetWriter(); p := Printout.NewPrinter(w, Printout.SymbolFile, FALSE);
		p.Type(sym.type.resolvedType); w.Update;
		RETURN buf.GetString()
	END TypeStr;

	(* Parse + semantically check `text`, returning the resolved module (or NIL).
	   Replicates Compiler.Modules' checker setup so imports resolve. *)
	PROCEDURE Analyze (text: Strings.String): SyntaxTree.Module;
	VAR optR, srcR: Streams.StringReader; opts: Compiler.CompilerOptions;
		diag: Diagnostics.DiagnosticsList; logbuf: Streams.Buffer; log: Streams.Writer;
		scanner: FoxScanner.Scanner; parser: FoxParser.Parser; module: SyntaxTree.Module;
		checker: FoxSemanticChecker.Checker; importCache: SyntaxTree.ModuleScope; system: FoxGlobal.System;
	BEGIN
		EnsureImportsOf(text);   (* build project import-closure symbols first *)
		NEW(diag); NEW(logbuf, 128); log := logbuf.GetWriter();
		Streams.OpenStringReader(optR, "-p=Unix64");
		IF ~Compiler.GetOptions(optR, log, diag, opts) THEN RETURN NIL END;
		Streams.OpenStringReader(srcR, text^);
		scanner := FoxScanner.NewScanner("source", srcR, 0, diag);
		parser := FoxParser.NewParser(scanner, diag, "");
		module := parser.Module();
		IF (module = NIL) OR parser.error THEN RETURN module END;
		system := opts.backend.GetSystem();
		IF opts.symbolFile # NIL THEN opts.symbolFile.Initialize(diag, system, "") END;
		importCache := NIL;
		checker := FoxSemanticChecker.NewChecker(diag, FALSE, FALSE, system, opts.symbolFile, importCache, "");
		checker.Module(module);
		RETURN module
	END Analyze;

	(* Locate the readable source of module <mname>: a project module symlinked into
	   the cwd (from /work), else the stdlib source tree the client mounted at /libsrc. *)
	PROCEDURE ModSourceFile (CONST mname: ARRAY OF CHAR; VAR fn: ARRAY OF CHAR): BOOLEAN;
	BEGIN
		COPY(mname, fn); Strings.Append(fn, ".Mod");
		IF FileExists(fn) THEN RETURN TRUE END;
		IF stdlibSrcHost[0] # 0X THEN
			COPY("/libsrc/", fn); Strings.Append(fn, mname); Strings.Append(fn, ".Mod");
			IF FileExists(fn) THEN RETURN TRUE END
		END;
		RETURN FALSE
	END ModSourceFile;

	(* Reliable declaration position of symbol <symName> in module <mname>: re-analyze
	   the module's own source (positions from a .SymUu can't be trusted) and find the
	   declaration by name. Returns FALSE if the source or the declaration isn't found. *)
	PROCEDURE FindDeclPos (CONST mname, symName: ARRAY OF CHAR; VAR line, char: SIGNED32): BOOLEAN;
	VAR fn: ARRAY 256 OF CHAR; text: Strings.String; module: SyntaxTree.Module; ds: DeclScan; sym: SyntaxTree.Symbol;
	BEGIN
		IF ~ModSourceFile(mname, fn) THEN RETURN FALSE END;
		text := ReadFile(fn); IF text = NIL THEN RETURN FALSE END;
		module := Analyze(text); IF module = NIL THEN RETURN FALSE END;
		NEW(ds); sym := ds.Find(module, symName); IF sym = NIL THEN RETURN FALSE END;
		line := SIGNED32(sym.position.line) - 1;
		char := SIGNED32(sym.position.start - sym.position.linepos);
		RETURN TRUE
	END FindDeclPos;

	(* textDocument/hover result, or NIL if nothing under the offset. *)
	PROCEDURE HoverAt (text: Strings.String; offset: SIGNED64): JSON.Value;
	VAR module: SyntaxTree.Module; f: Finder; d: SyntaxTree.SymbolDesignator; sym: SyntaxTree.Symbol;
		nm: ARRAY 128 OF CHAR; kd: ARRAY 16 OF CHAR; ts: Strings.String; lf: ARRAY 2 OF CHAR;
		val: ARRAY 1024 OF CHAR; contents, range, result: JSON.Object; line, char: SIGNED32;
	BEGIN
		module := Analyze(text); IF module = NIL THEN RETURN NIL END;
		NEW(f); d := f.Find(module, offset); IF d = NIL THEN RETURN NIL END;
		sym := d.symbol; sym.GetName(nm); Kind(sym, kd); ts := TypeStr(sym);
		COPY(kd, val); Strings.Append(val, " "); Strings.Append(val, nm);
		IF ts # NIL THEN Strings.Append(val, " : "); Strings.Append(val, ts^) END;
		IF sym.comment # NIL THEN lf[0] := LF; lf[1] := 0X; Strings.Append(val, lf); Strings.Append(val, sym.comment.source^) END;
		contents := JSON.NewObject();
		contents.Set("kind", JSON.NewString("plaintext"));
		contents.Set("value", JSON.NewString(val));
		OffsetToPos(text, d.position.start, line, char);
		range := JSON.NewObject();
		range.Set("start", Position(line, char));
		range.Set("end", Position(line, char + SIGNED32(Strings.Length(nm))));
		result := JSON.NewObject();
		result.Set("contents", contents); result.Set("range", range);
		RETURN result
	END HoverAt;

	(* Sibling URI: take curUri (file:// URI of the current document), drop its last
	   path segment and append "<mname>.Mod". Both the current file and the target
	   project module live in the same directory, which is what the client mounts at
	   /work, so this yields a host URI the editor can open. *)
	PROCEDURE SiblingUri (curUri: Strings.String; CONST mname: ARRAY OF CHAR): Strings.String;
	VAR i, last: SIZE; s: ARRAY 1024 OF CHAR;
	BEGIN
		IF curUri = NIL THEN RETURN NIL END;
		last := -1; i := 0;
		WHILE curUri[i] # 0X DO IF curUri[i] = "/" THEN last := i END; INC(i) END;
		IF last < 0 THEN RETURN NIL END;
		FOR i := 0 TO last DO s[i] := curUri[i] END;   (* prefix incl. trailing "/" *)
		s[last+1] := 0X;
		Strings.Append(s, mname); Strings.Append(s, ".Mod");
		RETURN Strings.NewString(s)
	END SiblingUri;

	(* Host file:// URI of module <mname>'s source, or NIL if not addressable.
	   - project module: its <mname>.Mod is symlinked into the cwd (from /work);
	     map it to a sibling of the current document.
	   - stdlib module: the client mounts a host source tree at /libsrc and passes its
	     host path (stdlibSrcHost) in initializationOptions.stdlibSrc; return the
	     matching host URI. *)
	PROCEDURE SourceUriFor (curUri: Strings.String; CONST mname: ARRAY OF CHAR): Strings.String;
	VAR f, s: ARRAY 1024 OF CHAR;
	BEGIN
		COPY(mname, f); Strings.Append(f, ".Mod");
		IF FileExists(f) THEN RETURN SiblingUri(curUri, mname) END;
		IF stdlibSrcHost[0] # 0X THEN
			COPY("/libsrc/", f); Strings.Append(f, mname); Strings.Append(f, ".Mod");
			IF FileExists(f) THEN
				COPY("file://", s); Strings.Append(s, stdlibSrcHost);
				Strings.Append(s, "/"); Strings.Append(s, mname); Strings.Append(s, ".Mod");
				RETURN Strings.NewString(s)
			END
		END;
		RETURN NIL
	END SourceUriFor;

	(* textDocument/definition Location. Resolves declarations in the current file
	   AND in other modules: the imported symbol's position (line/start/linepos) is
	   preserved in the .SymUu, so we point at the owning module's source file. *)
	PROCEDURE DefinitionAt (text: Strings.String; offset: SIGNED64; uri: Strings.String): JSON.Value;
	VAR module, owner: SyntaxTree.Module; f: Finder; d: SyntaxTree.SymbolDesignator; sym: SyntaxTree.Symbol;
		nm, mname: ARRAY 128 OF CHAR; loc, range: JSON.Object; line, char: SIGNED32; targetUri: Strings.String;
	BEGIN
		module := Analyze(text); IF module = NIL THEN RETURN NIL END;
		NEW(f); d := f.Find(module, offset); IF d = NIL THEN RETURN NIL END;
		sym := d.symbol;
		IF sym.scope = NIL THEN RETURN NIL END;
		owner := sym.scope.ownerModule;
		IF owner = NIL THEN RETURN NIL END;
		IF sym.position.line <= 0 THEN RETURN NIL END;   (* builtin / SYSTEM / no source *)
		sym.GetName(nm);
		IF owner = module THEN
			(* same file: this symbol came from the fresh analysis, so its own position
			   is reliable *)
			targetUri := uri;
			line := SIGNED32(sym.position.line) - 1;
			char := SIGNED32(sym.position.start - sym.position.linepos)
		ELSE
			(* other module: the imported symbol's position (from a .SymUu) is not
			   reliable — resolve the real coordinates from the module's own source *)
			owner.GetName(mname);
			targetUri := SourceUriFor(uri, mname);
			IF targetUri = NIL THEN RETURN NIL END;
			IF ~FindDeclPos(mname, nm, line, char) THEN RETURN NIL END
		END;
		range := JSON.NewObject();
		range.Set("start", Position(line, char));
		range.Set("end", Position(line, char + SIGNED32(Strings.Length(nm))));
		loc := JSON.NewObject();
		loc.Set("uri", JSON.NewString(targetUri^)); loc.Set("range", range);
		RETURN loc
	END DefinitionAt;

	(* Shared server loop. live=TRUE also re-diagnoses on every didChange
	   (rely on the client to debounce); live=FALSE diagnoses on open/save only. *)
	PROCEDURE Serve (context: Commands.Context; live: BOOLEAN);
	VAR msg: JSON.Value; req, params, td, caps, result, pos, initOpts: JSON.Object;
		method, uri, text, sopt: Strings.String; in: Streams.Reader; out: Streams.Writer;
		changes: JSON.Value; arr: JSON.Array; first, res: JSON.Value;
		line, char: SIGNED32; doc: Document;
	BEGIN
		in := context.in; out := context.out;
		documents := NIL; initialized := FALSE; stdlibSrcHost[0] := 0X;
		LOOP
			msg := ReadMessage(in);
			IF msg = NIL THEN EXIT END;              (* EOF or unrecoverable *)
			req := AsObject(msg);
			IF req # NIL THEN
				IF GetStr(req, "method", method) THEN
					params := AsObject(req.Get("params"));
					IF method^ = "initialize" THEN
						caps := JSON.NewObject();
						caps.Set("textDocumentSync", JSON.NewNumber(1));   (* full sync *)
						caps.Set("hoverProvider", JSON.NewBool(TRUE));
						caps.Set("definitionProvider", JSON.NewBool(TRUE));
						result := JSON.NewObject();
						result.Set("capabilities", caps);
						(* optional: host dir of extracted stdlib sources, for cross-module
						   go-to-definition into the standard library *)
						initOpts := AsObject(params.Get("initializationOptions"));
						IF (initOpts # NIL) & GetStr(initOpts, "stdlibSrc", sopt) THEN
							COPY(sopt^, stdlibSrcHost)
						END;
						Respond(out, req.Get("id"), result)
					ELSIF method^ = "initialized" THEN
						initialized := TRUE
					ELSIF method^ = "shutdown" THEN
						Respond(out, req.Get("id"), NIL)
					ELSIF method^ = "exit" THEN
						EXIT
					ELSIF method^ = "textDocument/didOpen" THEN
						td := AsObject(params.Get("textDocument"));
						IF (td # NIL) & GetStr(td, "uri", uri) & GetStr(td, "text", text) THEN
							PutDoc(uri^, text^); PublishFor(out, uri)
						END
					ELSIF method^ = "textDocument/didChange" THEN
						(* keep the buffer text current but do NOT re-diagnose on every
						   keystroke: compiling per change is too heavy and produces
						   flickering/stale transient errors. Diagnostics refresh on
						   open and on save (below). *)
						td := AsObject(params.Get("textDocument"));
						changes := params.Get("contentChanges");
						IF (td # NIL) & GetStr(td, "uri", uri) & (changes # NIL) & (changes IS JSON.Array) THEN
							arr := changes(JSON.Array); first := arr.At(0);
							IF (first # NIL) & GetStr(AsObject(first), "text", text) THEN
								PutDoc(uri^, text^);
								IF live THEN PublishFor(out, uri) END
							END
						END
					ELSIF method^ = "textDocument/didSave" THEN
						td := AsObject(params.Get("textDocument"));
						(* didSave may carry the saved text; use it if present *)
						IF (td # NIL) & GetStr(td, "uri", uri) THEN
							IF GetStr(params, "text", text) THEN PutDoc(uri^, text^) END;
							PublishFor(out, uri)
						END
					ELSIF method^ = "textDocument/didClose" THEN
						td := AsObject(params.Get("textDocument"));
						IF (td # NIL) & GetStr(td, "uri", uri) THEN
							RemoveDoc(uri^); PublishFor(out, uri)   (* empty diagnostics *)
						END
					ELSIF method^ = "textDocument/hover" THEN
						td := AsObject(params.Get("textDocument"));
						pos := AsObject(params.Get("position"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) & (pos # NIL)
							& GetInt(pos, "line", line) & GetInt(pos, "character", char) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := HoverAt(doc.text, PosToOffset(doc.text, line, char)) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/definition" THEN
						td := AsObject(params.Get("textDocument"));
						pos := AsObject(params.Get("position"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) & (pos # NIL)
							& GetInt(pos, "line", line) & GetInt(pos, "character", char) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := DefinitionAt(doc.text, PosToOffset(doc.text, line, char), uri) END
						END;
						Respond(out, req.Get("id"), res)
					ELSE
						(* unknown: answer requests with null so clients don't hang *)
						Respond(out, req.Get("id"), NIL)
					END
				END
			END
		END
	END Serve;

	(** `oberon LSP.Run` — diagnostics on open + save (default, stable). *)
	PROCEDURE Run* (context: Commands.Context);
	BEGIN Serve(context, FALSE) END Run;

	(** `oberon LSP.RunLive` — also re-diagnose on every change (client debounces). *)
	PROCEDURE RunLive* (context: Commands.Context);
	BEGIN Serve(context, TRUE) END RunLive;

END LSP.
