MODULE In; (** AUTHOR "FOF"; PURPOSE "Simple argument parser for educational purposes"; *)

IMPORT Commands, Streams;

PROCEDURE GetArg*(): Streams.Reader;
BEGIN
	RETURN Commands.GetContext().arg;
END GetArg;

PROCEDURE Char*(VAR ch: CHAR): BOOLEAN;
BEGIN
	RETURN GetArg().GetChar(ch);
END Char;

PROCEDURE Int*(VAR i: INTEGER; hex := FALSE: BOOLEAN): BOOLEAN;
(*	hex = TRUE reads the digits as hexadecimal, with an optional "H" postfix -- which is what the
	reader underneath does. It is not, as this comment used to say, that a hex number must carry the
	postfix: nothing enforces that. And the default used to be TRUE, so `In.Int(i)` read "42" as 66
	and "-42" as -66 -- every number hexadecimal, in the module whose whole purpose is a first
	program's arguments. *)
BEGIN
	RETURN GetArg().GetInteger(i, hex);
END Int;

PROCEDURE Real*(VAR f: FLOAT64): BOOLEAN;
BEGIN
	RETURN GetArg().GetReal(f);
END Real;

PROCEDURE String*(VAR s: ARRAY OF CHAR): BOOLEAN;
BEGIN
	RETURN GetArg().GetString(s);
END String;

END In.


