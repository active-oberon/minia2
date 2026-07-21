MODULE LSP;
(**
	AUTHOR "minia2 SDK";
	PURPOSE "Minimal Language Server (LSP) for Active Oberon — diagnostics over JSON-RPC/stdio";
	LIMITATIONS
		"- MVP: only publishes diagnostics (syntax + semantic errors/warnings) on
		   open/change/save. No hover/definition/completion yet.
		 - Imports resolve against the current working directory only (the SDK seeds
		   it with the standard library); multi-file user projects are not indexed.
		 - Positions assume the source is ASCII/UTF-8 with 1 char = 1 UTF-16 unit."
*)

IMPORT Streams, Strings, JSON, Diagnostics, Compiler, SyntaxTree := FoxSyntaxTree, Commands;

CONST
	CR = 0DX; LF = 0AX;

TYPE
	Document = OBJECT
	VAR next: Document; uri: Strings.String; text: Strings.String;
	END Document;

VAR
	documents: Document;
	initialized: BOOLEAN;

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

	(** Command entry point: `oberon LSP.Run`. Speaks LSP over stdin/stdout. *)
	PROCEDURE Run* (context: Commands.Context);
	VAR msg: JSON.Value; req, params, td, caps, result: JSON.Object;
		method, uri, text: Strings.String; in: Streams.Reader; out: Streams.Writer;
		changes: JSON.Value; arr: JSON.Array; first: JSON.Value;
	BEGIN
		in := context.in; out := context.out;
		documents := NIL; initialized := FALSE;
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
						result := JSON.NewObject();
						result.Set("capabilities", caps);
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
						td := AsObject(params.Get("textDocument"));
						changes := params.Get("contentChanges");
						IF (td # NIL) & GetStr(td, "uri", uri) & (changes # NIL) & (changes IS JSON.Array) THEN
							arr := changes(JSON.Array); first := arr.At(0);
							IF (first # NIL) & GetStr(AsObject(first), "text", text) THEN
								PutDoc(uri^, text^); PublishFor(out, uri)
							END
						END
					ELSIF method^ = "textDocument/didSave" THEN
						td := AsObject(params.Get("textDocument"));
						IF (td # NIL) & GetStr(td, "uri", uri) THEN PublishFor(out, uri) END
					ELSIF method^ = "textDocument/didClose" THEN
						td := AsObject(params.Get("textDocument"));
						IF (td # NIL) & GetStr(td, "uri", uri) THEN
							RemoveDoc(uri^); PublishFor(out, uri)   (* empty diagnostics *)
						END
					ELSE
						(* unknown: answer requests with null so clients don't hang *)
						Respond(out, req.Get("id"), NIL)
					END
				END
			END
		END
	END Run;

END LSP.
