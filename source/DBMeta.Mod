MODULE DBMeta;
IMPORT Pager, SYSTEM;

CONST
  Magic0 = "A"; Magic1 = "2"; Magic2 = "D"; Magic3 = "B";
  Version* = 3;  (* bumped: layout changed *)
  DefaultPageSize* = 4096;

TYPE
  Meta* = RECORD
    magic-: ARRAY 4 OF CHAR;
    version-: SIGNED32;
    pageSize-: SIGNED32;
    keySize-: SIGNED32;

    flags*: SIGNED32;
    reserved*: SIGNED32;

    heapFirstPage*: SIGNED32;
    heapLastPage*: SIGNED32;
    btreeRootPage*: SIGNED32;

    nextFreePage*: SIGNED32;

    crc32-: SIGNED32;
  END;

PROCEDURE WriteI32(VAR a: ARRAY OF CHAR; pos: SIZE; x: SIGNED32);
(* Writes a 32-bit signed integer in little-endian order. *)
BEGIN
  a[pos] := CHR(x MOD 256); x := x DIV 256; INC(pos);
  a[pos] := CHR(x MOD 256); x := x DIV 256; INC(pos);
  a[pos] := CHR(x MOD 256); x := x DIV 256; INC(pos);
  a[pos] := CHR(x MOD 256);
END WriteI32;

PROCEDURE ReadI32(CONST a: ARRAY OF CHAR; pos: SIZE): SIGNED32;
(* Reads a 32-bit signed integer in little-endian order. *)
VAR b0, b1, b2, b3: SIGNED32;
BEGIN
  b0 := ORD(a[pos]); b1 := ORD(a[pos+1]); b2 := ORD(a[pos+2]); b3 := ORD(a[pos+3]);
  RETURN b0 + b1*256 + b2*65536 + b3*16777216
END ReadI32;

PROCEDURE CalcCRC32(CONST a: ARRAY OF CHAR; ofs, n: SIZE): SIGNED32;
(* Computes a lightweight checksum for the header region (not a full CRC32 yet). *)
VAR i: SIZE; c: SIGNED32;
BEGIN
  c := 0;
  i := 0;
  WHILE i < n DO
    c := c * 1664525 + 1013904223 + ORD(a[ofs + i]);
    INC(i)
  END;
  RETURN c
END CalcCRC32;

PROCEDURE Init*(VAR m: Meta; keySize: SIGNED32);
(* Initializes default superblock values for a new database file. *)
BEGIN
  m.magic[0] := Magic0; m.magic[1] := Magic1; m.magic[2] := Magic2; m.magic[3] := Magic3;
  m.version := Version;
  m.pageSize := DefaultPageSize;
  m.keySize := keySize;

  m.flags := 0;
  m.reserved := 0;

  m.heapFirstPage := 1;
  m.heapLastPage := 0;     (* not allocated yet *)
  m.btreeRootPage := 0;    (* not allocated yet *)
  m.nextFreePage := 1;     (* next alloc will start at page 1 *)

  m.crc32 := 0
END Init;

PROCEDURE Store*(VAR db: Pager.DB; VAR m: Meta);
(* Stores meta to page 0 and updates crc32 field before writing. *)
VAR p: Pager.Page; i: SIZE; crc: SIGNED32;
BEGIN
  p.id := 0;
  i := 0; WHILE i < Pager.PageSize DO p.data[i] := 0X; INC(i) END;

  p.data[0] := m.magic[0]; p.data[1] := m.magic[1]; p.data[2] := m.magic[2]; p.data[3] := m.magic[3];
  WriteI32(p.data, 4,  m.version);
  WriteI32(p.data, 8,  m.pageSize);
  WriteI32(p.data, 12, m.keySize);

  WriteI32(p.data, 16, m.flags);
  WriteI32(p.data, 20, m.reserved);

  WriteI32(p.data, 24, m.heapFirstPage);
  WriteI32(p.data, 28, m.heapLastPage);
  WriteI32(p.data, 32, m.btreeRootPage);
  WriteI32(p.data, 36, m.nextFreePage);

  crc := CalcCRC32(p.data, 0, 40);   (* exclude crc field *)
  m.crc32 := crc;
  WriteI32(p.data, 40, m.crc32);

  Pager.WritePage(db, p)
END Store;

PROCEDURE Load*(VAR db: Pager.DB; VAR m: Meta): BOOLEAN;
(* Loads meta from page 0; validates magic/version/pagesize and checksum. *)
VAR p: Pager.Page; crc, stored: SIGNED32;
BEGIN
  IF Pager.PageCount(db) = 0 THEN RETURN FALSE END;

  Pager.ReadPage(db, 0, p);

  IF (p.data[0] # Magic0) OR (p.data[1] # Magic1) OR (p.data[2] # Magic2) OR (p.data[3] # Magic3) THEN
    RETURN FALSE
  END;

  m.magic[0] := p.data[0]; m.magic[1] := p.data[1]; m.magic[2] := p.data[2]; m.magic[3] := p.data[3];
  m.version := ReadI32(p.data, 4);
  m.pageSize := ReadI32(p.data, 8);
  m.keySize := ReadI32(p.data, 12);

  m.flags := ReadI32(p.data, 16);
  m.reserved := ReadI32(p.data, 20);

  m.heapFirstPage := ReadI32(p.data, 24);
  m.heapLastPage := ReadI32(p.data, 28);
  m.btreeRootPage := ReadI32(p.data, 32);
  m.nextFreePage := ReadI32(p.data, 36);

  m.crc32 := ReadI32(p.data, 40);

  IF (m.version # Version) OR (m.pageSize # DefaultPageSize) THEN RETURN FALSE END;

  stored := m.crc32;
  crc := CalcCRC32(p.data, 0, 40);
  RETURN crc = stored
END Load;

END DBMeta.
