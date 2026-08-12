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

IMPORT Streams, Strings, Files, JSON, Diagnostics, Compiler, SyntaxTree := FoxSyntaxTree, Commands,
	FoxScanner, FoxParser, FoxSemanticChecker, FoxGlobal, FoxBasic, Printout := FoxPrintout;

CONST
	CR = 0DX; LF = 0AX;

TYPE
	Document = OBJECT
	VAR next: Document; uri: Strings.String; text: Strings.String;
	END Document;

	(* Locates the innermost resolved use-site whose token span contains a byte offset.
	   A use-site is either a SymbolDesignator (in executable code) or a QualifiedType
	   (a type annotation in a declaration: VAR/field/parameter/return/base types). The
	   result is the referenced symbol plus the use-site's name position (for the hover
	   highlight). Smaller spans win, so the innermost reference is preferred. *)
	Finder = OBJECT
	VAR foundSym: SyntaxTree.Symbol; foundStart: SIGNED64; foundNameLen: SIZE;
		bestSpan: SIZE; target: SIGNED64; hasFound: BOOLEAN;
		(* collect mode (find-all-references): gather every use-site matching a key.
		   tokenize mode (semantic tokens): gather EVERY resolved occurrence + its class. *)
		collect, tokenize: BOOLEAN; keyName, keyOwner: ARRAY 128 OF CHAR; keyKind: SIGNED32;
		(* Non-NIL narrows the key to one declaring scope, so that a local `i` in one
		   procedure is not confused with an unrelated local `i` in its sibling. Only
		   usable within the module the scope was taken from, hence NIL for the
		   cross-file sweep, which visits module-level symbols only. *)
		keyScope: SyntaxTree.Scope;
		refOff: ARRAY 16384 OF SIGNED64; refLen, refKind: ARRAY 16384 OF SIGNED32; refN: SIGNED32;

		(* LSP semantic-token type index (see the legend in Serve), or -1 to skip. *)
		PROCEDURE SemKind (sym: SyntaxTree.Symbol): SIGNED32;
		VAR k: SIGNED32; inRec: BOOLEAN;
		BEGIN
			k := -1; inRec := (sym.scope # NIL) & (sym.scope IS SyntaxTree.RecordScope);
			WITH sym:
				  SyntaxTree.Module DO k := 0
				| SyntaxTree.Import DO k := 0
				| SyntaxTree.TypeDeclaration DO k := 1
				| SyntaxTree.Procedure DO IF inRec THEN k := 7 ELSE k := 2 END
				| SyntaxTree.Variable DO IF inRec THEN k := 6 ELSE k := 3 END
				| SyntaxTree.Parameter DO k := 4
				| SyntaxTree.Constant DO k := 5
			ELSE
			END;
			RETURN k
		END SemKind;

		(* Coarse symbol class, to disambiguate same-named symbols. *)
		PROCEDURE KindOf (sym: SyntaxTree.Symbol): SIGNED32;
		VAR k: SIGNED32;
		BEGIN
			k := 0;
			WITH sym:
				  SyntaxTree.Procedure DO k := 1
				| SyntaxTree.Variable DO k := 2
				| SyntaxTree.Parameter DO k := 2
				| SyntaxTree.TypeDeclaration DO k := 3
				| SyntaxTree.Constant DO k := 4
			ELSE
			END;
			RETURN k
		END KindOf;

		PROCEDURE SymMatches (sym: SyntaxTree.Symbol): BOOLEAN;
		VAR nm, onm: ARRAY 128 OF CHAR;
		BEGIN
			sym.GetName(nm); IF nm # keyName THEN RETURN FALSE END;
			IF (sym.scope = NIL) OR (sym.scope.ownerModule = NIL) THEN RETURN FALSE END;
			IF keyScope # NIL THEN RETURN sym.scope = keyScope END;
			sym.scope.ownerModule.GetName(onm);
			RETURN (onm = keyOwner) & (KindOf(sym) = keyKind)
		END SymMatches;

		(* Record a candidate hit: matchStart/matchSpan is the clickable span; hitStart/
		   nameLen is the name token to highlight (the two differ for qualified refs).
		   In collect mode, every match of the key is recorded; otherwise the innermost
		   hit containing `target`. *)
		PROCEDURE Hit (sym: SyntaxTree.Symbol; matchStart: SIGNED64; matchSpan: SIZE; hitStart: SIGNED64; nameLen: SIZE);
		BEGIN
			IF sym = NIL THEN RETURN END;
			IF tokenize THEN
				IF (hitStart >= 0) & (refN < LEN(refOff)) THEN
					IF SemKind(sym) >= 0 THEN
						refOff[refN] := hitStart; refLen[refN] := SIGNED32(nameLen);
						refKind[refN] := SemKind(sym); INC(refN)
					END
				END
			ELSIF collect THEN
				IF (hitStart >= 0) & (refN < LEN(refOff)) & SymMatches(sym) THEN
					refOff[refN] := hitStart; refLen[refN] := SIGNED32(nameLen); INC(refN)
				END
			ELSIF (matchStart >= 0) & (target >= matchStart) & (target < matchStart + matchSpan) THEN
				IF ~hasFound OR (matchSpan < bestSpan) THEN
					hasFound := TRUE; bestSpan := matchSpan;
					foundSym := sym; foundStart := hitStart; foundNameLen := nameLen
				END
			END
		END Hit;

		PROCEDURE Consider (d: SyntaxTree.SymbolDesignator);
		VAR span: SIZE; nm: ARRAY 128 OF CHAR;
		BEGIN
			IF d.symbol = NIL THEN RETURN END;
			d.symbol.GetName(nm); span := Strings.Length(nm);
			Hit(d.symbol, d.position.start, span, d.position.start, span)
		END Consider;

		(* Type annotation reference: match anywhere on "prefix.suffix", highlight the
		   suffix (the type name), resolve to the referenced type declaration. *)
		PROCEDURE ConsiderType (qt: SyntaxTree.QualifiedType);
		VAR qi: SyntaxTree.QualifiedIdentifier; td: SyntaxTree.TypeDeclaration;
			pnm, snm: ARRAY 128 OF CHAR; plen, slen: SIZE;
		BEGIN
			(* the type reference's OWN declaration (e.g. the alias NbrInt.Integer), not the
			   fully-resolved underlying type whose typeDeclaration may be NIL for a builtin *)
			td := qt.typeDeclaration;
			IF (td = NIL) & (qt.resolvedType # NIL) THEN td := qt.resolvedType.typeDeclaration END;
			IF td = NIL THEN RETURN END;
			qi := qt.qualifiedIdentifier; IF qi = NIL THEN RETURN END;
			(* GetString on an invalid string index would index the pool out of range *)
			IF qi.suffix = FoxBasic.invalidString THEN RETURN END;
			FoxBasic.GetString(qi.suffix, snm); slen := Strings.Length(snm);
			IF qi.prefix # FoxBasic.invalidString THEN
				FoxBasic.GetString(qi.prefix, pnm); plen := Strings.Length(pnm);
				Hit(td, qi.position.start, plen + 1 + slen, qi.position.start + plen + 1, slen)
			ELSE
				Hit(td, qi.position.start, slen, qi.position.start, slen)
			END
		END ConsiderType;

		(* Recurse a type structure, considering every qualified reference within it. *)
		PROCEDURE WType (t: SyntaxTree.Type);
		VAR p: SyntaxTree.Parameter;
		BEGIN
			IF t = NIL THEN RETURN END;
			WITH t:
				  SyntaxTree.QualifiedType DO ConsiderType(t)
				| SyntaxTree.ArrayType DO WType(t.arrayBase)
				| SyntaxTree.MathArrayType DO WType(t.arrayBase)
				| SyntaxTree.PointerType DO WType(t.pointerBase)
				| SyntaxTree.RecordType DO
					WType(t.baseType);
					WScope(t.recordScope)   (* record/object fields live in their own scope *)
				| SyntaxTree.ProcedureType DO
					p := t.firstParameter;
					WHILE p # NIL DO WType(p.type); p := p.nextParameter END;
					WType(t.returnType)
			ELSE
			END
		END WType;

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

		(* Recurse the whole scope tree. Per scope: (1) walk declaration-site type
		   annotations of its symbols (variables, fields, parameters, procedure
		   signatures, declared types' base/element types); (2) walk procedure/method
		   bodies. This covers module procedures, nested procedures, AND members
		   declared inside OBJECT/RECORD types (whose scopes are nested scopes). *)
		PROCEDURE WScope (scope: SyntaxTree.Scope);
		VAR ns: SyntaxTree.Scope; sym: SyntaxTree.Symbol; dnm: ARRAY 128 OF CHAR;
		BEGIN
			IF scope = NIL THEN RETURN END;
			sym := scope.firstSymbol;
			WHILE sym # NIL DO
				(* the declaration's own name is also a resolvable site (so hover /
				   definition / references work when the cursor is on the declaration) *)
				sym.GetName(dnm);
				IF (dnm[0] # "@") & (sym.position.line > 0) THEN
					Hit(sym, sym.position.start, Strings.Length(dnm), sym.position.start, Strings.Length(dnm))
				END;
				WITH sym:
					  SyntaxTree.Variable DO WType(sym.type)
					| SyntaxTree.Parameter DO WType(sym.type)
					| SyntaxTree.TypeDeclaration DO WType(sym.declaredType)
					| SyntaxTree.Procedure DO WType(sym.type)
				ELSE
				END;
				sym := sym.nextSymbol
			END;
			WITH scope: SyntaxTree.ProcedureScope DO
				IF scope.body # NIL THEN WSeq(scope.body.statements) END
			ELSE
			END;
			ns := scope.firstScope;
			WHILE ns # NIL DO WScope(ns); ns := ns.nextScope END
		END WScope;

		PROCEDURE Traverse (module: SyntaxTree.Module);
		VAR ms: SyntaxTree.ModuleScope;
		BEGIN
			IF module = NIL THEN RETURN END;
			ms := module.moduleScope;
			WScope(ms);
			IF (ms.bodyProcedure # NIL) & (ms.bodyProcedure.procedureScope # NIL)
				& (ms.bodyProcedure.procedureScope.body # NIL) THEN
				WSeq(ms.bodyProcedure.procedureScope.body.statements)
			END
		END Traverse;

		PROCEDURE Find (module: SyntaxTree.Module; offset: SIGNED64): BOOLEAN;
		BEGIN
			collect := FALSE; tokenize := FALSE; hasFound := FALSE; bestSpan := 0; target := offset;
			foundSym := NIL; foundStart := 0; foundNameLen := 0;
			Traverse(module);
			RETURN hasFound
		END Find;

		(* Collect every use-site of the symbol identified by (name, owner, kind), or by
		   its declaring scope when `scope` is given (see keyScope). *)
		PROCEDURE CollectRefs (module: SyntaxTree.Module; CONST name, owner: ARRAY OF CHAR; kind: SIGNED32;
			scope: SyntaxTree.Scope);
		BEGIN
			collect := TRUE; tokenize := FALSE; COPY(name, keyName); COPY(owner, keyOwner); keyKind := kind;
			keyScope := scope; refN := 0;
			Traverse(module);
			collect := FALSE; keyScope := NIL
		END CollectRefs;

		(* Collect every resolved occurrence + its semantic class. *)
		PROCEDURE CollectTokens (module: SyntaxTree.Module);
		BEGIN
			tokenize := TRUE; collect := FALSE; refN := 0;
			Traverse(module);
			tokenize := FALSE
		END CollectTokens;
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

	(* Builds a hierarchical textDocument/documentSymbol tree (LSP DocumentSymbol[]) of
	   a freshly-analyzed module: the module as root, then its types (with their fields
	   and methods as children), procedures, variables and constants. Positions come
	   from the fresh analysis, so they are reliable. Self-contained (no module-level
	   proc calls) so it can live in the type section. *)
	Outliner = OBJECT

		PROCEDURE Pos (line, char: SIGNED32): JSON.Object;
		VAR o: JSON.Object;
		BEGIN
			o := JSON.NewObject();
			o.Set("line", JSON.NewNumber(line));
			o.Set("character", JSON.NewNumber(char));
			RETURN o
		END Pos;

		PROCEDURE Range (sym: SyntaxTree.Symbol): JSON.Object;
		VAR line, char, len: SIGNED32; nm: ARRAY 128 OF CHAR; r: JSON.Object;
		BEGIN
			IF sym.position.line > 0 THEN
				line := SIGNED32(sym.position.line) - 1;
				char := SIGNED32(sym.position.start - sym.position.linepos)
			ELSE line := 0; char := 0 END;
			sym.GetName(nm); len := SIGNED32(Strings.Length(nm));
			r := JSON.NewObject();
			r.Set("start", Pos(line, char));
			r.Set("end", Pos(line, char + len));
			RETURN r
		END Range;

		PROCEDURE Node (sym: SyntaxTree.Symbol; kind: SIGNED32; children: JSON.Array): JSON.Object;
		VAR nm: ARRAY 128 OF CHAR; o: JSON.Object;
		BEGIN
			sym.GetName(nm);
			o := JSON.NewObject();
			o.Set("name", JSON.NewString(nm));
			o.Set("kind", JSON.NewNumber(kind));
			o.Set("range", Range(sym));
			o.Set("selectionRange", Range(sym));   (* fresh object; must be within range *)
			IF children # NIL THEN o.Set("children", children) END;
			RETURN o
		END Node;

		PROCEDURE RecordScopeOf (t: SyntaxTree.Type): SyntaxTree.Scope;
		BEGIN
			IF t = NIL THEN RETURN NIL END;
			IF t IS SyntaxTree.PointerType THEN t := t(SyntaxTree.PointerType).pointerBase END;
			IF (t # NIL) & (t IS SyntaxTree.RecordType) THEN RETURN t(SyntaxTree.RecordType).recordScope END;
			RETURN NIL
		END RecordScopeOf;

		(* record/object members: fields (kind Field=8) and methods (kind Method=6) *)
		PROCEDURE Members (scope: SyntaxTree.Scope): JSON.Array;
		VAR arr: JSON.Array; sym: SyntaxTree.Symbol; nm: ARRAY 128 OF CHAR;
		BEGIN
			arr := JSON.NewArray();
			IF scope = NIL THEN RETURN arr END;
			sym := scope.firstSymbol;
			WHILE sym # NIL DO
				sym.GetName(nm);
				IF (nm[0] # "@") & (sym.position.line > 0) THEN
					WITH sym:
						  SyntaxTree.Variable DO arr.Add(Node(sym, 8, NIL))
						| SyntaxTree.Procedure DO arr.Add(Node(sym, 6, NIL))
					ELSE
					END
				END;
				sym := sym.nextSymbol
			END;
			RETURN arr
		END Members;

		(* top-level module members; types carry their record/object members as children *)
		PROCEDURE TopLevel (scope: SyntaxTree.Scope): JSON.Array;
		VAR arr, ch: JSON.Array; sym: SyntaxTree.Symbol; nm: ARRAY 128 OF CHAR; rs: SyntaxTree.Scope;
		BEGIN
			arr := JSON.NewArray();
			IF scope = NIL THEN RETURN arr END;
			sym := scope.firstSymbol;
			WHILE sym # NIL DO
				sym.GetName(nm);
				IF (nm[0] # "@") & (sym.position.line > 0) THEN
					WITH sym:
						  SyntaxTree.TypeDeclaration DO
							rs := RecordScopeOf(sym.declaredType);
							IF rs # NIL THEN ch := Members(rs) ELSE ch := NIL END;
							arr.Add(Node(sym, 5, ch))
						| SyntaxTree.Procedure DO arr.Add(Node(sym, 12, NIL))
						| SyntaxTree.Variable DO arr.Add(Node(sym, 13, NIL))
						| SyntaxTree.Constant DO arr.Add(Node(sym, 14, NIL))
					ELSE
					END
				END;
				sym := sym.nextSymbol
			END;
			RETURN arr
		END TopLevel;

		PROCEDURE Module (module: SyntaxTree.Module): JSON.Array;
		VAR arr: JSON.Array;
		BEGIN
			arr := JSON.NewArray();
			IF module = NIL THEN RETURN arr END;
			arr.Add(Node(module, 2, TopLevel(module.moduleScope)));   (* kind Module=2 *)
			RETURN arr
		END Module;
	END Outliner;

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

	(* The directory of an open document, with its trailing slash, taken from the document's
	   own URI. The sweep over a project's other modules used to enumerate "./*.Mod", which
	   is the process's working directory -- and `ob lsp` sets that to a scratch directory,
	   so under the SDK the sweep listed an empty directory and every rename across files
	   quietly edited nothing but the declaration. What the editor has open is the one
	   directory we can always name. Returns FALSE for a URI with no path or no scheme we
	   understand, and the caller then falls back to the working directory. *)
	PROCEDURE DocumentDir (uri: Strings.String; VAR dir: ARRAY OF CHAR): BOOLEAN;
	CONST scheme = "file://";
	VAR i, from, last, n: SIZE;
	BEGIN
		IF uri = NIL THEN RETURN FALSE END;
		from := 0; i := 0;
		WHILE (scheme[i] # 0X) & (uri[i] = scheme[i]) DO INC(i) END;
		IF scheme[i] = 0X THEN from := i ELSIF uri[0] # "/" THEN RETURN FALSE END;
		last := -1; i := from;
		WHILE uri[i] # 0X DO IF uri[i] = "/" THEN last := i END; INC(i) END;
		IF last < from THEN RETURN FALSE END;
		n := 0; i := from;
		WHILE (i <= last) & (n < LEN(dir)-1) DO dir[n] := uri[i]; INC(n); INC(i) END;
		dir[n] := 0X;
		RETURN n > 0
	END DocumentDir;

	(* Mask for enumerating the other modules beside `uri`, and the prefix to read them by. *)
	PROCEDURE SiblingMask (uri: Strings.String; VAR mask, prefix: ARRAY OF CHAR);
	BEGIN
		IF DocumentDir(uri, prefix) THEN
			COPY(prefix, mask); Strings.Append(mask, "*.Mod")
		ELSE
			(* RelativeFileSystem needs the ./ prefix *)
			COPY("./", prefix); COPY("./*.Mod", mask)
		END
	END SiblingMask;

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

	(* Reads one framed message. `alive` says whether the stream is still usable: it is
	   FALSE only for end of input or a header we cannot make sense of, and TRUE with a NIL
	   result for a message whose body is not JSON -- the frame gave its length, so exactly
	   that many bytes were consumed and the next message is still where it should be. One
	   bad message from an editor is not a reason to drop the session. *)
	PROCEDURE ReadMessage (in: Streams.Reader; VAR alive: BOOLEAN): JSON.Value;
	VAR line: ARRAY 256 OF CHAR; n, got: SIGNED32; len: SIZE;
		buf: POINTER TO ARRAY OF CHAR; v: JSON.Value; ok: BOOLEAN;
	BEGIN
		alive := FALSE; n := -1;
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
		alive := TRUE;                                (* the frame was whole, whatever it held *)
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

	(* Map the compiler's internal basic-type name to the source keyword. *)
	PROCEDURE BasicName (CONST s: ARRAY OF CHAR; VAR o: ARRAY OF CHAR);
	BEGIN
		IF s = "@Integer8" THEN COPY("SIGNED8", o)
		ELSIF s = "@Integer16" THEN COPY("SIGNED16", o)
		ELSIF s = "@Integer32" THEN COPY("SIGNED32", o)
		ELSIF s = "@Integer64" THEN COPY("SIGNED64", o)
		ELSIF s = "@Unsigned8" THEN COPY("UNSIGNED8", o)
		ELSIF s = "@Unsigned16" THEN COPY("UNSIGNED16", o)
		ELSIF s = "@Unsigned32" THEN COPY("UNSIGNED32", o)
		ELSIF s = "@Unsigned64" THEN COPY("UNSIGNED64", o)
		ELSIF s = "@Boolean8" THEN COPY("BOOLEAN", o)
		ELSIF s = "@Character8" THEN COPY("CHAR", o)
		ELSIF s = "@Character16" THEN COPY("CHAR16", o)
		ELSIF s = "@Character32" THEN COPY("CHAR32", o)
		ELSIF s = "@Float32" THEN COPY("FLOAT32", o)
		ELSIF s = "@Float64" THEN COPY("FLOAT64", o)
		ELSIF (s = "@Set8") OR (s = "@Set16") OR (s = "@Set32") OR (s = "@Set64") THEN COPY("SET", o)
		ELSIF (s = "@Size32") OR (s = "@Size64") THEN COPY("SIZE", o)
		ELSIF s = "ADDRESSTYPE" THEN COPY("ADDRESS", o)
		ELSE COPY(s, o)
		END
	END BasicName;

	(* Concise, readable type name — a reference, not a structural dump. Named types
	   become "Owner.Name"; composite types recurse; basic types map to keywords. *)
	PROCEDURE TypeToStr (t: SyntaxTree.Type): Strings.String;
	VAR buf: Streams.Buffer; w: Streams.Writer; p: Printout.Printer;
		td: SyntaxTree.TypeDeclaration; par: SyntaxTree.Parameter; sub: Strings.String;
		res, tmp: ARRAY 1024 OF CHAR; first: BOOLEAN;
	BEGIN
		IF t = NIL THEN RETURN NIL END;
		t := t.resolvedType; IF t = NIL THEN RETURN NIL END;
		td := t.typeDeclaration;
		IF td # NIL THEN
			res[0] := 0X;
			IF (td.scope # NIL) & (td.scope.ownerModule # NIL) THEN
				td.scope.ownerModule.GetName(tmp);
				IF tmp[0] # 0X THEN Strings.Append(res, tmp); Strings.Append(res, ".") END
			END;
			td.GetName(tmp); Strings.Append(res, tmp);
			RETURN Strings.NewString(res)
		END;
		WITH t:
			  SyntaxTree.PointerType DO
				COPY("POINTER TO ", res); sub := TypeToStr(t.pointerBase);
				IF sub # NIL THEN Strings.Append(res, sub^) END; RETURN Strings.NewString(res)
			| SyntaxTree.ArrayType DO
				COPY("ARRAY OF ", res); sub := TypeToStr(t.arrayBase);
				IF sub # NIL THEN Strings.Append(res, sub^) END; RETURN Strings.NewString(res)
			| SyntaxTree.MathArrayType DO
				COPY("ARRAY OF ", res); sub := TypeToStr(t.arrayBase);
				IF sub # NIL THEN Strings.Append(res, sub^) END; RETURN Strings.NewString(res)
			| SyntaxTree.RecordType DO
				RETURN Strings.NewString("RECORD")
			| SyntaxTree.ProcedureType DO
				COPY("PROCEDURE(", res); par := t.firstParameter; first := TRUE;
				WHILE par # NIL DO
					IF ~first THEN Strings.Append(res, "; ") END;
					par.GetName(tmp); Strings.Append(res, tmp);
					sub := TypeToStr(par.type);
					IF sub # NIL THEN Strings.Append(res, ": "); Strings.Append(res, sub^) END;
					first := FALSE; par := par.nextParameter
				END;
				Strings.Append(res, ")");
				sub := TypeToStr(t.returnType);
				IF sub # NIL THEN Strings.Append(res, ": "); Strings.Append(res, sub^) END;
				RETURN Strings.NewString(res)
		ELSE
			NEW(buf, 128); w := buf.GetWriter(); p := Printout.NewPrinter(w, Printout.SourceCode, FALSE);
			p.Type(t); w.Update; sub := buf.GetString();
			IF sub = NIL THEN RETURN NIL END;
			BasicName(sub^, res); RETURN Strings.NewString(res)
		END
	END TypeToStr;

	PROCEDURE TypeStr (sym: SyntaxTree.Symbol): Strings.String;
	BEGIN
		IF sym IS SyntaxTree.TypeDeclaration THEN
			RETURN TypeToStr(sym(SyntaxTree.TypeDeclaration).declaredType)
		ELSE
			RETURN TypeToStr(sym.type)
		END
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
	VAR module: SyntaxTree.Module; f: Finder; sym: SyntaxTree.Symbol;
		nm: ARRAY 128 OF CHAR; kd: ARRAY 16 OF CHAR; ts: Strings.String; lf: ARRAY 2 OF CHAR;
		val: ARRAY 1024 OF CHAR; contents, range, result: JSON.Object; line, char: SIGNED32;
	BEGIN
		module := Analyze(text); IF module = NIL THEN RETURN NIL END;
		NEW(f); IF ~f.Find(module, offset) THEN RETURN NIL END;
		sym := f.foundSym; sym.GetName(nm); Kind(sym, kd); ts := TypeStr(sym);
		COPY(kd, val); Strings.Append(val, " "); Strings.Append(val, nm);
		IF ts # NIL THEN Strings.Append(val, " : "); Strings.Append(val, ts^) END;
		IF sym.comment # NIL THEN lf[0] := LF; lf[1] := 0X; Strings.Append(val, lf); Strings.Append(val, sym.comment.source^) END;
		contents := JSON.NewObject();
		contents.Set("kind", JSON.NewString("plaintext"));
		contents.Set("value", JSON.NewString(val));
		OffsetToPos(text, f.foundStart, line, char);
		range := JSON.NewObject();
		range.Set("start", Position(line, char));
		range.Set("end", Position(line, char + SIGNED32(f.foundNameLen)));
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
	VAR module, owner: SyntaxTree.Module; f: Finder; sym: SyntaxTree.Symbol;
		nm, mname: ARRAY 128 OF CHAR; loc, range: JSON.Object; line, char: SIGNED32; targetUri: Strings.String;
	BEGIN
		module := Analyze(text); IF module = NIL THEN RETURN NIL END;
		NEW(f); IF ~f.Find(module, offset) THEN RETURN NIL END;
		sym := f.foundSym;
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

	(* textDocument/documentSymbol: the module's symbol tree (outline). *)
	PROCEDURE DocumentSymbols (text: Strings.String): JSON.Value;
	VAR module: SyntaxTree.Module; o: Outliner;
	BEGIN
		module := Analyze(text); IF module = NIL THEN RETURN JSON.NewArray() END;
		NEW(o); RETURN o.Module(module)
	END DocumentSymbols;

	(* ---- completion ---- *)

	PROCEDURE IsIdentChar (ch: CHAR): BOOLEAN;
	BEGIN
		RETURN ((ch >= "a") & (ch <= "z")) OR ((ch >= "A") & (ch <= "Z"))
			OR ((ch >= "0") & (ch <= "9")) OR (ch = "_")
	END IsIdentChar;

	(* Lexical context at the cursor (robust to invalid source): the partial word being
	   typed, and — if it is immediately preceded by "." — the qualifier identifier. *)
	PROCEDURE CompletionContext (text: Strings.String; offset: SIGNED64;
		VAR isDot: BOOLEAN; VAR qual, part: ARRAY OF CHAR; VAR partStart, qualStart: SIGNED64);
	VAR i, ps, qe, qs, k: SIZE;
	BEGIN
		isDot := FALSE; qual[0] := 0X; part[0] := 0X; qualStart := 0;
		IF text = NIL THEN partStart := offset; RETURN END;
		i := SIZE(offset);
		ps := i;
		WHILE (ps > 0) & IsIdentChar(text[ps-1]) DO DEC(ps) END;
		partStart := ps;
		k := 0; WHILE (ps + k < i) & (k < LEN(part)-1) DO part[k] := text[ps+k]; INC(k) END;
		part[k] := 0X;
		IF (ps > 0) & (text[ps-1] = ".") THEN
			isDot := TRUE; qe := ps - 1; qs := qe;
			WHILE (qs > 0) & IsIdentChar(text[qs-1]) DO DEC(qs) END;
			qualStart := qs;
			k := 0; WHILE (qs + k < qe) & (k < LEN(qual)-1) DO qual[k] := text[qs+k]; INC(k) END;
			qual[k] := 0X
		END
	END CompletionContext;

	(* text with the partial word [partStart, offset) replaced by a dummy identifier, so
	   an otherwise-incomplete "qualifier." parses and the qualifier can be resolved. *)
	PROCEDURE WithDummy (text: Strings.String; partStart, offset: SIGNED64): Strings.String;
	VAR buf: Streams.Buffer; w: Streams.Writer; i: SIZE;
	BEGIN
		NEW(buf, 4096); w := buf.GetWriter();
		FOR i := 0 TO SIZE(partStart) - 1 DO w.Char(text[i]) END;
		w.String("Cmpl0Dummy");
		i := SIZE(offset);
		WHILE text[i] # 0X DO w.Char(text[i]); INC(i) END;
		w.Update; RETURN buf.GetString()
	END WithDummy;

	(* Parse-only (imports are at the top and parse even when the body is invalid). *)
	PROCEDURE ParsedModule (text: Strings.String): SyntaxTree.Module;
	VAR srcR: Streams.StringReader; diag: Diagnostics.DiagnosticsList;
		scanner: FoxScanner.Scanner; parser: FoxParser.Parser;
	BEGIN
		IF text = NIL THEN RETURN NIL END;
		NEW(diag); Streams.OpenStringReader(srcR, text^);
		scanner := FoxScanner.NewScanner("source", srcR, 0, diag);
		parser := FoxParser.NewParser(scanner, diag, "");
		RETURN parser.Module()
	END ParsedModule;

	(* Map a qualifier (local import name / alias) to the real module name. *)
	PROCEDURE ImportRealName (module: SyntaxTree.Module; CONST qual: ARRAY OF CHAR; VAR real: ARRAY OF CHAR): BOOLEAN;
	VAR imp: SyntaxTree.Import; nm: ARRAY 128 OF CHAR;
	BEGIN
		IF module = NIL THEN RETURN FALSE END;
		imp := module.moduleScope.firstImport;
		WHILE imp # NIL DO
			imp.GetName(nm);
			IF nm = qual THEN FoxBasic.GetString(imp.moduleName, real); RETURN TRUE END;
			imp := imp.nextImport
		END;
		RETURN FALSE
	END ImportRealName;

	(* The module scope (exported symbols, from its .SymUu) of module <name>. *)
	PROCEDURE ModuleScopeOf (CONST name: ARRAY OF CHAR): SyntaxTree.Scope;
	VAR synth: ARRAY 512 OF CHAR; module: SyntaxTree.Module; imp: SyntaxTree.Import;
	BEGIN
		COPY("MODULE Cmpl0; IMPORT ", synth);
		Strings.Append(synth, name); Strings.Append(synth, "; END Cmpl0.");
		module := Analyze(Strings.NewString(synth));
		IF module = NIL THEN RETURN NIL END;
		imp := module.moduleScope.firstImport;
		IF (imp # NIL) & (imp.module # NIL) THEN RETURN imp.module.moduleScope END;
		RETURN NIL
	END ModuleScopeOf;

	PROCEDURE CompletionKind (sym: SyntaxTree.Symbol): SIGNED32;
	VAR k: SIGNED32;
	BEGIN
		k := 1;   (* Text *)
		WITH sym:
			  SyntaxTree.Module DO k := 9
			| SyntaxTree.TypeDeclaration DO k := 7    (* Class *)
			| SyntaxTree.Constant DO k := 21          (* Constant *)
			| SyntaxTree.Procedure DO k := 3          (* Function *)
			| SyntaxTree.Variable DO k := 6           (* Variable *)
			| SyntaxTree.Parameter DO k := 6
		ELSE
		END;
		RETURN k
	END CompletionKind;

	PROCEDURE CompletionItem (sym: SyntaxTree.Symbol): JSON.Object;
	VAR o: JSON.Object; nm: ARRAY 128 OF CHAR; ts: Strings.String;
	BEGIN
		sym.GetName(nm);
		o := JSON.NewObject();
		o.Set("label", JSON.NewString(nm));
		o.Set("kind", JSON.NewNumber(CompletionKind(sym)));
		ts := TypeStr(sym);
		IF ts # NIL THEN o.Set("detail", JSON.NewString(ts^)) END;
		RETURN o
	END CompletionItem;

	PROCEDURE AddScopeSymbols (arr: JSON.Array; scope: SyntaxTree.Scope);
	VAR sym: SyntaxTree.Symbol; nm: ARRAY 128 OF CHAR;
	BEGIN
		IF scope = NIL THEN RETURN END;
		sym := scope.firstSymbol;
		WHILE sym # NIL DO
			sym.GetName(nm);
			IF (nm[0] # "@") & ~(sym IS SyntaxTree.Import) THEN arr.Add(CompletionItem(sym)) END;
			sym := sym.nextSymbol
		END
	END AddScopeSymbols;

	(* Add fields and methods of a record/object type (following the base-type chain). *)
	PROCEDURE AddTypeMembers (arr: JSON.Array; t: SyntaxTree.Type);
	VAR rec: SyntaxTree.RecordType; depth: SIGNED32;
	BEGIN
		depth := 0;
		WHILE (t # NIL) & (depth < 16) DO
			t := t.resolvedType;
			IF (t # NIL) & (t IS SyntaxTree.PointerType) THEN
				t := t(SyntaxTree.PointerType).pointerBase;
				IF t # NIL THEN t := t.resolvedType END
			END;
			IF (t # NIL) & (t IS SyntaxTree.RecordType) THEN
				rec := t(SyntaxTree.RecordType);
				AddScopeSymbols(arr, rec.recordScope);
				t := rec.baseType
			ELSE
				t := NIL
			END;
			INC(depth)
		END
	END AddTypeMembers;

	PROCEDURE AddImportNames (arr: JSON.Array; module: SyntaxTree.Module);
	VAR imp: SyntaxTree.Import; nm: ARRAY 128 OF CHAR; o: JSON.Object;
	BEGIN
		IF module = NIL THEN RETURN END;
		imp := module.moduleScope.firstImport;
		WHILE imp # NIL DO
			imp.GetName(nm);
			IF nm[0] # "@" THEN
				o := JSON.NewObject();
				o.Set("label", JSON.NewString(nm)); o.Set("kind", JSON.NewNumber(9));  (* Module *)
				arr.Add(o)
			END;
			imp := imp.nextImport
		END
	END AddImportNames;

	PROCEDURE AddKeywords (arr: JSON.Array);
		PROCEDURE K (CONST s: ARRAY OF CHAR);
		VAR o: JSON.Object;
		BEGIN
			o := JSON.NewObject();
			o.Set("label", JSON.NewString(s)); o.Set("kind", JSON.NewNumber(14));  (* Keyword *)
			arr.Add(o)
		END K;
	BEGIN
		K("ARRAY"); K("AWAIT"); K("BEGIN"); K("BY"); K("CASE"); K("CONST"); K("DEFINITION");
		K("DIV"); K("DO"); K("ELSE"); K("ELSIF"); K("END"); K("ENUM"); K("EXIT"); K("EXTERN");
		K("FALSE"); K("FINALLY"); K("FOR"); K("IF"); K("IGNORE"); K("IMPORT"); K("IN"); K("IS");
		K("LOOP"); K("MOD"); K("MODULE"); K("NEW"); K("NIL"); K("OBJECT"); K("OF"); K("OPERATOR");
		K("OR"); K("OUT"); K("POINTER"); K("PROCEDURE"); K("RECORD"); K("REPEAT"); K("RETURN");
		K("SELF"); K("THEN"); K("TO"); K("TRUE"); K("TYPE"); K("UNTIL"); K("VAR"); K("WHILE"); K("WITH");
		K("BOOLEAN"); K("CHAR"); K("INTEGER"); K("LONGINT"); K("HUGEINT"); K("REAL"); K("LONGREAL");
		K("SET"); K("SIZE"); K("ADDRESS"); K("SIGNED8"); K("SIGNED16"); K("SIGNED32"); K("SIGNED64");
		K("UNSIGNED8"); K("UNSIGNED16"); K("UNSIGNED32"); K("UNSIGNED64"); K("ANY")
	END AddKeywords;

	(* textDocument/completion: after "Mod." -> that module's exported symbols; otherwise
	   keywords + imported module names + this module's top-level declarations. *)
	PROCEDURE CompletionAt (text: Strings.String; offset: SIGNED64): JSON.Value;
	VAR isDot: BOOLEAN; qual, part, real: ARRAY 256 OF CHAR; partStart, qualStart: SIGNED64;
		arr: JSON.Array; pm, am: SyntaxTree.Module; scope: SyntaxTree.Scope; ds: DeclScan; sym: SyntaxTree.Symbol;
	BEGIN
		arr := JSON.NewArray();
		CompletionContext(text, offset, isDot, qual, part, partStart, qualStart);
		IF isDot THEN
			IF qual[0] = 0X THEN RETURN arr END;
			pm := ParsedModule(text);
			IF (pm # NIL) & ImportRealName(pm, qual, real) THEN
				scope := ModuleScopeOf(real);            (* Mod. -> module's exported symbols *)
				AddScopeSymbols(arr, scope)
			ELSE
				(* variable/field . -> members of its record/object type. Insert a dummy
				   identifier so the incomplete "qualifier." parses, then resolve the
				   qualifier by name (a failed selector doesn't keep a findable use-site). *)
				am := Analyze(WithDummy(text, partStart, offset));
				IF am # NIL THEN
					NEW(ds); sym := ds.Find(am, qual);
					IF sym # NIL THEN AddTypeMembers(arr, sym.type) END
				END
			END
		ELSE
			AddKeywords(arr);
			pm := ParsedModule(text);
			IF pm # NIL THEN AddImportNames(arr, pm) END;
			am := Analyze(text);   (* best-effort: this module's own top-level declarations *)
			IF am # NIL THEN AddScopeSymbols(arr, am.moduleScope) END
		END;
		RETURN arr
	END CompletionAt;

	(* ---- signature help ---- *)

	PROCEDURE FindInScope (scope: SyntaxTree.Scope; CONST name: ARRAY OF CHAR): SyntaxTree.Symbol;
	VAR sym: SyntaxTree.Symbol; nm: ARRAY 128 OF CHAR;
	BEGIN
		IF scope = NIL THEN RETURN NIL END;
		sym := scope.firstSymbol;
		WHILE sym # NIL DO sym.GetName(nm); IF nm = name THEN RETURN sym END; sym := sym.nextSymbol END;
		RETURN NIL
	END FindInScope;

	(* A member named <name> in a record/object type, following the base-type chain. *)
	PROCEDURE FindMember (t: SyntaxTree.Type; CONST name: ARRAY OF CHAR): SyntaxTree.Symbol;
	VAR rec: SyntaxTree.RecordType; depth: SIGNED32; sym: SyntaxTree.Symbol;
	BEGIN
		depth := 0;
		WHILE (t # NIL) & (depth < 16) DO
			t := t.resolvedType;
			IF (t # NIL) & (t IS SyntaxTree.PointerType) THEN
				t := t(SyntaxTree.PointerType).pointerBase;
				IF t # NIL THEN t := t.resolvedType END
			END;
			IF (t # NIL) & (t IS SyntaxTree.RecordType) THEN
				rec := t(SyntaxTree.RecordType);
				sym := FindInScope(rec.recordScope, name); IF sym # NIL THEN RETURN sym END;
				t := rec.baseType
			ELSE
				t := NIL
			END;
			INC(depth)
		END;
		RETURN NIL
	END FindMember;

	(* Lexically find the enclosing call: the callee identifier (with optional qualifier)
	   just before the unmatched "(" left of the cursor, and the active parameter index
	   (top-level commas between that "(" and the cursor). *)
	PROCEDURE SignatureContext (text: Strings.String; offset: SIGNED64;
		VAR qual, name: ARRAY OF CHAR; VAR activeParam: SIGNED32; VAR inCall: BOOLEAN);
	VAR i, openPos, j, cs, ce, qs, qe, k: SIZE; depth: SIGNED32; ch: CHAR; foundOpen: BOOLEAN;
	BEGIN
		inCall := FALSE; qual[0] := 0X; name[0] := 0X; activeParam := 0;
		IF text = NIL THEN RETURN END;
		i := SIZE(offset); depth := 0; foundOpen := FALSE; openPos := 0;
		LOOP
			IF i = 0 THEN EXIT END;
			DEC(i); ch := text[i];
			IF (ch = ")") OR (ch = "]") OR (ch = "}") THEN INC(depth)
			ELSIF ch = "(" THEN
				IF depth = 0 THEN openPos := i; foundOpen := TRUE; EXIT ELSE DEC(depth) END
			ELSIF (ch = "[") OR (ch = "{") THEN
				IF depth = 0 THEN RETURN ELSE DEC(depth) END
			ELSIF (ch = ",") & (depth = 0) THEN INC(activeParam)
			ELSIF (ch = ";") & (depth = 0) THEN RETURN
			END
		END;
		IF ~foundOpen THEN RETURN END;
		j := openPos;
		WHILE (j > 0) & ((text[j-1] = " ") OR (text[j-1] = 09X)) DO DEC(j) END;
		ce := j; cs := j;
		WHILE (cs > 0) & IsIdentChar(text[cs-1]) DO DEC(cs) END;
		IF cs = ce THEN RETURN END;
		k := 0; WHILE (cs + k < ce) & (k < LEN(name)-1) DO name[k] := text[cs+k]; INC(k) END;
		name[k] := 0X;
		IF (cs > 0) & (text[cs-1] = ".") THEN
			qe := cs - 1; qs := qe;
			WHILE (qs > 0) & IsIdentChar(text[qs-1]) DO DEC(qs) END;
			k := 0; WHILE (qs + k < qe) & (k < LEN(qual)-1) DO qual[k] := text[qs+k]; INC(k) END;
			qual[k] := 0X
		END;
		inCall := TRUE
	END SignatureContext;

	(* Resolve the called procedure symbol (Mod.Proc / Proc / obj.Method). *)
	PROCEDURE ResolveCallee (text: Strings.String; CONST qual, name: ARRAY OF CHAR; offset: SIGNED64): SyntaxTree.Symbol;
	VAR pm, am: SyntaxTree.Module; real: ARRAY 256 OF CHAR; ds: DeclScan; sym: SyntaxTree.Symbol;
		buf: Streams.Buffer; w: Streams.Writer; i: SIZE;
	BEGIN
		IF qual[0] # 0X THEN
			pm := ParsedModule(text);
			IF (pm # NIL) & ImportRealName(pm, qual, real) THEN
				RETURN FindInScope(ModuleScopeOf(real), name)
			END
		END;
		(* close the (possibly unbalanced) call with a dummy so the buffer parses *)
		NEW(buf, 4096); w := buf.GetWriter();
		FOR i := 0 TO SIZE(offset) - 1 DO w.Char(text[i]) END;
		w.String("Cmpl0Dummy)");
		i := SIZE(offset); WHILE text[i] # 0X DO w.Char(text[i]); INC(i) END;
		w.Update;
		am := Analyze(buf.GetString());
		IF am = NIL THEN RETURN NIL END;
		NEW(ds);
		IF qual[0] # 0X THEN
			sym := ds.Find(am, qual);            (* obj.Method: resolve obj, then its member *)
			IF sym # NIL THEN RETURN FindMember(sym.type, name) END;
			RETURN NIL
		ELSE
			RETURN ds.Find(am, name)             (* bare procedure *)
		END
	END ResolveCallee;

	(* textDocument/signatureHelp result, or NIL. *)
	PROCEDURE SignatureHelpAt (text: Strings.String; offset: SIGNED64): JSON.Value;
	VAR qual, name: ARRAY 256 OF CHAR; activeParam: SIGNED32; inCall, first: BOOLEAN;
		callee: SyntaxTree.Symbol; pt: SyntaxTree.ProcedureType; p: SyntaxTree.Parameter;
		sig, result, pinfo: JSON.Object; params, sigs: JSON.Array;
		label: ARRAY 1024 OF CHAR; pstr: ARRAY 256 OF CHAR; pnm: ARRAY 128 OF CHAR; ts: Strings.String;
	BEGIN
		SignatureContext(text, offset, qual, name, activeParam, inCall);
		IF ~inCall OR (name[0] = 0X) THEN RETURN NIL END;
		callee := ResolveCallee(text, qual, name, offset);
		IF (callee = NIL) OR ~(callee IS SyntaxTree.Procedure) THEN RETURN NIL END;
		IF (callee.type = NIL) OR ~(callee.type IS SyntaxTree.ProcedureType) THEN RETURN NIL END;
		pt := callee.type(SyntaxTree.ProcedureType);
		COPY(name, label); Strings.Append(label, "(");
		params := JSON.NewArray();
		p := pt.firstParameter; first := TRUE;
		WHILE p # NIL DO
			p.GetName(pnm); COPY(pnm, pstr);
			ts := TypeToStr(p.type);
			IF ts # NIL THEN Strings.Append(pstr, ": "); Strings.Append(pstr, ts^) END;
			IF ~first THEN Strings.Append(label, "; ") END;
			Strings.Append(label, pstr);
			pinfo := JSON.NewObject(); pinfo.Set("label", JSON.NewString(pstr)); params.Add(pinfo);
			first := FALSE; p := p.nextParameter
		END;
		Strings.Append(label, ")");
		IF pt.returnType # NIL THEN
			ts := TypeToStr(pt.returnType);
			IF ts # NIL THEN Strings.Append(label, ": "); Strings.Append(label, ts^) END
		END;
		sig := JSON.NewObject();
		sig.Set("label", JSON.NewString(label));
		sig.Set("parameters", params);
		sigs := JSON.NewArray(); sigs.Add(sig);
		result := JSON.NewObject();
		result.Set("signatures", sigs);
		result.Set("activeSignature", JSON.NewNumber(0));
		result.Set("activeParameter", JSON.NewNumber(activeParam));
		RETURN result
	END SignatureHelpAt;

	(* ---- find all references ---- *)

	PROCEDURE Contains (s: Strings.String; CONST sub: ARRAY OF CHAR): BOOLEAN;
	VAR i, j, slen, sublen: SIZE;
	BEGIN
		IF s = NIL THEN RETURN FALSE END;
		slen := Strings.Length(s^); sublen := Strings.Length(sub);
		IF sublen = 0 THEN RETURN TRUE END;
		i := 0;
		WHILE i + sublen <= slen DO
			j := 0; WHILE (j < sublen) & (s[i+j] = sub[j]) DO INC(j) END;
			IF j = sublen THEN RETURN TRUE END;
			INC(i)
		END;
		RETURN FALSE
	END Contains;

	(* "PFX:dir/Name.Mod" -> "Name" *)
	PROCEDURE ModuleBaseName (CONST fn: ARRAY OF CHAR; VAR base: ARRAY OF CHAR);
	VAR i, start, n: SIZE;
	BEGIN
		start := 0; i := 0;
		WHILE fn[i] # 0X DO IF (fn[i] = ":") OR (fn[i] = "/") THEN start := i + 1 END; INC(i) END;
		n := 0; i := start;
		WHILE (fn[i] # 0X) & (n < LEN(base)-1) DO base[n] := fn[i]; INC(n); INC(i) END;
		base[n] := 0X;
		IF (n >= 4) & (base[n-4] = ".") & (base[n-3] = "M") & (base[n-2] = "o") & (base[n-1] = "d") THEN
			base[n-4] := 0X
		END
	END ModuleBaseName;

	PROCEDURE LocExists (arr: JSON.Array; CONST uri: ARRAY OF CHAR; line, char: SIGNED32): BOOLEAN;
	VAR i: SIZE; v, lv, cv: JSON.Value; o, r, st: JSON.Object;
	BEGIN
		i := 0;
		WHILE i < arr.length DO
			v := arr.At(i);
			IF (v # NIL) & (v IS JSON.Object) THEN
				o := v(JSON.Object); r := AsObject(o.Get("range"));
				v := o.Get("uri");
				IF (v # NIL) & (v IS JSON.String) & (v(JSON.String).value^ = uri) & (r # NIL) THEN
					st := AsObject(r.Get("start"));
					IF st # NIL THEN
						lv := st.Get("line"); cv := st.Get("character");
						IF (lv # NIL) & (lv IS JSON.Number) & (cv # NIL) & (cv IS JSON.Number)
							& (SIGNED32(ENTIER(lv(JSON.Number).value)) = line)
							& (SIGNED32(ENTIER(cv(JSON.Number).value)) = char) THEN RETURN TRUE END
					END
				END
			END;
			INC(i)
		END;
		RETURN FALSE
	END LocExists;

	(* Turn a Finder's collected offsets (into `text`) into LSP Location objects (deduped). *)
	PROCEDURE AddLocs (arr: JSON.Array; f: Finder; text: Strings.String; uri: Strings.String);
	VAR i, line, char: SIGNED32; range, loc: JSON.Object;
	BEGIN
		IF uri = NIL THEN RETURN END;
		i := 0;
		WHILE i < f.refN DO
			OffsetToPos(text, f.refOff[i], line, char);
			IF ~LocExists(arr, uri^, line, char) THEN
				range := JSON.NewObject();
				range.Set("start", Position(line, char));
				range.Set("end", Position(line, char + f.refLen[i]));
				loc := JSON.NewObject(); loc.Set("uri", JSON.NewString(uri^)); loc.Set("range", range);
				arr.Add(loc)
			END;
			INC(i)
		END
	END AddLocs;

	(* textDocument/references: all use-sites of the symbol under the cursor. Project-wide
	   for module-level / record members; current-buffer only for locals. Always includes
	   the declaration. *)
	PROCEDURE ReferencesAt (text: Strings.String; offset: SIGNED64; uri: Strings.String): JSON.Value;
	VAR module, fm: SyntaxTree.Module; f: Finder; sym: SyntaxTree.Symbol; arr: JSON.Array;
		name, owner, modName: ARRAY 128 OF CHAR; readName, mask, prefix: ARRAY 1024 OF CHAR;
		kind: SIGNED32; wide: BOOLEAN; narrow: SyntaxTree.Scope; en: Files.Enumerator; fn: ARRAY 256 OF CHAR;
		flags: SET; tm, dt: SIGNED32; sz: Files.Size; ftext, declUri, sibUri: Strings.String;
		line, char: SIGNED32; range, loc: JSON.Object;
	BEGIN
		arr := JSON.NewArray();
		module := Analyze(text); IF module = NIL THEN RETURN arr END;
		NEW(f); IF ~f.Find(module, offset) THEN RETURN arr END;
		sym := f.foundSym; sym.GetName(name);
		IF (sym.scope = NIL) OR (sym.scope.ownerModule = NIL) THEN RETURN arr END;
		sym.scope.ownerModule.GetName(owner);
		kind := f.KindOf(sym);
		wide := (sym.scope IS SyntaxTree.ModuleScope) OR (sym.scope IS SyntaxTree.RecordScope);

		(* a symbol nobody outside can see is collected by its own scope, not by name *)
		IF wide THEN narrow := NIL ELSE narrow := sym.scope END;
		f.CollectRefs(module, name, owner, kind, narrow);   (* current buffer *)
		AddLocs(arr, f, text, uri);

		IF wide THEN
			SiblingMask(uri, mask, prefix);
			NEW(en); en.Open(mask, {});
			WHILE en.HasMoreEntries() DO
				IF en.GetEntry(fn, flags, tm, dt, sz) THEN
					ModuleBaseName(fn, modName);
					sibUri := SiblingUri(uri, modName);
					(* skip the current document itself (already collected from the buffer) *)
					IF (modName[0] # 0X) & (sibUri # NIL) & (sibUri^ # uri^) THEN
						(* by full path, not by name: the search path holds the standard
						   library too, and a project module may share a name with one *)
						COPY(prefix, readName); Strings.Append(readName, modName);
						Strings.Append(readName, ".Mod");
						ftext := ReadFile(readName);
						IF (ftext # NIL) & Contains(ftext, owner) THEN
							fm := Analyze(ftext);
							IF fm # NIL THEN
								f.CollectRefs(fm, name, owner, kind, NIL);
								AddLocs(arr, f, ftext, sibUri)
							END
						END
					END
				END
			END;
			en.Close
		END;

		(* The declaration site, for a symbol whose own module may not be the open buffer.
		   Only for the wide case: FindDeclPos searches by name alone, so on a local it
		   would happily return a sibling procedure's same-named declaration -- and the
		   real one is in `arr` already, collected by scope. *)
		IF wide THEN declUri := SourceUriFor(uri, owner) ELSE declUri := NIL END;
		IF (declUri # NIL) & FindDeclPos(owner, name, line, char) & ~LocExists(arr, declUri^, line, char) THEN
			range := JSON.NewObject();
			range.Set("start", Position(line, char));
			range.Set("end", Position(line, char + SIGNED32(Strings.Length(name))));
			loc := JSON.NewObject(); loc.Set("uri", JSON.NewString(declUri^)); loc.Set("range", range);
			arr.Add(loc)
		END;
		RETURN arr
	END ReferencesAt;

	(* ---- semantic tokens ---- *)

	(* Insertion sort a Finder's collected tokens by byte offset (nearly sorted already). *)
	PROCEDURE SortTokens (f: Finder);
	VAR i, j: SIGNED32; o: SIGNED64; l, k: SIGNED32;
	BEGIN
		i := 1;
		WHILE i < f.refN DO
			o := f.refOff[i]; l := f.refLen[i]; k := f.refKind[i]; j := i - 1;
			WHILE (j >= 0) & (f.refOff[j] > o) DO
				f.refOff[j+1] := f.refOff[j]; f.refLen[j+1] := f.refLen[j]; f.refKind[j+1] := f.refKind[j]; DEC(j)
			END;
			f.refOff[j+1] := o; f.refLen[j+1] := l; f.refKind[j+1] := k; INC(i)
		END
	END SortTokens;

	(* textDocument/semanticTokens/full: delta-encoded 5-tuples (deltaLine, deltaChar,
	   length, tokenType, 0) for every resolved identifier occurrence, sorted by position. *)
	PROCEDURE SemanticTokens (text: Strings.String): JSON.Value;
	VAR module: SyntaxTree.Module; f: Finder; data: JSON.Array; result: JSON.Object;
		i: SIGNED32; pos, tstart: SIZE; curLine, curChar, prevLine, prevChar, dl, dc: SIGNED32;
	BEGIN
		data := JSON.NewArray();
		result := JSON.NewObject(); result.Set("data", data);
		module := Analyze(text); IF module = NIL THEN RETURN result END;
		NEW(f); f.CollectTokens(module); SortTokens(f);
		pos := 0; curLine := 0; curChar := 0; prevLine := 0; prevChar := 0; i := 0;
		WHILE i < f.refN DO
			IF (i = 0) OR (f.refOff[i] # f.refOff[i-1]) THEN   (* drop duplicate positions *)
				tstart := SIZE(f.refOff[i]);
				WHILE (pos < tstart) & (text[pos] # 0X) DO
					IF text[pos] = LF THEN INC(curLine); curChar := 0 ELSE INC(curChar) END;
					INC(pos)
				END;
				dl := curLine - prevLine;
				IF dl = 0 THEN dc := curChar - prevChar ELSE dc := curChar END;
				data.Add(JSON.NewNumber(dl)); data.Add(JSON.NewNumber(dc));
				data.Add(JSON.NewNumber(f.refLen[i])); data.Add(JSON.NewNumber(f.refKind[i]));
				data.Add(JSON.NewNumber(0));
				prevLine := curLine; prevChar := curChar
			END;
			INC(i)
		END;
		RETURN result
	END SemanticTokens;

	(* ---- rename ---- *)

	PROCEDURE EditExists (earr: JSON.Array; line, char: SIGNED32): BOOLEAN;
	VAR i: SIZE; v, lv, cv: JSON.Value; o, r, st: JSON.Object;
	BEGIN
		i := 0;
		WHILE i < earr.length DO
			v := earr.At(i);
			IF (v # NIL) & (v IS JSON.Object) THEN
				o := v(JSON.Object); r := AsObject(o.Get("range"));
				IF r # NIL THEN
					st := AsObject(r.Get("start"));
					IF st # NIL THEN
						lv := st.Get("line"); cv := st.Get("character");
						IF (lv # NIL) & (lv IS JSON.Number) & (cv # NIL) & (cv IS JSON.Number)
							& (SIGNED32(ENTIER(lv(JSON.Number).value)) = line)
							& (SIGNED32(ENTIER(cv(JSON.Number).value)) = char) THEN RETURN TRUE END
					END
				END
			END;
			INC(i)
		END;
		RETURN FALSE
	END EditExists;

	(* Append TextEdits (range -> newName) for a Finder's collected offsets to the
	   per-uri array inside a WorkspaceEdit.changes object (deduped). *)
	PROCEDURE AddEdits (changes: JSON.Object; f: Finder; text, uri, newName: Strings.String);
	VAR i, line, char: SIGNED32; edits: JSON.Value; earr: JSON.Array; te, range: JSON.Object;
	BEGIN
		IF uri = NIL THEN RETURN END;
		edits := changes.Get(uri^);
		IF (edits # NIL) & (edits IS JSON.Array) THEN earr := edits(JSON.Array)
		ELSE earr := JSON.NewArray(); changes.Set(uri^, earr) END;
		i := 0;
		WHILE i < f.refN DO
			OffsetToPos(text, f.refOff[i], line, char);
			IF ~EditExists(earr, line, char) THEN
				range := JSON.NewObject();
				range.Set("start", Position(line, char));
				range.Set("end", Position(line, char + f.refLen[i]));
				te := JSON.NewObject(); te.Set("range", range); te.Set("newText", JSON.NewString(newName^));
				earr.Add(te)
			END;
			INC(i)
		END
	END AddEdits;

	(* textDocument/rename -> WorkspaceEdit. Only module-level symbols (types,
	   procedures, module variables, constants) are renamed: their (name, owner, kind)
	   identity is unambiguous within a module, so the rename is safe and project-wide.
	   Locals and record/object members are declined (NIL) to avoid renaming same-named
	   siblings. *)
	PROCEDURE RenameAt (text: Strings.String; offset: SIGNED64; uri, newName: Strings.String): JSON.Value;
	VAR module, fm: SyntaxTree.Module; f: Finder; sym: SyntaxTree.Symbol; changes: JSON.Object;
		name, owner, modName: ARRAY 128 OF CHAR; readName, mask, prefix: ARRAY 1024 OF CHAR;
		kind: SIGNED32;
		en: Files.Enumerator; fn: ARRAY 256 OF CHAR; flags: SET; tm, dt: SIGNED32; sz: Files.Size;
		ftext: Strings.String; result: JSON.Object; local: BOOLEAN; narrow: SyntaxTree.Scope;
	BEGIN
		module := Analyze(text); IF module = NIL THEN RETURN NIL END;
		NEW(f); IF ~f.Find(module, offset) THEN RETURN NIL END;
		sym := f.foundSym; sym.GetName(name);
		IF (sym.scope = NIL) OR (sym.scope.ownerModule = NIL) THEN RETURN NIL END;
		(* Two kinds of rename are safe. A module-level symbol is swept across the project,
		   as find-all-references does. A procedure-local (or parameter) cannot be named
		   from another file at all, so renaming it inside this buffer is complete — but it
		   must be collected by its own scope, or a sibling procedure's same-named local
		   would be renamed too. A record field is still refused: its key is only
		   (name, module, kind), which is too loose to rewrite other files with. *)
		local := ~(sym.scope IS SyntaxTree.ModuleScope);
		IF local & (sym.scope IS SyntaxTree.RecordScope) THEN RETURN NIL END;
		sym.scope.ownerModule.GetName(owner); kind := f.KindOf(sym);
		changes := JSON.NewObject();

		IF local THEN narrow := sym.scope ELSE narrow := NIL END;
		f.CollectRefs(module, name, owner, kind, narrow); AddEdits(changes, f, text, uri, newName);

		IF ~local THEN
			SiblingMask(uri, mask, prefix);
			NEW(en); en.Open(mask, {});
			WHILE en.HasMoreEntries() DO
				IF en.GetEntry(fn, flags, tm, dt, sz) THEN
					ModuleBaseName(fn, modName);
					IF (modName[0] # 0X) & (SiblingUri(uri, modName) # NIL) & (SiblingUri(uri, modName)^ # uri^) THEN
						COPY(prefix, readName); Strings.Append(readName, modName);
						Strings.Append(readName, ".Mod");
						ftext := ReadFile(readName);
						IF (ftext # NIL) & Contains(ftext, owner) THEN
							fm := Analyze(ftext);
							IF fm # NIL THEN
								f.CollectRefs(fm, name, owner, kind, NIL);
								AddEdits(changes, f, ftext, SiblingUri(uri, modName), newName)
							END
						END
					END
				END
			END;
			en.Close
		END;
		(* the declaration is collected too: WScope treats a declaration name as a
		   resolvable site, and the owner module is always processed above. *)
		result := JSON.NewObject(); result.Set("changes", changes);
		RETURN result
	END RenameAt;

	(* ---- formatting ---- *)

	(* Remove the printer's "(*unresolved*)" markers (present because we print a
	   parse-only AST to avoid the checker expanding the IMPORT list). *)
	PROCEDURE CleanUnresolved (s: Strings.String): Strings.String;
	CONST pat = "(*unresolved*)";
	VAR buf: Streams.Buffer; w: Streams.Writer; i, j, plen: SIZE;
	BEGIN
		IF s = NIL THEN RETURN NIL END;
		plen := Strings.Length(pat);
		NEW(buf, 4096); w := buf.GetWriter(); i := 0;
		WHILE s[i] # 0X DO
			j := 0; WHILE (j < plen) & (s[i+j] = pat[j]) DO INC(j) END;
			IF j = plen THEN INC(i, plen) ELSE w.Char(s[i]); INC(i) END
		END;
		w.Update; RETURN buf.GetString()
	END CleanUnresolved;

	(* The printer ends a declaration with a space before its newline ("TYPE ", "END; ").
	   Nobody wants an editor's format command to plant trailing whitespace in every file,
	   so it is taken off here; the printer itself is vanilla, and this is our surface. *)
	PROCEDURE StripTrailingBlanks (s: Strings.String): Strings.String;
	VAR buf: Streams.Buffer; w: Streams.Writer; i, held, j: SIZE;
	BEGIN
		IF s = NIL THEN RETURN NIL END;
		NEW(buf, 4096); w := buf.GetWriter(); i := 0; held := -1;
		WHILE s[i] # 0X DO
			IF (s[i] = " ") OR (s[i] = 09X) THEN
				IF held < 0 THEN held := i END     (* hold it: it may be at end of line *)
			ELSE
				IF held >= 0 THEN
					(* replay it verbatim, tabs included, unless the line ended right here *)
					IF (s[i] # CR) & (s[i] # LF) THEN
						j := held; WHILE j < i DO w.Char(s[j]); INC(j) END
					END;
					held := -1
				END;
				w.Char(s[i])
			END;
			INC(i)
		END;
		w.Update; RETURN buf.GetString()
	END StripTrailingBlanks;

	(* textDocument/formatting: reprint the whole module in Fox's canonical style. Only
	   syntactically-valid files are formatted (else NIL). A single whole-document edit. *)
	PROCEDURE Formatting (text: Strings.String): JSON.Value;
	VAR srcR: Streams.StringReader; diag: Diagnostics.DiagnosticsList;
		scanner: FoxScanner.Scanner; parser: FoxParser.Parser; module: SyntaxTree.Module;
		buf: Streams.Buffer; w: Streams.Writer; p: Printout.Printer; s: Strings.String;
		res: JSON.Array; edit, range: JSON.Object; i: SIZE; lastLine, lastChar: SIGNED32;
	BEGIN
		IF text = NIL THEN RETURN NIL END;
		NEW(diag); Streams.OpenStringReader(srcR, text^);
		scanner := FoxScanner.NewScanner("source", srcR, 0, diag);
		parser := FoxParser.NewParser(scanner, diag, "");
		module := parser.Module();
		IF (module = NIL) OR parser.error THEN RETURN NIL END;   (* never reformat broken source *)
		NEW(buf, 8192); w := buf.GetWriter(); p := Printout.NewPrinter(w, Printout.SourceCode, FALSE);
		p.Module(module); w.Update; s := StripTrailingBlanks(CleanUnresolved(buf.GetString()));
		IF s = NIL THEN RETURN NIL END;
		lastLine := 0; lastChar := 0; i := 0;
		WHILE text[i] # 0X DO
			IF text[i] = LF THEN INC(lastLine); lastChar := 0 ELSE INC(lastChar) END; INC(i)
		END;
		range := JSON.NewObject();
		range.Set("start", Position(0, 0)); range.Set("end", Position(lastLine, lastChar));
		edit := JSON.NewObject(); edit.Set("range", range); edit.Set("newText", JSON.NewString(s^));
		res := JSON.NewArray(); res.Add(edit);
		RETURN res
	END Formatting;

	(* ---- code actions ---- *)

	PROCEDURE IndexOf (text: Strings.String; CONST pat: ARRAY OF CHAR; from: SIZE): SIZE;
	VAR i, j, plen, tlen: SIZE;
	BEGIN
		plen := Strings.Length(pat); tlen := Strings.Length(text^);
		IF plen = 0 THEN RETURN -1 END;
		i := from;
		WHILE i + plen <= tlen DO
			j := 0; WHILE (j < plen) & (text[i+j] = pat[j]) DO INC(j) END;
			IF j = plen THEN RETURN i END; INC(i)
		END;
		RETURN -1
	END IndexOf;

	PROCEDURE MakeEdit (sl, sc, el, ec: SIGNED32; newText: Strings.String): JSON.Object;
	VAR te, r: JSON.Object;
	BEGIN
		r := JSON.NewObject(); r.Set("start", Position(sl, sc)); r.Set("end", Position(el, ec));
		te := JSON.NewObject(); te.Set("range", r); te.Set("newText", JSON.NewString(newText^));
		RETURN te
	END MakeEdit;

	PROCEDURE MakeAction (CONST title: ARRAY OF CHAR; uri: Strings.String; edit: JSON.Object): JSON.Object;
	VAR act, we, changes: JSON.Object; arr: JSON.Array;
	BEGIN
		arr := JSON.NewArray(); arr.Add(edit);
		changes := JSON.NewObject(); changes.Set(uri^, arr);
		we := JSON.NewObject(); we.Set("changes", changes);
		act := JSON.NewObject();
		act.Set("title", JSON.NewString(title)); act.Set("kind", JSON.NewString("quickfix")); act.Set("edit", we);
		RETURN act
	END MakeAction;

	(* If (line,char) sits on an identifier that is immediately followed by ".", it's a
	   module qualifier: return that name. *)
	PROCEDURE IdentModuleAt (text: Strings.String; line, char: SIGNED32; VAR mod: ARRAY OF CHAR): BOOLEAN;
	VAR off, e, k: SIZE;
	BEGIN
		mod[0] := 0X; off := SIZE(PosToOffset(text, line, char));
		IF ~IsIdentChar(text[off]) THEN RETURN FALSE END;
		e := off; WHILE IsIdentChar(text[e]) DO INC(e) END;
		IF text[e] # "." THEN RETURN FALSE END;
		k := 0; WHILE (off + k < e) & (k < LEN(mod)-1) DO mod[k] := text[off+k]; INC(k) END;
		mod[k] := 0X; RETURN mod[0] # 0X
	END IdentModuleAt;

	PROCEDURE ImportAlreadyThere (text: Strings.String; CONST mod: ARRAY OF CHAR): BOOLEAN;
	VAR pm: SyntaxTree.Module; imp: SyntaxTree.Import; nm: ARRAY 128 OF CHAR;
	BEGIN
		pm := ParsedModule(text); IF pm = NIL THEN RETURN FALSE END;
		imp := pm.moduleScope.firstImport;
		WHILE imp # NIL DO imp.GetName(nm); IF nm = mod THEN RETURN TRUE END; imp := imp.nextImport END;
		RETURN FALSE
	END ImportAlreadyThere;

	(* A quickfix that adds module <mod> to the IMPORT list (or a new IMPORT after the
	   module header). *)
	PROCEDURE AddImportAction (text, uri: Strings.String; CONST mod: ARRAY OF CHAR): JSON.Object;
	VAR impIdx, semi: SIZE; insOff: SIZE; il, ic: SIGNED32; nt, title: ARRAY 256 OF CHAR;
	BEGIN
		impIdx := IndexOf(text, "IMPORT", 0);
		IF impIdx >= 0 THEN
			semi := IndexOf(text, ";", impIdx); IF semi < 0 THEN RETURN NIL END;
			insOff := semi; COPY(", ", nt); Strings.Append(nt, mod)
		ELSE
			semi := IndexOf(text, ";", 0); IF semi < 0 THEN RETURN NIL END;
			insOff := semi + 1; COPY(" IMPORT ", nt); Strings.Append(nt, mod); Strings.Append(nt, ";")
		END;
		OffsetToPos(text, insOff, il, ic);
		COPY("Import ", title); Strings.Append(title, mod);
		RETURN MakeAction(title, uri, MakeEdit(il, ic, il, ic, Strings.NewString(nt)))
	END AddImportAction;

	(* textDocument/codeAction: add-import quickfixes for undeclared qualifiers in the
	   supplied diagnostics, plus comment/uncomment of a non-empty selection. *)
	PROCEDURE CodeActions (text, uri: Strings.String; diags: JSON.Array;
		sl, sc, el, ec: SIGNED32): JSON.Value;
	VAR actions: JSON.Array; i: SIZE; d, dr, dstart: JSON.Object; mv, lv, cv: JSON.Value;
		dl, dc: SIGNED32; mod, seen: ARRAY 1024 OF CHAR; act: JSON.Object;
		o1, o2, k: SIZE; buf: Streams.Buffer; w: Streams.Writer; wrapped: BOOLEAN;
	BEGIN
		actions := JSON.NewArray(); seen[0] := 0X;
		IF diags # NIL THEN
			i := 0;
			WHILE i < diags.length DO
				d := AsObject(diags.At(i));
				IF d # NIL THEN
					mv := d.Get("message");
					IF (mv # NIL) & (mv IS JSON.String) & Contains(mv(JSON.String).value, "ndeclared") THEN
						dr := AsObject(d.Get("range"));
						IF dr # NIL THEN dstart := AsObject(dr.Get("start")) ELSE dstart := NIL END;
						IF dstart # NIL THEN
							lv := dstart.Get("line"); cv := dstart.Get("character");
							IF (lv # NIL) & (lv IS JSON.Number) & (cv # NIL) & (cv IS JSON.Number) THEN
								dl := SIGNED32(ENTIER(lv(JSON.Number).value));
								dc := SIGNED32(ENTIER(cv(JSON.Number).value));
								IF IdentModuleAt(text, dl, dc, mod) & ~ImportAlreadyThere(text, mod)
									& ~Contains(Strings.NewString(seen), mod) THEN
									Strings.Append(seen, mod); Strings.Append(seen, ";");
									act := AddImportAction(text, uri, mod);
									IF act # NIL THEN actions.Add(act) END
								END
							END
						END
					END
				END;
				INC(i)
			END
		END;
		(* comment / uncomment a non-empty selection *)
		IF (sl # el) OR (sc # ec) THEN
			o1 := SIZE(PosToOffset(text, sl, sc)); o2 := SIZE(PosToOffset(text, el, ec));
			IF o2 > o1 THEN
				wrapped := (text[o1] = "(") & (text[o1+1] = "*") & (o2 >= o1+4)
					& (text[o2-2] = "*") & (text[o2-1] = ")");
				NEW(buf, 1024); w := buf.GetWriter();
				IF wrapped THEN
					k := o1 + 2; WHILE k < o2 - 2 DO w.Char(text[k]); INC(k) END; w.Update;
					actions.Add(MakeAction("Uncomment selection", uri, MakeEdit(sl, sc, el, ec, buf.GetString())))
				ELSE
					w.String("(*"); k := o1; WHILE k < o2 DO w.Char(text[k]); INC(k) END; w.String("*)"); w.Update;
					actions.Add(MakeAction("Comment selection", uri, MakeEdit(sl, sc, el, ec, buf.GetString())))
				END
			END
		END;
		RETURN actions
	END CodeActions;

	(* Shared server loop. live=TRUE also re-diagnoses on every didChange
	   (rely on the client to debounce); live=FALSE diagnoses on open/save only. *)
	PROCEDURE Serve (context: Commands.Context; live: BOOLEAN);
	VAR msg: JSON.Value; req, params, td, caps, result, pos, initOpts, compl, sighelp, semtok, legend: JSON.Object;
		rng, ctx, endO: JSON.Object;
		method, uri, text, sopt: Strings.String; in: Streams.Reader; out: Streams.Writer;
		changes: JSON.Value; arr, trig, sigtrig, ttypes, diagsArr: JSON.Array; first, res, diagsV: JSON.Value;
		line, char, line2, char2: SIGNED32; doc: Document; alive: BOOLEAN;
	BEGIN
		in := context.in; out := context.out;
		documents := NIL; initialized := FALSE; stdlibSrcHost[0] := 0X;
		LOOP
			msg := ReadMessage(in, alive);
			IF (msg = NIL) & ~alive THEN EXIT END;   (* end of input, or a header past saving *)
			req := AsObject(msg);                    (* NIL for a message we skipped: read on *)
			IF req # NIL THEN
				IF GetStr(req, "method", method) THEN
					params := AsObject(req.Get("params"));
					IF method^ = "initialize" THEN
						caps := JSON.NewObject();
						caps.Set("textDocumentSync", JSON.NewNumber(1));   (* full sync *)
						caps.Set("hoverProvider", JSON.NewBool(TRUE));
						caps.Set("definitionProvider", JSON.NewBool(TRUE));
						caps.Set("documentSymbolProvider", JSON.NewBool(TRUE));
						compl := JSON.NewObject();
						trig := JSON.NewArray(); trig.Add(JSON.NewString("."));
						compl.Set("triggerCharacters", trig);
						caps.Set("completionProvider", compl);
						sighelp := JSON.NewObject();
						sigtrig := JSON.NewArray(); sigtrig.Add(JSON.NewString("(")); sigtrig.Add(JSON.NewString(","));
						sighelp.Set("triggerCharacters", sigtrig);
						caps.Set("signatureHelpProvider", sighelp);
						caps.Set("referencesProvider", JSON.NewBool(TRUE));
						legend := JSON.NewObject();
						ttypes := JSON.NewArray();
						ttypes.Add(JSON.NewString("namespace")); ttypes.Add(JSON.NewString("type"));
						ttypes.Add(JSON.NewString("function")); ttypes.Add(JSON.NewString("variable"));
						ttypes.Add(JSON.NewString("parameter")); ttypes.Add(JSON.NewString("enumMember"));
						ttypes.Add(JSON.NewString("property")); ttypes.Add(JSON.NewString("method"));
						legend.Set("tokenTypes", ttypes);
						legend.Set("tokenModifiers", JSON.NewArray());
						semtok := JSON.NewObject();
						semtok.Set("legend", legend);
						semtok.Set("full", JSON.NewBool(TRUE));
						caps.Set("semanticTokensProvider", semtok);
						caps.Set("renameProvider", JSON.NewBool(TRUE));
						caps.Set("documentFormattingProvider", JSON.NewBool(TRUE));
						caps.Set("codeActionProvider", JSON.NewBool(TRUE));
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
					ELSIF method^ = "textDocument/documentSymbol" THEN
						td := AsObject(params.Get("textDocument"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := DocumentSymbols(doc.text) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/completion" THEN
						td := AsObject(params.Get("textDocument"));
						pos := AsObject(params.Get("position"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) & (pos # NIL)
							& GetInt(pos, "line", line) & GetInt(pos, "character", char) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := CompletionAt(doc.text, PosToOffset(doc.text, line, char)) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/signatureHelp" THEN
						td := AsObject(params.Get("textDocument"));
						pos := AsObject(params.Get("position"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) & (pos # NIL)
							& GetInt(pos, "line", line) & GetInt(pos, "character", char) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := SignatureHelpAt(doc.text, PosToOffset(doc.text, line, char)) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/references" THEN
						td := AsObject(params.Get("textDocument"));
						pos := AsObject(params.Get("position"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) & (pos # NIL)
							& GetInt(pos, "line", line) & GetInt(pos, "character", char) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := ReferencesAt(doc.text, PosToOffset(doc.text, line, char), uri) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/semanticTokens/full" THEN
						td := AsObject(params.Get("textDocument"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := SemanticTokens(doc.text) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/rename" THEN
						td := AsObject(params.Get("textDocument"));
						pos := AsObject(params.Get("position"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) & (pos # NIL)
							& GetInt(pos, "line", line) & GetInt(pos, "character", char)
							& GetStr(params, "newName", sopt) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := RenameAt(doc.text, PosToOffset(doc.text, line, char), uri, sopt) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/formatting" THEN
						td := AsObject(params.Get("textDocument"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) THEN
							doc := FindDoc(uri^);
							IF doc # NIL THEN res := Formatting(doc.text) END
						END;
						Respond(out, req.Get("id"), res)
					ELSIF method^ = "textDocument/codeAction" THEN
						td := AsObject(params.Get("textDocument"));
						rng := AsObject(params.Get("range"));
						ctx := AsObject(params.Get("context"));
						res := NIL;
						IF (td # NIL) & GetStr(td, "uri", uri) & (rng # NIL) THEN
							pos := AsObject(rng.Get("start")); endO := AsObject(rng.Get("end"));
							IF (pos # NIL) & (endO # NIL)
								& GetInt(pos, "line", line) & GetInt(pos, "character", char)
								& GetInt(endO, "line", line2) & GetInt(endO, "character", char2) THEN
								doc := FindDoc(uri^);
								IF doc # NIL THEN
									diagsArr := NIL;
									IF ctx # NIL THEN
										diagsV := ctx.Get("diagnostics");
										IF (diagsV # NIL) & (diagsV IS JSON.Array) THEN diagsArr := diagsV(JSON.Array) END
									END;
									res := CodeActions(doc.text, uri, diagsArr, line, char, line2, char2)
								END
							END
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
