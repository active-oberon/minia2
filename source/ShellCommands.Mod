MODULE ShellCommands; (* ejz,  *)
IMPORT Machine, Streams, Pipes, AosModules := Modules, Files, Dates, Strings, Commands;

CONST
	MaxString = 256;

TYPE
	String = ARRAY MaxString OF CHAR;

	CmdAlias = POINTER TO RECORD
		alias, cmd, help: String;
		next: CmdAlias
	END;

	CmdParameters = POINTER TO ARRAY OF CHAR;

	AliasList = OBJECT
		VAR alias: CmdAlias;

		PROCEDURE Alias(alias, cmd, help: ARRAY OF CHAR);
			VAR a: CmdAlias;
		BEGIN {EXCLUSIVE}
			a := SELF.alias;
			WHILE (a # NIL) & (a.alias # alias) DO
				a := a.next
			END;
			IF a = NIL THEN
				NEW(a); a.next := SELF.alias; SELF.alias := a; COPY(alias, a.alias)
			END;
			COPY(cmd, a.cmd); COPY(help, a.help)
		END Alias;

		PROCEDURE Find(alias: ARRAY OF CHAR): CmdAlias;
			VAR a: CmdAlias;
		BEGIN {EXCLUSIVE}
			a := SELF.alias;
			WHILE (a # NIL) & (a.alias # alias) DO
				a := a.next
			END;
			RETURN a
		END Find;

		PROCEDURE List(out: Streams.Writer);
			VAR a: CmdAlias;
		BEGIN {EXCLUSIVE}
			a := alias;
			WHILE a # NIL DO
				out.String(a.alias); out.Char(09X); out.String(a.cmd); out.Ln();
				IF a.help # "" THEN
					out.Char(09X); out.String(a.help); out.Ln()
				END;
				a := a.next
			END
		END List;

		PROCEDURE &Init*;
		BEGIN
			alias := NIL;
			Alias("alias", "ShellCommands.Alias", "alias [ [ alias cmd ] help ]");
			Alias("del", "ShellCommands.Delete", "del { file }");
			Alias("dir", "ShellCommands.Directory", "dir [ pattern ]");
			Alias("echo", "ShellCommands.Echo", "echo { par }");
			Alias("exit", "ShellCommands.Exit", "exit");
			Alias("free", "ShellCommands.Free", "free mod");
			Alias("help", "ShellCommands.Help", "help [ alias ]");
			Alias("mods", "ShellCommands.Modules", "mods");
			Alias("start", "ShellCommands.Start", "start cmd { pars }");
			Alias("ver", "ShellCommands.Version", "ver")
		END Init;
	END AliasList;

	Context* = OBJECT (Commands.Context)
	VAR
		alias: AliasList;
		C: ANY;

		PROCEDURE &New*(C: ANY; in: Streams.Reader; out, err: Streams.Writer);
		BEGIN
			Init(in, NIL, out, err, NIL);
			SELF.C := C; alias := NIL
		END New;

		(*	Give the context the arguments of the command about to run in it. It has to be a reader
			of its own and not the one the context was born with: for a NIL argument reader
			Commands.Context.Init substitutes an empty one **one byte wide**, and SetRaw clamps to
			the reader's own buffer without saying so -- which gave every command in this shell the
			first character of its arguments and nothing else. A NIL here means no arguments at
			all, and that has to be an empty reader too, or the one byte of the empty reader reads
			as an argument and a command that would fall back on the session's input never does. *)
		PROCEDURE SetArguments(arguments: CmdParameters; length: SIZE);
		VAR arg: Streams.StringReader;
		BEGIN
			IF (arguments = NIL) OR (length <= 0) THEN length := 0 END;
			NEW(arg, length + 1);
			IF length > 0 THEN arg.SetRaw(arguments^, 0, length) END;
			Init(in, arg, out, error, caller)
		END SetArguments;

	END Context;

	Command = OBJECT
	VAR
		ctx: Context;
		cmd: String;
		args: CmdParameters; argLen: SIZE;   (* the arguments belong to the command, not to a context *)
		next: Command;

		PROCEDURE SetArguments(arguments: CmdParameters; length: SIZE);
		BEGIN
			args := arguments; argLen := length;
			ctx.SetArguments(args, argLen)
		END SetArguments;

		PROCEDURE SetContext(C: ANY; in: Streams.Reader; out, err: Streams.Writer);
		VAR a: AliasList;
		BEGIN
			IF (C # ctx.C) OR (in # ctx.in) OR (out # ctx.out) OR (err # ctx.error) THEN
				a := ctx.alias;
				NEW(ctx, C, in, out, err);
				ctx.alias := a;
				ctx.SetArguments(args, argLen)   (* a new context is not a reason to lose them *)
			END
		END SetContext;

		PROCEDURE &Init*(ctx: Context);
		BEGIN
			ASSERT(ctx # NIL);
			SELF.ctx := ctx; cmd := ""; args := NIL; argLen := 0; next := NIL
		END Init;

	END Command;

PROCEDURE GetPar(par: ANY; VAR p: CmdParameters; VAR w: Streams.Writer);
VAR arg : Streams.StringReader; len, length : SIZE;
BEGIN
	p := NIL; w := NIL;
	IF (par # NIL) & (par IS Commands.Context) & (par(Commands.Context).arg IS Streams.StringReader) THEN
		arg := par(Commands.Context).arg (Streams.StringReader);
		len := arg.Available();
		IF (len > 0) THEN
			NEW(p, len);
			arg.Bytes(p^, 0, len, length);
			w := par(Commands.Context).out;
		END;
	END
END GetPar;

PROCEDURE GetAliasList(p: Commands.Context): AliasList;
BEGIN
	IF (p # NIL) & (p IS Context) THEN
		RETURN p(Context).alias
	END;
	RETURN NIL
END GetAliasList;

PROCEDURE Close(p: Commands.Context);
VAR ctx: Context;
BEGIN
	IF (p # NIL) & (p IS Context) THEN
		ctx := p(Context);
		IF (ctx.C # NIL) & (ctx.C IS Pipes.Pipe) THEN   (* NIL IS T traps: the two above guard, this did not *)
			ctx.out.Update(); ctx.C(Pipes.Pipe).Close()
		END
	END
END Close;

(*	The alias table lives in the session, and these two are commands anybody can type at the other
	shell, where the context is not a session and GetAliasList answers NIL. Saying so is the answer;
	reading through the NIL is not. *)
PROCEDURE NoSession(context : Commands.Context);
BEGIN
	context.error.String("ShellCommands: no shell session -- this command needs one"); context.error.Ln;
	context.error.Update;
	context.result := Commands.CommandError
END NoSession;

PROCEDURE Alias*(context : Commands.Context);
VAR al: AliasList; alias, cmd, help: String;
BEGIN
	al := GetAliasList(context);
	IF al = NIL THEN NoSession(context); RETURN END;
	IF context.arg.GetString(alias) & context.arg.GetString(cmd) THEN
		context.out.String(alias); context.out.Char(09X); context.out.String(cmd); context.out.Ln;
		IF context.arg.GetString(help) THEN
			context.out.Char(09X); context.out.String(help); context.out.Ln()
		ELSE help := "";
		END;
		al.Alias(alias, cmd, help);
	ELSE
		al.List(context.out)
	END;
	Close(context);
END Alias;

PROCEDURE Delete*(context : Commands.Context);
VAR filename: Files.FileName; res: INTEGER;
BEGIN
	WHILE context.arg.GetString(filename) DO
		context.out.String(filename); context.out.Char(09X);
		Files.Delete(filename, res);
		IF res = Files.Ok THEN
			context.out.String("done");
		ELSE
			context.out.String("error: "); context.out.Int(res, 0)
		END;
		context.out.Ln;
	END;
	Close(context);
END Delete;

PROCEDURE Directory*(context : Commands.Context);
VAR
	enum: Files.Enumerator;
	name: Files.FileName; flags: SET; time, date: SIGNED32; size: Files.Size; tdrec: Dates.DateTime; str: ARRAY 32 OF CHAR;
BEGIN
	IF ~context.arg.GetString(str) THEN str := "*"; END;
	NEW(enum);
	enum.Open(str, {Files.EnumSize, Files.EnumTime});
	WHILE enum.GetEntry(name, flags, time, date, size) DO
		context.out.String(name); context.out.Char(09X); context.out.Int(size, 0); context.out.Char(09X);
		tdrec := Dates.OberonToDateTime(date, time);
		Dates.TimeToStr(tdrec, str);
		context.out.String(str); context.out.Ln()
	END;
	Close(context);
END Directory;

PROCEDURE Echo*(context : Commands.Context);
VAR in : Streams.Reader;
BEGIN
	IF (context.arg.Available() > 0) THEN
		in := context.arg;
	ELSE
		in := context.in;
	END;
	Streams.Copy (in, context.out);
	Close(context);
END Echo;

PROCEDURE Exit*(context : Commands.Context);
VAR ctx: Context;
BEGIN
	IF (context # NIL) & (context IS Context) THEN
		context.out.Ln(); context.out.String("logout"); context.out.Ln();
		ctx := context(Context);
		IF (ctx.C # NIL) & (ctx.C IS Streams.Connection) THEN
			ctx.C(Streams.Connection).Close()
		END
	END;
	Close(context);
END Exit;

PROCEDURE Free*(context : Commands.Context);
VAR name: AosModules.Name; msg: String; res: INTEGER;
BEGIN
	IF context.arg.GetString(name) THEN
		context.out.String(name); context.out.Char(09X);
		AosModules.FreeModule(name, res, msg);
		IF res = 0 THEN
			context.out.String("done")
		ELSE
			context.out.Int(res, 0); context.out.String(": "); context.out.String(msg)
		END;
		context.out.Ln;
	END;
	Close(context);
END Free;

PROCEDURE Help*(context : Commands.Context);
VAR name: String; al: AliasList; a: CmdAlias;
BEGIN
	IF ~context.arg.GetString(name) THEN name := "help" END;
	al := GetAliasList(context);
	IF al = NIL THEN NoSession(context); RETURN END;
	a := al.Find(name);
	IF a # NIL THEN
		context.out.String(a.help);
	ELSE
		context.out.String(name); context.out.Char(09X); context.out.String("no such alias");
	END;
	context.out.Ln;
	Close(context);
END Help;

PROCEDURE Modules*(context : Commands.Context);
VAR mod: AosModules.Module;
BEGIN
	mod := AosModules.root;
	WHILE mod # NIL DO
		context.out.String(mod.name); context.out.Char(09X);
		context.out.Int(mod.refcnt, 0); context.out.Ln();
		mod := mod.next
	END;
	Close(context);
END Modules;

(*
	cmdline = cmdpar { "|" cmdpar } [ ( ">" | ">>" ) file ] .
	cmdpar = cmd { par } [ "<" file ] .
*)
PROCEDURE execute(context : Commands.Context; VAR cmdline: ARRAY OF CHAR; flags: SET; VAR res: INTEGER; VAR msg: ARRAY OF CHAR);
VAR
	ctx: Context; R: Streams.StringReader; cmd, prev, cmds: Command; i, j, p, ofs, len: SIZE; ch, filter: CHAR;
	in, pR: Streams.Reader; out, err, pW: Streams.Writer; file: Files.FileName; F, newF: Files.File; fR: Files.Reader;
	fW: Files.Writer; pipe: Pipes.Pipe; a: CmdAlias; cmdString : POINTER TO ARRAY OF CHAR;
BEGIN
	IF (context = NIL) OR ~(context IS Context) THEN
		(* Start and Execute are reachable from anywhere; the type guard below is not a check *)
		res := -1; COPY("ShellCommands: no shell session -- this command needs one", msg); RETURN
	END;
	ctx := context(Context);
	len := LEN(cmdline); newF := NIL; cmds := NIL; prev := NIL;
	IF ctx.alias = NIL THEN NEW(ctx.alias) END; ofs := 0;
	in := ctx.in; out := ctx.out; err := ctx.error; pipe := NIL;
	NEW(R, len); R.Set(cmdline); R.SkipWhitespace();
	LOOP
		NEW(cmd, ctx); R.String(cmd.cmd);
		IF prev # NIL THEN
			prev.next := cmd;
			Streams.OpenReader(pR, pipe.Receive)
		ELSE
			cmds := cmd; pR := in
		END;
		prev := cmd;
		R.SkipWhitespace(); p := ofs + SIZE(R.Pos());
		IF p < len THEN
			i := p; ch := cmdline[i];
			WHILE (ch # 0X) & (ch # "|") & (ch # "<") & (ch # ">") DO
				INC(i); ch := cmdline[i]
			END;
			filter := ch
		ELSE
			i := len; filter := 0X
		END;
		IF p < i THEN
			NEW(cmdString, i-p+2); j := 0;
			ch := cmdline[p]; j := 0;
			WHILE (ch # 0X) & (p < i) DO
				cmdString[j] := ch; INC(j);
				INC(p); ch := cmdline[p]
			END;
			cmdString[j] := " "; INC(j);
			cmdString[j] := 0X;

			cmd.SetArguments(cmdString, j);
		ELSE
			cmdString := NIL;
			cmd.SetArguments(NIL, 0)   (* and not what the command before it on the line was given *)
		END;
		CASE filter OF
		"|": ofs := i+1; R.SetRaw(cmdline, ofs, len-ofs);
				NEW(pipe, 1024);
				Streams.OpenWriter(pW, pipe.Send);
				cmd.SetContext(pipe, pR, pW, err)
		|"<": ofs := i+1; R.SetRaw(cmdline, ofs, len-ofs);
				R.SkipWhitespace(); R.String(file);
				R.SkipWhitespace(); R.Char(ch);
				IF ch = "|" THEN
					NEW(pipe, 1024);
					Streams.OpenWriter(pW, pipe.Send)
				ELSE
					pipe := NIL
				END;
				F := Files.Old(file);
				IF F # NIL THEN
					Files.OpenReader(fR, F, 0);
					IF pR # in THEN
						res := -1; COPY("invalid command syntax", msg); RETURN
					END;
					IF pipe # NIL THEN
						cmd.SetContext(pipe, fR, pW, err)
					ELSE
						cmd.SetContext(ctx.C, fR, out, err)
					END
				ELSE
					res := -1; COPY("input file not found", msg); RETURN
				END;
				IF pipe = NIL THEN
					R.SkipWhitespace();
					IF R.res # Streams.EOF THEN
						res := -1; COPY("invalid command syntax", msg); RETURN
					END;
					EXIT
				END
		|">": IF cmdline[i+1] = ">" THEN
					ofs := i+2; R.SetRaw(cmdline, ofs, len-ofs);
					R.SkipWhitespace(); R.String(file);
					F := Files.Old(file);
					IF F # NIL THEN
						Files.OpenWriter(fW, F, F.Length());
						cmd.SetContext(ctx.C, pR, fW, err)
					ELSE
						res := -1; COPY("ouput file not found", msg); RETURN
					END
				ELSE
					ofs := i+1; R.SetRaw(cmdline, ofs, len-ofs);
					R.SkipWhitespace(); R.String(file);
					F := Files.New(file);
					IF F # NIL THEN
						Files.OpenWriter(fW, F, 0);
						cmd.SetContext(ctx.C, pR, fW, err);
						newF := F
					ELSE
						res := -1; COPY("ouput file not created", msg); RETURN
					END
				END;
				R.SkipWhitespace();
				IF R.res # Streams.EOF THEN
					res := -1; COPY("invalid command syntax", msg); RETURN
				END;
				EXIT
		ELSE
			cmd.SetContext(ctx.C, pR, out, err); EXIT
		END;
		R.SkipWhitespace();
		IF R.res # Streams.Ok THEN
			res := -1; COPY("invalid command syntax", msg); RETURN
		END
	END;
	prev := NIL; cmd := cmds;
	WHILE cmd # NIL DO
		a := ctx.alias.Find(cmd.cmd);
		IF a # NIL THEN COPY(a.cmd, cmd.cmd) END;
		IF cmd.next = NIL THEN
			Commands.Activate(cmd.cmd, cmd.ctx, flags, res, msg)
		ELSE
			Commands.Activate(cmd.cmd, cmd.ctx, {}, res, msg)
		END;
		IF res # 0 THEN RETURN END;
		prev := cmd; cmd := cmd.next
	END;
	IF newF # NIL THEN
		prev.ctx.out.Update();
		Files.Register(newF)
	END
END execute;

PROCEDURE Start*(context : Commands.Context);
VAR msg: String; len: SIZE; res: INTEGER; string : POINTER TO ARRAY OF CHAR;
BEGIN
	IF (context.arg IS Streams.StringReader) & (context.arg.Available() > 0) THEN
		NEW(string, context.arg.Available() +1);
		context.arg.Bytes(string^, 0, context.arg.Available(), len);
		string[LEN(string)-1] := 0X;
		execute(context, string^, {}, res, msg);
		IF res # 0 THEN
			context.out.Int(res, 0); context.out.String(": "); context.out.String(msg); context.out.Ln();
			context.result := Commands.CommandError   (* printing it is not the same as reporting it *)
		END
	END;
	Close(context);
END Start;

PROCEDURE Version*(context : Commands.Context);
BEGIN
	context.out.String(Machine.version); context.out.Ln;
	Close(context);
END Version;

PROCEDURE Execute*(par: Commands.Context;  VAR cmdline: ARRAY OF CHAR; VAR res: INTEGER; VAR msg: ARRAY OF CHAR);
BEGIN
	execute(par, cmdline, {Commands.Wait}, res, msg)
END Execute;

END ShellCommands.
