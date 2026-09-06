MODULE ProcessInfo0; (** AUTHOR "staubesv"; PURPOSE "Platform-dependent process interface"; *)

IMPORT
	Objects;

TYPE

	ProcessArray* = ARRAY OF Objects.Process;

PROCEDURE GetProcesses*(VAR array : ProcessArray; VAR nofProcesses : SIZE);
VAR thread : Objects.Process; length, i : SIZE;
BEGIN
	nofProcesses := 0;
	length := LEN(array);
	(*	empty it first: the caller is handed a count and everything past it has to be nothing, or
		what the caller left in the array reads back as part of the snapshot. This one never did;
		the twin in ProcessInfo0.Mod meant to and read its own loop bound before setting it. *)
	FOR i := 0 TO length-1 DO array[i] := NIL; END;
	thread := Objects.root;
	WHILE (thread # NIL) & (nofProcesses < length) DO
		IF (thread.mode # Objects.Terminated) THEN
			array[nofProcesses] := thread(Objects.Process);
			INC(nofProcesses);
		END;
		thread := thread.nextProcess;
	END;
END GetProcesses;

PROCEDURE GetProcess*(id : INTEGER) : Objects.Process;
VAR process, thread : Objects.Process;
BEGIN
	process := NIL;
	thread := Objects.root;
	WHILE (thread # NIL) & (process = NIL) DO
		IF thread.id = id THEN process := thread; END;
		thread := thread.nextProcess;
	END;
	RETURN process;
END GetProcess;

END ProcessInfo0.
