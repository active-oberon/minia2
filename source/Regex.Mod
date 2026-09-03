MODULE Regex;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "Regular expressions for Active Oberon, matched without backtracking";
	LIMITATIONS
		"- UTF-8 in, byte offsets out: Find and Group report where a match is in bytes, because
		   that is what a caller indexes with; a byte that is not well-formed UTF-8 is matched
		   as the character of that byte's value, so a broken string cannot stall the search;
		 - simple case only: there is no case-insensitive flag yet;
		 - no back references (a back reference is what makes matching exponential, and this
		   engine trades it away on purpose);
		 - {m,n} is written out into the program, so a count is capped at MaxRepeat;
		 - ^ and $ anchor the whole text, not a line;
		 - at most MaxGroups capturing groups;
		 - a compiled Regexp carries the result of its last search, so it is a searcher and not
		   a shared constant: give each activity its own;
		 - Split ignores an empty match, because splitting on one produces one piece per
		   character and nobody means that."
*)
(*	The engine is Thompson's: the pattern becomes a program, and the program is run over the
	input with every thread advancing one character at a time. Cost is O(pattern * input) and
	nothing a caller writes can make it worse -- which is the property a standard library needs
	and a backtracking matcher cannot promise. Threads are ordered by preference, so the first
	one to reach Match wins: that is leftmost-first, the semantics Perl and Go both print. *)

IMPORT Strings, Unicode, UTF8Strings;

CONST
	MaxGroups* = 9;		(** capturing groups, not counting group 0 -- the whole match *)
	MaxRepeat* = 1000;	(** the largest count {m,n} may name: the program is written out, not counted *)

	(* instructions *)
	opChar = 0; opAny = 1; opClass = 2; opSplit = 3; opJmp = 4; opSave = 5;
	opBol = 6; opEol = 7; opMatch = 8;

	(* syntax tree *)
	nEmpty = 0; nChar = 1; nAny = 2; nClass = 3; nCat = 4; nAlt = 5;
	nStar = 6; nPlus = 7; nQuest = 8; nGroup = 9; nBol = 10; nEol = 11;

TYPE
	(*	A class is ranges of code points plus a set of general categories, either of which may
		be empty, and a flag for [^...]. Ranges rather than a bitmap because the code space is
		1114112 wide; categories because \p{L} is one bit here and a table lookup at run time. *)
	Range = RECORD lo, hi: SIGNED32 END;
	Ranges = POINTER TO ARRAY OF Range;
	Class = RECORD
		first, count: SIGNED32;		(* the class's slice of the shared range array *)
		cats: SET;
		negated: BOOLEAN
	END;
	Classes = POINTER TO ARRAY OF Class;

	Instr = RECORD
		op: SIGNED32;
		ch: SIGNED32;		(* the code point, for opChar *)
		set: SIGNED32;		(* index into classes, for opClass *)
		x, y: SIGNED32		(* branch targets for opSplit/opJmp, slot for opSave *)
	END;
	Program = POINTER TO ARRAY OF Instr;

	Node = POINTER TO RECORD
		kind: SIGNED32;
		ch: SIGNED32;
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
		classes: Classes;
		nclasses: SIGNED32;
		ranges: Ranges;
		nranges: SIGNED32;
		ngroups-: SIGNED32;		(** capturing groups the pattern declares, not counting group 0 *)
		nslots: SIGNED32;
		caps: ARRAY 2 * (MaxGroups + 1) OF SIZE;
		found: BOOLEAN;
		clist, nlist: List;

		PROCEDURE & InitRegexp;
		BEGIN
			nprog := 0; nclasses := 0; nranges := 0; ngroups := 0; found := FALSE
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

		PROCEDURE InClass(set, c: SIGNED32): BOOLEAN;
		VAR i: SIGNED32; in: BOOLEAN;
		BEGIN
			in := FALSE;
			i := classes[set].first;
			WHILE (i < classes[set].first + classes[set].count) & ~in DO
				in := (ranges[i].lo <= c) & (c <= ranges[i].hi);
				INC(i)
			END;
			IF ~in & (classes[set].cats # {}) THEN in := Unicode.Category(c) IN classes[set].cats END;
			RETURN in # classes[set].negated
		END InClass;

		(*	The character at pos and where the one after it starts. A byte that does not decode
			is its own character: the alternative is a search that stops on bad input, and a
			pattern matcher is exactly the tool a caller reaches for when the input is suspect. *)
		PROCEDURE At(CONST s: ARRAY OF CHAR; pos, len: SIZE; VAR c: SIGNED32; VAR next: SIZE);
		VAR i: SIZE; ucs: UTF8Strings.Char32;
		BEGIN
			i := pos;
			IF UTF8Strings.DecodeChar(s, i, ucs) & (i > pos) & (i <= len) THEN
				c := SIGNED32(ucs); next := i
			ELSE
				c := ORD(s[pos]); next := pos + 1
			END
		END At;

		PROCEDURE Run(CONST s: ARRAY OF CHAR; start, len: SIZE): BOOLEAN;
		VAR cap: ARRAY 2 * (MaxGroups + 1) OF SIZE;
			i, k, pc, c: SIGNED32; pos, next: SIZE; matched, step, cut: BOOLEAN; t: List;
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
				IF pos < len THEN At(s, pos, len, c, next) ELSE c := -1; next := pos + 1 END;
				WHILE (i < clist.n) & ~cut DO
					pc := clist.pc[i];
					step := FALSE;
					CASE prog[pc].op OF
					  opChar: step := (pos < len) & (c = prog[pc].ch)
					| opAny: step := (pos < len) & (c # 0AH)
					| opClass: step := (pos < len) & InClass(prog[pc].set, c)
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
						Add(nlist, pc + 1, cap, next, len)
					END;
					INC(i)
				END;
				t := clist; clist := nlist; nlist := t;
				IF pos >= len THEN EXIT END;
				pos := next
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

		(*	Replace every match, expanding $0..$9 in the replacement to the groups of that
			match ($$ is a dollar). An empty match still advances by one character, which is
			the difference between replacing and hanging. *)
		PROCEDURE ReplaceAll*(CONST s, repl: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): BOOLEAN;
		VAR at, from, pos, len, gp, gl, i, n, o: SIZE; g: SIGNED32;

			PROCEDURE Emit(c: CHAR): BOOLEAN;
			BEGIN
				IF o + 1 >= LEN(out) THEN RETURN FALSE END;
				out[o] := c; INC(o);
				RETURN TRUE
			END Emit;

		BEGIN
			n := Strings.Length(s); from := 0; o := 0;
			WHILE (from <= n) & SELF.Find(s, from, pos, len) DO
				FOR at := from TO pos - 1 DO IF ~Emit(s[at]) THEN RETURN FALSE END END;
				i := 0;
				WHILE repl[i] # 0X DO
					IF (repl[i] = "$") & (repl[i + 1] = "$") THEN
						IF ~Emit("$") THEN RETURN FALSE END; INC(i, 2)
					ELSIF (repl[i] = "$") & (repl[i + 1] >= "0") & (repl[i + 1] <= "9") THEN
						g := ORD(repl[i + 1]) - ORD("0"); INC(i, 2);
						IF SELF.Group(g, gp, gl) THEN
							FOR at := gp TO gp + gl - 1 DO IF ~Emit(s[at]) THEN RETURN FALSE END END
						END
					ELSE
						IF ~Emit(repl[i]) THEN RETURN FALSE END; INC(i)
					END
				END;
				IF len = 0 THEN
					IF pos < n THEN IF ~Emit(s[pos]) THEN RETURN FALSE END END;
					from := pos + 1
				ELSE
					from := pos + len
				END
			END;
			FOR at := from TO n - 1 DO IF ~Emit(s[at]) THEN RETURN FALSE END END;
			out[o] := 0X;
			RETURN TRUE
		END ReplaceAll;

		(*	The pieces between the matches. "a1b22c" split on [0-9]+ is a, b, c -- and a match
			at either end leaves the empty piece there, the way Go and Python both do it. *)
		PROCEDURE Split*(CONST s: ARRAY OF CHAR; VAR parts: Strings.StringArray): SIZE;
		VAR from, pos, len, n, count, k, at: SIZE; piece: Strings.String;

			PROCEDURE Grow;
			VAR bigger: Strings.StringArray; i: SIZE;
			BEGIN
				IF parts = NIL THEN NEW(parts, 8)
				ELSIF count = LEN(parts) THEN
					NEW(bigger, 2 * count);
					FOR i := 0 TO count - 1 DO bigger[i] := parts[i] END;
					parts := bigger
				END
			END Grow;

		BEGIN
			n := Strings.Length(s); from := 0; count := 0;
			WHILE (from <= n) & SELF.Find(s, from, pos, len) & (len > 0) DO
				Grow;
				NEW(piece, pos - from + 1);
				k := 0;
				FOR at := from TO pos - 1 DO piece[k] := s[at]; INC(k) END;
				piece[k] := 0X;
				parts[count] := piece; INC(count);
				from := pos + len
			END;
			Grow;
			NEW(piece, n - from + 1);
			k := 0;
			FOR at := from TO n - 1 DO piece[k] := s[at]; INC(k) END;
			piece[k] := 0X;
			parts[count] := piece; INC(count);
			RETURN count
		END Split;

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
		tlo, thi: ARRAY 8 OF SIGNED32;		(* the spans a shorthand stands for, before Pour *)
		tn: SIGNED32;

		PROCEDURE & InitParser(CONST pattern: ARRAY OF CHAR; re: Regexp);
		BEGIN
			len := Strings.Length(pattern);
			NEW(pat, len + 1); COPY(pattern, pat^);
			pos := 0; groups := 0; tn := 0; r := re; failed := FALSE; message := ""
		END InitParser;

		(*	The next character of the pattern, decoded: a literal outside ASCII is one character
			and not the two or three bytes it is written in. Everything the syntax itself uses is
			ASCII, so Ch stays a byte. *)
		PROCEDURE Rune(): SIGNED32;
		VAR i: SIZE; ucs: UTF8Strings.Char32;
		BEGIN
			IF pos >= len THEN RETURN 0 END;
			i := pos;
			IF UTF8Strings.DecodeChar(pat^, i, ucs) & (i > pos) & (i <= len) THEN
				pos := i; RETURN SIGNED32(ucs)
			END;
			i := pos; INC(pos);
			RETURN ORD(pat[i])
		END Rune;

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
			NEW(n); n.kind := kind; n.ch := 0; n.set := -1; n.group := 0;
			n.greedy := TRUE; n.left := NIL; n.right := NIL;
			RETURN n
		END NewNode;

		PROCEDURE NewClass(): SIGNED32;
		VAR grown: Classes; i: SIGNED32;
		BEGIN
			IF r.classes = NIL THEN NEW(r.classes, 8)
			ELSIF r.nclasses = LEN(r.classes) THEN
				NEW(grown, 2 * r.nclasses);
				FOR i := 0 TO r.nclasses - 1 DO grown[i] := r.classes[i] END;
				r.classes := grown
			END;
			r.classes[r.nclasses].first := r.nranges;
			r.classes[r.nclasses].count := 0;
			r.classes[r.nclasses].cats := {};
			r.classes[r.nclasses].negated := FALSE;
			INC(r.nclasses);
			RETURN r.nclasses - 1
		END NewClass;

		(* Ranges go to the class being built, which is always the last one. *)
		PROCEDURE AddRange(set, lo, hi: SIGNED32);
		VAR grown: Ranges; i: SIGNED32;
		BEGIN
			IF r.ranges = NIL THEN NEW(r.ranges, 16)
			ELSIF r.nranges = LEN(r.ranges) THEN
				NEW(grown, 2 * r.nranges);
				FOR i := 0 TO r.nranges - 1 DO grown[i] := r.ranges[i] END;
				r.ranges := grown
			END;
			r.ranges[r.nranges].lo := lo; r.ranges[r.nranges].hi := hi;
			INC(r.nranges); INC(r.classes[set].count)
		END AddRange;

		(*	The spans a shorthand stands for, collected first so that the upper-case form can
			add their complement instead -- which is what lets [\D] and [\S] mean anything. *)
		PROCEDURE Pour(set: SIGNED32; negate: BOOLEAN);
		VAR i, next: SIGNED32;
		BEGIN
			IF ~negate THEN
				FOR i := 0 TO tn - 1 DO AddRange(set, tlo[i], thi[i]) END
			ELSE
				next := 0;
				FOR i := 0 TO tn - 1 DO
					IF tlo[i] > next THEN AddRange(set, next, tlo[i] - 1) END;
					next := thi[i] + 1
				END;
				IF next <= Unicode.MaxCode THEN AddRange(set, next, Unicode.MaxCode) END
			END;
			tn := 0
		END Pour;

		PROCEDURE Span(lo, hi: SIGNED32);
		BEGIN
			tlo[tn] := lo; thi[tn] := hi; INC(tn)
		END Span;

		(*	\d \w \s and their negations. ASCII on purpose, the way Go reads them: a person who
			wants every letter Unicode knows writes \p{L}, and a person who writes \w means the
			characters of an identifier. *)
		PROCEDURE Shorthand(c: CHAR; set: SIGNED32): BOOLEAN;
		BEGIN
			tn := 0;
			CASE c OF
			  "d", "D": Span(30H, 39H)
			| "w", "W": Span(30H, 39H); Span(41H, 5AH); Span(5FH, 5FH); Span(61H, 7AH)
			| "s", "S": Span(9, 0DH); Span(20H, 20H)
			ELSE RETURN FALSE
			END;
			Pour(set, c < "a");			(* upper case is the complement *)
			RETURN TRUE
		END Shorthand;

		(*	\p{Lu} is one general category, \p{L} every category starting with that letter. *)
		PROCEDURE CategorySet(CONST name: ARRAY OF CHAR; VAR cats: SET): BOOLEAN;
			PROCEDURE Named(CONST n: ARRAY OF CHAR; c: SIGNED32);
			BEGIN
				IF (name = n) OR ((name[1] = 0X) & (name[0] = n[0])) THEN cats := cats + {c} END
			END Named;
		BEGIN
			cats := {};
			IF (name[0] = 0X) OR (name[2] # 0X) THEN RETURN FALSE END;
			Named("Lu", Unicode.Lu); Named("Ll", Unicode.Ll); Named("Lt", Unicode.Lt);
			Named("Lm", Unicode.Lm); Named("Lo", Unicode.Lo);
			Named("Mn", Unicode.Mn); Named("Mc", Unicode.Mc); Named("Me", Unicode.Me);
			Named("Nd", Unicode.Nd); Named("Nl", Unicode.Nl); Named("No", Unicode.No);
			Named("Pc", Unicode.Pc); Named("Pd", Unicode.Pd); Named("Ps", Unicode.Ps);
			Named("Pe", Unicode.Pe); Named("Pi", Unicode.Pi); Named("Pf", Unicode.Pf);
			Named("Po", Unicode.Po);
			Named("Sm", Unicode.Sm); Named("Sc", Unicode.Sc); Named("Sk", Unicode.Sk);
			Named("So", Unicode.So);
			Named("Zs", Unicode.Zs); Named("Zl", Unicode.Zl); Named("Zp", Unicode.Zp);
			Named("Cc", Unicode.Cc); Named("Cf", Unicode.Cf); Named("Cs", Unicode.Cs);
			Named("Co", Unicode.Co); Named("Cn", Unicode.Cn);
			RETURN cats # {}
		END CategorySet;

		(* Reads \p{X} or \P{X} after the p, and answers whether it was one. *)
		PROCEDURE Property(c: CHAR; set: SIGNED32; inClass: BOOLEAN): BOOLEAN;
		VAR name: ARRAY 4 OF CHAR; i: SIGNED32; cats: SET;
		BEGIN
			IF (c # "p") & (c # "P") THEN RETURN FALSE END;
			INC(pos);
			IF SELF.Ch() # "{" THEN Fail("expected { after \p"); RETURN TRUE END;
			INC(pos);
			i := 0;
			WHILE (pos < len) & (SELF.Ch() # "}") & (i < 3) DO
				name[i] := SELF.Ch(); INC(i); INC(pos)
			END;
			name[i] := 0X;
			IF SELF.Ch() # "}" THEN Fail("unterminated \p{...}"); RETURN TRUE END;
			INC(pos);
			IF ~CategorySet(name, cats) THEN Fail("unknown general category"); RETURN TRUE END;
			IF c = "P" THEN
				IF inClass THEN Fail("\P is not allowed inside a class"); RETURN TRUE END;
				r.classes[set].negated := TRUE
			END;
			r.classes[set].cats := r.classes[set].cats + cats;
			RETURN TRUE
		END Property;

		(*	The character an escape stands for. \d and \p are not characters and are handled by
			the caller; everything else is itself, which is what lets a pattern write \. \* \(
			without a table of what is special where. *)
		PROCEDURE Escaped(): SIGNED32;
		VAR c: CHAR;
		BEGIN
			c := SELF.Ch();
			CASE c OF
			  "n": INC(pos); RETURN 0AH
			| "r": INC(pos); RETURN 0DH
			| "t": INC(pos); RETURN 9
			| "f": INC(pos); RETURN 0CH
			| "v": INC(pos); RETURN 0BH
			| 0X: Fail("pattern ends in a backslash"); RETURN 0
			ELSE RETURN SELF.Rune()
			END
		END Escaped;

		(*	One member of a class: a character or a span of them. Escapes that are whole sets
			have been taken by the caller. *)
		PROCEDURE ClassItem(set: SIGNED32);
		VAR lo, hi: SIGNED32;
		BEGIN
			IF SELF.Ch() = "\" THEN INC(pos); lo := SELF.Escaped() ELSE lo := SELF.Rune() END;
			IF failed THEN RETURN END;
			IF (SELF.Ch() = "-") & (pos + 1 < len) & (pat[pos + 1] # "]") THEN
				INC(pos);
				IF SELF.Ch() = "\" THEN INC(pos); hi := SELF.Escaped() ELSE hi := SELF.Rune() END;
				IF failed THEN RETURN END;
				IF hi < lo THEN Fail("range runs backwards"); RETURN END;
				AddRange(set, lo, hi)
			ELSE
				AddRange(set, lo, lo)
			END
		END ClassItem;

		PROCEDURE ParseClass(): Node;
		VAR n: Node; set: SIGNED32; negate, first: BOOLEAN; c: CHAR;
		BEGIN
			INC(pos);				(* [ *)
			set := SELF.NewClass();
			negate := SELF.Ch() = "^";
			IF negate THEN INC(pos) END;
			first := TRUE;
			WHILE (pos < len) & ((SELF.Ch() # "]") OR first) DO
				first := FALSE;
				IF SELF.Ch() = "\" THEN
					INC(pos);
					c := SELF.Ch();
					IF SELF.Shorthand(c, set) THEN INC(pos)
					ELSIF SELF.Property(c, set, TRUE) THEN (* taken *)
					ELSE DEC(pos); SELF.ClassItem(set)
					END
				ELSE
					SELF.ClassItem(set)
				END;
				IF failed THEN RETURN NIL END
			END;
			IF SELF.Ch() # "]" THEN Fail("unterminated character class"); RETURN NIL END;
			INC(pos);
			r.classes[set].negated := negate;
			n := SELF.NewNode(nClass); n.set := set;
			RETURN n
		END ParseClass;

		PROCEDURE ParseAtom(): Node;
		VAR n, inner: Node; c: CHAR; set, cp: SIGNED32; capturing: BOOLEAN; g: SIGNED32;
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
				IF SELF.Property(SELF.Ch(), set, FALSE) THEN
					IF failed THEN RETURN NIL END;
					n := SELF.NewNode(nClass); n.set := set;
					RETURN n
				END;
				DEC(r.nclasses);		(* the class was not needed after all *)
				cp := SELF.Escaped();
				IF failed THEN RETURN NIL END;
				n := SELF.NewNode(nChar); n.ch := cp;
				RETURN n
			| ")": Fail("unbalanced )"); RETURN NIL
			| "*", "+", "?": Fail("nothing to repeat"); RETURN NIL
			ELSE
				n := SELF.NewNode(nChar); n.ch := SELF.Rune();
				RETURN n
			END
		END ParseAtom;

		PROCEDURE Clone(n: Node): Node;
		VAR c: Node;
		BEGIN
			IF n = NIL THEN RETURN NIL END;
			c := SELF.NewNode(n.kind);
			c.ch := n.ch; c.set := n.set; c.group := n.group; c.greedy := n.greedy;
			c.left := SELF.Clone(n.left); c.right := SELF.Clone(n.right);
			RETURN c
		END Clone;

		PROCEDURE Cat(left, right: Node): Node;
		VAR n: Node;
		BEGIN
			IF left = NIL THEN RETURN right END;
			IF right = NIL THEN RETURN left END;
			n := SELF.NewNode(nCat); n.left := left; n.right := right;
			RETURN n
		END Cat;

		(*	x{m,n} is written out rather than counted: m copies, then n-m optional ones nested
			so that a copy cannot be skipped and a later one taken. That is what makes the
			program grow with the count, and why MaxRepeat exists. *)
		PROCEDURE Repeated(x: Node; min, max: SIGNED32; greedy: BOOLEAN): Node;
		VAR head, tail, q, star: Node; i: SIGNED32;
		BEGIN
			head := NIL;
			FOR i := 1 TO min DO head := SELF.Cat(head, SELF.Clone(x)) END;
			IF max < 0 THEN
				star := SELF.NewNode(nStar); star.greedy := greedy; star.left := SELF.Clone(x);
				RETURN SELF.Cat(head, star)
			END;
			tail := NIL;
			FOR i := min + 1 TO max DO
				q := SELF.NewNode(nQuest); q.greedy := greedy;
				q.left := SELF.Cat(SELF.Clone(x), tail);
				tail := q
			END;
			IF (head = NIL) & (tail = NIL) THEN RETURN SELF.NewNode(nEmpty) END;
			RETURN SELF.Cat(head, tail)
		END Repeated;

		PROCEDURE Number(VAR value: SIGNED32): BOOLEAN;
		VAR digits: SIGNED32;
		BEGIN
			value := 0; digits := 0;
			WHILE (SELF.Ch() >= "0") & (SELF.Ch() <= "9") DO
				value := value * 10 + (ORD(SELF.Ch()) - ORD("0"));
				INC(pos); INC(digits);
				IF value > MaxRepeat THEN Fail("repetition count is larger than MaxRepeat"); RETURN FALSE END
			END;
			RETURN digits > 0
		END Number;

		(*	{m}, {m,} or {m,n}. Anything else that starts with a brace is a brace: Perl reads
			it that way and so does every pattern a person pastes in, so a failed parse rewinds
			instead of failing the compile. *)
		PROCEDURE ParseCount(x: Node; VAR done: BOOLEAN): Node;
		VAR mark: SIZE; min, max: SIGNED32; greedy: BOOLEAN;
		BEGIN
			mark := pos; done := FALSE;
			INC(pos);
			IF ~SELF.Number(min) THEN
				IF failed THEN RETURN NIL END;
				pos := mark; RETURN x
			END;
			max := min;
			IF SELF.Ch() = "," THEN
				INC(pos);
				IF SELF.Ch() = "}" THEN max := -1
				ELSIF ~SELF.Number(max) THEN
					IF failed THEN RETURN NIL END;
					pos := mark; RETURN x
				END
			END;
			IF SELF.Ch() # "}" THEN pos := mark; RETURN x END;
			INC(pos);
			IF (max >= 0) & (max < min) THEN Fail("repetition counts run backwards"); RETURN NIL END;
			greedy := TRUE;
			IF SELF.Ch() = "?" THEN INC(pos); greedy := FALSE END;
			done := TRUE;
			RETURN SELF.Repeated(x, min, max, greedy)
		END ParseCount;

		PROCEDURE ParseRepeat(): Node;
		VAR n, rep: Node; c: CHAR; counted: BOOLEAN;
		BEGIN
			n := SELF.ParseAtom();
			IF failed THEN RETURN NIL END;
			LOOP
				c := SELF.Ch();
				IF c = "{" THEN
					n := SELF.ParseCount(n, counted);
					IF failed THEN RETURN NIL END;
					IF counted THEN (* another quantifier may follow *) ELSE EXIT END
				ELSIF (c = "*") OR (c = "+") OR (c = "?") THEN
					INC(pos);
					CASE c OF
					  "*": rep := SELF.NewNode(nStar)
					| "+": rep := SELF.NewNode(nPlus)
					ELSE rep := SELF.NewNode(nQuest)
					END;
					rep.left := n;
					IF SELF.Ch() = "?" THEN INC(pos); rep.greedy := FALSE END;
					n := rep
				ELSE EXIT
				END
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

		PROCEDURE Put(op, ch, set, x, y: SIGNED32): SIGNED32;
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
			| nAny: i := SELF.Put(opAny, 0, -1, 0, 0)
			| nClass: i := SELF.Put(opClass, 0, n.set, 0, 0)
			| nBol: i := SELF.Put(opBol, 0, -1, 0, 0)
			| nEol: i := SELF.Put(opEol, 0, -1, 0, 0)
			| nCat: SELF.Emit(n.left); SELF.Emit(n.right)
			| nGroup:
				i := SELF.Put(opSave, 0, -1, 2 * n.group, 0);
				SELF.Emit(n.left);
				i := SELF.Put(opSave, 0, -1, 2 * n.group + 1, 0)
			| nAlt:
				split := SELF.Put(opSplit, 0, -1, 0, 0);
				r.prog[split].x := r.nprog;
				SELF.Emit(n.left);
				jmp := SELF.Put(opJmp, 0, -1, 0, 0);
				r.prog[split].y := r.nprog;
				SELF.Emit(n.right);
				r.prog[jmp].x := r.nprog
			| nQuest:
				split := SELF.Put(opSplit, 0, -1, 0, 0);
				body := r.nprog;
				SELF.Emit(n.left);
				IF n.greedy THEN r.prog[split].x := body; r.prog[split].y := r.nprog
				ELSE r.prog[split].x := r.nprog; r.prog[split].y := body
				END
			| nStar:
				top := SELF.Put(opSplit, 0, -1, 0, 0);
				body := r.nprog;
				SELF.Emit(n.left);
				jmp := SELF.Put(opJmp, 0, -1, top, 0);
				IF n.greedy THEN r.prog[top].x := body; r.prog[top].y := r.nprog
				ELSE r.prog[top].x := r.nprog; r.prog[top].y := body
				END
			| nPlus:
				body := r.nprog;
				SELF.Emit(n.left);
				split := SELF.Put(opSplit, 0, -1, 0, 0);
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
	i := e.Put(opSave, 0, -1, 0, 0);		(* group 0 opens *)
	e.Emit(tree);
	i := e.Put(opSave, 0, -1, 1, 0);		(* and closes *)
	i := e.Put(opMatch, 0, -1, 0, 0);
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
