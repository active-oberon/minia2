MODULE GPIO;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "The pins of a board, from a program: the kernel's GPIO character device"; *)

(*	A board's pins are a device file -- /dev/gpiochip0 -- and three ioctls on it: ask what the chip
	is, ask for a set of lines, then read or write their values. That is the whole of making a pin
	do something physical, and it is the whole of this module.

	Nothing is loaded and nothing is linked: `libgpiod` is a runtime dependency for what fits on one
	page, and /sys/class/gpio has been deprecated in the kernel since 4.8 and costs a file open per
	read. The interface here is the character device's **v2** ABI, the one the kernel's own header
	calls current -- kernel 5.10 and later, so every Raspberry Pi OS since Bullseye.

	Values are a SET, because that is what v2 hands over: one bit per line, in the order the lines
	were asked for. So `0 IN values` is the first line of the request whatever pin it sits on, and
	INCL/EXCL write them. A program that thinks in pin numbers keeps its own table.

	A request outlives the chip: the kernel hands back a descriptor of its own, so the chip is
	opened and closed inside a call here and only `Lines` has to be closed by the program.

	Every record below has to have the layout of the kernel's struct, and no compiler anywhere
	checks that: `tests/GPIO.Test` asserts each size and offset against what a C program measures
	on the same machine. The ioctl numbers are not written down at all -- they are derived from
	SIZEOF the way <asm/ioctl.h> derives them, so a record that changes size cannot go on carrying
	a number that fitted the old one. *)

IMPORT Unix, Strings;

CONST
	(** the direction and the electrics of a line, at the bits gpio_v2_line_flag gives them *)
	Input* = {2};  Output* = {3};  ActiveLow* = {1};
	OpenDrain* = {6};  OpenSource* = {7};
	PullUp* = {8};  PullDown* = {9};  NoBias* = {10};

	MaxLines* = 64;					(** GPIO_V2_LINES_MAX: as many lines as one request holds *)

	NameSize = 32;					(* GPIO_MAX_NAME_SIZE *)
	MaxAttributes = 10;				(* GPIO_V2_LINE_NUM_ATTRS_MAX *)

TYPE
	(* struct gpiochip_info *)
	ChipInfo = RECORD
		name: ARRAY NameSize OF CHAR;
		label: ARRAY NameSize OF CHAR;
		lines: UNSIGNED32;
	END;

	(* struct gpio_v2_line_attribute -- value is the union: flags, output values or a debounce *)
	Attribute = RECORD
		id: UNSIGNED32;
		padding: UNSIGNED32;
		value: UNSIGNED64;
	END;

	(* struct gpio_v2_line_config_attribute *)
	ConfigAttribute = RECORD
		attr: Attribute;
		mask: UNSIGNED64;
	END;

	(* struct gpio_v2_line_config *)
	Config = RECORD
		flags: SET64;
		numAttrs: UNSIGNED32;
		padding: ARRAY 5 OF UNSIGNED32;
		attrs: ARRAY MaxAttributes OF ConfigAttribute;
	END;

	(* struct gpio_v2_line_request *)
	LineRequest = RECORD
		offsets: ARRAY MaxLines OF UNSIGNED32;
		consumer: ARRAY NameSize OF CHAR;
		config: Config;
		numLines: UNSIGNED32;
		eventBufferSize: UNSIGNED32;
		padding: ARRAY 5 OF UNSIGNED32;
		fd: SIGNED32;
	END;

	(* struct gpio_v2_line_values *)
	LineValues = RECORD
		bits: SET64;
		mask: SET64;
	END;

CONST
	(*	_IOR and _IOWR of <asm/ioctl.h>: the direction in the top two bits, the size of the
		argument in the next fourteen, then the device's letter and the number of the call. Both
		directions written as negative numbers, because that is what a 32-bit ioctl request is. *)
	DirRead = -80000000H;  DirReadWrite = -40000000H;  Gpio = 0B4H * 100H;

	GetChipInfo = DirRead + SIZEOF(ChipInfo) * 10000H + Gpio + 01H;
	GetLine = DirReadWrite + SIZEOF(LineRequest) * 10000H + Gpio + 07H;
	GetValues = DirReadWrite + SIZEOF(LineValues) * 10000H + Gpio + 0EH;
	SetValues = DirReadWrite + SIZEOF(LineValues) * 10000H + Gpio + 0FH;

VAR
	(**	Why the last call that failed did: the C errno. 13 (EACCES) is the usual one and means the
		program is not in the group that owns /dev/gpiochip*, 2 (ENOENT) that there is no such
		chip, 16 (EBUSY) that another program is holding the line. One variable for the module, not
		one per thread as C's own errno is: two threads driving pins at once read each other's. *)
	error-: SIGNED32;

	(*	never assigned: a global is zeroed when the module is loaded, and the kernel rejects a
		request whose padding is not zero, while a local record here is whatever the stack held *)
	empty: LineRequest;

TYPE
	(**	The lines a program asked for and may now read or write. Bit i is the i-th line of the
		request. Close gives them back to the kernel; a program that forgets holds them until it
		ends. *)
	Lines* = OBJECT
	VAR
		fd: SIGNED32;
		all: SET64;					(* every line of the request -- the mask each ioctl wants *)

		PROCEDURE & Init (descriptor: SIGNED32; count: SIZE);
		VAR i: SIZE;
		BEGIN
			fd := descriptor; all := {};
			FOR i := 0 TO count - 1 DO INCL(all, i) END
		END Init;

		(** What the lines are at this moment. An output line reads back what was written to it. *)
		PROCEDURE Read* (VAR values: SET64): BOOLEAN;
		VAR v: LineValues;
		BEGIN
			v.mask := all; v.bits := {};
			IF Unix.ioctl(fd, GetValues, ADDRESSOF(v)) # 0 THEN error := Unix.errno(); RETURN FALSE END;
			values := v.bits; RETURN TRUE
		END Read;

		(** Drive every line of the request: in the set is high, out of it is low. *)
		PROCEDURE Write* (values: SET64): BOOLEAN;
		VAR v: LineValues;
		BEGIN
			v.mask := all; v.bits := values * all;
			IF Unix.ioctl(fd, SetValues, ADDRESSOF(v)) # 0 THEN error := Unix.errno(); RETURN FALSE END;
			RETURN TRUE
		END Write;

		PROCEDURE Close*;
		VAR ignore: SIGNED32;
		BEGIN
			IF fd >= 0 THEN ignore := Unix.close(fd); fd := -1 END
		END Close;

	END Lines;

	(* Open -- the chip on its own, so that a failure to open one is reported in a single place *)
	PROCEDURE Open (chip: SIGNED32): SIGNED32;
	VAR path: ARRAY NameSize OF CHAR;  number: ARRAY 16 OF CHAR;  fd: SIGNED32;
	BEGIN
		COPY("/dev/gpiochip", path); Strings.IntToStr(chip, number); Strings.Append(path, number);
		fd := Unix.open(ADDRESSOF(path), Unix.rdwr, 0);
		IF fd < 0 THEN error := Unix.errno() END;
		RETURN fd
	END Open;

	(**	What the chip is: the driver's name for it (gpiochip0), the board's own label
		(pinctrl-bcm2835) and how many lines it has. The one call here that changes nothing, so it
		is what a program asks first to find out whether it is talking to a board at all. *)
	PROCEDURE Info* (chip: SIGNED32; VAR name, label: ARRAY OF CHAR; VAR lines: SIGNED32): BOOLEAN;
	VAR info: ChipInfo;  fd, ignore: SIGNED32;
	BEGIN
		fd := Open(chip);
		IF fd < 0 THEN RETURN FALSE END;
		IF Unix.ioctl(fd, GetChipInfo, ADDRESSOF(info)) # 0 THEN
			error := Unix.errno(); ignore := Unix.close(fd); RETURN FALSE
		END;
		ignore := Unix.close(fd);
		COPY(info.name, name); COPY(info.label, label); lines := SIGNED32(info.lines);
		RETURN TRUE
	END Info;

	(**	Ask the kernel for these lines of this chip, all of them with the same flags, and hold them
		under this label -- the name other programs and `gpioinfo` see. NIL if the kernel refused,
		and `error` says why. *)
	PROCEDURE Request* (chip: SIGNED32; CONST offsets: ARRAY OF SIGNED32; flags: SET64;
										CONST label: ARRAY OF CHAR): Lines;
	VAR request: LineRequest;  fd, ignore: SIGNED32;  i: SIZE;  lines: Lines;
	BEGIN
		IF (LEN(offsets) = 0) OR (LEN(offsets) > MaxLines) THEN
			error := 22;				(* EINVAL, the same answer the kernel would give *)
			RETURN NIL
		END;
		fd := Open(chip);
		IF fd < 0 THEN RETURN NIL END;
		request := empty;
		FOR i := 0 TO LEN(offsets) - 1 DO request.offsets[i] := UNSIGNED32(offsets[i]) END;
		Strings.AppendX(request.consumer, label);	(* a label longer than the field is cut, not written past *)
		request.config.flags := flags;
		request.numLines := UNSIGNED32(LEN(offsets));
		IF Unix.ioctl(fd, GetLine, ADDRESSOF(request)) # 0 THEN
			error := Unix.errno(); ignore := Unix.close(fd); RETURN NIL
		END;
		ignore := Unix.close(fd);						(* the request carries a descriptor of its own now *)
		NEW(lines, request.fd, LEN(offsets));
		RETURN lines
	END Request;

	(**	One line, which is the whole of a blinking LED or a button:
		`led := GPIO.Line(0, 17, GPIO.Output, "blink")`, then `led.Write({0})`. *)
	PROCEDURE Line* (chip, offset: SIGNED32; flags: SET64; CONST label: ARRAY OF CHAR): Lines;
	VAR one: ARRAY 1 OF SIGNED32;
	BEGIN
		one[0] := offset; RETURN Request(chip, one, flags, label)
	END Line;

END GPIO.
