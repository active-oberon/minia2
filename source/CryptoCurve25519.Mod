MODULE CryptoCurve25519;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "RFC 7748 X25519: the key agreement ob get would verify a download with";
	LIMITATIONS
		"- constant time by construction and not by measurement: the ladder swaps with a mask,
		   the field never branches on a limb, and nothing indexes memory by a secret -- but
		   nobody outside this tree has looked at it with a timer;
		 - no check that the peer's public key is not one of the small-order points. RFC 7748
		   says an all-zero shared secret may be rejected and ScalarMult reports it, so the
		   caller can;
		 - the inverse is computed by squaring through the whole exponent rather than by the
		   eleven-multiplication chain: about a fifth slower on the whole operation, and short
		   enough to read."
*)
(*	The field lives here and CryptoEd25519 borrows it: the curves are different, the field is
	the same one, and a second copy of a hundred generated product terms would be a second copy
	of every mistake in them.

	The field is GF(2^255 - 19) in ten limbs of alternating 26 and 25 bits, which is what the
	arithmetic wants on a machine with no 128-bit product: every limb product fits a SIGNED64
	with room for the nineteen-fold reduction and the sum of ten of them. The multiplication
	below is generated rather than typed -- a hundred terms is a hundred chances to transpose
	an index -- and checked against the vectors of RFC 7748, including the one that iterates a
	thousand times, which is what catches a carry that is wrong once in a while. *)

IMPORT CryptoUtils;

CONST
	KeySize* = 32;		(** bytes, both scalar and point *)

TYPE
	(** a field element: ten limbs, alternating 26 and 25 bits *)
	Element* = ARRAY 10 OF SIGNED64;

PROCEDURE Zero*(VAR h: Element);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 9 DO h[i] := 0 END
END Zero;

PROCEDURE One*(VAR h: Element);
BEGIN
	Zero(h); h[0] := 1
END One;

PROCEDURE Copy*(VAR h: Element; CONST f: Element);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 9 DO h[i] := f[i] END
END Copy;

PROCEDURE Add*(VAR h: Element; CONST f, g: Element);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 9 DO h[i] := f[i] + g[i] END
END Add;

PROCEDURE Sub*(VAR h: Element; CONST f, g: Element);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 9 DO h[i] := f[i] - g[i] END
END Sub;

(*	The carry chain after a product: limb k keeps 26 bits when k is even and 25 when it is odd,
	and what leaves limb 9 comes back into limb 0 multiplied by 19, which is the reduction. The
	shift is arithmetic on purpose -- a limb may be negative after Sub. *)
PROCEDURE Carry*(VAR h: Element);
VAR c: SIGNED64; i: SIGNED32;
BEGIN
	FOR i := 0 TO 9 DO
		IF ODD(i) THEN
			c := Floor(h[i], 25);
			h[i] := h[i] - c * 2000000H;			(* 2^25 *)
		ELSE
			c := Floor(h[i], 26);
			h[i] := h[i] - c * 4000000H				(* 2^26 *)
		END;
		IF i < 9 THEN h[i + 1] := h[i + 1] + c ELSE h[0] := h[0] + 19 * c END
	END;
	(* one more pass on limb 0, which the 19 above may have pushed over *)
	c := Floor(h[0], 26);
	h[0] := h[0] - c * 4000000H;
	h[1] := h[1] + c
END Carry;

(*	x divided by 2^bits, rounded towards minus infinity. DIV already floors in this language,
	which is exactly what a signed limb needs and what a C shift would have had to spell out. *)
PROCEDURE Floor(x: SIGNED64; bits: SIGNED32): SIGNED64;
VAR d: SIGNED64; i: SIGNED32;
BEGIN
	d := 1;
	FOR i := 1 TO bits DO d := d * 2 END;
	RETURN x DIV d
END Floor;

PROCEDURE Mul*(VAR h: Element; CONST f, g: Element);
VAR t: Element;
BEGIN
	t[0] := f[0] * g[0] + 38 * f[1] * g[9] + 19 * f[2] * g[8] + 38 * f[3] * g[7]
		+ 19 * f[4] * g[6] + 38 * f[5] * g[5] + 19 * f[6] * g[4] + 38 * f[7] * g[3]
		+ 19 * f[8] * g[2] + 38 * f[9] * g[1];
	t[1] := f[0] * g[1] + f[1] * g[0] + 19 * f[2] * g[9] + 19 * f[3] * g[8] + 19 * f[4] * g[7]
		+ 19 * f[5] * g[6] + 19 * f[6] * g[5] + 19 * f[7] * g[4] + 19 * f[8] * g[3]
		+ 19 * f[9] * g[2];
	t[2] := f[0] * g[2] + 2 * f[1] * g[1] + f[2] * g[0] + 38 * f[3] * g[9] + 19 * f[4] * g[8]
		+ 38 * f[5] * g[7] + 19 * f[6] * g[6] + 38 * f[7] * g[5] + 19 * f[8] * g[4]
		+ 38 * f[9] * g[3];
	t[3] := f[0] * g[3] + f[1] * g[2] + f[2] * g[1] + f[3] * g[0] + 19 * f[4] * g[9]
		+ 19 * f[5] * g[8] + 19 * f[6] * g[7] + 19 * f[7] * g[6] + 19 * f[8] * g[5]
		+ 19 * f[9] * g[4];
	t[4] := f[0] * g[4] + 2 * f[1] * g[3] + f[2] * g[2] + 2 * f[3] * g[1] + f[4] * g[0]
		+ 38 * f[5] * g[9] + 19 * f[6] * g[8] + 38 * f[7] * g[7] + 19 * f[8] * g[6]
		+ 38 * f[9] * g[5];
	t[5] := f[0] * g[5] + f[1] * g[4] + f[2] * g[3] + f[3] * g[2] + f[4] * g[1] + f[5] * g[0]
		+ 19 * f[6] * g[9] + 19 * f[7] * g[8] + 19 * f[8] * g[7] + 19 * f[9] * g[6];
	t[6] := f[0] * g[6] + 2 * f[1] * g[5] + f[2] * g[4] + 2 * f[3] * g[3] + f[4] * g[2]
		+ 2 * f[5] * g[1] + f[6] * g[0] + 38 * f[7] * g[9] + 19 * f[8] * g[8] + 38 * f[9] * g[7];
	t[7] := f[0] * g[7] + f[1] * g[6] + f[2] * g[5] + f[3] * g[4] + f[4] * g[3] + f[5] * g[2]
		+ f[6] * g[1] + f[7] * g[0] + 19 * f[8] * g[9] + 19 * f[9] * g[8];
	t[8] := f[0] * g[8] + 2 * f[1] * g[7] + f[2] * g[6] + 2 * f[3] * g[5] + f[4] * g[4]
		+ 2 * f[5] * g[3] + f[6] * g[2] + 2 * f[7] * g[1] + f[8] * g[0] + 38 * f[9] * g[9];
	t[9] := f[0] * g[9] + f[1] * g[8] + f[2] * g[7] + f[3] * g[6] + f[4] * g[5] + f[5] * g[4]
		+ f[6] * g[3] + f[7] * g[2] + f[8] * g[1] + f[9] * g[0];
	Copy(h, t); Carry(h); Carry(h)
END Mul;

PROCEDURE Square*(VAR h: Element; CONST f: Element);
BEGIN
	Mul(h, f, f)		(* ponytail: the dedicated squaring is a third faster and twice the code *)
END Square;

PROCEDURE Mul121666(VAR h: Element; CONST f: Element);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 9 DO h[i] := f[i] * 121666 END;
	Carry(h)
END Mul121666;

(*	Swap f and g when swap is 1, leave them when it is 0, and take the same time either way:
	this is the one place in the ladder that a branch would leak a bit of the scalar. *)
PROCEDURE CSwap(VAR f, g: Element; swap: SIGNED64);
VAR mask, t: SIGNED64; i: SIGNED32;
BEGIN
	mask := -swap;
	FOR i := 0 TO 9 DO
		t := SIGNED64(SET64(mask) * (SET64(f[i]) / SET64(g[i])));
		f[i] := SIGNED64(SET64(f[i]) / SET64(t));
		g[i] := SIGNED64(SET64(g[i]) / SET64(t))
	END
END CSwap;

(** the inverse in the field, by squaring through 2^255 - 21 *)
PROCEDURE Invert*(VAR out: Element; CONST z: Element);
VAR t, acc: Element; i: SIGNED32;
BEGIN
	(*	p - 2 is 2^255 - 21: every bit set except bits 2 and 4. Square-and-multiply from the
		top costs 254 squarings and 252 multiplications, and the exponent is public. *)
	Copy(acc, z);
	FOR i := 253 TO 0 BY -1 DO
		Square(t, acc); Copy(acc, t);
		IF (i # 2) & (i # 4) THEN Mul(t, acc, z); Copy(acc, t) END
	END;
	Copy(out, acc)
END Invert;

(** a point or a scalar out of its thirty-two bytes, little endian, top bit dropped *)
PROCEDURE FromBytes*(VAR h: Element; CONST b: ARRAY OF CHAR);
VAR w: ARRAY 32 OF SIGNED64; i: SIGNED32; v: SIGNED64;

	PROCEDURE Bits(from, n: SIGNED32): SIGNED64;
	VAR k, r: SIGNED32; acc: SIGNED64; bit: SIGNED64;
	BEGIN
		acc := 0;
		FOR k := n - 1 TO 0 BY -1 DO
			r := from + k;
			bit := (w[r DIV 8] DIV Pow2(r MOD 8)) MOD 2;
			acc := acc * 2 + bit
		END;
		RETURN acc
	END Bits;

BEGIN
	FOR i := 0 TO 31 DO w[i] := ORD(b[i]) END;
	w[31] := w[31] MOD 80H;					(* the standard ignores the top bit of a u coordinate *)
	v := 0; i := 0;
	h[0] := Bits(0, 26); h[1] := Bits(26, 25); h[2] := Bits(51, 26); h[3] := Bits(77, 25);
	h[4] := Bits(102, 26); h[5] := Bits(128, 25); h[6] := Bits(153, 26); h[7] := Bits(179, 25);
	h[8] := Bits(204, 26); h[9] := Bits(230, 25)
END FromBytes;

PROCEDURE Pow2*(n: SIGNED32): SIGNED64;
VAR d: SIGNED64; i: SIGNED32;
BEGIN
	d := 1;
	FOR i := 1 TO n DO d := d * 2 END;
	RETURN d
END Pow2;

(*	The thirty-two bytes of an element, fully reduced -- which is the part it is easy to get
	nearly right: an element that is exactly the prime has to come out as zero, and the first
	version of this did not, so a point whose square root needed the negative branch looked like
	a point that had no square root at all. The guess q below is ref10's: it is 1 exactly when
	the value is at least p, and adding 19*q then dropping the bit at 2^255 subtracts it. *)
PROCEDURE ToBytes*(VAR b: ARRAY OF CHAR; CONST f: Element);
VAR h: Element; q, c: SIGNED64; i, k: SIGNED32; bit: SIGNED32; out: ARRAY 32 OF SIGNED64;
BEGIN
	Copy(h, f); Carry(h); Carry(h); Carry(h);
	q := Floor(19 * h[9] + 1000000H, 25);
	FOR i := 0 TO 9 DO
		IF ODD(i) THEN q := Floor(h[i] + q, 25) ELSE q := Floor(h[i] + q, 26) END
	END;
	h[0] := h[0] + 19 * q;
	c := 0;
	FOR i := 0 TO 9 DO
		h[i] := h[i] + c;
		IF ODD(i) THEN c := Floor(h[i], 25); h[i] := h[i] - c * 2000000H
		ELSE c := Floor(h[i], 26); h[i] := h[i] - c * 4000000H
		END
	END;
	(* what left limb 9 is the 2^255 that the subtraction above removed *)
	FOR i := 0 TO 31 DO out[i] := 0 END;
	k := 0;
	FOR i := 0 TO 9 DO
		FOR bit := 0 TO Width(i) - 1 DO
			IF (h[i] DIV Pow2(bit)) MOD 2 = 1 THEN
				out[k DIV 8] := out[k DIV 8] + Pow2(k MOD 8)
			END;
			INC(k)
		END
	END;
	FOR i := 0 TO 31 DO b[i] := CHR(SIGNED32(out[i] MOD 100H)) END
END ToBytes;

PROCEDURE Width(i: SIGNED32): SIGNED32;
BEGIN
	IF ODD(i) THEN RETURN 25 ELSE RETURN 26 END
END Width;

(*	The Montgomery ladder of RFC 7748 section 5: two points kept, one bit of the scalar per
	round, and which of the two is which decided by a swap that does not branch. *)
PROCEDURE ScalarMult*(CONST scalar: ARRAY OF CHAR; CONST point: ARRAY OF CHAR;
						VAR out: ARRAY OF CHAR): BOOLEAN;
VAR k: ARRAY 32 OF SIGNED64;
	x1, x2, z2, x3, z3, a, b, c, d, e, aa, bb, da, cb, t: Element;
	i, pos: SIGNED32; swap, bit: SIGNED64; zero: BOOLEAN;
BEGIN
	FOR i := 0 TO 31 DO k[i] := ORD(scalar[i]) END;
	(* clamping: the standard says the scalar is a multiple of 8 with a fixed top bit *)
	k[0] := SIGNED64(SET64(k[0]) * SET64(0F8H));
	k[31] := SIGNED64(SET64(k[31]) * SET64(7FH));
	k[31] := SIGNED64(SET64(k[31]) + SET64(40H));

	FromBytes(x1, point);
	One(x2); Zero(z2); Copy(x3, x1); One(z3);
	swap := 0;
	FOR pos := 254 TO 0 BY -1 DO
		bit := (k[pos DIV 8] DIV Pow2(pos MOD 8)) MOD 2;
		swap := SIGNED64(SET64(swap) / SET64(bit));
		CSwap(x2, x3, swap); CSwap(z2, z3, swap);
		swap := bit;

		Sub(a, x2, z2); Square(aa, a);
		Add(b, x2, z2); Square(bb, b);
		Sub(e, bb, aa);
		Add(c, x3, z3); Sub(d, x3, z3);
		Mul(da, d, b); Mul(cb, c, a);
		Add(t, da, cb); Square(x3, t);
		Sub(t, da, cb); Square(z3, t); Mul(t, z3, x1); Copy(z3, t);
		Mul(x2, aa, bb);
		Mul121666(t, e); Add(t, t, aa); Mul(z2, e, t)
	END;
	CSwap(x2, x3, swap); CSwap(z2, z3, swap);
	Invert(t, z2);
	Mul(x2, x2, t);
	ToBytes(out, x2);
	(*	An all-zero result means the peer sent a point of small order and the secret is not one.
		RFC 7748 leaves rejecting it to the protocol, so it is reported and not enforced. *)
	zero := TRUE;
	FOR i := 0 TO 31 DO IF out[i] # 0X THEN zero := FALSE END END;
	RETURN ~zero
END ScalarMult;

(** the public key of a secret: the scalar times the base point, u = 9 *)
PROCEDURE Public*(CONST secret: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): BOOLEAN;
VAR base: ARRAY 32 OF CHAR; i: SIGNED32;
BEGIN
	FOR i := 0 TO 31 DO base[i] := 0X END;
	base[0] := 09X;
	RETURN ScalarMult(secret, base, out)
END Public;

END CryptoCurve25519.
