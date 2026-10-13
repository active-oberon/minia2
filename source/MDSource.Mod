MODULE MDSource; (** AUTHOR "BohdanT"; PURPOSE:  where the help files come from. A directory now, a ZIP archive can be added as another Source *)

IMPORT Files, Streams, Codecs, Raster, Strings, KernelLog, Zip, WMGraphics;

(*
	A Source is a set of named files. Names use '/' and are relative to the root of the source, for example
	"index.md" or "images/circuit.png". The viewer only talks to a Source, so documents and pictures can
	live in a directory or inside an archive without any change in the viewer.
*)

TYPE
	(** a list of file names *)
	NameList* = OBJECT
	VAR
		name*: ARRAY 256 OF CHAR;
		next*: NameList;
	END NameList;

	Source* = OBJECT
		(** a reader of the file, or NIL if there is no such file *)
		PROCEDURE Open*(CONST path: ARRAY OF CHAR): Streams.Reader;
		BEGIN
			RETURN NIL
		END Open;

		(** the names of all pages (the .md files) of the source, or NIL if the source cannot list them *)
		PROCEDURE Pages*(): NameList;
		BEGIN
			RETURN NIL
		END Pages;
	END Source;

	(** files of a directory; root is put in front of every name (it ends with '/' or ':' or is empty) *)
	FileSource* = OBJECT(Source)
	VAR
		root: ARRAY 256 OF CHAR;

		PROCEDURE &Init*(CONST dir: ARRAY OF CHAR);
		BEGIN
			COPY(dir, root)
		END Init;

		PROCEDURE Open*(CONST path: ARRAY OF CHAR): Streams.Reader;
		VAR f: Files.File; r: Files.Reader; full: ARRAY 512 OF CHAR; i, n: SIGNED32;
		BEGIN
			n := 0; i := 0;
			WHILE (root[i] # 0X) & (n < LEN(full) - 1) DO full[n] := root[i]; INC(n); INC(i) END;
			i := 0;
			WHILE (path[i] # 0X) & (n < LEN(full) - 1) DO full[n] := path[i]; INC(n); INC(i) END;
			full[n] := 0X;
			f := Files.Old(full);
			IF f = NIL THEN RETURN NIL END;
			Files.OpenReader(r, f, 0);
			RETURN r
		END Open;
	END FileSource;

	(* the bytes of one archive entry, served as a stream *)
	MemReceiver = OBJECT
	VAR
		data: POINTER TO ARRAY OF CHAR;
		size, pos: SIZE;

		PROCEDURE Receive(VAR buf: ARRAY OF CHAR; ofs, len, min: SIZE; VAR got: SIZE; VAR res: INTEGER);
		VAR n, i: SIZE;
		BEGIN
			n := size - pos;
			IF n > len THEN n := len END;
			IF n <= 0 THEN
				got := 0; res := Streams.EOF
			ELSE
				FOR i := 0 TO n - 1 DO buf[ofs + i] := data[pos + i] END;
				INC(pos, n); got := n; res := Streams.Ok
			END
		END Receive;
	END MemReceiver;

	(** the files of a ZIP archive. If everything in the archive lies in one top folder ("help/index.md",
	    "help/images/a.png"), that folder is skipped: the names used by the viewer are always relative
	    to the content ("index.md", "images/a.png"). *)
	ZipSource* = OBJECT(Source)
	VAR
		arc: Zip.Archive;
		prefix: ARRAY 128 OF CHAR;	(* "" or "folder/" *)

		PROCEDURE &Init*(a: Zip.Archive);
		VAR ent: Zip.Entry; i: SIGNED32; ok: BOOLEAN;
		BEGIN
			arc := a; prefix[0] := 0X;
			ent := Zip.FirstEntry(arc);
			IF ent = NIL THEN RETURN END;
			i := 0;
			WHILE (ent.name[i] # 0X) & (ent.name[i] # '/') & (i < LEN(prefix) - 2) DO
				prefix[i] := ent.name[i]; INC(i)
			END;
			IF ent.name[i] # '/' THEN prefix[0] := 0X; RETURN END;
			prefix[i] := '/'; prefix[i + 1] := 0X;
			ok := TRUE;
			WHILE ok & (ent # NIL) DO
				ok := StartsWith(ent.name, prefix);
				ent := Zip.NextEntry(ent)
			END;
			IF ~ok THEN prefix[0] := 0X END
		END Init;

		PROCEDURE Pages*(): NameList;
		VAR ent: Zip.Entry; first, last, n: NameList; k, len, j: SIGNED32;
		BEGIN
			first := NIL; last := NIL;
			k := 0; WHILE prefix[k] # 0X DO INC(k) END;
			ent := Zip.FirstEntry(arc);
			WHILE ent # NIL DO
				IF StartsWith(ent.name, prefix) THEN
					len := 0; WHILE ent.name[k + len] # 0X DO INC(len) END;
					IF (len > 3) & (ent.name[k + len - 3] = '.') & ((ent.name[k + len - 2] = 'm') OR (ent.name[k + len - 2] = 'M'))
							& ((ent.name[k + len - 1] = 'd') OR (ent.name[k + len - 1] = 'D')) THEN
						NEW(n); n.next := NIL;
						FOR j := 0 TO len - 1 DO n.name[j] := ent.name[k + j] END;
						n.name[len] := 0X;
						IF last # NIL THEN last.next := n ELSE first := n END;
						last := n
					END
				END;
				ent := Zip.NextEntry(ent)
			END;
			RETURN first
		END Pages;

		PROCEDURE Open*(CONST path: ARRAY OF CHAR): Streams.Reader;
		VAR full: ARRAY 512 OF CHAR; ent: Zip.Entry; rd: Zip.Reader; res: INTEGER;
			data: POINTER TO ARRAY OF CHAR; size, got, n: SIZE; m: MemReceiver; r: Streams.Reader; i, k: SIGNED32;
		BEGIN
			k := 0; i := 0;
			WHILE prefix[i] # 0X DO full[k] := prefix[i]; INC(k); INC(i) END;
			i := 0;
			WHILE (path[i] # 0X) & (k < LEN(full) - 1) DO full[k] := path[i]; INC(k); INC(i) END;
			full[k] := 0X;
			ent := Zip.GetEntry(arc, full, res);
			IF ent = NIL THEN RETURN NIL END;
			size := ent.uncompSize;
			NEW(data, size + 1);
			rd := Zip.OpenReader(arc, ent);
			IF rd.res # Zip.Ok THEN
				KernelLog.String("MDSource: cannot unpack "); KernelLog.String(full); KernelLog.Ln;
				RETURN NIL
			END;
			got := 0;
			WHILE got < size DO
				Zip.ReadBytes(rd, data^, got, size - got, n);
				IF n <= 0 THEN size := got ELSE INC(got, n) END	(* a truncated entry ends the loop *)
			END;
			Zip.Close(rd);
			IF rd.res # Zip.Ok THEN
				KernelLog.String("MDSource: damaged archive entry "); KernelLog.String(full); KernelLog.Ln;
				RETURN NIL
			END;
			NEW(m); m.data := data; m.size := size; m.pos := 0;
			Streams.OpenReader(r, m.Receive);
			RETURN r
		END Open;
	END ZipSource;

(* does s start with p? *)
PROCEDURE StartsWith(CONST s, p: ARRAY OF CHAR): BOOLEAN;
VAR i: SIGNED32;
BEGIN
	i := 0;
	WHILE (p[i] # 0X) & (s[i] = p[i]) DO INC(i) END;
	RETURN p[i] = 0X
END StartsWith;

(** opens a ZIP archive as a Source; NIL, with a message in the log, if that is not possible *)
PROCEDURE OpenZip*(CONST file: ARRAY OF CHAR): Source;
VAR arc: Zip.Archive; res: INTEGER; z: ZipSource;
BEGIN
	arc := Zip.OpenArchive(file, res);
	IF (arc = NIL) OR (res # Zip.Ok) THEN
		KernelLog.String("MDSource: cannot open archive "); KernelLog.String(file); KernelLog.String(" - ");
		IF res = Zip.FileError THEN KernelLog.String("file not found")
		ELSIF res = Zip.NotZipArchiveError THEN KernelLog.String("not a ZIP archive")
		ELSE KernelLog.String("error "); KernelLog.Int(res, 0)
		END;
		KernelLog.Ln;
		RETURN NIL
	END;
	NEW(z, arc);
	RETURN z
END OpenZip;

(** the page `page` links to `link`: the directory of the page is put in front of a relative link and
    "." and ".." are removed; a link that starts with '/' is relative to the root of the source *)
PROCEDURE Resolve*(CONST page, link: ARRAY OF CHAR; VAR full: ARRAY OF CHAR);
VAR joined: ARRAY 512 OF CHAR; seg: ARRAY 256 OF CHAR; i, j, k, n, last: SIGNED32;
BEGIN
	n := 0;
	IF link[0] # '/' THEN	(* start with the directory of the page *)
		last := -1; i := 0;
		WHILE page[i] # 0X DO IF page[i] = '/' THEN last := i END; INC(i) END;
		FOR i := 0 TO last DO
			IF n < LEN(joined) - 1 THEN joined[n] := page[i]; INC(n) END
		END
	END;
	i := 0; IF link[0] = '/' THEN i := 1 END;
	WHILE (link[i] # 0X) & (n < LEN(joined) - 1) DO joined[n] := link[i]; INC(n); INC(i) END;
	joined[n] := 0X;
	(* remove "." and ".." *)
	n := 0; i := 0;
	WHILE joined[i] # 0X DO
		j := 0;
		WHILE (joined[i] # 0X) & (joined[i] # '/') & (j < LEN(seg) - 1) DO seg[j] := joined[i]; INC(j); INC(i) END;
		seg[j] := 0X;
		WHILE (joined[i] # 0X) & (joined[i] # '/') DO INC(i) END;	(* a segment that was too long *)
		IF joined[i] = '/' THEN INC(i) END;
		IF (seg[0] = 0X) OR (seg = ".") THEN
			(* nothing *)
		ELSIF seg = ".." THEN
			k := n;
			WHILE (k > 0) & (full[k - 1] # '/') DO DEC(k) END;
			IF k > 0 THEN DEC(k) END;	(* the slash in front of the last segment goes too *)
			n := k
		ELSIF n + j + 2 < LEN(full) THEN
			IF n > 0 THEN full[n] := '/'; INC(n) END;
			FOR k := 0 TO j - 1 DO full[n] := seg[k]; INC(n) END
		END
	END;
	full[n] := 0X
END Resolve;

(* the extension of a file name without the dot, in upper case *)
PROCEDURE Extension(CONST name: ARRAY OF CHAR; VAR ext: ARRAY OF CHAR);
VAR i, dot, k: SIGNED32;
BEGIN
	dot := -1; i := 0;
	WHILE name[i] # 0X DO IF name[i] = '.' THEN dot := i END; INC(i) END;
	k := 0;
	IF dot >= 0 THEN
		i := dot + 1;
		WHILE (name[i] # 0X) & (k < LEN(ext) - 1) DO ext[k] := name[i]; INC(k); INC(i) END
	END;
	ext[k] := 0X;
	Strings.UpperCase(ext)
END Extension;

(** decodes a picture from a stream; the type is taken from the extension of name; NIL if it fails *)
PROCEDURE DecodeImage*(in: Streams.Reader; CONST name: ARRAY OF CHAR): WMGraphics.Image;
VAR decoder: Codecs.ImageDecoder; ext: ARRAY 16 OF CHAR; res: INTEGER; w, h: SIZE; x: SIGNED32;
	img: WMGraphics.Image;
BEGIN
	IF in = NIL THEN RETURN NIL END;
	Extension(name, ext);
	decoder := Codecs.GetImageDecoder(ext);
	IF decoder = NIL THEN
		KernelLog.String("MDSource: no image decoder for "); KernelLog.String(ext); KernelLog.Ln;
		RETURN NIL
	END;
	decoder.Open(in, res);
	IF res # 0 THEN
		KernelLog.String("MDSource: the decoder rejected "); KernelLog.String(name);
		KernelLog.String(", res = "); KernelLog.Int(res, 0); KernelLog.Ln;
		RETURN NIL
	END;
	decoder.GetImageInfo(w, h, x, x);
	NEW(img);
	Raster.Create(img, w, h, Raster.BGRA8888);
	decoder.Render(img);
	RETURN img
END DecodeImage;

END MDSource.
