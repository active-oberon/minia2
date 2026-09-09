MODULE ZoomProbe;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "What the display says a pixel is, printed for tests/zoom-check.sh"; *)

(*
	Built with `ob build --gui`, run against an X server of a known density, and read by
	tests/zoom-check.sh: it prints the pixel size the driver reported and the zoom the window
	manager would take from it. Nothing here is graphical -- it asks the display and leaves.
*)

IMPORT Displays, Plugins, Trace;

CONST
	NominalUnit = 10000;		(* WindowManager.NominalUnit, repeated: importing it would want the window manager *)
	MaxZoom = 8;

PROCEDURE Zoom(unit: SIGNED32): SIGNED32;
BEGIN
	IF (unit <= 0) OR (unit >= NominalUnit) THEN RETURN 1 END;
	RETURN MIN(MaxZoom, MAX(1, (NominalUnit + unit DIV 2) DIV unit))
END Zoom;

PROCEDURE Do*;
VAR plugin: Plugins.Plugin; display: Displays.Display;
BEGIN
	plugin := Displays.registry.Get("");
	IF plugin = NIL THEN Trace.StringLn("zoom: no display");  RETURN END;
	display := plugin(Displays.Display);
	Trace.String("zoom: ");  Trace.Int(display.width, 0);  Trace.String(" x ");
	Trace.Int(display.height, 0);  Trace.String(" unit=");  Trace.Int(display.unit, 0);
	Trace.String(" zoom=");  Trace.Int(Zoom(display.unit), 0);  Trace.Ln
END Do;

END ZoomProbe.
