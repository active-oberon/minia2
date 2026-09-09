MODULE Window;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "What a windowed program is: one display, the events, and a frame"; *)

(*
	Build it with the display linked in:

		ob build --gui Window.Mod

	The window is the whole picture -- there is no desktop and no widget in it. A program takes the
	display that `ob build --gui` installed, draws on it, hears the keyboard and the pointer through
	Inputs, and leaves when it is done. Drag with the left button to paint, press Escape to leave.
*)

IMPORT Displays, Inputs, Plugins, Trace;

CONST
	Background = 0102838H;
	Brush = 0FFB000H;
	Size = 12;						(* the brush, in pixels *)
	Left = 0;							(* the pointer button, as Inputs numbers them *)

TYPE
	(* A monitor, so that Do can wait without spinning: the program's main procedure has nothing to
	   do until a key arrives on another activity. *)
	Leaving = OBJECT
	VAR asked: BOOLEAN;

		PROCEDURE Ask*;
		BEGIN {EXCLUSIVE}
			asked := TRUE
		END Ask;

		PROCEDURE Await*;
		BEGIN {EXCLUSIVE}
			AWAIT(asked)
		END Await;

	END Leaving;

	Keys = OBJECT (Inputs.Sink)

		PROCEDURE Handle*(VAR message: Inputs.Message);
		BEGIN
			(* the test is not decoration: whatever anybody broadcasts on Inputs.keyboard arrives here *)
			IF message IS Inputs.KeyboardMsg THEN
				WITH message: Inputs.KeyboardMsg DO
					IF message.keysym = Inputs.KsEscape THEN leaving.Ask END
				END
			END
		END Handle;

	END Keys;

	Pointer = OBJECT (Inputs.Sink)

		PROCEDURE Handle*(VAR message: Inputs.Message);
		BEGIN
			IF message IS Inputs.AbsMouseMsg THEN
				WITH message: Inputs.AbsMouseMsg DO
					IF Left IN message.keys THEN
						display.Fill(Brush, message.x - Size DIV 2, message.y - Size DIV 2, Size, Size);
						display.Update
					END
				END
			END
		END Handle;

	END Pointer;

VAR
	display: Displays.Display;
	keys: Keys;  pointer: Pointer;
	leaving: Leaving;

(** Paint until Escape. *)
PROCEDURE Do*;
VAR plugin: Plugins.Plugin;
BEGIN
	plugin := Displays.registry.Get("");			(* whichever driver --gui installed: X11 here, Win32 there *)
	IF plugin = NIL THEN
		Trace.StringLn("Window: no display was installed -- build it with `ob build --gui`");  RETURN
	END;
	display := plugin(Displays.Display);
	display.Fill(Background, 0, 0, display.width, display.height);
	display.Update;
	NEW(leaving);  NEW(keys);  NEW(pointer);
	Inputs.keyboard.Register(keys);  Inputs.mouse.Register(pointer);
	Trace.String("Window: ");  Trace.Int(display.width, 0);  Trace.String(" x ");
	Trace.Int(display.height, 0);  Trace.StringLn(", drag to paint, Escape to leave");
	leaving.Await;
	Inputs.keyboard.Unregister(keys);  Inputs.mouse.Unregister(pointer)
END Do;

END Window.
