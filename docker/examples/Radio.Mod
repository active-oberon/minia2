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
	  + −  volume        r      one of those shown, at random
	  Tab  change frame  m      write the catalogue out as M3U
	  e    edit the catalogue in $EDITOR       Ctrl-Q  leave

	Choosing a genre in the left frame narrows the middle one, and everything that follows --
	playing, the random one, what is written out -- follows what is shown. `Radio.List` prints
	the catalogue and needs no terminal at all.

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
	genre: ARRAY MaxStations OF Strings.String;   (* the genres, once each, in the order met *)
	genres: SIGNED32;
	shown: ARRAY MaxStations OF SIGNED32;         (* which station each line of the list is *)
	listed: SIGNED32;

	screen: Frames.Screen;
	genreFrame, list, log: Frames.Frame;
	genreText, catalogue, output: Frames.Text;

	player: Processes.Process;         (* mpv, while something is playing *)
	control: LocalSockets.Connection;  (* and the socket it listens on *)
	socketPath: ARRAY 128 OF CHAR;
	playing: SIGNED32;                 (* which station, or -1 *)
	volume: SIGNED32;
	paused: BOOLEAN;
	rows, columns: SIGNED32;
	dice: Random.Sequence;
	status: ARRAY 200 OF CHAR;         (* mpv's position line, which is state and not a message *)
	said: SIGNED32;                    (* how many lines the log had when it was last drawn *)

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

	(* Each genre once, in the order the catalogue mentions them. *)
	PROCEDURE Met (CONST what: ARRAY OF CHAR);
	VAR i: SIGNED32;
	BEGIN
		FOR i := 0 TO genres-1 DO IF genre[i]^ = what THEN RETURN END END;
		IF genres < MaxStations THEN genre[genres] := Strings.NewString(what); INC(genres) END
	END Met;

	PROCEDURE Read (CONST path: ARRAY OF CHAR): BOOLEAN;
	VAR f: Files.File; r: Files.Reader; line: ARRAY 1024 OF CHAR;
		kind, name, url: ARRAY 256 OF CHAR; from: SIZE;
	BEGIN
		f := Files.Old(path); IF f = NIL THEN RETURN FALSE END;
		Files.OpenReader(r, f, 0);
		stations := 0;
		WHILE (r.res = Streams.Ok) & (stations < MaxStations) DO
			r.Ln(line);
			IF (line[0] # "#") & (line[0] # 0X) THEN
				from := 0;
				IF Field(line, from, kind) & Field(line, from, name) & Field(line, from, url) THEN
					station[stations].genre := Strings.NewString(kind);
					station[stations].name := Strings.NewString(name);
					station[stations].url := Strings.NewString(url);
					Met(kind);
					INC(stations)
				END
			END
		END;
		RETURN stations > 0
	END Read;

	(*	The stations of one genre, or all of them. Everything that follows -- what is played, the
		random one, what is written out -- goes by what is shown, so narrowing the list narrows
		them too, which is what the genre menu of the shell version did in its own way. *)
	PROCEDURE Fill (which: SIGNED32);
	VAR i: SIGNED32; line: ARRAY 300 OF CHAR;
	BEGIN
		catalogue.Clear; listed := 0;
		FOR i := 0 TO stations-1 DO
			IF (which < 0) OR (station[i].genre^ = genre[which]^) THEN
				COPY(station[i].name^, line);
				IF which < 0 THEN
					Strings.Append(line, "   "); Strings.Append(line, station[i].genre^)
				END;
				catalogue.Add(line); shown[listed] := i; INC(listed)
			END
		END;
		IF listed = 0 THEN catalogue.Add("(no stations of that kind)") END;
		list.top := 0; list.caret := 0
	END Fill;

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
		playing := -1; paused := FALSE; status := ""
	END Stop;

	(* The station on that line of the list, or -1 where the list is empty. *)
	PROCEDURE Chosen (line: SIGNED32): SIGNED32;
	BEGIN
		IF (line < 0) OR (line >= listed) THEN RETURN -1 END;
		RETURN shown[line]
	END Chosen;

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
		playing := which; status := "";
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

	(* mpv's own position line, which it rewrites rather than adds to. *)
	PROCEDURE Status (CONST line: ARRAY OF CHAR): BOOLEAN;
	BEGIN RETURN (line[0] = "A") & (line[1] = ":") & (line[2] = " ")
	END Status;

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
			IF line # "" THEN
				(*	mpv rewrites its position line many times a second. It is not a message and
					does not belong among them: it goes in the frame's name, where a thing that
					is always true and always changing belongs. *)
				IF Status(line) THEN COPY(line, status) ELSE Say(line) END
			END
		END
	END Listen;

	(*	The catalogue as a playlist, in the form every player reads. What is written is what is
		shown, so a narrowed list writes one genre's worth -- which is the same rule as playing. *)
	PROCEDURE Export;
	VAR directory, path: ARRAY 256 OF CHAR; f: Files.File; w: Files.Writer;
		i, which: SIGNED32; said: ARRAY 300 OF CHAR;
	BEGIN
		IF ~Home(directory) THEN RETURN END;
		COPY(directory, path); Strings.Append(path, "radio.m3u");
		f := Files.New(path);
		IF f = NIL THEN Say("could not write the playlist"); RETURN END;
		Files.OpenWriter(w, f, 0);
		w.String("#EXTM3U"); w.Char(0AX);
		FOR i := 0 TO listed-1 DO
			which := shown[i];
			w.String('#EXTINF:-1 group-title="'); w.String(station[which].genre^);
			w.String('",'); w.String(station[which].name^); w.Char(0AX);
			w.String(station[which].url^); w.Char(0AX)
		END;
		w.Update; Files.Register(f);
		said := "wrote "; Strings.AppendInt(said, listed);
		Strings.Append(said, " stations to "); Strings.Append(said, path); Say(said)
	END Export;

	(*	The catalogue in an editor. The editor wants the terminal the way it found it, so this
		gives it back, waits, and takes it again -- which is what a full-screen program has to do
		around any program that draws for itself. *)
	PROCEDURE Edit;
	VAR directory, path: ARRAY 256 OF CHAR; editor: ARRAY 128 OF CHAR;
		arguments: Strings.StringArray; child: Processes.Process; code: SIGNED32;
	BEGIN
		IF ~Home(directory) THEN RETURN END;
		COPY(directory, path); Strings.Append(path, "stations.tsv");
		IF ~Processes.Environment("EDITOR", editor) OR (editor = "") THEN editor := "nano" END;
		NEW(arguments, 2);
		arguments[0] := Strings.NewString(editor);
		arguments[1] := Strings.NewString(path);

		Terminal.ShowCursor(TRUE); Terminal.AltScreen(FALSE); Terminal.Flush; Terminal.Close;
		child := Processes.StartAttached(editor, arguments);
		IF child # NIL THEN code := child.Wait(); child.Close END;
		IF Terminal.Open() THEN END;
		Terminal.AltScreen(TRUE); Terminal.ShowCursor(FALSE);

		IF child = NIL THEN Say("no editor to edit it with"); RETURN END;
		catalogue.Clear; genres := 0; stations := 0;
		IF Read(path) THEN
			genreText.Clear; genreText.Add("All");
			FOR code := 0 TO genres-1 DO genreText.Add(genre[code]^) END;
			genreFrame.caret := 0; Fill(-1);
			Say("the catalogue was read again")
		END
	END Edit;

	(* ---- what is on the screen ---- *)

	(*	The station frame's name says what is playing; the keys are written over the other frame,
		where they stay still. A name plus a help line does not fit in a title, and cutting the
		one that changes is the wrong half to lose. *)
	PROCEDURE Title;
	VAR t: ARRAY 256 OF CHAR;
	BEGIN
		IF (playing >= 0) & (status # "") THEN
			t := " "; Strings.Append(t, status); Strings.Append(t, " ")
		ELSE
			t := " Enter plays, s stops, p pauses, +/- volume, r random, m writes M3U, e edits, Ctrl-Q leaves "
		END;
		COPY(t, log.title);
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
	VAR directory, path: ARRAY 256 OF CHAR; i: SIGNED32;
	BEGIN
		NEW(catalogue); NEW(output);
		IF ~Home(directory) THEN RETURN FALSE END;
		COPY(directory, path); Strings.Append(path, "stations.tsv");
		IF ~Read(path) THEN RETURN FALSE END;

		NEW(genreText); genreText.Add("All");
		FOR i := 0 TO genres-1 DO genreText.Add(genre[i]^) END;

		NEW(genreFrame, " Genres ", genreText); genreFrame.editable := FALSE;
		NEW(list, " Stations ", catalogue); list.editable := FALSE;
		NEW(log, " Enter plays, s stops, p pauses, +/- volume, r random, m writes M3U, e edits, Ctrl-Q leaves ",
			output);
		log.editable := FALSE;
		(*	Two tracks: the genres beside everything else, and in the wider one the stations over
			what they say. Three equal columns would give the log a third of the width, and the
			log is the part with sentences in it. *)
		NEW(screen);
		screen.NewTrack(1); screen.Add(genreFrame);
		screen.NewTrack(3); screen.Add(list); screen.Add(log);
		Fill(-1);
		output.Add("mpv does the playing; everything else here is Active Oberon");
		RETURN TRUE
	END Compose;

	(* ---- the loop: the keyboard, a child, and time ---- *)

	(* `ob run Radio.Mod` invokes the exported command Do. *)
	PROCEDURE Do* (context: Commands.Context);
	VAR e: Terminal.Event; leave, changed, onlyStatus: BOOLEAN; was: ARRAY 200 OF CHAR;
	BEGIN
		IF ~Terminal.Open() THEN
			context.error.String("Radio: standard input is not a terminal"); context.error.Ln;
			RETURN
		END;
		socketPath := "/tmp/a2-radio-"; Strings.AppendInt(socketPath, Unix.getpid());
		Strings.Append(socketPath, ".sock");
		playing := -1; volume := 70; paused := FALSE; said := 0;
		NEW(dice); dice.InitSeed(SIGNED32(Kernel.GetTicks()));   (* a different station each run *)
		IF ~Compose() THEN
			Terminal.Close;
			context.error.String("Radio: no catalogue in $XDG_CONFIG_HOME/radio/stations.tsv");
			context.error.Ln; RETURN
		END;
		Fit;
		Terminal.AltScreen(TRUE); Terminal.ShowCursor(FALSE);
		Title; screen.Refresh(Terminal.out); Terminal.Flush;
		leave := FALSE;
		REPEAT
			(*	Draw when something has changed and not otherwise. Painting a screen twenty-five
				times a second whether or not it differs is what makes a terminal program flicker,
				and there is nothing to see in it either. *)
			changed := FALSE; onlyStatus := FALSE;
			IF Terminal.Pending() THEN
				IF ~Terminal.Read(e) THEN
					leave := TRUE
				ELSIF (e.kind = Terminal.Character) & (e.modifiers = {Terminal.Ctrl})
						& (e.char = ORD("q")) THEN
					leave := TRUE
				ELSIF (e.kind = Terminal.Key) & (e.key = Terminal.Enter) THEN
					IF screen.Focused() = genreFrame THEN
						Fill(genreFrame.caret - 1)     (* the first line is All, which is -1 *)
					ELSE
						Play(Chosen(list.caret))
					END
				ELSIF e.kind = Terminal.Character THEN
					CASE CHR(e.char) OF
						  "s": Stop; Say("stopped")
						| "p": Pause
						| "+", "=": Volume(volume + 5)
						| "-": Volume(volume - 5)
						| "m": Export
						| "e": Edit
						| "r": IF listed > 0 THEN Play(Chosen(dice.Integer() MOD listed)) END
					ELSE
					END
				ELSE
					IF screen.Handle(e) THEN END
				END;
				changed := TRUE;
				IF Terminal.Resized() THEN
					Fit; Title; screen.Refresh(Terminal.out); Terminal.Flush; changed := FALSE
				END
			ELSE
				COPY(status, was);
				Listen;
				onlyStatus := (output.count = said) & (was # status);
				changed := onlyStatus OR (output.count # said);
				IF ~changed THEN Objects.Sleep(Idle) END
			END;
			said := output.count;
			IF changed & ~leave THEN
				Title;
				(*	mpv's position changes several times a second and lives in one frame's name.
					Redrawing the other two for it would be work nobody asked for -- which is what
					having frames is for. *)
				IF onlyStatus THEN log.Draw(Terminal.out, screen.Focused() = log)
				ELSE screen.Draw(Terminal.out)
				END;
				Terminal.Flush
			END
		UNTIL leave;
		Stop;
		Terminal.ShowCursor(TRUE); Terminal.AltScreen(FALSE); Terminal.Flush;
		Terminal.Close
	END Do;

(**	`ob run Radio.Mod List` -- the catalogue as text, for a pipe or a look. Needs no terminal,
	and is the one thing here that a full-screen program cannot be. *)
PROCEDURE List* (context: Commands.Context);
VAR directory, path: ARRAY 256 OF CHAR; i, width, n: SIGNED32;
BEGIN
	NEW(catalogue); stations := 0; genres := 0;
	IF ~Home(directory) THEN
		context.error.String("Radio: no place to look for a catalogue"); context.error.Ln; RETURN
	END;
	COPY(directory, path); Strings.Append(path, "stations.tsv");
	IF ~Read(path) THEN
		context.error.String("Radio: no catalogue at "); context.error.String(path);
		context.error.Ln; RETURN
	END;
	width := 0;
	FOR i := 0 TO stations-1 DO
		n := SIGNED32(Strings.Length(station[i].genre^));
		IF n > width THEN width := n END
	END;
	FOR i := 0 TO stations-1 DO
		context.out.String(station[i].genre^);
		n := width - SIGNED32(Strings.Length(station[i].genre^)) + 2;
		WHILE n > 0 DO context.out.Char(" "); DEC(n) END;
		context.out.String(station[i].name^); context.out.Ln
	END;
	context.out.Update
END List;

END Radio.
