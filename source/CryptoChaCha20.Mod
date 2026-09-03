MODULE CryptoChaCha20;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "RFC 8439 ChaCha20, and the AEAD it makes with Poly1305";
	LIMITATIONS
		"- the nonce is the 96-bit one of RFC 8439, not the 64-bit nonce of the original paper;
		 - the counter is 32 bits, so one key and nonce encrypt at most 256 gigabytes;
		 - a nonce may be used once per key and the module cannot check that: repeat one and the
		   keystream repeats with it, which loses the plaintext and the authentication key both."
*)
(*	ChaCha20 is add, rotate and exclusive-or on a four by four square of words, and nothing it
	does depends on the data -- so it takes the same time on every input, which is the property
	AES tables cannot promise without hardware. Seal and Open below are the AEAD of RFC 8439:
	encrypt with the keystream from counter 1, authenticate with a Poly1305 key taken from
	counter 0, and refuse on the tag rather than hand back plaintext nobody vouched for. *)

IMPORT Poly1305 := CryptoPoly1305;

CONST
	KeySize* = 32;			(** bytes *)
	NonceSize* = 12;		(** bytes *)
	TagSize* = 16;			(** bytes of authentication tag *)
	BlockSize* = 64;		(** bytes of keystream per block *)

TYPE
	State = ARRAY 16 OF SIGNED32;

(*	Assembled in a SET32 and not by arithmetic: a word whose top byte is 80H or more is a
	negative SIGNED32, and converting the sum into one is a range violation rather than the
	wrap this needs. It cost a wrong keystream for exactly the keys that have a high byte. *)
PROCEDURE Get32(CONST b: ARRAY OF CHAR; pos: SIZE): SIGNED32;
VAR s: SET32; i: SIGNED32;
BEGIN
	s := {};
	FOR i := 3 TO 0 BY -1 DO
		s := LSH(s, 8) + SET32(ORD(b[pos + i]))
	END;
	RETURN SIGNED32(s)
END Get32;

PROCEDURE Put32(v: SIGNED32; VAR b: ARRAY OF CHAR; pos: SIZE);
VAR s: SET32; i: SIGNED32;
BEGIN
	s := SET32(v);
	FOR i := 0 TO 3 DO
		b[pos + i] := CHR(SIGNED32(s * SET32(0FFH)));
		s := LSH(s, -8)
	END
END Put32;

PROCEDURE -Rot(x: SIGNED32; n: SIGNED32): SIGNED32;
BEGIN
	RETURN SIGNED32(ROT(SET32(x), n))
END Rot;

PROCEDURE Quarter(VAR s: State; a, b, c, d: SIGNED32);
BEGIN
	INC(s[a], s[b]); s[d] := Rot(SIGNED32(SET32(s[d]) / SET32(s[a])), 16);
	INC(s[c], s[d]); s[b] := Rot(SIGNED32(SET32(s[b]) / SET32(s[c])), 12);
	INC(s[a], s[b]); s[d] := Rot(SIGNED32(SET32(s[d]) / SET32(s[a])), 8);
	INC(s[c], s[d]); s[b] := Rot(SIGNED32(SET32(s[b]) / SET32(s[c])), 7)
END Quarter;

(** One 64-byte block of keystream for this key, nonce and counter. *)
PROCEDURE Block*(CONST key: ARRAY OF CHAR; CONST nonce: ARRAY OF CHAR; counter: SIGNED32;
					VAR out: ARRAY OF CHAR; pos: SIZE);
VAR s, w: State; i: SIGNED32;
BEGIN
	s[0] := SIGNED32(61707865H); s[1] := SIGNED32(3320646EH);		(* "expand 32-byte k" *)
	s[2] := SIGNED32(79622D32H); s[3] := SIGNED32(6B206574H);
	FOR i := 0 TO 7 DO s[4 + i] := Get32(key, 4 * i) END;
	s[12] := counter;
	FOR i := 0 TO 2 DO s[13 + i] := Get32(nonce, 4 * i) END;
	FOR i := 0 TO 15 DO w[i] := s[i] END;
	FOR i := 1 TO 10 DO											(* ten double rounds *)
		Quarter(w, 0, 4, 8, 12); Quarter(w, 1, 5, 9, 13);
		Quarter(w, 2, 6, 10, 14); Quarter(w, 3, 7, 11, 15);
		Quarter(w, 0, 5, 10, 15); Quarter(w, 1, 6, 11, 12);
		Quarter(w, 2, 7, 8, 13); Quarter(w, 3, 4, 9, 14)
	END;
	FOR i := 0 TO 15 DO Put32(w[i] + s[i], out, pos + 4 * i) END
END Block;

(*	Encryption and decryption are the same operation: the keystream is exclusive-ored with what
	is there. src and dst may be the same array. *)
PROCEDURE XOR*(CONST key: ARRAY OF CHAR; CONST nonce: ARRAY OF CHAR; counter: SIGNED32;
				CONST src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR; len: SIZE);
VAR stream: ARRAY BlockSize OF CHAR; at, n, i: SIZE;
BEGIN
	at := 0;
	WHILE at < len DO
		Block(key, nonce, counter, stream, 0);
		n := len - at;
		IF n > BlockSize THEN n := BlockSize END;
		FOR i := 0 TO n - 1 DO
			dst[at + i] := CHR(SIGNED32(SET32(ORD(src[at + i])) / SET32(ORD(stream[i]))))
		END;
		INC(at, n); INC(counter)
	END
END XOR;

(*	The Poly1305 key for a message is the first 32 bytes of this key and nonce's keystream at
	counter zero, so it is different for every message and never touches the plaintext. *)
PROCEDURE MacKey(CONST key, nonce: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR stream: ARRAY BlockSize OF CHAR; i: SIZE;
BEGIN
	Block(key, nonce, 0, stream, 0);
	FOR i := 0 TO 31 DO out[i] := stream[i] END
END MacKey;

PROCEDURE Tag(CONST macKey: ARRAY OF CHAR; CONST aad: ARRAY OF CHAR; aadLen: SIZE;
				CONST text: ARRAY OF CHAR; textLen: SIZE; VAR tag: ARRAY OF CHAR);
VAR p: Poly1305.Poly; pad: ARRAY 16 OF CHAR; lengths: ARRAY 16 OF CHAR; i: SIZE; n: SIZE;
BEGIN
	FOR i := 0 TO 15 DO pad[i] := 0X END;
	NEW(p, macKey);
	p.Update(aad, 0, aadLen);
	n := (16 - aadLen MOD 16) MOD 16;
	p.Update(pad, 0, n);
	p.Update(text, 0, textLen);
	n := (16 - textLen MOD 16) MOD 16;
	p.Update(pad, 0, n);
	(* the two lengths, little endian, so that a byte moved from the text to the header shows *)
	FOR i := 0 TO 15 DO lengths[i] := 0X END;
	n := aadLen;
	FOR i := 0 TO 7 DO lengths[i] := CHR(n MOD 100H); n := n DIV 100H END;
	n := textLen;
	FOR i := 8 TO 15 DO lengths[i] := CHR(n MOD 100H); n := n DIV 100H END;
	p.Update(lengths, 0, 16);
	p.GetTag(tag, 0)
END Tag;

(** Encrypt and authenticate: dst gets the ciphertext, tag the sixteen bytes that vouch for it. *)
PROCEDURE Seal*(CONST key, nonce: ARRAY OF CHAR; CONST aad: ARRAY OF CHAR; aadLen: SIZE;
				CONST plain: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR; len: SIZE;
				VAR tag: ARRAY OF CHAR);
VAR macKey: ARRAY 32 OF CHAR;
BEGIN
	MacKey(key, nonce, macKey);
	XOR(key, nonce, 1, plain, dst, len);
	Tag(macKey, aad, aadLen, dst, len, tag)
END Seal;

(*	Decrypt only if the tag is the one this key would have produced. The comparison walks the
	whole tag whatever it finds: a comparison that stops at the first wrong byte tells an
	attacker how many bytes were right, which is enough to forge one byte at a time. *)
PROCEDURE Open*(CONST key, nonce: ARRAY OF CHAR; CONST aad: ARRAY OF CHAR; aadLen: SIZE;
				CONST cipher: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR; len: SIZE;
				CONST tag: ARRAY OF CHAR): BOOLEAN;
VAR macKey: ARRAY 32 OF CHAR; want: ARRAY TagSize OF CHAR; diff: SIGNED32; i: SIZE;
BEGIN
	MacKey(key, nonce, macKey);
	Tag(macKey, aad, aadLen, cipher, len, want);
	diff := 0;
	FOR i := 0 TO TagSize - 1 DO
		diff := SIGNED32(SET32(diff) + (SET32(ORD(want[i])) / SET32(ORD(tag[i]))))
	END;
	IF diff # 0 THEN RETURN FALSE END;
	XOR(key, nonce, 1, cipher, dst, len);
	RETURN TRUE
END Open;

END CryptoChaCha20.
