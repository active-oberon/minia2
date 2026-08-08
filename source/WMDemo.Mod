MODULE WMDemo;	(** AUTHOR ""; PURPOSE "A window of A2's own window manager, and the check of one without a screen"; *)

(*
	What DisplayDemo is to a display driver, this is to the window manager above it.

	DisplayDemo draws into a Displays.Display and owns the whole screen while it does. That answers
	for the driver and for nothing else: a picture on a phone drawn by one module that owns the frame
	buffer is a picture, not a system. This module opens a window in `WindowManager` -- the real one,
	the one with a background, decoration, a pointer and an event loop -- so that what is on the
	screen is A2's window manager and not a demo wearing its colours.

	The check below is the same trick DisplayDemo.Check plays, one layer up: a display that is
	nothing but memory, the window manager brought up over it, a window opened in it, and then the
	frame buffer read back and printed coarsely. It needs no screen and no window, so the machine
	that has neither can still answer for the whole stack -- Raster, WMGraphics, the font, the
	decoration, the compositing in WindowManager -- which is all of it except the last copy into
	ANativeWindow, and that copy is what tests/display-check.sh already covers.

	The picture settles by itself and not on a timer: the window manager paints on a thread of its
	own, so Check reads the frame buffer until two consecutive reads agree, rather than sleeping for
	a number somebody guessed on one machine.
*)

IMPORT
	SYSTEM, Trace, Objects, Plugins, Displays, Strings, Inputs,
	Rect := WMRectangles, WMGraphics, WMDefaultFont, WM := WMWindowManager, WindowManager;

CONST
	(*	The window, and where it sits. Anything that decides what lands in the frame buffer is a
		constant here, because the recorded picture in tests/wm-expected.txt is a function of all of
		them. *)
	Width = 520;  Height = 300;
	Left = 120;  Top = 260;

	Panel = SIGNED32(0F0F4F8FFH);		(* the paper the window is drawn on *)
	Ink = SIGNED32(0102030FFH);
	Accent = SIGNED32(0E06020FFH);

	(*	The check's display and its background: a phone in portrait, and the window manager's own
		default blue, so that what the check draws is what the phone draws. *)
	CheckWidth = 1080;  CheckHeight = 2340;
	CheckBackground = SIGNED32(8080FFFFH);

	Columns = 78;  Lines = 30;			(* the coarse picture, the shape display-check.sh also prints *)
	SettleMilliseconds = 50;  SettleTries = 200;

TYPE
	Window = OBJECT (WM.BufferWindow)
	VAR
		typed: ARRAY 96 OF CHAR;		(* what has been typed into it, and nothing more *)
		filled: SIZE;

		PROCEDURE &New*;
		BEGIN
			typed := "";  filled := 0;
			Init(Width, Height, FALSE);
			Paint;
			SetTitle(Strings.NewString("A2"));
			WM.AddWindow(SELF, Left, Top)
		END New;

		(*	The keyboard, arriving the way every other key in A2 arrives: the window manager hands the
			focused window a character, an X11 keysym and the modifiers, and where they came from -- a
			soft keyboard on a phone, an X server, a PS/2 controller on a bare board -- is not a question
			this procedure can ask. That is the point of doing it in `Inputs` rather than in the
			application: nothing above the driver is Android-specific, and this same window would take
			typing from any of the three.

			Releases are ignored: a character arrives on the way down, and a window that acted on both
			would type everything twice. *)
		PROCEDURE KeyEvent*(ucs: SIZE; flags: SET; keysym: SIZE);
		BEGIN
			IF Inputs.Release IN flags THEN RETURN END;
			IF keysym = Inputs.KsBackSpace THEN
				IF filled > 0 THEN DEC(filled);  typed[filled] := 0X END
			ELSIF (keysym = Inputs.KsReturn) OR (keysym = Inputs.KsEscape) THEN
				filled := 0;  typed[0] := 0X
			ELSIF (ucs >= 20H) & (ucs < 7FH) & (filled < LEN(typed) - 1) THEN
				typed[filled] := CHR(ucs);  INC(filled);  typed[filled] := 0X
			ELSE
				RETURN									(* nothing changed, so nothing is redrawn *)
			END;
			Paint
		END KeyEvent;

		(*	Everything the window shows, at once.

			The font is asked for by name and not taken from the canvas: the one compiled into
			WMDefaultFont, which is the one a machine with no fonts on disk has. That is the phone --
			and it is also what makes the recorded picture below the same picture on the desktop, where
			the font manager finds the OpenType fonts in data/ and would otherwise draw these three
			lines differently on every machine. It is exercised rather than avoided: if that fallback
			stopped working the window would come up blank, and blank is what the record catches. *)
		PROCEDURE Paint;
		VAR font: WMGraphics.Font;  y, dx, dy, line, prompt, caret: SIZE;
		BEGIN
			canvas.Fill(Rect.MakeRect(0, 0, Width, Height), Panel, WMGraphics.ModeCopy);
			canvas.Fill(Rect.MakeRect(0, 0, Width, 4), Accent, WMGraphics.ModeCopy);

			font := WMDefaultFont.LoadDefaultFont();
			IF font # NIL THEN canvas.SetFont(font) ELSE font := canvas.GetFont() END;
			canvas.SetColor(Ink);
			font.GetStringSize("Ag", dx, line);
			y := 40;
			canvas.DrawString(24, y, "Active Oberon / A2");  INC(y, line + 6);
			canvas.DrawString(24, y, "window manager, on this machine");  INC(y, line + 6);
			canvas.DrawString(24, y, "drag me by the title bar, then type");  INC(y, line + 12);

			(*	The typed line, with a caret drawn rather than blinked: a blinking caret wants a timer,
				and the only thing this one has to say is that a key arrived. *)
			font.GetStringSize("> ", prompt, dy);
			font.GetStringSize(typed, caret, dy);
			canvas.DrawString(24, y, "> ");
			canvas.DrawString(24 + prompt, y, typed);
			canvas.Fill(Rect.MakeRect(24 + prompt + caret, y - line + 3, 24 + prompt + caret + 2, y + 3),
				Accent, WMGraphics.ModeCopy);

			(*	A frame and both diagonals: the same geometry tests/display-check.sh reads off a
				photograph, here inside a window, where a wrong stride or a wrong offset bends it. *)
			canvas.Line(0, 0, Width - 1, 0, Ink, WMGraphics.ModeCopy);
			canvas.Line(0, Height - 1, Width - 1, Height - 1, Ink, WMGraphics.ModeCopy);
			canvas.Line(0, 0, 0, Height - 1, Ink, WMGraphics.ModeCopy);
			canvas.Line(Width - 1, 0, Width - 1, Height - 1, Ink, WMGraphics.ModeCopy);
			canvas.Line(0, 0, Width - 1, Height - 1, Accent, WMGraphics.ModeCopy);
			canvas.Line(0, Height - 1, Width - 1, 0, Accent, WMGraphics.ModeCopy);

			Invalidate(Rect.MakeRect(0, 0, Width, Height))
		END Paint;

		(*	Closed from the decoration -- the red square -- and not through Close below, so this is where
			the module finds out. Without it a window shut with a finger leaves the variable pointing at
			it, and Open answers "already open" about a window that is not there any more. *)
		PROCEDURE Close*;
		BEGIN
			Close^;
			window := NIL;
			Trace.StringLn("WMDemo: window closed")
		END Close;

	END Window;

	(*	A display that is nothing but memory, as in DisplayDemo -- the same shape, because the same
		thing is being asked: what did the layer above actually write. *)
	Memory = OBJECT (Displays.Display)
	VAR pixels: POINTER TO ARRAY OF CHAR;

		PROCEDURE &Init*(w, h: SIGNED32);
		BEGIN
			width := w;  height := h;  offscreen := 0;
			format := Displays.color8888;  unit := 10000;
			NEW(pixels, w * h * 4);
			InitFrameBuffer(ADDRESSOF(pixels[0]), w * h * 4, w * 4)
		END Init;

	END Memory;

VAR
	window: Window;

(** Open the window. Wants a window manager already up -- WindowManager.Install puts one there. *)
PROCEDURE Open*;
BEGIN
	IF window # NIL THEN Trace.StringLn("WMDemo: the window is already open");  RETURN END;
	NEW(window);
	Trace.StringLn("WMDemo: window open")
END Open;

(** Close it again, so that opening twice is a thing that can be tried. *)
PROCEDURE Close*;
BEGIN
	IF window # NIL THEN window.Close END			(* which clears the variable, see the method *)
END Close;

(*	A number that changes when the picture does. Every pixel, so that a difference anywhere moves it;
	it says nothing about what the picture is, only that it has stopped being drawn. *)
PROCEDURE Sum(memory: Memory): SIGNED32;
VAR adr, last: ADDRESS;  word, total: SIGNED32;
BEGIN
	total := 0;
	adr := ADDRESSOF(memory.pixels[0]);
	last := adr + SIZE(memory.width) * SIZE(memory.height) * 4;
	WHILE adr < last DO
		SYSTEM.GET(adr, word);
		total := total * 31 + word;
		INC(adr, 4 * 64)						(* every sixty-fourth pixel: enough to move, cheap to read *)
	END;
	RETURN total
END Sum;

(*	Wait until two reads of the frame buffer agree. Returns how long that took, in tries, or -1 if it
	never did -- which is a result too, and a more useful one than a picture caught mid-paint. *)
PROCEDURE Settle(memory: Memory): SIGNED32;
VAR previous, now, tries: SIGNED32;
BEGIN
	previous := Sum(memory) + 1;  tries := 0;
	WHILE tries < SettleTries DO
		Objects.Sleep(SettleMilliseconds);
		now := Sum(memory);
		IF now = previous THEN RETURN tries END;
		previous := now;  INC(tries)
	END;
	RETURN -1
END Settle;

(*	A rectangle of pixels, printed as Columns by Lines characters -- the same four the display check
	prints, and picked out of a transcript by the same rule. Four levels of brightness rather than a
	comparison against particular colours: what is being recorded is a shape. *)
PROCEDURE Print(adr: ADDRESS; bpr: SIZE; w, h: SIZE);
VAR px, py: SIGNED32;  colour, level: SIGNED32;
BEGIN
	FOR py := 0 TO Lines - 1 DO
		FOR px := 0 TO Columns - 1 DO
			SYSTEM.GET(adr + (SIZE(py) * h DIV Lines) * bpr + (SIZE(px) * w DIV Columns) * 4, colour);
			(*	Green weighs most in what an eye calls brightness, and here it also happens to be what
				separates the blue background from the pale window. *)
			level := ASH(colour, -8) MOD 256;
			IF level < 64 THEN Trace.Char("#")
			ELSIF level < 128 THEN Trace.Char("+")
			ELSIF level < 224 THEN Trace.Char(".")
			ELSE Trace.Char(" ")
			END
		END;
		Trace.Ln
	END
END Print;

(*	Where the window landed on the screen, said as two numbers rather than as a picture.

	The screen cannot be compared against a record the way the window's own image can: the title bar
	is drawn by the decoration, in whatever font the machine found on disk, and a desktop with the
	OpenType fonts in data/ draws it differently from a phone with none. So what is recorded of the
	screen is not its picture but this: strictly inside the window's bounds, below the decoration, the
	panel colour and nothing else; well clear of the decoration, the background and nothing else.
	Both are counted as `so many of so many`, so that either one falling short is a number and not a
	judgement: compositing in the wrong place moves the first, a window drawn over the whole screen
	moves the second.

	Clear of the decoration means Clearance pixels, and that is not a guess about how wide a border
	is: the title bar sits above the window and the frame around it, so points nearer than that
	belong to neither answer and are counted in neither. *)
PROCEDURE Placement(memory: Memory; VAR inside, insideOf, outside, outsideOf: SIGNED32);
CONST Step = 8;  Clearance = 64;
VAR x, y: SIGNED32;  background: SIGNED32;

	PROCEDURE At(x, y: SIGNED32): SIGNED32;
	VAR colour: SIGNED32;
	BEGIN
		SYSTEM.GET(ADDRESSOF(memory.pixels[0]) + SIZE(y) * memory.width * 4 + SIZE(x) * 4, colour);
		RETURN colour
	END At;

BEGIN
	(*	The background is read off the screen rather than taken from the constant the manager was
		given: what is painted is that colour composited, and the word in the frame buffer is
		therefore not the word that was asked for. A corner far from the window is the background by
		construction -- the window is 520 by 300 at 120, 260 on a screen of 1080 by 2340. *)
	background := At(CheckWidth - 8, CheckHeight - 8);
	inside := 0;  insideOf := 0;  outside := 0;  outsideOf := 0;
	y := 0;
	WHILE y < CheckHeight DO
		x := 0;
		WHILE x < CheckWidth DO
			IF (x >= Left + Step) & (x < Left + Width - Step) & (y >= Top + Step) & (y < Top + Height - Step) THEN
				(*	The diagonals cross the panel, so a point counts as the window if it is anything but
					the background -- what is asked is which window owns the pixel, not what it drew. *)
				INC(insideOf);
				IF At(x, y) # background THEN INC(inside) END
			ELSIF (x < Left - Clearance) OR (x >= Left + Width + Clearance)
					OR (y < Top - Clearance) OR (y >= Top + Height + Clearance) THEN
				INC(outsideOf);
				IF At(x, y) = background THEN INC(outside) END
			END;
			INC(x, Step)
		END;
		INC(y, Step)
	END
END Placement;

(**	Bring the window manager up over a display that is nothing but memory, open the window in it, and
	print what landed in the frame buffer. No screen, no window, no device. *)
PROCEDURE Check*;
VAR memory: Memory;  res: INTEGER;  tries, inside, insideOf, outside, outsideOf: SIGNED32;
BEGIN
	NEW(memory, CheckWidth, CheckHeight);
	memory.SetName("WMDemoMemory");
	memory.desc := "A display that is nothing but memory, for checking the window manager";
	Displays.registry.Add(memory, res);
	ASSERT(res = Plugins.Ok);

	(*	No pointer: the sprite is drawn wherever the pointer happens to be, and on a machine with no
		mouse that is a pixel nobody chose. Everything else is the default the phone gets. *)
	WindowManager.Replace(CheckBackground, TRUE, FALSE);
	Open;

	tries := Settle(memory);
	IF tries < 0 THEN
		Trace.StringLn("WMDemo: the picture never settled")
	ELSE
		Trace.String("WMDemo: the picture settled after ");  Trace.Int(tries, 0);
		Trace.String(" x ");  Trace.Int(SettleMilliseconds, 0);  Trace.StringLn(" ms")
	END;

	Placement(memory, inside, insideOf, outside, outsideOf);
	Trace.String("WMDemo: window ");  Trace.Int(inside, 0);  Trace.String(" of ");  Trace.Int(insideOf, 0);
	Trace.String(", background ");  Trace.Int(outside, 0);  Trace.String(" of ");  Trace.Int(outsideOf, 0);
	Trace.Ln;

	Print(ADDRESSOF(memory.pixels[0]), SIZE(memory.width) * 4, memory.width, memory.height);
	Print(window.img.adr, window.img.bpr, window.img.width, window.img.height)
END Check;

END WMDemo.
