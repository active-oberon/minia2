MODULE Display;

(* imports, not Commands.Call: a static binary holds what something imports, and `ob build --gui` links this *)
IMPORT XDisplay, KbdMouse;

PROCEDURE Install*;
BEGIN
	XDisplay.Install; KbdMouse.Init
END Install;

END Display.
