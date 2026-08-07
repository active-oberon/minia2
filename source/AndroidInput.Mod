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

IMPORT Unix, Inputs, Objects, Trace;

CONST
	(*	What a2app.c calls them. Ours, not the NDK's: nothing in A2 should have to agree with a constant
		of Android's, and these three are the whole vocabulary. *)
	Down = 0;  Move = 1;  Up = 2;

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
	next: PROCEDURE {C} ( what, x, y: ADDRESS ): SIGNED32;
	reader: Reader;
	touching: BOOLEAN;			(* a finger is down, so the button is held *)
	lastX, lastY: SIGNED32;

(*	One event, translated and broadcast. Answers whether there was one. *)
PROCEDURE Take( ): BOOLEAN;
VAR what, x, y: SIGNED32;  message: Inputs.AbsMouseMsg;
BEGIN
	what := 0;  x := 0;  y := 0;
	IF next(ADDRESSOF(what), ADDRESSOF(x), ADDRESSOF(y)) = 0 THEN RETURN FALSE END;
	CASE what OF
	| Down:	touching := TRUE
	| Move:	(* the button stays as it is: a move with no finger down is a move with no button *)
	| Up:		touching := FALSE
	ELSE
		RETURN TRUE			(* something we do not translate, and taking it out of the ring is enough *)
	END;
	message.keys := {};
	IF touching THEN INCL(message.keys, Left) END;
	message.x := x;  message.y := y;  message.z := 0;
	message.dx := x - lastX;  message.dy := y - lastY;  message.dz := 0;
	lastX := x;  lastY := y;
	Inputs.mouse.Handle(message);
	RETURN TRUE
END Take;

(** Start delivering the application's touches as mouse messages. *)
PROCEDURE Install*;
BEGIN
	IF reader # NIL THEN Trace.StringLn("AndroidInput: already installed");  RETURN END;
	IF ~Unix.DlsymOptional(0, "A2InputNext", ADDRESSOF(next)) THEN
		Trace.StringLn("AndroidInput: no window here -- this system was not started by the application");
		RETURN
	END;
	NEW(reader);
	Trace.StringLn("AndroidInput: installed, touches go to Inputs.mouse")
END Install;

(** Stop delivering them. *)
PROCEDURE Remove*;
BEGIN
	IF reader = NIL THEN RETURN END;
	reader.Stop;  reader := NIL
END Remove;

END AndroidInput.
