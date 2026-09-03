MODULE CryptoHKDF;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "RFC 5869 HKDF: turn one secret into as many keys as a protocol needs";
	LIMITATIONS
		"- the output is at most 255 hash lengths, which is the standard's limit and not this
		   implementation's;
		 - the hash is named by module, the way CryptoHMAC names it, so a caller passes
		   \"CryptoSHA256\" rather than an object."
*)
(*	Extract turns a secret of any shape -- a Diffie-Hellman result, a password already stretched,
	a device serial -- into one pseudorandom key of hash length. Expand turns that key into as
	many bytes as are wanted, each labelled by info so that two uses of the same secret cannot
	produce the same key by accident. Deriving a key by hashing the secret with a label is the
	thing this exists to stop people doing. *)

IMPORT HMAC := CryptoHMAC;

CONST
	MaxHash = 64;		(* SHA-512's, the longest here *)

(** The extract step: a pseudorandom key of hash length, into prk. Returns its length, 0 on failure. *)
PROCEDURE Extract*(CONST hashmod: ARRAY OF CHAR; CONST salt: ARRAY OF CHAR; saltLen: SIZE;
					CONST ikm: ARRAY OF CHAR; ikmLen: SIZE; VAR prk: ARRAY OF CHAR): SIZE;
VAR mac: HMAC.HMac; zeros: ARRAY MaxHash OF CHAR; i: SIZE;
BEGIN
	NEW(mac, hashmod);
	IF mac.size > LEN(prk) THEN RETURN 0 END;
	IF saltLen > 0 THEN
		mac.Initialize(salt, saltLen)
	ELSE
		(* no salt means a string of zeros as long as the hash, which is not the same as no key *)
		FOR i := 0 TO mac.size - 1 DO zeros[i] := 0X END;
		mac.Initialize(zeros, mac.size)
	END;
	mac.Update(ikm, 0, ikmLen);
	mac.GetMac(prk, 0);
	RETURN mac.size
END Extract;

(** The expand step: len bytes into okm, labelled by info. FALSE if len is beyond the standard's limit. *)
PROCEDURE Expand*(CONST hashmod: ARRAY OF CHAR; CONST prk: ARRAY OF CHAR; prkLen: SIZE;
					CONST info: ARRAY OF CHAR; infoLen: SIZE; VAR okm: ARRAY OF CHAR; len: SIZE): BOOLEAN;
VAR mac: HMAC.HMac; t: ARRAY MaxHash OF CHAR; counter: ARRAY 1 OF CHAR;
	have, n, i: SIZE; block: SIGNED32;
BEGIN
	NEW(mac, hashmod);
	IF (len < 0) OR (len > 255 * mac.size) OR (len > LEN(okm)) THEN RETURN FALSE END;
	have := 0; block := 0; n := 0;
	WHILE have < len DO
		INC(block);
		mac.Initialize(prk, prkLen);
		IF block > 1 THEN mac.Update(t, 0, mac.size) END;		(* T(i) feeds into T(i+1) *)
		mac.Update(info, 0, infoLen);
		counter[0] := CHR(block);
		mac.Update(counter, 0, 1);
		mac.GetMac(t, 0);
		n := len - have;
		IF n > mac.size THEN n := mac.size END;
		FOR i := 0 TO n - 1 DO okm[have + i] := t[i] END;
		INC(have, n)
	END;
	RETURN TRUE
END Expand;

(** Both steps, which is what a caller almost always wants. *)
PROCEDURE Derive*(CONST hashmod: ARRAY OF CHAR; CONST salt: ARRAY OF CHAR; saltLen: SIZE;
					CONST ikm: ARRAY OF CHAR; ikmLen: SIZE; CONST info: ARRAY OF CHAR; infoLen: SIZE;
					VAR okm: ARRAY OF CHAR; len: SIZE): BOOLEAN;
VAR prk: ARRAY MaxHash OF CHAR; prkLen: SIZE;
BEGIN
	prkLen := Extract(hashmod, salt, saltLen, ikm, ikmLen, prk);
	IF prkLen = 0 THEN RETURN FALSE END;
	RETURN Expand(hashmod, prk, prkLen, info, infoLen, okm, len)
END Derive;

END CryptoHKDF.
