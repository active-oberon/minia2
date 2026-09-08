MODULE HostLibsProbe;	(* the loader's answer for each name in names.txt, for tests/hostlibs-check.sh *)
IMPORT Files, Streams, HostLibs, KernelLog;

	(* HostLibsProbe.Do reads the names from a file rather than the command line, so that `ob build`
	   can bake it into a program the check runs like any other. *)
	PROCEDURE Do*;
	VAR file: Files.File; reader: Files.Reader; name: Files.FileName; lib: HostLibs.LibHandle;
	BEGIN
		file := Files.Old("names.txt");
		IF file = NIL THEN KernelLog.String("no names.txt here"); KernelLog.Ln; RETURN END;
		Files.OpenReader(reader, file, 0);
		REPEAT
			reader.Ln(name);
			IF name # "" THEN
				KernelLog.String(name); KernelLog.String(" -> ");
				IF HostLibs.LoadLibraryOptional(name, lib) THEN
					KernelLog.String("loaded")
				ELSE
					KernelLog.String("failed")
				END;
				KernelLog.Ln
			END
		UNTIL reader.res # Streams.Ok
	END Do;

END HostLibsProbe.
