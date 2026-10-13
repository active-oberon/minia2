
MODULE BTreeStr;
IMPORT SYSTEM, Pager, KernelLog;

CONST
  KeySize* = 32;      (* 31 символ + 0X *)
  MaxKeys  = 64;      (* під 4KB сторінку для KeySize=32 *)

TYPE
  Key* = ARRAY KeySize OF CHAR;

  RecordId* = RECORD
    page*: SIZE;
    slot*: SIZE;
  END;

  Index* = RECORD
    db: Pager.DB;
    root*: SIZE;
  END;

  Meta = RECORD
    magic: ARRAY 4 OF CHAR;   (* "AODB" *)
    version: SIZE;        (* 1 *)
    keySize: SIZE;        (* 32 *)
    root: SIZE;           (* pageId кореня *)
  END;

  NodeHeader = RECORD
    isLeaf: BOOLEAN;
    count: SIZE;
    pad: SIZE;
    right: SIZE;          (* тільки для leaf: правий сусід, -1 *)
  END;

  LeafNode = RECORD
    h: NodeHeader;
    keys: ARRAY MaxKeys OF Key;
    ridPage: ARRAY MaxKeys OF SIZE;
    ridSlot: ARRAY MaxKeys OF SIZE;
  END;

  InternalNode = RECORD
    h: NodeHeader;
    keys: ARRAY MaxKeys OF Key;
    child: ARRAY MaxKeys+1 OF SIZE;
  END;


(* ========================================================= *)
(* Key utils                                                   *)
(* ========================================================= *)

PROCEDURE KeyClear(VAR k: Key);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < KeySize DO k[i] := 0X; INC(i) END
END KeyClear;

PROCEDURE KeyFromString*(CONST s: ARRAY OF CHAR; VAR k: Key): BOOLEAN;
VAR i: INTEGER;
BEGIN
  KeyClear(k);
  i := 0;
  WHILE (i < KeySize-1) & (s[i] # 0X) DO
    k[i] := s[i]; INC(i)
  END;
  IF s[i] # 0X THEN RETURN FALSE END;  (* задовгий ключ *)
  RETURN TRUE
END KeyFromString;

PROCEDURE KeyCmp(CONST a, b: Key): INTEGER;
VAR i: INTEGER; ca, cb: CHAR;
BEGIN
  i := 0;
  WHILE i < KeySize DO
    ca := a[i]; cb := b[i];
    IF ca # cb THEN RETURN ORD(ca) - ORD(cb) END;
    INC(i)
  END;
  RETURN 0
END KeyCmp;

PROCEDURE KeyCopy(CONST src: Key; VAR dst: Key);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(src), SYSTEM.ADR(dst), KeySize)
END KeyCopy;

(* ========================================================= *)
(* Low-level page read/write                                  *)
(* ========================================================= *)

PROCEDURE ClearPage(VAR p: Pager.Page);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < Pager.PageSize DO p.data[i] := 0X; INC(i) END
END ClearPage;

PROCEDURE LoadHeader(VAR p: Pager.Page; VAR h: NodeHeader);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(p.data[0]), SYSTEM.ADR(h), SIZEOF(NodeHeader))
END LoadHeader;

PROCEDURE LoadLeaf(VAR p: Pager.Page; VAR n: LeafNode);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(p.data[0]), SYSTEM.ADR(n), SIZEOF(LeafNode))
END LoadLeaf;

PROCEDURE StoreLeaf(VAR p: Pager.Page; CONST n: LeafNode);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(n), SYSTEM.ADR(p.data[0]), SIZEOF(LeafNode))
END StoreLeaf;

PROCEDURE LoadInternal(VAR p: Pager.Page; VAR n: InternalNode);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(p.data[0]), SYSTEM.ADR(n), SIZEOF(InternalNode))
END LoadInternal;

PROCEDURE StoreInternal(VAR p: Pager.Page; CONST n: InternalNode);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(n), SYSTEM.ADR(p.data[0]), SIZEOF(InternalNode))
END StoreInternal;

(* ========================================================= *)
(* Meta (page 0)                                               *)
(* ========================================================= *)

PROCEDURE EnsureSuperblock(VAR idx: Index);
VAR pc: SIZE; p: Pager.Page;
BEGIN
  pc := Pager.PageCount(idx.db);
  IF pc = 0 THEN
    p.id := 0; ClearPage(p);
    Pager.WritePage(idx.db, p)
  END
END EnsureSuperblock;

PROCEDURE MetaRead(VAR idx: Index; VAR m: Meta): BOOLEAN;
VAR p: Pager.Page;
BEGIN
  IF Pager.PageCount(idx.db) = 0 THEN RETURN FALSE END;
  Pager.ReadPage(idx.db, 0, p);
  SYSTEM.MOVE(SYSTEM.ADR(p.data[0]), SYSTEM.ADR(m), SIZEOF(Meta));
  RETURN (m.magic[0]="A") & (m.magic[1]="O") & (m.magic[2]="D") & (m.magic[3]="B")
         & (m.version = 1) & (m.keySize = KeySize)
END MetaRead;

PROCEDURE MetaWrite(VAR idx: Index; root: SIZE);
VAR p: Pager.Page; m: Meta;
BEGIN
  p.id := 0; ClearPage(p);
  m.magic[0] := "A"; m.magic[1] := "O"; m.magic[2] := "D"; m.magic[3] := "B";
  m.version := 1;
  m.keySize := KeySize;
  m.root := root;
  SYSTEM.MOVE(SYSTEM.ADR(m), SYSTEM.ADR(p.data[0]), SIZEOF(Meta));
  Pager.WritePage(idx.db, p)
END MetaWrite;

PROCEDURE AllocNodePage(VAR idx: Index): SIZE;
VAR pc: SIZE; p: Pager.Page;
BEGIN
  EnsureSuperblock(idx);
  pc := Pager.PageCount(idx.db);
  IF pc < 1 THEN pc := 1 END;       (* page 0 reserved *)
  p.id := pc;
  ClearPage(p);
  Pager.WritePage(idx.db, p);
  RETURN pc
END AllocNodePage;

(* ========================================================= *)
(* Search helper                                                *)
(* ========================================================= *)

PROCEDURE LowerBound(CONST keys: ARRAY OF Key; n: SIZE; CONST key: Key): SIZE;
VAR lo, hi, mid: SIZE;
BEGIN
  lo := 0; hi := n;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    IF KeyCmp(keys[mid], key) < 0 THEN lo := mid + 1 ELSE hi := mid END
  END;
  RETURN lo
END LowerBound;

(* ========================================================= *)
(* Public init                                                   *)
(* ========================================================= *)

PROCEDURE OpenWithRoot*(VAR idx: Index; VAR db: Pager.DB; rootPage: SIGNED32);
(* Binds an index instance to an existing root page in the given database file. *)
BEGIN
  idx.db := db;
  idx.root := rootPage
END OpenWithRoot;

PROCEDURE CreateRoot*(VAR idx: Index; VAR db: Pager.DB; VAR rootPage: SIGNED32);
(* Creates a new empty leaf root page at end-of-file and returns its page id. *)
VAR
  pc: SIGNED32;
  p: Pager.Page;
  leaf: LeafNode;
  i: INTEGER;
BEGIN
  idx.db := db;

  pc := Pager.PageCount(db);
  IF pc < 1 THEN pc := 1 END;  (* page 0 reserved for DBMeta *)
  rootPage := pc;

  p.id := rootPage;
  i := 0;
  WHILE i < Pager.PageSize DO
    p.data[i] := 0X; INC(i)
  END;

  leaf.h.isLeaf := TRUE;
  leaf.h.count := 0;
  leaf.h.pad := 0;
  leaf.h.right := -1;

  i := 0;
  WHILE i < MaxKeys DO
    KeyClear(leaf.keys[i]);
    leaf.ridPage[i] := 0;
    leaf.ridSlot[i] := 0;
    INC(i)
  END;

  StoreLeaf(p, leaf);
  Pager.WritePage(db, p);

  idx.root := rootPage
END CreateRoot;

PROCEDURE OpenOrCreate*(VAR idx: Index; VAR db: Pager.DB);
VAR m: Meta; rootId: SIZE; p: Pager.Page; leaf: LeafNode; i: INTEGER;
BEGIN
  idx.db := db;
  EnsureSuperblock(idx);

  IF MetaRead(idx, m) THEN
    idx.root := m.root;
    RETURN
  END;

  rootId := AllocNodePage(idx);
  idx.root := rootId;

  leaf.h.isLeaf := TRUE;
  leaf.h.count := 0;
  leaf.h.pad := 0;
  leaf.h.right := -1;

  i := 0;
  WHILE i < MaxKeys DO
    KeyClear(leaf.keys[i]);
    leaf.ridPage[i] := 0;
    leaf.ridSlot[i] := 0;
    INC(i)
  END;

  p.id := rootId;
  StoreLeaf(p, leaf);
  Pager.WritePage(idx.db, p);

  MetaWrite(idx, rootId)
END OpenOrCreate;

(* ========================================================= *)
(* Find                                                          *)
(* ========================================================= *)

PROCEDURE Find*(VAR idx: Index; CONST key: Key; VAR rid: RecordId): BOOLEAN;
VAR pageId: SIZE; p: Pager.Page; h: NodeHeader; leaf: LeafNode; in: InternalNode; pos: SIZE;
VAR leafPage: SIZE; posOut: SIZE;
BEGIN


  leafPage := -1; posOut := -1;
  pageId := idx.root;

  LOOP
    Pager.ReadPage(idx.db, pageId, p);
    LoadHeader(p, h);

    IF h.isLeaf THEN
      LoadLeaf(p, leaf);
      pos := LowerBound(leaf.keys, leaf.h.count, key);

      leafPage := pageId;
(*      KernelLog.String("leafPage= "); KernelLog.Int(leafPage, 0); *)
      posOut := pos;

      IF (pos < leaf.h.count) & (KeyCmp(leaf.keys[pos], key) = 0) THEN
        rid.page := leaf.ridPage[pos];
        rid.slot := leaf.ridSlot[pos];
        RETURN TRUE
      ELSE
        RETURN FALSE
      END
    ELSE
      LoadInternal(p, in);
      pos := LowerBound(in.keys, in.h.count, key);

      (* важливо: separator == minKey(rightSubtree) => для рівності йдемо вправо *)
      IF (pos < in.h.count) & (KeyCmp(in.keys[pos], key) = 0) THEN INC(pos) END;

      pageId := in.child[pos]
    END
  END

 (* pageId := idx.root;
  LOOP
    Pager.ReadPage(idx.db, pageId, p);
    LoadHeader(p, h);

    IF h.isLeaf THEN
      LoadLeaf(p, leaf);
      pos := LowerBound(leaf.keys, leaf.h.count, key);
      IF (pos < leaf.h.count) & (KeyCmp(leaf.keys[pos], key) = 0) THEN
        rid.page := leaf.ridPage[pos];
        rid.slot := leaf.ridSlot[pos];
        RETURN TRUE
      ELSE
        RETURN FALSE
      END
    ELSE

		LoadInternal(p, in);
		pos := LowerBound(in.keys, in.h.count, key);
		IF (pos < in.h.count) & (KeyCmp(in.keys[pos], key) = 0) THEN
		  INC(pos)   (* ключ рівний separator -> йдемо вправо *)
		END;
		pageId := in.child[pos]
    END
  END*)
END Find;

(* ========================================================= *)
(* Leaf operations                                               *)
(* ========================================================= *)

PROCEDURE LeafInsert(VAR leaf: LeafNode; CONST key: Key; rid: RecordId; VAR inserted: BOOLEAN);
VAR pos, i: SIZE;
BEGIN
  inserted := FALSE;
  pos := LowerBound(leaf.keys, leaf.h.count, key);

  (* unique: duplicate check *)
  IF (pos < leaf.h.count) & (KeyCmp(leaf.keys[pos], key) = 0) THEN RETURN END;

  i := leaf.h.count;
  WHILE i > pos DO
    KeyCopy(leaf.keys[i-1], leaf.keys[i]);
    leaf.ridPage[i] := leaf.ridPage[i-1];
    leaf.ridSlot[i] := leaf.ridSlot[i-1];
    DEC(i)
  END;

  KeyCopy(key, leaf.keys[pos]);
  leaf.ridPage[pos] := rid.page;
  leaf.ridSlot[pos] := rid.slot;
  INC(leaf.h.count);
  inserted := TRUE
END LeafInsert;

PROCEDURE LeafSplitAndInsert(VAR idx: Index; VAR leftP: Pager.Page; VAR left: LeafNode;
                             CONST key: Key; rid: RecordId;
                             VAR sep: Key; VAR rightId: SIZE;
                             VAR inserted: BOOLEAN);
VAR
  rightP: Pager.Page;
  right: LeafNode;
  mid, i, j: SIZE;
  ins: BOOLEAN;
BEGIN
  inserted := FALSE;

  rightId := AllocNodePage(idx);
  rightP.id := rightId;

  right.h.isLeaf := TRUE;
  right.h.count := 0;
  right.h.pad := 0;
  right.h.right := left.h.right;

  mid := left.h.count DIV 2;

  j := 0; i := mid;
  WHILE i < left.h.count DO
    KeyCopy(left.keys[i], right.keys[j]);
    right.ridPage[j] := left.ridPage[i];
    right.ridSlot[j] := left.ridSlot[i];
    INC(right.h.count);
    INC(j); INC(i)
  END;

  left.h.count := mid;
  left.h.right := rightId;

  (* separator = перший ключ правого листа *)
  KeyCopy(right.keys[0], sep);

  (* вставляємо новий ключ у потрібний бік *)
  IF KeyCmp(key, sep) < 0 THEN
    LeafInsert(left, key, rid, ins)
  ELSE
    LeafInsert(right, key, rid, ins)
  END;

  inserted := ins;

  StoreLeaf(leftP, left);
  Pager.WritePage(idx.db, leftP);

  StoreLeaf(rightP, right);
  Pager.WritePage(idx.db, rightP)
END LeafSplitAndInsert;

(* ========================================================= *)
(* Internal operations                                           *)
(* ========================================================= *)

PROCEDURE InternalInsert(VAR in: InternalNode; pos: SIZE; CONST key: Key; rightChild: SIZE);
VAR i: SIZE;
BEGIN
  i := in.h.count;
  WHILE i > pos DO
    KeyCopy(in.keys[i-1], in.keys[i]);
    in.child[i+1] := in.child[i];
    DEC(i)
  END;

  KeyCopy(key, in.keys[pos]);
  in.child[pos+1] := rightChild;
  INC(in.h.count)
END InternalInsert;

PROCEDURE InternalSplitAndInsert(VAR idx: Index; VAR leftP: Pager.Page; VAR left: InternalNode;
                                 pos: SIZE; CONST key: Key; rightChild: SIZE;
                                 VAR up: Key; VAR rightId: SIZE);
VAR
  tmpKeys: ARRAY MaxKeys+1 OF Key;
  tmpChild: ARRAY MaxKeys+2 OF SIZE;
  total, mid: SIZE;
  i, j: SIZE;
  rightP: Pager.Page;
  right: InternalNode;
BEGIN
  (* total keys after insertion *)
  total := left.h.count + 1;

  (* children into tmp with insertion at pos+1 *)
  i := 0;
  WHILE i <= pos DO
    tmpChild[i] := left.child[i];
    INC(i)
  END;
  tmpChild[pos+1] := rightChild;
  i := pos+1;
  WHILE i <= left.h.count DO
    tmpChild[i+1] := left.child[i];
    INC(i)
  END;

  (* keys into tmp with insertion at pos *)
  i := 0;
  WHILE i < pos DO
    KeyCopy(left.keys[i], tmpKeys[i]);
    INC(i)
  END;
  KeyCopy(key, tmpKeys[pos]);
  i := pos;
  WHILE i < left.h.count DO
    KeyCopy(left.keys[i], tmpKeys[i+1]);
    INC(i)
  END;

  (* split point *)
  mid := total DIV 2;
  KeyCopy(tmpKeys[mid], up);

  (* allocate right *)
  rightId := AllocNodePage(idx);
  rightP.id := rightId;

  right.h.isLeaf := FALSE;
  right.h.count := 0;
  right.h.pad := 0;
  right.h.right := -1;

  (* left keeps keys [0..mid-1] *)
  left.h.count := 0;
  i := 0;
  WHILE i < mid DO
    KeyCopy(tmpKeys[i], left.keys[i]);
    INC(left.h.count);
    INC(i)
  END;

  (* left children [0..mid] *)
  i := 0;
  WHILE i <= mid DO
    left.child[i] := tmpChild[i];
    INC(i)
  END;

  (* right keys [mid+1..total-1] *)
  j := 0;
  i := mid + 1;
  WHILE i < total DO
    KeyCopy(tmpKeys[i], right.keys[j]);
    INC(right.h.count);
    INC(j); INC(i)
  END;

  (* right children [mid+1..total] *)
  j := 0;
  i := mid + 1;
  WHILE i <= total DO
    right.child[j] := tmpChild[i];
    INC(j); INC(i)
  END;

  StoreInternal(leftP, left);
  Pager.WritePage(idx.db, leftP);

  StoreInternal(rightP, right);
  Pager.WritePage(idx.db, rightP)
END InternalSplitAndInsert;

(* ========================================================= *)
(* Insert recursion                                              *)
(* ========================================================= *)

PROCEDURE InsertRec(VAR idx: Index; pageId: SIZE; CONST key: Key; rid: RecordId;
                    VAR inserted: BOOLEAN; VAR split: BOOLEAN; VAR sepKey: Key; VAR newRight: SIZE);
VAR
  p: Pager.Page;
  h: NodeHeader;
  leaf: LeafNode;
  in: InternalNode;
  pos: SIZE;
  childId: SIZE;
  childInserted, childSplit: BOOLEAN;
  childRight: SIZE;
  childSep: Key;
BEGIN
  inserted := FALSE; split := FALSE; newRight := -1;
  KeyClear(sepKey); KeyClear(childSep);

  Pager.ReadPage(idx.db, pageId, p);
  LoadHeader(p, h);

  IF h.isLeaf THEN
    LoadLeaf(p, leaf);

    (* якщо лист не повний — звичайна вставка *)
    IF leaf.h.count < MaxKeys THEN
      LeafInsert(leaf, key, rid, inserted);
      IF inserted THEN
        StoreLeaf(p, leaf);
        Pager.WritePage(idx.db, p)
      END;
      RETURN
    END;

    (* ЛИСТ ПОВНИЙ: СПОЧАТКУ ПЕРЕВІРКА ДУБЛІКАТА (ВАЖЛИВО!) *)
    pos := LowerBound(leaf.keys, leaf.h.count, key);
    IF (pos < leaf.h.count) & (KeyCmp(leaf.keys[pos], key) = 0) THEN
      inserted := FALSE;
      split := FALSE;
      RETURN
    END;

    (* не дублікат -> split + insert *)
    LeafSplitAndInsert(idx, p, leaf, key, rid, sepKey, newRight, inserted);
    split := TRUE;
    RETURN

  ELSE
			 
		LoadInternal(p, in);
		pos := LowerBound(in.keys, in.h.count, key);
		IF (pos < in.h.count) & (KeyCmp(in.keys[pos], key) = 0) THEN
		  INC(pos)   (* ключ рівний separator -> спуск вправо *)
		END;
		childId := in.child[pos];

    InsertRec(idx, childId, key, rid, childInserted, childSplit, childSep, childRight);
    inserted := childInserted;

    IF ~childSplit THEN
      RETURN
    END;

    (* вставити separator у поточний internal *)
    IF in.h.count < MaxKeys THEN
      InternalInsert(in, pos, childSep, childRight);
      StoreInternal(p, in);
      Pager.WritePage(idx.db, p);
      split := FALSE;
      RETURN
    END;

    (* split internal *)
    InternalSplitAndInsert(idx, p, in, pos, childSep, childRight, sepKey, newRight);
    split := TRUE;
    RETURN
  END
END InsertRec;

(* ========================================================= *)
(* Public Insert                                                  *)
(* ========================================================= *)

PROCEDURE Insert*(VAR idx: Index; CONST key: Key; rid: RecordId): BOOLEAN;
VAR
  oldRoot, newRootId, right: SIZE;
  inserted, split: BOOLEAN;
  sep: Key;
  p: Pager.Page;
  root: InternalNode;
BEGIN
  oldRoot := idx.root;
  KeyClear(sep);

  InsertRec(idx, oldRoot, key, rid, inserted, split, sep, right);

  IF ~inserted THEN
    RETURN FALSE    (* duplicate *)
  END;

  IF ~split THEN
    RETURN TRUE
  END;

  (* split кореня -> новий root internal *)
  newRootId := AllocNodePage(idx);
  idx.root := newRootId;

  root.h.isLeaf := FALSE;
  root.h.count := 1;
  root.h.pad := 0;
  root.h.right := -1;

  KeyCopy(sep, root.keys[0]);
  root.child[0] := oldRoot;
  root.child[1] := right;

  p.id := newRootId;
  StoreInternal(p, root);
  Pager.WritePage(idx.db, p);

  MetaWrite(idx, idx.root);
  RETURN TRUE
END Insert;

PROCEDURE Update*(VAR idx: Index; CONST key: Key; newRid: RecordId): BOOLEAN;
(*TODO (Bounds & unsigned safety):
- This prototype uses SIZE for lengths/indices in several places. SIZE is often unsigned, so
  DEC(x) or (x := x - 1) will underflow when x = 0 and wrap to a huge value.
- Before any decrement of a SIZE value, guard with: IF x # 0 THEN DEC(x) END; (or IF x > 0 THEN DEC(x) END;).
- Add explicit bounds checks before indexing arrays:
    * leaf position: 0 <= pos < leaf.count
    * internal child index: 0 <= pos <= internal.count   (child has count+1 entries)
- Replace patterns like: n := LEN(buf) - 1  with a safe clamp helper that handles LEN(buf)=0.
- Prefer small helper procedures:
    DecIfNonZero(VAR x: SIZE);
    ClampIndex(VAR i: SIZE; limit: SIZE);
  to avoid repeating subtle unsigned edge cases.
- In case of corrupted on-disk pages, return FALSE instead of triggering TRAP 7.*)
VAR
  pageId: SIZE;
  p: Pager.Page;
  h: NodeHeader;
  in: InternalNode;
  leaf: LeafNode;
  pos: SIZE;
BEGIN
  pageId := idx.root;

  LOOP
    Pager.ReadPage(idx.db, pageId, p);
    LoadHeader(p, h);

    IF h.isLeaf THEN
      LoadLeaf(p, leaf);
      pos := LowerBound(leaf.keys, leaf.h.count, key);

      IF (pos < leaf.h.count) & (KeyCmp(leaf.keys[pos], key) = 0) THEN
        leaf.ridPage[pos] := newRid.page;
        leaf.ridSlot[pos] := newRid.slot;
        StoreLeaf(p, leaf);
        Pager.WritePage(idx.db, p);
        RETURN TRUE
      ELSE
        RETURN FALSE
      END
    ELSE
      LoadInternal(p, in);
      pos := LowerBound(in.keys, in.h.count, key);
      IF (pos < in.h.count) & (KeyCmp(in.keys[pos], key) = 0) THEN INC(pos) END;
      pageId := in.child[pos]
    END
  END
END Update;


PROCEDURE DumpLeaf*(VAR idx: Index; pageId: SIZE; n: SIZE);
VAR
  p: Pager.Page;
  leaf: LeafNode;
  i: SIZE;
  s: ARRAY 40 OF CHAR;
BEGIN
  Pager.ReadPage(idx.db, pageId, p);
  LoadLeaf(p, leaf);

  KernelLog.String("DumpLeaf page="); KernelLog.Int(pageId, 1);
  KernelLog.String(" count="); KernelLog.Int(leaf.h.count, 1);
  KernelLog.String(" right="); KernelLog.Int(leaf.h.right, 1);
  KernelLog.Ln;

  i := 0;
  WHILE (i < n) & (i < leaf.h.count) DO
    (* скопіюємо ключ у s для друку *)
    SYSTEM.MOVE(SYSTEM.ADR(leaf.keys[i]), SYSTEM.ADR(s), KeySize);
    s[KeySize-1] := 0X;

    KernelLog.String("  "); KernelLog.Int(i, 1);
    KernelLog.String(" key="); KernelLog.String(s);
    KernelLog.String(" rid=("); KernelLog.Int(leaf.ridPage[i], 1);
    KernelLog.String(","); KernelLog.Int(leaf.ridSlot[i], 1);
    KernelLog.String(")");
    KernelLog.Ln;

    INC(i)
  END
END DumpLeaf;


BEGIN
  ASSERT(SIZEOF(LeafNode) <= Pager.PageSize);
  ASSERT(SIZEOF(InternalNode) <= Pager.PageSize)
END BTreeStr.
