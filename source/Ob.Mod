MODULE Ob;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "The ob command line, in Active Oberon"; *)

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
	Shell, LSP, Kernel, Trace, SyntaxTree := FoxSyntaxTree, FoxScanner, FoxParser, FoxBasic, FoxGlobal,
	ObHost;

CONST
	MaxPath = ObHost.MaxPath;

	(* The architecture this binary was compiled for, which is the only "host" that means anything:
	   an x86-64 SDK under an emulator is still an x86-64 SDK. *)
#IF WIN THEN
	HostTarget = "win64";
	ObjectExtension = "GofWw"; SymbolExtension = ".SymWw";
	CompilerPlatform = "Win64"; LinkerPlatform = "Win64";
#ELSIF ARM64 THEN
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

(* Windows answers GetModuleFileName with backslashes whatever ob builds its own paths with, so
   a path is split on either separator. On Unix ObHost.Separator is the slash and nothing changes. *)
PROCEDURE IsSeparator(character: CHAR): BOOLEAN;
BEGIN RETURN (character = '/') OR (character = ObHost.Separator)
END IsSeparator;

PROCEDURE Join*(CONST dir, name: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
VAR length: SIZE;
BEGIN
	COPY(dir, path);
	length := Strings.Length(path);
	IF (length > 0) & ~IsSeparator(path[length-1]) THEN Strings.AppendChar(path, '/') END;
	Strings.Append(path, name)
END Join;

(** The directory part of a path, without its trailing separator. "" when there is none. *)
PROCEDURE Directory*(CONST path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
VAR i: SIZE;
BEGIN
	COPY(path, dir);
	i := Strings.Length(dir);
	WHILE (i > 0) & ~IsSeparator(dir[i-1]) DO DEC(i) END;
	IF i = 0 THEN dir := "" ELSE dir[i-1] := 0X END	(* i-1 drops the separator itself *)
END Directory;

(** The last component of a path. *)
PROCEDURE BaseName*(CONST path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, length: SIZE;
BEGIN
	length := Strings.Length(path); i := length;
	WHILE (i > 0) & ~IsSeparator(path[i-1]) DO DEC(i) END;
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
	(* On an SDK that is not x86-64 Linux, the native objects in lib/ ARE that platform's objects
	   and there is no separate cross directory for it. *)
	IF (HostTarget = "a64") & ~ObHost.Exists(libA64) THEN COPY(lib, libA64) END;
	IF (HostTarget = "win64") & ~ObHost.Exists(libWin) THEN COPY(lib, libWin) END
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
	directory full of symlinks used to do. Files, not UnixFiles: Files is the one that knows
	which file system this platform has. *)
PROCEDURE AddSearchPath(CONST directory: ARRAY OF CHAR): BOOLEAN;
VAR quoted: Path;
BEGIN
	IF ~ObHost.Exists(directory) THEN RETURN TRUE END;		(* absent lib-a64 is not an error *)
	Quoted(directory, quoted);
	RETURN Execute("Files.AddSearchPath", quoted)
END AddSearchPath;

(** Where the compiler writes what it produces. *)
PROCEDURE SetWorkPath(CONST directory: ARRAY OF CHAR): BOOLEAN;
VAR quoted: Path;
BEGIN
	Quoted(directory, quoted);
	RETURN Execute("Files.SetWorkPath", quoted)
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
			handle.Close;
			RETURN length > 0
		END
	END;
	handle.Close;
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
VAR handle: Files.File; reader: Files.Reader; compiled: BOOLEAN;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN IF report THEN Die("cannot open the source file") END; RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	compiled := CompileReader(file, reader, platform, objectExtension, symbolExtension, report);
	handle.Close;
	RETURN compiled
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
CONST TraceCapacity = 64*1024;

VAR
	previousTraceChar: Trace.CharProc;
	traced: ARRAY TraceCapacity OF CHAR;
	tracedLength: SIZE;

(* Runs where a trap handler runs, so it allocates nothing and locks nothing: a fixed array and
   an index. What does not fit is dropped, which is what the twentieth page of a trap is worth. *)
PROCEDURE CaptureChar(character: CHAR);
BEGIN {UNCOOPERATIVE, UNCHECKED}
	IF tracedLength < LEN(traced) THEN traced[tracedLength] := character; INC(tracedLength) END
END CaptureChar;

PROCEDURE CaptureTrace;
BEGIN tracedLength := 0; previousTraceChar := Trace.Char; Trace.Char := CaptureChar
END CaptureTrace;

PROCEDURE RestoreTrace;
BEGIN Trace.Char := previousTraceChar
END RestoreTrace;

PROCEDURE WriteTraced(writer: Streams.Writer);
VAR index: SIZE;
BEGIN
	FOR index := 0 TO tracedLength-1 DO writer.Char(traced[index]) END
END WriteTraced;

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
	CaptureTrace;
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
	reader.Ln(version); file.Close;
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
#IF WIN THEN
	targets := "win64 (PE .exe, native)";
#ELSIF ARM64 THEN
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
(* Every directory along a path that is not there yet. A $TMPDIR that does not exist is a real
   situation, and so is a vendored package three segments deep. *)
PROCEDURE MakePath(CONST path: ARRAY OF CHAR): BOOLEAN;
VAR partial: Path; index, length: SIZE;
BEGIN
	length := Strings.Length(path); index := 1;
	WHILE index <= length DO
		IF (index = length) OR (path[index] = '/') THEN
			Strings.Copy(path, 0, index, partial);
			IF ~ObHost.Exists(partial) & ~ObHost.MakeDirectory(partial) THEN RETURN FALSE END
		END;
		INC(index)
	END;
	RETURN ObHost.Exists(path)
END MakePath;

PROCEDURE ScratchDirectory(VAR path: ARRAY OF CHAR): BOOLEAN;
VAR temporary: Path; name: ARRAY 32 OF CHAR;
BEGIN
	IF ~ObHost.Env("TMPDIR", temporary) OR (temporary = "") THEN
		IF ~ObHost.Env("TEMP", temporary) OR (temporary = "") THEN temporary := "/tmp" END
	END;
	name := "ob-"; Strings.AppendInt(name, ObHost.ProcessId());
	Join(temporary, name, path);
	RETURN MakePath(path)
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
	handle.Close;
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
	source.Close; destination.Close;
	RETURN TRUE
END CopyFile;

(*
	Start another ob and give it a deadline. This is the one place a process is still involved,
	and it is involved because the work has to be abandonable: see ObHost.Spawn.
*)
PROCEDURE RunProgram(CONST program: ARRAY OF CHAR; arguments: Strings.StringArray;
		limitMilliseconds: SIGNED32; VAR exitCode: SIGNED32): BOOLEAN;
CONST Tick = 20;
VAR process: ADDRESS; waited: SIGNED32; timer: Kernel.Timer;
BEGIN
	process := ObHost.Spawn(program, arguments);
	IF process = 0 THEN RETURN FALSE END;
	NEW(timer);		(* Kernel.Timer, not Objects.Sleep: the latter is Unix only *)
	waited := 0;
	WHILE waited < limitMilliseconds DO
		IF ObHost.Finished(process, exitCode) THEN RETURN TRUE END;
		timer.Sleep(Tick); INC(waited, Tick)
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
	handle.Close;
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
	writer.Update; Files.Register(index); index.Close;
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
	ob get -- fetch a package into .a2pkg/, pin it in a2pkg.lock, add it to a2pkg.json and do the
	same for whatever it requires. A name with a dot in its first segment is a git repository
	(github.com/user/repo); a bare one is a registry package resolved through $A2_REGISTRY.

	git is the one program ob still needs on the PATH, and there is no way around that: it speaks
	a protocol, not a file format. What ob does NOT do any more is read git's answer off a pipe --
	the commit it pins comes out of .git/HEAD, which is a file.
*)
PROCEDURE RemoveTree(CONST path: ARRAY OF CHAR);
VAR handle: ADDRESS; entry, child: Path; ignore: BOOLEAN;
BEGIN
	handle := ObHost.OpenDirectory(path);
	IF handle = 0 THEN ignore := ObHost.Remove(path); RETURN END;
	WHILE ObHost.NextEntry(handle, entry) DO
		IF (entry # ".") & (entry # "..") THEN Join(path, entry, child); RemoveTree(child) END
	END;
	ObHost.CloseDirectory(handle);
	ignore := ObHost.RemoveDirectory(path)
END RemoveTree;

PROCEDURE CopyTree(CONST from, to: ARRAY OF CHAR): BOOLEAN;
VAR handle: ADDRESS; entry, source, destination: Path; done: BOOLEAN;
BEGIN
	handle := ObHost.OpenDirectory(from);
	IF handle = 0 THEN RETURN CopyFile(from, to) END;
	IF ~MakePath(to) THEN ObHost.CloseDirectory(handle); RETURN FALSE END;
	done := TRUE;
	WHILE ObHost.NextEntry(handle, entry) DO
		IF (entry # ".") & (entry # "..") THEN
			Join(from, entry, source); Join(to, entry, destination);
			IF ~CopyTree(source, destination) THEN done := FALSE END
		END
	END;
	ObHost.CloseDirectory(handle);
	RETURN done
END CopyTree;

PROCEDURE Git(arguments: Strings.StringArray): BOOLEAN;
VAR exitCode: SIGNED32;
BEGIN
	IF ~RunProgram("git", arguments, 600000, exitCode) THEN RETURN FALSE END;
	RETURN exitCode = 0
END Git;

PROCEDURE ReadJsonFile(CONST file: ARRAY OF CHAR; VAR object: JSON.Object): BOOLEAN;
VAR handle: Files.File; reader: Files.Reader; value: JSON.Value;
BEGIN
	object := NIL;
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	IF ~JSON.ParseStream(reader, value) THEN handle.Close; RETURN FALSE END;
	handle.Close;
	IF ~(value IS JSON.Object) THEN RETURN FALSE END;
	object := value(JSON.Object);
	RETURN TRUE
END ReadJsonFile;

PROCEDURE WriteJsonString(writer: Streams.Writer; CONST text: ARRAY OF CHAR);
VAR index: SIZE;
BEGIN
	writer.Char('"');
	FOR index := 0 TO Strings.Length(text)-1 DO
		IF (text[index] = '"') OR (text[index] = '\') THEN writer.Char('\') END;
		writer.Char(text[index])
	END;
	writer.Char('"')
END WriteJsonString;

(* Indented, two spaces per level, because a2pkg.json and a2pkg.lock are files people read and
   put in version control. JSON.Write is compact, which the shell version avoided by piping
   through jq. *)
PROCEDURE WriteJsonIndented(writer: Streams.Writer; value: JSON.Value; depth: SIGNED32);
VAR member: JSON.Member; item: JSON.Item; first: BOOLEAN; level: SIGNED32;

	PROCEDURE Indent(by: SIGNED32);
	VAR count: SIGNED32;
	BEGIN FOR count := 1 TO by DO writer.String("  ") END
	END Indent;

BEGIN
	IF (value # NIL) & (value IS JSON.Object) THEN
		member := value(JSON.Object).members;
		IF member = NIL THEN writer.String("{}"); RETURN END;
		writer.String("{"); writer.Char(0AX); first := TRUE;
		WHILE member # NIL DO
			IF ~first THEN writer.String(","); writer.Char(0AX) END;
			first := FALSE;
			Indent(depth + 1); WriteJsonString(writer, member.key^); writer.String(": ");
			WriteJsonIndented(writer, member.value, depth + 1);
			member := member.next
		END;
		writer.Char(0AX); Indent(depth); writer.String("}")
	ELSIF (value # NIL) & (value IS JSON.Array) THEN
		item := value(JSON.Array).items;
		IF item = NIL THEN writer.String("[]"); RETURN END;
		writer.String("["); writer.Char(0AX); first := TRUE;
		WHILE item # NIL DO
			IF ~first THEN writer.String(","); writer.Char(0AX) END;
			first := FALSE;
			Indent(depth + 1); WriteJsonIndented(writer, item.value, depth + 1);
			item := item.next
		END;
		writer.Char(0AX); Indent(depth); writer.String("]")
	ELSE
		level := depth;	(* nothing to indent inside a scalar *)
		JSON.Write(writer, value)
	END
END WriteJsonIndented;

PROCEDURE WriteJsonFile(CONST file: ARRAY OF CHAR; value: JSON.Value): BOOLEAN;
VAR handle: Files.File; writer: Files.Writer;
BEGIN
	handle := Files.New(file);
	IF handle = NIL THEN RETURN FALSE END;
	Files.OpenWriter(writer, handle, 0);
	WriteJsonIndented(writer, value, 0); writer.Char(0AX);
	writer.Update; Files.Register(handle); handle.Close;
	RETURN TRUE
END WriteJsonFile;

PROCEDURE JsonText(object: JSON.Object; CONST key: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
VAR member: JSON.Value;
BEGIN
	IF object = NIL THEN RETURN FALSE END;
	member := object.Get(key);
	IF (member = NIL) OR ~(member IS JSON.String) THEN RETURN FALSE END;
	COPY(member(JSON.String).value^, value); RETURN TRUE
END JsonText;

(* The commit a fresh clone is standing on, read out of .git rather than off git's own output:
   a tag or a detached clone puts the hash straight into HEAD, a branch puts a ref there and the
   hash in the file it names. *)
PROCEDURE HeadCommit(CONST repository: ARRAY OF CHAR; VAR commit: ARRAY OF CHAR): BOOLEAN;
VAR path, line: Path; handle: Files.File; reader: Files.Reader;
BEGIN
	Join(repository, ".git/HEAD", path);
	handle := Files.Old(path);
	IF handle = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	reader.Ln(line); Strings.Trim(line, 0DX); Strings.Trim(line, ' ');
	IF Strings.Pos("ref: ", line) = 0 THEN
		Strings.Copy(line, 5, Strings.Length(line) - 5, commit);
		Join(repository, ".git", path); Strings.AppendChar(path, '/'); Strings.Append(path, commit);
		handle := Files.Old(path);
		IF handle = NIL THEN RETURN FALSE END;
		Files.OpenReader(reader, handle, 0);
		reader.Ln(line); Strings.Trim(line, 0DX); Strings.Trim(line, ' ')
	END;
	COPY(line, commit);
	RETURN commit # ""
END HeadCommit;

PROCEDURE RecordDependency(CONST name, version, commit: ARRAY OF CHAR);
VAR path: Path; manifest, lock, entry: JSON.Object;
BEGIN
	Join(project, "a2pkg.json", path);
	IF ~ReadJsonFile(path, manifest) THEN
		manifest := JSON.NewObject();
		manifest.Set("name", JSON.NewString("app"));
		manifest.Set("requires", JSON.NewObject())
	END;
	IF (manifest.Get("requires") = NIL) OR ~(manifest.Get("requires") IS JSON.Object) THEN
		manifest.Set("requires", JSON.NewObject())
	END;
	manifest.Get("requires")(JSON.Object).Set(name, JSON.NewString(version));
	IF ~WriteJsonFile(path, manifest) THEN DieOn("cannot write ", path); RETURN END;

	Join(project, "a2pkg.lock", path);
	IF ~ReadJsonFile(path, lock) THEN lock := JSON.NewObject() END;
	entry := JSON.NewObject();
	entry.Set("version", JSON.NewString(version));
	entry.Set("commit", JSON.NewString(commit));
	lock.Set(name, entry);
	IF ~WriteJsonFile(path, lock) THEN DieOn("cannot write ", path) END
END RecordDependency;

(* A package's requirements are fetched by the same procedure that fetched it, and that procedure
   is declared after this one; the variable is what Oberon offers instead of a forward declaration. *)
VAR fetch: PROCEDURE(CONST specification: ARRAY OF CHAR);

PROCEDURE GetTransitive(CONST directory: ARRAY OF CHAR);
VAR path: Path; manifest, requires: JSON.Object; member: JSON.Member; installed: Path;
BEGIN
	Join(directory, "a2pkg.json", path);
	IF ~ReadJsonFile(path, manifest) THEN RETURN END;
	IF (manifest.Get("requires") = NIL) OR ~(manifest.Get("requires") IS JSON.Object) THEN RETURN END;
	requires := manifest.Get("requires")(JSON.Object);
	member := requires.members;
	WHILE member # NIL DO
		IF Strings.Pos("std/", member.key^) # 0 THEN		(* the SDK provides std/*, never fetched *)
			Join(project, ".a2pkg", installed); Strings.AppendChar(installed, '/');
			Strings.Append(installed, member.key^);
			IF ~ObHost.Exists(installed) THEN fetch(member.key^) END
		END;
		member := member.next
	END
END GetTransitive;

PROCEDURE GetGit(CONST repository, version: ARRAY OF CHAR);
VAR cache, parent, url, commit, manifest, line, pinned: Path;
	arguments: Strings.StringArray;
BEGIN
	Join(project, ".a2pkg", cache); Strings.AppendChar(cache, '/'); Strings.Append(cache, repository);
	RemoveTree(cache);
	Directory(cache, parent);
	IF ~MakePath(parent) THEN DieOn("cannot create ", parent); RETURN END;
	url := "https://"; Strings.Append(url, repository); Strings.Append(url, ".git");

	(* shallow and VCS-free: only the requested tag or branch, then .git is dropped, so what stays
	   in the cache is the package source and nothing else *)
	IF version # "" THEN
		NEW(arguments, 11);
		arguments[0] := Strings.NewString("git");
		arguments[1] := Strings.NewString("-c");
		arguments[2] := Strings.NewString("advice.detachedHead=false");
		arguments[3] := Strings.NewString("clone");
		arguments[4] := Strings.NewString("-q");
		arguments[5] := Strings.NewString("--depth"); arguments[6] := Strings.NewString("1");
		arguments[7] := Strings.NewString("--branch"); arguments[8] := Strings.NewString(version);
		arguments[9] := Strings.NewString(url); arguments[10] := Strings.NewString(cache)
	ELSE
		NEW(arguments, 7);
		arguments[0] := Strings.NewString("git");
		arguments[1] := Strings.NewString("clone");
		arguments[2] := Strings.NewString("-q");
		arguments[3] := Strings.NewString("--depth"); arguments[4] := Strings.NewString("1");
		arguments[5] := Strings.NewString(url); arguments[6] := Strings.NewString(cache)
	END;
	IF ~Git(arguments) THEN
		DieOn("clone failed: ", repository); RETURN
	END;
	Join(cache, "a2pkg.json", manifest);
	IF ~ObHost.Exists(manifest) THEN
		DieOn("not an A2 package (no a2pkg.json): ", repository); RETURN
	END;
	IF ~HeadCommit(cache, commit) THEN commit := "" END;
	COPY(version, pinned);
	IF pinned = "" THEN COPY(commit, pinned) END;
	Join(cache, ".git", line); RemoveTree(line);
	RecordDependency(repository, pinned, commit);
	line := "ob: got "; Strings.Append(line, repository);
	Strings.Append(line, "  ("); Strings.Append(line, pinned); Strings.AppendChar(line, ')'); Say(line);
	GetTransitive(cache)
END GetGit;

PROCEDURE GetRegistry(CONST name, version: ARRAY OF CHAR);
VAR registry, index, path, status, destination, version2, line: Path;
	catalogue, packages, entry: JSON.Object; arguments: Strings.StringArray; manifest: JSON.Object;
BEGIN
	IF ~ObHost.Env("A2_REGISTRY", registry) OR (registry = "") THEN
		Die("ob get by name needs A2_REGISTRY (a git URL or a path to the registry)"); RETURN
	END;
	IF ~ObHost.Exists(registry) THEN
		Join(project, ".a2pkg/.registry", path); RemoveTree(path);
		NEW(arguments, 7);
		arguments[0] := Strings.NewString("git");
		arguments[1] := Strings.NewString("clone");
		arguments[2] := Strings.NewString("-q");
		arguments[3] := Strings.NewString("--depth"); arguments[4] := Strings.NewString("1");
		arguments[5] := Strings.NewString(registry); arguments[6] := Strings.NewString(path);
		IF ~Git(arguments) THEN DieOn("registry clone failed: ", registry); RETURN END;
		COPY(path, registry)
	END;
	Join(registry, "index.json", index);
	IF ~ReadJsonFile(index, catalogue) THEN DieOn("registry has no index.json: ", registry); RETURN END;
	IF (catalogue.Get("packages") = NIL) OR ~(catalogue.Get("packages") IS JSON.Object) THEN
		DieOn("registry index has no packages: ", index); RETURN
	END;
	packages := catalogue.Get("packages")(JSON.Object);
	IF (packages.Get(name) = NIL) OR ~(packages.Get(name) IS JSON.Object) THEN
		DieOn("package not in registry: ", name); RETURN
	END;
	entry := packages.Get(name)(JSON.Object);
	IF ~JsonText(entry, "path", path) THEN DieOn("registry entry has no path: ", name); RETURN END;
	IF ~JsonText(entry, "status", status) THEN status := "unknown" END;
	Join(registry, path, line);
	IF ~ObHost.Exists(line) THEN
		DieOn("no installable source yet for ", name); RETURN
	END;
	Join(project, ".a2pkg", destination); Strings.AppendChar(destination, '/');
	Strings.Append(destination, name);
	RemoveTree(destination);
	IF ~CopyTree(line, destination) THEN DieOn("cannot copy the package into ", destination); RETURN END;
	version2 := "0.0.0";
	Join(destination, "a2pkg.json", path);
	IF ReadJsonFile(path, manifest) THEN
		IF ~JsonText(manifest, "version", version2) THEN version2 := "0.0.0" END
	END;
	IF version # "" THEN COPY(version, version2) END;
	RecordDependency(name, version2, "registry");
	line := "ob: got "; Strings.Append(line, name);
	Strings.Append(line, "  (registry @ "); Strings.Append(line, version2);
	Strings.AppendChar(line, ')'); Say(line);
	GetTransitive(destination)
END GetRegistry;

PROCEDURE GetOne(CONST specification: ARRAY OF CHAR);
VAR repository, version, first: Path; at, slash: SIZE;
BEGIN
	COPY(specification, repository); version := "";
	at := Strings.Length(repository);
	WHILE (at > 0) & (repository[at-1] # '@') DO DEC(at) END;
	IF at > 0 THEN
		Strings.Copy(repository, at, Strings.Length(repository) - at, version);
		repository[at-1] := 0X
	END;
	slash := Strings.Pos("/", repository);
	IF slash < 0 THEN first := repository ELSE Strings.Copy(repository, 0, slash, first) END;
	IF Strings.Pos(".", first) >= 0 THEN GetGit(repository, version)
	ELSE GetRegistry(repository, version)
	END
END GetOne;

PROCEDURE GetVerb;
VAR specification: Path; any: BOOLEAN;
BEGIN
	any := FALSE;
	WHILE NextArgument(specification) DO
		IF specification[0] = '-' THEN DieOn("unknown option: ", specification); RETURN END;
		GetOne(specification); any := TRUE;
		IF failed THEN RETURN END
	END;
	IF ~any THEN Die("usage: ob get <host/user/repo>[@version] ..."); RETURN END;
	Say("ob: updated a2pkg.json + a2pkg.lock ; deps vendored in .a2pkg/")
END GetVerb;

(* see the note on `fetch` above *)
PROCEDURE InstallFetch;
BEGIN fetch := GetOne
END InstallFetch;

(*
	ob test -- the test files the tree already uses: `#` comments, then cases introduced by
	`positive: name` or `negative: name`, each followed by the Oberon source of that case. A
	positive case must compile and run without failing; a negative one must fail.

	Each case is compiled AND loaded by a second ob, one process per case, which is what the shell
	version did and for the same two reasons: a case that traps cannot be allowed to poison the
	next one, and a case that damages the frame it returns through never comes back, so it needs a
	deadline. What is different is how the verdict is read. The shell version had to grep the
	runtime's output for "loaded." and "Could not load module", because the A2 runtime exits 0
	whatever happens; here the child is ob, and it answers with its exit code.

	The child's diagnostics and everything the case wrote to the trace channel go into a log file
	in the scratch directory, and the parent prints it only when the case fails -- otherwise a run
	would be buried under the output of every negative case and every test that traps on purpose.
*)
TYPE
	Key = POINTER TO RECORD next: Key; text: Path END;
	CaseRecord = POINTER TO RECORD next: CaseRecord; status, file, kind, name: Path END;

VAR
	baseline, newFailures: Key;
	caseRecords, lastCaseRecord: CaseRecord;
	testVerbose, testGithub, testRun: BOOLEAN;
	testFilter, testFile, testReport, testScratch, testSelf: Path;
	caseLimit, sinceCollection: SIGNED32;
	totalCases, passedCases, failedCases, knownCases, fixedCases: SIGNED32;

PROCEDURE AddKey(VAR list: Key; CONST text: ARRAY OF CHAR);
VAR entry: Key;
BEGIN NEW(entry); COPY(text, entry.text); entry.next := list; list := entry
END AddKey;

PROCEDURE HasKey(list: Key; CONST text: ARRAY OF CHAR): BOOLEAN;
BEGIN
	WHILE list # NIL DO
		IF list.text = text THEN RETURN TRUE END;
		list := list.next
	END;
	RETURN FALSE
END HasKey;

PROCEDURE CountKeys(list: Key): SIGNED32;
VAR count: SIGNED32;
BEGIN count := 0;
	WHILE list # NIL DO INC(count); list := list.next END;
	RETURN count
END CountKeys;

PROCEDURE LoadBaseline(CONST file: ARRAY OF CHAR);
VAR handle: Files.File; reader: Files.Reader; line: Path;
BEGIN
	baseline := NIL;
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN END;
	Files.OpenReader(reader, handle, 0);
	WHILE reader.res = Streams.Ok DO
		reader.Ln(line); Strings.Trim(line, 0DX);
		IF (line # "") & (line[0] # '#') THEN AddKey(baseline, line) END
	END;
	handle.Close;
	line := "ob test: baseline "; Strings.Append(line, file);
	Strings.Append(line, " ("); Strings.AppendInt(line, CountKeys(baseline));
	Strings.Append(line, " known failure(s))"); Say(line)
END LoadBaseline;

PROCEDURE RecordCase(CONST status, kind, name: ARRAY OF CHAR);
VAR record: CaseRecord;
BEGIN
	IF testReport = "" THEN RETURN END;
	NEW(record); COPY(status, record.status); COPY(testFile, record.file);
	COPY(kind, record.kind); COPY(name, record.name); record.next := NIL;
	IF caseRecords = NIL THEN caseRecords := record ELSE lastCaseRecord.next := record END;
	lastCaseRecord := record
END RecordCase;

(* One Actions annotation per case that breaks the build, so it shows on the run and not only in
   the log. Anchored at the test file; the format carries no line information. *)
PROCEDURE Annotate(CONST severity, kind, name: ARRAY OF CHAR);
VAR line: Path;
BEGIN
	IF ~testGithub THEN RETURN END;
	line := "::"; Strings.Append(line, severity);
	Strings.Append(line, " file="); Strings.Append(line, testFile);
	Strings.Append(line, ",title="); Strings.Append(line, testFile);
	Strings.Append(line, "::"); Strings.Append(line, kind);
	Strings.Append(line, ": "); Strings.Append(line, name);
	Say(line)
END Annotate;

(* What the child left behind, indented, as the shell version's excerpt was. *)
PROCEDURE ShowCaseLog;
VAR path: Path; handle: Files.File; reader: Files.Reader; line: ARRAY 1024 OF CHAR; shown: SIGNED32;
BEGIN
	Join(testScratch, "case.log", path);
	handle := Files.Old(path);
	IF handle = NIL THEN RETURN END;
	Files.OpenReader(reader, handle, 0);
	shown := 0;
	WHILE (reader.res = Streams.Ok) & (testVerbose OR (shown < 20)) DO
		reader.Ln(line); Strings.Trim(line, 0DX);
		IF line # "" THEN
			out.String("        "); out.String(line); EndLine(out); INC(shown)
		END
	END;
	handle.Close
END ShowCaseLog;

PROCEDURE RunCase(CONST kind, name, entry: ARRAY OF CHAR);
VAR arguments: Strings.StringArray; exitCode: SIGNED32; line, key: Path;
	bad, good, expected, finished: BOOLEAN;
BEGIN
	NEW(arguments, 5);
	arguments[0] := Strings.NewString("ob");
	arguments[1] := Strings.NewString("test-case");
	arguments[2] := Strings.NewString(testScratch);
	arguments[3] := Strings.NewString(entry);
	IF testRun THEN arguments[4] := Strings.NewString("run") ELSE arguments[4] := Strings.NewString("compile") END;

	(* A file descriptor is released when the File that held it is collected, and a run of six
	   thousand cases would otherwise reach the limit long before the collector had a reason to
	   run. Every so often, give it one. *)
	INC(sinceCollection);
	IF sinceCollection >= 200 THEN Kernel.GC; sinceCollection := 0 END;

	finished := RunProgram(testSelf, arguments, caseLimit, exitCode);
	bad := ~finished OR (exitCode # 0);
	good := (kind = "positive") & ~bad OR (kind = "negative") & bad;

	key := ""; Strings.Append(key, testFile); Strings.AppendChar(key, 9X);
	Strings.Append(key, kind); Strings.Append(key, ": "); Strings.Append(key, name);
	expected := HasKey(baseline, key);

	IF good & ~expected THEN
		INC(passedCases); line := "  ok    "; Strings.Append(line, kind);
		Strings.Append(line, ": "); Strings.Append(line, name); Say(line);
		IF testVerbose THEN ShowCaseLog END;
		RecordCase("ok", kind, name)
	ELSIF good THEN
		INC(fixedCases); line := "  FIXED "; Strings.Append(line, kind);
		Strings.Append(line, ": "); Strings.Append(line, name);
		Strings.Append(line, "  (passes now — remove it from the baseline)"); Say(line);
		RecordCase("fixed", kind, name);
		Annotate("warning", kind, name)
	ELSIF expected THEN
		INC(knownCases); line := "  known "; Strings.Append(line, kind);
		Strings.Append(line, ": "); Strings.Append(line, name); Say(line);
		IF testVerbose THEN ShowCaseLog END;
		RecordCase("known", kind, name)
	ELSE
		INC(failedCases); AddKey(newFailures, key);
		line := "  FAIL  "; Strings.Append(line, kind);
		Strings.Append(line, ": "); Strings.Append(line, name);
		IF ~finished THEN Strings.Append(line, "  (did not come back)") END;
		Say(line); ShowCaseLog;
		RecordCase("failed", kind, name);
		Annotate("error", kind, name)
	END
END RunCase;

(* The case body, as the child will find it, and the modules it declares. *)
PROCEDURE WriteCase(body: Streams.Buffer; modules: Strings.StringArray; count: SIZE;
		VAR entry: ARRAY OF CHAR): BOOLEAN;
VAR path: Path; text: Strings.String; index: SIZE; ignore: BOOLEAN;
BEGIN
	IF count = 0 THEN RETURN FALSE END;
	(* start Test when the case declares it, which is the convention, else the last module *)
	COPY(modules[count-1]^, entry);
	FOR index := 0 TO count-1 DO
		IF modules[index]^ = "Test" THEN entry := "Test" END
	END;
	(* drop only THIS case's own artifacts, so a compile failure cannot be masked by a stale
	   object; earlier cases' modules stay, because the test files build up helpers in one case
	   and import them in later ones *)
	FOR index := 0 TO count-1 DO
		Join(testScratch, modules[index]^, path); Strings.AppendChar(path, '.');
		Strings.Append(path, ObjectExtension); ignore := ObHost.Remove(path);
		Join(testScratch, modules[index]^, path); Strings.Append(path, SymbolExtension);
		ignore := ObHost.Remove(path)
	END;
	(* Written through ObHost rather than through Files, and this is the difference between a run
	   that reports the truth and one that does not: a Files.File keeps its descriptor until the
	   collector finalises it, Files.File.Close is abstract and does nothing on Unix, and there is
	   one of these per case. When the descriptors run out, Files.New quietly returns NIL and every
	   later case is reported as having no MODULE in it -- 4240 of them, in the run that found it. *)
	Join(testScratch, "TesterInput.txt", path);
	text := body.GetString();
	IF text = NIL THEN Die("the case body could not be read back"); RETURN FALSE END;
	IF ~ObHost.WriteFile(path, text^) THEN DieOn("cannot write ", path); RETURN FALSE END;
	RETURN TRUE
END WriteCase;

PROCEDURE CaseSelected(CONST name: ARRAY OF CHAR): BOOLEAN;
VAR lowerName, lowerFilter: Path;
BEGIN
	IF testFilter = "" THEN RETURN TRUE END;
	COPY(name, lowerName); Strings.LowerCase(lowerName);
	COPY(testFilter, lowerFilter); Strings.LowerCase(lowerFilter);
	RETURN Strings.Pos(lowerFilter, lowerName) >= 0
END CaseSelected;

(* A file may carry harness settings on a `# options` line. Two of them matter: a prolog asking
   for another target cannot work against this SDK's symbol files, and a command with no
   System.Load means the file only checks that things compile. *)
PROCEDURE ReadFileOptions(CONST line: ARRAY OF CHAR; VAR skip: BOOLEAN);
VAR flags: Path; start, stop: SIZE;
BEGIN
	skip := FALSE; testRun := TRUE;
	IF Strings.Pos("System.Load", line) < 0 THEN testRun := FALSE END;
	start := Strings.Pos("Compiler.Compile", line);
	IF start < 0 THEN RETURN END;
	INC(start, 16);
	stop := Strings.Pos("TesterInput.txt", line);
	IF stop <= start THEN RETURN END;
	Strings.Copy(line, start, stop - start, flags);
	Strings.TrimLeft(flags, ' ');
	IF Strings.Pos("-p=", flags) >= 0 THEN
		out.String("  SKIP  whole file: it names its own target ("); out.String(flags);
		out.String("), which is not the one being tested"); EndLine(out);
		skip := TRUE
	END
END ReadFileOptions;

PROCEDURE RunTestFile(CONST file: ARRAY OF CHAR);
VAR handle: Files.File; reader: Files.Reader; line, kind, name, entry, nextKind, nextName: Path;
	body: Streams.Buffer; writer: Streams.Writer; modules: Strings.StringArray;
	count, position, length: SIZE; skip, pending: BOOLEAN;

	PROCEDURE Flush;
	BEGIN
		IF pending & CaseSelected(name) THEN
			writer.Update;
			IF WriteCase(body, modules, count, entry) THEN
				RunCase(kind, name, entry); INC(totalCases)
			ELSE
				out.String("  SKIP  "); out.String(name); out.String(" (no MODULE in case)");
				EndLine(out); RecordCase("skipped", kind, name)
			END
		END;
		pending := FALSE
	END Flush;

	PROCEDURE Begin(CONST newKind, newName: ARRAY OF CHAR);
	BEGIN
		COPY(newKind, kind); COPY(newName, name); Strings.Trim(name, ' ');
		NEW(body, 4096); writer := body.GetWriter();
		NEW(modules, 64); count := 0; pending := TRUE
	END Begin;

BEGIN
	BaseName(file, testFile);
	line := "=== "; Strings.Append(line, testFile); Say(line);
	handle := Files.Old(file);
	IF handle = NIL THEN DieOn("no such file: ", file); RETURN END;
	Files.OpenReader(reader, handle, 0);
	testRun := TRUE; pending := FALSE; skip := FALSE;
	WHILE reader.res = Streams.Ok DO
		reader.Ln(line); Strings.Trim(line, 0DX);
		IF Strings.Pos("positive:", line) = 0 THEN
			Flush; Strings.Copy(line, 9, Strings.Length(line) - 9, nextName); Begin("positive", nextName)
		ELSIF Strings.Pos("negative:", line) = 0 THEN
			Flush; Strings.Copy(line, 9, Strings.Length(line) - 9, nextName); Begin("negative", nextName)
		ELSIF (line # "") & (line[0] = '#') THEN
			IF Strings.Pos("options", line) > 0 THEN
				ReadFileOptions(line, skip);
				IF skip THEN RETURN END
			END
		ELSIF pending THEN
			writer.String(line); writer.Char(0AX);
			(* a MODULE header inside the case: the module this case declares *)
			position := 0;
			WHILE (line[position] = ' ') OR (line[position] = 9X) DO INC(position) END;
			IF (Strings.Pos("MODULE ", line) = position) & (count < LEN(modules^)) THEN
				INC(position, 7);
				WHILE line[position] = ' ' DO INC(position) END;
				length := position;
				WHILE ((line[length] >= 'A') & (line[length] <= 'Z'))
						OR ((line[length] >= 'a') & (line[length] <= 'z'))
						OR ((line[length] >= '0') & (line[length] <= '9'))
						OR (line[length] = '_') DO INC(length) END;
				IF length > position THEN
					Strings.Copy(line, position, length - position, nextKind);
					modules[count] := Strings.NewString(nextKind); INC(count)
				END
			END
		END
	END;
	handle.Close;
	Flush
END RunTestFile;

PROCEDURE WriteReport(CONST file: ARRAY OF CHAR);
VAR handle: Files.File; writer: Files.Writer; record: CaseRecord; first: BOOLEAN; line: Path;

	PROCEDURE Count(CONST label: ARRAY OF CHAR; value: SIGNED32);
	BEGIN
		writer.String("  "); WriteJsonString(writer, label); writer.String(": ");
		writer.Int(value, 0); writer.String(","); writer.Char(0AX)
	END Count;

BEGIN
	handle := Files.New(file);
	IF handle = NIL THEN DieOn("cannot write the report ", file); RETURN END;
	Files.OpenWriter(writer, handle, 0);
	writer.String("{"); writer.Char(0AX);
	Count("total", totalCases); Count("passed", passedCases); Count("failed", failedCases);
	Count("known", knownCases); Count("fixed", fixedCases);
	writer.String('  "cases": ['); writer.Char(0AX);
	record := caseRecords; first := TRUE;
	WHILE record # NIL DO
		IF ~first THEN writer.String(","); writer.Char(0AX) END;
		first := FALSE;
		writer.String('    {"status": '); WriteJsonString(writer, record.status);
		writer.String(', "file": '); WriteJsonString(writer, record.file);
		writer.String(', "kind": '); WriteJsonString(writer, record.kind);
		writer.String(', "name": '); WriteJsonString(writer, record.name);
		writer.String("}");
		record := record.next
	END;
	IF ~first THEN writer.Char(0AX) END;
	writer.String("  ]"); writer.Char(0AX);
	writer.String("}"); writer.Char(0AX);
	writer.Update; Files.Register(handle); handle.Close;
	line := "ob test: wrote report "; Strings.Append(line, file); Say(line)
END WriteReport;

PROCEDURE WriteExpected(CONST file: ARRAY OF CHAR);
VAR handle: Files.File; writer: Files.Writer; entry: Key; sorted: Strings.StringArray;
	swap: Strings.String; count, index, position: SIZE; line: Path;
BEGIN
	count := CountKeys(newFailures);
	NEW(sorted, count + 1); index := 0; entry := newFailures;
	WHILE entry # NIL DO sorted[index] := Strings.NewString(entry.text); INC(index); entry := entry.next END;
	FOR index := 1 TO count-1 DO
		swap := sorted[index]; position := index;
		WHILE (position > 0) & (sorted[position-1]^ > swap^) DO
			sorted[position] := sorted[position-1]; DEC(position)
		END;
		sorted[position] := swap
	END;
	handle := Files.New(file);
	IF handle = NIL THEN DieOn("cannot write the baseline ", file); RETURN END;
	Files.OpenWriter(writer, handle, 0);
	writer.String("# Cases known to fail in this tree — regenerate with: ob test --write-expected ");
	BaseName(file, line); writer.String(line); writer.Char(0AX);
	writer.String("# Format: <TestFile><TAB><kind>: <case name>.  A listed case that PASSES is reported");
	writer.Char(0AX);
	writer.String("# as FIXED and fails the run, so this file cannot silently go stale."); writer.Char(0AX);
	FOR index := 0 TO count-1 DO writer.String(sorted[index]^); writer.Char(0AX) END;
	writer.Update; Files.Register(handle); handle.Close;
	line := "ob test: wrote baseline "; Strings.Append(line, file);
	Strings.Append(line, " ("); Strings.AppendInt(line, count); Strings.Append(line, " entr(ies))");
	Say(line)
END WriteExpected;

(* Not a verb for people: one case, compiled and loaded in a process of its own, answering with
   its exit code. Everything it says goes to case.log in the scratch directory. *)
PROCEDURE TestCaseVerb;
VAR scratch, entry, mode, path: Path; handle: Files.File; writer: Files.Writer;
	source: Path; module: Modules.Module; result: INTEGER; message: ARRAY 256 OF CHAR;
	compiled: BOOLEAN;
BEGIN
	IF ~NextArgument(scratch) OR ~NextArgument(entry) OR ~NextArgument(mode) THEN
		Die("test-case is internal: ob test-case <scratch> <Entry> run|compile"); RETURN
	END;
	Join(scratch, "case.log", path);
	handle := Files.New(path);
	IF handle # NIL THEN Files.OpenWriter(writer, handle, 0); error := writer END;

	IF ~AddSearchPath(lib) OR ~AddSearchPath(project) OR ~AddSearchPath(scratch)
			OR ~SetWorkPath(scratch) THEN
		failed := TRUE
	ELSE
		Join(scratch, "TesterInput.txt", source);
		CaptureTrace;
		compiled := CompileFile(source, CompilerPlatform, ObjectExtension, SymbolExtension, TRUE);
		IF compiled & (mode = "run") THEN
			module := Modules.ThisModule(entry, result, message);
			IF module = NIL THEN
				error.String("could not load module "); error.String(entry);
				error.String(": "); error.String(message); error.Char(0AX);
				compiled := FALSE
			END
		END;
		RestoreTrace;
		WriteTraced(error);
		IF ~compiled THEN failed := TRUE END
	END;
	IF handle # NIL THEN error.Update; Files.Register(handle) END
END TestCaseVerb;

PROCEDURE TestVerb;
VAR argument, target, expect, write, entry, path, line: Path;
	files: Strings.StringArray; count, index: SIZE; handle: ADDRESS; limitText: Path;
BEGIN
	testVerbose := FALSE; testFilter := ""; testReport := ""; expect := ""; write := "";
	COPY(HostTarget, target);
	testGithub := ObHost.Env("GITHUB_ACTIONS", line) & (line = "true");
	NEW(files, 256); count := 0;
	WHILE NextArgument(argument) DO
		IF (argument = "-v") OR (argument = "--verbose") THEN testVerbose := TRUE
		ELSIF (argument = "-t") OR (argument = "--target") THEN
			IF ~NextArgument(target) THEN Die("-t needs a target"); RETURN END
		ELSIF (argument = "-r") OR (argument = "--run") THEN
			IF ~NextArgument(testFilter) THEN Die("-r needs a substring"); RETURN END
		ELSIF argument = "--expect" THEN
			IF ~NextArgument(expect) THEN Die("--expect needs a file"); RETURN END
		ELSIF argument = "--write-expected" THEN
			IF ~NextArgument(write) THEN Die("--write-expected needs a file"); RETURN END
		ELSIF argument = "--report" THEN
			IF ~NextArgument(testReport) THEN Die("--report needs a file"); RETURN END
		ELSIF argument = "--github" THEN testGithub := TRUE
		ELSIF argument[0] = '-' THEN DieOn("unknown option: ", argument); RETURN
		ELSIF count < LEN(files^) THEN files[count] := Strings.NewString(argument); INC(count)
		END
	END;

	IF target # HostTarget THEN
		DieOn("this ob cannot test for another architecture yet; the shell ob still can: -t ", target);
		RETURN
	END;

	IF count = 0 THEN
		handle := ObHost.OpenDirectory(project);
		IF handle # 0 THEN
			WHILE ObHost.NextEntry(handle, entry) & (count < LEN(files^)) DO
				IF Strings.Match("*.Test", entry) THEN
					Join(project, entry, path); files[count] := Strings.NewString(path); INC(count)
				END
			END;
			ObHost.CloseDirectory(handle)
		END;
		IF count = 0 THEN Die("no *.Test files here (usage: ob test [File.Test ...])"); RETURN END
	END;
	(* resolved now, while the working directory is still the user's: the scratch directory the
	   cases are compiled in becomes the working directory further down, and a name given on the
	   command line is relative to where ob was started *)
	FOR index := 0 TO count-1 DO
		IF ObHost.RealPath(files[index]^, path) THEN files[index] := Strings.NewString(path)
		ELSE DieOn("no such file: ", files[index]^); RETURN
		END
	END;

	IF expect = "" THEN
		IF target = "linux64" THEN expect := "a2test-expected.txt"
		ELSE expect := "a2test-expected-"; Strings.Append(expect, target); Strings.Append(expect, ".txt")
		END
	END;
	Join(project, expect, path);
	IF ObHost.Exists(path) THEN LoadBaseline(path) ELSE baseline := NIL END;

	caseLimit := 180000;
	IF ObHost.Env("A2_TEST_CASE_TIMEOUT", limitText) & (limitText # "") THEN
		caseLimit := SIGNED32(1000 * ToInteger(limitText, 180))
	END;
	IF ~ObHost.ExecutablePath(testSelf) THEN Die("cannot find my own binary"); RETURN END;
	IF ~ScratchDirectory(testScratch) THEN Die("cannot create a scratch directory"); RETURN END;
	IF AddSearchPath(lib) & AddSearchPath(project) & AddSearchPath(testScratch)
			& SetWorkPath(testScratch) THEN
		BuildSiblings(testScratch, CompilerPlatform, ObjectExtension, SymbolExtension)
	END;

	totalCases := 0; sinceCollection := 0; passedCases := 0; failedCases := 0; knownCases := 0; fixedCases := 0;
	newFailures := NIL; caseRecords := NIL;
	FOR index := 0 TO count-1 DO RunTestFile(files[index]^) END;
	DiscardScratch(testScratch);

	Say("");
	line := "ob test: "; Strings.AppendInt(line, totalCases); Strings.Append(line, " case(s), ");
	Strings.AppendInt(line, passedCases); Strings.Append(line, " passed, ");
	Strings.AppendInt(line, failedCases); Strings.Append(line, " failed, ");
	Strings.AppendInt(line, knownCases); Strings.Append(line, " known-failing, ");
	Strings.AppendInt(line, fixedCases); Strings.Append(line, " fixed"); Say(line);

	IF write # "" THEN Join(project, write, path); WriteExpected(path); RETURN END;
	IF testReport # "" THEN Join(project, testReport, path); WriteReport(path) END;
	IF fixedCases > 0 THEN
		line := "ob test: "; Strings.AppendInt(line, fixedCases);
		Strings.Append(line, " case(s) marked known-failing now pass — drop them from the baseline");
		Say(line)
	END;
	IF (failedCases > 0) OR (fixedCases > 0) THEN failed := TRUE END
END TestVerb;

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
	Say("  ob get <pkg>[@ver] ...             fetch package(s) into .a2pkg/, pin them, resolve deps");
	Say("  ob test [File.Test ...] [-v]       run test files (default: every *.Test here)");
	Say("  ob doc [File.Mod] [-o dir]         generate HTML API docs (index + per-module)");
	Say("  ob lint                            check every import points at its tier or lower");
	Say("  ob lsp [--live]                    the Active Oberon language server, over stdio");
	Say("  ob repl                            the interactive A2 shell, in this directory");
	Say("  ob version                         print the SDK version banner");
	Say("  ob help                            this text");
	Say("");
	Say("Still served by the shell version: ob test for another architecture.")
END Help;

(* --- entry ------------------------------------------------------------------------------- *)

PROCEDURE Dispatch(CONST verb: ARRAY OF CHAR);
VAR message: ARRAY 128 OF CHAR;
BEGIN
	IF verb = "build" THEN BuildVerb
	ELSIF verb = "compile" THEN CompileVerb
	ELSIF verb = "run" THEN RunVerb
	ELSIF verb = "get" THEN GetVerb
	ELSIF verb = "test" THEN TestVerb
	ELSIF verb = "test-case" THEN TestCaseVerb
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
	Layout; FindProject; InstallFetch;
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
