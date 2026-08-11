MODULE Ob;	(** AUTHOR "minia2"; PURPOSE "The ob command line, in Active Oberon"; *)

(*
	`ob` as a program instead of a shell script. The point is not to translate 1062 lines of bash --
	it is that the compiler and the linker are linked into this very binary, so a verb calls them
	instead of starting a process, and the whole thing ships as one executable per platform.

	Two things the bash version had to work around fall away here:

	-  The scratch directory full of symlinks to the standard library. It existed because the
	   compiler was believed to resolve imports from the current directory alone; it resolves them
	   through the Files search path just as well, so a verb names lib/ and is done.
	-  Reading the SDK's own ELF header to learn its architecture. This binary IS the architecture,
	   so the answer is a compile-time constant.

	What is NOT here yet is deliberate: see Verb below. Anything unimplemented says so and exits 1,
	because a driver that silently does nothing is worse than the shell script it replaces.
*)

IMPORT StdIO, Commands, Modules, Streams, Strings, Files, Diagnostics, Compiler,
	SyntaxTree := FoxSyntaxTree, ObHost;

CONST
	MaxPath = ObHost.MaxPath;

	(* The architecture this binary was compiled for, which is the only "host" that means anything:
	   an x86-64 SDK under an emulator is still an x86-64 SDK. *)
#IF ARM64 THEN
	HostTarget = "a64";
	ObjectExtension = "GofU8"; SymbolExtension = ".SymU8";
	CompilerPlatform = "UnixA64"; LinkerPlatform = "LinuxA64";
#ELSE
	HostTarget = "linux64";
	ObjectExtension = "GofUu"; SymbolExtension = ".SymUu";
	CompilerPlatform = "Unix64"; LinkerPlatform = "Linux64";
#END

	DefaultSdk = "/opt/a2sdk";

TYPE
	Path = ObHost.Path;

VAR
	out, error: Streams.Writer;
	failed: BOOLEAN;

	sdk-, project-: Path;			(* the SDK this binary belongs to; the directory the user is in *)
	lib-, libWin-, libA64-, libSym-: Path;
	packages-, bootList-, bootListWin-: Path;

(* --- paths ------------------------------------------------------------------------------- *)

PROCEDURE Join*(CONST dir, name: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
VAR length: SIZE;
BEGIN
	COPY(dir, path);
	length := Strings.Length(path);
	IF (length > 0) & (path[length-1] # '/') THEN Strings.AppendChar(path, '/') END;
	Strings.Append(path, name)
END Join;

(** The directory part of a path, without its trailing separator. "" when there is none. *)
PROCEDURE Directory*(CONST path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
VAR i: SIZE;
BEGIN
	COPY(path, dir);
	i := Strings.Length(dir);
	WHILE (i > 0) & (dir[i-1] # '/') DO DEC(i) END;
	IF i = 0 THEN dir := "" ELSE dir[i-1] := 0X END	(* i-1 drops the separator itself *)
END Directory;

(** The last component of a path. *)
PROCEDURE BaseName*(CONST path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, length: SIZE;
BEGIN
	length := Strings.Length(path); i := length;
	WHILE (i > 0) & (path[i-1] # '/') DO DEC(i) END;
	Strings.Copy(path, i, length - i, name)
END BaseName;

(* --- output ------------------------------------------------------------------------------ *)

(* Streams.Writer.Ln writes CR LF, which is not what a program on a Unix terminal writes and not
   what anything reading ob's output would expect. Every line ob writes itself ends here instead. *)
PROCEDURE EndLine(writer: Streams.Writer);
BEGIN writer.Char(0AX); writer.Update
END EndLine;

PROCEDURE Say*(CONST text: ARRAY OF CHAR);
BEGIN out.String(text); EndLine(out)
END Say;

(** Report a failure the way the shell version did -- "ob: ..." on standard error -- and fail the run. *)
PROCEDURE Die*(CONST text: ARRAY OF CHAR);
BEGIN
	error.String("ob: "); error.String(text); EndLine(error); failed := TRUE
END Die;

PROCEDURE DieOn*(CONST text, detail: ARRAY OF CHAR);
BEGIN
	error.String("ob: "); error.String(text); error.String(detail); EndLine(error); failed := TRUE
END DieOn;

(* --- the SDK this binary belongs to ------------------------------------------------------- *)

(*
	$A2SDK wins; failing that, the directory this binary sits in, with symlinks followed -- which is
	what lets `ln -s /opt/a2sdk/ob ~/.local/bin/ob` work with no environment at all. lib/ is the
	marker: it is what every verb needs and what no other directory has.
*)
PROCEDURE FindSdk(): BOOLEAN;
VAR exe, dir, candidate: Path;
BEGIN
	IF ObHost.Env("A2SDK", sdk) & (sdk # "") THEN RETURN TRUE END;
	IF ObHost.ExecutablePath(exe) THEN
		Directory(exe, dir);
		Join(dir, "lib", candidate);
		IF ObHost.Exists(candidate) THEN COPY(dir, sdk); RETURN TRUE END
	END;
	sdk := DefaultSdk;
	RETURN ObHost.Exists(sdk)
END FindSdk;

PROCEDURE Layout;
BEGIN
	Join(sdk, "lib", lib);
	Join(sdk, "lib-win64", libWin);
	Join(sdk, "lib-a64", libA64);
	Join(sdk, "lib-sym", libSym);
	Join(sdk, "packages", packages);
	Join(sdk, "boot-modules.txt", bootList);
	Join(sdk, "boot-modules-win64.txt", bootListWin);
	(* On an AArch64 SDK the native objects ARE the AArch64 objects; there is no separate lib-a64. *)
	IF (HostTarget = "a64") & ~ObHost.Exists(libA64) THEN COPY(lib, libA64) END
END Layout;

(** Where the user's sources, a2pkg.json and .a2pkg/ live: the directory ob was started in. *)
PROCEDURE FindProject;
BEGIN
	IF ~ObHost.Env("A2_PROJECT", project) OR (project = "") THEN
		IF ~ObHost.CurrentDirectory(project) THEN project := "." END
	END
END FindProject;

(* --- arguments ---------------------------------------------------------------------------- *)

VAR argument: SIGNED32;		(* the next command-line argument a verb has not read yet *)

PROCEDURE NextArgument(VAR value: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF argument >= ObHost.ArgCount() THEN value := ""; RETURN FALSE END;
	ObHost.Arg(argument, value); INC(argument); RETURN TRUE
END NextArgument;

(* --- talking to the compiler and the file system ------------------------------------------- *)

(*
	Run one A2 command in this process. Paths are quoted because the option parser on the other
	side stops at the first character that cannot be in a name: an unquoted /home/a-b/x becomes
	/home/a followed by the flags -b. That is the same bug that made `ob build -o hello-arm64`
	write a file called `hello`.
*)
PROCEDURE Execute(CONST command, arguments: ARRAY OF CHAR): BOOLEAN;
VAR reader: Streams.StringReader; context: Commands.Context;
	result: INTEGER; message: ARRAY 256 OF CHAR;
BEGIN
	NEW(reader, LEN(arguments)); reader.Set(arguments);
	NEW(context, StdIO.env.in, reader, out, error, NIL);
	Commands.Activate(command, context, {Commands.Wait}, result, message);
	IF result # Commands.Ok THEN Die(message); RETURN FALSE END;
	RETURN TRUE
END Execute;

PROCEDURE Quoted(CONST text: ARRAY OF CHAR; VAR quoted: ARRAY OF CHAR);
BEGIN
	quoted := '"'; Strings.Append(quoted, text); Strings.AppendChar(quoted, '"')
END Quoted;

(** Where imports are resolved from. Unlike a shell, this is the whole of what the scratch
	directory full of symlinks used to do. *)
PROCEDURE AddSearchPath(CONST directory: ARRAY OF CHAR): BOOLEAN;
VAR quoted: Path;
BEGIN
	IF ~ObHost.Exists(directory) THEN RETURN TRUE END;		(* absent lib-a64 is not an error *)
	Quoted(directory, quoted);
	RETURN Execute("UnixFiles.AddSearchPath", quoted)
END AddSearchPath;

(** Where the compiler writes what it produces. *)
PROCEDURE SetWorkPath(CONST directory: ARRAY OF CHAR): BOOLEAN;
VAR quoted: Path;
BEGIN
	Quoted(directory, quoted);
	RETURN Execute("UnixFiles.SetWorkPath", quoted)
END SetWorkPath;

(** The name after MODULE, which is what the compiler names its output after -- so a source
	called Unix.ObHost.Mod produces ObHost.GofUu, and the caller has to know that. *)
PROCEDURE ModuleName(CONST file: ARRAY OF CHAR; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR handle: Files.File; reader: Files.Reader; line: ARRAY 1024 OF CHAR; position, length: SIZE;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	WHILE reader.res = Streams.Ok DO
		reader.Ln(line);
		(* the header, not a mention of it: MODULE has to open the line, as the shell's grep required *)
		position := 0;
		WHILE (line[position] = ' ') OR (line[position] = 9X) DO INC(position) END;
		IF Strings.Pos("MODULE ", line) = position THEN
			INC(position, 7);
			WHILE line[position] = ' ' DO INC(position) END;
			length := 0;
			WHILE ((line[position] >= 'A') & (line[position] <= 'Z'))
					OR ((line[position] >= 'a') & (line[position] <= 'z'))
					OR ((line[position] >= '0') & (line[position] <= '9'))
					OR (line[position] = '_') DO
				name[length] := line[position]; INC(length); INC(position)
			END;
			name[length] := 0X;
			RETURN length > 0
		END
	END;
	RETURN FALSE
END ModuleName;

(*
	Compile one source file, in this process. This is where the shell script started a compiler
	and this does not: Compiler.GetOptions turns an option string into a record, Compiler.Modules
	does the work, and the diagnostics come back as a list instead of as text to grep.
*)
PROCEDURE CompileFile(CONST file, platform, objectExtension, symbolExtension: ARRAY OF CHAR;
		report: BOOLEAN): BOOLEAN;
VAR optionReader: Streams.StringReader; options: Compiler.CompilerOptions;
	handle: Files.File; reader: Files.Reader;
	diagnostics: Diagnostics.DiagnosticsList; logBuffer: Streams.Buffer; log: Streams.Writer;
	importCache: SyntaxTree.ModuleScope; text: ARRAY 256 OF CHAR; compiled: BOOLEAN;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN IF report THEN Die("cannot open the source file") END; RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);

	text := "-p="; Strings.Append(text, platform);
	Strings.Append(text, " --objectFileExtension="); Strings.Append(text, objectExtension);
	Strings.Append(text, " --symbolFileExtension="); Strings.Append(text, symbolExtension);
	Streams.OpenStringReader(optionReader, text);

	NEW(diagnostics); NEW(logBuffer, 1024); log := logBuffer.GetWriter();
	IF ~Compiler.GetOptions(optionReader, error, diagnostics, options) THEN
		IF report THEN Die("the compiler rejected its own options -- this is a bug in ob") END;
		RETURN FALSE
	END;
	importCache := NIL;
	compiled := Compiler.Modules(file, reader, 0, diagnostics, log, options, importCache);
	log.Update;
	IF report THEN diagnostics.ToStream(error, Diagnostics.All); error.Update END;
	RETURN compiled
END CompileFile;

(*
	Compile the project's other modules until nothing new compiles, so that the module the user
	named can import its siblings with nothing listed anywhere. One round cannot do it: the
	compiler takes files in the order given, not in dependency order, so a module whose import is
	later in the round fails and succeeds next time. Modules that never compile are left alone --
	if the user's module needed one, its own diagnostics say which import is missing.
*)
PROCEDURE BuildSiblings(CONST work, platform, objectExtension, symbolExtension: ARRAY OF CHAR);
VAR enumerator: Files.Enumerator; mask, file, name, symbol: Path;
	flags: SET; time, date: SIGNED32; size: Files.Size; changed: BOOLEAN;
BEGIN
	Join(project, "*.Mod", mask);
	REPEAT
		changed := FALSE;
		NEW(enumerator); enumerator.Open(mask, {});
		WHILE enumerator.GetEntry(file, flags, time, date, size) DO
			IF ModuleName(file, name) THEN
				Join(work, name, symbol); Strings.Append(symbol, symbolExtension);
				IF ~ObHost.Exists(symbol)
						& CompileFile(file, platform, objectExtension, symbolExtension, FALSE) THEN
					changed := TRUE
				END
			END
		END;
		enumerator.Close
	UNTIL ~changed
END BuildSiblings;

(*
	Search paths every verb wants: the standard library, the user's own directory, and where this
	run writes -- the last one because a sibling compiled a moment ago has to be findable, and the
	working directory is not searched once a search path exists.
*)
PROCEDURE PrepareIn(CONST work: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN AddSearchPath(lib) & AddSearchPath(project) & AddSearchPath(work) & SetWorkPath(work)
END PrepareIn;

(* --- verbs ------------------------------------------------------------------------------- *)

(* How many modules a library directory holds, counted by its symbol files. *)
PROCEDURE CountModules(CONST directory, extension: ARRAY OF CHAR): SIZE;
VAR enumerator: Files.Enumerator; mask, name: Path; flags: SET; time, date: SIGNED32;
	size: Files.Size; count: SIZE;
BEGIN
	Join(directory, "*", mask); Strings.Append(mask, extension);
	count := 0;
	NEW(enumerator); enumerator.Open(mask, {});
	WHILE enumerator.GetEntry(name, flags, time, date, size) DO INC(count) END;
	enumerator.Close;
	RETURN count
END CountModules;

PROCEDURE WriteCount(CONST label, directory, extension: ARRAY OF CHAR);
VAR line: ARRAY 128 OF CHAR;
BEGIN
	line := "            ";
	Strings.AppendInt(line, CountModules(directory, extension));
	Strings.Append(line, " modules ("); Strings.Append(line, label); Strings.Append(line, ")");
	Say(line)
END WriteCount;

PROCEDURE ReadVersion(VAR version: ARRAY OF CHAR): BOOLEAN;
VAR name: Path; file: Files.File; reader: Files.Reader;
BEGIN
	Join(sdk, "VERSION", name);
	file := Files.Old(name);
	IF file = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, file, 0);
	reader.Ln(version);
	RETURN version # ""
END ReadVersion;

PROCEDURE Version;
VAR line, version: Path; targets: ARRAY 128 OF CHAR;
BEGIN
	line := "A2 (Active Oberon) SDK — minia2";
	IF ReadVersion(version) THEN Strings.AppendChar(line, ' '); Strings.Append(line, version) END;
	Say(line);
	line := "  sdk     : "; Strings.Append(line, sdk); Say(line);
	line := "  runtime : this binary ("; Strings.Append(line, HostTarget); Strings.Append(line, ")"); Say(line);
	line := "  stdlib  : "; Strings.AppendInt(line, CountModules(lib, SymbolExtension));
	Strings.Append(line, " modules ("); Strings.Append(line, HostTarget); Strings.Append(line, ")");
	Say(line);
#IF ARM64 THEN
	targets := "a64 (ELF, native)";
#ELSE
	targets := "linux64 (ELF)";
	IF ObHost.Exists(libWin) THEN
		WriteCount("win64", libWin, ".SymWw"); Strings.Append(targets, ", win64 (PE .exe)")
	END;
	IF ObHost.Exists(libA64) THEN
		WriteCount("a64", libA64, ".SymU8"); Strings.Append(targets, ", a64 (AArch64 ELF)")
	END;
#END
	line := "  targets : "; Strings.Append(line, targets); Say(line)
END Version;

(* Read the source name and an optional -o from the command line; TRUE when they make sense. *)
PROCEDURE ReadSourceAndOutput(CONST usage: ARRAY OF CHAR; VAR source, output: ARRAY OF CHAR): BOOLEAN;
VAR argument: Path;
BEGIN
	source := "";
	WHILE NextArgument(argument) DO
		IF (argument = "-o") OR (argument = "--output") THEN
			IF ~NextArgument(output) THEN Die(usage); RETURN FALSE END
		ELSIF argument[0] = '-' THEN
			DieOn("unknown option: ", argument); RETURN FALSE
		ELSE COPY(argument, source)
		END
	END;
	IF source = "" THEN Die(usage); RETURN FALSE END;
	RETURN TRUE
END ReadSourceAndOutput;

PROCEDURE CompileVerb;
VAR source, output, absolute, work, name, line: Path;
BEGIN
	output := ".";
	IF ~ReadSourceAndOutput("usage: ob compile <File.Mod> [-o <dir>]", source, output) THEN RETURN END;
	IF ~ObHost.RealPath(source, absolute) THEN DieOn("no such file: ", source); RETURN END;
	IF ~ObHost.Exists(output) & ~ObHost.MakeDirectory(output) THEN
		DieOn("cannot create the output directory: ", output); RETURN
	END;
	IF ~ObHost.RealPath(output, work) THEN DieOn("no such directory: ", output); RETURN END;
	IF ~ModuleName(absolute, name) THEN DieOn("no MODULE header in ", source); RETURN END;
	IF ~PrepareIn(work) THEN RETURN END;
	BuildSiblings(work, CompilerPlatform, ObjectExtension, SymbolExtension);
	IF ~CompileFile(absolute, CompilerPlatform, ObjectExtension, SymbolExtension, TRUE) THEN
		failed := TRUE; RETURN
	END;
	line := "ob: wrote "; Join(work, name, work);
	Strings.Append(line, work); Strings.AppendChar(line, '.'); Strings.Append(line, ObjectExtension);
	Say(line)
END CompileVerb;

(*
	A directory of this process's own, for objects nobody asked to keep. Named after the process
	id: two ob runs in the same project must not compile over each other.
*)
PROCEDURE ScratchDirectory(VAR path: ARRAY OF CHAR): BOOLEAN;
VAR temporary: Path; name: ARRAY 32 OF CHAR;
BEGIN
	IF ~ObHost.Env("TMPDIR", temporary) OR (temporary = "") THEN temporary := "/tmp" END;
	name := "ob-"; Strings.AppendInt(name, ObHost.ProcessId());
	Join(temporary, name, path);
	RETURN ObHost.MakeDirectory(path)
END ScratchDirectory;

(*
	Leave the directory before emptying it, and list it with opendir rather than through Files:
	the compiler writes each output as a hidden .tmp.<n>.<pid> first, and Files' own enumerator
	refuses to show any name that begins with a dot. Emptied through Files, this directory looks
	empty and rmdir still answers ENOTEMPTY.
*)
PROCEDURE DiscardScratch(CONST directory: ARRAY OF CHAR);
VAR handle: ADDRESS; name, file: Path; ignore: BOOLEAN;
BEGIN
	ignore := SetWorkPath(project);
	handle := ObHost.OpenDirectory(directory);
	IF handle # 0 THEN
		WHILE ObHost.NextEntry(handle, name) DO
			IF (name # ".") & (name # "..") THEN
				Join(directory, name, file); ignore := ObHost.Remove(file)
			END
		END;
		ObHost.CloseDirectory(handle)
	END;
	ignore := ObHost.RemoveDirectory(directory)
END DiscardScratch;

(*
	Compile and run. The shell version execed a second process here; this one loads the module
	into itself, which is the same mechanism `ob build` bakes into a binary and the same one that
	took until 05.08.2026 to work on AArch64.
*)
PROCEDURE RunVerb;
VAR source, absolute, scratch, name, command: Path; procedure: Path;
	result: INTEGER; message: ARRAY 256 OF CHAR;
BEGIN
	IF ~NextArgument(source) OR (source = "") THEN
		Die("usage: ob run <File.Mod> [Proc]"); RETURN
	END;
	IF ~NextArgument(procedure) OR (procedure = "") THEN procedure := "Do" END;
	IF ~ObHost.RealPath(source, absolute) THEN DieOn("no such file: ", source); RETURN END;
	IF ~ModuleName(absolute, name) THEN DieOn("no MODULE header in ", source); RETURN END;
	IF ~ScratchDirectory(scratch) THEN Die("cannot create a scratch directory"); RETURN END;
	IF ~PrepareIn(scratch) THEN RETURN END;
	BuildSiblings(scratch, CompilerPlatform, ObjectExtension, SymbolExtension);
	IF CompileFile(absolute, CompilerPlatform, ObjectExtension, SymbolExtension, TRUE) THEN
		COPY(name, command); Strings.AppendChar(command, '.'); Strings.Append(command, procedure);
		Commands.Call(command, {Commands.Wait}, result, message);
		IF result # Commands.Ok THEN Die(message) END
	ELSE
		failed := TRUE
	END;
	DiscardScratch(scratch)
END RunVerb;

PROCEDURE Help;
BEGIN
	Say("ob — a Go-style CLI over the A2 (Active Oberon) toolchain.");
	Say("");
	Say("  ob compile <File.Mod> [-o <dir>]   compile one module to an object file");
	Say("  ob run     <File.Mod> [Proc]       compile, then run a command (default: Do)");
	Say("  ob version                         print the SDK version banner");
	Say("  ob help                            this text");
	Say("");
	Say("Verbs still served by the shell version: build, get, lint, test, doc, lsp, repl.")
END Help;

(* --- entry ------------------------------------------------------------------------------- *)

PROCEDURE Dispatch(CONST verb: ARRAY OF CHAR);
VAR message: ARRAY 128 OF CHAR;
BEGIN
	IF verb = "compile" THEN CompileVerb
	ELSIF verb = "run" THEN RunVerb
	ELSIF (verb = "version") OR (verb = "--version") OR (verb = "-v") THEN Version
	ELSIF (verb = "") OR (verb = "help") OR (verb = "-h") OR (verb = "--help") THEN Help
	ELSE
		message := "unknown command: "; Strings.Append(message, verb);
		Strings.Append(message, " (try: ob help)"); Die(message)
	END
END Dispatch;

(** The whole command line. Returns FALSE when the run failed, which the caller turns into exit 1. *)
PROCEDURE Run*(): BOOLEAN;
VAR verb: Path;
BEGIN
	out := StdIO.env.out; error := StdIO.env.error; failed := FALSE;
	IF ~FindSdk() THEN
		Die("no SDK found: set A2SDK to the SDK root (the directory holding lib/)");
		RETURN FALSE
	END;
	Layout; FindProject;
	ObHost.Arg(1, verb); argument := 2;
	Dispatch(verb);
	RETURN ~failed
END Run;

(*
	The whole binary is this module: it is linked last, its body is the program, and the exit code
	comes out of Modules.Shutdown -- Reboot is 0, PowerDown is 1. The work happens on an activity
	of its own rather than in the body, for the same reason StdIOShell does it: a command wants a
	process with the usual data structures around it, and the module loader has not finished here.
*)
TYPE
	Executor = OBJECT
	VAR
		done := FALSE: BOOLEAN;
		code := Modules.PowerDown: SIGNED32;

		PROCEDURE Wait;
		BEGIN {EXCLUSIVE}
			AWAIT(done)
		END Wait;

	BEGIN {ACTIVE, EXCLUSIVE}
		IF Run() THEN code := Modules.Reboot END;
	FINALLY
		done := TRUE
	END Executor;

VAR executor: Executor;

BEGIN
	NEW(executor); executor.Wait;
	Modules.Shutdown(executor.code)
END Ob.
