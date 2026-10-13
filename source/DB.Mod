MODULE DB;
IMPORT Pager, DBMeta, Table, BTreeStr;

TYPE
  Handle* = RECORD
    db*: Pager.DB;
    meta*: DBMeta.Meta;
    tab*: Table.Table;
    idx*: BTreeStr.Index;
  END;

PROCEDURE ClearPage(VAR p: Pager.Page);
(* Fills a page buffer with 0X bytes. *)
VAR i: SIZE;
BEGIN
  i := 0; WHILE i < Pager.PageSize DO p.data[i] := 0X; INC(i) END
END ClearPage;

PROCEDURE AllocPage*(VAR h: Handle; VAR pageId: SIGNED32);
(* Allocates a new page id from meta.nextFreePage and physically extends the file. *)
VAR p: Pager.Page;
BEGIN
  pageId := h.meta.nextFreePage;
  INC(h.meta.nextFreePage);

  p.id := pageId;
  ClearPage(p);
  Pager.WritePage(h.db, p);

  DBMeta.Store(h.db, h.meta)
END AllocPage;

PROCEDURE OpenOrCreate*(VAR h: Handle; CONST filename: ARRAY OF CHAR);
(* Opens an existing A2DB file or creates a new one with a valid superblock and roots. *)
VAR ok: BOOLEAN; heap0, root: SIGNED32;
BEGIN
  Pager.Open(h.db, filename);

  ok := DBMeta.Load(h.db, h.meta);
  IF ~ok THEN
    DBMeta.Init(h.meta, BTreeStr.KeySize);
    DBMeta.Store(h.db, h.meta)
  END;

  (* Ensure heap first page exists and heapLastPage is set *)
  IF h.meta.heapLastPage = 0 THEN
    AllocPage(h, heap0);
    h.meta.heapFirstPage := heap0;
    h.meta.heapLastPage := heap0;
    DBMeta.Store(h.db, h.meta)
  END;

  Table.Open(h.tab, h.db, h.meta.heapFirstPage, h.meta.heapLastPage);

  (* Ensure btree root exists *)
  IF h.meta.btreeRootPage = 0 THEN
    BTreeStr.CreateRoot(h.idx, h.db, root);   (* create at EOF - see note below *)
    h.meta.btreeRootPage := root;
    (* Important: keep allocator consistent *)
    IF h.meta.nextFreePage <= root THEN h.meta.nextFreePage := root + 1 END;
    DBMeta.Store(h.db, h.meta)
  ELSE
    BTreeStr.OpenWithRoot(h.idx, h.db, h.meta.btreeRootPage)
  END
END OpenOrCreate;

END DB.