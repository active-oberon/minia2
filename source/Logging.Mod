MODULE Logging; (** PURPOSE "Typed structured records with replaceable, synchronous handlers"; *)

IMPORT Streams, Strings, Clock, Dates, JSON;

CONST
	LevelDebug* = -4;
	LevelInfo* = 0;
	LevelWarn* = 4;
	LevelError* = 8;

	TextValue* = 0; IntValue* = 1; UIntValue* = 2; BoolValue* = 3; FloatValue* = 4;

TYPE
	Attr* = RECORD
		key*, text*: Strings.String;
		kind*: SIGNED32;
		integer*: SIGNED64;
		unsigned*: UNSIGNED64;
		boolean*: BOOLEAN;
		real*: FLOAT64;
	END;

	(* shortcut: pass declared attribute arrays, inline array literals need a compiler fix. *)
	Attrs* = POINTER TO ARRAY OF Attr;

	Record* = RECORD
		time*: Dates.DateTime;
		level*: SIGNED32;
		message*: Strings.String;
		attrs*: Attrs;
	END;

	Handler* = OBJECT
		PROCEDURE Enabled*(level: SIGNED32): BOOLEAN;
		BEGIN RETURN TRUE END Enabled;

		PROCEDURE Handle*(CONST record: Record): SIGNED32;
		BEGIN HALT(301) END Handle;
	END Handler;

	StreamHandler* = OBJECT (Handler)
	VAR writer: Streams.Writer; minimum: SIGNED32; json: BOOLEAN;

		PROCEDURE &Init(writer: Streams.Writer; minimum: SIGNED32; json: BOOLEAN);
		BEGIN
			ASSERT(writer # NIL);
			SELF.writer := writer; SELF.minimum := minimum; SELF.json := json
		END Init;

		(** SetLevel changes filtering for every logger sharing this handler. *)
		PROCEDURE SetLevel*(level: SIGNED32);
		BEGIN {EXCLUSIVE} minimum := level END SetLevel;

		PROCEDURE Enabled*(level: SIGNED32): BOOLEAN;
		BEGIN {EXCLUSIVE} RETURN level >= minimum END Enabled;

		(** Handle keeps the writer exclusive until the complete record has been flushed. *)
		PROCEDURE Handle*(CONST record: Record): SIGNED32;
		VAR timestamp: ARRAY 32 OF CHAR; i: SIZE; key: Strings.String;
		BEGIN {EXCLUSIVE}
			ASSERT((record.message # NIL) & (record.attrs # NIL));
			Dates.FormatDateTime("yyyy-mm-ddThh:nn:ssZ", record.time, timestamp);
			IF json THEN
				writer.String('{"time":'); WriteString(writer, timestamp);
				writer.String(',"level":'); WriteString(writer, LevelName(record.level)^);
				writer.String(',"msg":'); WriteString(writer, record.message^);
				writer.String(',"attrs":{')
			ELSE
				writer.String("time="); writer.String(timestamp);
				writer.String(" level="); writer.String(LevelName(record.level)^);
				writer.String(" msg="); WriteString(writer, record.message^)
			END;
			FOR i := 0 TO LEN(record.attrs^) - 1 DO
				IF json THEN
					IF i > 0 THEN writer.Char(",") END;
					WriteString(writer, record.attrs[i].key^); writer.Char(":")
				ELSE
					writer.Char(" "); key := Strings.ConcatToNew("attrs.", record.attrs[i].key^);
					WriteKey(writer, key^); writer.Char("=")
				END;
				WriteValue(writer, record.attrs[i])
			END;
			IF json THEN writer.String("}}") END;
			writer.Ln; writer.Update;
			RETURN writer.res
		END Handle;
	END StreamHandler;

	Logger* = OBJECT
	VAR handler: Handler; attributes: Attrs;

		PROCEDURE &Init*(handler: Handler);
		BEGIN
			ASSERT(handler # NIL); SELF.handler := handler;
		END Init;

		(** With copies attributes into a new logger so the parent stays safe to share. *)
		PROCEDURE With*(CONST attrs: ARRAY OF Attr): Logger;
		VAR child: Logger;
		BEGIN
			NEW(child, handler); child.attributes := Merge(attributes, attrs);
			RETURN child
		END With;

		PROCEDURE Enabled*(level: SIGNED32): BOOLEAN;
		BEGIN RETURN handler.Enabled(level) END Enabled;

		(** Log filters before allocating a record and returns the handler's output error. *)
		PROCEDURE Log*(level: SIGNED32; CONST message: ARRAY OF CHAR; CONST attrs: ARRAY OF Attr): SIGNED32;
		VAR record: Record;
		BEGIN
			IF ~Enabled(level) THEN RETURN Streams.Ok END;
			record.time := Dates.Now(); Dates.AddMinutes(record.time, -Clock.tz); record.level := level;
			record.message := Strings.NewString(message); record.attrs := Merge(attributes, attrs);
			RETURN handler.Handle(record)
		END Log;

		PROCEDURE Debug*(CONST message: ARRAY OF CHAR): SIGNED32;
		BEGIN RETURN Log(LevelDebug, message, empty^) END Debug;

		PROCEDURE Info*(CONST message: ARRAY OF CHAR): SIGNED32;
		BEGIN RETURN Log(LevelInfo, message, empty^) END Info;

		PROCEDURE Warn*(CONST message: ARRAY OF CHAR): SIGNED32;
		BEGIN RETURN Log(LevelWarn, message, empty^) END Warn;

		PROCEDURE Error*(CONST message: ARRAY OF CHAR): SIGNED32;
		BEGIN RETURN Log(LevelError, message, empty^) END Error;
	END Logger;

VAR empty: Attrs;

(** Merge lets later attributes replace earlier values without retaining the caller's array. *)
PROCEDURE Merge(base: Attrs; CONST added: ARRAY OF Attr): Attrs;
VAR work, result: Attrs; attr: Attr; n, count, i, j: SIZE;
BEGIN
	n := 0; IF base # NIL THEN n := LEN(base^) END;
	NEW(work, n + LEN(added)); count := 0;
	FOR i := 0 TO n + LEN(added) - 1 DO
		IF i < n THEN attr := base[i] ELSE attr := added[i - n] END;
		ASSERT((attr.key # NIL) & (attr.kind >= TextValue) & (attr.kind <= FloatValue));
		attr.key := Strings.NewString(attr.key^);
		IF attr.kind = TextValue THEN ASSERT(attr.text # NIL); attr.text := Strings.NewString(attr.text^) END;
		j := 0;
		WHILE (j < count) & (work[j].key^ # attr.key^) DO INC(j) END;
		work[j] := attr;
		IF j = count THEN INC(count) END
	END;
	NEW(result, count);
	FOR i := 0 TO count - 1 DO result[i] := work[i] END;
	RETURN result
END Merge;

PROCEDURE String*(CONST key, value: ARRAY OF CHAR): Attr;
VAR attr: Attr;
BEGIN
	attr.key := Strings.NewString(key); attr.kind := TextValue; attr.text := Strings.NewString(value);
	RETURN attr
END String;

PROCEDURE Int*(CONST key: ARRAY OF CHAR; value: SIGNED64): Attr;
VAR attr: Attr;
BEGIN
	attr.key := Strings.NewString(key); attr.kind := IntValue; attr.integer := value;
	RETURN attr
END Int;

PROCEDURE UInt*(CONST key: ARRAY OF CHAR; value: UNSIGNED64): Attr;
VAR attr: Attr;
BEGIN
	attr.key := Strings.NewString(key); attr.kind := UIntValue; attr.unsigned := value;
	RETURN attr
END UInt;

PROCEDURE Bool*(CONST key: ARRAY OF CHAR; value: BOOLEAN): Attr;
VAR attr: Attr;
BEGIN
	attr.key := Strings.NewString(key); attr.kind := BoolValue; attr.boolean := value;
	RETURN attr
END Bool;

PROCEDURE Float*(CONST key: ARRAY OF CHAR; value: FLOAT64): Attr;
VAR attr: Attr;
BEGIN
	attr.key := Strings.NewString(key); attr.kind := FloatValue; attr.real := value;
	RETURN attr
END Float;

(** NewTextHandler writes one escaped key=value record per line to a dedicated writer. *)
PROCEDURE NewTextHandler*(writer: Streams.Writer; minimum := LevelInfo: SIGNED32): StreamHandler;
VAR handler: StreamHandler;
BEGIN NEW(handler, writer, minimum, FALSE); RETURN handler END NewTextHandler;

(** NewJSONHandler nests attributes so their names cannot replace record metadata. *)
PROCEDURE NewJSONHandler*(writer: Streams.Writer; minimum := LevelInfo: SIGNED32): StreamHandler;
VAR handler: StreamHandler;
BEGIN NEW(handler, writer, minimum, TRUE); RETURN handler END NewJSONHandler;

PROCEDURE LevelName(level: SIGNED32): Strings.String;
VAR name: ARRAY 32 OF CHAR;
BEGIN
	CASE level OF
		LevelDebug: name := "DEBUG" | LevelInfo: name := "INFO"
		| LevelWarn: name := "WARN" | LevelError: name := "ERROR"
	ELSE Strings.IntToStr(level, name)
	END;
	RETURN Strings.NewString(name)
END LevelName;

PROCEDURE WriteString(writer: Streams.Writer; CONST text: ARRAY OF CHAR);
BEGIN JSON.Write(writer, JSON.NewString(text)) END WriteString;

PROCEDURE WriteKey(writer: Streams.Writer; CONST key: ARRAY OF CHAR);
VAR i: SIZE; quote: BOOLEAN;
BEGIN
	i := 0; quote := FALSE;
	WHILE (i < LEN(key)) & (key[i] # 0X) DO
		IF (key[i] <= " ") OR (key[i] = 22X) OR (key[i] = 5CX) OR (key[i] = "=") THEN quote := TRUE END;
		INC(i)
	END;
	IF quote THEN WriteString(writer, key) ELSE writer.String(key) END
END WriteKey;

(** WriteValue keeps 64-bit integers exact and makes non-finite floats valid JSON strings. *)
PROCEDURE WriteValue(writer: Streams.Writer; CONST attr: Attr);
BEGIN
	CASE attr.kind OF
		TextValue: WriteString(writer, attr.text^)
		| IntValue: writer.Int(attr.integer, 0)
		| UIntValue: writer.UInt(attr.unsigned, 0)
		| BoolValue: IF attr.boolean THEN writer.String("true") ELSE writer.String("false") END
		| FloatValue:
			IF attr.real # attr.real THEN WriteString(writer, "NaN")
			ELSIF attr.real > MAX(FLOAT64) THEN WriteString(writer, "+Inf")
			ELSIF attr.real < MIN(FLOAT64) THEN WriteString(writer, "-Inf")
			ELSE JSON.Write(writer, JSON.NewNumber(attr.real))
			END
	END
END WriteValue;

BEGIN NEW(empty, 0)
END Logging.
