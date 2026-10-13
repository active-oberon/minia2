MODULE Pager;
IMPORT Files, Streams;

CONST
  PageSize* = 4096;

TYPE
  Page* = RECORD
    id*: SIZE;
    data*: ARRAY PageSize OF CHAR;
  END;

  DB* = RECORD
    file: Files.File;
  END;

PROCEDURE Open*(VAR db: DB; name: ARRAY OF CHAR);
BEGIN
  db.file := Files.Old(name);

  IF db.file = NIL THEN
    db.file := Files.New(name);
    IF db.file # NIL THEN
      Files.Register(db.file)   
    END
  END
END Open;

PROCEDURE PageCount*(VAR db: DB): SIGNED32;
VAR len: Files.Position;
BEGIN
  len := Files.Length(db.file);              (* офіційна обгортка  *)
  RETURN SIGNED32(len DIV PageSize)
END PageCount;

PROCEDURE ReadPage*(VAR db: DB; id: SIZE; VAR p: Page);
VAR
  r: Files.Reader;
  pos: Streams.Position;
  n: SIZE;
BEGIN
  pos := id * PageSize;
  p.id := id;

  Files.OpenReader(r, db.file, pos);         (* buffered reader *)
  r.Bytes(p.data, 0, PageSize, n);            (* читаємо до *)

  (* якщо файл коротший — добиваємо нулями *)
  WHILE n < PageSize DO
    p.data[n] := 0X;
    INC(n)
  END
END ReadPage;

PROCEDURE WritePage*(VAR db: DB; VAR p: Page);
VAR
  w: Files.Writer;
  pos: Streams.Position;
BEGIN
  pos := p.id * PageSize;

  Files.OpenWriter(w, db.file, pos);         (* buffered writer  *)
  w.Bytes(p.data, 0, PageSize);
  w.Update                                  (* flush буфера у файл  *)
END WritePage;

END Pager.
