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
	(*	Where the window sits and how much of the view it takes, as fractions of the view rather than as
		pixels. A pixel is not a size on a screen whose own pixel can be a quarter of a millimetre or a
		fifteenth: 520 by 300 is a comfortable window on a monitor and wider than the glass on a phone,
		and the window manager now zooms the view so that neither number means what it used to (see
		WindowManager.ZoomForUnit). What is fixed here is the shape -- a margin, a third of the height,
		a little way down -- and Fit below turns that into the numbers the window is made with. The
		recorded picture in tests/wm-expected.txt is a function of them and of the check's display. *)
	Margin = 12;  HeightPart = 3;  TopPart = 8;
	FallbackWidth = 520;  FallbackHeight = 300;			(* with no view to ask: the old constants *)
	FallbackLeft = 120;  FallbackTop = 260;

	Panel = SIGNED32(0F0F4F8FFH);		(* the paper the window is drawn on *)
	Ink = SIGNED32(0102030FFH);
	Accent = SIGNED32(0E06020FFH);

	(*	The check's display and its background: a phone in portrait, and the window manager's own
		default blue, so that what the check draws is what the phone draws.

		Including the pixel, and this exact number: 2177/36000 mm is what the phone this was written on
		reports -- 420 dots to the inch, out of AConfiguration by way of AndroidDisplay -- rather than the
		10000 of an ordinary screen. The window manager reads it and zooms by it, so a check that reported
		a monitor's pixel would be a check of the one path the phone never takes; reporting the phone's
		makes the window recorded below the window that is on the phone. (The glass measures nearer 2430 --
		2340 rows in some 158 mm -- and Android rounds its density into buckets. What matters here is being
		the same number the phone is given, not the truer one.) *)
	CheckWidth = 1080;  CheckHeight = 2340;
	CheckUnit = 2177;
	CheckBackground = SIGNED32(8080FFFFH);

	Columns = 78;  Lines = 30;			(* the coarse picture, the shape display-check.sh also prints *)
	SettleMilliseconds = 50;  SettleTries = 200;

TYPE
	Window = OBJECT (WM.BufferWindow)
	VAR
		typed: ARRAY 96 OF CHAR;		(* what has been typed into it, and nothing more *)
		filled: SIZE;
		w, h: SIZE;						(* what Fit made of the view: the window's own coordinates *)

		PROCEDURE &New*;
		VAR left, top: SIZE;
		BEGIN
			typed := "";  filled := 0;
			Fit(left, top, w, h);
			Init(w, h, FALSE);
			Paint;
			SetTitle(Strings.NewString("A2"));
			WM.AddWindow(SELF, left, top)
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
		CONST Inset = 12;
		BEGIN
			canvas.Fill(Rect.MakeRect(0, 0, w, h), Panel, WMGraphics.ModeCopy);
			canvas.Fill(Rect.MakeRect(0, 0, w, 4), Accent, WMGraphics.ModeCopy);

			font := WMDefaultFont.LoadDefaultFont();
			IF font # NIL THEN canvas.SetFont(font) ELSE font := canvas.GetFont() END;
			canvas.SetColor(Ink);
			font.GetStringSize("Ag", dx, line);
			y := line + 16;
			canvas.DrawString(Inset, y, "Active Oberon / A2");  INC(y, line + 6);
			canvas.DrawString(Inset, y, "window manager, on this");  INC(y, line + 6);
			canvas.DrawString(Inset, y, "machine. drag me, then type");  INC(y, line + 12);

			(*	The typed line, with a caret drawn rather than blinked: a blinking caret wants a timer,
				and the only thing this one has to say is that a key arrived. *)
			font.GetStringSize("> ", prompt, dy);
			font.GetStringSize(typed, caret, dy);
			canvas.DrawString(Inset, y, "> ");
			canvas.DrawString(Inset + prompt, y, typed);
			canvas.Fill(Rect.MakeRect(Inset + prompt + caret, y - line + 3, Inset + prompt + caret + 2, y + 3),
				Accent, WMGraphics.ModeCopy);

			(*	A frame and both diagonals: the same geometry tests/display-check.sh reads off a
				photograph, here inside a window, where a wrong stride or a wrong offset bends it. *)
			canvas.Line(0, 0, w - 1, 0, Ink, WMGraphics.ModeCopy);
			canvas.Line(0, h - 1, w - 1, h - 1, Ink, WMGraphics.ModeCopy);
			canvas.Line(0, 0, 0, h - 1, Ink, WMGraphics.ModeCopy);
			canvas.Line(w - 1, 0, w - 1, h - 1, Ink, WMGraphics.ModeCopy);
			canvas.Line(0, 0, w - 1, h - 1, Accent, WMGraphics.ModeCopy);
			canvas.Line(0, h - 1, w - 1, 0, Accent, WMGraphics.ModeCopy);

			Invalidate(Rect.MakeRect(0, 0, w, h))
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
			format := Displays.color8888;  unit := CheckUnit;
			NEW(pixels, w * h * 4);
			InitFrameBuffer(ADDRESSOF(pixels[0]), w * h * 4, w * 4)
		END Init;

	END Memory;

VAR
	window: Window;

(*	How big the window is and where it goes, out of the view that is going to show it.

	The view is asked rather than assumed because it is no longer the screen: WindowManager zooms it by
	the size of the screen's pixel, so on a phone the coordinate space the window is opened in is a few
	hundred wide where the screen is 1080. A window made 520 wide would be two thirds off the glass --
	which is what happened, and it is the whole reason this procedure exists rather than four constants.

	Asking waits for a window manager to be installed, which is what AddWindow below does anyway -- this
	adds no way to hang that opening the window did not already have. The fallback is for a registry that
	hands back nothing: four constants are cheaper than a trap. *)
PROCEDURE Fit(VAR left, top, w, h: SIZE);
VAR view: WM.ViewPort;  availableW, availableH: SIZE;
BEGIN
	view := WM.GetDefaultView();
	IF view = NIL THEN
		left := FallbackLeft;  top := FallbackTop;  w := FallbackWidth;  h := FallbackHeight;  RETURN
	END;
	availableW := ENTIER(view.range.r - view.range.l);
	availableH := ENTIER(view.range.b - view.range.t);
	w := availableW - 2 * Margin;
	h := availableH DIV HeightPart;
	left := ENTIER(view.range.l) + Margin;
	top := ENTIER(view.range.t) + availableH DIV TopPart;
	Trace.String("WMDemo: the view shows ");  Trace.Int(availableW, 0);  Trace.String(" x ");
	Trace.Int(availableH, 0);  Trace.String(", so the window is ");  Trace.Int(w, 0);
	Trace.String(" x ");  Trace.Int(h, 0);  Trace.String(" at ");  Trace.Int(left, 0);
	Trace.String(", ");  Trace.Int(top, 0);  Trace.Ln
END Fit;

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

	Clear of the decoration means Clearance, and that is not a guess about how wide a border is: the
	title bar sits above the window and the frame around it, so points nearer than that belong to
	neither answer and are counted in neither.

	Where the window is on the screen is worked out and not written down. The window has bounds, but they
	are the window manager's coordinates, and the frame buffer this reads is the screen's -- and between
	the two there is now a zoom, which the view reports as its range. So both the rectangle and the
	clearance are put through it: at zoom 1 that is the arithmetic doing nothing and the numbers this
	procedure used to have as constants, and at the phone's zoom it is the only way it could be right. *)
PROCEDURE Placement(memory: Memory; VAR inside, insideOf, outside, outsideOf: SIGNED32);
CONST Step = 8;  Clearance = 64;
VAR x, y: SIGNED32;  background: SIGNED32;
	view: WM.ViewPort;  scale: FLOAT32;  left, top, right, bottom, clear: SIGNED32;

	PROCEDURE At(x, y: SIGNED32): SIGNED32;
	VAR colour: SIGNED32;
	BEGIN
		SYSTEM.GET(ADDRESSOF(memory.pixels[0]) + SIZE(y) * memory.width * 4 + SIZE(x) * 4, colour);
		RETURN colour
	END At;

BEGIN
	(*	The window's rectangle on the screen: its bounds, less the view's origin, times the zoom -- and
		the zoom is the screen divided by what the view shows, which is all the range says and all that is
		needed here. *)
	view := WM.GetDefaultView();
	scale := memory.width / (view.range.r - view.range.l);
	left := ENTIER((window.bounds.l - view.range.l) * scale);
	top := ENTIER((window.bounds.t - view.range.t) * scale);
	right := ENTIER((window.bounds.r - view.range.l) * scale);
	bottom := ENTIER((window.bounds.b - view.range.t) * scale);
	clear := ENTIER(Clearance * scale);
	Trace.String("WMDemo: on the screen the window is ");  Trace.Int(left, 0);  Trace.String(", ");
	Trace.Int(top, 0);  Trace.String(" to ");  Trace.Int(right, 0);  Trace.String(", ");
	Trace.Int(bottom, 0);  Trace.Ln;

	(*	The background is read off the screen rather than taken from the constant the manager was
		given: what is painted is that colour composited, and the word in the frame buffer is
		therefore not the word that was asked for. The corner furthest from the window is the background
		by construction -- the window sits a margin in from the left and an eighth of the way down. *)
	background := At(CheckWidth - 8, CheckHeight - 8);
	inside := 0;  insideOf := 0;  outside := 0;  outsideOf := 0;
	y := 0;
	WHILE y < CheckHeight DO
		x := 0;
		WHILE x < CheckWidth DO
			IF (x >= left + Step) & (x < right - Step) & (y >= top + Step) & (y < bottom - Step) THEN
				(*	The diagonals cross the panel, so a point counts as the window if it is anything but
					the background -- what is asked is which window owns the pixel, not what it drew. *)
				INC(insideOf);
				IF At(x, y) # background THEN INC(inside) END
			ELSIF (x < left - clear) OR (x >= right + clear)
					OR (y < top - clear) OR (y >= bottom + clear) THEN
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
