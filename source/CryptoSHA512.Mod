MODULE CryptoSHA512;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "SHA2-512, the hash Ed25519 signs with and the library did not have";
	LIMITATIONS
		"- SHA-384 is this core with another initial value and a shorter answer, and is not here
		   because nothing asks for it yet;
		 - the length field is 128 bits in the standard and 64 here: a message of two exabytes
		   would be hashed wrongly, and there is no such message."
*)
(*	The shape is CryptoSHA256's -- a Hashes.Hash so that CryptoHMAC and Checksum can ask for it
	by name -- and the arithmetic is the same with sixty-four bit words: eighty rounds instead of
	sixty-four, other rotation distances, and a block twice as long. *)

IMPORT Hashes := CryptoHashes;

CONST
	BlockSize* = 128;	(** bytes per block *)
	HashSize* = 64;		(** bytes of hash *)

VAR
	K: ARRAY 80 OF SIGNED64;	(* cube roots of the first eighty primes *)

TYPE
	Hash* = OBJECT (Hashes.Hash)
	VAR
		state: ARRAY 8 OF SIGNED64;
		bytes: SIGNED64;			(* how much has been hashed, for the length field *)
		pending: ARRAY BlockSize OF CHAR;
		n: SIZE;					(* bytes in pending *)

		PROCEDURE &Init*;
		BEGIN
			SetNameAndSize("sha2-512", HashSize);
			SetBlockSize(BlockSize);		(* 128, not the 64 every earlier hash has *)
			initialized := FALSE
		END Init;

		PROCEDURE Initialize*;
		BEGIN
			state[0] := SIGNED64(6A09E667F3BCC908H);
			state[1] := SIGNED64(0BB67AE8584CAA73BH);
			state[2] := SIGNED64(3C6EF372FE94F82BH);
			state[3] := SIGNED64(0A54FF53A5F1D36F1H);
			state[4] := SIGNED64(510E527FADE682D1H);
			state[5] := SIGNED64(9B05688C2B3E6C1FH);
			state[6] := SIGNED64(1F83D9ABFB41BD6BH);
			state[7] := SIGNED64(5BE0CD19137E2179H);
			bytes := 0; n := 0; initialized := TRUE
		END Initialize;

		PROCEDURE Block(CONST data: ARRAY OF CHAR; pos: SIZE);
		VAR a, b, c, d, e, f, g, h, t1, t2: SIGNED64; w: ARRAY 80 OF SIGNED64; i: SIGNED32;
		BEGIN
			FOR i := 0 TO 15 DO w[i] := Get64(data, pos + 8 * i) END;
			FOR i := 16 TO 79 DO
				w[i] := sigma1(w[i - 2]) + w[i - 7] + sigma0(w[i - 15]) + w[i - 16]
			END;
			a := state[0]; b := state[1]; c := state[2]; d := state[3];
			e := state[4]; f := state[5]; g := state[6]; h := state[7];
			FOR i := 0 TO 79 DO
				t1 := h + Sigma1(e) + Ch(e, f, g) + K[i] + w[i];
				t2 := Sigma0(a) + Maj(a, b, c);
				h := g; g := f; f := e; e := d + t1;
				d := c; c := b; b := a; a := t1 + t2
			END;
			INC(state[0], a); INC(state[1], b); INC(state[2], c); INC(state[3], d);
			INC(state[4], e); INC(state[5], f); INC(state[6], g); INC(state[7], h)
		END Block;

		PROCEDURE Update*(CONST data: ARRAY OF CHAR; pos, len: SIZE);
		BEGIN
			ASSERT(initialized);
			INC(bytes, len);
			WHILE len > 0 DO
				pending[n] := data[pos]; INC(n); INC(pos); DEC(len);
				IF n = BlockSize THEN SELF.Block(pending, 0); n := 0 END
			END
		END Update;

		PROCEDURE GetHash*(VAR buf: ARRAY OF CHAR; pos: SIZE);
		VAR bits: SIGNED64; i: SIGNED32;
		BEGIN
			bits := bytes * 8;
			pending[n] := 80X; INC(n);
			IF n > BlockSize - 16 THEN
				WHILE n < BlockSize DO pending[n] := 0X; INC(n) END;
				SELF.Block(pending, 0); n := 0
			END;
			WHILE n < BlockSize - 8 DO pending[n] := 0X; INC(n) END;
			Put64(bits, pending, BlockSize - 8);	(* the high half of the length is the zeroes above *)
			SELF.Block(pending, 0); n := 0;
			FOR i := 0 TO 7 DO Put64(state[i], buf, pos + 8 * i) END
		END GetHash;

	END Hash;

(** an instance, for CryptoHashes.NewHash("CryptoSHA512") and for callers that name the module *)
PROCEDURE NewHash*(): Hashes.Hash;
VAR h: Hash;
BEGIN
	NEW(h);
	RETURN h
END NewHash;

PROCEDURE Get64(CONST b: ARRAY OF CHAR; pos: SIZE): SIGNED64;
VAR v: SIGNED64; i: SIGNED32;
BEGIN
	v := 0;
	FOR i := 0 TO 7 DO v := SIGNED64(LSH(SET64(v), 8)) + ORD(b[pos + i]) END;
	RETURN v
END Get64;

PROCEDURE Put64(v: SIGNED64; VAR b: ARRAY OF CHAR; pos: SIZE);
VAR i: SIGNED32;
BEGIN
	FOR i := 7 TO 0 BY -1 DO
		b[pos + i] := CHR(SIGNED32(SIGNED64(SET64(v) * SET64(0FFH))));
		v := SIGNED64(LSH(SET64(v), -8))
	END
END Put64;

(*	The four functions of the standard, written the way CryptoSHA256 writes its four: on SET64,
	where ROT is a rotation to the left, so a rotation right by k is a rotation left by 64 - k. *)
PROCEDURE -Ch(x, y, z: SIGNED64): SIGNED64;
BEGIN
	RETURN SIGNED64((SET64(x) * SET64(y)) / ((-SET64(x)) * SET64(z)))
END Ch;

PROCEDURE -Maj(x, y, z: SIGNED64): SIGNED64;
BEGIN
	RETURN SIGNED64((SET64(x) * SET64(y)) / (SET64(x) * SET64(z)) / (SET64(y) * SET64(z)))
END Maj;

PROCEDURE -Sigma0(x: SIGNED64): SIGNED64;
BEGIN
	RETURN SIGNED64(ROT(SET64(x), 36) / ROT(SET64(x), 30) / ROT(SET64(x), 25))
END Sigma0;

PROCEDURE -Sigma1(x: SIGNED64): SIGNED64;
BEGIN
	RETURN SIGNED64(ROT(SET64(x), 50) / ROT(SET64(x), 46) / ROT(SET64(x), 23))
END Sigma1;

PROCEDURE -sigma0(x: SIGNED64): SIGNED64;
BEGIN
	RETURN SIGNED64(ROT(SET64(x), 63) / ROT(SET64(x), 56) / LSH(SET64(x), -7))
END sigma0;

PROCEDURE -sigma1(x: SIGNED64): SIGNED64;
BEGIN
	RETURN SIGNED64(ROT(SET64(x), 45) / ROT(SET64(x), 3) / LSH(SET64(x), -6))
END sigma1;

PROCEDURE InitK;
BEGIN
	K[0] := SIGNED64(428A2F98D728AE22H); K[1] := SIGNED64(7137449123EF65CDH);
	K[2] := SIGNED64(0B5C0FBCFEC4D3B2FH); K[3] := SIGNED64(0E9B5DBA58189DBBCH);
	K[4] := SIGNED64(3956C25BF348B538H); K[5] := SIGNED64(59F111F1B605D019H);
	K[6] := SIGNED64(923F82A4AF194F9BH); K[7] := SIGNED64(0AB1C5ED5DA6D8118H);
	K[8] := SIGNED64(0D807AA98A3030242H); K[9] := SIGNED64(12835B0145706FBEH);
	K[10] := SIGNED64(243185BE4EE4B28CH); K[11] := SIGNED64(550C7DC3D5FFB4E2H);
	K[12] := SIGNED64(72BE5D74F27B896FH); K[13] := SIGNED64(80DEB1FE3B1696B1H);
	K[14] := SIGNED64(9BDC06A725C71235H); K[15] := SIGNED64(0C19BF174CF692694H);
	K[16] := SIGNED64(0E49B69C19EF14AD2H); K[17] := SIGNED64(0EFBE4786384F25E3H);
	K[18] := SIGNED64(0FC19DC68B8CD5B5H); K[19] := SIGNED64(240CA1CC77AC9C65H);
	K[20] := SIGNED64(2DE92C6F592B0275H); K[21] := SIGNED64(4A7484AA6EA6E483H);
	K[22] := SIGNED64(5CB0A9DCBD41FBD4H); K[23] := SIGNED64(76F988DA831153B5H);
	K[24] := SIGNED64(983E5152EE66DFABH); K[25] := SIGNED64(0A831C66D2DB43210H);
	K[26] := SIGNED64(0B00327C898FB213FH); K[27] := SIGNED64(0BF597FC7BEEF0EE4H);
	K[28] := SIGNED64(0C6E00BF33DA88FC2H); K[29] := SIGNED64(0D5A79147930AA725H);
	K[30] := SIGNED64(6CA6351E003826FH); K[31] := SIGNED64(142929670A0E6E70H);
	K[32] := SIGNED64(27B70A8546D22FFCH); K[33] := SIGNED64(2E1B21385C26C926H);
	K[34] := SIGNED64(4D2C6DFC5AC42AEDH); K[35] := SIGNED64(53380D139D95B3DFH);
	K[36] := SIGNED64(650A73548BAF63DEH); K[37] := SIGNED64(766A0ABB3C77B2A8H);
	K[38] := SIGNED64(81C2C92E47EDAEE6H); K[39] := SIGNED64(92722C851482353BH);
	K[40] := SIGNED64(0A2BFE8A14CF10364H); K[41] := SIGNED64(0A81A664BBC423001H);
	K[42] := SIGNED64(0C24B8B70D0F89791H); K[43] := SIGNED64(0C76C51A30654BE30H);
	K[44] := SIGNED64(0D192E819D6EF5218H); K[45] := SIGNED64(0D69906245565A910H);
	K[46] := SIGNED64(0F40E35855771202AH); K[47] := SIGNED64(106AA07032BBD1B8H);
	K[48] := SIGNED64(19A4C116B8D2D0C8H); K[49] := SIGNED64(1E376C085141AB53H);
	K[50] := SIGNED64(2748774CDF8EEB99H); K[51] := SIGNED64(34B0BCB5E19B48A8H);
	K[52] := SIGNED64(391C0CB3C5C95A63H); K[53] := SIGNED64(4ED8AA4AE3418ACBH);
	K[54] := SIGNED64(5B9CCA4F7763E373H); K[55] := SIGNED64(682E6FF3D6B2B8A3H);
	K[56] := SIGNED64(748F82EE5DEFB2FCH); K[57] := SIGNED64(78A5636F43172F60H);
	K[58] := SIGNED64(84C87814A1F0AB72H); K[59] := SIGNED64(8CC702081A6439ECH);
	K[60] := SIGNED64(90BEFFFA23631E28H); K[61] := SIGNED64(0A4506CEBDE82BDE9H);
	K[62] := SIGNED64(0BEF9A3F7B2C67915H); K[63] := SIGNED64(0C67178F2E372532BH);
	K[64] := SIGNED64(0CA273ECEEA26619CH); K[65] := SIGNED64(0D186B8C721C0C207H);
	K[66] := SIGNED64(0EADA7DD6CDE0EB1EH); K[67] := SIGNED64(0F57D4F7FEE6ED178H);
	K[68] := SIGNED64(6F067AA72176FBAH); K[69] := SIGNED64(0A637DC5A2C898A6H);
	K[70] := SIGNED64(113F9804BEF90DAEH); K[71] := SIGNED64(1B710B35131C471BH);
	K[72] := SIGNED64(28DB77F523047D84H); K[73] := SIGNED64(32CAAB7B40C72493H);
	K[74] := SIGNED64(3C9EBE0A15C9BEBCH); K[75] := SIGNED64(431D67C49C100D4CH);
	K[76] := SIGNED64(4CC5D4BECB3E42B6H); K[77] := SIGNED64(597F299CFC657E2AH);
	K[78] := SIGNED64(5FCB6FAB3AD6FAECH); K[79] := SIGNED64(6C44198C4A475817H);
END InitK;

BEGIN
	InitK
END CryptoSHA512.
