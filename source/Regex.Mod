MODULE Regex;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "Regular expressions for Active Oberon, matched without backtracking";
	LIMITATIONS
		"- bytes, not characters: a pattern matches UTF-8 literally, but `.` counts one byte
		   and a range like [a-z] cannot span a multi-byte character;
		 - no counted repetition {m,n}, no back references (a back reference is what makes
		   matching exponential, and this engine trades it away on purpose);
		 - ^ and $ anchor the whole text, not a line;
		 - at most MaxGroups capturing groups;
		 - a compiled Regexp carries the result of its last search, so it is a searcher and not
		   a shared constant: give each activity its own."
*)
(*	The engine is Thompson's: the pattern becomes a program, and the program is run over the
	input with every thread advancing one character at a time. Cost is O(pattern * input) and
	nothing a caller writes can make it worse -- which is the property a standard library needs
	and a backtracking matcher cannot promise. Threads are ordered by preference, so the first
	one to reach Match wins: that is leftmost-first, the semantics Perl and Go both print. *)

IMPORT Strings;

CONST
	MaxGroups* = 9;		(** capturing groups, not counting group 0 -- the whole match *)

	(* instructions *)
	opChar = 0; opAny = 1; opClass = 2; opSplit = 3; opJmp = 4; opSave = 5;
	opBol = 6; opEol = 7; opMatch = 8;

	(* syntax tree *)
	nEmpty = 0; nChar = 1; nAny = 2; nClass = 3; nCat = 4; nAlt = 5;
	nStar = 6; nPlus = 7; nQuest = 8; nGroup = 9; nBol = 10; nEol = 11;

TYPE
	CharSet = ARRAY 256 OF BOOLEAN;
	CharSets = POINTER TO ARRAY OF CharSet;

	Instr = RECORD
		op: SIGNED32;
		ch: CHAR;
		set: SIGNED32;		(* index into classes, for opClass *)
		x, y: SIGNED32		(* branch targets for opSplit/opJmp, slot for opSave *)
	END;
	Program = POINTER TO ARRAY OF Instr;

	Node = POINTER TO RECORD
		kind: SIGNED32;
		ch: CHAR;
		set: SIGNED32;
		group: SIGNED32;
		greedy: BOOLEAN;
		left, right: Node
	END;

	(* One list of the running program's threads. mark/gen keep a pc out of the list twice:
		two threads at the same pc with different captures differ only in a capture nobody
		asked for, and dropping the later one is what keeps the run linear. *)
	List = RECORD
		n: SIGNED32;
		gen: SIGNED32;
		pc: POINTER TO ARRAY OF SIGNED32;
		mark: POINTER TO ARRAY OF SIGNED32;
		cap: POINTER TO ARRAY OF SIZE		(* n rows of nslots *)
	END;

TYPE
	Regexp* = OBJECT
	VAR
		prog: Program;
		nprog: SIGNED32;
		classes: CharSets;
		nclasses: SIGNED32;
		ngroups-: SIGNED32;		(** capturing groups the pattern declares, not counting group 0 *)
		nslots: SIGNED32;
		caps: ARRAY 2 * (MaxGroups + 1) OF SIZE;
		found: BOOLEAN;
		clist, nlist: List;

		PROCEDURE & InitRegexp;
		BEGIN
			nprog := 0; nclasses := 0; ngroups := 0; found := FALSE
		END InitRegexp;

		PROCEDURE Lists;
		BEGIN
			nslots := 2 * (ngroups + 1);
			NEW(clist.pc, nprog); NEW(clist.mark, nprog); NEW(clist.cap, nprog * nslots);
			NEW(nlist.pc, nprog); NEW(nlist.mark, nprog); NEW(nlist.cap, nprog * nslots);
			Clear(clist); Clear(nlist)
		END Lists;

		PROCEDURE Clear(VAR l: List);
		VAR i: SIGNED32;
		BEGIN
			l.n := 0; INC(l.gen);
			IF l.gen = 1 THEN FOR i := 0 TO nprog - 1 DO l.mark[i] := 0 END END
		END Clear;

		(* Add pc and everything reachable from it without consuming a character. The capture
			slots travel with the thread, which is the only reason this engine can report groups
			at all; they are restored around the recursion so that a Split does not leak one
			branch's Save into the other. *)
		PROCEDURE Add(VAR l: List; pc: SIGNED32; VAR cap: ARRAY OF SIZE; pos, len: SIZE);
		VAR i: SIGNED32; old: SIZE;
		BEGIN
			IF l.mark[pc] = l.gen THEN RETURN END;
			l.mark[pc] := l.gen;
			CASE prog[pc].op OF
			  opJmp: Add(l, prog[pc].x, cap, pos, len)
			| opSplit:
				Add(l, prog[pc].x, cap, pos, len);
				Add(l, prog[pc].y, cap, pos, len)
			| opSave:
				old := cap[prog[pc].x];
				cap[prog[pc].x] := pos;
				Add(l, pc + 1, cap, pos, len);
				cap[prog[pc].x] := old
			| opBol: IF pos = 0 THEN Add(l, pc + 1, cap, pos, len) END
			| opEol: IF pos = len THEN Add(l, pc + 1, cap, pos, len) END
			ELSE
				l.pc[l.n] := pc;
				FOR i := 0 TO nslots - 1 DO l.cap[l.n * nslots + i] := cap[i] END;
				INC(l.n)
			END
		END Add;

		PROCEDURE Run(CONST s: ARRAY OF CHAR; start, len: SIZE): BOOLEAN;
		VAR cap: ARRAY 2 * (MaxGroups + 1) OF SIZE;
			i, k, pc: SIGNED32; pos: SIZE; c: CHAR; matched, step, cut: BOOLEAN; t: List;
		BEGIN
			matched := FALSE; pos := start;
			Clear(clist); Clear(nlist);
			LOOP
				IF ~matched THEN
					FOR i := 0 TO nslots - 1 DO cap[i] := -1 END;
					Add(clist, 0, cap, pos, len)
				END;
				IF clist.n = 0 THEN EXIT END;
				Clear(nlist);
				i := 0; cut := FALSE;
				WHILE (i < clist.n) & ~cut DO
					pc := clist.pc[i];
					IF pos < len THEN c := s[pos] ELSE c := 0X END;
					step := FALSE;
					CASE prog[pc].op OF
					  opChar: step := (pos < len) & (c = prog[pc].ch)
					| opAny: step := (pos < len) & (c # 0AX)
					| opClass: step := (pos < len) & classes[prog[pc].set][ORD(c)]
					| opMatch:
						FOR k := 0 TO nslots - 1 DO caps[k] := clist.cap[i * nslots + k] END;
						matched := TRUE;
						(* everything after this thread is a worse match: leftmost-first *)
						cut := TRUE
					ELSE (* the epsilon instructions never reach a list *)
					END;
					IF step THEN
						(* the thread's own slots, lifted out of the flat row store *)
						FOR k := 0 TO nslots - 1 DO cap[k] := clist.cap[i * nslots + k] END;
						Add(nlist, pc + 1, cap, pos + 1, len)
					END;
					INC(i)
				END;
				t := clist; clist := nlist; nlist := t;
				IF pos >= len THEN EXIT END;
				INC(pos)
			END;
			found := matched;
			RETURN matched
		END Run;

		(** Does the pattern match anywhere in s? Groups are readable afterwards with Group. *)
		PROCEDURE Match*(CONST s: ARRAY OF CHAR): BOOLEAN;
		VAR pos, len: SIZE;
		BEGIN
			RETURN SELF.Find(s, 0, pos, len)
		END Match;

		(** The leftmost match at or after from: pos and len say where it is. *)
		PROCEDURE Find*(CONST s: ARRAY OF CHAR; from: SIZE; VAR pos, len: SIZE): BOOLEAN;
		VAR n: SIZE;
		BEGIN
			n := Strings.Length(s);
			IF (from < 0) OR (from > n) THEN found := FALSE; RETURN FALSE END;
			IF ~SELF.Run(s, from, n) THEN RETURN FALSE END;
			pos := caps[0]; len := caps[1] - caps[0];
			RETURN TRUE
		END Find;

		(** Where group i landed in the last successful search. Group 0 is the whole match;
			a group that did not take part returns FALSE. *)
		PROCEDURE Group*(i: SIGNED32; VAR pos, len: SIZE): BOOLEAN;
		BEGIN
			IF ~found OR (i < 0) OR (i > ngroups) THEN RETURN FALSE END;
			IF caps[2 * i] < 0 THEN RETURN FALSE END;
			pos := caps[2 * i]; len := caps[2 * i + 1] - caps[2 * i];
			RETURN TRUE
		END Group;

		(** Group i of the last search, copied out. FALSE if it did not take part. *)
		PROCEDURE GroupString*(i: SIGNED32; CONST s: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
		VAR pos, len, k: SIZE;
		BEGIN
			IF ~SELF.Group(i, pos, len) THEN RETURN FALSE END;
			IF len >= LEN(value) THEN RETURN FALSE END;
			FOR k := 0 TO len - 1 DO value[k] := s[pos + k] END;
			value[len] := 0X;
			RETURN TRUE
		END GroupString;

	END Regexp;

TYPE
	Parser = OBJECT
	VAR
		pat: Strings.String;
		pos, len: SIZE;
		groups: SIGNED32;
		r: Regexp;
		failed: BOOLEAN;
		message: ARRAY 128 OF CHAR;

		PROCEDURE & InitParser(CONST pattern: ARRAY OF CHAR; re: Regexp);
		BEGIN
			len := Strings.Length(pattern);
			NEW(pat, len + 1); COPY(pattern, pat^);
			pos := 0; groups := 0; r := re; failed := FALSE; message := ""
		END InitParser;

		PROCEDURE Fail(CONST msg: ARRAY OF CHAR);
		VAR num: ARRAY 16 OF CHAR;
		BEGIN
			IF failed THEN RETURN END;
			failed := TRUE;
			COPY(msg, message);
			Strings.Append(message, " at offset ");
			Strings.IntToStr(pos, num); Strings.Append(message, num)
		END Fail;

		PROCEDURE Ch(): CHAR;
		BEGIN
			IF pos < len THEN RETURN pat[pos] ELSE RETURN 0X END
		END Ch;

		PROCEDURE NewNode(kind: SIGNED32): Node;
		VAR n: Node;
		BEGIN
			NEW(n); n.kind := kind; n.ch := 0X; n.set := -1; n.group := 0;
			n.greedy := TRUE; n.left := NIL; n.right := NIL;
			RETURN n
		END NewNode;

		PROCEDURE NewClass(): SIGNED32;
		VAR grown: CharSets; i, j: SIGNED32;
		BEGIN
			IF r.classes = NIL THEN NEW(r.classes, 8)
			ELSIF r.nclasses = LEN(r.classes) THEN
				NEW(grown, 2 * r.nclasses);
				FOR i := 0 TO r.nclasses - 1 DO
					FOR j := 0 TO 255 DO grown[i][j] := r.classes[i][j] END
				END;
				r.classes := grown
			END;
			FOR j := 0 TO 255 DO r.classes[r.nclasses][j] := FALSE END;
			INC(r.nclasses);
			RETURN r.nclasses - 1
		END NewClass;

		(* \d \w \s and their negations, as a set poured into an existing class *)
		PROCEDURE Shorthand(c: CHAR; set: SIGNED32): BOOLEAN;
		VAR i: SIGNED32; want: BOOLEAN;
			PROCEDURE Put(from, to: CHAR);
			VAR k: SIGNED32;
			BEGIN
				FOR k := ORD(from) TO ORD(to) DO r.classes[set][k] := want END
			END Put;
		BEGIN
			want := (c >= "a");			(* lower case adds, upper case takes away *)
			IF ~want THEN FOR i := 0 TO 255 DO r.classes[set][i] := TRUE END END;
			CASE c OF
			  "d", "D": Put("0", "9")
			| "w", "W": Put("0", "9"); Put("A", "Z"); Put("a", "z"); r.classes[set][ORD("_")] := want
			| "s", "S":
				r.classes[set][ORD(" ")] := want; r.classes[set][9] := want;
				r.classes[set][10] := want; r.classes[set][11] := want;
				r.classes[set][12] := want; r.classes[set][13] := want
			ELSE RETURN FALSE
			END;
			RETURN TRUE
		END Shorthand;

		(* The character an escape stands for. \d and friends are not characters and are
			handled by the caller; everything else is itself, which is what lets a pattern
			write \. \* \( without a table of what is special where. *)
		PROCEDURE Escaped(): CHAR;
		VAR c: CHAR;
		BEGIN
			c := SELF.Ch(); INC(pos);
			CASE c OF
			  "n": RETURN 0AX
			| "r": RETURN 0DX
			| "t": RETURN 9X
			| "f": RETURN 0CX
			| "v": RETURN 0BX
			| 0X: Fail("pattern ends in a backslash"); RETURN 0X
			ELSE RETURN c
			END
		END Escaped;

		PROCEDURE ParseClass(): Node;
		VAR n: Node; set: SIGNED32; negate, first: BOOLEAN; c, hi: CHAR; i: SIGNED32;
		BEGIN
			INC(pos);				(* [ *)
			set := SELF.NewClass();
			negate := SELF.Ch() = "^";
			IF negate THEN INC(pos) END;
			first := TRUE;
			WHILE (pos < len) & ((SELF.Ch() # "]") OR first) DO
				first := FALSE;
				c := SELF.Ch();
				IF c = "\" THEN
					INC(pos);
					IF SELF.Shorthand(SELF.Ch(), set) THEN INC(pos); c := 0X
					ELSE c := SELF.Escaped(); r.classes[set][ORD(c)] := TRUE;
						IF (SELF.Ch() = "-") & (pos + 1 < len) & (pat[pos + 1] # "]") THEN
							INC(pos); hi := SELF.Ch();
							IF hi = "\" THEN INC(pos); hi := SELF.Escaped() ELSE INC(pos) END;
							FOR i := ORD(c) TO ORD(hi) DO r.classes[set][i] := TRUE END
						END
					END
				ELSE
					INC(pos);
					IF (SELF.Ch() = "-") & (pos + 1 < len) & (pat[pos + 1] # "]") THEN
						INC(pos); hi := SELF.Ch();
						IF hi = "\" THEN INC(pos); hi := SELF.Escaped() ELSE INC(pos) END;
						IF ORD(hi) < ORD(c) THEN Fail("range runs backwards"); RETURN NIL END;
						FOR i := ORD(c) TO ORD(hi) DO r.classes[set][i] := TRUE END
					ELSE
						r.classes[set][ORD(c)] := TRUE
					END
				END;
				IF failed THEN RETURN NIL END
			END;
			IF SELF.Ch() # "]" THEN Fail("unterminated character class"); RETURN NIL END;
			INC(pos);
			IF negate THEN
				FOR i := 0 TO 255 DO r.classes[set][i] := ~r.classes[set][i] END
			END;
			n := SELF.NewNode(nClass); n.set := set;
			RETURN n
		END ParseClass;

		PROCEDURE ParseAtom(): Node;
		VAR n, inner: Node; c: CHAR; set: SIGNED32; capturing: BOOLEAN; g: SIGNED32;
		BEGIN
			c := SELF.Ch();
			CASE c OF
			  "(":
				INC(pos);
				capturing := TRUE;
				IF (SELF.Ch() = "?") & (pos + 1 < len) & (pat[pos + 1] = ":") THEN
					INC(pos, 2); capturing := FALSE
				END;
				g := 0;
				IF capturing THEN
					INC(groups);
					IF groups > MaxGroups THEN Fail("too many capturing groups"); RETURN NIL END;
					g := groups
				END;
				inner := SELF.ParseAlt();
				IF failed THEN RETURN NIL END;
				IF SELF.Ch() # ")" THEN Fail("missing )"); RETURN NIL END;
				INC(pos);
				IF ~capturing THEN RETURN inner END;
				n := SELF.NewNode(nGroup); n.group := g; n.left := inner;
				RETURN n
			| "[": RETURN SELF.ParseClass()
			| ".": INC(pos); RETURN SELF.NewNode(nAny)
			| "^": INC(pos); RETURN SELF.NewNode(nBol)
			| "$": INC(pos); RETURN SELF.NewNode(nEol)
			| "\":
				INC(pos);
				set := SELF.NewClass();
				IF SELF.Shorthand(SELF.Ch(), set) THEN
					INC(pos);
					n := SELF.NewNode(nClass); n.set := set;
					RETURN n
				END;
				DEC(r.nclasses);		(* the class was not needed after all *)
				c := SELF.Escaped();
				IF failed THEN RETURN NIL END;
				n := SELF.NewNode(nChar); n.ch := c;
				RETURN n
			| ")": Fail("unbalanced )"); RETURN NIL
			| "*", "+", "?": Fail("nothing to repeat"); RETURN NIL
			ELSE
				INC(pos);
				n := SELF.NewNode(nChar); n.ch := c;
				RETURN n
			END
		END ParseAtom;

		PROCEDURE ParseRepeat(): Node;
		VAR n, rep: Node; c: CHAR;
		BEGIN
			n := SELF.ParseAtom();
			IF failed THEN RETURN NIL END;
			LOOP
				c := SELF.Ch();
				IF (c # "*") & (c # "+") & (c # "?") THEN EXIT END;
				INC(pos);
				CASE c OF
				  "*": rep := SELF.NewNode(nStar)
				| "+": rep := SELF.NewNode(nPlus)
				ELSE rep := SELF.NewNode(nQuest)
				END;
				rep.left := n;
				IF SELF.Ch() = "?" THEN INC(pos); rep.greedy := FALSE END;
				n := rep
			END;
			RETURN n
		END ParseRepeat;

		PROCEDURE ParseCat(): Node;
		VAR n, right, cat: Node; c: CHAR;
		BEGIN
			n := NIL;
			LOOP
				c := SELF.Ch();
				IF (pos >= len) OR (c = "|") OR (c = ")") THEN EXIT END;
				right := SELF.ParseRepeat();
				IF failed THEN RETURN NIL END;
				IF n = NIL THEN n := right
				ELSE cat := SELF.NewNode(nCat); cat.left := n; cat.right := right; n := cat
				END
			END;
			IF n = NIL THEN n := SELF.NewNode(nEmpty) END;
			RETURN n
		END ParseCat;

		PROCEDURE ParseAlt(): Node;
		VAR n, right, alt: Node;
		BEGIN
			n := SELF.ParseCat();
			IF failed THEN RETURN NIL END;
			WHILE SELF.Ch() = "|" DO
				INC(pos);
				right := SELF.ParseCat();
				IF failed THEN RETURN NIL END;
				alt := SELF.NewNode(nAlt); alt.left := n; alt.right := right; n := alt
			END;
			RETURN n
		END ParseAlt;

		PROCEDURE Parse(): Node;
		VAR n: Node;
		BEGIN
			n := SELF.ParseAlt();
			IF failed THEN RETURN NIL END;
			IF pos # len THEN Fail("unbalanced )"); RETURN NIL END;
			RETURN n
		END Parse;

	END Parser;

TYPE
	Emitter = OBJECT
	VAR
		r: Regexp;

		PROCEDURE & InitEmitter(re: Regexp);
		BEGIN
			r := re; NEW(r.prog, 32); r.nprog := 0
		END InitEmitter;

		PROCEDURE Put(op: SIGNED32; ch: CHAR; set, x, y: SIGNED32): SIGNED32;
		VAR grown: Program; i: SIGNED32;
		BEGIN
			IF r.nprog = LEN(r.prog) THEN
				NEW(grown, 2 * r.nprog);
				FOR i := 0 TO r.nprog - 1 DO grown[i] := r.prog[i] END;
				r.prog := grown
			END;
			r.prog[r.nprog].op := op; r.prog[r.nprog].ch := ch;
			r.prog[r.nprog].set := set; r.prog[r.nprog].x := x; r.prog[r.nprog].y := y;
			INC(r.nprog);
			RETURN r.nprog - 1
		END Put;

		PROCEDURE Emit(n: Node);
		VAR split, jmp, top, body: SIGNED32; i: SIGNED32;
		BEGIN
			CASE n.kind OF
			  nEmpty:
			| nChar: i := SELF.Put(opChar, n.ch, -1, 0, 0)
			| nAny: i := SELF.Put(opAny, 0X, -1, 0, 0)
			| nClass: i := SELF.Put(opClass, 0X, n.set, 0, 0)
			| nBol: i := SELF.Put(opBol, 0X, -1, 0, 0)
			| nEol: i := SELF.Put(opEol, 0X, -1, 0, 0)
			| nCat: SELF.Emit(n.left); SELF.Emit(n.right)
			| nGroup:
				i := SELF.Put(opSave, 0X, -1, 2 * n.group, 0);
				SELF.Emit(n.left);
				i := SELF.Put(opSave, 0X, -1, 2 * n.group + 1, 0)
			| nAlt:
				split := SELF.Put(opSplit, 0X, -1, 0, 0);
				r.prog[split].x := r.nprog;
				SELF.Emit(n.left);
				jmp := SELF.Put(opJmp, 0X, -1, 0, 0);
				r.prog[split].y := r.nprog;
				SELF.Emit(n.right);
				r.prog[jmp].x := r.nprog
			| nQuest:
				split := SELF.Put(opSplit, 0X, -1, 0, 0);
				body := r.nprog;
				SELF.Emit(n.left);
				IF n.greedy THEN r.prog[split].x := body; r.prog[split].y := r.nprog
				ELSE r.prog[split].x := r.nprog; r.prog[split].y := body
				END
			| nStar:
				top := SELF.Put(opSplit, 0X, -1, 0, 0);
				body := r.nprog;
				SELF.Emit(n.left);
				jmp := SELF.Put(opJmp, 0X, -1, top, 0);
				IF n.greedy THEN r.prog[top].x := body; r.prog[top].y := r.nprog
				ELSE r.prog[top].x := r.nprog; r.prog[top].y := body
				END
			| nPlus:
				body := r.nprog;
				SELF.Emit(n.left);
				split := SELF.Put(opSplit, 0X, -1, 0, 0);
				IF n.greedy THEN r.prog[split].x := body; r.prog[split].y := r.nprog
				ELSE r.prog[split].x := r.nprog; r.prog[split].y := body
				END
			END
		END Emit;

	END Emitter;

(** Compile pattern. Returns NIL and a reason in error if the pattern is not one. *)
PROCEDURE Compile*(CONST pattern: ARRAY OF CHAR; VAR error: ARRAY OF CHAR): Regexp;
VAR r: Regexp; p: Parser; e: Emitter; tree: Node; i: SIGNED32;
BEGIN
	NEW(r);
	NEW(p, pattern, r);
	tree := p.Parse();
	IF p.failed THEN COPY(p.message, error); RETURN NIL END;
	r.ngroups := p.groups;
	NEW(e, r);
	i := e.Put(opSave, 0X, -1, 0, 0);		(* group 0 opens *)
	e.Emit(tree);
	i := e.Put(opSave, 0X, -1, 1, 0);		(* and closes *)
	i := e.Put(opMatch, 0X, -1, 0, 0);
	r.Lists;
	error := "";
	RETURN r
END Compile;

(** Does pattern match anywhere in s? A pattern that does not compile does not match. *)
PROCEDURE Matches*(CONST pattern, s: ARRAY OF CHAR): BOOLEAN;
VAR r: Regexp; error: ARRAY 128 OF CHAR;
BEGIN
	r := Compile(pattern, error);
	IF r = NIL THEN RETURN FALSE END;
	RETURN r.Match(s)
END Matches;

END Regex.
