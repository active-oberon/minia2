MODULE Table;
IMPORT Pager, PageLayout;

TYPE
  RecordId* = RECORD
    page*: SIZE;
    slot*: SIZE;
  END;


  Table* = RECORD
    db: Pager.DB;
    firstPage: SIGNED32;
    lastPage: SIGNED32;
  END;

PROCEDURE Open*(VAR t: Table; VAR db: Pager.DB; firstPage, lastPage: SIGNED32);
(* Opens the heap table with explicit page range (page 0 reserved for DBMeta). *)
BEGIN
  t.db := db;
  t.firstPage := firstPage;
  t.lastPage := lastPage
END Open;


PROCEDURE SetLastPage*(VAR t: Table; lastPage: SIGNED32);
(* Updates the last heap page id after the DB allocator extends the heap. *)
BEGIN
  t.lastPage := lastPage
END SetLastPage;


PROCEDURE EnsureFirstPage(VAR t: Table);
(* Ensures that the first heap page exists and is initialized. *)
VAR pc: SIGNED32; p: Pager.Page;
BEGIN
  pc := Pager.PageCount(t.db);
  IF pc <= t.firstPage THEN
    p.id := t.firstPage;
    PageLayout.Init(p.data);
    Pager.WritePage(t.db, p)
  END
END EnsureFirstPage;

PROCEDURE Insert*(VAR t: Table;
                  CONST rec: ARRAY OF CHAR; len: SIZE;
                  VAR rid: RecordId): BOOLEAN;
VAR
  pc: SIGNED32;
  p: Pager.Page;
  slot: SIZE;
  ok: BOOLEAN;
BEGIN
  EnsureFirstPage(t);

	pc := Pager.PageCount(t.db);
  IF pc <= t.firstPage THEN
    (* EnsureFirstPage already should have created it, but be defensive *)
    p.id := t.firstPage
  ELSE
    p.id := pc - 1
  END;
  
  Pager.ReadPage(t.db, p.id, p);

  ok := PageLayout.InsertReuse(p.data, rec, len, slot);
  IF ok THEN
    Pager.WritePage(t.db, p);
    rid.page := p.id; rid.slot := slot;
    RETURN TRUE
  END;

  (* пробуємо compact тієї ж сторінки *)
  ok := PageLayout.Compact(p.data);
  IF ok THEN
    ok := PageLayout.InsertReuse(p.data, rec, len, slot);
    IF ok THEN
      Pager.WritePage(t.db, p);
      rid.page := p.id; rid.slot := slot;
      RETURN TRUE
    END
  END;

  (* створюємо нову сторінку *)
  p.id := pc;
  PageLayout.Init(p.data);
  ok := PageLayout.InsertReuse(p.data, rec, len, slot);
  IF ~ok THEN RETURN FALSE END;

  Pager.WritePage(t.db, p);
  rid.page := p.id; rid.slot := slot;
  RETURN TRUE
END Insert;

PROCEDURE Get*(VAR t: Table; rid: RecordId;
               VAR buf: ARRAY OF CHAR; VAR len: SIZE): BOOLEAN;
VAR p: Pager.Page;
BEGIN
  IF rid.page < 0 THEN RETURN FALSE END;
  Pager.ReadPage(t.db, rid.page, p);
  RETURN PageLayout.Get(p.data, rid.slot, buf, len)
END Get;

PROCEDURE Delete*(VAR t: Table; rid: RecordId): BOOLEAN;
VAR
  p: Pager.Page;
  ok: BOOLEAN;
BEGIN
  IF rid.page < 0 THEN RETURN FALSE END;
  Pager.ReadPage(t.db, rid.page, p);
  ok := PageLayout.Delete(p.data, rid.slot);
  IF ok THEN Pager.WritePage(t.db, p) END;
  RETURN ok
END Delete;

END Table.
