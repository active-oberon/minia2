MODULE DisplayDemo;	(** AUTHOR ""; PURPOSE "What a Displays driver looks like when it works: a picture and a moving thing"; *)

(*
	A first picture for a new display, and a moving one after it, so that a backend is asked both of
	the questions worth asking: does a frame arrive at all, and does the next one.

	Nothing here knows what it draws on. It takes whatever display is registered, writes lines through
	Displays.Transfer and rectangles through Fill, and calls Update when a frame is done -- so the same
	module is the check for the window of an Android application, for a linear frame buffer on a bare
	Raspberry Pi, and for anything else that ever registers.

	The Mandelbrot arithmetic is the one from RPIDemo, where it was written for a machine with no
	floating point at all: fixed point, one 64 bit multiply per step. Kept as it is because it costs
	nothing to keep and it makes the two demos comparable -- and because a display driver is a poor
	place to find out that the compiler's floating point is at fault.
*)

IMPORT SYSTEM, Displays, Plugins, Objects, Kernel, Trace;

CONST
	Fraction = 20;					(* fixed point: 12 integer bits, 20 fractional *)
	One = ASH(1, Fraction);
	MaxIter = 48;  Escape = 4 * One;

	FrameMilliseconds = 16;		(* what the animation aims at; what it gets is reported *)

TYPE
	Row = POINTER TO ARRAY OF CHAR;

	Animation = OBJECT
	VAR
		stop: BOOLEAN;
		x, y, dx, dy, size: SIGNED32;
		onWidth, onHeight: SIGNED32;		(* the shape of the display this was set up for *)
		under: POINTER TO ARRAY OF CHAR;	(* what the box covers, to put back when it moves on *)

		PROCEDURE &Init*(d: Displays.Display);
		BEGIN
			stop := FALSE;
			Fit(d)
		END Init;

		(*	Set up for the shape the display has now. Called again when it changes: a display can be
			turned sideways under a client -- a rotated window -- and A2 has no notification for it, so
			this is what noticing amounts to. *)
		PROCEDURE Fit(d: Displays.Display);
		BEGIN
			onWidth := d.width;  onHeight := d.height;
			size := d.width DIV 8;
			x := d.width DIV 3;  y := d.height DIV 3;
			dx := size DIV 6 + 1;  dy := dx + 1;
			IF (under = NIL) OR (LEN(under^) < size * size * 4) THEN NEW(under, size * size * 4) END
		END Fit;

		PROCEDURE Stop*;
		BEGIN {EXCLUSIVE}
			stop := TRUE
		END Stop;

		PROCEDURE Stopped( ): BOOLEAN;
		BEGIN {EXCLUSIVE}
			RETURN stop
		END Stopped;

	BEGIN {ACTIVE}
		(*	A box that bounces over whatever is already on the display, putting back what it covered
			rather than painting black behind itself -- which was the first version, and looked exactly
			like a broken driver: a black diagonal trail across the picture.

			Two things get measured here at once: that a second frame arrives at all, and what a frame
			costs. A backend that copies its whole buffer into a window pays for the whole screen every
			time, whatever the box costs, so the average is reported every so often. *)
		VAR frames, started: SIGNED32;
		frames := 0;  started := Kernel.GetTicks();
		display.Transfer(under^, 0, size * 4, x, y, size, size, Displays.get);
		display.Fill(0FFCC00H, x, y, size, size);
		WHILE ~Stopped() DO
			(*	The display turned sideways: the picture underneath is gone with the old shape, the box
				is somewhere that no longer exists, and what was saved beneath it belongs to neither. So
				everything is drawn again, and this is where a client finds out -- by asking. *)
			IF (display.width # onWidth) OR (display.height # onHeight) THEN
				Fit(display);
				DrawMandelbrot;
				display.Transfer(under^, 0, size * 4, x, y, size, size, Displays.get);
				display.Fill(0FFCC00H, x, y, size, size);
				display.Update;
				Trace.String("DisplayDemo: drawn again for ");
				Trace.Int(onWidth, 0);  Trace.String(" x ");  Trace.Int(onHeight, 0);  Trace.Ln
			END;
			display.Transfer(under^, 0, size * 4, x, y, size, size, Displays.set);	(* what was there *)
			INC(x, dx);  INC(y, dy);
			IF (x <= 0) OR (x + size >= display.width) THEN dx := -dx;  INC(x, 2 * dx) END;
			IF (y <= 0) OR (y + size >= display.height) THEN dy := -dy;  INC(y, 2 * dy) END;
			display.Transfer(under^, 0, size * 4, x, y, size, size, Displays.get);	(* what will be *)
			display.Fill(0FFCC00H, x, y, size, size);
			display.Update;
			INC(frames);
			IF frames MOD 120 = 0 THEN
				Trace.String("DisplayDemo: ");  Trace.Int(frames, 0);
				Trace.String(" frames, ");
				Trace.Int((Kernel.GetTicks() - started) DIV frames, 0);
				Trace.StringLn(" ms each including the wait")
			END;
			Objects.Sleep(FrameMilliseconds)
		END;
		Trace.StringLn("DisplayDemo: the animation stopped")
	END Animation;

VAR
	display: Displays.Display;
	row: Row;
	animation: Animation;

(*	Fixed point multiply. The intermediate wants more than 32 bits, so it is done in 64 and shifted
	back; DIV by a power of two floors, which is an arithmetic shift, and is right for negatives. *)
PROCEDURE Mul(a, b: SIGNED32): SIGNED32;
BEGIN
	RETURN SIGNED32(SIGNED64(a) * SIGNED64(b) DIV One)
END Mul;

PROCEDURE Take( ): BOOLEAN;
VAR plugin: Plugins.Plugin;
BEGIN
	plugin := Displays.registry.Get("");
	IF plugin = NIL THEN
		Trace.StringLn("DisplayDemo: no display registered");  RETURN FALSE
	END;
	display := plugin(Displays.Display);
	IF display.format # Displays.color8888 THEN
		Trace.String("DisplayDemo: this demo draws 32 bit pixels, and the display wants ");
		Trace.Int(display.format, 0);  Trace.StringLn(" bytes each");
		RETURN FALSE
	END;
	IF (row = NIL) OR (LEN(row^) < display.width * 4) THEN NEW(row, display.width * 4) END;
	RETURN TRUE
END Take;

(*	How long the point at c stays inside, up to MaxIter. The arithmetic and nothing else, so that the
	same answer can be asked for on a terminal (Ascii below) as on a display -- which is how a wrong
	picture is told from a wrong driver. *)
PROCEDURE Iterations(cr, ci: SIGNED32): SIGNED32;
VAR iter, zr, zi, zr2, zi2, t, q, dx: SIGNED32;
BEGIN
	(*	The analytic test for the main cardioid and the period-2 bulb. Interior points always run the
		full count, so skipping them is where the time is. *)
	dx := cr - One DIV 4;  q := Mul(dx, dx) + Mul(ci, ci);
	IF (Mul(q, q + dx) < Mul(ci, ci) DIV 4) OR (Mul(cr + One, cr + One) + Mul(ci, ci) < One DIV 16) THEN
		RETURN MaxIter
	END;
	zr := 0;  zi := 0;  iter := 0;
	LOOP
		zr2 := Mul(zr, zr);  zi2 := Mul(zi, zi);
		IF zr2 + zi2 > Escape THEN EXIT END;
		IF iter >= MaxIter THEN EXIT END;
		t := zr2 - zi2;
		zi := 2 * Mul(zr, zi) + ci;
		zr := t + cr;
		INC(iter)
	END;
	RETURN iter
END Iterations;

(*	One line of the set. Written into a row buffer and handed over in one call: a display is a device
	behind a lock, and a call per pixel would spend its time there rather than on the picture. *)
PROCEDURE MandelbrotLine(py, originX, originY, scaleX, scaleY: SIGNED32);
VAR px, iter, colour: SIGNED32;  ci: SIGNED32;
BEGIN
	ci := (py - originY) * scaleY;
	FOR px := 0 TO display.width - 1 DO
		iter := Iterations((px - originX) * scaleX, ci);
		IF iter >= MaxIter THEN
			colour := 0												(* inside the set *)
		ELSE														(* bands outside it *)
			colour := ASH(iter * 4 MOD 256, 16) + ASH(iter * 9 MOD 256, 8) + (128 + iter * 2 MOD 128)
		END;
		SYSTEM.PUT32(ADDRESSOF(row[0]) + px * 4, colour)
	END;
	display.Transfer(row^, 0, display.width * 4, 0, py, display.width, 1, Displays.set)
END MandelbrotLine;

(*	A display that is nothing but memory, for asking what was drawn without a screen to look at. *)
TYPE
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

(**	Draw the set at the size a phone screen has and print what landed in the frame buffer, coarsely.
	The picture and the arithmetic fail in ways that look alike on a screen, and this is the one that
	needs no screen: the shape below must be the shape Ascii prints. *)
PROCEDURE Check*;
CONST Columns = 78;  Lines = 30;
VAR memory: Memory;  saved: Displays.Display;  px, py, colour: SIGNED32;
BEGIN
	saved := display;
	NEW(memory, 1080, 2340);
	display := memory;
	IF (row = NIL) OR (LEN(row^) < display.width * 4) THEN NEW(row, display.width * 4) END;
	DrawMandelbrot;
	FOR py := 0 TO Lines - 1 DO
		FOR px := 0 TO Columns - 1 DO
			SYSTEM.GET(ADDRESSOF(memory.pixels[0])
				+ (SIZE(py) * memory.height DIV Lines) * memory.width * 4
				+ (SIZE(px) * memory.width DIV Columns) * 4, colour);
			IF colour = 0 THEN Trace.Char("#")
			ELSIF colour MOD 256 > 140 THEN Trace.Char("+")
			ELSE Trace.Char(".")
			END
		END;
		Trace.Ln
	END;
	display := saved
END Check;

(**	The same set on a terminal, 78 by 30. Here because the arithmetic and the driver fail in ways
	that look alike on a screen: this says which of the two it was, and it runs anywhere. *)
PROCEDURE Ascii*;
CONST Columns = 78;  Lines = 30;
	ScaleX = 3 * One DIV Columns;  ScaleY = 5 * One DIV (2 * Lines);
	OriginX = Columns * 3 DIV 4;  OriginY = Lines DIV 2;
VAR px, py, iter: SIGNED32;
BEGIN
	FOR py := 0 TO Lines - 1 DO
		FOR px := 0 TO Columns - 1 DO
			iter := Iterations((px - OriginX) * ScaleX, (py - OriginY) * ScaleY);
			IF iter >= MaxIter THEN Trace.Char("#")
			ELSIF iter > 8 THEN Trace.Char("+")
			ELSIF iter > 3 THEN Trace.Char(".")
			ELSE Trace.Char(" ")
			END
		END;
		Trace.Ln
	END
END Ascii;

(*	The set over the whole of whatever display is current, and nothing else -- no timing, no Update,
	so that the check below can draw the same thing without a screen. *)
PROCEDURE DrawMandelbrot;
VAR py, originX, originY, scaleX, scaleY: SIGNED32;
BEGIN
	(*	Here as well as in Take: a display can be wider than it was when this module first looked at
		it, and a row buffer one line short of the display is a write past the end of it. *)
	IF (row = NIL) OR (LEN(row^) < display.width * 4) THEN NEW(row, display.width * 4) END;
	(*	Per pixel steps, so that nothing overflows on the way: the width times three times One is
		already more than a 32 bit number can hold at the right hand edge. *)
	scaleX := 3 * One DIV display.width;
	scaleY := 5 * One DIV (2 * display.height);
	originX := display.width * 3 DIV 4;
	originY := display.height DIV 2;
	FOR py := 0 TO display.height - 1 DO MandelbrotLine(py, originX, originY, scaleX, scaleY) END
END DrawMandelbrot;

(** Draw the set over the whole display, and put it on the screen. *)
PROCEDURE Mandelbrot*;
VAR started: SIGNED32;
BEGIN
	IF ~Take() THEN RETURN END;
	started := Kernel.GetTicks();
	DrawMandelbrot;
	display.Update;
	Trace.String("DisplayDemo: Mandelbrot ");
	Trace.Int(display.width, 0);  Trace.String(" x ");  Trace.Int(display.height, 0);
	Trace.String(" in ");  Trace.Int(Kernel.GetTicks() - started, 0);  Trace.StringLn(" ms")
END Mandelbrot;

(*	A pattern whose geometry can be read off a photograph: a one pixel border, the two diagonals, and
	a box in each corner -- red top left, green top right, blue bottom left, white bottom right. A
	stride that is wrong shears the diagonals; a size that is wrong moves the boxes off the edges; a
	colour that is wrong names itself.

	`inPieces` puts it up in seven frames instead of one, which is the check for a driver that sends
	only what changed: the screen has to end up the same either way, and it does not if a frame that
	updates part of the window loses the rest. *)
PROCEDURE DrawPattern(inPieces: BOOLEAN);
VAR i, w, h, size: SIGNED32;

	PROCEDURE Piece;
	BEGIN
		IF inPieces THEN display.Update END
	END Piece;

BEGIN
	w := display.width;  h := display.height;  size := w DIV 6;
	display.Fill(0, 0, 0, w, h);  Piece;
	display.Fill(0808080H, 0, 0, w, 1);  display.Fill(0808080H, 0, h - 1, w, 1);
	display.Fill(0808080H, 0, 0, 1, h);  display.Fill(0808080H, w - 1, 0, 1, h);  Piece;
	FOR i := 0 TO w - 1 DO
		display.Dot(0FFFFFFH, i, SIGNED32(SIZE(i) * h DIV w));
		display.Dot(0FF00FFH, i, h - 1 - SIGNED32(SIZE(i) * h DIV w))
	END;
	Piece;
	display.Fill(0FF0000H, 2, 2, size, size);  Piece;							(* red, top left *)
	display.Fill(000FF00H, w - size - 2, 2, size, size);  Piece;				(* green, top right *)
	display.Fill(00000FFH, 2, h - size - 2, size, size);  Piece;				(* blue, bottom left *)
	display.Fill(0FFFFFFH, w - size - 2, h - size - 2, size, size);			(* white, bottom right *)
	display.Update
END DrawPattern;

(** The pattern, in one frame. *)
PROCEDURE Pattern*;
BEGIN
	IF ~Take() THEN RETURN END;
	DrawPattern(FALSE);
	Trace.String("DisplayDemo: pattern in one frame, on ");
	Trace.Int(display.width, 0);  Trace.String(" x ");  Trace.Int(display.height, 0);  Trace.Ln
END Pattern;

(** The same pattern, in seven frames -- the same screen, if partial frames lose nothing. *)
PROCEDURE PatternInPieces*;
BEGIN
	IF ~Take() THEN RETURN END;
	DrawPattern(TRUE);
	Trace.String("DisplayDemo: pattern in seven frames, on ");
	Trace.Int(display.width, 0);  Trace.String(" x ");  Trace.Int(display.height, 0);  Trace.Ln
END PatternInPieces;

(**	Time the smallest possible frame: one dot changed, put up a hundred times. What is left after the
	copying is gone -- the lock, whatever the surface carries over for itself, and the wait for a
	buffer to come free, which on a screen refreshing at 120 Hz is a refresh. *)
PROCEDURE Tiny*;
VAR i, started: SIGNED32;
BEGIN
	IF ~Take() THEN RETURN END;
	started := Kernel.GetTicks();
	FOR i := 1 TO 100 DO
		display.Dot(0FFFFFFH, i MOD display.width, display.height DIV 2);
		display.Update
	END;
	Trace.String("DisplayDemo: a hundred one-dot frames in ");
	Trace.Int(Kernel.GetTicks() - started, 0);  Trace.StringLn(" ms")
END Tiny;

(** Time a plain frame: fill the display in one colour and put it up, ten times over. *)
PROCEDURE Frames*;
VAR i, started: SIGNED32;
BEGIN
	IF ~Take() THEN RETURN END;
	started := Kernel.GetTicks();
	FOR i := 1 TO 10 DO
		display.Fill(ASH(i * 24 MOD 256, 8) + 040H, 0, 0, display.width, display.height);
		display.Update
	END;
	Trace.String("DisplayDemo: ten full frames in ");
	Trace.Int(Kernel.GetTicks() - started, 0);  Trace.StringLn(" ms")
END Frames;

(** Start the bouncing box, on a thread of its own. *)
PROCEDURE Animate*;
BEGIN
	IF animation # NIL THEN Trace.StringLn("DisplayDemo: already running");  RETURN END;
	IF ~Take() THEN RETURN END;
	NEW(animation, display);
	Trace.StringLn("DisplayDemo: the box is bouncing")
END Animate;

(** Stop it. *)
PROCEDURE Stop*;
BEGIN
	IF animation = NIL THEN RETURN END;
	animation.Stop;  animation := NIL
END Stop;

(** The set, then the box: what one asks of a display the first time it works. *)
PROCEDURE Run*;
BEGIN
	Mandelbrot;
	Animate
END Run;

END DisplayDemo.
