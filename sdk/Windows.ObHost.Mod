MODULE ObHost;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Host services Ob needs and portable A2 does not offer: real argv, environment, resolved paths"; *)

(*
	The Windows half of the platform layer under Ob, answering the same questions as the Unix one
	in Unix.ObHost.Mod. It is longer for one reason: Windows hands a program its command line as a
	single string and leaves the splitting to it, so the argument vector is built here, once, by
	the rules the C runtime uses -- a quote opens and closes a field, a backslash escapes a quote
	only when it precedes one, and "" inside a quoted field is a quote.

	Everything else is the same call under another name. Paths keep the separator the caller used:
	Windows accepts a forward slash everywhere, and ob builds its paths with one.
*)

IMPORT SYSTEM, Kernel32, Strings, WinFS;

CONST
	MaxPath* = 1024;
	Separator* = '\';

	InvalidAttributes = -1;			(* what GetFileAttributes answers for a name that is not there *)
	DirectoryAttribute = 10H;		(* FILE_ATTRIBUTE_DIRECTORY *)
	WaitTimeout = 102H;				(* WAIT_TIMEOUT *)
	StillActive = 103H;				(* STILL_ACTIVE, the exit code of a process that has not exited *)

TYPE
	Path* = ARRAY MaxPath OF CHAR;

	Directory = POINTER TO RECORD
		handle: Kernel32.HANDLE;
		data: Kernel32.FindData;
		first: BOOLEAN
	END;

VAR
	arguments: Strings.StringArray;
	count: SIZE;
	(* Why the last Spawn failed, 0 when it did not -- GetLastError here, the code posix_spawnp
	   returns on the Unix side. Same question, different numbers. *)
	spawnError-: SIGNED32;

(* --- the command line, split the way a C runtime splits it -------------------------------- *)

PROCEDURE SplitCommandLine;
VAR line: ARRAY 32*1024 OF CHAR; field: Path; address: Kernel32.LPSTR;
	position, length, backslashes, index: SIZE; quoted, done: BOOLEAN; character: CHAR;

	PROCEDURE Emit;
	BEGIN
		field[length] := 0X;
		IF count < LEN(arguments^) THEN arguments[count] := Strings.NewString(field); INC(count) END;
		length := 0
	END Emit;

	PROCEDURE Backslashes(runs: SIZE; escaped: BOOLEAN);
	VAR pairs, rest: SIZE;
	BEGIN
		(* a run of backslashes escapes a quote only when it stands directly before one, and then
		   only in pairs; otherwise every backslash is a backslash *)
		IF escaped THEN pairs := runs DIV 2; rest := runs MOD 2 ELSE pairs := runs; rest := 0 END;
		WHILE pairs > 0 DO field[length] := '\'; INC(length); DEC(pairs) END;
		IF rest > 0 THEN field[length] := '"'; INC(length) END
	END Backslashes;

BEGIN
	NEW(arguments, 256); count := 0;
	address := Kernel32.GetCommandLine();
	position := 0;
	IF address # 0 THEN
		REPEAT
			SYSTEM.GET(address + position, character); line[position] := character; INC(position)
		UNTIL (character = 0X) OR (position = LEN(line) - 1)
	END;
	line[position] := 0X;

	position := 0; length := 0; quoted := FALSE; done := FALSE;
	WHILE ~done DO
		character := line[position];
		IF character = 0X THEN
			IF length > 0 THEN Emit END;
			done := TRUE
		ELSIF (character = ' ') & ~quoted THEN
			IF length > 0 THEN Emit END;
			INC(position)
		ELSIF character = '\' THEN
			backslashes := 0;
			WHILE line[position] = '\' DO INC(backslashes); INC(position) END;
			IF line[position] = '"' THEN
				Backslashes(backslashes, TRUE);
				IF backslashes MOD 2 = 0 THEN quoted := ~quoted END;
				INC(position)
			ELSE
				Backslashes(backslashes, FALSE)
			END
		ELSIF character = '"' THEN
			IF quoted & (line[position+1] = '"') THEN
				field[length] := '"'; INC(length); INC(position, 2)
			ELSE
				quoted := ~quoted; INC(position)
			END
		ELSE
			IF length < LEN(field) - 1 THEN field[length] := character; INC(length) END;
			INC(position)
		END
	END;
	IF count = 0 THEN arguments[0] := Strings.NewString("ob"); count := 1 END;
	index := count		(* keeps the compiler from warning about an unused loop variable *)
END SplitCommandLine;

(** Number of command-line arguments, including argv[0]. *)
PROCEDURE ArgCount*(): SIGNED32;
BEGIN
	RETURN SIGNED32(count)
END ArgCount;

(** Argument no, verbatim -- spaces and quotes included. Empty when no is out of range. *)
PROCEDURE Arg*(no: SIGNED32; VAR value: ARRAY OF CHAR);
BEGIN
	IF (no < 0) OR (no >= count) THEN value := "" ELSE COPY(arguments[no]^, value) END
END Arg;

(** An environment variable, FALSE when it is not set. *)
PROCEDURE Env*(CONST name: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
VAR buffer: Path; length: SIGNED32;
BEGIN
	length := Kernel32.GetEnvironmentVariable(name, buffer, LEN(buffer));
	IF (length <= 0) OR (length >= LEN(buffer)) THEN value := ""; RETURN FALSE END;
	COPY(buffer, value); RETURN TRUE
END Env;

(** An absolute path. Windows has no realpath; GetFullPathName is what there is, and it does not
	resolve a link -- which costs nothing here, because the one caller that needs a link followed
	is ExecutablePath, and GetModuleFileName answers that directly. *)
(*	A path as the file system will take it. The forward slash is normalised away first: it is what
	a user types and what every document here writes, `GetFileAttributes` accepts it, and under wine
	`GetFullPathName` hands it back untouched -- so the name resolved fine, existed fine, and then
	could not be opened, which read as "no MODULE header in examples/Hello.Mod" about a file whose
	first word is MODULE. *)
(*
	Is the name anchored -- a drive, a UNC share, or a root -- or is it relative to wherever the
	process happens to be standing?
*)
PROCEDURE Absolute(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF (path[0] = 0X) THEN RETURN FALSE END;
	IF (path[0] = Separator) OR (path[0] = '/') THEN RETURN TRUE END;
	RETURN (path[1] = ':') & (path[2] # 0X)
END Absolute;

(*
	What the user typed, resolved against the directory they typed it in.

	Windows resolves a relative name against the process's current directory, and A2 moves that:
	the work path IS the current directory there (Windows.WinFS.SetPaths), and ob sets the work
	path to its own scratch directory before it compiles. So by the time a verb looks at its
	argument, `Foo.Mod` no longer means the Foo.Mod the user was looking at. WinFS keeps the
	directory the process started in for exactly this, and on Unix the question never arises
	because nothing there ever calls chdir.
*)
PROCEDURE Anchor(CONST path: ARRAY OF CHAR; VAR anchored: ARRAY OF CHAR);
VAR start: Path; length: SIZE;
BEGIN
	COPY(path, anchored);
	IF Absolute(path) THEN RETURN END;
	(*	$A2_PROJECT first, by the same rule Ob.FindProject follows, and for the same reason it is
		needed at all: a shell can hand a program a working directory that is not the one it is
		showing the user -- Windows PowerShell changes its own location without changing the
		process's -- and then the only truth about where the user stands is what the shell says
		out loud. *)
	IF Env("A2_PROJECT", start) & (start # "") THEN
	ELSE WinFS.StartPath(start)
	END;
	IF start = "" THEN RETURN END;
	length := 0; WHILE start[length] # 0X DO INC(length) END;
	IF (length > 0) & (start[length-1] # Separator) & (start[length-1] # '/') THEN
		Strings.Append(start, Separator)
	END;
	Strings.Append(start, path);
	COPY(start, anchored)
END Anchor;

PROCEDURE RealPath*(CONST path: ARRAY OF CHAR; VAR resolved: ARRAY OF CHAR): BOOLEAN;
VAR buffer, native: Path; index: SIZE;
BEGIN
	Anchor(path, native); index := 0;
	WHILE native[index] # 0X DO
		IF native[index] = '/' THEN native[index] := Separator END;
		INC(index)
	END;
	IF ~Exists(native) THEN resolved := ""; RETURN FALSE END;
	IF Kernel32.GetFullPathName(native, LEN(buffer), buffer, 0) = 0 THEN resolved := ""; RETURN FALSE END;
	COPY(buffer, resolved); RETURN TRUE
END RealPath;

(** Where this very binary sits. *)
PROCEDURE ExecutablePath*(VAR path: ARRAY OF CHAR): BOOLEAN;
VAR buffer: Path;
BEGIN
	IF Kernel32.GetModuleFileName(0, buffer, LEN(buffer)) = 0 THEN path := ""; RETURN FALSE END;
	COPY(buffer, path); RETURN TRUE
END ExecutablePath;

(**
	The directory the user is in -- which is the one this process was started in, not the one it
	has walked to since. Ob asks this to decide where the project is, and a process whose current
	directory is its own scratch directory has no project. Falls back to Windows' answer when the
	file system never recorded a start (nothing ran SetPaths).
*)
PROCEDURE CurrentDirectory*(VAR path: ARRAY OF CHAR): BOOLEAN;
VAR buffer: Path;
BEGIN
	WinFS.StartPath(buffer);
	IF buffer # "" THEN COPY(buffer, path); RETURN TRUE END;
	IF Kernel32.GetCurrentDirectory(LEN(buffer), buffer) = 0 THEN path := ""; RETURN FALSE END;
	COPY(buffer, path); RETURN TRUE
END CurrentDirectory;

(** Does the name exist at all -- file, directory or anything else. *)
PROCEDURE Exists*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN SYSTEM.VAL(SIGNED32, Kernel32.GetFileAttributes(path)) # InvalidAttributes
END Exists;

(** Is the name executable. Windows decides that by extension rather than by a permission bit,
	so anything that exists and is not a directory is as good an answer as there is. *)
PROCEDURE Executable*(CONST path: ARRAY OF CHAR): BOOLEAN;
VAR attributes: SIGNED32;
BEGIN
	attributes := SYSTEM.VAL(SIGNED32, Kernel32.GetFileAttributes(path));
	IF attributes = InvalidAttributes THEN RETURN FALSE END;
	RETURN attributes DIV DirectoryAttribute MOD 2 = 0
END Executable;

(** Copy a file byte for byte, by OS path. The Unix half explains why this is not Files' job. *)
PROCEDURE CopyFile*(CONST from, to: ARRAY OF CHAR): BOOLEAN;
VAR source, target: ARRAY MaxPath OF CHAR;
BEGIN
	COPY(from, source); COPY(to, target);		(* Kernel32 takes them as VAR, so it gets copies *)
	RETURN Kernel32.CopyFile(source, target, 0) # 0
END CopyFile;

(** TRUE when this system will not start a plain A2 image. Windows runs what the linker wrote. *)
PROCEDURE ImageNeedsLoader*(): BOOLEAN;
BEGIN
	RETURN FALSE
END ImageNeedsLoader;

(** Nothing to do: a Windows file is executable because of its name. *)
PROCEDURE MakeExecutable*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN Exists(path)
END MakeExecutable;

PROCEDURE MakeDirectory*(CONST path: ARRAY OF CHAR): BOOLEAN;
VAR name: Path;
BEGIN
	COPY(path, name);
	IF Kernel32.CreateDirectory(name, NIL) # 0 THEN RETURN TRUE END;
	RETURN Exists(path)
END MakeDirectory;

PROCEDURE Remove*(CONST path: ARRAY OF CHAR): BOOLEAN;
VAR name: Path;
BEGIN
	COPY(path, name);
	RETURN Kernel32.DeleteFile(name) # 0
END Remove;

PROCEDURE RemoveDirectory*(CONST path: ARRAY OF CHAR): BOOLEAN;
VAR name: Path;
BEGIN
	COPY(path, name);
	RETURN Kernel32.RemoveDirectory(name) # 0
END RemoveDirectory;

(* --- directories -------------------------------------------------------------------------- *)

(** Open a directory for listing. 0 when it cannot be listed, as on Unix. *)
PROCEDURE OpenDirectory*(CONST path: ARRAY OF CHAR): ADDRESS;
VAR directory: Directory; mask: Path;
BEGIN
	IF ~Exists(path) OR Executable(path) THEN RETURN 0 END;		(* a file, not a directory *)
	COPY(path, mask); Strings.Append(mask, "\*");
	NEW(directory);
	directory.handle := Kernel32.FindFirstFile(mask, directory.data);
	IF directory.handle = Kernel32.InvalidHandleValue THEN RETURN 0 END;
	directory.first := TRUE;
	RETURN SYSTEM.VAL(ADDRESS, directory)
END OpenDirectory;

(** The next name in the directory, "." and ".." included. FALSE at the end. *)
PROCEDURE NextEntry*(handle: ADDRESS; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR directory: Directory;
BEGIN
	IF handle = 0 THEN name := ""; RETURN FALSE END;
	directory := SYSTEM.VAL(Directory, handle);
	IF directory.first THEN directory.first := FALSE
	ELSIF Kernel32.FindNextFile(directory.handle, directory.data) = 0 THEN name := ""; RETURN FALSE
	END;
	COPY(directory.data.cFileName, name);
	RETURN TRUE
END NextEntry;

PROCEDURE CloseDirectory*(handle: ADDRESS);
VAR directory: Directory; ignore: Kernel32.BOOL;
BEGIN
	IF handle = 0 THEN RETURN END;
	directory := SYSTEM.VAL(Directory, handle);
	ignore := Kernel32.FindClose(directory.handle)
END CloseDirectory;

(*
	Writing a file without going through Files, for the reason given in the Unix half: a Files.File
	holds its handle until the collector finalises it, and `ob test` writes one file per case.
*)
PROCEDURE WriteFile*(CONST path, contents: ARRAY OF CHAR): BOOLEAN;
VAR file: Kernel32.HANDLE; length, written: SIGNED32; overlapped: Kernel32.Overlapped;
	ignore: Kernel32.BOOL;
BEGIN
	file := Kernel32.CreateFile(path, {Kernel32.GenericWrite}, {}, NIL,
			Kernel32.CreateAlways, {}, 0);
	IF file = Kernel32.InvalidHandleValue THEN RETURN FALSE END;
	length := 0;
	WHILE contents[length] # 0X DO INC(length) END;
	written := 0;
	IF length > 0 THEN ignore := Kernel32.WriteFile(file, contents, length, written, overlapped) END;
	ignore := Kernel32.CloseHandle(file);
	RETURN written = length
END WriteFile;

(** This process's id -- the only thing making a scratch directory name unique here. *)
(*
	The Unix half sends this process's output to a file with dup2, so that a child which is not A2
	-- an emulator running a case built for another architecture -- can be captured. There is no
	such thing to capture here: driving qemu is a Unix arrangement, and the only Windows binding
	that would do it, SetStdHandle, is not in Kernel32.Mod. Refusing is the honest answer, and ob
	reads it as "this host cannot execute cases for another architecture" -- it still compiles them.
*)
PROCEDURE Redirect*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN FALSE
END Redirect;

PROCEDURE ProcessId*(): SIGNED32;
BEGIN
	RETURN Kernel32.GetCurrentProcessId()
END ProcessId;

(* --- another program ---------------------------------------------------------------------- *)

(*
	CreateProcess takes one command line, not a vector, so the vector is joined back up here --
	quoting any argument that carries a space, which is the inverse of the splitting at the top of
	this module and the reason both live in one file.

	What comes back is the process HANDLE, not the process id: it is what waiting and killing need,
	and the caller treats it as an opaque token either way.
*)
PROCEDURE Spawn*(CONST program: ARRAY OF CHAR; arguments: Strings.StringArray): ADDRESS;
VAR line: ARRAY 32*1024 OF CHAR; index: SIZE; application, directory: Path;
	startup: Kernel32.StartupInfo; information: Kernel32.ProcessInformation;
BEGIN
	line := "";
	FOR index := 0 TO LEN(arguments^)-1 DO
		IF index > 0 THEN Strings.AppendChar(line, ' ') END;
		IF Strings.Pos(" ", arguments[index]^) >= 0 THEN
			Strings.AppendChar(line, '"'); Strings.Append(line, arguments[index]^);
			Strings.AppendChar(line, '"')
		ELSE
			Strings.Append(line, arguments[index]^)
		END
	END;
	COPY(program, application);
	IF ~CurrentDirectory(directory) THEN directory := "." END;
	startup.cb := SIZEOF(Kernel32.StartupInfo);
	startup.lpReserved := 0; startup.lpDesktop := 0; startup.lpTitle := 0;
	startup.dwFlags := {}; startup.cbReserved2 := 0; startup.lpReserved2 := 0;
	IF Kernel32.CreateProcess(application, line, NIL, NIL, 1, 0, NIL,
			directory, startup, information) = 0 THEN
		spawnError := SIGNED32(Kernel32.GetLastError()); RETURN 0
	END;
	spawnError := 0;
	RETURN information.hProcess
END Spawn;

(** Has the child finished, without waiting for it. *)
PROCEDURE Finished*(process: ADDRESS; VAR exitCode: SIGNED32): BOOLEAN;
VAR code: SIGNED32; ignore: Kernel32.BOOL;
BEGIN
	IF Kernel32.WaitForSingleObject(process, 0) = WaitTimeout THEN RETURN FALSE END;
	code := StillActive;
	ignore := Kernel32.GetExitCodeProcess(process, code);
	IF code = StillActive THEN RETURN FALSE END;
	exitCode := code;
	ignore := Kernel32.CloseHandle(process);
	RETURN TRUE
END Finished;

(** Kill the child and let go of it. *)
PROCEDURE Terminate*(process: ADDRESS);
VAR ignore: Kernel32.BOOL;
BEGIN
	ignore := Kernel32.TerminateProcess(process, 1);
	ignore := Kernel32.CloseHandle(process)
END Terminate;

BEGIN
	SplitCommandLine
END ObHost.
