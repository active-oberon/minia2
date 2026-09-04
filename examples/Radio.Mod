MODULE Radio;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "Internet radio: the catalogue in one frame, what it says in the other" *)

(*	The program this SDK was wanted for, and the first one written on it that its author runs
	every day. It replaces a shell script of some two hundred and seventy lines -- fzf, awk,
	column, shuf and mpv -- with the same behaviour and one dependency: mpv, which does the
	playing, because writing a decoder for half the stations on the list is a different project.

	Everything else is A2: the catalogue is read with Files, the two frames and the caret are
	Frames, the terminal is Terminal, mpv is started with Processes and told what to do through
	LocalSockets -- its control socket, which is a socket named by a path and takes one JSON
	command per line.

	The loop is what this program is for showing. Three things happen without asking each other's
	permission -- somebody types, mpv says something, the window is resized -- and each is an
	active object of its own that hands what it has to one place. The program then waits in a
	single AWAIT and does what arrived. There is no polling, no timer to tune, no state machine,
	and nothing to cancel: an object whose source has ended simply ends.

	That is the comparison the plan asks for, and the honest form of it is the plumbing alone --
	the three objects and the queue between them -- against the goroutines, channels, select and
	context another language spends on the same three sources.

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

IMPORT Files, Streams, Strings, UTF8Strings, Commands, Terminal, Frames, Processes, LocalSockets, Unix, Objects,
	Random, Kernel, Vorbis := OGGVorbisPlayer,
	(*	One parametric module, instantiated for the kind of thing this program hands about: the
		waiting is written once, in the library, and named here. *)
	Arrivals := Channels(Arrival);

CONST
	MaxStations = 512;
	Waiting = 32;                      (* how much may pile up before a source waits its turn *)
	Watch = 400;                       (* milliseconds between looks at the window's size *)

	(** what Events.Next handed over *)
	AKey = 0; ALine = 1; AResize = 2;

TYPE
	(** What one of the three sources has to say. *)
	Arrival* = RECORD
		kind*: SIGNED32;               (** AKey, ALine, AResize *)
		key*: Terminal.Event;
		said*: Strings.String;
	END;

	Station = RECORD
		genre, name, url: Strings.String;
	END;

	(** What was typed, handed over as it is typed. Ends when the terminal does. *)
	Keyboard = OBJECT
	VAR arriving: Arrivals.Channel; what: Arrival;

		PROCEDURE &InitKeyboard* (where: Arrivals.Channel);
		BEGIN arriving := where
		END InitKeyboard;

	BEGIN {ACTIVE}
		what.kind := AKey;
		WHILE Terminal.Read(what.key) & arriving.Put(what) DO END;
		arriving.Close                 (* the terminal ended, and so does the program *)
	END Keyboard;

	(**	What mpv says, line by line. Reading a child waits on a pipe rather than in a system
		call, so this object waits and the rest of the program does not. It ends by itself when
		the child does, which is all that stopping a station amounts to: nothing to cancel. *)
	Player = OBJECT
	VAR arriving: Arrivals.Channel; player: Processes.Process; what: Arrival;
		said: ARRAY 300 OF CHAR; n: SIZE; ch: CHAR;

		PROCEDURE &InitPlayer* (where: Arrivals.Channel; which: Processes.Process);
		BEGIN arriving := where; player := which
		END InitPlayer;

	BEGIN {ACTIVE}
		LOOP
			n := 0;
			LOOP
				ch := player.Output.Get();
				IF player.Output.res # Streams.Ok THEN EXIT END;
				IF (ch = 0AX) OR (ch = 0DX) OR (n = LEN(said)-1) THEN EXIT END;
				said[n] := ch; INC(n)
			END;
			said[n] := 0X;
			IF player.Output.res # Streams.Ok THEN EXIT END;
			IF said # "" THEN
				what.kind := ALine; what.said := Strings.NewString(said);
				IF ~arriving.Put(what) THEN EXIT END
			END
		END
	END Player;

	(**	A station played here rather than by anybody else. OGGVorbisPlayer decodes Vorbis and
		reads the stream itself; PlayURL does not return until the stream ends or StopURL is
		called, so it belongs in an object of its own like everything else that waits.

		Only Ogg. The player is a Vorbis decoder and nothing else, and more than half the
		stations in a catalogue are AAC or MP3 -- those still go to mpv, which is the honest
		division and not a stage of one. *)
	Native = OBJECT
	VAR arriving: Arrivals.Channel; address: Strings.String; what: Arrival; played: BOOLEAN;

		PROCEDURE &InitNative* (where: Arrivals.Channel; url: Strings.String);
		BEGIN arriving := where; address := url
		END InitNative;

	BEGIN {ACTIVE}
		played := Vorbis.PlayURL(address);
		what.kind := ALine;
		IF played THEN what.said := Strings.NewString("the stream ended")
		ELSE what.said := Strings.NewString("that stream is not Vorbis, or did not answer")
		END;
		IF ~arriving.Put(what) THEN END      (* the program may have left before the stream did *)
	END Native;

	(**	The window's size, looked at now and then. It is the third source, and the only one that
		must be asked rather than waited for: a size does not announce itself, and the signal that
		would is worth less than what a handler in the wrong place costs. *)
	Clock = OBJECT
	VAR arriving: Arrivals.Channel; what: Arrival; stop: BOOLEAN;

		PROCEDURE &InitClock* (where: Arrivals.Channel);
		BEGIN arriving := where; stop := FALSE
		END InitClock;

		PROCEDURE Stop*;
		BEGIN {EXCLUSIVE} stop := TRUE
		END Stop;

	BEGIN {ACTIVE}
		what.kind := AResize;
		WHILE ~stop DO
			Objects.Sleep(Watch);
			IF ~stop & Terminal.Resized() & ~arriving.Put(what) THEN stop := TRUE END
		END
	END Clock;

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
	inhouse: Native;                   (* or the Vorbis decoder, when the station is Ogg *)
	control: LocalSockets.Connection;  (* and the socket it listens on *)
	socketPath: ARRAY 128 OF CHAR;
	playing: SIGNED32;                 (* which station, or -1 *)
	volume: SIGNED32;
	paused: BOOLEAN;
	rows, columns: SIGNED32;
	dice: Random.Sequence;
	arriving: Arrivals.Channel;        (* where the three sources hand over what they have *)
	keyboard: Keyboard;
	listener: Player;
	clock: Clock;
	status: ARRAY 200 OF CHAR;         (* mpv's position line, which is state and not a message *)

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
		IF inhouse # NIL THEN
			(*	The object ends when PlayURL returns, and PlayURL returns when this flag is
				seen -- so nothing is cancelled and nothing is waited for here. *)
			Vorbis.StopURL; inhouse := NIL
		END;
		playing := -1; paused := FALSE; status := ""
	END Stop;

	(*	Ogg is played here, everything else by mpv. The URL is what says which, because that is
		all a catalogue line has: a station whose address ends in .ogg is Vorbis often enough to
		try, and the object above says so in the log when it is not. *)
	PROCEDURE Ogg (CONST url: ARRAY OF CHAR): BOOLEAN;
	VAR n: SIZE;
	BEGIN
		n := Strings.Length(url);
		RETURN (n > 4) & (url[n-4] = ".") & (CAP(url[n-3]) = "O") & (CAP(url[n-2]) = "G")
			& (CAP(url[n-1]) = "G")
	END Ogg;

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

		IF Ogg(station[which].url^) THEN
			playing := which; status := "";
			NEW(inhouse, arriving, station[which].url);
			said := "playing here, without mpv: "; Strings.Append(said, station[which].name^);
			Say(said);
			RETURN
		END;

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
		NEW(listener, arriving, player);   (* it ends by itself when the child does *)
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
		IF inhouse # NIL THEN
			(*	The volume of what is played here is the one OGGVorbisPlayer opens its channel
				with, and it exports no way to change it. Saying so is better than moving a
				number on the screen that nothing follows. *)
			Say("the volume of a station played here is fixed; mpv's is not");
			RETURN
		END;
		json := '{"command": ["set_property", "volume", '; Strings.AppendInt(json, volume);
		Strings.Append(json, "]}");
		Command(json)
	END Volume;

	PROCEDURE Pause;
	BEGIN
		IF inhouse # NIL THEN
			Say("a station played here cannot be paused, only stopped");
			RETURN
		END;
		paused := ~paused;
		IF paused THEN Command('{"command": ["set_property", "pause", true]}'); Say("paused")
		ELSE Command('{"command": ["set_property", "pause", false]}'); Say("playing again")
		END
	END Pause;

	(* mpv's own position line, which it rewrites rather than adds to. *)
	PROCEDURE Status (CONST line: ARRAY OF CHAR): BOOLEAN;
	BEGIN RETURN (line[0] = "A") & (line[1] = ":") & (line[2] = " ")
	END Status;

	(*	The screen, and only as much of it as changed: mpv's position lives in one frame's name, and
		redrawing the other two for it would be work nobody asked for. *)
	PROCEDURE Draw (onlyStatus: BOOLEAN);
	BEGIN
		Title;
		IF onlyStatus THEN log.Draw(Terminal.out, screen.Focused() = log)
		ELSE screen.Draw(Terminal.out)
		END;
		Terminal.Flush
	END Draw;

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
			IF inhouse # NIL THEN
				Strings.Append(t, ", here ")           (* and not through mpv *)
			ELSE
				Strings.Append(t, ", volume "); Strings.AppendInt(t, volume);
				Strings.Append(t, " ")
			END
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
		output.Add("Ogg is played here; mpv plays the rest. Everything else is Active Oberon");
		RETURN TRUE
	END Compose;

	(* ---- the loop: the keyboard, a child, and time ---- *)

	(* `ob run Radio.Mod` invokes the exported command Do. *)
	PROCEDURE Do* (context: Commands.Context);
	VAR e: Terminal.Event; leave: BOOLEAN; said: Strings.String; arrival: Arrival;
	BEGIN
		IF ~Terminal.Open() THEN
			context.error.String("Radio: standard input is not a terminal"); context.error.Ln;
			RETURN
		END;
		(* $TMPDIR before /tmp: Termux has no /tmp at all, and mpv is told this path too. *)
		IF ~Processes.Environment("TMPDIR", socketPath) OR (socketPath = "") THEN socketPath := "/tmp" END;
		Strings.Append(socketPath, "/a2-radio-"); Strings.AppendInt(socketPath, Unix.getpid());
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
		Title; screen.Refresh(Terminal.out); Terminal.Flush;
		NEW(arriving); NEW(keyboard, arriving); NEW(clock, arriving);
		leave := FALSE;
		REPEAT
			IF ~arriving.Get(arrival) THEN leave := TRUE ELSE
			e := arrival.key; said := arrival.said;
			CASE arrival.kind OF
				  AResize: Fit; Title; screen.Refresh(Terminal.out); Terminal.Flush
				| ALine:
					(*	mpv rewrites its position line many times a second: that is state, not a
						message, and it goes in the frame's name rather than among what was said. *)
					IF Status(said^) THEN COPY(said^, status); Draw(TRUE)
					ELSE Say(said^); Draw(FALSE)
					END
				| AKey:
					IF (e.kind = Terminal.Character) & (e.modifiers = {Terminal.Ctrl})
							& (e.char = ORD("q")) THEN
						leave := TRUE
					ELSIF (e.kind = Terminal.Key) & (e.key = Terminal.Enter) THEN
						IF screen.Focused() = genreFrame THEN
							Fill(genreFrame.caret - 1)     (* the first line is All, which is -1 *)
						ELSE
							Play(Chosen(list.caret))
						END;
						Draw(FALSE)
					ELSIF e.kind = Terminal.Character THEN
						CASE CHR(e.char) OF
							  "s": Stop; Say("stopped")
							| "p", " ": Pause          (* the hand reaches for the space bar *)
							| "+", "=": Volume(volume + 5)
							| "-": Volume(volume - 5)
							| "m": Export
							| "e": Edit
							| "r": IF listed > 0 THEN Play(Chosen(dice.Integer() MOD listed)) END
						ELSE
						END;
						Draw(FALSE)
					ELSE
						IF screen.Handle(e) THEN END;
						Draw(FALSE)
					END
			ELSE
			END END
		UNTIL leave;
		clock.Stop; arriving.Close;
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
	(* UTF8Strings.Length, not Strings.Length: the genres are Ukrainian, and a column padded by
		byte count is a column that does not line up *)
	width := 0;
	FOR i := 0 TO stations-1 DO
		n := SIGNED32(UTF8Strings.Length(station[i].genre^));
		IF n > width THEN width := n END
	END;
	FOR i := 0 TO stations-1 DO
		context.out.String(station[i].genre^);
		n := width - SIGNED32(UTF8Strings.Length(station[i].genre^)) + 2;
		WHILE n > 0 DO context.out.Char(" "); DEC(n) END;
		context.out.String(station[i].name^); context.out.Ln
	END;
	context.out.Update
END List;

END Radio.
