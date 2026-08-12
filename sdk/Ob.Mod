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
	lib-, libWin-, libA64-, libLinux-, libSym-: Path;
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

(**
	A path the caller gave, resolved against a directory -- unless it is absolute already, in which
	case it is taken as it stands. A leading separator on Unix, a drive letter or a leading
	separator on Windows.
*)
PROCEDURE Absolute*(CONST dir, name: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
VAR letter: BOOLEAN;
BEGIN
	letter := ((CAP(name[0]) >= 'A') & (CAP(name[0]) <= 'Z')) & (LEN(name) > 1) & (name[1] = ':');
	IF IsSeparator(name[0]) OR letter THEN COPY(name, path) ELSE Join(dir, name, path) END
END Absolute;

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

(*
	Put a list of names in order. Wanted wherever ob enumerates a directory: what order a directory
	hands its entries back in is the file system's business and changes as files are written, so a
	run over "everything here" would otherwise not be the same run twice -- and the shell version,
	which enumerated with a glob, was sorted without having to think about it.
*)
PROCEDURE SortNames*(names: Strings.StringArray; count: SIZE);
VAR index, place: SIZE; held: Strings.String;
BEGIN
	FOR index := 1 TO count-1 DO
		held := names[index]; place := index;
		WHILE (place > 0) & (names[place-1]^ > held^) DO
			names[place] := names[place-1]; DEC(place)
		END;
		names[place] := held
	END
END SortNames;

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
	Join(sdk, "lib-linux64", libLinux);
	Join(sdk, "lib-sym", libSym);
	Join(sdk, "packages", packages);
	Join(sdk, "boot-modules.txt", bootList);
	Join(sdk, "boot-modules-win64.txt", bootListWin);
	(* On an SDK that is not x86-64 Linux, the native objects in lib/ ARE that platform's objects
	   and there is no separate cross directory for it. *)
	IF (HostTarget = "a64") & ~ObHost.Exists(libA64) THEN COPY(lib, libA64) END;
	IF (HostTarget = "win64") & ~ObHost.Exists(libWin) THEN COPY(lib, libWin) END;
	IF (HostTarget = "linux64") & ~ObHost.Exists(libLinux) THEN COPY(lib, libLinux) END
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
	IF ObHost.Exists(libA64) THEN
		WriteCount("a64", libA64, ".SymU8"); Strings.Append(targets, ", a64 (AArch64 ELF)")
	END;
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

(*
	Where the objects for a target live. lib/ is this SDK's own platform and nothing else: on a
	Windows SDK it holds Win64 objects, so asking for linux64 there has to land on a directory that
	is not present rather than on the wrong objects.
*)
PROCEDURE TargetLibrary(CONST target: ARRAY OF CHAR; VAR directory: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF target = HostTarget THEN COPY(lib, directory)
	ELSIF target = "win64" THEN COPY(libWin, directory)
	ELSIF target = "a64" THEN COPY(libA64, directory)
	ELSE COPY(libLinux, directory)
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
(*
	The boot set as one line for the linker. `withShell` is the difference between the two images
	ob links: a built program has its own entry module and must not also start the interactive
	shell, while the image `ob test -t <other architecture>` runs cases in is driven by commands
	and is nothing without it.
*)
PROCEDURE ReadBootList(CONST file: ARRAY OF CHAR; withShell: BOOLEAN; VAR list: ARRAY OF CHAR): BOOLEAN;
VAR handle: Files.File; reader: Files.Reader; line: Path;
BEGIN
	handle := Files.Old(file);
	IF handle = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	list := "";
	WHILE reader.res = Streams.Ok DO
		reader.Ln(line);
		Strings.Trim(line, ' '); Strings.Trim(line, 0DX);
		IF (line # "") & (line[0] # '#')
				& (withShell OR ((line # "StdIOShell") & (line # "Shell"))) THEN
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
	IF ~ReadBootList(boot, FALSE, bootModules) THEN DieOn("cannot read the boot module list ", boot); RETURN END;

	IF output = "" THEN COPY(name, output); Strings.Append(output, suffix) END;
	Absolute(project, output, destination);
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
	Copy a prepared scratch directory into a fresh one. `ob test -j` gives every job a directory of
	its own -- the cases of one file leave objects behind that its later cases import, and two files
	sharing a directory would overwrite each other's -- and every job needs what the run prepared
	once: the project's siblings compiled, and, for another architecture, the image cases are
	executed in. Copying beats preparing it N times, and it is the same bytes by construction. The
	prepared directory holds files only; the job directories are made beside it, not inside it.
*)
PROCEDURE SeedScratch(CONST from, to: ARRAY OF CHAR): BOOLEAN;
VAR handle: ADDRESS; name, source, destination: Path; ignore: BOOLEAN;
BEGIN
	handle := ObHost.OpenDirectory(from);
	IF handle = 0 THEN RETURN FALSE END;
	WHILE ObHost.NextEntry(handle, name) DO
		IF (name # ".") & (name # "..") THEN
			Join(from, name, source); Join(to, name, destination);
			IF CopyFile(source, destination) & ObHost.Executable(source) THEN
				ignore := ObHost.MakeExecutable(destination)
			END
		END
	END;
	ObHost.CloseDirectory(handle);
	RETURN TRUE
END SeedScratch;

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
	pages: Strings.StringArray; count, i: SIZE;
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
	SortNames(pages, count);

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
		END;
		SortNames(names, count)
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
(*
	-j -- several pieces of the suites at a time.

	Files alone are not enough to divide by: 5450 of this tree's 6965 cases are in one file, so a run
	split by file is still that file long. What is divided is the case list itself, into chunks a job
	takes one at a time, in a directory of its own.

	The cases of a file are NOT independent -- the files build up a helper module in one case and
	import it in a later one -- and this is what a chunk has to carry with it. Every case's imports
	are read at parse time; a case whose import was declared by an earlier case depends on it, and a
	chunk begins by replaying, silently and compile-only, the earlier cases its own cases depend on
	(transitively). Everything else a case might have found in the directory it never asked for, so
	not having it changes nothing -- and being generous here is safe by construction: anything
	replayed is something the sequential run had at that point too.

	A job is a state machine the parent steps, not a thread: there is nothing to synchronise then,
	and a case is still a process of its own with a deadline, as it has to be. Output is buffered per
	chunk and printed when every chunk before it has been, so a parallel run reads exactly like a
	sequential one and the two can be diffed line by line. With -j 1 there is one chunk per file,
	nothing is buffered, and the run streams as it always did.
*)
CONST DeclarationTableSize = 4096;

TYPE
	Key = POINTER TO RECORD next: Key; text: Path END;
	CaseRecord = POINTER TO RECORD next: CaseRecord; status, file, kind, name: Path END;

	(* A case as the parser found it. Reading a file is separated from running it because a job that
	   has to stop at every case to read the next line cannot be stepped alongside others. *)
	TestCase = POINTER TO RECORD
		next: TestCase;
		kind, name, entry: Path;
		body: Strings.String;
		modules: Strings.StringArray; count: SIZE;
		imports: Strings.StringArray; importCount: SIZE;
		needs: CaseLink;					(* earlier cases of this file that declare what this one imports *)
		index: SIZE
	END;

	CaseLink = POINTER TO RECORD next: CaseLink; case: TestCase END;

	(* Which case last declared a module, while a file is being planned. *)
	Declaration = POINTER TO RECORD next: Declaration; name: Path; case: TestCase END;

	(* A piece of one file: the cases to report on, the earlier ones to replay first, and whether the
	   file's cases execute or only compile. *)
	Chunk = POINTER TO RECORD
		next: Chunk;
		name: Path;						(* the test file's base name *)
		header: BOOLEAN;				(* this is the file's first chunk, so it prints the === line *)
		message: Path;					(* a whole-file SKIP, printed instead of running anything *)
		execute: BOOLEAN;
		replay: CaseLink;
		first: TestCase; count: SIZE;
		index: SIZE
	END;

	Job = POINTER TO RECORD
		scratch: Path;					(* its own directory *)
		chunk: Chunk;
		pending: TestCase; remaining: SIZE;
		replay: CaseLink;
		current: TestCase;				(* the case in flight *)
		replaying: BOOLEAN;				(* ... and whether it is only being replayed, so it is not judged *)
		busy: BOOLEAN;
		buffered: BOOLEAN;
		buffer: Streams.Buffer;			(* NIL when the job writes straight to the terminal *)
		writer: Streams.Writer;
		records, lastRecord: CaseRecord;
		process: ADDRESS;
		spawnFault: SIGNED32;			(* why the case would not start; per job, because ObHost's is not *)
		deadline: Kernel.MilliTimer
	END;

	(* One finished chunk, held until every chunk before it has been printed. *)
	Block = POINTER TO RECORD
		text: Strings.String;
		records: CaseRecord
	END;

VAR
	baseline, newFailures: Key;
	caseRecords, lastCaseRecord: CaseRecord;
	testVerbose, testGithub: BOOLEAN;
	testFilter, testReport, testScratch, testSelf: Path;
	caseLimit, sinceCollection: SIGNED32;
	blocks: POINTER TO ARRAY OF Block;		(* one per chunk, in the order the chunks were planned *)
	declarations: ARRAY DeclarationTableSize OF Declaration;
	seedKeep: Path;							(* the one file a job's directory keeps when it is emptied *)
	totalCases, passedCases, failedCases, knownCases, fixedCases: SIGNED32;

	(* The target the cases are compiled for, and what compiling for it means. Equal to this
	   binary's own settings unless -t named another architecture. *)
	testTarget, testPlatform, testObject, testSymbol, testLibrary: Path;
	(* The emulator a case built for another architecture is run in, empty when there is none --
	   which is how the run knows to skip the cases that execute rather than report them on no
	   evidence. The C library and the image are the child's business: it resolves them the same
	   way and from the same environment, so nothing has to be handed over. *)
	testEmulator: Path;

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

PROCEDURE LoadBaseline(CONST file, name: ARRAY OF CHAR);
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
	(* Named as it was asked for, not as it was found: the baseline is looked up inside the project,
	   and printing the absolute path would say something different from the shell version for no
	   gain to whoever reads it. *)
	line := "ob test: baseline "; Strings.Append(line, name);
	Strings.Append(line, " ("); Strings.AppendInt(line, CountKeys(baseline));
	Strings.Append(line, " known failure(s))"); Say(line)
END LoadBaseline;

(*
	--- testing for another architecture -------------------------------------------------------

	A case for another architecture cannot be loaded into this process, so it is compiled here and
	executed in an emulator, on an image of that architecture linked out of the objects this SDK
	carries for it. Both halves of that are needed: without the emulator or a C library for it,
	the suites that only compile still run and the ones that execute are skipped -- reported as
	skipped, not as passed, which is the whole point of saying it out loud.

	Both the parent and the case child resolve this the same way and from the same environment, so
	the child needs no more than the name of the target on its command line.
*)
(*
	How long a case is given before it is taken to be not coming back. Both processes need it: the
	parent bounds the case child, and the child bounds the emulator it starts -- and a limit of
	zero, which is what the child had while this lived in TestVerb alone, kills the emulator before
	it has drawn breath. Nothing is reported then, which reads as a case that produced no output.
*)
PROCEDURE ReadCaseLimit;
VAR text: Path;
BEGIN
	caseLimit := 180000;
	IF ObHost.Env("A2_TEST_CASE_TIMEOUT", text) & (text # "") THEN
		caseLimit := SIGNED32(1000 * ToInteger(text, 180))
	END
END ReadCaseLimit;

PROCEDURE TestTargetSettings(CONST target: ARRAY OF CHAR): BOOLEAN;
BEGIN
	COPY(target, testTarget);
	IF target = HostTarget THEN
		COPY(CompilerPlatform, testPlatform); COPY(ObjectExtension, testObject);
		COPY(SymbolExtension, testSymbol); COPY(lib, testLibrary);
		RETURN TRUE
	END;
	IF target # "a64" THEN
		DieOn("cannot test for this target from this SDK: ", target); RETURN FALSE
	END;
	testPlatform := "UnixA64"; testObject := "GofU8"; testSymbol := ".SymU8";
	COPY(libA64, testLibrary);
	IF ~ObHost.Exists(testLibrary) THEN
		DieOn("this SDK ships no objects for target ", target); RETURN FALSE
	END;
	RETURN TRUE
END TestTargetSettings;

(* The first of the named programs that exists on the PATH. *)
PROCEDURE OnPath(CONST first, second: ARRAY OF CHAR; VAR program: ARRAY OF CHAR): BOOLEAN;
VAR directories, directory, candidate: Path; position, start: SIZE; index: SIGNED32;

	PROCEDURE Look(CONST name: ARRAY OF CHAR): BOOLEAN;
	BEGIN
		Join(directory, name, candidate);
		IF ObHost.Executable(candidate) THEN COPY(candidate, program); RETURN TRUE END;
		RETURN FALSE
	END Look;

BEGIN
	IF ~ObHost.Env("PATH", directories) THEN RETURN FALSE END;
	position := 0; start := 0;
	LOOP
		IF (directories[position] = ':') OR (directories[position] = 0X) THEN
			IF position > start THEN
				Strings.Copy(directories, start, position - start, directory);
				IF Look(first) OR Look(second) THEN RETURN TRUE END
			END;
			IF directories[position] = 0X THEN EXIT END;
			start := position + 1
		END;
		INC(position);
		IF position >= LEN(directories) THEN EXIT END
	END;
	RETURN FALSE
END OnPath;

PROCEDURE FindEmulator(VAR program: ARRAY OF CHAR): BOOLEAN;
VAR named: Path;
BEGIN
	IF ObHost.Env("A2_QEMU", named) & (named # "") THEN
		IF ~ObHost.Executable(named) THEN
			DieOn("A2_QEMU names something that cannot be run: ", named); RETURN FALSE
		END;
		COPY(named, program); RETURN TRUE
	END;
	RETURN OnPath("qemu-aarch64-static", "qemu-aarch64", program)
END FindEmulator;

(* The emulator needs an AArch64 C library to load the image against: the image is dynamically
   linked, as every A2 Unix binary is. On Debian and Ubuntu that is the libc6-arm64-cross package;
   tests/a64-sysroot.sh unpacks one where the package cannot be installed. *)
PROCEDURE FindSysroot(VAR directory: ARRAY OF CHAR): BOOLEAN;
VAR named, loader: Path;

	PROCEDURE Holds(CONST candidate: ARRAY OF CHAR): BOOLEAN;
	BEGIN
		Join(candidate, "lib", loader); Join(loader, "ld-linux-aarch64.so.1", loader);
		RETURN ObHost.Exists(loader)
	END Holds;

BEGIN
	IF ObHost.Env("A2_A64_SYSROOT", named) & (named # "") THEN
		IF ~Holds(named) THEN
			DieOn("A2_A64_SYSROOT has no lib/ld-linux-aarch64.so.1: ", named); RETURN FALSE
		END;
		COPY(named, directory); RETURN TRUE
	END;
	IF Holds("/usr/aarch64-linux-gnu") THEN directory := "/usr/aarch64-linux-gnu"; RETURN TRUE END;
	IF Holds("/usr/local/aarch64-linux-gnu") THEN directory := "/usr/local/aarch64-linux-gnu"; RETURN TRUE END;
	RETURN FALSE
END FindSysroot;

(* Where the image lives, given the scratch directory the run works in. Both the parent, which
   links it, and the child, which runs it, compute this rather than passing it along. *)
PROCEDURE EmulatorImage(CONST scratch: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
BEGIN
	Join(scratch, "oberon-", path); Strings.Append(path, testTarget)
END EmulatorImage;

(* Look for the emulator and a C library, and link an image to run cases in. Anything missing
   leaves testEmulator empty, which is how the run knows to skip the suites that execute. *)
PROCEDURE PrepareEmulator;
VAR arguments, list, image, name, sysroot, line: Path;

	PROCEDURE Without(CONST reason: ARRAY OF CHAR);
	BEGIN
		line := "ob test: "; Strings.Append(line, reason);
		Strings.Append(line, " — cases that execute will be skipped"); Say(line);
		testEmulator := ""
	END Without;

BEGIN
	testEmulator := "";
	IF testTarget # "a64" THEN RETURN END;
	IF testTarget = HostTarget THEN
		(* On an AArch64 SDK there is nothing to emulate and no image to link: this process is
		   already the machine the cases are compiled for, so they load into it like any other
		   case. It is also the only way the suites see a processor that reorders memory accesses
		   -- qemu-user does not -- which is the whole reason for running them on the phone. *)
		Say("ob test: AArch64 cases run natively, in this process"); RETURN
	END;
	IF ~FindEmulator(testEmulator) OR ~FindSysroot(sysroot) THEN
		Without("no qemu-aarch64 or AArch64 C library"); RETURN
	END;
	IF ~ReadBootList(bootList, TRUE, list) THEN
		line := "no boot module list ("; Strings.Append(line, bootList);
		Strings.AppendChar(line, ')'); Without(line); RETURN
	END;

	EmulatorImage(testScratch, image); BaseName(image, name);
	(* No --path: the objects come off the search path and the image is written to the work path,
	   both of which are already the scratch directory. Naming it here would not survive the
	   linker's option parser anyway -- an unquoted value ends at the first character that cannot
	   be in a name, and a scratch directory is called ob-<pid>. The interactive shell stays in the
	   set on purpose: a case is loaded by a command given to that shell. *)
	arguments := "-p=LinuxA64 --extension="; Strings.Append(arguments, testObject);
	Strings.Append(arguments, " --fileName='"); Strings.Append(arguments, name);
	Strings.Append(arguments, "' "); Strings.Append(arguments, list);
	IF ~Link(arguments) OR ~ObHost.Exists(image) OR ~ObHost.MakeExecutable(image) THEN
		Without("could not link an AArch64 image"); RETURN
	END;

	(* Word for word what the shell version says, down to the name of the emulator: the check that
	   this driver replaced it compares the two transcripts, and a run is only the same run if it
	   reads the same. *)
	BaseName(testEmulator, name);
	line := "ob test: AArch64 cases run under "; Strings.Append(line, name);
	Strings.Append(line, " in a linked image"); Say(line)
END PrepareEmulator;

(* Everything a job says goes through its own writer: the terminal with -j 1, a buffer otherwise. *)
PROCEDURE Tell(job: Job; CONST text: ARRAY OF CHAR);
BEGIN job.writer.String(text); EndLine(job.writer)
END Tell;

PROCEDURE RecordCase(job: Job; CONST status, kind, name: ARRAY OF CHAR);
VAR record: CaseRecord;
BEGIN
	IF testReport = "" THEN RETURN END;
	NEW(record); COPY(status, record.status); COPY(job.chunk.name, record.file);
	COPY(kind, record.kind); COPY(name, record.name); record.next := NIL;
	IF job.records = NIL THEN job.records := record ELSE job.lastRecord.next := record END;
	job.lastRecord := record
END RecordCase;

(* One Actions annotation per case that breaks the build, so it shows on the run and not only in
   the log. Anchored at the test file; the format carries no line information. *)
PROCEDURE Annotate(job: Job; CONST severity, kind, name: ARRAY OF CHAR);
VAR line: Path;
BEGIN
	IF ~testGithub THEN RETURN END;
	line := "::"; Strings.Append(line, severity);
	Strings.Append(line, " file="); Strings.Append(line, job.chunk.name);
	Strings.Append(line, ",title="); Strings.Append(line, job.chunk.name);
	Strings.Append(line, "::"); Strings.Append(line, kind);
	Strings.Append(line, ": "); Strings.Append(line, name);
	Tell(job, line)
END Annotate;

(* What the child left behind, indented, as the shell version's excerpt was. *)
PROCEDURE ShowCaseLog(job: Job);
VAR path: Path; handle: Files.File; reader: Files.Reader; line: ARRAY 1024 OF CHAR; shown: SIGNED32;
BEGIN
	Join(job.scratch, "case.log", path);
	handle := Files.Old(path);
	IF handle = NIL THEN RETURN END;
	Files.OpenReader(reader, handle, 0);
	shown := 0;
	WHILE (reader.res = Streams.Ok) & (testVerbose OR (shown < 20)) DO
		reader.Ln(line); Strings.Trim(line, 0DX);
		IF line # "" THEN
			job.writer.String("        "); job.writer.String(line); EndLine(job.writer); INC(shown)
		END
	END;
	handle.Close
END ShowCaseLog;

(* The verdict on the case in flight. Split from starting it, because between the two the parent
   goes off and steps the other jobs. *)
PROCEDURE Verdict(job: Job; finished: BOOLEAN; exitCode: SIGNED32);
VAR line, key: Path; bad, good, expected: BOOLEAN;
BEGIN
	bad := ~finished OR (exitCode # 0);
	good := (job.current.kind = "positive") & ~bad OR (job.current.kind = "negative") & bad;

	key := ""; Strings.Append(key, job.chunk.name); Strings.AppendChar(key, 9X);
	Strings.Append(key, job.current.kind); Strings.Append(key, ": ");
	Strings.Append(key, job.current.name);
	expected := HasKey(baseline, key);

	IF good & ~expected THEN
		INC(passedCases); line := "  ok    "; Strings.Append(line, job.current.kind);
		Strings.Append(line, ": "); Strings.Append(line, job.current.name); Tell(job, line);
		IF testVerbose THEN ShowCaseLog(job) END;
		RecordCase(job, "ok", job.current.kind, job.current.name)
	ELSIF good THEN
		INC(fixedCases); line := "  FIXED "; Strings.Append(line, job.current.kind);
		Strings.Append(line, ": "); Strings.Append(line, job.current.name);
		Strings.Append(line, "  (passes now — remove it from the baseline)"); Tell(job, line);
		RecordCase(job, "fixed", job.current.kind, job.current.name);
		Annotate(job, "warning", job.current.kind, job.current.name)
	ELSIF expected THEN
		INC(knownCases); line := "  known "; Strings.Append(line, job.current.kind);
		Strings.Append(line, ": "); Strings.Append(line, job.current.name); Tell(job, line);
		IF testVerbose THEN ShowCaseLog(job) END;
		RecordCase(job, "known", job.current.kind, job.current.name)
	ELSE
		INC(failedCases); AddKey(newFailures, key);
		line := "  FAIL  "; Strings.Append(line, job.current.kind);
		Strings.Append(line, ": "); Strings.Append(line, job.current.name);
		IF ~finished THEN
			IF job.spawnFault # 0 THEN
				(* The case never started, which is not the case failing. Said apart because it
				   reads as a defect in the code under test and is a defect in the machine. *)
				Strings.Append(line, "  (could not be started: error ");
				Strings.AppendInt(line, job.spawnFault); Strings.AppendChar(line, ')')
			ELSE
				Strings.Append(line, "  (did not come back)")
			END
		END;
		Tell(job, line); ShowCaseLog(job);
		RecordCase(job, "failed", job.current.kind, job.current.name);
		Annotate(job, "error", job.current.kind, job.current.name)
	END
END Verdict;

(* The case body, as the child will find it, in the job's own directory. *)
PROCEDURE WriteCase(job: Job; case: TestCase): BOOLEAN;
VAR path: Path; index: SIZE; ignore: BOOLEAN;
BEGIN
	(* drop only THIS case's own artifacts, so a compile failure cannot be masked by a stale
	   object; earlier cases' modules stay, because the test files build up helpers in one case
	   and import them in later ones *)
	FOR index := 0 TO case.count-1 DO
		Join(job.scratch, case.modules[index]^, path); Strings.AppendChar(path, '.');
		Strings.Append(path, testObject); ignore := ObHost.Remove(path);
		Join(job.scratch, case.modules[index]^, path); Strings.Append(path, testSymbol);
		ignore := ObHost.Remove(path)
	END;
	(* Written through ObHost rather than through Files, and this is the difference between a run
	   that reports the truth and one that does not: a Files.File keeps its descriptor until the
	   collector finalises it, Files.File.Close is abstract and does nothing on Unix, and there is
	   one of these per case. When the descriptors run out, Files.New quietly returns NIL and every
	   later case is reported as having no MODULE in it -- 4240 of them, in the run that found it. *)
	Join(job.scratch, "TesterInput.txt", path);
	IF ~ObHost.WriteFile(path, case.body^) THEN DieOn("cannot write ", path); RETURN FALSE END;
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
PROCEDURE ReadFileOptions(CONST line: ARRAY OF CHAR; VAR execute, skip: BOOLEAN;
		VAR message: ARRAY OF CHAR);
VAR flags: Path; start, stop: SIZE;
BEGIN
	skip := FALSE; execute := TRUE;
	IF Strings.Pos("System.Load", line) < 0 THEN execute := FALSE END;
	start := Strings.Pos("Compiler.Compile", line);
	IF start < 0 THEN RETURN END;
	INC(start, 16);
	stop := Strings.Pos("TesterInput.txt", line);
	IF stop <= start THEN RETURN END;
	Strings.Copy(line, start, stop - start, flags);
	Strings.TrimLeft(flags, ' ');
	IF Strings.Pos("-p=", flags) >= 0 THEN
		COPY("  SKIP  whole file: it names its own target (", message);
		Strings.Append(message, flags);
		Strings.Append(message, "), which is not the one being tested");
		skip := TRUE
	END
END ReadFileOptions;

(* Every name in an IMPORT clause, which may run over several lines. Read generously: a name too
   many costs one replayed case, a name too few costs a case that cannot find what it imports. *)
PROCEDURE ReadImports(case: TestCase; CONST line: ARRAY OF CHAR; VAR inside: BOOLEAN);
VAR position, start: SIZE; word: Path;

	PROCEDURE Letter(character: CHAR): BOOLEAN;
	BEGIN
		RETURN ((character >= 'A') & (character <= 'Z')) OR ((character >= 'a') & (character <= 'z'))
			OR (character = '_')
	END Letter;

BEGIN
	position := 0;
	IF ~inside THEN
		position := Strings.Pos("IMPORT", line);
		IF position < 0 THEN RETURN END;
		INC(position, 6); inside := TRUE
	END;
	WHILE (line[position] # 0X) & (line[position] # ';') DO
		IF Letter(line[position]) THEN
			start := position;
			WHILE Letter(line[position]) OR ((line[position] >= '0') & (line[position] <= '9')) DO
				INC(position)
			END;
			IF case.importCount < LEN(case.imports^) THEN
				Strings.Copy(line, start, position - start, word);
				case.imports[case.importCount] := Strings.NewString(word); INC(case.importCount)
			END
		ELSE
			INC(position)
		END
	END;
	IF line[position] = ';' THEN inside := FALSE END
END ReadImports;

(*
	Read one file into cases. FALSE when the file is skipped as a whole -- with the reason in
	message, which the run prints where it would have printed the cases.
*)
PROCEDURE ParseTestFile(CONST file: ARRAY OF CHAR; VAR cases: TestCase; VAR count: SIZE;
		VAR execute: BOOLEAN; VAR message: ARRAY OF CHAR): BOOLEAN;
VAR handle: Files.File; reader: Files.Reader; line, word: Path;
	body: Streams.Buffer; writer: Streams.Writer; modules: Strings.StringArray;
	case, last: TestCase; modent, position, length, index: SIZE; skip, lost, inImport: BOOLEAN;

	PROCEDURE Close;
	BEGIN
		IF case = NIL THEN RETURN END;
		writer.Update; case.body := body.GetString();
		IF case.body = NIL THEN case.body := Strings.NewString(""); lost := TRUE END;
		case.modules := modules; case.count := modent;
		IF modent > 0 THEN
			(* start Test when the case declares it, which is the convention, else the last module *)
			COPY(modules[modent-1]^, case.entry);
			FOR index := 0 TO modent-1 DO
				IF modules[index]^ = "Test" THEN case.entry := "Test" END
			END
		END;
		case.index := count; INC(count);
		IF cases = NIL THEN cases := case ELSE last.next := case END;
		last := case; case := NIL
	END Close;

	PROCEDURE Begin(CONST kind, name: ARRAY OF CHAR);
	BEGIN
		Close;
		NEW(case); case.next := NIL; COPY(kind, case.kind);
		COPY(name, case.name); Strings.Trim(case.name, ' '); case.entry := "";
		NEW(body, 4096); writer := body.GetWriter();
		NEW(modules, 64); modent := 0;
		NEW(case.imports, 64); case.importCount := 0; case.needs := NIL;
		inImport := FALSE
	END Begin;

BEGIN
	cases := NIL; count := 0; execute := TRUE; COPY("", message);
	case := NIL; last := NIL; skip := FALSE; lost := FALSE; inImport := FALSE;
	handle := Files.Old(file);
	IF handle = NIL THEN DieOn("no such file: ", file); RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	WHILE (reader.res = Streams.Ok) & ~skip DO
		reader.Ln(line); Strings.Trim(line, 0DX);
		IF Strings.Pos("positive:", line) = 0 THEN
			Strings.Copy(line, 9, Strings.Length(line) - 9, word); Begin("positive", word)
		ELSIF Strings.Pos("negative:", line) = 0 THEN
			Strings.Copy(line, 9, Strings.Length(line) - 9, word); Begin("negative", word)
		ELSIF (line # "") & (line[0] = '#') THEN
			IF Strings.Pos("options", line) > 0 THEN ReadFileOptions(line, execute, skip, message) END
		ELSIF case # NIL THEN
			writer.String(line); writer.Char(0AX);
			ReadImports(case, line, inImport);
			(* a MODULE header inside the case: the module this case declares *)
			position := 0;
			WHILE (line[position] = ' ') OR (line[position] = 9X) DO INC(position) END;
			IF (Strings.Pos("MODULE ", line) = position) & (modent < LEN(modules^)) THEN
				INC(position, 7);
				WHILE line[position] = ' ' DO INC(position) END;
				length := position;
				WHILE ((line[length] >= 'A') & (line[length] <= 'Z'))
						OR ((line[length] >= 'a') & (line[length] <= 'z'))
						OR ((line[length] >= '0') & (line[length] <= '9'))
						OR (line[length] = '_') DO INC(length) END;
				IF length > position THEN
					Strings.Copy(line, position, length - position, word);
					modules[modent] := Strings.NewString(word); INC(modent)
				END
			END
		END
	END;
	handle.Close;
	IF skip THEN cases := NIL; count := 0; RETURN FALSE END;
	Close;
	IF lost THEN Die("the case body could not be read back"); RETURN FALSE END;
	(* Whether a file's cases execute is settled by its `# options` line. Compiled for another
	   architecture with nothing able to run them, they are skipped: reporting them on no evidence
	   is the one outcome worse than not running them. *)
	IF (cases # NIL) & execute & (testTarget # HostTarget) & (testEmulator = "") THEN
		COPY("  SKIP  whole file: its cases execute, and nothing here can execute ", message);
		Strings.Append(message, testPlatform); Strings.Append(message, " code");
		cases := NIL; count := 0; RETURN FALSE
	END;
	RETURN TRUE
END ParseTestFile;

(* --- what a chunk has to bring with it --------------------------------------------------- *)

PROCEDURE HashName(CONST name: ARRAY OF CHAR): SIZE;
VAR value, index: SIZE;
BEGIN
	value := 0; index := 0;
	WHILE name[index] # 0X DO
		value := (value * 31 + ORD(name[index])) MOD DeclarationTableSize; INC(index)
	END;
	RETURN value
END HashName;

PROCEDURE ClearDeclarations;
VAR index: SIZE;
BEGIN FOR index := 0 TO DeclarationTableSize-1 DO declarations[index] := NIL END
END ClearDeclarations;

(* The last case before this point that declared the module, NIL when nothing did. *)
PROCEDURE DeclaredBy(CONST name: ARRAY OF CHAR): TestCase;
VAR entry: Declaration;
BEGIN
	entry := declarations[HashName(name)];
	WHILE entry # NIL DO
		IF entry.name = name THEN RETURN entry.case END;
		entry := entry.next
	END;
	RETURN NIL
END DeclaredBy;

PROCEDURE Declare(CONST name: ARRAY OF CHAR; case: TestCase);
VAR entry: Declaration; slot: SIZE;
BEGIN
	slot := HashName(name); entry := declarations[slot];
	WHILE entry # NIL DO
		IF entry.name = name THEN entry.case := case; RETURN END;
		entry := entry.next
	END;
	NEW(entry); COPY(name, entry.name); entry.case := case;
	entry.next := declarations[slot]; declarations[slot] := entry
END Declare;

PROCEDURE DeclaresItself(case: TestCase; CONST name: ARRAY OF CHAR): BOOLEAN;
VAR index: SIZE;
BEGIN
	FOR index := 0 TO case.count-1 DO
		IF case.modules[index]^ = name THEN RETURN TRUE END
	END;
	RETURN FALSE
END DeclaresItself;

(* Add a case to a list kept in the order the cases are in the file. FALSE when it was already
   there, which is what stops the closure below from going round for ever. *)
PROCEDURE AddLink(VAR list: CaseLink; case: TestCase): BOOLEAN;
VAR entry, item: CaseLink;
BEGIN
	IF (list = NIL) OR (list.case.index > case.index) THEN
		NEW(entry); entry.case := case; entry.next := list; list := entry; RETURN TRUE
	END;
	item := list;
	WHILE (item.next # NIL) & (item.next.case.index <= case.index) DO item := item.next END;
	IF item.case = case THEN RETURN FALSE END;
	NEW(entry); entry.case := case; entry.next := item.next; item.next := entry;
	RETURN TRUE
END AddLink;

(* Which earlier case of this file declares what each case imports. *)
PROCEDURE FindDependencies(cases: TestCase);
VAR case, provider: TestCase; index: SIZE; ignore: BOOLEAN;
BEGIN
	ClearDeclarations;
	case := cases;
	WHILE case # NIL DO
		case.needs := NIL;
		FOR index := 0 TO case.importCount-1 DO
			IF ~DeclaresItself(case, case.imports[index]^) THEN
				provider := DeclaredBy(case.imports[index]^);
				IF provider # NIL THEN ignore := AddLink(case.needs, provider) END
			END
		END;
		FOR index := 0 TO case.count-1 DO Declare(case.modules[index]^, case) END;
		case := case.next
	END;
	ClearDeclarations
END FindDependencies;

(* The cases before this chunk that it cannot do without, transitively and in file order. A case the
   -r filter drops is not replayed: the sequential run would not have run it either. *)
PROCEDURE PlanReplay(first: TestCase; count, start: SIZE): CaseLink;
VAR list, item: CaseLink; case: TestCase; need: CaseLink; index: SIZE; added: BOOLEAN;

	PROCEDURE Want(case: TestCase);
	BEGIN
		IF (case.index < start) & CaseSelected(case.name) & AddLink(list, case) THEN added := TRUE END
	END Want;

BEGIN
	list := NIL; case := first;
	FOR index := 0 TO count-1 DO
		need := case.needs;
		WHILE need # NIL DO Want(need.case); need := need.next END;
		case := case.next
	END;
	(* A replayed case may itself need an earlier one, and that one is inserted before it -- so the
	   list is walked again until a pass adds nothing. It is a handful of cases; this is not a cost. *)
	REPEAT
		added := FALSE; item := list;
		WHILE item # NIL DO
			need := item.case.needs;
			WHILE need # NIL DO Want(need.case); need := need.next END;
			item := item.next
		END
	UNTIL ~added;
	RETURN list
END PlanReplay;

(*
	Plan one file: its cases, cut into chunks of at most `size`, each with what it has to replay.
	A file that is skipped whole still gets a chunk, so that the run says so in the right place.
*)
PROCEDURE PlanFile(CONST file: ARRAY OF CHAR; pieces: SIZE; VAR list, last: Chunk; VAR total: SIZE);
CONST Smallest = 32;			(* below this a chunk is all overhead: a directory to fill, cases to replay *)
VAR cases, case: TestCase; count, size, taken: SIZE; execute, header: BOOLEAN;
	message, name: Path; chunk: Chunk;

	PROCEDURE Add(first: TestCase; count: SIZE): Chunk;
	VAR piece: Chunk;
	BEGIN
		NEW(piece); piece.next := NIL; COPY(name, piece.name); piece.header := header;
		COPY(message, piece.message); piece.execute := execute;
		piece.first := first; piece.count := count; piece.replay := NIL;
		piece.index := total; INC(total);
		header := FALSE; message := "";
		IF list = NIL THEN list := piece ELSE last.next := piece END;
		last := piece;
		RETURN piece
	END Add;

BEGIN
	BaseName(file, name); header := TRUE; message := "";
	IF ~ParseTestFile(file, cases, count, execute, message) THEN
		(* Skipped whole, or not there at all -- either way the file is still announced, and the
		   reason with it. *)
		chunk := Add(NIL, 0); RETURN
	END;
	size := (count + pieces - 1) DIV pieces;
	IF size < Smallest THEN size := Smallest END;
	IF size < count THEN FindDependencies(cases) END;
	case := cases;
	WHILE case # NIL DO
		taken := 0;
		chunk := Add(case, 0);
		WHILE (case # NIL) & (taken < size) DO case := case.next; INC(taken) END;
		chunk.count := taken;
		IF chunk.first.index > 0 THEN
			chunk.replay := PlanReplay(chunk.first, taken, chunk.first.index)
		END
	END
END PlanFile;

(* --- running them ------------------------------------------------------------------------ *)

PROCEDURE SpawnCase(job: Job; run: BOOLEAN): ADDRESS;
VAR arguments: Strings.StringArray;
BEGIN
	NEW(arguments, 6);
	arguments[0] := Strings.NewString("ob");
	arguments[1] := Strings.NewString("test-case");
	arguments[2] := Strings.NewString(job.scratch);
	arguments[3] := Strings.NewString(job.current.entry);
	IF run THEN arguments[4] := Strings.NewString("run")
	ELSE arguments[4] := Strings.NewString("compile")
	END;
	(* The target, so that the child compiles for it and knows whether it may load what it built.
	   Everything else about running for another architecture the child resolves for itself. *)
	arguments[5] := Strings.NewString(testTarget);
	RETURN ObHost.Spawn(testSelf, arguments)
END SpawnCase;

PROCEDURE StartCase(job: Job; run: BOOLEAN): BOOLEAN;
BEGIN
	job.process := SpawnCase(job, run); job.spawnFault := ObHost.spawnError;
	IF job.process = 0 THEN RETURN FALSE END;
	Kernel.SetTimer(job.deadline, caseLimit);
	RETURN TRUE
END StartCase;

(* Finished with this chunk: what it said and what it recorded are kept as one block, to be printed
   when every chunk before it has been. *)
PROCEDURE FinishChunk(job: Job);
VAR block: Block;
BEGIN
	NEW(block); block.records := job.records; block.text := NIL;
	IF job.buffered THEN job.writer.Update; block.text := job.buffer.GetString() END;
	blocks[job.chunk.index] := block;
	job.busy := FALSE; job.current := NIL; job.pending := NIL; job.remaining := 0;
	job.records := NIL; job.lastRecord := NIL
END FinishChunk;

(* Start the next case of this job's chunk -- replaying the ones it depends on first -- or end the
   chunk when there is none left. *)
PROCEDURE Advance(job: Job);
VAR line: Path; started: BOOLEAN;
BEGIN
	LOOP
		IF job.replay # NIL THEN
			job.current := job.replay.case; job.replay := job.replay.next; job.replaying := TRUE;
			(* Compiled, never run: all this case is here for is what it leaves in the directory.
			   Nothing is reported and nothing is counted -- it was judged where it belongs. *)
			IF (job.current.count > 0) & WriteCase(job, job.current) & StartCase(job, FALSE) THEN
				RETURN
			END
		ELSIF job.remaining > 0 THEN
			job.replaying := FALSE;
			job.current := job.pending; job.pending := job.pending.next; DEC(job.remaining);
			started := FALSE;
			IF ~CaseSelected(job.current.name) THEN				(* -r dropped it *)
			ELSIF job.current.count = 0 THEN
				line := "  SKIP  "; Strings.Append(line, job.current.name);
				Strings.Append(line, " (no MODULE in case)"); Tell(job, line);
				RecordCase(job, "skipped", job.current.kind, job.current.name)
			ELSIF WriteCase(job, job.current) THEN
				INC(totalCases);
				(* A file descriptor is released when the File that held it is collected, and a run
				   of six thousand cases would otherwise reach the limit long before the collector
				   had a reason to run. Every so often, give it one. *)
				INC(sinceCollection);
				IF sinceCollection >= 200 THEN Kernel.GC; sinceCollection := 0 END;
				started := StartCase(job, job.chunk.execute);
				IF ~started THEN
					Verdict(job, FALSE, 0)			(* it never started, which is not the case failing *)
				END
			END;
			IF started THEN RETURN END
		ELSE
			EXIT
		END
	END;
	FinishChunk(job)
END Advance;

(* One step of a job that holds a chunk: TRUE when the case in flight settled and the next one
   started, FALSE when it is still running and the parent has nothing to do here. *)
PROCEDURE StepJob(job: Job): BOOLEAN;
VAR exitCode: SIGNED32; done: BOOLEAN;
BEGIN
	IF job.process = 0 THEN RETURN FALSE END;
	done := ObHost.Finished(job.process, exitCode);
	IF ~done THEN
		IF ~Kernel.Expired(job.deadline) THEN RETURN FALSE END;
		ObHost.Terminate(job.process); exitCode := 0
	END;
	job.process := 0;
	IF ~job.replaying THEN Verdict(job, done, exitCode) END;
	Advance(job);
	RETURN TRUE
END StepJob;

(* Empty a job's directory and put back what every chunk starts from. The image is left where it is:
   nothing writes to it, and it is the one file here big enough for copying it per chunk to show. *)
PROCEDURE ResetScratch(job: Job): BOOLEAN;
VAR handle: ADDRESS; name, path: Path; ignore: BOOLEAN;
BEGIN
	handle := ObHost.OpenDirectory(job.scratch);
	IF handle # 0 THEN
		WHILE ObHost.NextEntry(handle, name) DO
			IF (name # ".") & (name # "..") & (name # seedKeep) THEN
				Join(job.scratch, name, path); ignore := ObHost.Remove(path)
			END
		END;
		ObHost.CloseDirectory(handle)
	END;
	RETURN SeedScratch(testScratch, job.scratch)
END ResetScratch;

PROCEDURE TakeChunk(job: Job; chunk: Chunk);
VAR line: Path;
BEGIN
	job.busy := TRUE; job.chunk := chunk;
	job.records := NIL; job.lastRecord := NIL; job.process := 0; job.spawnFault := 0;
	IF job.buffered THEN
		NEW(job.buffer, 4096); job.writer := job.buffer.GetWriter();
		IF ~ResetScratch(job) THEN DieOn("cannot prepare a job directory: ", job.scratch) END
	END;
	IF chunk.header THEN line := "=== "; Strings.Append(line, chunk.name); Tell(job, line) END;
	IF chunk.message # "" THEN Tell(job, chunk.message) END;
	job.replay := chunk.replay; job.pending := chunk.first; job.remaining := chunk.count;
	Advance(job)
END TakeChunk;

(*
	The run itself. One chunk per job in flight, each stepped in turn; a job with nothing to report
	costs a poll, and when no job moved at all the parent sleeps rather than spinning a core that a
	case could be using. Chunks are printed in the order they were planned, however they finish.
*)
PROCEDURE RunChunks(chunks: Chunk; count: SIZE; jobs: SIGNED32);
VAR pool: POINTER TO ARRAY OF Job; job: Job; block: Block; timer: Kernel.Timer; image: Path;
	printed: SIZE; index, tick: SIGNED32; moved: BOOLEAN;
BEGIN
	(* How long the parent sleeps when no job moved. One job waits on one case, as it always did;
	   with several, this is the latency between a case ending and the next one starting, once per
	   case and on every job -- 20ms of it is a core's worth of the run. *)
	IF jobs > 1 THEN tick := 5 ELSE tick := 20 END;
	NEW(blocks, count);
	seedKeep := "";
	IF testEmulator # "" THEN EmulatorImage(testScratch, image); BaseName(image, seedKeep) END;
	NEW(pool, jobs);
	FOR index := 0 TO jobs-1 DO
		NEW(job); job.busy := FALSE; job.buffered := jobs > 1;
		COPY(testScratch, job.scratch);
		IF job.buffered THEN
			(* A directory of its own, beside the prepared one rather than inside it, and seeded
			   from it: the siblings compiled for the cases to import, and the image cases are
			   executed in when they are not this machine's code. *)
			Strings.Append(job.scratch, "-j"); Strings.AppendInt(job.scratch, index);
			IF ~MakePath(job.scratch) THEN
				DieOn("cannot make a job directory: ", job.scratch); RETURN
			END
		ELSE
			job.writer := out
		END;
		pool[index] := job
	END;

	NEW(timer); printed := 0;
	WHILE printed < count DO
		moved := FALSE;
		FOR index := 0 TO jobs-1 DO
			job := pool[index];
			IF ~job.busy & (chunks # NIL) THEN
				TakeChunk(job, chunks); chunks := chunks.next; moved := TRUE
			END;
			IF StepJob(job) THEN moved := TRUE END
		END;
		WHILE (printed < count) & (blocks[printed] # NIL) DO
			block := blocks[printed]; blocks[printed] := NIL; INC(printed);
			IF block.text # NIL THEN out.String(block.text^); out.Update END;
			IF block.records # NIL THEN
				IF caseRecords = NIL THEN caseRecords := block.records
				ELSE lastCaseRecord.next := block.records
				END;
				lastCaseRecord := block.records;
				WHILE lastCaseRecord.next # NIL DO lastCaseRecord := lastCaseRecord.next END
			END;
			moved := TRUE
		END;
		IF ~moved THEN timer.Sleep(tick) END
	END;
	IF jobs > 1 THEN
		FOR index := 0 TO jobs-1 DO DiscardScratch(pool[index].scratch) END
	END
END RunChunks;

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
	count, index: SIZE; line: Path;
BEGIN
	count := CountKeys(newFailures);
	NEW(sorted, count + 1); index := 0; entry := newFailures;
	WHILE entry # NIL DO sorted[index] := Strings.NewString(entry.text); INC(index); entry := entry.next END;
	SortNames(sorted, count);
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

(*
	A case built for another architecture, run in the emulator on the image the parent linked.

	The verdict cannot be an exit code here: the A2 runtime exits 0 whatever happened, so what is
	read is what it said, exactly as the shell version had to. A bare `Trap` line is not a failure
	-- cases trap on purpose and the runtime carries on -- but "Could not load module", an `error:`
	or a missing "<entry> loaded." are.

	The emulator's output goes to the same case.log as everything else, appended after what has
	already been written to it, so a failing case reads as one story.
*)
PROCEDURE RunInEmulator(CONST scratch, entry: ARRAY OF CHAR): BOOLEAN;
VAR arguments: Strings.StringArray; command, image, sysroot, marker, log: Path;
	handle: Files.File; reader: Files.Reader; line: ARRAY 1024 OF CHAR;
	exitCode: SIGNED32; finished, loaded, bad, ignore: BOOLEAN;
BEGIN
	EmulatorImage(scratch, image);
	IF ~ObHost.Exists(image) THEN RETURN FALSE END;
	IF ~FindEmulator(command) OR ~FindSysroot(sysroot) THEN RETURN FALSE END;
	(* A file of its own, and not the case log this process is already writing: a Files.File that
	   this process created holds the length it had when it was registered, so a second process
	   appending to it is read back as nothing at all -- intermittently, which is worse. What the
	   emulator writes is copied into the case log afterwards, so a failing case still reads as one
	   story. *)
	Join(scratch, "case-run.log", log);
	(* Removed first, and this is not tidiness. The scratch directory is shared by every case of the
	   run, and the redirection below appends: what the previous case's emulator said would be read
	   back as this one's, so a single `error:` anywhere early would fail every case after it. The
	   shell version was safe from this by writing the file with `>`. *)
	ignore := ObHost.Remove(log);

	(* Both directories have to be named. What a process was started in is not on its search path
	   by itself, and the standard library for this target is not in the image: the image holds the
	   boot set, and everything the case imports beyond it is loaded from lib-a64 at run time --
	   which is the same thing that happens on a real AArch64 machine. *)
	line := "Files.AddSearchPath "; Strings.Append(line, testLibrary);
	Strings.Append(line, "~ Files.AddSearchPath "); Strings.Append(line, scratch);
	Strings.Append(line, "~ System.Load "); Strings.Append(line, entry); Strings.Append(line, " ~");

	NEW(arguments, 6);
	arguments[0] := Strings.NewString("qemu");
	arguments[1] := Strings.NewString("-L");
	arguments[2] := Strings.NewString(sysroot);
	arguments[3] := Strings.NewString(image);
	arguments[4] := Strings.NewString("do");
	arguments[5] := Strings.NewString(line);

	(* From here on this process writes to the log file rather than to a terminal, which is what
	   lets the emulator -- which knows nothing of A2 -- be captured at all. *)
	IF ~ObHost.Redirect(log) THEN
		error.String("this host cannot capture an emulator's output"); error.Char(0AX);
		RETURN FALSE
	END;
	finished := RunProgram(command, arguments, caseLimit, exitCode);
	IF ~finished THEN RETURN FALSE END;

	loaded := FALSE; bad := exitCode # 0;
	COPY(entry, marker); Strings.Append(marker, " loaded.");
	handle := Files.Old(log);
	IF handle = NIL THEN RETURN FALSE END;
	Files.OpenReader(reader, handle, 0);
	WHILE reader.res = Streams.Ok DO
		reader.Ln(line); Strings.Trim(line, 0DX);
		error.String(line); error.Char(0AX);		(* into the case log, for the parent to show *)
		IF (Strings.Pos("error:", line) >= 0) OR (Strings.Pos("Could not load module", line) >= 0)
				OR (Strings.Pos("not successful", line) >= 0) THEN
			bad := TRUE
		END;
		IF Strings.Pos(marker, line) >= 0 THEN loaded := TRUE END
	END;
	handle.Close;
	RETURN loaded & ~bad
END RunInEmulator;

(* Not a verb for people: one case, compiled and loaded in a process of its own, answering with
   its exit code. Everything it says goes to case.log in the scratch directory. *)
PROCEDURE TestCaseVerb;
VAR scratch, entry, mode, target, path: Path; handle: Files.File; writer: Files.Writer;
	source: Path; module: Modules.Module; result: INTEGER; message: ARRAY 256 OF CHAR;
	compiled: BOOLEAN;
BEGIN
	IF ~NextArgument(scratch) OR ~NextArgument(entry) OR ~NextArgument(mode) THEN
		Die("test-case is internal: ob test-case <scratch> <Entry> run|compile [target]"); RETURN
	END;
	IF ~NextArgument(target) THEN COPY(HostTarget, target) END;
	IF ~TestTargetSettings(target) THEN RETURN END;
	ReadCaseLimit;

	Join(scratch, "case.log", path);
	handle := Files.New(path);
	IF handle # NIL THEN Files.OpenWriter(writer, handle, 0); error := writer END;

	(* lib is on the path even when the case is built for another architecture: the backend and the
	   front end are loaded by name when the compiler runs, and what runs here is this machine's
	   code whatever is being compiled. The two libraries cannot be confused for each other -- a
	   target is its object and symbol file extensions. *)
	IF ~AddSearchPath(lib) OR ~AddSearchPath(testLibrary) OR ~AddSearchPath(project)
			OR ~AddSearchPath(scratch) OR ~SetWorkPath(scratch) THEN
		failed := TRUE
	ELSE
		Join(scratch, "TesterInput.txt", source);
		CaptureTrace;
		compiled := CompileFile(source, testPlatform, testObject, testSymbol, TRUE);
		IF compiled & (mode = "run") & (target = HostTarget) THEN
			module := Modules.ThisModule(entry, result, message);
			IF module = NIL THEN
				error.String("could not load module "); error.String(entry);
				error.String(": "); error.String(message); error.Char(0AX);
				compiled := FALSE
			END
		END;
		RestoreTrace;
		WriteTraced(error);
		IF compiled & (mode = "run") & (target # HostTarget) THEN
			compiled := RunInEmulator(scratch, entry)
		END;
		IF ~compiled THEN failed := TRUE END
	END;
	IF handle # NIL THEN error.Update; Files.Register(handle) END
END TestCaseVerb;

PROCEDURE TestVerb;
CONST MaxJobs = 64;
VAR argument, target, expect, write, entry, path, line: Path;
	files: Strings.StringArray; count, index, chunkCount: SIZE; handle: ADDRESS; jobs: SIGNED32;
	chunks, lastChunk: Chunk;
BEGIN
	testVerbose := FALSE; testFilter := ""; testReport := ""; expect := ""; write := "";
	COPY(HostTarget, target); jobs := 1;
	testGithub := ObHost.Env("GITHUB_ACTIONS", line) & (line = "true");
	NEW(files, 256); count := 0;
	WHILE NextArgument(argument) DO
		IF (argument = "-v") OR (argument = "--verbose") THEN testVerbose := TRUE
		ELSIF (argument = "-j") OR (argument = "--jobs") THEN
			IF ~NextArgument(line) THEN Die("-j needs a number of files to run at a time"); RETURN END;
			jobs := ToInteger(line, 0);
			IF (jobs < 1) OR (jobs > MaxJobs) THEN DieOn("-j takes 1 to 64: ", line); RETURN END
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

	IF ~TestTargetSettings(target) THEN RETURN END;

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
		IF count = 0 THEN Die("no *.Test files here (usage: ob test [File.Test ...])"); RETURN END;
		SortNames(files, count)
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
	IF ObHost.Exists(path) THEN LoadBaseline(path, expect) ELSE baseline := NIL END;

	ReadCaseLimit;
	IF ~ObHost.ExecutablePath(testSelf) THEN Die("cannot find my own binary"); RETURN END;
	IF ~ScratchDirectory(testScratch) THEN Die("cannot create a scratch directory"); RETURN END;
	IF AddSearchPath(lib) & AddSearchPath(testLibrary) & AddSearchPath(project)
			& AddSearchPath(testScratch) & SetWorkPath(testScratch) THEN
		BuildSiblings(testScratch, testPlatform, testObject, testSymbol)
	END;
	(* Only now, because the image is linked into the scratch directory. *)
	PrepareEmulator;

	(*
		How finely the case lists are cut. One piece per file leaves the run as long as its longest
		file -- and 5450 of this tree's 6965 cases are in one -- so with jobs to fill there are
		several pieces per job: the tail of the run is then one chunk long rather than one file.
	*)
	chunks := NIL; lastChunk := NIL; chunkCount := 0;
	FOR index := 0 TO count-1 DO
		PlanFile(files[index]^, SIZE(4 * jobs), chunks, lastChunk, chunkCount)
	END;
	IF jobs > 1 THEN
		line := "ob test: "; Strings.AppendInt(line, jobs);
		Strings.Append(line, " at a time, in "); Strings.AppendInt(line, SIGNED32(chunkCount));
		Strings.Append(line, " piece(s); each piece is printed when it ends");
		Say(line)
	END;

	totalCases := 0; sinceCollection := 0; passedCases := 0; failedCases := 0; knownCases := 0; fixedCases := 0;
	newFailures := NIL; caseRecords := NIL; lastCaseRecord := NIL;
	RunChunks(chunks, chunkCount, jobs);
	DiscardScratch(testScratch);

	Say("");
	line := "ob test: "; Strings.AppendInt(line, totalCases); Strings.Append(line, " case(s), ");
	Strings.AppendInt(line, passedCases); Strings.Append(line, " passed, ");
	Strings.AppendInt(line, failedCases); Strings.Append(line, " failed, ");
	Strings.AppendInt(line, knownCases); Strings.Append(line, " known-failing, ");
	Strings.AppendInt(line, fixedCases); Strings.Append(line, " fixed"); Say(line);

	(* Relative to the project, which is where the baseline lives and where CI expects the report --
	   unless it was given as an absolute path, which used to be appended to the project directory
	   and produced a name no file system would take. *)
	IF write # "" THEN Absolute(project, write, path); WriteExpected(path); RETURN END;
	IF testReport # "" THEN Absolute(project, testReport, path); WriteReport(path) END;
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
	Say("  ob test [File.Test ...] [-v] [-j N] run test files (default: every *.Test here)");
	Say("  ob doc [File.Mod] [-o dir]         generate HTML API docs (index + per-module)");
	Say("  ob lint                            check every import points at its tier or lower");
	Say("  ob lsp [--live]                    the Active Oberon language server, over stdio");
	Say("  ob repl                            the interactive A2 shell, in this directory");
	Say("  ob version                         print the SDK version banner");
	Say("  ob help                            this text");
	Say("");
	Say("ob test -j N runs N test files at a time; -t names another architecture.")
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
