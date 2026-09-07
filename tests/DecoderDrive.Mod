MODULE DecoderDrive; (** AUTHOR "Andrii Puhachenko"; PURPOSE "drive a registered disassembler over a stream of bytes"; *)

(*
	The half of the differential test that runs inside A2: bytes in, one line per instruction out.
	tests/decoder-check.sh assembles tests/amd64-instructions.s and tests/i386-instructions.s with
	llvm-mc, gives the bytes to this module and to objdump, and compares the two readings -- so both
	the decoder and its printer are under test, and they would have to be wrong in the same way, and
	in a way that agrees with the architecture manual, to pass. The decoder is named by the object
	file extension it was registered for: Abx is AMD64Decoder, Obx is I386Decoder.

	Why a module and a shell script rather than a case in a tests/*.Test file: both decoders are
	reached only through Decoder, whose import list runs into the component framework, and several
	of those modules wait during their own initialisation for a display and a window manager and
	block for ever on a machine that has neither. So the decoder cannot be loaded headless at all;
	the check registers a display of nothing but memory (WMDemo.Screen) and installs the window
	manager over it first, which is the same trick tests/wm-check.sh plays for the window manager.
*)

IMPORT Files, Streams, MemoryReader, Decoder, Commands, Strings;

TYPE
	(*	Decoder.Decode wants a ProcedureInfo and dereferences it; its constructor is not exported, and
		an extension with one of its own is the only way to have one from outside the module. Nothing
		of it is used here but codeOffset, which is 0, and GetFieldAtOffset, which finds nothing. *)
	Code = OBJECT (Decoder.ProcedureInfo)
		PROCEDURE &Init*;
		BEGIN
		END Init;
	END Code;

	Bytes = POINTER TO ARRAY OF CHAR;

PROCEDURE HexDigit (ch: CHAR; VAR value: SIGNED32): BOOLEAN;
BEGIN
	IF (ch >= '0') & (ch <= '9') THEN value := ORD(ch) - ORD('0')
	ELSIF (ch >= 'a') & (ch <= 'f') THEN value := ORD(ch) - ORD('a') + 10
	ELSIF (ch >= 'A') & (ch <= 'F') THEN value := ORD(ch) - ORD('A') + 10
	ELSE RETURN FALSE
	END;
	RETURN TRUE
END HexDigit;

(*	Every pair of hex digits in the file is a byte and everything else is a separator, so the same
	reader takes "48 89 e5" and llvm-mc's own "0x48,0x89,0xe5". *)
PROCEDURE ReadBytes (CONST name: ARRAY OF CHAR; VAR bytes: Bytes; VAR count: SIZE): BOOLEAN;
VAR file: Files.File; reader: Files.Reader; ch: CHAR; high, low: SIGNED32; pending: BOOLEAN;
BEGIN
	file := Files.Old(name);
	IF file = NIL THEN RETURN FALSE END;
	NEW(bytes, file.Length() DIV 2 + 1); count := 0; pending := FALSE;
	NEW(reader, file, 0);
	reader.Char(ch);
	WHILE reader.res = Streams.Ok DO
		IF HexDigit(ch, low) THEN
			IF pending THEN
				bytes[count] := CHR(high * 16 + low); INC(count); pending := FALSE
			ELSE
				high := low; pending := TRUE
			END
		ELSE
			pending := FALSE					(* "0x" is a separator followed by a pair, not a digit *)
		END;
		reader.Char(ch)
	END;
	RETURN TRUE
END ReadBytes;

(**	DecoderDrive.Decode <extension> <hex file> <listing file> ~ -- decode the bytes with the decoder
	registered for that object file extension and write one line per instruction: offset, length,
	the bytes it took, and the instruction as that decoder prints it. *)
PROCEDURE Decode* (context: Commands.Context);
VAR
	extension: Decoder.Extension;
	in, out: Files.FileName;
	bytes: Bytes; count, i: SIZE;
	file: Files.File; writer: Files.Writer;
	reader: MemoryReader.Reader;
	decoder: Decoder.Decoder;
	opcode: Decoder.Opcode;
	code: Code;
	line: Streams.StringWriter;
	text: ARRAY 1024 OF CHAR;
	number: ARRAY 32 OF CHAR;
BEGIN
	IF ~context.arg.GetString(extension) OR ~context.arg.GetString(in) OR ~context.arg.GetString(out) THEN
		context.error.String("usage: DecoderDrive.Decode <extension> <hex file> <listing file>"); context.error.Ln; RETURN
	END;
	IF ~ReadBytes(in, bytes, count) THEN
		context.error.String("cannot read "); context.error.String(in); context.error.Ln; RETURN
	END;
	file := Files.New(out);
	IF file = NIL THEN
		context.error.String("cannot write "); context.error.String(out); context.error.Ln; RETURN
	END;
	NEW(writer, file, 0);
	NEW(reader, ADDRESSOF(bytes[0]), count);
	NEW(code);
	decoder := Decoder.GetDecoder(extension, reader);
	IF decoder = NIL THEN
		context.error.String("no decoder is registered for "); context.error.String(extension); context.error.Ln; RETURN
	END;
	NEW(line, LEN(text));
	decoder.outputStreamWriter := line;
	opcode := decoder.Decode(code);
	WHILE opcode # NIL DO
		NEW(line, LEN(text));
		opcode.PrintInstruction(line); line.Char(' ');
		opcode.PrintArguments(line);
		line.Update; line.Get(text);
		Strings.Trim(text, ' ');
		writer.Int(opcode.offset, 0); writer.Char(09X);
		writer.Int(opcode.length, 0); writer.Char(09X);
		FOR i := 0 TO opcode.length - 1 DO
			Strings.IntToHexStr(ORD(opcode.code[i]), 2, number);
			Strings.LowerCase(number);
			writer.String(number)
		END;
		writer.Char(09X); writer.String(text); writer.Ln;
		opcode := opcode.next
	END;
	writer.Update; Files.Register(file);
	context.out.String("DecoderDrive: "); context.out.String(extension); context.out.String(", ");
	context.out.Int(count, 0);
	context.out.String(" bytes decoded into "); context.out.String(out); context.out.Ln;
	context.out.Update
END Decode;

END DecoderDrive.
