(** AUTHOR "Andrii Puhachenko"; PURPOSE "Generic hash map and set"; *)

(*

	The container std/data was missing. GenericCollections has Stack, Queue, DEQue and Vector --
	everything that is a line of elements -- and nothing that is a lookup, so anything needing
	one grew its own: TFClasses has a string dictionary, FoxBasic has a symbol table, and neither
	can hand its map to the other. A map is a shared type, which is what puts it in std.

	Parameters:

		K - the key type;

		V - the value type. A Set carries no value, so instantiate it with BOOLEAN and ignore it;

		Hash - "(CONST k: K): SIZE", any spread of the key over the whole range; Hashing has one
			for the usual key types. It may return a negative number;

		Equal - "(CONST a, b: K): BOOLEAN". Two keys that are Equal MUST hash the same, or the
			map will hold both and find neither reliably.

	Collisions are chained, and the table doubles when it is three quarters full, so a lookup
	costs what the hash costs and nothing more.

*)

MODULE GenericMaps(TYPE K, TYPE V, CONST Hash, CONST Equal);

CONST
	INITIAL_SIZE* = 16;		(** buckets a fresh map starts with; it doubles from there *)

TYPE
	Entry = POINTER TO RECORD
		key: K;
		value: V;
		hash: SIZE;
		next: Entry
	END;

	Buckets = POINTER TO ARRAY OF Entry;

	Map* = OBJECT
	VAR
		buckets: Buckets;
		count-: SIZE;			(** how many pairs are in it *)

		PROCEDURE & New*;
		BEGIN
			NEW(buckets, INITIAL_SIZE);
			count := 0
		END New;

		PROCEDURE Index(h: SIZE; n: SIZE): SIZE;
		VAR i: SIZE;
		BEGIN
			i := h MOD n;
			IF i < 0 THEN INC(i, n) END;		(* a hash may be negative; a bucket may not *)
			RETURN i
		END Index;

		PROCEDURE Find(CONST key: K; VAR h: SIZE): Entry;
		VAR e: Entry;
		BEGIN
			h := Hash(key);
			e := buckets[SELF.Index(h, LEN(buckets))];
			WHILE e # NIL DO
				IF (e.hash = h) & Equal(e.key, key) THEN RETURN e END;
				e := e.next
			END;
			RETURN NIL
		END Find;

		PROCEDURE Grow;
		VAR old: Buckets; fresh: Buckets; e, next: Entry; i, at: SIZE;
		BEGIN
			old := buckets;
			NEW(fresh, 2 * LEN(old));
			FOR i := 0 TO LEN(old) - 1 DO
				e := old[i];
				WHILE e # NIL DO
					next := e.next;
					at := SELF.Index(e.hash, LEN(fresh));
					e.next := fresh[at]; fresh[at] := e;
					e := next
				END
			END;
			buckets := fresh
		END Grow;

		(** Add the pair, or replace the value of a key that is already there. *)
		PROCEDURE Put*(CONST key: K; CONST value: V);
		VAR e: Entry; h, at: SIZE;
		BEGIN
			e := SELF.Find(key, h);
			IF e # NIL THEN e.value := value; RETURN END;
			IF 4 * (count + 1) > 3 * LEN(buckets) THEN SELF.Grow END;
			at := SELF.Index(h, LEN(buckets));
			NEW(e); e.key := key; e.value := value; e.hash := h;
			e.next := buckets[at]; buckets[at] := e;
			INC(count)
		END Put;

		(** The value of key, if it is there. *)
		PROCEDURE Get*(CONST key: K; VAR value: V): BOOLEAN;
		VAR e: Entry; h: SIZE;
		BEGIN
			e := SELF.Find(key, h);
			IF e = NIL THEN RETURN FALSE END;
			value := e.value;
			RETURN TRUE
		END Get;

		PROCEDURE Contains*(CONST key: K): BOOLEAN;
		VAR h: SIZE;
		BEGIN
			RETURN SELF.Find(key, h) # NIL
		END Contains;

		(** FALSE when there was nothing to remove. *)
		PROCEDURE Remove*(CONST key: K): BOOLEAN;
		VAR e, prev: Entry; h, at: SIZE;
		BEGIN
			h := Hash(key);
			at := SELF.Index(h, LEN(buckets));
			e := buckets[at]; prev := NIL;
			WHILE e # NIL DO
				IF (e.hash = h) & Equal(e.key, key) THEN
					IF prev = NIL THEN buckets[at] := e.next ELSE prev.next := e.next END;
					DEC(count);
					RETURN TRUE
				END;
				prev := e; e := e.next
			END;
			RETURN FALSE
		END Remove;

		PROCEDURE Count*(): SIZE;
		BEGIN
			RETURN count
		END Count;

		PROCEDURE Empty*(): BOOLEAN;
		BEGIN
			RETURN count = 0
		END Empty;

		PROCEDURE Reset*;
		BEGIN
			NEW(buckets, INITIAL_SIZE);
			count := 0
		END Reset;

		(** A walk over every pair, in no order at all. Adding or removing invalidates it. *)
		PROCEDURE All*(): Iterator;
		VAR it: Iterator;
		BEGIN
			NEW(it, buckets);
			RETURN it
		END All;

	END Map;

	Iterator* = OBJECT
	VAR
		buckets: Buckets;
		at: SIZE;
		e: Entry;

		PROCEDURE & Start*(b: Buckets);
		BEGIN
			buckets := b; at := 0; e := NIL
		END Start;

		(** The next pair, FALSE when there is none. *)
		PROCEDURE Next*(VAR key: K; VAR value: V): BOOLEAN;
		BEGIN
			WHILE (e = NIL) & (at < LEN(buckets)) DO
				e := buckets[at]; INC(at)
			END;
			IF e = NIL THEN RETURN FALSE END;
			key := e.key; value := e.value;
			e := e.next;
			RETURN TRUE
		END Next;

	END Iterator;

	(*	A set is a map whose value nobody reads. It is here rather than in a module of its own
		because the table would be the same code twice; the price is that instantiating one
		names a value type, and BOOLEAN is the one to name. *)
	Set* = OBJECT
	VAR
		map: Map;
		count-: SIZE;

		PROCEDURE & NewSet*;
		BEGIN
			NEW(map); count := 0
		END NewSet;

		(** TRUE when it was not there before. *)
		PROCEDURE Add*(CONST key: K): BOOLEAN;
		VAR v: V;
		BEGIN
			IF map.Contains(key) THEN RETURN FALSE END;
			map.Put(key, v);
			count := map.count;
			RETURN TRUE
		END Add;

		PROCEDURE Contains*(CONST key: K): BOOLEAN;
		BEGIN
			RETURN map.Contains(key)
		END Contains;

		PROCEDURE Remove*(CONST key: K): BOOLEAN;
		VAR gone: BOOLEAN;
		BEGIN
			gone := map.Remove(key);
			count := map.count;
			RETURN gone
		END Remove;

		PROCEDURE Count*(): SIZE;
		BEGIN
			RETURN count
		END Count;

		PROCEDURE Empty*(): BOOLEAN;
		BEGIN
			RETURN count = 0
		END Empty;

		PROCEDURE Reset*;
		BEGIN
			map.Reset; count := 0
		END Reset;

		PROCEDURE All*(): Iterator;
		BEGIN
			RETURN map.All()
		END All;

	END Set;

END GenericMaps.
