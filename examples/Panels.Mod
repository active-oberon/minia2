MODULE Panels;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Oberon in a terminal: two frames, and text that runs" *)

(*	Two tiled frames and a caret: a list of commands above, what they wrote below. Ctrl-E runs
	the line the caret is on, and the answer is appended to the log -- which is a text like any
	other, so a line down there can be edited and run in its turn.

	That last part is the difference from every modern full-screen program: the keys are not a
	set the author chose, they are whatever is written in the frame. It is also the whole of
	Oberon's interface, and it fits in the sixty lines below because Frames does the model and
	Terminal does the device.

	    ob run examples/Panels.Mod        -- Ctrl-E runs a line, Tab changes frame, Ctrl-Q leaves.
*)

IMPORT Terminal, Frames, Commands;

VAR
	screen: Frames.Screen;
	commands, log: Frames.Frame;
	list, output: Frames.Text;
	rows, columns: SIGNED32;

	PROCEDURE Compose;
	BEGIN
		NEW(list);
		list.Add("System.Time");
		list.Add("Reflection.ShowProcesses");
		list.Add("System.Watch");
		list.Add("");
		list.Add("(* any line here runs: type one and press Ctrl-E *)");
		NEW(output);
		output.Add("what a command writes lands here, and can be run again");

		NEW(commands, " Commands -- Ctrl-E runs the line, Tab changes frame, Ctrl-Q leaves ", list);
		NEW(log, " Log ", output);
		log.editable := FALSE;
		NEW(screen); screen.Add(commands); screen.Add(log)
	END Compose;

	PROCEDURE Fit;
	BEGIN
		IF ~Terminal.Size(rows, columns) THEN rows := 24; columns := 80 END;
		screen.Layout(rows, columns)
	END Fit;

	PROCEDURE Run (CONST line: ARRAY OF CHAR);
	VAR ignore: BOOLEAN;
	BEGIN
		output.Add(""); output.Add("> "); output.Set(output.count-1, line);
		ignore := Frames.Execute(line, output);
		log.ToEnd
	END Run;

	(* `ob run Panels.Mod` invokes the exported command Do. *)
	PROCEDURE Do* (context: Commands.Context);
	VAR e: Terminal.Event; leave, ignored: BOOLEAN; line: Frames.Text;
	BEGIN
		IF ~Terminal.Open() THEN
			context.error.String("Panels: standard input is not a terminal"); context.error.Ln;
			RETURN
		END;
		Compose; Fit;
		Terminal.AltScreen(TRUE); Terminal.ShowCursor(FALSE);
		leave := FALSE;
		REPEAT
			screen.Draw(Terminal.out); Terminal.Flush;
			IF ~Terminal.Read(e) THEN
				leave := TRUE
			ELSIF (e.kind = Terminal.Character) & (e.modifiers = {Terminal.Ctrl}) THEN
				IF e.char = ORD("q") THEN leave := TRUE
				ELSIF e.char = ORD("e") THEN
					IF screen.Focused().Line() # NIL THEN Run(screen.Focused().Line()^) END
				END
			ELSE
				ignored := screen.Handle(e);
				IF Terminal.Resized() THEN Fit END
			END
		UNTIL leave;
		Terminal.ShowCursor(TRUE); Terminal.AltScreen(FALSE); Terminal.Flush;
		Terminal.Close
	END Do;

END Panels.
