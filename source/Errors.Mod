MODULE Errors; (** AUTHOR "staubesv"; PURPOSE "Error message interface"; *)
(**
 * Interface to system-wide unique error codes. Can be used by application to retrieve textual representations
 * error codes.
 *
 * Notes:
 *	- only for use withhin applications
 *	- don't move this file to the system package, never use it from within modules in the system package
 *)

IMPORT
	Modules, Streams, Commands, Strings, Files;

CONST
	DefaultErrorMessageFile = "errors.txt";

	MaxLineLength = 256; (* Maximum length of line in error message file *)
	InitialCacheSize = 128;

	(* parser result codes *)
	Ok = 0;
	NotFound = 1;
	Error = 2;
	FileNotFound = 3;

	UnknownModule = "Unknown";

TYPE

	ErrorMessage* = RECORD
		code : SIGNED32;
		moduleName- : Modules.Name;
		text- : Strings.String; (* is never NIL *)
	END;

	ErrorMessages = POINTER TO ARRAY OF ErrorMessage;

VAR
	cache : ErrorMessages;
	index : SIGNED32;
	lastModuleName : Modules.Name;

PROCEDURE GetErrorString(errorCode : INTEGER) : Strings.String;
VAR message : ARRAY 128 OF CHAR; nbr : ARRAY 16 OF CHAR;
BEGIN
	message := "Unknown error, res: ";
	Strings.IntToStr(errorCode, nbr); Strings.Append(message, nbr);
	RETURN Strings.NewString(message);
END GetErrorString;

(** Get error message for the specified error number. If no message can be found, a generic error message is generated *)
PROCEDURE GetErrorMessage*(errorCode : INTEGER) : ErrorMessage;
VAR errorMessage : ErrorMessage; res : INTEGER;
BEGIN {EXCLUSIVE}
	res := -1;
	Get(errorCode, errorMessage, res);
	IF (res # Ok) THEN
		errorMessage.moduleName := UnknownModule;
		errorMessage.text := GetErrorString(errorCode);
	END;
	ASSERT(errorMessage.text # NIL);
	RETURN errorMessage;
END GetErrorMessage;

PROCEDURE ToStream*(errorCode : INTEGER; out : Streams.Writer);
VAR errorMessage : ErrorMessage;
BEGIN
	ASSERT(out # NIL);
	errorMessage := GetErrorMessage(errorCode);
	out.String(errorMessage.text^);
	out.String(" (");
	IF (errorMessage.moduleName # UnknownModule) THEN out.String(errorMessage.moduleName); out.String(":"); END;
	out.Int(errorCode, 0); out.String(")");
	out.Update;
END ToStream;

PROCEDURE ResizeCache;
VAR newCache : ErrorMessages; i : SIZE;
BEGIN
	IF (cache # NIL) THEN
		NEW(newCache, 2*LEN(cache));
		FOR i := 0 TO LEN(cache)-1 DO newCache[i] := cache[i]; END;
	ELSE
		NEW(newCache, InitialCacheSize);
	END;
	cache := newCache;
END ResizeCache;

PROCEDURE Add(CONST errorMessage : ErrorMessage);
BEGIN
	IF (cache = NIL) OR (index >= LEN(cache)) THEN ResizeCache; END;
	cache[index] := errorMessage;
	INC(index);
END Add;

PROCEDURE Get(number : INTEGER; VAR errorMessage : ErrorMessage; VAR res : INTEGER);
VAR i : SIGNED32;
BEGIN
	IF (cache # NIL) THEN
		i := 0; WHILE (i < index) & (cache[i].code # number) DO INC(i); END;
	ELSE
		i := MAX(SIGNED32);
	END;
	IF (i < index) THEN
		errorMessage := cache[i]; res := Ok;
	ELSE
		res := NotFound;
	END;
END Get;

PROCEDURE ParseLine(reader : Streams.Reader; VAR errorMessage : ErrorMessage; VAR res : INTEGER);
VAR line : ARRAY MaxLineLength OF CHAR;
BEGIN
	errorMessage.text := NIL; (* the caller must not read what this line did not set *)
	IF reader.GetInteger(errorMessage.code, FALSE) THEN
		reader.SkipSpaces; (* spaces and tabs only: the text of an entry ends where its line ends *)
		reader.Ln(line);
		IF (reader.res = Streams.Ok) OR (reader.res = Streams.EOF) THEN
			errorMessage.text := Strings.NewString(line); res := Ok;
		ELSE
			res := reader.res;
		END;
	ELSE
		res := reader.res;
	END;
END ParseLine;

PROCEDURE ParseFile(CONST filename : Files.FileName; VAR res : INTEGER);
VAR file : Files.File; reader : Files.Reader; errorMessage : ErrorMessage; ch : CHAR;
BEGIN
	file := Files.Old(filename);
	IF (file # NIL) THEN
		res := Ok;
		Files.OpenReader(reader, file, 0);
		(*	Peek answers 0X at the end of the file and clears the EOF it saw there, so the end of the
			file is that 0X and not reader.res. The loop used to test reader.res, ran one turn too many
			and read a number that was not there -- which reported every well-formed file as broken. *)
		reader.SkipWhitespace; (* leading blank lines, and the indentation of the first line *)
		ch := reader.Peek();
		WHILE (res = Ok) & (ch # 0X) DO
			IF (ch = "#") THEN
				reader.SkipLn; (* line comment, wherever on the line it begins *)
			ELSE
				ParseLine(reader, errorMessage, res);
				IF (res = Ok) THEN
					(*	a code that divides by a hundred names the group the codes under it belong to --
						and is a code in its own right as well: errors.txt writes 0 and 300 that way. *)
					IF (errorMessage.code MOD 100 = 0) THEN COPY(errorMessage.text^, lastModuleName); END;
					errorMessage.moduleName := lastModuleName;
					Add(errorMessage);
				END;
			END;
			reader.SkipWhitespace;
			ch := reader.Peek();
		END;
		IF (res = Ok) & ((reader.res = Streams.Ok) OR (reader.res = Streams.EOF)) THEN res := Ok; ELSE res := Error; END;
	ELSE
		res := FileNotFound;
	END;
END ParseFile;

(**	Load and parse a error message file. *)
PROCEDURE Open*(context : Commands.Context); (** [filename] ~ *)
VAR filename : Files.FileName; res : INTEGER;
BEGIN {EXCLUSIVE}
	index := 0; cache := NIL; lastModuleName := UnknownModule; (* what the last file named is not this file's *)
	context.arg.SkipWhitespace; context.arg.String(filename);
	IF (filename = "") THEN COPY(DefaultErrorMessageFile, filename); END;
	context.out.String("Errors: Loading error messages from file "); context.out.String(filename);
	context.out.String(" ... "); context.out.Update;
	ParseFile(filename, res);
	IF (res = Ok) THEN
		context.out.Int(index, 0); context.out.String(" messages loaded.");
	ELSE
		context.out.String("failed, res: "); context.out.Int(res, 0);
	END;
	context.out.Ln;
END Open;

(** Show the error message for the optionally specified error number. If no number is specified,
	show all loaded error messages. This procedure is primarly for testing purposes. *)
PROCEDURE Show*(context : Commands.Context); (** [error number] ~ *)
CONST Tab = 09X;
VAR number, i : SIGNED32; errorMessage : ErrorMessage;
BEGIN
	IF context.arg.GetInteger(number, FALSE) THEN
		errorMessage := GetErrorMessage(number);
		context.out.String("Error message for number "); context.out.Int(number, 0); context.out.String(": ");
		context.out.String("Module: "); context.out.String(errorMessage.moduleName);
		context.out.String(", Text: "); context.out.String(errorMessage.text^);
	ELSE
		context.out.String("Errors: ");
		IF (index > 0) THEN
			context.out.Int(index, 0); context.out.String(" error messages loaded: "); context.out.Ln;
			BEGIN {EXCLUSIVE}
				FOR i := 0 TO index-1 DO
					context.out.Int(cache[i].code, 0); context.out.Char(Tab);
					context.out.String(cache[i].text^);
					context.out.String(" ("); context.out.String(cache[i].moduleName); context.out.String(")");
					context.out.Ln;
				END;
			END;
		ELSE
			context.out.String("No error messages loaded.");
		END;
	END;
	context.out.Ln;
END Show;

BEGIN
	index := 0;
	lastModuleName := UnknownModule;
END Errors.

Errors.Open ~

Errors.Show 1505~

Errors.Show~

System.Free Errors ~
