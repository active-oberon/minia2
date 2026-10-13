MODULE KVStoreV2;
IMPORT DB, Table, BTreeStr;

TYPE
  Store* = RECORD
    h*: DB.Handle;
  END;

PROCEDURE Open*(VAR s: Store; CONST filename: ARRAY OF CHAR);
(* Opens or creates a single-file database and binds heap + index handles. *)
BEGIN
  DB.OpenOrCreate(s.h, filename)
END Open;

PROCEDURE Get*(VAR s: Store; CONST keyStr: ARRAY OF CHAR;
               VAR buf: ARRAY OF CHAR; VAR len: SIZE): BOOLEAN;
(* Finds key in BTree, then reads the value from heap; returns FALSE if missing or tombstoned. *)
VAR
  key: BTreeStr.Key;
  ridIdx: BTreeStr.RecordId;
  rid: Table.RecordId;
  okKey, okFind: BOOLEAN;
BEGIN
  okKey := BTreeStr.KeyFromString(keyStr, key);
  IF ~okKey THEN RETURN FALSE END;

  okFind := BTreeStr.Find(s.h.idx, key, ridIdx);
  IF ~okFind THEN RETURN FALSE END;

  rid.page := ridIdx.page;
  rid.slot := ridIdx.slot;

  RETURN Table.Get(s.h.tab, rid, buf, len)
END Get;

PROCEDURE PutUnique*(VAR s: Store; CONST keyStr: ARRAY OF CHAR;
                     CONST value: ARRAY OF CHAR; valueLen: SIZE): BOOLEAN;
(* Inserts a new key/value only if key does not exist; returns FALSE if key already exists. *)
VAR
  key: BTreeStr.Key;
  rid: Table.RecordId;
  ridIdx: BTreeStr.RecordId;
  okKey, okTab, okIdx, existed, okDel: BOOLEAN;
BEGIN
  okKey := BTreeStr.KeyFromString(keyStr, key);
  IF ~okKey THEN RETURN FALSE END;

  existed := BTreeStr.Find(s.h.idx, key, ridIdx);
  IF existed THEN RETURN FALSE END;

  okTab := Table.Insert(s.h.tab, value, valueLen, rid);
  IF ~okTab THEN RETURN FALSE END;

  ridIdx.page := rid.page;
  ridIdx.slot := rid.slot;

  okIdx := BTreeStr.Insert(s.h.idx, key, ridIdx);
  IF okIdx THEN
    RETURN TRUE
  ELSE
    okDel := Table.Delete(s.h.tab, rid);
    RETURN FALSE
  END
END PutUnique;

PROCEDURE UpdateOnly*(VAR s: Store; CONST keyStr: ARRAY OF CHAR;
                      CONST value: ARRAY OF CHAR; valueLen: SIZE): BOOLEAN;
(* Updates value only if key exists; returns FALSE if key is missing or update fails. *)
VAR
  key: BTreeStr.Key;
  oldIdxRid, newIdxRid: BTreeStr.RecordId;
  oldRid, newRid: Table.RecordId;
  okKey, existed, okTab, okIdx, okDel: BOOLEAN;
BEGIN
  okKey := BTreeStr.KeyFromString(keyStr, key);
  IF ~okKey THEN RETURN FALSE END;

  existed := BTreeStr.Find(s.h.idx, key, oldIdxRid);
  IF ~existed THEN RETURN FALSE END;

  okTab := Table.Insert(s.h.tab, value, valueLen, newRid);
  IF ~okTab THEN RETURN FALSE END;

  newIdxRid.page := newRid.page;
  newIdxRid.slot := newRid.slot;

  okIdx := BTreeStr.Update(s.h.idx, key, newIdxRid);
  IF ~okIdx THEN
    okDel := Table.Delete(s.h.tab, newRid);
    RETURN FALSE
  END;

  oldRid.page := oldIdxRid.page;
  oldRid.slot := oldIdxRid.slot;
  okDel := Table.Delete(s.h.tab, oldRid);

  RETURN TRUE
END UpdateOnly;

PROCEDURE PutOrUpdate*(VAR s: Store; CONST keyStr: ARRAY OF CHAR;
                       CONST value: ARRAY OF CHAR; valueLen: SIZE): BOOLEAN;
(* Upserts key/value: inserts if missing, otherwise updates index to a new heap record. *)
VAR
  key: BTreeStr.Key;
  existed: BOOLEAN;
  oldIdxRid, newIdxRid: BTreeStr.RecordId;
  oldRid, newRid: Table.RecordId;
  okKey, okTab, okIdx, okDel: BOOLEAN;
BEGIN
  okKey := BTreeStr.KeyFromString(keyStr, key);
  IF ~okKey THEN RETURN FALSE END;

  existed := BTreeStr.Find(s.h.idx, key, oldIdxRid);

  okTab := Table.Insert(s.h.tab, value, valueLen, newRid);
  IF ~okTab THEN RETURN FALSE END;

  newIdxRid.page := newRid.page;
  newIdxRid.slot := newRid.slot;

  IF existed THEN
    okIdx := BTreeStr.Update(s.h.idx, key, newIdxRid);
    IF ~okIdx THEN
      okDel := Table.Delete(s.h.tab, newRid);
      RETURN FALSE
    END;

    oldRid.page := oldIdxRid.page;
    oldRid.slot := oldIdxRid.slot;
    okDel := Table.Delete(s.h.tab, oldRid);
    RETURN TRUE
  ELSE
    okIdx := BTreeStr.Insert(s.h.idx, key, newIdxRid);
    IF ~okIdx THEN
      okDel := Table.Delete(s.h.tab, newRid);
      RETURN FALSE
    END;
    RETURN TRUE
  END
END PutOrUpdate;

PROCEDURE DeleteV1*(VAR s: Store; CONST keyStr: ARRAY OF CHAR): BOOLEAN;
(* Deletes heap record (tombstone) but keeps index entry (v1); Get() will return FALSE after delete. *)
VAR
  key: BTreeStr.Key;
  ridIdx: BTreeStr.RecordId;
  rid: Table.RecordId;
  okKey, okFind, okDel: BOOLEAN;
BEGIN
  okKey := BTreeStr.KeyFromString(keyStr, key);
  IF ~okKey THEN RETURN FALSE END;

  okFind := BTreeStr.Find(s.h.idx, key, ridIdx);
  IF ~okFind THEN RETURN FALSE END;

  rid.page := ridIdx.page;
  rid.slot := ridIdx.slot;

  okDel := Table.Delete(s.h.tab, rid);
  RETURN okDel
END DeleteV1;

END KVStoreV2.