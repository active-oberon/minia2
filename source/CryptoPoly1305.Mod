MODULE CryptoPoly1305;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "RFC 8439 Poly1305: a one-time authenticator";
	LIMITATIONS
		"- one key, one message. Poly1305 is not a MAC that may be keyed twice: authenticate two
		   messages with one key and the key can be recovered from the two tags. The key comes
		   from CryptoChaCha20 per message for exactly that reason;
		 - no verify procedure here: comparing tags is the caller's, and CryptoChaCha20.Open
		   does it in constant time."
*)
(*	The number is read out of the message sixteen bytes at a time, multiplied by r and reduced
	modulo 2^130 - 5. Neither the multiplication nor the reduction may branch on the data, so
	the accumulator is five limbs of twenty-six bits, the products fit a sixty-four bit word,
	and the carry always runs the same way whatever the message is. *)

CONST
	KeySize* = 32;		(** bytes: r and s *)
	TagSize* = 16;		(** bytes *)

TYPE
	Poly* = OBJECT
	VAR
		r: ARRAY 5 OF SIGNED64;			(* the multiplier, clamped *)
		h: ARRAY 5 OF SIGNED64;			(* the accumulator *)
		pad: ARRAY 4 OF SIGNED64;		(* s, added at the end *)
		leftover: ARRAY 16 OF CHAR;
		n: SIZE;

		PROCEDURE & Init*(CONST key: ARRAY OF CHAR);
		VAR t0, t1, t2, t3: SIGNED64; i: SIGNED32;
		BEGIN
			t0 := Get32(key, 0); t1 := Get32(key, 4); t2 := Get32(key, 8); t3 := Get32(key, 12);
			(*	Clamping: the standard clears twenty-two bits of r so that the products cannot
				overflow the limbs, and it is not optional. *)
			r[0] := t0 MOD 8000000H;
			r[1] := ((t0 DIV 4000000H) + (t1 * 40H)) MOD 4000000H;
			r[2] := ((t1 DIV 100000H) + (t2 * 1000H)) MOD 4000000H;
			r[3] := ((t2 DIV 4000H) + (t3 * 40000H)) MOD 4000000H;
			r[4] := (t3 DIV 100H) MOD 400000H;
			r[0] := SIGNED64(SET64(r[0]) * SET64(3FFFFFFH));
			r[1] := SIGNED64(SET64(r[1]) * SET64(3FFFF03H));
			r[2] := SIGNED64(SET64(r[2]) * SET64(3FFC0FFH));
			r[3] := SIGNED64(SET64(r[3]) * SET64(3F03FFFH));
			r[4] := SIGNED64(SET64(r[4]) * SET64(00FFFFFH));
			FOR i := 0 TO 4 DO h[i] := 0 END;
			FOR i := 0 TO 3 DO pad[i] := Get32(key, 16 + 4 * i) END;
			n := 0
		END Init;

		(*	One sixteen-byte block into the accumulator. final says the message ended here, in
			which case the implicit high bit is not added -- the padding byte took its place. *)
		PROCEDURE Block(CONST m: ARRAY OF CHAR; pos: SIZE; hibit: SIGNED64);
		VAR t0, t1, t2, t3: SIGNED64; d0, d1, d2, d3, d4, c: SIGNED64;
			h0, h1, h2, h3, h4: SIGNED64;
			r0, r1, r2, r3, r4, s1, s2, s3, s4: SIGNED64;
		BEGIN
			r0 := r[0]; r1 := r[1]; r2 := r[2]; r3 := r[3]; r4 := r[4];
			s1 := r1 * 5; s2 := r2 * 5; s3 := r3 * 5; s4 := r4 * 5;
			t0 := Get32(m, pos); t1 := Get32(m, pos + 4);
			t2 := Get32(m, pos + 8); t3 := Get32(m, pos + 12);
			h0 := h[0] + t0 MOD 4000000H;
			h1 := h[1] + ((t0 DIV 4000000H) + (t1 * 40H)) MOD 4000000H;
			h2 := h[2] + ((t1 DIV 100000H) + (t2 * 1000H)) MOD 4000000H;
			h3 := h[3] + ((t2 DIV 4000H) + (t3 * 40000H)) MOD 4000000H;
			h4 := h[4] + (t3 DIV 100H) + hibit;
			(* h := h * r mod 2^130 - 5, where the 5 folds the top limb back into the bottom *)
			d0 := h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
			d1 := h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
			d2 := h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
			d3 := h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
			d4 := h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
			c := d0 DIV 4000000H; h0 := d0 MOD 4000000H;
			d1 := d1 + c; c := d1 DIV 4000000H; h1 := d1 MOD 4000000H;
			d2 := d2 + c; c := d2 DIV 4000000H; h2 := d2 MOD 4000000H;
			d3 := d3 + c; c := d3 DIV 4000000H; h3 := d3 MOD 4000000H;
			d4 := d4 + c; c := d4 DIV 4000000H; h4 := d4 MOD 4000000H;
			h0 := h0 + c * 5; c := h0 DIV 4000000H; h0 := h0 MOD 4000000H;
			h1 := h1 + c;
			h[0] := h0; h[1] := h1; h[2] := h2; h[3] := h3; h[4] := h4
		END Block;

		(** More of the message. Any lengths; the blocks are gathered here. *)
		PROCEDURE Update*(CONST m: ARRAY OF CHAR; pos, len: SIZE);
		VAR i: SIZE;
		BEGIN
			WHILE len > 0 DO
				IF (n = 0) & (len >= 16) THEN
					SELF.Block(m, pos, 1000000H);
					INC(pos, 16); DEC(len, 16)
				ELSE
					leftover[n] := m[pos]; INC(n); INC(pos); DEC(len);
					IF n = 16 THEN
						SELF.Block(leftover, 0, 1000000H); n := 0
					END
				END
			END;
			i := 0
		END Update;

		(** The tag. The object is spent afterwards. *)
		PROCEDURE GetTag*(VAR tag: ARRAY OF CHAR; pos: SIZE);
		VAR g0, g1, g2, g3, g4, c, mask: SIGNED64; f: SIGNED64; i: SIZE;
			h0, h1, h2, h3, h4: SIGNED64;
		BEGIN
			IF n > 0 THEN
				leftover[n] := 1X; INC(n);
				WHILE n < 16 DO leftover[n] := 0X; INC(n) END;
				SELF.Block(leftover, 0, 0);		(* the 1 byte above is the high bit for this block *)
				n := 0
			END;
			h0 := h[0]; h1 := h[1]; h2 := h[2]; h3 := h[3]; h4 := h[4];
			c := h1 DIV 4000000H; h1 := h1 MOD 4000000H;
			h2 := h2 + c; c := h2 DIV 4000000H; h2 := h2 MOD 4000000H;
			h3 := h3 + c; c := h3 DIV 4000000H; h3 := h3 MOD 4000000H;
			h4 := h4 + c; c := h4 DIV 4000000H; h4 := h4 MOD 4000000H;
			h0 := h0 + c * 5; c := h0 DIV 4000000H; h0 := h0 MOD 4000000H;
			h1 := h1 + c;
			(* h - (2^130 - 5), kept only if it did not borrow -- and chosen without branching *)
			g0 := h0 + 5; c := g0 DIV 4000000H; g0 := g0 MOD 4000000H;
			g1 := h1 + c; c := g1 DIV 4000000H; g1 := g1 MOD 4000000H;
			g2 := h2 + c; c := g2 DIV 4000000H; g2 := g2 MOD 4000000H;
			g3 := h3 + c; c := g3 DIV 4000000H; g3 := g3 MOD 4000000H;
			g4 := h4 + c - 4000000H;
			(*	g4 went negative exactly when h was already below the prime, so the subtraction
				must be thrown away. Which of the two is kept is chosen by a mask and not by an
				IF: the branch would take a different time for a message that happened to reach
				the prime, and the tag is a secret. *)
			mask := SIGNED64(LSH(SET64(g4), -63));		(* 1 when g4 is negative, 0 when it is not *)
			mask := -mask;								(* all ones: keep h *)
			h0 := SIGNED64((SET64(h0) * SET64(mask)) + (SET64(g0) * (-SET64(mask))));
			h1 := SIGNED64((SET64(h1) * SET64(mask)) + (SET64(g1) * (-SET64(mask))));
			h2 := SIGNED64((SET64(h2) * SET64(mask)) + (SET64(g2) * (-SET64(mask))));
			h3 := SIGNED64((SET64(h3) * SET64(mask)) + (SET64(g3) * (-SET64(mask))));
			h4 := SIGNED64((SET64(h4) * SET64(mask)) + (SET64(g4) * (-SET64(mask))));
			(* back to four thirty-two bit words, then add s *)
			h0 := (h0 + h1 * 4000000H) MOD 100000000H;
			h1 := ((h1 DIV 40H) + h2 * 100000H) MOD 100000000H;
			h2 := ((h2 DIV 1000H) + h3 * 4000H) MOD 100000000H;
			h3 := ((h3 DIV 40000H) + h4 * 100H) MOD 100000000H;
			f := h0 + pad[0]; h0 := f MOD 100000000H;
			f := h1 + pad[1] + f DIV 100000000H; h1 := f MOD 100000000H;
			f := h2 + pad[2] + f DIV 100000000H; h2 := f MOD 100000000H;
			f := h3 + pad[3] + f DIV 100000000H; h3 := f MOD 100000000H;
			Put32(h0, tag, pos); Put32(h1, tag, pos + 4);
			Put32(h2, tag, pos + 8); Put32(h3, tag, pos + 12);
			i := 0
		END GetTag;

	END Poly;

(*	Shifted into a SET64 rather than added up with multipliers. The arithmetic version is not
	merely uglier, it is wrong: ORD of a CHAR is a small type, so 100H * ORD(c) is multiplied in
	sixteen bits and wraps -- see the case in tests/Numbers.Test. It cost the Poly1305 key two
	wrong bytes and an afternoon. *)
PROCEDURE Get32(CONST b: ARRAY OF CHAR; pos: SIZE): SIGNED64;
VAR v: SET64; i: SIGNED32;
BEGIN
	v := {};
	FOR i := 3 TO 0 BY -1 DO
		v := LSH(v, 8) + SET64(ORD(b[pos + i]))
	END;
	RETURN SIGNED64(v)
END Get32;

PROCEDURE Put32(v: SIGNED64; VAR b: ARRAY OF CHAR; pos: SIZE);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 3 DO
		b[pos + i] := CHR(SIGNED32(v MOD 100H));
		v := v DIV 100H
	END
END Put32;

(** The tag of one message under one key, which is all Poly1305 may ever be asked. *)
PROCEDURE Mac*(CONST key: ARRAY OF CHAR; CONST m: ARRAY OF CHAR; len: SIZE; VAR tag: ARRAY OF CHAR);
VAR p: Poly;
BEGIN
	NEW(p, key);
	p.Update(m, 0, len);
	p.GetTag(tag, 0)
END Mac;

END CryptoPoly1305.
