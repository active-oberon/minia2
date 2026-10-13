MODULE SqlParse;
IMPORT SqlScan;

CONST
  MaxName*     = 256;
  MaxCols*     = 32;
  MaxConds*    = 16;
  MaxValues*   = 32;
  MaxColDefs*  = 32;

TYPE
  StmtKind* = INTEGER;

CONST
  stNone*        = 0;
  stSelect*      = 1;
  stInsert*      = 2;
  stCreateTable* = 3;
  stUpdate*      = 4;
  stDelete*      = 5;

TYPE
  ValueKind* = INTEGER;

CONST
  vkNone*    = 0;
  vkIdent*   = 1;
  vkString*  = 2;
  vkInt*     = 3;
  vkFloat*   = 4;
  vkParam*   = 5;

TYPE
  Value* = RECORD
    kind*: ValueKind;
    text*: ARRAY MaxName OF CHAR;
    quotedIdent*: BOOLEAN;
  END;

  Cond* = RECORD
    left*: ARRAY MaxName OF CHAR;
    leftQuoted*: BOOLEAN;
    op*: SqlScan.TokenKind;
    right*: Value;
  END;

  SelectStmt* = RECORD
    selectAll*: BOOLEAN;
    colCount*: INTEGER;
    cols*: ARRAY MaxCols OF ARRAY MaxName OF CHAR;
    colsQuoted*: ARRAY MaxCols OF BOOLEAN;

    table*: ARRAY MaxName OF CHAR;
    tableQuoted*: BOOLEAN;

    hasWhere*: BOOLEAN;
    condCount*: INTEGER;
    conds*: ARRAY MaxConds OF Cond;
  END;

  InsertStmt* = RECORD
    table*: ARRAY MaxName OF CHAR;
    tableQuoted*: BOOLEAN;

    hasColumns*: BOOLEAN;
    colCount*: INTEGER;
    cols*: ARRAY MaxCols OF ARRAY MaxName OF CHAR;
    colsQuoted*: ARRAY MaxCols OF BOOLEAN;

    valueCount*: INTEGER;
    values*: ARRAY MaxValues OF Value;
  END;

  UpdateStmt* = RECORD
    table*: ARRAY MaxName OF CHAR;
    tableQuoted*: BOOLEAN;

    setCol*: ARRAY MaxName OF CHAR;
    setColQuoted*: BOOLEAN;
    setVal*: Value;

    hasWhere*: BOOLEAN;
    condCount*: INTEGER;
    conds*: ARRAY MaxConds OF Cond;
  END;

  DeleteStmt* = RECORD
    table*: ARRAY MaxName OF CHAR;
    tableQuoted*: BOOLEAN;

    hasWhere*: BOOLEAN;
    condCount*: INTEGER;
    conds*: ARRAY MaxConds OF Cond;
  END;

  ColDef* = RECORD
    name*: ARRAY MaxName OF CHAR;
    nameQuoted*: BOOLEAN;
    typeName*: ARRAY MaxName OF CHAR;
  END;

  CreateTableStmt* = RECORD
    table*: ARRAY MaxName OF CHAR;
    tableQuoted*: BOOLEAN;
    colDefCount*: INTEGER;
    colDefs*: ARRAY MaxColDefs OF ColDef;
  END;

  Statement* = RECORD
    kind*: StmtKind;
    select*: SelectStmt;
    ins*: InsertStmt;
    upd*: UpdateStmt;
    del*: DeleteStmt;
    create*: CreateTableStmt;
  END;

  Parser* = RECORD
    sc: SqlScan.Scanner;
    tok: SqlScan.Token;
    err: ARRAY 200 OF CHAR;
    errLine, errCol: SIGNED32;
  END;

PROCEDURE CopyStr(CONST from: ARRAY OF CHAR; VAR to: ARRAY OF CHAR);
(* Copies a 0X-terminated string with truncation. *)
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(to)-1) & (from[i] # 0X) DO
    to[i] := from[i]; INC(i)
  END;
  to[i] := 0X
END CopyStr;

PROCEDURE SetErr(VAR p: Parser; CONST msg: ARRAY OF CHAR);
(* Stores parser error message and current token position. *)
BEGIN
  CopyStr(msg, p.err);
  p.errLine := p.tok.line;
  p.errCol := p.tok.col
END SetErr;

PROCEDURE NextTok(VAR p: Parser);
(* Advances to the next token from the scanner. *)
BEGIN
  SqlScan.Next(p.sc, p.tok)
END NextTok;

PROCEDURE IsKW(VAR p: Parser; CONST kw: ARRAY OF CHAR): BOOLEAN;
(* Returns TRUE if current token is the given keyword (scanner outputs KW in uppercase). *)
BEGIN
  RETURN (p.tok.kind = SqlScan.Keyword) & (p.tok.text = kw)
END IsKW;

PROCEDURE ExpectKW(VAR p: Parser; CONST kw: ARRAY OF CHAR): BOOLEAN;
(* Consumes the expected keyword token or sets an error. *)
BEGIN
  IF IsKW(p, kw) THEN
    NextTok(p);
    RETURN TRUE
  ELSE
    SetErr(p, "Expected keyword");
    RETURN FALSE
  END
END ExpectKW;

PROCEDURE ExpectKind(VAR p: Parser; k: SqlScan.TokenKind; CONST msg: ARRAY OF CHAR): BOOLEAN;
(* Consumes the expected token kind or sets an error message. *)
BEGIN
  IF p.tok.kind = k THEN
    NextTok(p);
    RETURN TRUE
  ELSE
    SetErr(p, msg);
    RETURN FALSE
  END
END ExpectKind;

PROCEDURE ParseIdent(VAR p: Parser; VAR name: ARRAY OF CHAR; VAR quoted: BOOLEAN; CONST msg: ARRAY OF CHAR): BOOLEAN;
(* Parses one identifier token into name/quoted flags. *)
BEGIN
  IF p.tok.kind # SqlScan.Ident THEN
    SetErr(p, msg);
    RETURN FALSE
  END;
  COPY(p.tok.text, name);
  quoted := p.tok.quotedIdent;
  NextTok(p);
  RETURN TRUE
END ParseIdent;

PROCEDURE ParseNameToken(VAR p: Parser; VAR name: ARRAY OF CHAR; VAR quoted: BOOLEAN; CONST msg: ARRAY OF CHAR): BOOLEAN;
(* Parses a name token that may be IDENT or KEYWORD (prototype-friendly). *)
BEGIN
  IF p.tok.kind = SqlScan.Ident THEN
    COPY(p.tok.text, name);
    quoted := p.tok.quotedIdent;
    NextTok(p);
    RETURN TRUE
  ELSIF p.tok.kind = SqlScan.Keyword THEN
    COPY(p.tok.text, name);
    quoted := FALSE;
    NextTok(p);
    RETURN TRUE
  ELSE
    SetErr(p, msg);
    RETURN FALSE
  END
END ParseNameToken;

PROCEDURE IsRelOp(k: SqlScan.TokenKind): BOOLEAN;
(* Returns TRUE for relation operators supported by the parser. *)
BEGIN
  RETURN (k = SqlScan.Eq) OR (k = SqlScan.Ne) OR
         (k = SqlScan.Lt) OR (k = SqlScan.Le) OR
         (k = SqlScan.Gt) OR (k = SqlScan.Ge)
END IsRelOp;

PROCEDURE Init*(VAR p: Parser; CONST sql: ARRAY OF CHAR);
(* Initializes parser and reads the first token from SQL input. *)
BEGIN
  SqlScan.Init(p.sc, sql);
  p.err := "";
  p.errLine := 0;
  p.errCol := 0;
  NextTok(p)
END Init;

PROCEDURE Error*(VAR p: Parser; VAR msg: ARRAY OF CHAR; VAR line, col: SIGNED32);
(* Returns the last parser error message and its location. *)
BEGIN
  CopyStr(p.err, msg);
  line := p.errLine;
  col := p.errCol
END Error;

PROCEDURE ParseValue(VAR p: Parser; VAR v: Value): BOOLEAN;
(* Parses a literal/identifier/parameter value token into Value. *)
BEGIN
  v.kind := vkNone;
  v.text := "";
  v.quotedIdent := FALSE;

  CASE p.tok.kind OF
    SqlScan.String:
      v.kind := vkString; CopyStr(p.tok.text, v.text); NextTok(p); RETURN TRUE
  | SqlScan.Int:
      v.kind := vkInt; CopyStr(p.tok.text, v.text); NextTok(p); RETURN TRUE
  | SqlScan.Float:
      v.kind := vkFloat; CopyStr(p.tok.text, v.text); NextTok(p); RETURN TRUE
  | SqlScan.Param:
      v.kind := vkParam; CopyStr(p.tok.text, v.text); NextTok(p); RETURN TRUE
  | SqlScan.Ident:
      v.kind := vkIdent; CopyStr(p.tok.text, v.text); v.quotedIdent := p.tok.quotedIdent; NextTok(p); RETURN TRUE
  | SqlScan.Keyword:
      (* Allow keywords as values in prototype mode *)
      v.kind := vkIdent; CopyStr(p.tok.text, v.text); v.quotedIdent := FALSE; NextTok(p); RETURN TRUE
  ELSE
      SetErr(p, "Expected value");
      RETURN FALSE
  END
END ParseValue;

PROCEDURE ParseCond(VAR p: Parser; VAR c: Cond): BOOLEAN;
(* Parses one condition: name op value (e.g., id = ?). *)
VAR ok: BOOLEAN;
BEGIN
  ok := ParseNameToken(p, c.left, c.leftQuoted, "Expected identifier in condition");
  IF ~ok THEN RETURN FALSE END;

  IF ~IsRelOp(p.tok.kind) THEN
    SetErr(p, "Expected relation operator");
    RETURN FALSE
  END;

  c.op := p.tok.kind;
  NextTok(p);

  RETURN ParseValue(p, c.right)
END ParseCond;

PROCEDURE ParseWhereConds(VAR p: Parser; VAR hasWhere: BOOLEAN; VAR count: INTEGER; VAR conds: ARRAY OF Cond): BOOLEAN;
(* Parses optional WHERE with AND-separated conditions. *)
VAR ok: BOOLEAN; i: INTEGER;
BEGIN
  hasWhere := FALSE;
  count := 0;

  IF IsKW(p, "WHERE") THEN
    hasWhere := TRUE;
    NextTok(p);

    i := 0;
    LOOP
      IF i >= MaxConds THEN
        SetErr(p, "Too many WHERE conditions");
        RETURN FALSE
      END;

      ok := ParseCond(p, conds[i]);
      IF ~ok THEN RETURN FALSE END;
      INC(i);

      IF IsKW(p, "AND") THEN
        NextTok(p)
      ELSE
        EXIT
      END
    END;

    count := i
  END;

  RETURN TRUE
END ParseWhereConds;

PROCEDURE ParseColList(VAR p: Parser; VAR s: SelectStmt): BOOLEAN;
(* Parses SELECT column list: '*' or name list separated by commas. *)
VAR i: INTEGER; ok: BOOLEAN;
BEGIN
  s.selectAll := FALSE;
  s.colCount := 0;

  IF p.tok.kind = SqlScan.Star THEN
    s.selectAll := TRUE;
    NextTok(p);
    RETURN TRUE
  END;

  i := 0;
  ok := ParseNameToken(p, s.cols[i], s.colsQuoted[i], "Expected column name or *");
  IF ~ok THEN RETURN FALSE END;
  INC(i);

  WHILE p.tok.kind = SqlScan.Comma DO
    NextTok(p);

    IF i >= MaxCols THEN
      SetErr(p, "Too many columns");
      RETURN FALSE
    END;

    ok := ParseNameToken(p, s.cols[i], s.colsQuoted[i], "Expected column name after comma");
    IF ~ok THEN RETURN FALSE END;
    INC(i)
  END;

  s.colCount := i;
  RETURN TRUE
END ParseColList;

PROCEDURE ParseSelect(VAR p: Parser; VAR s: SelectStmt): BOOLEAN;
(* Parses SELECT statement into SelectStmt. *)
VAR ok: BOOLEAN;
BEGIN
  s.selectAll := FALSE; s.colCount := 0;
  s.table := ""; s.tableQuoted := FALSE;
  s.hasWhere := FALSE; s.condCount := 0;

  ok := ExpectKW(p, "SELECT");
  IF ~ok THEN RETURN FALSE END;

  ok := ParseColList(p, s);
  IF ~ok THEN RETURN FALSE END;

  ok := ExpectKW(p, "FROM");
  IF ~ok THEN RETURN FALSE END;

  ok := ParseIdent(p, s.table, s.tableQuoted, "Expected table name");
  IF ~ok THEN RETURN FALSE END;

  ok := ParseWhereConds(p, s.hasWhere, s.condCount, s.conds);
  IF ~ok THEN RETURN FALSE END;

  IF p.tok.kind = SqlScan.Semicolon THEN NextTok(p) END;
  IF p.tok.kind # SqlScan.Eof THEN SetErr(p, "Expected end of statement"); RETURN FALSE END;

  RETURN TRUE
END ParseSelect;

PROCEDURE ParseInsert(VAR p: Parser; VAR ins: InsertStmt): BOOLEAN;
(* Parses INSERT INTO <table> [(col,...)] VALUES (val,...) ; *)
VAR ok: BOOLEAN; i: INTEGER;
BEGIN
  ins.table := ""; ins.tableQuoted := FALSE;
  ins.hasColumns := FALSE; ins.colCount := 0;
  ins.valueCount := 0;

  ok := ExpectKW(p, "INSERT"); IF ~ok THEN RETURN FALSE END;
  ok := ExpectKW(p, "INTO");   IF ~ok THEN RETURN FALSE END;

  ok := ParseIdent(p, ins.table, ins.tableQuoted, "Expected table name after INTO");
  IF ~ok THEN RETURN FALSE END;

  IF p.tok.kind = SqlScan.LParen THEN
    ins.hasColumns := TRUE;
    NextTok(p);

    i := 0;
    ok := ParseNameToken(p, ins.cols[i], ins.colsQuoted[i], "Expected column name in INSERT column list");
    IF ~ok THEN RETURN FALSE END;
    INC(i);

    WHILE p.tok.kind = SqlScan.Comma DO
      NextTok(p);
      IF i >= MaxCols THEN SetErr(p, "Too many INSERT columns"); RETURN FALSE END;
      ok := ParseNameToken(p, ins.cols[i], ins.colsQuoted[i], "Expected column name after comma");
      IF ~ok THEN RETURN FALSE END;
      INC(i)
    END;

    ins.colCount := i;
    ok := ExpectKind(p, SqlScan.RParen, "Expected ')' after INSERT column list");
    IF ~ok THEN RETURN FALSE END
  END;

  ok := ExpectKW(p, "VALUES"); IF ~ok THEN RETURN FALSE END;
  ok := ExpectKind(p, SqlScan.LParen, "Expected '(' after VALUES"); IF ~ok THEN RETURN FALSE END;

  i := 0;
  LOOP
    IF i >= MaxValues THEN SetErr(p, "Too many VALUES"); RETURN FALSE END;
    ok := ParseValue(p, ins.values[i]);
    IF ~ok THEN RETURN FALSE END;
    INC(i);

    IF p.tok.kind = SqlScan.Comma THEN
      NextTok(p)
    ELSE
      EXIT
    END
  END;

  ins.valueCount := i;

  ok := ExpectKind(p, SqlScan.RParen, "Expected ')' after VALUES list");
  IF ~ok THEN RETURN FALSE END;

  IF p.tok.kind = SqlScan.Semicolon THEN NextTok(p) END;
  IF p.tok.kind # SqlScan.Eof THEN SetErr(p, "Expected end of statement"); RETURN FALSE END;

  IF ins.hasColumns THEN
    IF ins.colCount # ins.valueCount THEN SetErr(p, "Column count does not match VALUES count"); RETURN FALSE END
  ELSE
    IF ins.valueCount < 2 THEN SetErr(p, "VALUES must provide at least two items (key, value)"); RETURN FALSE END
  END;

  RETURN TRUE
END ParseInsert;

PROCEDURE ParseUpdate(VAR p: Parser; VAR u: UpdateStmt): BOOLEAN;
(* Parses UPDATE <table> SET <col>=<value> [WHERE ...] ; *)
VAR ok: BOOLEAN;
BEGIN
  u.table := ""; u.tableQuoted := FALSE;
  u.setCol := ""; u.setColQuoted := FALSE;
  u.setVal.kind := vkNone; u.setVal.text := ""; u.setVal.quotedIdent := FALSE;
  u.hasWhere := FALSE; u.condCount := 0;

  ok := ExpectKW(p, "UPDATE"); IF ~ok THEN RETURN FALSE END;
  ok := ParseIdent(p, u.table, u.tableQuoted, "Expected table name after UPDATE");
  IF ~ok THEN RETURN FALSE END;

  ok := ExpectKW(p, "SET"); IF ~ok THEN RETURN FALSE END;

  ok := ParseNameToken(p, u.setCol, u.setColQuoted, "Expected column name after SET");
  IF ~ok THEN RETURN FALSE END;

  ok := ExpectKind(p, SqlScan.Eq, "Expected '=' in SET clause");
  IF ~ok THEN RETURN FALSE END;

  ok := ParseValue(p, u.setVal);
  IF ~ok THEN RETURN FALSE END;

  ok := ParseWhereConds(p, u.hasWhere, u.condCount, u.conds);
  IF ~ok THEN RETURN FALSE END;

  IF p.tok.kind = SqlScan.Semicolon THEN NextTok(p) END;
  IF p.tok.kind # SqlScan.Eof THEN SetErr(p, "Expected end of statement"); RETURN FALSE END;

  RETURN TRUE
END ParseUpdate;

PROCEDURE ParseDelete(VAR p: Parser; VAR d: DeleteStmt): BOOLEAN;
(* Parses DELETE FROM <table> [WHERE ...] ; *)
VAR ok: BOOLEAN;
BEGIN
  d.table := ""; d.tableQuoted := FALSE;
  d.hasWhere := FALSE; d.condCount := 0;

  ok := ExpectKW(p, "DELETE"); IF ~ok THEN RETURN FALSE END;
  ok := ExpectKW(p, "FROM");   IF ~ok THEN RETURN FALSE END;

  ok := ParseIdent(p, d.table, d.tableQuoted, "Expected table name after FROM");
  IF ~ok THEN RETURN FALSE END;

  ok := ParseWhereConds(p, d.hasWhere, d.condCount, d.conds);
  IF ~ok THEN RETURN FALSE END;

  IF p.tok.kind = SqlScan.Semicolon THEN NextTok(p) END;
  IF p.tok.kind # SqlScan.Eof THEN SetErr(p, "Expected end of statement"); RETURN FALSE END;

  RETURN TRUE
END ParseDelete;

PROCEDURE ParseCreateTable(VAR p: Parser; VAR ct: CreateTableStmt): BOOLEAN;
(* Parses CREATE TABLE; not implemented yet in this iteration. *)
BEGIN
  SetErr(p, "CREATE TABLE parsing not implemented yet");
  RETURN FALSE
END ParseCreateTable;

PROCEDURE Parse*(VAR p: Parser; VAR st: Statement): BOOLEAN;
(* Parses one SQL statement and returns a unified Statement record. *)
VAR ok: BOOLEAN;
BEGIN
  st.kind := stNone;

  IF IsKW(p, "SELECT") THEN
    st.kind := stSelect;
    ok := ParseSelect(p, st.select);
    RETURN ok
  ELSIF IsKW(p, "INSERT") THEN
    st.kind := stInsert;
    ok := ParseInsert(p, st.ins);
    RETURN ok
  ELSIF IsKW(p, "UPDATE") THEN
    st.kind := stUpdate;
    ok := ParseUpdate(p, st.upd);
    RETURN ok
  ELSIF IsKW(p, "DELETE") THEN
    st.kind := stDelete;
    ok := ParseDelete(p, st.del);
    RETURN ok
  ELSIF IsKW(p, "CREATE") THEN
    st.kind := stCreateTable;
    ok := ParseCreateTable(p, st.create);
    RETURN ok
  ELSE
    SetErr(p, "Unsupported statement");
    RETURN FALSE
  END
END Parse;

END SqlParse.
