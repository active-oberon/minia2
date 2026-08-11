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

IMPORT StdIO, Commands, Modules, Streams, Strings, Files, Diagnostics, JSON, Compiler, Linker,
	Shell, LSP, Objects, Trace, SyntaxTree := FoxSyntaxTree, FoxScanner, FoxParser, FoxBasic, FoxGlobal,
	ObHost;

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

(* The linker, called rather than started. Its result comes back through the context. *)
PROCEDURE Link(CONST arguments: ARRAY OF CHAR): BOOLEAN;
VAR reader: Streams.StringReader; context: Commands.Context; buffer: Streams.Buffer;
	quiet: Streams.Writer;
BEGIN
	NEW(reader, LEN(arguments)); reader.Set(arguments);
	(* the linker narrates every module it reads; the user asked for a binary, not for that *)
	NEW(buffer, 4096); quiet := buffer.GetWriter();
	NEW(context, StdIO.env.in, reader, quiet, error, NIL);
	Linker.Link(context);
	quiet.Update;
	RETURN context.result = Commands.Ok
END Link;

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
PROCEDURE CompileReader(CONST name: ARRAY OF CHAR; reader: Streams.Reader;
		CONST platform, objectExtension, symbolExtension: ARRAY OF CHAR; report: BOOLEAN): BOOLEAN;
VAR optionReader: Streams.StringReader; options: Compiler.CompilerOptions;
	diagnostics: Diagnostics.DiagnosticsList; logBuffer: Streams.Buffer; log: Streams.Writer;
	importCache: SyntaxTree.ModuleScope; text: ARRAY 256 OF CHAR; compiled: BOOLEAN;
BEGIN
	text := "-p="; Strings.Append(text, platform);
	Strings.Append(text, " --objectFileExtension="); Strings.Append(text, objectExtension);
	Strings.Append(text, " --symbolFileExtension="); Strings.Append(text, symbolExtension);
	Streams.OpenStringReader(optionReader, text);

	NEW(diagnostics); NEW(logBuffer, 1024); log := logBuffer.GetWriter();
	IF ~Compiler.GetOptions(optionReader, error, diagnostics, options) THEN
		IF report THEN
			diagnostics.ToStream(error, Diagnostics.All);
			DieOn("the compiler rejected these options: ", text)
		END;
		RETURN FALSE
	END;
	importCache := NIL;
	compiled := Compiler.Modules(name, reader, 0, diagnostics, log, options, importCache);
	log.Update;
	IF report THEN diagnostics.ToStream(error, Diagnostics.All); error.Update END;
	RETURN compiled
END CompileReader;

PROCEDURE CompileFile(CONST file, platform, objectExtension, symbolExtension: ARRAY OF CHAR;
		report: BOOLEAN): BOOLEAN;
VAR handle: Files.File; reader: Files.Reader;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN IF report THEN Die("cannot open the source file") END; RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	RETURN CompileReader(file, reader, platform, objectExtension, symbolExtension, report)
END CompileFile;

(*
	The documentation backend writes to the trace channel whatever it is asked: a leftover
	TRACE(name, extension) in FoxDocumentationBackend.ProcessSyntaxTreeModule, and "error in
	parsing" without a position, seven times per module, from the doc-comment parser's Expect.
	Neither is ob's to fix here -- both are the compiler's, and both are worth an upstream patch --
	but neither belongs on the terminal of someone who asked for HTML. Trace.Char is a procedure
	variable, so it can be pointed at nothing for as long as the backend runs.

	A trap during those seconds would lose its message. It is seconds, and only around this.
*)
VAR previousTraceChar: Trace.CharProc;

PROCEDURE Swallow(character: CHAR);
BEGIN {UNCOOPERATIVE, UNCHECKED}
END Swallow;

PROCEDURE SilenceTrace;
BEGIN previousTraceChar := Trace.Char; Trace.Char := Swallow
END SilenceTrace;

PROCEDURE RestoreTrace;
BEGIN Trace.Char := previousTraceChar
END RestoreTrace;

(* The same compiler, asked for a page instead of an object: no object file extension, so nothing
   is generated, and the Documentation backend writes the HTML into the working directory. *)
PROCEDURE CompileForDocumentation(CONST file, page: ARRAY OF CHAR): BOOLEAN;
VAR optionReader: Streams.StringReader; options: Compiler.CompilerOptions;
	handle: Files.File; reader: Files.Reader;
	diagnostics: Diagnostics.DiagnosticsList; logBuffer: Streams.Buffer; log: Streams.Writer;
	importCache: SyntaxTree.ModuleScope; text: ARRAY 256 OF CHAR; compiled: BOOLEAN;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN Die("cannot open the source file"); RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	text := "-p="; Strings.Append(text, CompilerPlatform);
	Strings.Append(text, " --symbolFileExtension="); Strings.Append(text, SymbolExtension);
	Strings.Append(text, " --documentation='"); Strings.Append(text, page); Strings.AppendChar(text, "'");
	Streams.OpenStringReader(optionReader, text);
	NEW(diagnostics); NEW(logBuffer, 1024); log := logBuffer.GetWriter();
	IF ~Compiler.GetOptions(optionReader, error, diagnostics, options) THEN
		diagnostics.ToStream(error, Diagnostics.All); DieOn("the compiler rejected these options: ", text);
		RETURN FALSE
	END;
	importCache := NIL;
	SilenceTrace;
	compiled := Compiler.Modules(file, reader, 0, diagnostics, log, options, importCache);
	RestoreTrace;
	log.Update;
	(* only when it failed: the backend complains about a missing documentation template on every
	   module, no SDK ships one, and it produces the page regardless *)
	IF ~compiled THEN diagnostics.ToStream(error, Diagnostics.All); error.Update END;
	RETURN compiled
END CompileForDocumentation;

(* A number out of the environment, with a fallback for anything that is not one. *)
PROCEDURE ToInteger(CONST text: ARRAY OF CHAR; default: SIGNED32): SIGNED32;
VAR value: SIGNED32; position: SIZE;
BEGIN
	position := 0; value := 0;
	Strings.StrToIntPos(text, value, position);
	IF value <= 0 THEN RETURN default END;
	RETURN value
END ToInteger;

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

(* Read an optional source name and an optional -o from the command line. *)
PROCEDURE ReadSourceAndOutputOptional(CONST usage: ARRAY OF CHAR; VAR source, output: ARRAY OF CHAR): BOOLEAN;
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
	RETURN TRUE
END ReadSourceAndOutputOptional;

(* The same, for the verbs that cannot do without the source. *)
PROCEDURE ReadSourceAndOutput(CONST usage: ARRAY OF CHAR; VAR source, output: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF ~ReadSourceAndOutputOptional(usage, source, output) THEN RETURN FALSE END;
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

(*
	Everything that differs between the three targets, in one place. The compiler platform and the
	linker platform are not the same name for the same thing: one says how to generate code, the
	other where the image is loaded and in what file format.
*)
PROCEDURE TargetSettings(CONST target: ARRAY OF CHAR;
		VAR compilerPlatform, objectExtension, symbolExtension, linkOptions, suffix, boot: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF (HostTarget = "a64") & (target # "a64") THEN
		DieOn("this SDK's runtime is AArch64 and ships no objects for target ", target); RETURN FALSE
	END;
	IF target = "linux64" THEN
		compilerPlatform := "Unix64"; objectExtension := "GofUu"; symbolExtension := ".SymUu";
		linkOptions := "-p=Linux64 --extension=GofUu"; suffix := ""; COPY(bootList, boot)
	ELSIF target = "win64" THEN
		compilerPlatform := "Win64"; objectExtension := "GofWw"; symbolExtension := ".SymWw";
		linkOptions := "--fileFormat=PE64CUI --extension=GofWw --displacement=401000H";
		suffix := ".exe"; COPY(bootListWin, boot)
	ELSIF target = "a64" THEN
		(* the same boot list as linux64: it names modules, and every one of them has an AArch64
		   build. Glue writes the ELF header itself, so the linker only needs the displacement,
		   which -p=LinuxA64 carries. *)
		compilerPlatform := "UnixA64"; objectExtension := "GofU8"; symbolExtension := ".SymU8";
		linkOptions := "-p=LinuxA64 --extension=GofU8"; suffix := ""; COPY(bootList, boot)
	ELSE
		DieOn("unknown target: ", target); RETURN FALSE
	END;
	IF ~ObHost.Exists(boot) THEN DieOn("no boot module list at ", boot); RETURN FALSE END;
	RETURN TRUE
END TargetSettings;

(** Where the objects for a target live. *)
PROCEDURE TargetLibrary(CONST target: ARRAY OF CHAR; VAR directory: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF target = "win64" THEN COPY(libWin, directory)
	ELSIF (target = "a64") & (HostTarget # "a64") THEN COPY(libA64, directory)
	ELSE COPY(lib, directory)
	END;
	IF ~ObHost.Exists(directory) THEN
		DieOn("this SDK ships no objects for target ", target); RETURN FALSE
	END;
	RETURN TRUE
END TargetLibrary;

(*
	The boot set as one line for the linker, without the interactive shell: the generated entry
	module drives startup instead. The rest of the closure the linker resolves by itself.
*)
PROCEDURE ReadBootList(CONST file: ARRAY OF CHAR; VAR list: ARRAY OF CHAR): BOOLEAN;
VAR handle: Files.File; reader: Files.Reader; line: Path;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	list := "";
	WHILE reader.res = Streams.Ok DO
		reader.Ln(line);
		Strings.Trim(line, ' '); Strings.Trim(line, 0DX);
		IF (line # "") & (line[0] # '#') & (line # "StdIOShell") & (line # "Shell") THEN
			Strings.Append(list, line); Strings.AppendChar(list, ' ')
		END
	END;
	RETURN list # ""
END ReadBootList;

(*
	The module that replaces the interactive shell in a built binary: its body runs at startup,
	calls the chosen command and turns success into an exit code (Reboot is 0, PowerDown is 1).
	Importing the user's module is what makes the linker include it.

	It is never written to disk. Compiler.Modules reads from any Streams.Reader, so the source of
	a generated module can be a string -- which is one more file the shell version had to create,
	name and delete.
*)
PROCEDURE EntrySource(CONST module, procedure: ARRAY OF CHAR; VAR source: ARRAY OF CHAR);
BEGIN
	(* the command name is quoted with apostrophes: Oberon has no escape inside a string, so a
	   double quote here would have to be written as one, and generated source is hard enough to
	   read already *)
	source := "MODULE ObEntry; IMPORT Commands, Modules, Trace, ";
	Strings.Append(source, module);
	Strings.Append(source, "; VAR res: INTEGER; msg: ARRAY 256 OF CHAR;");
	Strings.Append(source, " BEGIN Commands.Call('");
	Strings.Append(source, module); Strings.AppendChar(source, '.');
	Strings.Append(source, procedure);
	Strings.Append(source, "', {Commands.Wait}, res, msg);");
	Strings.Append(source, " IF res = 0 THEN Modules.Shutdown(Modules.Reboot)");
	Strings.Append(source, " ELSE Trace.String(msg); Trace.Ln; Modules.Shutdown(Modules.PowerDown) END");
	Strings.Append(source, " END ObEntry.")
END EntrySource;

PROCEDURE CompileString(CONST name, source, platform, objectExtension, symbolExtension: ARRAY OF CHAR): BOOLEAN;
VAR reader: Streams.StringReader;
BEGIN
	NEW(reader, LEN(source)); reader.Set(source);
	RETURN CompileReader(name, reader, platform, objectExtension, symbolExtension, TRUE)
END CompileString;

PROCEDURE BuildVerb;
VAR source, output, absolute, scratch, destination, directory, fileName, name: Path;
	target, procedure, argument: Path;
	compilerPlatform, objectExtension, symbolExtension, suffix: Path;
	linkOptions, boot, bootModules, library: Path;
	arguments: ARRAY 4096 OF CHAR; entry: ARRAY 1024 OF CHAR; line: Path;
BEGIN
	source := ""; output := ""; procedure := "Do"; COPY(HostTarget, target);
	WHILE NextArgument(argument) DO
		IF (argument = "-o") OR (argument = "--output") THEN
			IF ~NextArgument(output) THEN Die("-o needs a name"); RETURN END
		ELSIF (argument = "-t") OR (argument = "--target") THEN
			IF ~NextArgument(target) THEN Die("-t needs a target"); RETURN END
		ELSIF argument[0] = '-' THEN
			DieOn("unknown option: ", argument); RETURN
		ELSIF source = "" THEN COPY(argument, source)
		ELSE COPY(argument, procedure)
		END
	END;
	IF source = "" THEN
		Die("usage: ob build <File.Mod> [-o <name>] [-t linux64|win64|a64] [Proc]"); RETURN
	END;
	IF ~ObHost.RealPath(source, absolute) THEN DieOn("no such file: ", source); RETURN END;
	IF ~ModuleName(absolute, name) THEN DieOn("no MODULE header in ", source); RETURN END;
	IF ~TargetSettings(target, compilerPlatform, objectExtension, symbolExtension,
			linkOptions, suffix, boot) THEN RETURN END;
	IF ~TargetLibrary(target, library) THEN RETURN END;
	IF ~ReadBootList(boot, bootModules) THEN DieOn("cannot read the boot module list ", boot); RETURN END;

	IF output = "" THEN COPY(name, output); Strings.Append(output, suffix) END;
	IF output[0] = '/' THEN COPY(output, destination) ELSE Join(project, output, destination) END;
	Directory(destination, directory); BaseName(destination, fileName);
	IF directory = "" THEN COPY(project, directory) END;
	IF ~ObHost.Exists(directory) THEN DieOn("no such directory: ", directory); RETURN END;

	IF ~ScratchDirectory(scratch) THEN Die("cannot create a scratch directory"); RETURN END;
	(* lib is on the path even for a cross build: the backend and the frontend are loaded by name
	   when the compiler runs, and what runs here is this machine's code whatever is being built *)
	IF ~AddSearchPath(lib) OR ~AddSearchPath(library) OR ~AddSearchPath(project)
			OR ~AddSearchPath(scratch) OR ~SetWorkPath(scratch) THEN
		DiscardScratch(scratch); RETURN
	END;
	BuildSiblings(scratch, compilerPlatform, objectExtension, symbolExtension);
	IF CompileFile(absolute, compilerPlatform, objectExtension, symbolExtension, TRUE) THEN
		EntrySource(name, procedure, entry);
		IF CompileString("ObEntry", entry, compilerPlatform, objectExtension, symbolExtension) THEN
			(* the file name is quoted for the linker's option parser, which otherwise reads an
			   unquoted value up to the first character that cannot be in a name: hello-arm64
			   becomes the file hello followed by the flags -a -r -m -6 -4 *)
			COPY(linkOptions, arguments);
			Strings.Append(arguments, " --fileName='"); Strings.Append(arguments, fileName);
			Strings.Append(arguments, "' "); Strings.Append(arguments, bootModules);
			Strings.Append(arguments, name); Strings.Append(arguments, " ObEntry");
			IF SetWorkPath(directory) & Link(arguments) & ObHost.Exists(destination) THEN
				IF ~ObHost.MakeExecutable(destination) THEN
					DieOn("cannot make it executable: ", destination)
				ELSE
					line := "ob: wrote "; Strings.Append(line, destination);
					Strings.Append(line, "  (target: "); Strings.Append(line, target);
					Strings.Append(line, ", baked entry: "); Strings.Append(line, name);
					Strings.AppendChar(line, '.'); Strings.Append(line, procedure);
					Strings.AppendChar(line, ')'); Say(line)
				END
			ELSE
				Die("link failed (no output binary produced)")
			END
		ELSE
			failed := TRUE
		END
	ELSE
		failed := TRUE
	END;
	DiscardScratch(scratch)
END BuildVerb;

PROCEDURE CopyFile(CONST from, to: ARRAY OF CHAR): BOOLEAN;
VAR source, destination: Files.File; reader: Files.Reader; writer: Files.Writer;
	buffer: ARRAY 4096 OF CHAR; length: SIZE;
BEGIN
	source := Files.Old(from);
	IF source = NIL THEN RETURN FALSE END;
	destination := Files.New(to);
	IF destination = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, source, 0); Files.OpenWriter(writer, destination, 0);
	REPEAT
		reader.Bytes(buffer, 0, LEN(buffer), length);
		IF length > 0 THEN writer.Bytes(buffer, 0, length) END
	UNTIL length = 0;
	writer.Update; Files.Register(destination);
	RETURN TRUE
END CopyFile;

(*
	Start another ob and give it a deadline. This is the one place a process is still involved,
	and it is involved because the work has to be abandonable: see ObHost.Spawn.
*)
PROCEDURE RunProgram(CONST program: ARRAY OF CHAR; arguments: Strings.StringArray;
		limitMilliseconds: SIGNED32; VAR exitCode: SIGNED32): BOOLEAN;
CONST Tick = 20;
VAR process, waited: SIGNED32;
BEGIN
	process := ObHost.Spawn(program, arguments);
	IF process < 0 THEN RETURN FALSE END;
	waited := 0;
	WHILE waited < limitMilliseconds DO
		IF ObHost.Finished(process, exitCode) THEN RETURN TRUE END;
		Objects.Sleep(Tick); INC(waited, Tick)
	END;
	ObHost.Terminate(process);
	RETURN FALSE
END RunProgram;

(*
	ob lint -- every import has to point at the same tier or a lower one. The tier of a module is
	the tier of the package that provides it, read out of the shipped std manifests and whatever
	`ob get` has installed; the project's own code sits at the top, so it may import anything and
	nothing may import it.

	The imports come from the parser rather than from a search for the word IMPORT. It is linked
	into this binary already, it knows an aliased or a context import from a comment, and it is
	the same parser that will reject the file later anyway.
*)
TYPE
	Provider = POINTER TO RECORD
		next: Provider;
		module, package: Path;
		tier: SIGNED32
	END;

VAR providers: Provider;

PROCEDURE Provide(CONST module, package: ARRAY OF CHAR; tier: SIGNED32);
VAR entry: Provider;
BEGIN
	NEW(entry); COPY(module, entry.module); COPY(package, entry.package); entry.tier := tier;
	entry.next := providers; providers := entry
END Provide;

PROCEDURE TierOf(CONST module: ARRAY OF CHAR; VAR tier: SIGNED32; VAR package: ARRAY OF CHAR): BOOLEAN;
VAR entry: Provider;
BEGIN
	entry := providers;
	WHILE entry # NIL DO
		IF entry.module = module THEN tier := entry.tier; COPY(entry.package, package); RETURN TRUE END;
		entry := entry.next
	END;
	tier := 9; package := "project"; RETURN FALSE
END TierOf;

PROCEDURE ReadManifest(CONST file: ARRAY OF CHAR);
VAR handle: Files.File; reader: Files.Reader; value, member: JSON.Value; object: JSON.Object;
	list: JSON.Array; name: Path; tier: SIGNED32; index: SIZE;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN END;
	Files.OpenReader(reader, handle, 0);
	IF ~JSON.ParseStream(reader, value) OR ~(value IS JSON.Object) THEN RETURN END;
	object := value(JSON.Object);

	name := "?";
	member := object.Get("name");
	IF (member # NIL) & (member IS JSON.String) THEN COPY(member(JSON.String).value^, name) END;

	tier := 9;
	member := object.Get("tier");
	IF (member # NIL) & (member IS JSON.Number) THEN tier := ENTIER(member(JSON.Number).value) END;

	member := object.Get("provides");
	IF (member # NIL) & (member IS JSON.Array) THEN
		list := member(JSON.Array);
		FOR index := 0 TO list.length-1 DO
			member := list.At(index);
			IF (member # NIL) & (member IS JSON.String) THEN
				Provide(member(JSON.String).value^, name, tier)
			END
		END
	END
END ReadManifest;

(* Every a2pkg.json at or under a root, to the given depth. A package directory may itself hold
   package directories: the registry names them owner/name and ob get keeps that shape on disk. *)
PROCEDURE ScanPackages(CONST root: ARRAY OF CHAR; depth: SIGNED32);
VAR handle: ADDRESS; entry, path, manifest: Path;
BEGIN
	handle := ObHost.OpenDirectory(root);
	IF handle = 0 THEN RETURN END;
	WHILE ObHost.NextEntry(handle, entry) DO
		IF (entry # ".") & (entry # "..") THEN
			Join(root, entry, path);
			Join(path, "a2pkg.json", manifest);
			IF ObHost.Exists(manifest) THEN ReadManifest(manifest) END;
			IF depth > 0 THEN ScanPackages(path, depth-1) END
		END
	END;
	ObHost.CloseDirectory(handle)
END ScanPackages;

PROCEDURE LintFile(CONST file: ARRAY OF CHAR; VAR violations: SIGNED32);
VAR handle: Files.File; reader: Files.Reader; diagnostics: Diagnostics.DiagnosticsList;
	scanner: FoxScanner.Scanner; parser: FoxParser.Parser; module: SyntaxTree.Module;
	import: SyntaxTree.Import; name, imported, package, importedPackage, line: Path;
	tier, importedTier: SIGNED32;
BEGIN
	IF ~ModuleName(file, name) THEN RETURN END;
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN END;
	Files.OpenReader(reader, handle, 0);
	NEW(diagnostics);
	scanner := FoxScanner.NewScanner(name, reader, 0, diagnostics);
	parser := FoxParser.NewParser(scanner, diagnostics, "");
	module := parser.Module();
	IF (module = NIL) OR parser.error THEN RETURN END;

	IF ~TierOf(name, tier, package) THEN package := "project" END;
	import := module.moduleScope.firstImport;
	WHILE import # NIL DO
		IF import.moduleName # FoxGlobal.SystemName THEN
			FoxBasic.GetString(import.moduleName, imported);
			IF TierOf(imported, importedTier, importedPackage) & (importedTier > tier) THEN
				line := "  UP-EDGE  "; Strings.Append(line, name);
				Strings.Append(line, " (tier "); Strings.AppendInt(line, tier);
				Strings.Append(line, ", "); Strings.Append(line, package);
				Strings.Append(line, ") -> "); Strings.Append(line, imported);
				Strings.Append(line, " (tier "); Strings.AppendInt(line, importedTier);
				Strings.Append(line, ", "); Strings.Append(line, importedPackage);
				Strings.AppendChar(line, ')'); Say(line);
				INC(violations)
			END
		END;
		import := import.nextImport
	END
END LintFile;

PROCEDURE LintVerb;
VAR standard, vendor, path, entry, message: Path; handle: ADDRESS; violations: SIGNED32;
BEGIN
	providers := NIL;
	Join(packages, "std", standard); ScanPackages(standard, 0);
	Join(project, ".a2pkg", vendor); ScanPackages(vendor, 2);
	IF providers = NIL THEN
		DieOn("no package manifests found; looked in ", standard); RETURN
	END;

	violations := 0;
	handle := ObHost.OpenDirectory(project);
	IF handle = 0 THEN DieOn("cannot read the project directory ", project); RETURN END;
	WHILE ObHost.NextEntry(handle, entry) DO
		IF Strings.Match("*.Mod", entry) THEN Join(project, entry, path); LintFile(path, violations) END
	END;
	ObHost.CloseDirectory(handle);

	IF violations = 0 THEN Say("ob lint: OK — no upward dependencies")
	ELSE
		message := ""; Strings.AppendInt(message, violations);
		Strings.Append(message, " upward-dependency violation(s)"); Die(message)
	END
END LintVerb;

(*
	ob doc -- pkg.go.dev-style HTML from the doc comments, through the compiler's Documentation
	backend, one page per module plus an index.

	Each module is documented by a second ob, started for the purpose and given a deadline. That
	is not caution: the Documentation backend hangs outright on some modules (V4L2 is the one that
	was found), and one of those in a project would otherwise stall the whole run with no way out.
	A page that does not appear is reported with the reason the compiler gave, not as "timeout or
	error", which is what the shell version had to say because it could not tell the two apart.
*)
PROCEDURE DocumentModule(CONST file, scratch, output: ARRAY OF CHAR): BOOLEAN;
VAR name, page, source, destination: Path;
BEGIN
	IF ~ModuleName(file, name) THEN DieOn("no MODULE header in ", file); RETURN FALSE END;
	IF ~AddSearchPath(lib) OR ~AddSearchPath(project) OR ~AddSearchPath(scratch)
			OR ~SetWorkPath(scratch) THEN RETURN FALSE END;
	COPY(name, page); Strings.Append(page, ".html");
	IF ~CompileForDocumentation(file, page) THEN RETURN FALSE END;
	Join(scratch, page, source); Join(output, page, destination);
	IF ~CopyFile(source, destination) THEN DieOn("the backend produced no page for ", name); RETURN FALSE END;
	RETURN TRUE
END DocumentModule;

(* The pages in name order, not in the order the directory happens to hand them over: two runs
   over the same project should produce the same index. *)
PROCEDURE WriteIndex(CONST output: ARRAY OF CHAR): SIGNED32;
VAR handle: ADDRESS; entry, path: Path; index: Files.File; writer: Files.Writer;
	pages: Strings.StringArray; swap: Strings.String; count, i, j: SIZE;
BEGIN
	NEW(pages, 1024); count := 0;
	handle := ObHost.OpenDirectory(output);
	IF handle # 0 THEN
		WHILE ObHost.NextEntry(handle, entry) & (count < LEN(pages^)) DO
			IF Strings.Match("*.html", entry) & (entry # "index.html") THEN
				pages[count] := Strings.NewString(entry); INC(count)
			END
		END;
		ObHost.CloseDirectory(handle)
	END;
	FOR i := 1 TO count-1 DO
		swap := pages[i]; j := i;
		WHILE (j > 0) & (pages[j-1]^ > swap^) DO pages[j] := pages[j-1]; DEC(j) END;
		pages[j] := swap
	END;

	Join(output, "index.html", path);
	index := Files.New(path);
	IF index = NIL THEN RETURN 0 END;
	Files.OpenWriter(writer, index, 0);
	writer.String("<!doctype html><meta charset=utf-8><title>Package docs</title>"); writer.Char(0AX);
	writer.String("<h1>API documentation</h1><ul>"); writer.Char(0AX);
	FOR i := 0 TO count-1 DO
		COPY(pages[i]^, path); path[Strings.Length(path) - 5] := 0X;	(* drop ".html" *)
		writer.String("  <li><a href="); writer.Char('"'); writer.String(pages[i]^);
		writer.Char('"'); writer.Char('>'); writer.String(path);
		writer.String("</a></li>"); writer.Char(0AX)
	END;
	writer.String("</ul>"); writer.Char(0AX);
	writer.Update; Files.Register(index);
	RETURN SIGNED32(count)
END WriteIndex;

(* Not a verb for people: how ob asks another ob to document one module, so that the answer can
   be given up on. Takes the source, the directory the siblings were compiled into, and where the
   page goes. *)
PROCEDURE DocModuleVerb;
VAR file, scratch, output: Path;
BEGIN
	IF ~NextArgument(file) OR ~NextArgument(scratch) OR ~NextArgument(output) THEN
		Die("doc-module is internal: ob doc-module <File.Mod> <scratch> <output>"); RETURN
	END;
	IF ~DocumentModule(file, scratch, output) THEN failed := TRUE END
END DocModuleVerb;

PROCEDURE DocVerb;
VAR source, output, absolute, scratch, self, file, entry, line, limitText: Path;
	handle: ADDRESS; arguments: Strings.StringArray; limit, exitCode, documented: SIGNED32;
	names: Strings.StringArray; count, index: SIZE;
BEGIN
	output := "doc";
	IF ~ReadSourceAndOutputOptional("usage: ob doc [File.Mod] [-o <dir>]", source, output) THEN RETURN END;
	IF ~ObHost.Exists(output) & ~ObHost.MakeDirectory(output) THEN
		DieOn("cannot create the output directory: ", output); RETURN
	END;
	IF ~ObHost.RealPath(output, absolute) THEN DieOn("no such directory: ", output); RETURN END;
	COPY(absolute, output);
	IF ~ObHost.ExecutablePath(self) THEN Die("cannot find my own binary"); RETURN END;
	IF ~ScratchDirectory(scratch) THEN Die("cannot create a scratch directory"); RETURN END;

	limit := 30000;
	IF ObHost.Env("A2_DOC_TIMEOUT", limitText) & (limitText # "") THEN
		limit := SIGNED32(1000 * ToInteger(limitText, 30))
	END;

	(* the siblings are compiled once, here, rather than by each of the children in turn *)
	IF AddSearchPath(lib) & AddSearchPath(project) & AddSearchPath(scratch) & SetWorkPath(scratch) THEN
		BuildSiblings(scratch, CompilerPlatform, ObjectExtension, SymbolExtension)
	END;

	(* what to document: the file named, or every module of the project *)
	NEW(names, 1024); count := 0;
	IF source # "" THEN
		IF ObHost.RealPath(source, absolute) THEN names[0] := Strings.NewString(absolute); count := 1 END
	ELSE
		handle := ObHost.OpenDirectory(project);
		IF handle # 0 THEN
			WHILE ObHost.NextEntry(handle, entry) & (count < LEN(names^)) DO
				IF Strings.Match("*.Mod", entry) THEN
					Join(project, entry, file); names[count] := Strings.NewString(file); INC(count)
				END
			END;
			ObHost.CloseDirectory(handle)
		END
	END;
	IF count = 0 THEN Die("nothing to document here"); DiscardScratch(scratch); RETURN END;

	documented := 0;
	FOR index := 0 TO count-1 DO
		NEW(arguments, 5);
		arguments[0] := Strings.NewString("ob");
		arguments[1] := Strings.NewString("doc-module");
		arguments[2] := names[index];
		arguments[3] := Strings.NewString(scratch);
		arguments[4] := Strings.NewString(output);
		IF RunProgram(self, arguments, limit, exitCode) THEN
			IF exitCode = 0 THEN INC(documented) END
		ELSE
			IF ~ModuleName(names[index]^, entry) THEN COPY(names[index]^, entry) END;
			line := "ob: doc gave up on "; Strings.Append(line, entry);
			Strings.Append(line, " after "); Strings.AppendInt(line, limit DIV 1000);
			Strings.Append(line, "s (the documentation backend does not return on some modules)");
			error.String(line); EndLine(error)
		END
	END;

	DiscardScratch(scratch);
	line := "ob: wrote docs to "; Strings.Append(line, output);
	Strings.Append(line, " ("); Strings.AppendInt(line, WriteIndex(output));
	Strings.Append(line, " modules + index.html)"); Say(line);
	IF documented = 0 THEN failed := TRUE END
END DocVerb;

(*
	The language server, speaking LSP over this process's own standard input and output. It gets
	the full stdlib symbols rather than the headless subset, because an editor is opened on code
	that imports whatever it imports; then the project's own build if it has one, then its sources,
	which the server compiles on demand.
*)
PROCEDURE LspVerb;
VAR argument, scratch, symbols: Path; live: BOOLEAN; context: Commands.Context; ignore: BOOLEAN;
BEGIN
	live := FALSE;
	WHILE NextArgument(argument) DO
		IF argument = "--live" THEN live := TRUE
		ELSE DieOn("unknown option: ", argument); RETURN
		END
	END;
	IF ~ScratchDirectory(scratch) THEN Die("cannot create a scratch directory"); RETURN END;
	IF AddSearchPath(lib) & AddSearchPath(libSym) & AddSearchPath(project)
			& AddSearchPath(scratch) & SetWorkPath(scratch) THEN
		IF ObHost.Env("A2_SYMS", symbols) & (symbols # "") THEN ignore := AddSearchPath(symbols) END;
		NEW(context, StdIO.env.in, NIL, StdIO.env.out, error, NIL);
		IF live THEN LSP.RunLive(context) ELSE LSP.Run(context) END
	END;
	DiscardScratch(scratch)
END LspVerb;

(*
	The interactive shell, in the user's own directory. What the shell version had to do here --
	write a configuration file naming lib and the project, and hand it to `oberon run` because
	`oberon do` runs commands and exits -- is two search paths and a call.
*)
PROCEDURE ReplVerb;
VAR context: Commands.Context;
BEGIN
	IF AddSearchPath(lib) & AddSearchPath(project) & SetWorkPath(project) THEN
		NEW(context, StdIO.env.in, NIL, StdIO.env.out, error, NIL);
		Shell.Start(context)
	END
END ReplVerb;

PROCEDURE Help;
BEGIN
	Say("ob — a Go-style CLI over the A2 (Active Oberon) toolchain.");
	Say("");
	Say("  ob build   <File.Mod> [-o name] [-t linux64|win64|a64] [Proc]");
	Say("                                     link a standalone native executable");
	Say("  ob compile <File.Mod> [-o <dir>]   compile one module to an object file");
	Say("  ob run     <File.Mod> [Proc]       compile, then run a command (default: Do)");
	Say("  ob doc [File.Mod] [-o dir]         generate HTML API docs (index + per-module)");
	Say("  ob lint                            check every import points at its tier or lower");
	Say("  ob lsp [--live]                    the Active Oberon language server, over stdio");
	Say("  ob repl                            the interactive A2 shell, in this directory");
	Say("  ob version                         print the SDK version banner");
	Say("  ob help                            this text");
	Say("");
	Say("Verbs still served by the shell version: get, test.")
END Help;

(* --- entry ------------------------------------------------------------------------------- *)

PROCEDURE Dispatch(CONST verb: ARRAY OF CHAR);
VAR message: ARRAY 128 OF CHAR;
BEGIN
	IF verb = "build" THEN BuildVerb
	ELSIF verb = "compile" THEN CompileVerb
	ELSIF verb = "run" THEN RunVerb
	ELSIF verb = "doc" THEN DocVerb
	ELSIF verb = "doc-module" THEN DocModuleVerb
	ELSIF verb = "lint" THEN LintVerb
	ELSIF verb = "lsp" THEN LspVerb
	ELSIF verb = "repl" THEN ReplVerb
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
