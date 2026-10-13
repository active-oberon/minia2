MODULE SqlScan;
IMPORT SYSTEM;

CONST
  MaxLexeme* = 256;

TYPE
  TokenKind* = INTEGER;

CONST
  None*      = 0;
  Eof*       = 1;
  Error*     = 2;

  (* literals/identifiers *)
  Ident*     = 10;
  Keyword*   = 11;
  Int*       = 12;
  Float*     = 13;
  String*    = 14;
  Param*     = 15;

  (* punctuation *)
  LParen*    = 20;
  RParen*    = 21;
  Comma*     = 22;
  Semicolon* = 23;
  Dot*       = 24;
  Star*      = 25;

  (* operators *)
  Plus*      = 30;
  Minus*     = 31;
  Slash*     = 32;
  Percent*   = 33;
  Eq*        = 34;
  Ne*        = 35;
  Lt*        = 36;
  Le*        = 37;
  Gt*        = 38;
  Ge*        = 39;
  Concat*    = 40;

  (* char constants *)
  SingleQuote  = 27X;  (* ' *)
  DoubleQuote  = 22X;  (* " *)
  LeftBracket  = 5BX;  (* [ *)
  RightBracket = 5DX;  (* ] *)

TYPE
  Token* = RECORD
    kind*: TokenKind;
    line*, col*: SIGNED32;
    quotedIdent*: BOOLEAN;          (* TRUE якщо ident був у "..." або [...] *)
    text*: ARRAY MaxLexeme OF CHAR; (* ident/keyword/string/param/number-as-text *)
  END;

  Scanner* = RECORD
    src: POINTER TO ARRAY OF CHAR;
    len: SIGNED32;
    i: SIGNED32;
    line: SIGNED32;
    col: SIGNED32;
    err: ARRAY 80 OF CHAR;
  END;

(* ------------------------------------------------------------ *)
(* Utilities                                                     *)
(* ------------------------------------------------------------ *)

PROCEDURE CopyTrunc(CONST from: ARRAY OF CHAR; VAR to: ARRAY OF CHAR);
VAR i: SIGNED32;
BEGIN
  i := 0;
  WHILE (i < LEN(to)-1) & (from[i] # 0X) DO
    to[i] := from[i]; INC(i)
  END;
  to[i] := 0X
END CopyTrunc;

PROCEDURE SetError(VAR sc: Scanner; CONST msg: ARRAY OF CHAR);
BEGIN
  CopyTrunc(msg, sc.err)
END SetError;

PROCEDURE IsLetter(ch: CHAR): BOOLEAN;
BEGIN
  RETURN ((ch >= "A") & (ch <= "Z")) OR ((ch >= "a") & (ch <= "z"))
END IsLetter;

PROCEDURE IsDigit(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch >= "0") & (ch <= "9")
END IsDigit;

PROCEDURE IsIdentStart(ch: CHAR): BOOLEAN;
BEGIN
  RETURN IsLetter(ch) OR (ch = "_")
END IsIdentStart;

PROCEDURE IsIdentCont(ch: CHAR): BOOLEAN;
BEGIN
  RETURN IsIdentStart(ch) OR IsDigit(ch) OR (ch = "$")
END IsIdentCont;

PROCEDURE Upcase(VAR s: ARRAY OF CHAR);
VAR i: SIGNED32; ch: CHAR;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO
    ch := s[i];
    IF (ch >= "a") & (ch <= "z") THEN s[i] := CHR(ORD(ch) - 32) END;
    INC(i)
  END
END Upcase;

PROCEDURE Peek(VAR sc: Scanner): CHAR;
BEGIN
  IF sc.i >= sc.len THEN RETURN 0X END;
  RETURN sc.src^[sc.i]
END Peek;

PROCEDURE PeekN(VAR sc: Scanner; n: SIGNED32): CHAR;
VAR j: SIGNED32;
BEGIN
  j := sc.i + n;
  IF j >= sc.len THEN RETURN 0X END;
  RETURN sc.src^[j]
END PeekN;

PROCEDURE GetCh(VAR sc: Scanner): CHAR;
VAR ch: CHAR;
BEGIN
  ch := Peek(sc);
  IF ch = 0X THEN RETURN 0X END;

  INC(sc.i);
  IF ch = 0AX THEN
    INC(sc.line); sc.col := 1
  ELSE
    INC(sc.col)
  END;
  RETURN ch
END GetCh;

(* consume one character, ignoring returned value safely *)
PROCEDURE Consume(VAR sc: Scanner);
VAR dummy: CHAR;
BEGIN
  dummy := GetCh(sc)
END Consume;

(* ------------------------------------------------------------ *)
(* Init                                                          *)
(* ------------------------------------------------------------ *)

PROCEDURE Init*(VAR sc: Scanner; CONST s: ARRAY OF CHAR);
VAR n: SIGNED32;
BEGIN
  n := 0;
  WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END;

  (* NEW(pointer, n): n = кількість елементів *)
  NEW(sc.src, n+1);
  SYSTEM.MOVE(SYSTEM.ADR(s), SYSTEM.ADR(sc.src^[0]), n+1);

  sc.len := n;
  sc.i := 0;
  sc.line := 1;
  sc.col := 1;
  sc.err := ""
END Init;

(* ------------------------------------------------------------ *)
(* Skip spaces and comments                                      *)
(* ------------------------------------------------------------ *)

PROCEDURE SkipSpaceAndComments(VAR sc: Scanner);
VAR ch, ch2: CHAR;
BEGIN
  LOOP
    ch := Peek(sc);

    (* whitespace *)
    WHILE (ch = " ") OR (ch = 09X) OR (ch = 0DX) OR (ch = 0AX) DO
      Consume(sc);
      ch := Peek(sc)
    END;

    (* -- comment *)
    IF (ch = "-") & (PeekN(sc, 1) = "-") THEN
      Consume(sc); Consume(sc);
      ch := Peek(sc);
      WHILE (ch # 0X) & (ch # 0AX) DO
        Consume(sc);
        ch := Peek(sc)
      END

    ELSIF (ch = "/") & (PeekN(sc, 1) = "*") THEN
      (* /* comment */ *)
      Consume(sc); Consume(sc);
      LOOP
        ch := Peek(sc);
        IF ch = 0X THEN
          SetError(sc, "Unterminated /* comment */");
          EXIT
        END;
        ch2 := PeekN(sc, 1);
        IF (ch = "*") & (ch2 = "/") THEN
          Consume(sc); Consume(sc);
          EXIT
        ELSE
          Consume(sc)
        END
      END

    ELSE
      EXIT
    END
  END
END SkipSpaceAndComments;

(* ------------------------------------------------------------ *)
(* Keywords                                                      *)
(* ------------------------------------------------------------ *)

PROCEDURE IsKeyword(CONST up: ARRAY OF CHAR): BOOLEAN;
BEGIN
  (* up вже uppercase *)
  IF (up = "SELECT") OR (up = "FROM") OR (up = "WHERE") OR
     (up = "INSERT") OR (up = "INTO") OR (up = "VALUES") OR
     (up = "UPDATE") OR (up = "SET") OR (up = "DELETE") OR
     (up = "CREATE") OR (up = "TABLE") OR (up = "INDEX") OR
     (up = "ON") OR (up = "PRIMARY") OR (up = "KEY") OR
     (up = "UNIQUE") OR (up = "NOT") OR (up = "NULL") OR
     (up = "AND") OR (up = "OR") OR (up = "AS") OR
     (up = "ORDER") OR (up = "BY") OR (up = "LIMIT")
  THEN
    RETURN TRUE
  END;
  RETURN FALSE
END IsKeyword;

(* ------------------------------------------------------------ *)
(* Read identifier / keyword                                     *)
(* ------------------------------------------------------------ *)

PROCEDURE ReadIdent(VAR sc: Scanner; VAR tok: Token);
VAR j: SIGNED32; ch: CHAR; tmp, up: ARRAY MaxLexeme OF CHAR;
BEGIN
  j := 0;
  ch := Peek(sc);

  WHILE IsIdentCont(ch) DO
    ch := GetCh(sc);
    IF j < MaxLexeme-1 THEN tmp[j] := ch; INC(j) END;
    ch := Peek(sc)
  END;
  tmp[j] := 0X;

  tok.quotedIdent := FALSE;

  CopyTrunc(tmp, up);
  Upcase(up);

  IF IsKeyword(up) THEN
    tok.kind := Keyword;
    CopyTrunc(up, tok.text)     (* keyword зберігаємо uppercase *)
  ELSE
    tok.kind := Ident;
    CopyTrunc(tmp, tok.text)    (* ident зберігаємо як є *)
  END
END ReadIdent;

(* ------------------------------------------------------------ *)
(* Read quoted identifier "..."                                  *)
(* ------------------------------------------------------------ *)

PROCEDURE ReadQuotedIdent(VAR sc: Scanner; VAR tok: Token);
VAR j: SIGNED32; ch: CHAR; buf: ARRAY MaxLexeme OF CHAR;
BEGIN
  tok.kind := Ident;
  tok.quotedIdent := TRUE;
  j := 0;

  Consume(sc);  (* opening " *)

  LOOP
    ch := Peek(sc);
    IF ch = 0X THEN
      SetError(sc, "Unterminated quoted identifier");
      tok.kind := Error;
      EXIT
    END;

    IF ch = DoubleQuote THEN
      Consume(sc);
      IF Peek(sc) = DoubleQuote THEN
        Consume(sc);
        IF j < MaxLexeme-1 THEN buf[j] := DoubleQuote; INC(j) END
      ELSE
        EXIT
      END
    ELSE
      ch := GetCh(sc);
      IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END
    END
  END;

  buf[j] := 0X;
  CopyTrunc(buf, tok.text)
END ReadQuotedIdent;

(* ------------------------------------------------------------ *)
(* Read bracket identifier [...]                                 *)
(* ------------------------------------------------------------ *)

PROCEDURE ReadBracketIdent(VAR sc: Scanner; VAR tok: Token);
VAR j: SIGNED32; ch: CHAR; buf: ARRAY MaxLexeme OF CHAR;
BEGIN
  tok.kind := Ident;
  tok.quotedIdent := TRUE;
  j := 0;

  Consume(sc);  (* opening [ *)

  LOOP
    ch := Peek(sc);
    IF ch = 0X THEN
      SetError(sc, "Unterminated bracket identifier");
      tok.kind := Error;
      EXIT
    END;

    IF ch = RightBracket THEN
      Consume(sc);
      IF Peek(sc) = RightBracket THEN
        (* ]] -> ] *)
        Consume(sc);
        IF j < MaxLexeme-1 THEN buf[j] := RightBracket; INC(j) END
      ELSE
        EXIT
      END
    ELSE
      ch := GetCh(sc);
      IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END
    END
  END;

  buf[j] := 0X;
  CopyTrunc(buf, tok.text)
END ReadBracketIdent;

(* ------------------------------------------------------------ *)
(* Read string '...'                                             *)
(* ------------------------------------------------------------ *)

PROCEDURE ReadString(VAR sc: Scanner; VAR tok: Token);
VAR j: SIGNED32; ch: CHAR; buf: ARRAY MaxLexeme OF CHAR;
BEGIN
  tok.kind := String;
  tok.quotedIdent := FALSE;
  j := 0;

  Consume(sc); (* opening ' *)

  LOOP
    ch := Peek(sc);
    IF ch = 0X THEN
      SetError(sc, "Unterminated string");
      tok.kind := Error;
      EXIT
    END;

    IF ch = SingleQuote THEN
      Consume(sc);
      IF Peek(sc) = SingleQuote THEN
        Consume(sc);
        IF j < MaxLexeme-1 THEN buf[j] := SingleQuote; INC(j) END
      ELSE
        EXIT
      END
    ELSE
      ch := GetCh(sc);
      IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END
    END
  END;

  buf[j] := 0X;
  CopyTrunc(buf, tok.text)
END ReadString;

(* ------------------------------------------------------------ *)
(* Read number (as text)                                         *)
(* ------------------------------------------------------------ *)

PROCEDURE ReadNumber(VAR sc: Scanner; VAR tok: Token);
VAR j: SIGNED32; ch: CHAR; buf: ARRAY MaxLexeme OF CHAR; hasDot, hasExp: BOOLEAN;
BEGIN
  j := 0; hasDot := FALSE; hasExp := FALSE;

  ch := Peek(sc);
  WHILE IsDigit(ch) DO
    ch := GetCh(sc);
    IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END;
    ch := Peek(sc)
  END;

  IF (ch = ".") & IsDigit(PeekN(sc, 1)) THEN
    hasDot := TRUE;
    ch := GetCh(sc);
    IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END;

    ch := Peek(sc);
    WHILE IsDigit(ch) DO
      ch := GetCh(sc);
      IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END;
      ch := Peek(sc)
    END
  END;

  ch := Peek(sc);
  IF (ch = "e") OR (ch = "E") THEN
    hasExp := TRUE;
    ch := GetCh(sc);
    IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END;

    ch := Peek(sc);
    IF (ch = "+") OR (ch = "-") THEN
      ch := GetCh(sc);
      IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END
    END;

    ch := Peek(sc);
    WHILE IsDigit(ch) DO
      ch := GetCh(sc);
      IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END;
      ch := Peek(sc)
    END
  END;

  buf[j] := 0X;
  CopyTrunc(buf, tok.text);

  tok.quotedIdent := FALSE;
  IF hasDot OR hasExp THEN tok.kind := Float ELSE tok.kind := Int END
END ReadNumber;

(* ------------------------------------------------------------ *)
(* Read parameter ? :name @name $name                            *)
(* ------------------------------------------------------------ *)

PROCEDURE ReadParam(VAR sc: Scanner; VAR tok: Token);
VAR j: SIGNED32; ch, pfx: CHAR; buf: ARRAY MaxLexeme OF CHAR;
BEGIN
  tok.kind := Param;
  tok.quotedIdent := FALSE;
  j := 0;

  pfx := GetCh(sc);
  buf[j] := pfx; INC(j);

  IF pfx = "?" THEN
    buf[j] := 0X;
    CopyTrunc(buf, tok.text);
    RETURN
  END;

  ch := Peek(sc);
  WHILE IsIdentCont(ch) DO
    ch := GetCh(sc);
    IF j < MaxLexeme-1 THEN buf[j] := ch; INC(j) END;
    ch := Peek(sc)
  END;

  buf[j] := 0X;
  CopyTrunc(buf, tok.text)
END ReadParam;

(* ------------------------------------------------------------ *)
(* Next token                                                    *)
(* ------------------------------------------------------------ *)

PROCEDURE Next*(VAR sc: Scanner; VAR tok: Token);
VAR ch: CHAR;
BEGIN
  SkipSpaceAndComments(sc);

  tok.line := sc.line;
  tok.col := sc.col;
  tok.kind := None;
  tok.quotedIdent := FALSE;
  tok.text := "";

  ch := Peek(sc);
  IF ch = 0X THEN tok.kind := Eof; RETURN END;

  IF ch = DoubleQuote THEN
    ReadQuotedIdent(sc, tok);
    RETURN
  END;

  IF ch = LeftBracket THEN
    ReadBracketIdent(sc, tok);
    RETURN
  END;

  IF IsIdentStart(ch) THEN
    ReadIdent(sc, tok);
    RETURN
  END;

  IF IsDigit(ch) OR ((ch = ".") & IsDigit(PeekN(sc, 1))) THEN
    ReadNumber(sc, tok);
    RETURN
  END;

  IF ch = SingleQuote THEN
    ReadString(sc, tok);
    RETURN
  END;

  IF (ch = "?") OR (ch = ":") OR (ch = "@") OR (ch = "$") THEN
    ReadParam(sc, tok);
    RETURN
  END;

  CASE ch OF
    "(" : Consume(sc); tok.kind := LParen
  | ")" : Consume(sc); tok.kind := RParen
  | "," : Consume(sc); tok.kind := Comma
  | ";" : Consume(sc); tok.kind := Semicolon
  | "." : Consume(sc); tok.kind := Dot
  | "*" : Consume(sc); tok.kind := Star
  | "+" : Consume(sc); tok.kind := Plus
  | "-" : Consume(sc); tok.kind := Minus
  | "/" : Consume(sc); tok.kind := Slash
  | "%" : Consume(sc); tok.kind := Percent
  | "=" : Consume(sc); tok.kind := Eq
  | "<" :
      Consume(sc);
      ch := Peek(sc);
      IF ch = "=" THEN Consume(sc); tok.kind := Le
      ELSIF ch = ">" THEN Consume(sc); tok.kind := Ne
      ELSE tok.kind := Lt
      END
  | ">" :
      Consume(sc);
      ch := Peek(sc);
      IF ch = "=" THEN Consume(sc); tok.kind := Ge
      ELSE tok.kind := Gt
      END
  | "!" :
      Consume(sc);
      ch := Peek(sc);
      IF ch = "=" THEN Consume(sc); tok.kind := Ne
      ELSE tok.kind := Error; SetError(sc, "Unexpected '!'");
      END
  | "|" :
      Consume(sc);
      ch := Peek(sc);
      IF ch = "|" THEN Consume(sc); tok.kind := Concat
      ELSE tok.kind := Error; SetError(sc, "Unexpected '|'");
      END
  ELSE
      Consume(sc);
      tok.kind := Error;
      SetError(sc, "Unexpected character")
  END
END Next;

PROCEDURE ErrorMsg*(VAR sc: Scanner; VAR msg: ARRAY OF CHAR);
BEGIN
  CopyTrunc(sc.err, msg)
END ErrorMsg;

END SqlScan.
``