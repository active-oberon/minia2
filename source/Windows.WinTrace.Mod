MODULE WinTrace;

IMPORT Kernel32, Modules,Trace,Commands;

CONST
	none = 0; console = 1; file = 2;
	eof = 4201;   (* Streams.EOF, spelled out: this module sits below Streams and cannot import it *)
VAR
	hin-, hout-, herr-: Kernel32.HANDLE;
	mode: SIGNED32; (* none, console or file *)

	traceChar0: PROCEDURE(ch: CHAR);

(* Sender to be used with Stream.Writer *)
PROCEDURE Send* (CONST buf: ARRAY OF CHAR; ofs, len: SIZE; propagate: BOOLEAN; VAR res: INTEGER);
VAR b: Kernel32.BOOL; written: Kernel32.DWORD;
BEGIN
	IF mode # none THEN
		b := Kernel32.WriteFile (hout, buf[ofs], len(Kernel32.DWORD), written, NIL);
		IGNORE Kernel32.FlushFileBuffers(hout);
	END;
END Send;

(* Sender to be used with Stream.Writer *)
PROCEDURE SendError* (CONST buf: ARRAY OF CHAR; ofs, len: SIZE; propagate: BOOLEAN; VAR res: INTEGER);
VAR b: Kernel32.BOOL; written: Kernel32.DWORD;
BEGIN
	IF mode # none THEN
		b := Kernel32.WriteFile (herr, buf[ofs], len(Kernel32.DWORD), written, NIL);
		IGNORE Kernel32.FlushFileBuffers(herr);
	END;
END SendError;


(* Receiver to be used with Stream.Reader *)
(*	The Unix side of this had the same two faults, and they are both about the end of input:
	the loop asked for more without ever looking at whether the last read gave any, so a closed
	standard input was read forever at a full core, and `res` said Ok either way, so the reader
	above could not tell an empty stream from a full one. A second read also wrote over the
	first one's bytes, because ofs never moved. *)
PROCEDURE Receive* (VAR buf: ARRAY OF CHAR; ofs, size, min: SIZE; VAR len: SIZE; VAR res: INTEGER);
VAR b: Kernel32.BOOL; tlen: SIGNED32;
BEGIN
	len := 0;
	LOOP
		tlen := 0;
		b := Kernel32.ReadFile (hin, buf[ofs], size(Kernel32.DWORD), tlen, NIL);
		IF (b = 0) OR (tlen <= 0) THEN EXIT END;   (* the read failed, or the input ended *)
		INC(ofs, tlen); DEC(size, tlen); INC(len, tlen);
		IF (len >= min) OR (size <= 0) THEN EXIT END
	END;
	IF len >= min THEN res := 0 ELSE res := eof END
END Receive;

PROCEDURE Init;
BEGIN
	mode := none;
END Init;

PROCEDURE Close*;
BEGIN
	IF traceChar0 # NIL THEN
		Trace.Char := traceChar0;
	END;
	IF mode = console THEN
		IGNORE Kernel32.CloseHandle(hout);
	#IF ~SHAREDLIB THEN
		IGNORE Kernel32.FreeConsole ();
	#END;
	ELSIF mode = file THEN
		IGNORE Kernel32.CloseHandle(hout);
	END;
	hout := Kernel32.InvalidHandleValue;
	mode := none;
END Close;

PROCEDURE OpenConsole*;
VAR res: INTEGER;
BEGIN
	IF mode = console THEN RETURN
	ELSIF mode = file THEN Close
	END;
	IF Kernel32.AttachConsole(-1) = Kernel32.False THEN
		res := Kernel32.AllocConsole ();
	END;

	hin := Kernel32.GetStdHandle (Kernel32.STDInput);
	ASSERT ((hin) # (Kernel32.InvalidHandleValue));

	hout := Kernel32.GetStdHandle (Kernel32.STDOutput);
	ASSERT ((hout) # (Kernel32.InvalidHandleValue));

	herr := Kernel32.GetStdHandle (Kernel32.STDError);
	ASSERT ((herr) # (Kernel32.InvalidHandleValue));

	traceChar0 := Trace.Char;
	Trace.Char := Char;
	mode := console;
END OpenConsole;

PROCEDURE OpenFile*(context: Commands.Context);
VAR filename: ARRAY 256 OF CHAR;
BEGIN
	Close;
	IF ~context.arg.GetString(filename) THEN filename := "WinTrace.Text" END;
	hout := Kernel32.CreateFile(filename, {Kernel32.GenericWrite}, {Kernel32.FileShareRead}, NIL, Kernel32.CreateAlways, {Kernel32.FileAttributeNormal}, Kernel32.NULL);
	ASSERT ((hout) # (Kernel32.InvalidHandleValue));
	herr := hout;
	traceChar0 := Trace.Char;
	Trace.Char := Char;
	mode := file;
END OpenFile;

PROCEDURE Terminate;
BEGIN
	Close;
END Terminate;

PROCEDURE Char(c: CHAR);
VAR len: SIGNED32; b: Kernel32.BOOL;
BEGIN
	len := 1;
	b := Kernel32.WriteFile(hout,c,len,len,NIL);
END Char;

BEGIN
	Init;
	Modules.InstallTermHandler (Terminate);
END WinTrace.

WinTrace.OpenFile ~
WinTrace.OpenFile myTrace.Text ~
WinTrace.OpenConsole
WinTrace.Close
