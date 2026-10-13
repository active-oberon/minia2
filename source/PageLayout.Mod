
MODULE PageLayout;
IMPORT SYSTEM;

CONST
  PageSize* = 4096;

(* ================= Header & Slot ================= *)

TYPE
  PageHeader* = RECORD
    slotCount*: SIZE;
    freeStart*: SIZE;
    freeEnd*:   SIZE;
  END;

  Slot* = RECORD
    offset*: SIZE;   (* 0 = deleted *)
    length*: SIZE;
  END;

CONST
  HeaderSize = SIZEOF(PageHeader);
  SlotSize   = SIZEOF(Slot);

(* ================= Initialization ================= *)

PROCEDURE Init*(VAR page: ARRAY OF CHAR);
VAR
  h: PageHeader;
BEGIN
  h.slotCount := 0;
  h.freeStart := HeaderSize;
  h.freeEnd   := PageSize;
  SYSTEM.MOVE(SYSTEM.ADR(h), SYSTEM.ADR(page), HeaderSize)
END Init;

(* ================= Header access ================= *)

PROCEDURE ReadHeader*(CONST page: ARRAY OF CHAR; VAR h: PageHeader);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(page), SYSTEM.ADR(h), HeaderSize)
END ReadHeader;

PROCEDURE WriteHeader*(VAR page: ARRAY OF CHAR; CONST h: PageHeader);
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(h), SYSTEM.ADR(page), HeaderSize)
END WriteHeader;

(* ================= Slot access ================= *)

PROCEDURE ReadSlot*(CONST page: ARRAY OF CHAR;
                    slotId: SIZE;
                    VAR s: Slot): BOOLEAN;
VAR
  pos: SIZE;
  h: PageHeader;
BEGIN
  ReadHeader(page, h);
  IF (slotId < 0) OR (slotId >= h.slotCount) THEN RETURN FALSE END;

  pos := HeaderSize + slotId * SlotSize;
  SYSTEM.MOVE(SYSTEM.ADR(page[pos]), SYSTEM.ADR(s), SlotSize);
  RETURN TRUE
END ReadSlot;

PROCEDURE WriteSlot*(VAR page: ARRAY OF CHAR;
                     slotId: SIZE;
                     CONST s: Slot): BOOLEAN;
VAR
  pos: SIZE;
  h: PageHeader;
BEGIN
  ReadHeader(page, h);
  IF (slotId < 0) OR (slotId >= h.slotCount) THEN RETURN FALSE END;

  pos := HeaderSize + slotId * SlotSize;
  SYSTEM.MOVE(SYSTEM.ADR(s), SYSTEM.ADR(page[pos]), SlotSize);
  RETURN TRUE
END WriteSlot;

PROCEDURE InsertReuse*(VAR page: ARRAY OF CHAR;
                       CONST rec: ARRAY OF CHAR;
                       len: SIZE;
                       VAR slotId: SIZE): BOOLEAN;
VAR
  h: PageHeader;
  s: Slot;
  i: SIZE;
  need: SIZE;
BEGIN
  IF len <= 0 THEN RETURN FALSE END;

  ReadHeader(page, h);

  (* 1) Спроба reuse: шукаємо tombstone slot *)
  i := 0;
  WHILE i < h.slotCount DO
    IF ~ReadSlot(page, i, s) THEN RETURN FALSE END;
    IF s.offset = 0 THEN
      (* знайдено вільний слот: потрібне місце тільки під record *)
      need := len;
      IF h.freeStart + need > h.freeEnd THEN
        RETURN FALSE
      END;

      DEC(h.freeEnd, len);
      SYSTEM.MOVE(SYSTEM.ADR(rec), SYSTEM.ADR(page[h.freeEnd]), len);

      s.offset := h.freeEnd;
      s.length := len;

      IF ~WriteSlot(page, i, s) THEN RETURN FALSE END;
      WriteHeader(page, h);

      slotId := i;
      RETURN TRUE
    END;
    INC(i)
  END;

  (* 2) Якщо вільних слотів немає — звичайний Insert (додаємо слот) *)
  RETURN Insert(page, rec, len, slotId)
END InsertReuse;

PROCEDURE Compact*(VAR page: ARRAY OF CHAR): BOOLEAN;
VAR
  h: PageHeader;
  s: Slot;
  i: SIZE;
  newFreeEnd: SIZE;
  slotPos: SIZE;
  tmp: ARRAY PageSize OF CHAR;
BEGIN
  ReadHeader(page, h);

  (* базові перевірки *)
  IF (h.freeStart < HeaderSize) OR (h.freeEnd > PageSize) OR (h.freeStart > h.freeEnd) THEN
    RETURN FALSE
  END;

  (* зануляємо tmp *)
  i := 0;
  WHILE i < PageSize DO
    tmp[i] := 0X;
    INC(i)
  END;

  (* переписуємо header (freeEnd оновимо пізніше) *)
  newFreeEnd := PageSize;

  (* копіюємо header як є (потім поправимо поля) *)
  SYSTEM.MOVE(SYSTEM.ADR(h), SYSTEM.ADR(tmp[0]), HeaderSize);

  (* копіюємо slot directory як є, але потім оновимо offset живих *)
  SYSTEM.MOVE(SYSTEM.ADR(page[HeaderSize]), SYSTEM.ADR(tmp[HeaderSize]), h.slotCount * SlotSize);

  (* для кожного слота: якщо живий — переносимо запис у tmp з кінця *)
  i := 0;
  WHILE i < h.slotCount DO
    slotPos := HeaderSize + i * SlotSize;
    SYSTEM.MOVE(SYSTEM.ADR(page[slotPos]), SYSTEM.ADR(s), SlotSize);

    IF s.offset # 0 THEN
      (* місце під запис *)
      DEC(newFreeEnd, s.length);
      IF newFreeEnd < h.freeStart THEN RETURN FALSE END;

      (* копіюємо bytes запису *)
      SYSTEM.MOVE(SYSTEM.ADR(page[s.offset]), SYSTEM.ADR(tmp[newFreeEnd]), s.length);

      (* оновлюємо slot.offset *)
      s.offset := newFreeEnd;
      SYSTEM.MOVE(SYSTEM.ADR(s), SYSTEM.ADR(tmp[slotPos]), SlotSize);
    END;

    INC(i)
  END;

  (* оновлюємо header: freeEnd, freeStart *)
  h.freeStart := HeaderSize + h.slotCount * SlotSize;
  h.freeEnd := newFreeEnd;
  SYSTEM.MOVE(SYSTEM.ADR(h), SYSTEM.ADR(tmp[0]), HeaderSize);

  (* переписуємо tmp назад у page *)
  SYSTEM.MOVE(SYSTEM.ADR(tmp[0]), SYSTEM.ADR(page[0]), PageSize);
  RETURN TRUE
END Compact;
(* ================= Record operations ================= *)

PROCEDURE Insert*(VAR page: ARRAY OF CHAR;
                  CONST rec: ARRAY OF CHAR;
                  len: SIZE;
                  VAR slotId: SIZE): BOOLEAN;
VAR
  h: PageHeader;
  s: Slot;
  need: SIZE;
BEGIN
  ReadHeader(page, h);

  need := SlotSize + len;
  IF h.freeStart + need > h.freeEnd THEN
    RETURN FALSE
  END;

  (* record *)
  DEC(h.freeEnd, len);
  SYSTEM.MOVE(SYSTEM.ADR(rec), SYSTEM.ADR(page[h.freeEnd]), len);

  (* slot *)
  s.offset := h.freeEnd;
  s.length := len;
  SYSTEM.MOVE(SYSTEM.ADR(s), SYSTEM.ADR(page[h.freeStart]), SlotSize);

  slotId := h.slotCount;
  INC(h.slotCount);
  INC(h.freeStart, SlotSize);

  WriteHeader(page, h);
  RETURN TRUE
END Insert;

PROCEDURE Get*(CONST page: ARRAY OF CHAR;
               slotId: SIZE;
               VAR buf: ARRAY OF CHAR;
               VAR len: SIZE): BOOLEAN;
VAR
  s: Slot;
BEGIN
  IF ~ReadSlot(page, slotId, s) THEN RETURN FALSE END;
  IF s.offset = 0 THEN RETURN FALSE END;

  len := s.length;
  SYSTEM.MOVE(SYSTEM.ADR(page[s.offset]), SYSTEM.ADR(buf), len);
  RETURN TRUE
END Get;

PROCEDURE Delete*(VAR page: ARRAY OF CHAR; slotId: SIZE): BOOLEAN;
VAR
  s: Slot;
BEGIN
  IF ~ReadSlot(page, slotId, s) THEN RETURN FALSE END;
  IF s.offset = 0 THEN RETURN FALSE END;

  s.offset := 0;
  RETURN WriteSlot(page, slotId, s)
END Delete;

END PageLayout.
