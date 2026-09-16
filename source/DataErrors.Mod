(* CAPO - Computational Analysis Platform for Oberon - by Alan Freed and Felix Friedrich. *)
(* Version 1, Update 2 *)

MODULE DataErrors;   (** AUTHOR "adf, fof"; PURPOSE "For reporting runtime warnings & errors into file Error.Log"; *)

(**  Error.Log is an error log file that can be viewed with any ASCII editor, and is overwritten with each session.
	If no errors or warnings were logged, the file will be empty.  File Error.Log is automatically opened/closed whenever
	module DataErrors.Mod is loaded-into/freed-from the system.  The Error.Log file from the previous session is saved in
	file Error.Log.Bak.

	Logging of the first error message of a session produces an audible SOS beep to inform the user to check this file.
	Logging of the first warning message of a session produces just 3 beeps (instead of 9) in the SOS tone sequence.

	Errors are for catostropic events, e.g., division by zero.
	Warnings are for non-optimal events, e.g., a series did not converge. *)

IMPORT SYSTEM, Modules, Objects, Reflection, Files, NbrInt, NbrRat, NbrRe, NbrCplx;

VAR
	F: Files.File;  W: Files.Writer;


	(*	What follows used to be a copy of the trap writer of twenty years ago: a stack walk of its
		own, a variable dumper of its own, and addresses held in SIGNED32. On a 64-bit machine the
		very first step -- the frame pointer, truncated to 32 bits and then dereferenced -- was a
		segmentation violation, so every error reported by this package took the process down
		instead of writing a line. Reflection does the same walk, keeps addresses in ADDRESS, and
		is what the traps of this system are written with. *)

	(* Where the caller of an Error or Warning procedure will return to -- that is where the error
	   was made. *)
	PROCEDURE CallerPC( ): ADDRESS;
	VAR bp, pc: ADDRESS;
	BEGIN
		bp := SYSTEM.GetFramePointer();
		SYSTEM.GET( bp, bp );							(* the frame of the Error procedure itself *)
		SYSTEM.GET( bp + SIZEOF( ADDRESS ), pc );		(* and where it returns to *)
		RETURN pc
	END CallerPC;

	PROCEDURE Location( pc: ADDRESS );
	VAR m: Modules.Module;  name: ARRAY 256 OF CHAR;  startpc: ADDRESS;
	BEGIN
		m := Modules.ThisModuleByAdr( pc );
		IF m # NIL THEN W.String( "   module: " );  W.String( m.name );  W.Ln END;
		Reflection.GetProcedureName( pc, name, startpc );
		IF name # "" THEN W.String( "      procedure: " );  W.String( name );  W.Ln END
	END Location;

	PROCEDURE DetailedErrorReport( pc: ADDRESS );
	BEGIN
		W.String( "Stack trace back" );  W.Ln;
		Reflection.StackTraceBack( W, pc, SYSTEM.GetFramePointer(), SYSTEM.GetStackPointer(),
			Objects.GetStackBottom( Objects.CurrentProcess() ), TRUE, FALSE )
	END DetailedErrorReport;


(** Log an error message to file Error.Log. *)
	PROCEDURE Error*( message: ARRAY OF CHAR );
	VAR pc: ADDRESS;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "An error of:" );  W.Ln;  W.String( "   " );
			W.String( message );  W.Ln;  W.String( "occurred in:" );  W.Ln;  Location( pc );  W.Ln;
			DetailedErrorReport(pc);
			W.Update
		END
	END Error;

(** Log an error message to file Error.Log when an error arises from a passed parameter whose value was int. *)
	PROCEDURE IntError*( int: NbrInt.Integer;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "An ERROR occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this error was: " );  W.Ln;  W.String( "   " );  NbrInt.IntToString( int, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;
			DetailedErrorReport(pc);
			W.Update
		END
	END IntError;

(** Log an error message to file Error.Log when an error arises from a passed parameter whose value was rat. *)
	PROCEDURE RatError*( rat: NbrRat.Rational;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "An ERROR occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this error was: " );  W.Ln;  W.String( "   " );  NbrRat.RatToString( rat, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;
						DetailedErrorReport(pc);
			W.Update
		END
	END RatError;

(** Log an error message to file Error.Log when an error arises from a passed parameter whose value was re. *)
	PROCEDURE ReError*( re: NbrRe.Real;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "An ERROR occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this error was: " );  W.Ln;  W.String( "   " );  NbrRe.ReToString( re, 15, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;
						DetailedErrorReport(pc);
			W.Update
		END
	END ReError;

(** Log an error message to file Error.Log when an error arises from a passed parameter whose value was cplx. *)
	PROCEDURE CplxError*( cplx: NbrCplx.Complex;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "An ERROR occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this error was: " );  W.Ln;  W.String( "   " );  NbrCplx.CplxToPolarString( cplx, 15, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;
						DetailedErrorReport(pc); W.Update
		END
	END CplxError;

(** Log a warning message to file Error.Log. *)
	PROCEDURE Warning*( message: ARRAY OF CHAR );
	VAR pc: ADDRESS;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "A WARNING of:" );  W.Ln;  W.String( "   " );
			W.String( message );  W.Ln;  W.String( "occurred in:" );  W.Ln;  Location( pc );  W.Ln;  W.Update
		END
	END Warning;

(** Log a warning message to file Error.Log when a warning arises from a passed parameter whose value was int. *)
	PROCEDURE IntWarning*( int: NbrInt.Integer;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "A WARNING occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this warning was: " );  W.Ln;  W.String( "   " );  NbrInt.IntToString( int, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;  W.Update
		END
	END IntWarning;

(** Log a warning message to file Error.Log when a warning arises from a passed parameter whose value was rat. *)
	PROCEDURE RatWarning*( rat: NbrRat.Rational;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "A WARNING occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this warning was: " );  W.Ln;  W.String( "   " );  NbrRat.RatToString( rat, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;  W.Update
		END
	END RatWarning;

(** Log a warning message to file Error.Log when a warning arises from a passed parameter whose value was re. *)
	PROCEDURE ReWarning*( re: NbrRe.Real;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "A WARNING occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this warning was: " );  W.Ln;  W.String( "   " );  NbrRe.ReToString( re, 15, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;  W.Update
		END
	END ReWarning;

(** Log a warning message to file Error.Log when a warning arises from a passed parameter whose value was cplx. *)
	PROCEDURE CplxWarning*( cplx: NbrCplx.Complex;  message: ARRAY OF CHAR );
	VAR pc: ADDRESS;  string: ARRAY 64 OF CHAR;
	BEGIN {EXCLUSIVE}
		IF W # NIL THEN
			pc := CallerPC();  W.String( "A WARNING occurred in:" );  W.Ln;
			Location( pc );  W.String( "The argument passed that caused this warning was: " );  W.Ln;  W.String( "   " );  NbrCplx.CplxToPolarString( cplx, 15, string );
			W.String( string );  W.Ln;  W.String( "resulting in the following error message:" );  W.Ln;  W.String( "   " );  W.String( message );  W.Ln;  W.Ln;  W.Update
		END
	END CplxWarning;

(** Opens the file Error.Log, saving the prior log file to Error.Log.Bak.
		Error.Log is automatically opened whenever this module is loaded into memory,
		and it only needs to be reopened manually if you had previously closed it manually. *)
	PROCEDURE Open*;
	VAR ignor: INTEGER;  backup, current: Files.FileName;
	BEGIN
		COPY( "Error.Log", current );  COPY( "Error.Log.Bak", backup );  Files.Delete( backup, ignor );
		Files.Rename( current, backup, ignor );  F := Files.New( current );  Files.OpenWriter( W, F, 0 )
	END Open;

(** Closes the file Error.Log.
		Error.Log is automatically closed whenever this module is garbage collected.
		Executing Close forces the file to close immediately. *)
	PROCEDURE Close*;
	BEGIN
		IF F # NIL THEN Files.Register( F );  W := NIL;  F := NIL END
	END Close;



BEGIN
	Open;  Modules.InstallTermHandler( Close )
END DataErrors.

DataErrors.Close ~
EditTools.OpenAscii  Error.Log ~
EditTools.OpenAscii  Error.Log.Bak ~

