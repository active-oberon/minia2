MODULE AndroidDisplay;	(** AUTHOR ""; PURPOSE "Display driver over the window of an Android application"; *)

(*
	A2's display, in the window of an Android application.

	The picture goes through a frame buffer of our own -- one linear buffer, handed to
	Displays.InitFrameBuffer -- and Update copies it into the window. Not straight into the window's
	own buffer, which would be one copy fewer and wrong: a surface hands out a different buffer every
	frame, whose contents are whatever was in it two frames ago, and it may only be held between a
	lock and a post. A display, meanwhile, is a thing with an address that stays where it is.

	The window itself belongs to the application, and this module never touches it. `android/a2app.c`
	exports four procedures -- ask the size, lock for the pixels, unlock and post, and say which window
	this is -- and holds a mutex across the lock and the post: the framework destroys a window on a
	thread of its own, and there is no arrangement in which A2 could keep a pointer to it and be safe.
	Found by dlsym, so a system started from a command line simply has no window and this module says
	so and registers nothing.

	Colour. A2 keeps a pixel as 0xAARRGGBB, which in memory is B, G, R, A; the window is asked for
	RGBX_8888, which is R, G, B, X. So the copy swaps two bytes per pixel rather than moving whole
	lines. There is a BGRA format in the Android HAL that would make the copy a plain move, but it is
	not one the NDK offers, and the one thing worse than a copy is a format the surface silently
	reinterprets.

	What is copied is what changed. The drawing operations are overridden only to note the rectangle
	they touch -- they do their work by calling the inherited one -- and Update copies that rectangle
	and nothing else, which is the difference between paying for ten megabytes a frame and paying for
	the box that moved. The surface is told which region is coming and answers with the region it needs,
	widening it whenever it cannot carry the rest over from the last frame; that answer is what gets
	written.

	What that mechanism does NOT cover is a new window, and finding out cost a screenshot: a surface
	carries over the last thing the process painted, so the first buffer of a window A2 has never drawn
	in comes back asking for a small region with the application's own splash still in it. That is what
	the generation is for -- the application counts its windows, and a number that has moved means the
	whole picture goes again.

	Nothing is dirty, nothing is locked: an idle system posts no frames at all.

	A rotation makes the window a different shape while the display stays the same object, and this is
	where A2 has nothing to offer: a Displays.Display has a width and a height and no notion of either
	changing, so there is no notification for a client to wait for. What is done here is the least that
	is honest -- the size is taken from the buffer the window hands over, and when it differs the
	display's own width, height and stride are set to it and everything is marked dirty. A client that
	cares (DisplayDemo does) reads the size again on its next frame; a window manager would want a
	proper event, and the registry has the machinery for one when there is something to tell.

	The pixels are allocated once and never freed or moved: a rotation swaps the sides of the window and
	so needs not one byte more, and drawing is deliberately not locked against Update -- a client
	mid-Transfer while the fields changed would otherwise be writing into memory that had just gone back
	to the allocator. A window that genuinely grows is therefore refused, with a line in the log, rather
	than served by a reallocation nobody can make safe.
*)

IMPORT SYSTEM, Unix, Objects, Displays, Plugins, Trace;

CONST
	(*	What the window may hand us, as Android numbers its formats. Both of these are four bytes a
		pixel and are written the same way -- the fourth byte is alpha in one and ignored in the other,
		and it is set opaque either way. Anything else is refused rather than guessed at. *)
	FormatRGBA8888 = 1;  FormatRGBX8888 = 2;

	(*	How often the frame is offered to the window, in milliseconds. See Poster: this is a ceiling on
		how long a change waits, not a frame rate -- a frame with nothing dirty in it costs a monitor
		entry and no lock at all. *)
	FrameMilliseconds = 16;

	(*	The pixel size the display reports, as unit/36000 mm. The phone this was written on puts 2340
		rows in some 158 mm, which is a pixel of 0.0675 mm. Nothing asks a window for its physical
		size, so this is a constant standing for "a dense screen" rather than a measurement. *)
	PixelUnit = 2430;

TYPE
	(*	What has been drawn and not yet put on the screen, as one rectangle. A monitor of its own, and
		not part of the display: the display's drawing operations note their rectangle before doing the
		work, and Displays.Fill calls the display's own Transfer on the way -- so a lock on the display
		taken by the outer call would be asked for again by the inner one, and an A2 monitor is not
		re-entrant. This one is taken and released before anything else happens. *)
	Region = OBJECT
	VAR left, top, right, bottom: SIGNED32;		(* empty when right <= left *)

		PROCEDURE Add*(x, y, w, h, limitX, limitY: SIGNED32);
		BEGIN {EXCLUSIVE}
			IF x < 0 THEN w := w + x;  x := 0 END;
			IF y < 0 THEN h := h + y;  y := 0 END;
			IF x + w > limitX THEN w := limitX - x END;
			IF y + h > limitY THEN h := limitY - y END;
			IF (w <= 0) OR (h <= 0) THEN RETURN END;
			IF right <= left THEN
				left := x;  top := y;  right := x + w;  bottom := y + h
			ELSE
				IF x < left THEN left := x END;
				IF y < top THEN top := y END;
				IF x + w > right THEN right := x + w END;
				IF y + h > bottom THEN bottom := y + h END
			END
		END Add;

		PROCEDURE Whole*(w, h: SIGNED32);
		BEGIN {EXCLUSIVE}
			left := 0;  top := 0;  right := w;  bottom := h
		END Whole;

		(*	Answers what is dirty and forgets it. What is drawn after this and before the copy is drawn
			again next time: it marks the region again, and the frame it missed is one frame. *)
		PROCEDURE Take*(VAR l, t, r, b: SIGNED32): BOOLEAN;
		BEGIN {EXCLUSIVE}
			IF right <= left THEN RETURN FALSE END;
			l := left;  t := top;  r := right;  b := bottom;
			left := 0;  top := 0;  right := 0;  bottom := 0;
			RETURN TRUE
		END Take;

	END Region;

	Display* = OBJECT (Displays.Display)
		VAR
			pixels: ADDRESS;			(* our frame buffer: room for the window either way round *)
			bytes: SIZE;
			dirty: Region;
			generationSeen: SIGNED32;	(* which window we last drew in, see Update *)

		PROCEDURE &Init*(w, h: SIGNED32);
		BEGIN
			offscreen := 0;
			format := Displays.color8888;  unit := PixelUnit;
			(*	One allocation, for the window as it stands, and it is enough for the window turned round
				as well: a rotation swaps the sides and the product is what a frame buffer costs. The
				measurement that says so, from the phone this was written on: 1080 x 2340 upright and
				2244 x 1080 sideways, which is fewer pixels, not more -- landscape loses the strip beside
				the camera. Something that genuinely grows is refused in Update rather than reallocated,
				because drawing is not locked against Update and the memory would go out from under a
				client mid-Transfer. *)
			bytes := SIZE(w) * SIZE(h) * 4;
			pixels := Unix.malloc(bytes);
			ASSERT(pixels # 0);
			NEW(dirty);
			generationSeen := -1;
			Reshape(w, h)
		END Init;

		(*	Follow the window's shape. From Init, and from Update whenever the buffer that arrives is
			not the shape we last drew. The frame buffer keeps its address; what changes is how much of
			it is one line, and everything in it is black rather than the last shape rearranged. *)
		PROCEDURE Reshape(w, h: SIGNED32);
		BEGIN
			width := w;  height := h;
			InitFrameBuffer(pixels, SIGNED32(bytes), w * 4);
			Erase(pixels, SIZE(w) * SIZE(h) * 4);
			dirty.Whole(w, h)
		END Reshape;

		(*	The drawing operations, each noting where it draws and then drawing. Dot and Mask are not
			among them and need not be: both reach the frame buffer through Fill, on SELF, so the
			override below is what they call. *)
		PROCEDURE Transfer*(VAR buf: ARRAY OF CHAR;  ofs, stride, x, y, w, h: SIZE;  op: INTEGER);
		BEGIN
			IF op = Displays.set THEN
				dirty.Add(SIGNED32(x), SIGNED32(y), SIGNED32(w), SIGNED32(h), width, height)
			END;
			Transfer^(buf, ofs, stride, x, y, w, h, op)
		END Transfer;

		PROCEDURE Fill*(col, x, y, w, h: SIGNED32);
		BEGIN
			dirty.Add(x, y, w, h, width, height);
			Fill^(col, x, y, w, h)
		END Fill;

		PROCEDURE Copy*(sx, sy, w, h, dx, dy: SIGNED32);
		BEGIN
			dirty.Add(dx, dy, w, h, width, height);
			Copy^(sx, sy, w, h, dx, dy)
		END Copy;

		(**	Put what has been drawn on the screen, and only what has been drawn. Asks the surface for
			the region that changed and writes back the region the surface answers with, which is wider
			whenever it cannot carry the rest of the picture over from the frame before. *)
		PROCEDURE Update*;
		VAR bits: ADDRESS;  w, h, stride, windowFormat, l, t, r, b, generation: SIGNED32;
		BEGIN {EXCLUSIVE}
			IF (pixels = 0) OR (lockWindow = NIL) THEN RETURN END;
			(*	A new window keeps nothing of ours, and does not say so by itself: the surface carries
				the last thing this process painted into the buffer it hands out, so a window we have
				never drawn in comes back asking for a small region with somebody else's picture in it.
				Hence the generation, and hence everything being dirty when it moves on. *)
			generation := windowGeneration();
			IF generation # generationSeen THEN
				generationSeen := generation;
				dirty.Whole(width, height)
			END;
			IF ~dirty.Take(l, t, r, b) THEN RETURN END;	(* nothing changed: no lock, no frame *)
			bits := 0;  w := 0;  h := 0;  stride := 0;  windowFormat := 0;
			IF lockWindow(ADDRESSOF(bits), ADDRESSOF(w), ADDRESSOF(h), ADDRESSOF(stride),
					ADDRESSOF(windowFormat), ADDRESSOF(l), ADDRESSOF(t), ADDRESSOF(r), ADDRESSOF(b)) = 0 THEN
				(*	No window at the moment, which is ordinary -- the activity may be gone. What was
					dirty stays dirty, or the next window would get half a picture. *)
				dirty.Add(l, t, r - l, b - t, width, height);
				RETURN
			END;
			IF ~told THEN
				told := TRUE;
				Trace.String("AndroidDisplay: the window gives ");
				Trace.Int(w, 0);  Trace.String(" x ");  Trace.Int(h, 0);
				Trace.String(", stride ");  Trace.Int(stride, 0);  Trace.String(" pixels, bits at ");
				Trace.Hex(bits, 0);  Trace.Ln
			END;
			(*	The window is a different shape -- a rotation. The size is not asked for anywhere: it
				arrives with the buffer, which is the one place it cannot be out of date.

				Bigger than the buffer was made for, though, is refused: the room is the square of the
				longer side of the window we started with, which covers turning it round and nothing
				else. A window that grows -- an unfolding screen, a desktop -- would need the frame
				buffer allocated again, and that cannot be done under a client that may be drawing. So
				it says so and goes on drawing the part it can. *)
			IF (w # width) OR (h # height) THEN
				IF SIZE(w) * SIZE(h) * 4 > bytes THEN
					IF ~complained THEN
						complained := TRUE;
						Trace.String("AndroidDisplay: the window grew to ");
						Trace.Int(w, 0);  Trace.String(" x ");  Trace.Int(h, 0);
						Trace.StringLn(", which is more than the frame buffer holds -- drawing what fits")
					END
				ELSE
					Trace.String("AndroidDisplay: the window is now ");
					Trace.Int(w, 0);  Trace.String(" x ");  Trace.Int(h, 0);  Trace.Ln;
					Reshape(w, h);
					l := 0;  t := 0;  r := w;  b := h
				END
			END;

			(*	A window need not give what it was asked for, and one that gives two bytes a pixel is
				half the buffer we would write: this is the check that turns that into a line in the log
				rather than a fault past the end of somebody else's memory, which is how it was found. *)
			IF (windowFormat # FormatRGBA8888) & (windowFormat # FormatRGBX8888) THEN
				IF ~complained THEN
					complained := TRUE;
					Trace.String("AndroidDisplay: the window is format ");  Trace.Int(windowFormat, 0);
					Trace.StringLn(", and this driver writes four bytes a pixel -- nothing drawn")
				END;
				unlockWindow;
				RETURN
			END;
			IF bits # 0 THEN Blit(pixels, width, height, bits, w, h, stride, l, t, r, b) END;
			unlockWindow
		END Update;

		PROCEDURE Finalize*;
		BEGIN
			Finalize^;
			IF pixels # 0 THEN Unix.free(pixels);  pixels := 0 END
		END Finalize;

	END Display;

	(*	What puts the frame on the screen, on a clock of its own.

		A2's displays are memory that is already the screen: something draws into the frame buffer and
		the pixels are on the glass, so no client in the tree calls Update after drawing and the window
		manager is one of them -- it composes into the display and stops there. A window is not memory
		that is already the screen. The frame has to be handed over, and nobody above is going to do it.

		Rather than teach the window manager about a display that must be posted -- vanilla code, and it
		would still leave every other client -- the driver does it: one thread, offering the frame at
		FrameMilliseconds, and Update posting only what is dirty and nothing at all when nothing is.
		That is also what makes a client that does call Update, like DisplayDemo, cost nothing extra:
		its call empties the region, and the next tick finds it empty and returns.

		The rate is a ceiling on latency rather than a frame rate. What it costs when the screen is
		still is one entry into a monitor and one call into the application per tick -- no lock on the
		surface, no copy. *)
	Poster = OBJECT
	VAR alive, done: BOOLEAN;

		PROCEDURE &Init*;
		BEGIN alive := TRUE;  done := FALSE END Init;

		(*	Stops it and waits for it to be out of Update. Waiting is the point: what follows a Stop is
			the display being finalized and its frame buffer freed, and a thread that woke one tick
			later would be reading it. At most one tick. *)
		PROCEDURE Stop*;
		BEGIN {EXCLUSIVE}
			alive := FALSE;
			AWAIT(done)
		END Stop;

		PROCEDURE Alive( ): BOOLEAN;
		BEGIN {EXCLUSIVE} RETURN alive END Alive;

		PROCEDURE Finished;
		BEGIN {EXCLUSIVE} done := TRUE END Finished;

	BEGIN {ACTIVE}
		WHILE Alive() DO
			IF display # NIL THEN display.Update END;
			Objects.Sleep(FrameMilliseconds)
		END;
		Finished
	END Poster;

VAR
	(*	The application's three procedures. Nothing else here is Android's. *)
	windowSize: PROCEDURE {C} ( width, height: ADDRESS ): SIGNED32;
	windowGeneration: PROCEDURE {C} ( ): SIGNED32;
	lockWindow: PROCEDURE {C} ( bits, width, height, stride, format, left, top, right, bottom: ADDRESS ): SIGNED32;
	unlockWindow: PROCEDURE {C};

	display: Display;
	poster: Poster;
	told, complained: BOOLEAN;						(* the first frame says what the window handed over *)

PROCEDURE Erase(adr: ADDRESS; size: SIZE);
VAR i: SIZE;
BEGIN
	i := 0;
	WHILE i < size DO  SYSTEM.PUT32(adr + i, 0);  INC(i, 4)  END
END Erase;

(*	The rectangle l, t, r, b of ours into the window's, line by line, red and blue exchanged and the
	fourth byte set opaque. The window is asked for RGBX_8888, where the fourth byte is ignored; it is
	written all the same, so that the same copy is right if the surface ever hands us RGBA.

	Clipped against both, because neither side is the authority on the other: the window can be a
	different size than the display was made for (a rotation), and the region comes back from the
	surface widened to whatever it wants written. *)
PROCEDURE Blit(from: ADDRESS;  fw, fh: SIGNED32;  to: ADDRESS;  tw, th, stride, l, t, r, b: SIGNED32);
VAR x, y: SIGNED32;  src, dst: ADDRESS;  pixel: SIGNED32;
BEGIN
	IF l < 0 THEN l := 0 END;
	IF t < 0 THEN t := 0 END;
	IF r > fw THEN r := fw END;
	IF r > tw THEN r := tw END;
	IF b > fh THEN b := fh END;
	IF b > th THEN b := th END;
	FOR y := t TO b - 1 DO
		src := from + (SIZE(y) * fw + l) * 4;
		dst := to + (SIZE(y) * stride + l) * 4;
		FOR x := l TO r - 1 DO
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
	IF ~Unix.DlsymOptional(0, "A2WindowLockRegion", ADDRESSOF(lockWindow)) THEN windowSize := NIL;  RETURN END;
	IF ~Unix.DlsymOptional(0, "A2WindowUnlockAndPost", ADDRESSOF(unlockWindow)) THEN
		windowSize := NIL;  lockWindow := NIL;  RETURN
	END;
	IF ~Unix.DlsymOptional(0, "A2WindowGeneration", ADDRESSOF(windowGeneration)) THEN
		windowSize := NIL;  lockWindow := NIL;  unlockWindow := NIL
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
	NEW(poster);
	Trace.String("AndroidDisplay: installed, ");
	Trace.Int(w, 0);  Trace.String(" x ");  Trace.Int(h, 0);
	Trace.String(", ");  Trace.Int(SIGNED32(display.fbsize DIV 1024), 0);  Trace.StringLn("K of frame buffer")
END Install;

(** Take the display away again -- for a window that is gone for good, and for testing this twice. *)
PROCEDURE Remove*;
BEGIN
	IF display = NIL THEN RETURN END;
	(*	The thread first, and Stop waits: it reaches the display through the module variable below, and
		one that woke between the Remove and the Finalize would be posting out of freed memory. *)
	IF poster # NIL THEN poster.Stop;  poster := NIL END;
	Displays.registry.Remove(display);
	display.Finalize;
	display := NIL;
	Trace.StringLn("AndroidDisplay: removed")
END Remove;

BEGIN
	Link
END AndroidDisplay.
