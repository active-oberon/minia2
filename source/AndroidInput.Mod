MODULE AndroidInput;	(** AUTHOR ""; PURPOSE "Touches of an Android application, as A2's mouse"; *)

(*
	The finger, as far as A2 is concerned, is a mouse.

	Inputs is the whole of A2's input: a broadcaster for the mouse, one for the keyboard, and messages
	with absolute or relative positions. A2 has no notion of a touch, of a second finger, or of a
	gesture -- so a touch is delivered as Inputs.AbsMouseMsg with the left button held while the finger
	is down and released when it lifts, which is what every client of Inputs already understands. The
	one place this shows through is that there is no pointer on the screen between touches, because
	there is no finger there either.

	Where the events come from, and why not directly: they arrive on the framework's looper thread,
	which belongs to nobody in A2. Calling into A2 from it would be the same mistake as letting A2
	report ART's faults -- a collector that walks its own threads, monitors that only its processes may
	hold. So `android/a2app.c` puts them in a ring and this module takes them out on a thread of its
	own, five milliseconds at a time. Waiting on a condition in C instead would save the polling and
	cost the ability to stop the thread from A2, which is the worse trade for a system whose collector
	stops threads with signals.

	First finger only. A mouse has one position; the rest are dropped in the application, where the
	event with all of them is.
*)

IMPORT SYSTEM, Unix, Inputs, Objects, Trace;

CONST
	(*	What a2app.c calls them. Ours, not the NDK's: nothing in A2 should have to agree with a constant
		of Android's, and these four are the whole vocabulary. *)
	Down = 0;  Move = 1;  Up = 2;  Key = 3;

	(*	And the modifiers, four of them plus the bit that says the key came up. Android has twenty; A2
		knows these. The translation from key code to character happens on the C side, because what a
		key means is Android's question -- what arrives here is what X11 would have sent. *)
	ModShift = 0;  ModCtrl = 1;  ModAlt = 2;  ModMeta = 3;  ModRelease = 4;

	Left = 0;					(* the mouse button a finger is, as Inputs numbers them *)
	PollMilliseconds = 5;

TYPE
	Reader = OBJECT
	VAR
		stop: BOOLEAN;

		PROCEDURE Stop*;
		BEGIN {EXCLUSIVE}
			stop := TRUE
		END Stop;

		PROCEDURE Stopped( ): BOOLEAN;
		BEGIN {EXCLUSIVE}
			RETURN stop
		END Stopped;

	BEGIN {ACTIVE}
		WHILE ~Stopped() DO
			WHILE Take() DO END;		(* everything that is waiting, then sleep *)
			Objects.Sleep(PollMilliseconds)
		END;
		Trace.StringLn("AndroidInput: stopped")
	END Reader;

VAR
	next: PROCEDURE {C} ( what, a, b, c: ADDRESS ): SIGNED32;
	softKeyboard: PROCEDURE {C} ( show: SIGNED32 ): SIGNED32;
	reader: Reader;
	touching: BOOLEAN;			(* a finger is down, so the button is held *)

(*	One mouse message, at a position, with whatever buttons.

	No deltas, and this is not laziness: a client of an absolute message reads a non-zero dx as a
	relative movement and adds it to a pointer of its own instead of taking the position given
	(WindowManager.Mod, `IF dx # 0 THEN INC(x, dx) ELSE x := nx END`). Deltas computed from the last
	touch are honest deltas, and they still drift -- a finger down after a finger up moves the pointer
	by the distance between them, so it ends near the finger rather than under it. Near enough to look
	right, far enough to miss a close button eighteen pixels wide, which is how it was found. The X11
	driver has always done it this way: Unix.KbdMouse.Mod's SendMouseMsg sets x, y and dz and nothing
	else, the wheel being the one thing that genuinely is a delta. *)
PROCEDURE Send(x, y: SIGNED32;  keys: SET);
VAR message: Inputs.AbsMouseMsg;
BEGIN
	message.keys := keys;
	message.x := x;  message.y := y;  message.z := 0;
	message.dx := 0;  message.dy := 0;  message.dz := 0;
	Inputs.mouse.Handle(message)
END Send;

(*	One key, as A2's keyboard sees it. The character and the keysym arrive ready-made; what is done
	here is the modifiers, four bits into the set Inputs uses -- and the left-hand one of each pair,
	because everything in A2 tests `flags * Inputs.Shift # {}` and not which shift it was. *)
PROCEDURE SendKey(ch, keysym, modifiers: SIGNED32);
VAR message: Inputs.KeyboardMsg;  bits: SET;
BEGIN
	bits := SYSTEM.VAL(SET, modifiers);
	message.ch := CHR(ch MOD 256);
	message.keysym := keysym;
	message.flags := {};
	IF ModShift IN bits THEN INCL(message.flags, Inputs.LeftShift) END;
	IF ModCtrl IN bits THEN INCL(message.flags, Inputs.LeftCtrl) END;
	IF ModAlt IN bits THEN INCL(message.flags, Inputs.LeftAlt) END;
	IF ModMeta IN bits THEN INCL(message.flags, Inputs.LeftMeta) END;
	IF ModRelease IN bits THEN INCL(message.flags, Inputs.Release) END;
	Inputs.keyboard.Handle(message)
END SendKey;

(*	One event, translated and broadcast. Answers whether there was one. *)
PROCEDURE Take( ): BOOLEAN;
VAR what, x, y, extra: SIGNED32;
BEGIN
	what := 0;  x := 0;  y := 0;  extra := 0;
	IF next(ADDRESSOF(what), ADDRESSOF(x), ADDRESSOF(y), ADDRESSOF(extra)) = 0 THEN RETURN FALSE END;
	IF what = Key THEN
		(*	Keys and touches share a ring, so they keep their order: a key that overtook the tap that
			put the caret where it goes would be typed in the wrong place. *)
		SendKey(x, y, extra);  RETURN TRUE
	END;
	CASE what OF
	| Down:
		(*	A finger down is two mouse messages and not one: the pointer arriving, and then the button.

			A mouse is somewhere before it is pressed, and A2's window manager is built on that. It
			works out which window a press belongs to only while no button is held -- `IF keys = {}
			THEN newOwner := GetPositionOwnerIntern(...)` in WindowManager.Mod -- so a press at a place
			the pointer has never been is delivered to whatever was under it last time. A finger has no
			hover: the first thing it ever does at a position is press there. Hence the empty-handed
			message first, at the new position, which is what a mouse moving there would have sent.

			Found by dragging a window that would not move while its pointer followed the finger
			perfectly, which is a picture that says "the button never arrived" and means the opposite. *)
		Send(x, y, {});
		touching := TRUE
	| Move:	(* the button stays as it is: a move with no finger down is a move with no button *)
	| Up:		touching := FALSE
	ELSE
		RETURN TRUE			(* something we do not translate, and taking it out of the ring is enough *)
	END;
	IF touching THEN Send(x, y, {Left}) ELSE Send(x, y, {}) END;
	RETURN TRUE
END Take;

(** Start delivering the application's touches as mouse messages. *)
PROCEDURE Install*;
BEGIN
	IF reader # NIL THEN Trace.StringLn("AndroidInput: already installed");  RETURN END;
	IF Unix.DlsymOptional(0, "A2Keyboard", ADDRESSOF(softKeyboard)) THEN END;
	IF ~Unix.DlsymOptional(0, "A2InputNext", ADDRESSOF(next)) THEN
		Trace.StringLn("AndroidInput: no window here -- this system was not started by the application");
		RETURN
	END;
	NEW(reader);
	Trace.StringLn("AndroidInput: installed, touches go to Inputs.mouse and keys to Inputs.keyboard")
END Install;

(**	Ask for the soft keyboard. There is no other way to have one on a phone, and no window on this
	system knows to ask -- A2 has never had a keyboard that needed summoning. So it is a command, and
	the application raises it once when the window arrives. *)
PROCEDURE ShowKeyboard*;
BEGIN
	IF softKeyboard = NIL THEN Trace.StringLn("AndroidInput: no application here to ask");  RETURN END;
	IF softKeyboard(1) = 0 THEN Trace.StringLn("AndroidInput: no activity to ask for a keyboard") END
END ShowKeyboard;

(** Send it away again. *)
PROCEDURE HideKeyboard*;
BEGIN
	IF softKeyboard = NIL THEN RETURN END;
	IF softKeyboard(0) = 0 THEN END
END HideKeyboard;

(** Stop delivering them. *)
PROCEDURE Remove*;
BEGIN
	IF reader = NIL THEN RETURN END;
	reader.Stop;  reader := NIL
END Remove;

END AndroidInput.
