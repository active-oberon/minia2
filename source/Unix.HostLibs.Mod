(**
	AUTHOR: Alexey Morozov
	PURPOSE: Dynamic library tools for Unix platforms
*)
MODULE HostLibs;

IMPORT
	SYSTEM, Unix;

TYPE
	LibHandle* = ADDRESS; (** dynamic library handle type *)

CONST
	NilLibHandle* = NIL; (** invalid library handle *)

(*
	dlopen flags

	#define RTLD_LAZY     0x0001
	#define RTLD_NOW      0x0002
	#define RTLD_GLOBAL   0x0100
	#define RTLD_LOCAL    0x0000
	#define RTLD_NOSHARE  0x1000
	#define RTLD_EXE      0x2000
	#define RTLD_SCRIPT   0x4000
*)

	(**
		Load a dynamic library

		fileName: library file name
		lib: returned loaded library handle; NilLibHandle in case of an error

		Return: TRUE in case of success
	*)
	PROCEDURE LoadLibrary*(CONST fileName: ARRAY OF CHAR; VAR lib: LibHandle): BOOLEAN;
	BEGIN
		lib := Unix.Dlopen(fileName, 0x0001); (* RTLD_LAZY: use lazy binding - resolve symbols only at the user request *)
		RETURN (lib # NilLibHandle);
	FINALLY
		RETURN FALSE;
	END LoadLibrary;

	(**
		Load a dynamic library that need not be there. Unlike LoadLibrary this says nothing when it
		is missing -- for a caller working through a list of names the platform might use.
	*)
	PROCEDURE LoadLibraryOptional*(CONST fileName: ARRAY OF CHAR; VAR lib: LibHandle): BOOLEAN;
	BEGIN
		lib := Unix.DlopenOptional(fileName, 0x0001);
		RETURN (lib # NilLibHandle);
	FINALLY
		RETURN FALSE;
	END LoadLibraryOptional;

	(**
		Free a previously loaded dynamic library

		lib: library handle

		Return: TRUE in case of success
	*)
	PROCEDURE FreeLibrary*(CONST lib: LibHandle): BOOLEAN;
	BEGIN
		IF lib # NIL THEN
			Unix.Dlclose(lib);
			RETURN TRUE;
		END;
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
		Unix.Dlsym(lib,name,procAddr);
		SYSTEM.GET(procAddr,addr);
		RETURN addr # NIL;
	FINALLY
		RETURN FALSE;
	END GetProcedure;

	(**
		Get a procedure that need not be there. Unlike GetProcedure this says nothing when the name
		is missing: a library built without a feature does not export its entry points, and that is
		a fact about the build and not a fault. A binding to a whole header meets several of them.
	*)
	PROCEDURE GetProcedureOptional*(CONST lib: LibHandle; CONST name: ARRAY OF CHAR; CONST procAddr: ADDRESS): BOOLEAN;
	VAR addr: ADDRESS;
	BEGIN
		ASSERT(procAddr # NIL);
		IF ~Unix.DlsymOptional(lib,name,procAddr) THEN RETURN FALSE END;
		SYSTEM.GET(procAddr,addr);
		RETURN addr # NIL;
	FINALLY
		RETURN FALSE;
	END GetProcedureOptional;

END HostLibs.
