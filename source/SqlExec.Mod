MODULE SqlExec;
IMPORT SqlParse, SqlScan, KVStoreV2, Strings, KernelLog;

CONST
  MaxName = 256;

TYPE
  Params* = POINTER TO ARRAY OF ARRAY MaxName OF CHAR;

PROCEDURE StrLen(CONST x: ARRAY OF CHAR): SIZE;
(* Returns length of a 0X-terminated string as SIZE. *)
VAR i: SIZE;
BEGIN
  i := 0;
  WHILE (i < LEN(x)) & (x[i] # 0X) DO INC(i) END;
  RETURN i
END StrLen;

PROCEDURE StrEqCI(CONST a, b: ARRAY OF CHAR): BOOLEAN;
(* Compares two 0X-terminated strings case-insensitively (ASCII only). *)
VAR i: INTEGER; ca, cb: CHAR;
BEGIN
  i := 0;
  WHILE (a[i] # 0X) OR (b[i] # 0X) DO
    ca := a[i]; cb := b[i];
    Strings.UpperCaseChar(ca);
    Strings.UpperCaseChar(cb);
    IF ca # cb THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END StrEqCI;

PROCEDURE GetParam(params: Params; idx: INTEGER; VAR out: ARRAY OF CHAR): BOOLEAN;
(* Copies params[idx] into out; returns FALSE if params is NIL or idx out of range. *)
BEGIN
  out[0] := 0X;
  IF params = NIL THEN RETURN FALSE END;
  IF (idx < 0) OR (idx >= LEN(params^)) THEN RETURN FALSE END;
  COPY(params^[idx], out);
  RETURN TRUE
END GetParam;

PROCEDURE ValueToString(VAR v: SqlParse.Value; params: Params; paramIndex: INTEGER; VAR out: ARRAY OF CHAR): BOOLEAN;
(* Resolves a Value into a string buffer; maps '?' by paramIndex using params array. *)
VAR ok: BOOLEAN;
BEGIN
  out[0] := 0X;

  IF v.kind = SqlParse.vkString THEN
    COPY(v.text, out); RETURN TRUE
  ELSIF v.kind = SqlParse.vkIdent THEN
    COPY(v.text, out); RETURN TRUE
  ELSIF v.kind = SqlParse.vkParam THEN
    ok := GetParam(params, paramIndex, out);
    RETURN ok
  ELSE
    RETURN FALSE
  END
END ValueToString;

PROCEDURE ExtractKeyFromWhere(VAR conds: ARRAY OF SqlParse.Cond; condCount: INTEGER;
                              params: Params; defaultParamIndex: INTEGER;
                              VAR keyOut: ARRAY OF CHAR): BOOLEAN;
(* Extracts a key from WHERE conditions using id/key = (param or string/ident). *)
VAR i: INTEGER; c: SqlParse.Cond; ok: BOOLEAN;
BEGIN
  keyOut[0] := 0X;

  i := 0;
  WHILE i < condCount DO
    c := conds[i];

    IF (c.op = SqlScan.Eq) & (StrEqCI(c.left, "ID") OR StrEqCI(c.left, "KEY")) THEN
      IF c.right.kind = SqlParse.vkParam THEN
        ok := GetParam(params, defaultParamIndex, keyOut);
        RETURN ok
      ELSIF (c.right.kind = SqlParse.vkString) OR (c.right.kind = SqlParse.vkIdent) THEN
        COPY(c.right.text, keyOut);
        RETURN TRUE
      END
    END;

    INC(i)
  END;

  RETURN FALSE
END ExtractKeyFromWhere;

PROCEDURE ExecSelect(VAR store: KVStoreV2.Store; VAR sel: SqlParse.SelectStmt; params: Params;
                     VAR outBuf: ARRAY OF CHAR; VAR outLen: SIZE): BOOLEAN;
(* Executes SELECT by resolving key from WHERE and fetching value via KVStoreV2.Get. *)
VAR keyStr: ARRAY MaxName OF CHAR; ok: BOOLEAN;
BEGIN
  IF ~sel.hasWhere THEN RETURN FALSE END;

  ok := ExtractKeyFromWhere(sel.conds, sel.condCount, params, 0, keyStr);
  IF ~ok THEN RETURN FALSE END;

  RETURN KVStoreV2.Get(store, keyStr, outBuf, outLen)
END ExecSelect;

PROCEDURE ExecInsert(VAR store: KVStoreV2.Store; VAR ins: SqlParse.InsertStmt; params: Params;
                     VAR outBuf: ARRAY OF CHAR; VAR outLen: SIZE): BOOLEAN;
(* Executes INSERT via KVStoreV2.PutOrUpdate; supports VALUES(key,value) and (key,value) column list. *)
VAR
  keyStr, valStr: ARRAY MaxName OF CHAR;
  keyPos, valPos: INTEGER;
  i: INTEGER;
  okK, okV, ok: BOOLEAN;
  vlen: SIZE;
BEGIN
  keyStr[0] := 0X; valStr[0] := 0X;
  keyPos := -1; valPos := -1;

  IF ins.hasColumns THEN
    i := 0;
    WHILE i < ins.colCount DO
      IF StrEqCI(ins.cols[i], "KEY") OR StrEqCI(ins.cols[i], "ID") THEN
        keyPos := i
      ELSIF StrEqCI(ins.cols[i], "VALUE") OR StrEqCI(ins.cols[i], "VAL") THEN
        valPos := i
      END;
      INC(i)
    END;

    IF (keyPos < 0) OR (valPos < 0) THEN RETURN FALSE END;
    IF (keyPos >= ins.valueCount) OR (valPos >= ins.valueCount) THEN RETURN FALSE END
  ELSE
    IF ins.valueCount < 2 THEN RETURN FALSE END;
    keyPos := 0;
    valPos := 1
  END;

  okK := ValueToString(ins.values[keyPos], params, keyPos, keyStr);
  okV := ValueToString(ins.values[valPos], params, valPos, valStr);
  IF ~okK OR ~okV THEN RETURN FALSE END;

  vlen := StrLen(valStr);
  
(*KernelLog.String("ExecInsert key="); KernelLog.String(keyStr);
KernelLog.String(" val="); KernelLog.String(valStr); KernelLog.Ln;*)
  ok := KVStoreV2.PutOrUpdate(store, keyStr, valStr, vlen);

  IF ok THEN
    COPY("OK", outBuf);
    outLen := 2;
    RETURN TRUE
  ELSE
    RETURN FALSE
  END
END ExecInsert;

PROCEDURE ExecUpdate(VAR store: KVStoreV2.Store; VAR u: SqlParse.UpdateStmt; params: Params;
                     VAR outBuf: ARRAY OF CHAR; VAR outLen: SIZE): BOOLEAN;
(* Executes UPDATE kv SET value=? WHERE id=? using KVStoreV2.PutOrUpdate. *)
VAR
  keyStr, valStr: ARRAY MaxName OF CHAR;
  okKey, okVal, ok: BOOLEAN;
  vlen: SIZE;
BEGIN
  keyStr[0] := 0X; valStr[0] := 0X;

  IF ~u.hasWhere THEN RETURN FALSE END;

  (* Convention: params[0] is SET value, params[1] is WHERE key *)
  okVal := ValueToString(u.setVal, params, 0, valStr);
  IF ~okVal THEN RETURN FALSE END;

  okKey := ExtractKeyFromWhere(u.conds, u.condCount, params, 1, keyStr);
  IF ~okKey THEN RETURN FALSE END;

  vlen := StrLen(valStr);
  ok := KVStoreV2.PutOrUpdate(store, keyStr, valStr, vlen);

  IF ok THEN
    COPY("OK", outBuf);
    outLen := 2;
    RETURN TRUE
  ELSE
    RETURN FALSE
  END
END ExecUpdate;

PROCEDURE ExecDelete(VAR store: KVStoreV2.Store; VAR d: SqlParse.DeleteStmt; params: Params;
                     VAR outBuf: ARRAY OF CHAR; VAR outLen: SIZE): BOOLEAN;
(* Executes DELETE FROM kv WHERE id=? using KVStoreV2.DeleteV1. *)
VAR
  keyStr: ARRAY MaxName OF CHAR;
  okKey, ok: BOOLEAN;
BEGIN
  keyStr[0] := 0X;
  IF ~d.hasWhere THEN RETURN FALSE END;

  okKey := ExtractKeyFromWhere(d.conds, d.condCount, params, 0, keyStr);
  IF ~okKey THEN RETURN FALSE END;

  ok := KVStoreV2.DeleteV1(store, keyStr);

  IF ok THEN
    COPY("OK", outBuf);
    outLen := 2;
    RETURN TRUE
  ELSE
    RETURN FALSE
  END
END ExecDelete;

PROCEDURE ExecParams*(VAR store: KVStoreV2.Store; VAR st: SqlParse.Statement;
                      params: Params;
                      VAR outBuf: ARRAY OF CHAR; VAR outLen: SIZE): BOOLEAN;
(* Executes a parsed SQL statement using a params array (core execution entry). *)
BEGIN
  IF st.kind = SqlParse.stSelect THEN
    RETURN ExecSelect(store, st.select, params, outBuf, outLen)
  ELSIF st.kind = SqlParse.stInsert THEN
    RETURN ExecInsert(store, st.ins, params, outBuf, outLen)
  ELSIF st.kind = SqlParse.stUpdate THEN
    RETURN ExecUpdate(store, st.upd, params, outBuf, outLen)
  ELSIF st.kind = SqlParse.stDelete THEN
    RETURN ExecDelete(store, st.del, params, outBuf, outLen)
  ELSE
    RETURN FALSE
  END
END ExecParams;

PROCEDURE Exec*(VAR store: KVStoreV2.Store; VAR st: SqlParse.Statement;
                CONST p0, p1: ARRAY OF CHAR;
                VAR outBuf: ARRAY OF CHAR; VAR outLen: SIZE): BOOLEAN;
(* Convenience wrapper: executes with two string parameters mapped to params[0] and params[1]. *)
VAR ps: Params;
BEGIN
  NEW(ps, 2);
  COPY(p0, ps^[0]);
  COPY(p1, ps^[1]);
  RETURN ExecParams(store, st, ps, outBuf, outLen)
END Exec;

END SqlExec.