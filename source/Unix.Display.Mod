MODULE Display;

(* imports, not Commands.Call: a static binary holds what something imports, and `ob build --gui` links this *)
IMPORT Commands, XDisplay, KbdMouse;

(*	Install takes the window size the way the Windows twin of this module does -- `Display.Install
	800 600` -- so that a program built with `ob build --gui=800x600` can ask for a window without
	an environment variable. No arguments means what it always meant: the configuration decides. *)
PROCEDURE Install*(context: Commands.Context);
VAR width, height: SIGNED32;
BEGIN
	context.arg.SkipWhitespace;  context.arg.Int(width, FALSE);
	context.arg.SkipWhitespace;  context.arg.Int(height, FALSE);
	IF (width > 0) & (height > 0) THEN XDisplay.SetSize(width, height) END;
	XDisplay.Install; KbdMouse.Init
END Install;

END Display.
