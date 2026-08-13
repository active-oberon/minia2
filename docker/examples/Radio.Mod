MODULE Radio;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Internet radio: the catalogue in one frame, what it says in the other" *)

(*	The program this SDK was wanted for, and the first one written on it that its author runs
	every day. It replaces a shell script of some two hundred and seventy lines -- fzf, awk,
	column, shuf and mpv -- with the same behaviour and one dependency: mpv, which does the
	playing, because writing a decoder for half the stations on the list is a different project.

	Everything else is A2: the catalogue is read with Files, the two frames and the caret are
	Frames, the terminal is Terminal, mpv is started with Processes and told what to do through
	LocalSockets -- its control socket, which is a socket named by a path and takes one JSON
	command per line.

	What the loop shows is worth reading, because it is the thing the plan says the language is
	for: three sources of events -- the keyboard, a child's output, and time -- and no state
	machine anywhere. Ask each what it has, do that, draw. In a language without active objects
	this is where select and callbacks would go.

	    ob run examples/Radio.Mod

	  ↑ ↓  choose        Enter  play        s  stop        p  pause
	  + −  volume        r      a station at random        Ctrl-Q  leave

	The catalogue is $XDG_CONFIG_HOME/radio/stations.tsv (or ~/.config/radio), one station a
	line: genre, name and address, separated by tabs. Lines beginning with # are ignored, which
	is where its own header lives.
*)

IMPORT Files, Streams, Strings, Commands, Terminal, Frames, Processes, LocalSockets, Unix, Objects,
	Random, Kernel;

CONST
	Idle = 40;                         (* milliseconds to wait when nothing at all has happened *)
	MaxStations = 512;

TYPE
	Station = RECORD
		genre, name, url: Strings.String;
	END;

VAR
	station: ARRAY MaxStations OF Station;
	stations: SIGNED32;

	screen: Frames.Screen;
	list, log: Frames.Frame;
	catalogue, output: Frames.Text;

	player: Processes.Process;         (* mpv, while something is playing *)
	control: LocalSockets.Connection;  (* and the socket it listens on *)
	socketPath: ARRAY 128 OF CHAR;
	playing: SIGNED32;                 (* which station, or -1 *)
	volume: SIGNED32;
	paused: BOOLEAN;
	rows, columns: SIGNED32;
	dice: Random.Sequence;

	(* ---- the catalogue ---- *)

	PROCEDURE Home (VAR path: ARRAY OF CHAR): BOOLEAN;
	VAR value: ARRAY 128 OF CHAR;
	BEGIN
		IF Processes.Environment("XDG_CONFIG_HOME", value) & (value # "") THEN
			COPY(value, path); Strings.Append(path, "/radio/"); RETURN TRUE
		END;
		IF Processes.Environment("HOME", value) & (value # "") THEN
			COPY(value, path); Strings.Append(path, "/.config/radio/"); RETURN TRUE
		END;
		RETURN FALSE
	END Home;

	(* One tab-separated field. *)
	PROCEDURE Field (CONST line: ARRAY OF CHAR; VAR from: SIZE; VAR out: ARRAY OF CHAR): BOOLEAN;
	VAR n: SIZE;
	BEGIN
		IF line[from] = 0X THEN RETURN FALSE END;
		n := 0;
		WHILE (line[from] # 0X) & (line[from] # 09X) & (n < LEN(out)-1) DO
			out[n] := line[from]; INC(n); INC(from)
		END;
		out[n] := 0X;
		IF line[from] = 09X THEN INC(from) END;
		RETURN TRUE
	END Field;

	PROCEDURE Read (CONST path: ARRAY OF CHAR): BOOLEAN;
	VAR f: Files.File; r: Files.Reader; line: ARRAY 1024 OF CHAR;
		genre, name, url: ARRAY 256 OF CHAR; from: SIZE; shown: ARRAY 300 OF CHAR;
	BEGIN
		f := Files.Old(path); IF f = NIL THEN RETURN FALSE END;
		Files.OpenReader(r, f, 0);
		stations := 0;
		WHILE (r.res = Streams.Ok) & (stations < MaxStations) DO
			r.Ln(line);
			IF (line[0] # "#") & (line[0] # 0X) THEN
				from := 0;
				IF Field(line, from, genre) & Field(line, from, name) & Field(line, from, url) THEN
					station[stations].genre := Strings.NewString(genre);
					station[stations].name := Strings.NewString(name);
					station[stations].url := Strings.NewString(url);
					COPY(name, shown); Strings.Append(shown, "   ");
					Strings.Append(shown, genre);
					catalogue.Add(shown);
					INC(stations)
				END
			END
		END;
		RETURN stations > 0
	END Read;

	(* ---- mpv, and the socket it listens on ---- *)

	PROCEDURE Say (CONST what: ARRAY OF CHAR);
	BEGIN output.Add(what); log.ToEnd
	END Say;

	PROCEDURE Command (CONST json: ARRAY OF CHAR);
	BEGIN
		IF control # NIL THEN control.WriteLine(json) END
	END Command;

	(*	mpv makes its control socket when it starts, and this connects to it when it is there.
		Trying once would fail every time: the socket appears a moment after the program does. *)
	PROCEDURE Attach;
	VAR tries: SIGNED32;
	BEGIN
		tries := 0;
		WHILE (control = NIL) & (tries < 50) DO
			control := LocalSockets.Connect(socketPath);
			IF control = NIL THEN Objects.Sleep(100); INC(tries) END
		END;
		IF control = NIL THEN Say("mpv is playing, but its control socket never appeared") END
	END Attach;

	PROCEDURE Stop;
	VAR code: SIGNED32;
	BEGIN
		IF control # NIL THEN Command('{"command": ["quit"]}'); control.Close; control := NIL END;
		IF player # NIL THEN
			IF ~player.Finished(code) THEN player.Kill END;
			player.Close; player := NIL
		END;
		playing := -1; paused := FALSE
	END Stop;

	PROCEDURE Play (which: SIGNED32);
	VAR arguments: Strings.StringArray; include, ipc: ARRAY 256 OF CHAR;
		directory: ARRAY 128 OF CHAR; said: ARRAY 300 OF CHAR;
	BEGIN
		IF (which < 0) OR (which >= stations) THEN RETURN END;
		Stop;
		IF ~Home(directory) THEN RETURN END;

		include := "--include="; Strings.Append(include, directory); Strings.Append(include, "mpv.conf");
		ipc := "--input-ipc-server="; Strings.Append(ipc, socketPath);

		NEW(arguments, 5);
		arguments[0] := Strings.NewString("mpv");
		arguments[1] := Strings.NewString(include);
		arguments[2] := Strings.NewString(ipc);
		arguments[3] := Strings.NewString("--no-video");
		arguments[4] := station[which].url;

		player := Processes.Start("mpv", arguments);
		IF player = NIL THEN Say("mpv is not on the PATH, and it is what plays"); RETURN END;
		playing := which;
		said := "playing: "; Strings.Append(said, station[which].name^); Say(said);
		Attach;
		Volume(volume)
	END Play;

	PROCEDURE Volume (level: SIGNED32);
	VAR json: ARRAY 64 OF CHAR;
	BEGIN
		IF level < 0 THEN level := 0 END;
		IF level > 130 THEN level := 130 END;
		volume := level;
		json := '{"command": ["set_property", "volume", '; Strings.AppendInt(json, volume);
		Strings.Append(json, "]}");
		Command(json)
	END Volume;

	PROCEDURE Pause;
	BEGIN
		paused := ~paused;
		IF paused THEN Command('{"command": ["set_property", "pause", true]}'); Say("paused")
		ELSE Command('{"command": ["set_property", "pause", false]}'); Say("playing again")
		END
	END Pause;

	(* Whatever mpv has said since last time -- the station's own titles come through here. *)
	PROCEDURE Listen;
	VAR line: ARRAY 300 OF CHAR; i: SIZE; ch: CHAR;
	BEGIN
		IF player = NIL THEN RETURN END;
		WHILE player.Waiting() > 0 DO
			i := 0;
			LOOP
				IF player.Waiting() <= 0 THEN EXIT END;
				ch := player.Output.Get();
				IF (ch = 0AX) OR (ch = 0DX) OR (i = LEN(line)-1) THEN EXIT END;
				line[i] := ch; INC(i)
			END;
			line[i] := 0X;
			IF line # "" THEN Say(line) END
		END
	END Listen;

	(* ---- what is on the screen ---- *)

	(*	The station frame's name says what is playing; the keys are written over the other frame,
		where they stay still. A name plus a help line does not fit in a title, and cutting the
		one that changes is the wrong half to lose. *)
	PROCEDURE Title;
	VAR t: ARRAY 256 OF CHAR;
	BEGIN
		t := " Stations ";
		IF playing >= 0 THEN
			Strings.Append(t, "-- "); Strings.Append(t, station[playing].name^);
			IF paused THEN Strings.Append(t, " (paused)") END;
			Strings.Append(t, ", volume "); Strings.AppendInt(t, volume);
			Strings.Append(t, " ")
		END;
		COPY(t, list.title)
	END Title;

	PROCEDURE Fit;
	BEGIN
		IF ~Terminal.Size(rows, columns) THEN rows := 24; columns := 80 END;
		screen.Layout(rows, columns)
	END Fit;

	PROCEDURE Compose (): BOOLEAN;
	VAR directory, path: ARRAY 256 OF CHAR;
	BEGIN
		NEW(catalogue); NEW(output);
		IF ~Home(directory) THEN RETURN FALSE END;
		COPY(directory, path); Strings.Append(path, "stations.tsv");
		IF ~Read(path) THEN RETURN FALSE END;

		NEW(list, " Stations ", catalogue); list.editable := FALSE;
		NEW(log, " What it says -- Enter plays, s stops, p pauses, +/- volume, r random, Ctrl-Q leaves ",
			output);
		log.editable := FALSE;
		NEW(screen); screen.Add(list); screen.Add(log);
		output.Add("mpv does the playing; everything else here is Active Oberon");
		RETURN TRUE
	END Compose;

	(* ---- the loop: the keyboard, a child, and time ---- *)

	(* `ob run Radio.Mod` invokes the exported command Do. *)
	PROCEDURE Do* (context: Commands.Context);
	VAR e: Terminal.Event; leave, drew: BOOLEAN;
	BEGIN
		IF ~Terminal.Open() THEN
			context.error.String("Radio: standard input is not a terminal"); context.error.Ln;
			RETURN
		END;
		socketPath := "/tmp/a2-radio-"; Strings.AppendInt(socketPath, Unix.getpid());
		Strings.Append(socketPath, ".sock");
		playing := -1; volume := 70; paused := FALSE;
		NEW(dice); dice.InitSeed(SIGNED32(Kernel.GetTicks()));   (* a different station each run *)
		IF ~Compose() THEN
			Terminal.Close;
			context.error.String("Radio: no catalogue in $XDG_CONFIG_HOME/radio/stations.tsv");
			context.error.Ln; RETURN
		END;
		Fit;
		Terminal.AltScreen(TRUE); Terminal.ShowCursor(FALSE);
		leave := FALSE;
		REPEAT
			Title; screen.Draw(Terminal.out); Terminal.Flush;
			drew := FALSE;
			IF Terminal.Pending() THEN
				IF ~Terminal.Read(e) THEN
					leave := TRUE
				ELSIF (e.kind = Terminal.Character) & (e.modifiers = {Terminal.Ctrl})
						& (e.char = ORD("q")) THEN
					leave := TRUE
				ELSIF (e.kind = Terminal.Key) & (e.key = Terminal.Enter) THEN
					Play(list.caret)
				ELSIF e.kind = Terminal.Character THEN
					CASE CHR(e.char) OF
						  "s": Stop; Say("stopped")
						| "p": Pause
						| "+", "=": Volume(volume + 5)
						| "-": Volume(volume - 5)
						| "r": Play(dice.Integer() MOD stations)
					ELSE
					END
				ELSE
					drew := screen.Handle(e)
				END;
				IF Terminal.Resized() THEN Fit END
			ELSE
				Listen;
				IF ~drew THEN Objects.Sleep(Idle) END
			END
		UNTIL leave;
		Stop;
		Terminal.ShowCursor(TRUE); Terminal.AltScreen(FALSE); Terminal.Flush;
		Terminal.Close
	END Do;

END Radio.
