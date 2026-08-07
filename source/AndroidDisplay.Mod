MODULE AndroidDisplay;	(** AUTHOR ""; PURPOSE "Display driver over the window of an Android application"; *)

(*
	A2's display, in the window of an Android application.

	The picture goes through a frame buffer of our own -- one linear buffer, handed to
	Displays.InitFrameBuffer -- and Update copies it into the window. Not straight into the window's
	own buffer, which would be one copy fewer and wrong: a surface hands out a different buffer every
	frame, whose contents are whatever was in it two frames ago, and it may only be held between a
	lock and a post. A display, meanwhile, is a thing with an address that stays where it is.

	The window itself belongs to the application, and this module never touches it. `android/a2app.c`
	exports three procedures -- ask the size, lock for the pixels, unlock and post -- and holds a mutex
	across the second and third: the framework destroys a window on a thread of its own, and there is
	no arrangement in which A2 could keep a pointer to it and be safe. Found by dlsym, so a system
	started from a command line simply has no window and this module says so and registers nothing.

	Colour. A2 keeps a pixel as 0xAARRGGBB, which in memory is B, G, R, A; the window is asked for
	RGBX_8888, which is R, G, B, X. So the copy swaps two bytes per pixel rather than moving whole
	lines. There is a BGRA format in the Android HAL that would make the copy a plain move, but it is
	not one the NDK offers, and the one thing worse than a copy is a format the surface silently
	reinterprets.
*)

IMPORT SYSTEM, Unix, Displays, Plugins, Trace;

CONST
	(*	The pixel size the display reports, as unit/36000 mm. The phone this was written on puts 2340
		rows in some 158 mm, which is a pixel of 0.0675 mm. Nothing asks a window for its physical
		size, so this is a constant standing for "a dense screen" rather than a measurement. *)
	PixelUnit = 2430;

TYPE
	Display* = OBJECT (Displays.Display)
		VAR
			pixels: ADDRESS;			(* our frame buffer: width * height pixels, 4 bytes each *)
			bytes: SIZE;

		PROCEDURE &Init*(w, h: SIGNED32);
		BEGIN
			width := w;  height := h;  offscreen := 0;
			format := Displays.color8888;  unit := PixelUnit;
			bytes := SIZE(w) * SIZE(h) * 4;
			pixels := Unix.malloc(bytes);
			ASSERT(pixels # 0);
			Erase(pixels, bytes);
			InitFrameBuffer(pixels, SIGNED32(bytes), w * 4)
		END Init;

		(**	Put what has been drawn on the screen. Everything, every time: a lock without a dirty
			region is a promise to write the whole buffer, and the buffer we are given is not the one
			we wrote last time. *)
		PROCEDURE Update*;
		VAR bits: ADDRESS;  w, h, stride: SIGNED32;
		BEGIN {EXCLUSIVE}
			IF (pixels = 0) OR (lockWindow = NIL) THEN RETURN END;
			bits := 0;  w := 0;  h := 0;  stride := 0;
			IF lockWindow(ADDRESSOF(bits), ADDRESSOF(w), ADDRESSOF(h), ADDRESSOF(stride)) = 0 THEN
				RETURN	(* no window at the moment, which is ordinary: the activity may be gone *)
			END;
			IF ~told THEN
				told := TRUE;
				Trace.String("AndroidDisplay: the window gives ");
				Trace.Int(w, 0);  Trace.String(" x ");  Trace.Int(h, 0);
				Trace.String(", stride ");  Trace.Int(stride, 0);  Trace.String(" pixels, bits at ");
				Trace.Hex(bits, 0);  Trace.Ln
			END;
			IF bits # 0 THEN Blit(pixels, width, height, bits, w, h, stride) END;
			unlockWindow
		END Update;

		PROCEDURE Finalize*;
		BEGIN
			Finalize^;
			IF pixels # 0 THEN Unix.free(pixels);  pixels := 0 END
		END Finalize;

	END Display;

VAR
	(*	The application's three procedures. Nothing else here is Android's. *)
	windowSize: PROCEDURE {C} ( width, height: ADDRESS ): SIGNED32;
	lockWindow: PROCEDURE {C} ( bits, width, height, stride: ADDRESS ): SIGNED32;
	unlockWindow: PROCEDURE {C};

	display: Display;
	told: BOOLEAN;						(* the first frame says what the window handed over *)

PROCEDURE Erase(adr: ADDRESS; size: SIZE);
VAR i: SIZE;
BEGIN
	i := 0;
	WHILE i < size DO  SYSTEM.PUT32(adr + i, 0);  INC(i, 4)  END
END Erase;

(*	One line of ours into one line of the window's, red and blue exchanged and the fourth byte set
	opaque. The window is asked for RGBX_8888, where the fourth byte is ignored; it is written all
	the same, so that the same copy is right if the surface ever hands us RGBA. *)
PROCEDURE Blit(from: ADDRESS;  fw, fh: SIGNED32;  to: ADDRESS;  tw, th, stride: SIGNED32);
VAR x, y, rows, cols: SIGNED32;  src, dst: ADDRESS;  pixel: SIGNED32;
BEGIN
	rows := fh;  IF th < rows THEN rows := th END;
	cols := fw;  IF tw < cols THEN cols := tw END;
	FOR y := 0 TO rows - 1 DO
		src := from + SIZE(y) * fw * 4;
		dst := to + SIZE(y) * stride * 4;
		FOR x := 0 TO cols - 1 DO
			SYSTEM.GET(src, pixel);
			SYSTEM.PUT32(dst, SIGNED32(
				SET32(LSH(pixel, 16)) * SET32({16..23}) +		(* blue, into where red goes *)
				SET32(pixel) * SET32({8..15}) +					(* green, where it already is *)
				SET32(LSH(pixel, -16)) * SET32({0..7}) +		(* red, into where blue goes *)
				SET32({24..31})));								(* opaque, for a surface that reads it *)
			INC(src, 4);  INC(dst, 4)
		END
	END
END Blit;

PROCEDURE Link;
BEGIN
	(*	RTLD_DEFAULT, not a library of our own: these live in the application that started us, which
		is already in the process and is not something we could open by name. *)
	IF ~Unix.DlsymOptional(0, "A2WindowSize", ADDRESSOF(windowSize)) THEN RETURN END;
	IF ~Unix.DlsymOptional(0, "A2WindowLock", ADDRESSOF(lockWindow)) THEN windowSize := NIL;  RETURN END;
	IF ~Unix.DlsymOptional(0, "A2WindowUnlockAndPost", ADDRESSOF(unlockWindow)) THEN
		windowSize := NIL;  lockWindow := NIL
	END
END Link;

(** Register a display for the window of the application we are in, if there is one. *)
PROCEDURE Install*;
VAR w, h: SIGNED32;  res: INTEGER;
BEGIN
	IF display # NIL THEN
		Trace.StringLn("AndroidDisplay: already installed");  RETURN
	END;
	IF windowSize = NIL THEN
		Trace.StringLn("AndroidDisplay: no window here -- this system was not started by the application");
		RETURN
	END;
	w := 0;  h := 0;
	IF windowSize(ADDRESSOF(w), ADDRESSOF(h)) = 0 THEN
		Trace.StringLn("AndroidDisplay: the application has no window yet");  RETURN
	END;
	IF (w <= 0) OR (h <= 0) THEN
		Trace.StringLn("AndroidDisplay: the window has no size yet");  RETURN
	END;
	NEW(display, w, h);
	display.SetName("AndroidDisplay");
	display.desc := "Display over the window of an Android application";
	Displays.registry.Add(display, res);
	ASSERT(res = Plugins.Ok);
	Trace.String("AndroidDisplay: installed, ");
	Trace.Int(w, 0);  Trace.String(" x ");  Trace.Int(h, 0);
	Trace.String(", ");  Trace.Int(SIGNED32(display.fbsize DIV 1024), 0);  Trace.StringLn("K of frame buffer")
END Install;

(** Take the display away again -- for a window that is gone for good, and for testing this twice. *)
PROCEDURE Remove*;
BEGIN
	IF display = NIL THEN RETURN END;
	Displays.registry.Remove(display);
	display.Finalize;
	display := NIL;
	Trace.StringLn("AndroidDisplay: removed")
END Remove;

BEGIN
	Link
END AndroidDisplay.
