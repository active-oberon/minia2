MODULE DemoKV2;
IMPORT KVStoreV2, SqlParse, SqlExec, KernelLog;

VAR
  s: KVStoreV2.Store;
  ok: BOOLEAN;
  buf: ARRAY 256 OF CHAR;
  len: SIZE;

PROCEDURE StrLen(CONST x: ARRAY OF CHAR): SIZE;
(* Returns length of a 0X-terminated string as SIZE. *)
VAR i: SIZE;
BEGIN
  i := 0;
  WHILE (i < LEN(x)) & (x[i] # 0X) DO INC(i) END;
  RETURN i
END StrLen;

PROCEDURE ClampIndex(VAR n: SIZE; limit: SIZE);
(* Clamps an index into [0..limit-1]; handles limit=0 safely. *)
BEGIN
  IF limit = 0 THEN
    n := 0
  ELSIF n >= limit THEN
    n := limit - 1
  END
END ClampIndex;

PROCEDURE ShowBuf(CONST prefix: ARRAY OF CHAR; VAR b: ARRAY OF CHAR; n: SIZE);
(* Prints buffer as a string by ensuring 0X termination at position n (clamped). *)
VAR m: SIZE;
BEGIN
  m := n;
  ClampIndex(m, LEN(b));
  b[m] := 0X;

  KernelLog.String(prefix);
  KernelLog.String(b);
  KernelLog.Ln
END ShowBuf;

PROCEDURE ParseAndExec(CONST sql: ARRAY OF CHAR; CONST p0, p1: ARRAY OF CHAR);
(* Parses one SQL statement and executes it via SqlExec; prints parse/exec status. *)
VAR
  p: SqlParse.Parser;
  st: SqlParse.Statement;
  msg: ARRAY 200 OF CHAR;
  line, col: SIGNED32;
  outLen: SIZE;
  okParse, okExec: BOOLEAN;
BEGIN
  SqlParse.Init(p, sql);
  okParse := SqlParse.Parse(p, st);

  KernelLog.String("SQL: "); KernelLog.String(sql); KernelLog.Ln;
  KernelLog.String("SQL Parse ok="); KernelLog.Boolean(okParse); KernelLog.Ln;

  IF ~okParse THEN
    SqlParse.Error(p, msg, line, col);
    KernelLog.String("ParseError @"); KernelLog.Int(line, 1);
    KernelLog.Char(":"); KernelLog.Int(col, 1);
    KernelLog.String(" "); KernelLog.String(msg); KernelLog.Ln;
    KernelLog.Ln;
    RETURN
  END;

  outLen := 0;
  okExec := SqlExec.Exec(s, st, p0, p1, buf, outLen);
  KernelLog.String("SQL Exec ok="); KernelLog.Boolean(okExec); KernelLog.Ln;

  IF okExec THEN
    ShowBuf("SQL Result = ", buf, outLen)
  END;

  KernelLog.Ln
END ParseAndExec;

PROCEDURE Run*;
(* Runs KV demo + SQL INSERT/SELECT/UPDATE/DELETE end-to-end on single-file db.a2db. *)
VAR
  v1, v2: ARRAY 16 OF CHAR;
  l1, l2: SIZE;

  sql: ARRAY 512 OF CHAR;
  p0: ARRAY 64 OF CHAR;
  p1: ARRAY 64 OF CHAR;
BEGIN
  KVStoreV2.Open(s, "db.a2db");

  (* Seed via KV API *)
  v1 := "Hello"; l1 := StrLen(v1);
  ok := KVStoreV2.PutOrUpdate(s, "user:1", v1, l1);
  KernelLog.String("PutOrUpdate #1 ok="); KernelLog.Boolean(ok); KernelLog.Ln;

  v2 := "World"; l2 := StrLen(v2);
  ok := KVStoreV2.PutOrUpdate(s, "user:1", v2, l2);
  KernelLog.String("PutOrUpdate #2 ok="); KernelLog.Boolean(ok); KernelLog.Ln;

  ok := KVStoreV2.Get(s, "user:1", buf, len);
  KernelLog.String("Get user:1 ok="); KernelLog.Boolean(ok); KernelLog.Ln;
  IF ok THEN ShowBuf("Value user:1 = ", buf, len) END;

  ok := KVStoreV2.Get(s, "missing", buf, len);
  KernelLog.String("Get missing ok="); KernelLog.Boolean(ok); KernelLog.Ln;

  KernelLog.Ln;

  (* SQL INSERT (both forms) *)
  sql := "INSERT INTO kv VALUES ('user:2', 'Hello2');";
  p0 := ""; p1 := "";
  ParseAndExec(sql, p0, p1);

  sql := "INSERT INTO kv(key, value) VALUES ('user:3', 'Hello3');";
  p0 := ""; p1 := "";
  ParseAndExec(sql, p0, p1);

  (* Parameterized INSERT: VALUES(?, ?) *)
  sql := "INSERT INTO kv VALUES (?, ?);";
  p0 := "user:9";
  p1 := "Nine";
  ParseAndExec(sql, p0, p1);

  (* Verify inserted keys via KV API *)
  ok := KVStoreV2.Get(s, "user:2", buf, len);
  KernelLog.String("Get user:2 ok="); KernelLog.Boolean(ok); KernelLog.Ln;
  IF ok THEN ShowBuf("Value user:2 = ", buf, len) END;

  ok := KVStoreV2.Get(s, "user:3", buf, len);
  KernelLog.String("Get user:3 ok="); KernelLog.Boolean(ok); KernelLog.Ln;
  IF ok THEN ShowBuf("Value user:3 = ", buf, len) END;

  ok := KVStoreV2.Get(s, "user:9", buf, len);
  KernelLog.String("Get user:9 ok="); KernelLog.Boolean(ok); KernelLog.Ln;
  IF ok THEN ShowBuf("Value user:9 = ", buf, len) END;

  KernelLog.Ln;

  (* SQL UPDATE: UPDATE kv SET value=? WHERE id=?; *)
  sql := "UPDATE kv SET value = ? WHERE id = ?;";
  p0 := "Updated";
  p1 := "user:2";
  ParseAndExec(sql, p0, p1);

  ok := KVStoreV2.Get(s, "user:2", buf, len);
  KernelLog.String("Get user:2 after UPDATE ok="); KernelLog.Boolean(ok); KernelLog.Ln;
  IF ok THEN ShowBuf("Value user:2 = ", buf, len) END;

  KernelLog.Ln;

  (* SQL DELETE: DELETE FROM kv WHERE id=?; *)
  sql := "DELETE FROM kv WHERE id = ?;";
  p0 := "user:3";
  p1 := "";
  ParseAndExec(sql, p0, p1);

  ok := KVStoreV2.Get(s, "user:3", buf, len);
  KernelLog.String("Get user:3 after DELETE ok="); KernelLog.Boolean(ok); KernelLog.Ln;

  KernelLog.Ln;

  (* SQL SELECT: SELECT ... WHERE id=? ... *)
  sql := "SELECT [User Name], Col FROM [My Table] WHERE id = ? AND name = 'O''Brien';";
  p0 := "user:1";
  p1 := "";
  ParseAndExec(sql, p0, p1)
END Run;

END DemoKV2.Run~
System.Free DemoKV2 SqlExec ~
System.Free DemoKV2 SqlExec SqlParse SqlScan ~
System.Free DemoKV2 SqlExec SqlParse SqlScan KVStoreV2 DB DBMeta Table BTreeStr PageLayout Pager ~


Compiler.Compile SqlScan.mod SqlParse.mod SqlExec.mod DemoKV2.mod ~
Compiler.Compile Pager.mod PageLayout.mod Table.mod DBMeta.mod BTreeStr.mod DB.mod KVStoreV2.mod SqlScan.mod SqlParse.mod SqlExec.mod DemoKV2.mod ~