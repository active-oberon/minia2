MODULE ObHost;	(** AUTHOR "minia2"; PURPOSE "Host services Ob needs and portable A2 does not offer: real argv, environment, resolved paths"; *)

(*
	The Unix half of the platform layer under Ob. Everything here is a system call; anything that can
	be done with string arithmetic belongs in Ob itself, so that the Windows half stays this short.

	Why real argv at all, when a Commands.Context already carries arguments: StdIO builds that context
	by gluing argv together with spaces (StdIO.Args), so an argument containing a space arrives as two.
	`ob build "My Module.Mod"` has to work, hence Unix.argc/argv read directly.
*)

IMPORT S := SYSTEM, Unix;

CONST
	MaxPath* = 1024;

	(* chmod(2) modes are bit numbers, not the octal literal: 0755 is rwx r-x r-x. *)
	Mode755 = {0, 2, 3, 5, 6, 7, 8};

TYPE
	Path* = ARRAY MaxPath OF CHAR;

(* Copy a NUL-terminated C string at adr into s, truncating rather than overrunning. *)
PROCEDURE CopyIn(adr: ADDRESS; VAR s: ARRAY OF CHAR);
VAR i: SIZE; ch: CHAR;
BEGIN
	i := 0;
	REPEAT
		S.GET(adr, ch); INC(adr); s[i] := ch; INC(i)
	UNTIL (ch = 0X) OR (i = LEN(s));
	s[LEN(s)-1] := 0X
END CopyIn;

(** Number of command-line arguments, including argv[0]. *)
PROCEDURE ArgCount*(): SIGNED32;
BEGIN
	RETURN Unix.argc
END ArgCount;

(** Argument no, verbatim -- spaces and quotes included. Empty when no is out of range. *)
PROCEDURE Arg*(no: SIGNED32; VAR value: ARRAY OF CHAR);
BEGIN
	IF (no < 0) OR (no >= Unix.argc) THEN value := "" ELSE Unix.GetArg(no, value) END
END Arg;

(** An environment variable, FALSE when it is not set. *)
PROCEDURE Env*(CONST name: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
VAR adr: ADDRESS;
BEGIN
	adr := Unix.getenv(ADDRESSOF(name));
	IF adr = 0 THEN value := ""; RETURN FALSE END;
	CopyIn(adr, value); RETURN TRUE
END Env;

(** An absolute path with symlinks resolved. FALSE when the path does not exist. *)
PROCEDURE RealPath*(CONST path: ARRAY OF CHAR; VAR resolved: ARRAY OF CHAR): BOOLEAN;
VAR buffer: Path; adr: ADDRESS;
BEGIN
	adr := Unix.realpath(ADDRESSOF(path), ADDRESSOF(buffer));
	IF adr = 0 THEN resolved := ""; RETURN FALSE END;
	COPY(buffer, resolved); RETURN TRUE
END RealPath;

(**
	Where this very binary sits, with every symlink followed -- which is what lets a tarball SDK be
	used through a symlink in ~/.local/bin and still find the library beside the real file.
	/proc is Linux-only; on a system without it the caller falls back to $A2SDK.
*)
PROCEDURE ExecutablePath*(VAR path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN RealPath("/proc/self/exe", path)
END ExecutablePath;

(** The current working directory. *)
PROCEDURE CurrentDirectory*(VAR path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF Unix.getcwd(ADDRESSOF(path), LEN(path)) = 0 THEN path := ""; RETURN FALSE END;
	RETURN TRUE
END CurrentDirectory;

(** Does the name exist at all -- file, directory or anything else. *)
PROCEDURE Exists*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN Unix.access(ADDRESSOF(path), Unix.F_OK) = 0
END Exists;

(** Is the name executable by this process. *)
PROCEDURE Executable*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN Unix.access(ADDRESSOF(path), Unix.X_Ok) = 0
END Executable;

(** Make the file executable, as a freshly linked binary has to be. *)
PROCEDURE MakeExecutable*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN Unix.chmod(ADDRESSOF(path), Mode755) = 0
END MakeExecutable;

(** Create one directory, 0755. TRUE when it exists afterwards, whoever created it. *)
PROCEDURE MakeDirectory*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	IF Unix.mkdir(ADDRESSOF(path), 1EDH) = 0 THEN RETURN TRUE END;	(* 0755; mkdir takes mode_t, not a SET *)
	RETURN Exists(path)
END MakeDirectory;

(** Delete a file. *)
PROCEDURE Remove*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN Unix.unlink(ADDRESSOF(path)) = 0
END Remove;

(** Delete an empty directory. *)
PROCEDURE RemoveDirectory*(CONST path: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN Unix.rmdir(ADDRESSOF(path)) = 0
END RemoveDirectory;

(*
	Directory listing, straight off opendir/readdir, because the one in Files cannot do this job:
	its enumerator skips every name beginning with a dot whatever the mask says
	(Unix.UnixFiles.EnumDir), and it keeps its own listing in an anonymous file created in the
	working directory -- which is itself a dot file, in the very directory being listed. Both
	together mean a scratch directory can never be emptied through Files.
*)
PROCEDURE OpenDirectory*(CONST path: ARRAY OF CHAR): ADDRESS;
BEGIN
	RETURN Unix.opendir(ADDRESSOF(path))
END OpenDirectory;

(** The next name in the directory, "." and ".." included. FALSE at the end. *)
PROCEDURE NextEntry*(directory: ADDRESS; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR entry: Unix.Dirent;
BEGIN
	entry := Unix.readdir(directory);
	IF entry = NIL THEN name := ""; RETURN FALSE END;
	CopyIn(ADDRESSOF(entry.name), name);
	RETURN TRUE
END NextEntry;

PROCEDURE CloseDirectory*(directory: ADDRESS);
BEGIN
	Unix.closedir(directory)
END CloseDirectory;

(** This process's id -- the only thing making a scratch directory name unique here. *)
PROCEDURE ProcessId*(): SIGNED32;
BEGIN
	RETURN Unix.getpid()
END ProcessId;

END ObHost.
