(**
	AUTHOR: Alexey Morozov
	PURPOSE: Dynamic library tools for Windows platforms
*)
MODULE HostLibs;

IMPORT
	SYSTEM, Kernel32, Files;

TYPE
	LibHandle* = Kernel32.HANDLE; (** dynamic library handle type *)

CONST
	NilLibHandle* = Kernel32.NULL; (** invalid library handle *)

	DONT_RESOLVE_DLL_REFERENCES = 0;
	LOAD_LIBRARY_AS_DATAFILE = 1;
	(* reserved for internal LOAD_PACKAGED_LIBRARY = 2; *)
	LOAD_WITH_ALTERED_SEARCH_PATH = 3;
	LOAD_IGNORE_CODE_AUTHZ_LEVEL = 4;
	LOAD_LIBRARY_AS_IMAGE_RESOURCE = 5;
	LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE = 6;
	LOAD_LIBRARY_REQUIRE_SIGNED_TARGET = 7;
	LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 8;
	LOAD_LIBRARY_SEARCH_APPLICATION_DIR = 9;
	LOAD_LIBRARY_SEARCH_USER_DIRS = 10;
	LOAD_LIBRARY_SEARCH_SYSTEM32 = 11;
	LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = 12;
	LOAD_LIBRARY_SAFE_CURRENT_DIRS = 13;
	LOAD_LIBRARY_SEARCH_SYSTEM32_NO_FORWARDER = 14;

	(*
		The body of both loads. `report` is what separates them: a caller trying `sqlite3.dll` and
		then `libsqlite3-0.dll` is not looking at a failure when the first one is not there, and a
		procedure that answers with a BOOLEAN has already said everything it needs to.
	*)
	PROCEDURE Load(CONST fileName: ARRAY OF CHAR; VAR lib: LibHandle; report: BOOLEAN): BOOLEAN;
	CONST
		LoadLibraryExFlags = {LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS};
	VAR
		err: SIGNED32;
		fullName: Files.FileName;
		flags: SET;
		i: SIZE;
	BEGIN
		IF Files.Exists(fileName, fullName, flags) THEN
			i := 0;    (* it was read before it was set, and a loop over a name has to start at it *)
			WHILE fullName[i] # 0X DO
				IF fullName[i] = "/" THEN fullName[i] := "\"; END;
				INC(i);
			END;
			lib := Kernel32.LoadLibraryEx(fullName, NIL, LoadLibraryExFlags);
			IF (lib = NilLibHandle) & report THEN
				err := Kernel32.GetLastError();
				TRACE(fullName, err);
			END;
		ELSE (*! can happen when the library path is not specified *)
			lib := Kernel32.LoadLibrary(fileName);
			IF (lib = NilLibHandle) & report THEN
				err := Kernel32.GetLastError();
				TRACE(fileName, err);
			END;
		END;
		RETURN lib # NilLibHandle;
	FINALLY
		RETURN FALSE;
	END Load;

	(**
		Load a dynamic library

		fileName: library file name
		lib: returned loaded library handle; NilLibHandle in case of an error

		Return: TRUE in case of success
	*)
	PROCEDURE LoadLibrary*(CONST fileName: ARRAY OF CHAR; VAR lib: LibHandle): BOOLEAN;
	BEGIN
		RETURN Load(fileName, lib, TRUE);
	END LoadLibrary;

	(**
		Load a dynamic library that need not be there. Unlike LoadLibrary this says nothing when it
		is missing -- for a caller working through a list of names the platform might use.
	*)
	PROCEDURE LoadLibraryOptional*(CONST fileName: ARRAY OF CHAR; VAR lib: LibHandle): BOOLEAN;
	BEGIN
		RETURN Load(fileName, lib, FALSE);
	END LoadLibraryOptional;

	(**
		Free a previously loaded dynamic library

		lib: library handle

		Return: TRUE in case of success
	*)
	PROCEDURE FreeLibrary*(CONST lib: LibHandle): BOOLEAN;
	BEGIN
		RETURN (Kernel32.FreeLibrary(lib) # 0);
	FINALLY
		RETURN FALSE;
	END FreeLibrary;

	(**
		Get a procedure from a loaded dynamic library

		lib: library handle
		name: name of the procedure
		procAddr: address of the destination procedure pointer (e.g. ADDRESSOF(procedureVariable))

		Return: TRUE in case of success
	*)
	PROCEDURE GetProcedure*(CONST lib: LibHandle; CONST name: ARRAY OF CHAR; CONST procAddr: ADDRESS): BOOLEAN;
	VAR addr: ADDRESS;
	BEGIN
		ASSERT(procAddr # NIL);
		Kernel32.GetProcAddress(lib,name,addr);
		IF addr # NIL THEN
			SYSTEM.PUT(procAddr,addr);
			RETURN TRUE;
		END;
	FINALLY
		RETURN FALSE;
	END GetProcedure;

	(**
		Get a procedure that need not be there. The same thing on this host, where nothing is said
		about a name that is missing; the Unix twin does say something, and this is the interface
		on which the two are quiet in the same way. A library built without a feature does not
		export its entry points, and that is a fact about the build and not a fault.
	*)
	PROCEDURE GetProcedureOptional*(CONST lib: LibHandle; CONST name: ARRAY OF CHAR; CONST procAddr: ADDRESS): BOOLEAN;
	BEGIN
		RETURN GetProcedure(lib, name, procAddr);
	END GetProcedureOptional;

END HostLibs.

System.FreeDownTo HostLibs ~
