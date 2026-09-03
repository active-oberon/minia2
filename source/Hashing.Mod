MODULE Hashing;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "Hash and equality for the key types a Map is usually keyed by";
	LIMITATIONS
		"- not a cryptographic hash and not resistant to a chosen-key attack: this is a good
		   spread and nothing more. A map fed keys from a hostile network wants a keyed hash;
		 - strings hash by bytes, so two spellings of the same text in different normal forms
		   are different keys;
		 - the constants are FNV-1a's but the basis is not, so these numbers are this library's
		   and not comparable with another implementation's."
*)
(*	GenericMaps takes a hash and an equality as module parameters, and without a place to get
	them every caller writes one. These are that place.

	It is FNV-1a -- exclusive-or a byte, multiply by a prime -- and not the rotate-and-xor that
	FoxBasic and TFClasses use for the compiler's own tables. That one has no multiplication,
	which is why it was tried first, and it does not work here: rotation and exclusive-or are
	linear, so keys that differ in a few bits produce hashes that differ in a few bits, and a
	thousand keys named key000..key999 landed in 28 of 64 buckets. Multiplication is what breaks
	that structure. The suite measures the spread rather than trusting this paragraph. *)

IMPORT Strings;

CONST
	prime = 1099511628211;				(* FNV-1a, 64 bit; the multiplication wraps and is meant to *)
	basis = 2166136261;					(* FNV's 32-bit basis: the 64-bit one does not fit a literal here *)
	positive = 7FFFFFFFFFFFFFFFH;		(* a hash is a number, and a negative one is a nuisance *)

(*	The bucket a map picks is the hash modulo a power of two, so it reads the LOW bits, while
	the accumulation above fills the high ones. Fold them down and return something no caller
	has to take the absolute value of. *)
PROCEDURE Mix(h: SIZE): SIZE;
BEGIN
	h := h * prime;
	h := SIZE(SET(h) / SET(ROT(h, 32)));
	h := h * prime;
	h := SIZE(SET(h) / SET(ROT(h, 29)));
	RETURN SIZE(SET(h) * SET(positive))
END Mix;

(** The bytes of a 0X-terminated string. *)
PROCEDURE String*(CONST s: ARRAY OF CHAR): SIZE;
VAR h: SIZE; i: SIZE;
BEGIN
	h := basis; i := 0;
	WHILE s[i] # 0X DO
		h := SIZE(SET(h) / SET(ORD(s[i]))) * prime;
		INC(i)
	END;
	RETURN Mix(h)
END String;

(** The same over len bytes, terminator or not. *)
PROCEDURE Bytes*(CONST b: ARRAY OF CHAR; len: SIZE): SIZE;
VAR h, i: SIZE;
BEGIN
	h := basis;
	FOR i := 0 TO len - 1 DO h := SIZE(SET(h) / SET(ORD(b[i]))) * prime END;
	RETURN Mix(h)
END Bytes;

(*	A whole number is its own hash in most tables, and that is nearly right: what breaks is a
	table whose size is a power of two, where the high bits are never looked at, and keys that
	arrive in sequence. Mix puts the high bits where they will be read. *)
PROCEDURE Int*(x: SIGNED64): SIZE;
BEGIN
	RETURN Mix(SIZE(x))
END Int;

(** The pair for Strings.String keys, which is what a map of names is keyed by. *)
PROCEDURE StringPtr*(s: Strings.String): SIZE;
BEGIN
	IF s = NIL THEN RETURN 0 END;
	RETURN String(s^)
END StringPtr;

PROCEDURE StringPtrEqual*(a, b: Strings.String): BOOLEAN;
BEGIN
	IF (a = NIL) OR (b = NIL) THEN RETURN a = b END;
	RETURN a^ = b^
END StringPtrEqual;

PROCEDURE IntEqual*(a, b: SIGNED64): BOOLEAN;
BEGIN
	RETURN a = b
END IntEqual;

END Hashing.
