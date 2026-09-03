MODULE CryptoEd25519;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "RFC 8032 Ed25519: sign a release, and check the signature on a download";
	LIMITATIONS
		"- constant time by construction and not by measurement, the same caveat CryptoCurve25519
		   carries: the scalar multiplication always adds and selects with a mask, the field
		   never branches on a limb, and nobody outside this tree has looked at it with a timer;
		 - Verify is deliberately not constant time -- everything it touches is public;
		 - no Ed25519ph and no context strings: this is the plain scheme of section 5.1;
		 - a signature is accepted if the equation holds, including for the small-order public
		   keys the standard permits; a protocol that cares must refuse those itself."
*)
(*	The field, and every operation on it, is CryptoCurve25519's -- same prime, same limbs. What
	is here is the group: the twisted Edwards curve in extended coordinates, the reduction of a
	scalar modulo the group order, and the two procedures a caller wants.

	Scalars are reduced by long division rather than by the generated limb arithmetic every C
	implementation uses: two hundred and fifty six conditional subtractions of a shifted order,
	each of them taken whatever the bits say. It is a few thousand operations against a quarter
	of a million in the point multiplication beside it, so the cost does not show, and it is
	short enough to be read for correctness rather than trusted. *)

IMPORT F := CryptoCurve25519, CryptoSHA512;

CONST
	KeySize* = 32;			(** bytes of secret key, and of public key *)
	SignatureSize* = 64;	(** bytes *)

TYPE
	Element = F.Element;
	(** a point in extended coordinates: x = X/Z, y = Y/Z, and T = XY/Z *)
	Point = RECORD x, y, z, t: Element END;
	Scalar = ARRAY 32 OF SIGNED32;		(* little endian, one byte a limb, for the reduction *)

VAR
	d, d2, sqrtm1: Element;		(* the curve constant, twice it, and a square root of -1 *)
	base: Point;
	order: ARRAY 33 OF SIGNED32;	(* L, little endian bytes *)

PROCEDURE Set(VAR e: Element; a, b, c, dd, ee, ff, gg, hh, ii, jj: SIGNED64);
BEGIN
	e[0] := a; e[1] := b; e[2] := c; e[3] := dd; e[4] := ee;
	e[5] := ff; e[6] := gg; e[7] := hh; e[8] := ii; e[9] := jj
END Set;

PROCEDURE Neutral(VAR p: Point);
BEGIN
	F.Zero(p.x); F.One(p.y); F.One(p.z); F.Zero(p.t)
END Neutral;

PROCEDURE CopyPoint(VAR p: Point; CONST q: Point);
BEGIN
	F.Copy(p.x, q.x); F.Copy(p.y, q.y); F.Copy(p.z, q.z); F.Copy(p.t, q.t)
END CopyPoint;

(*	The unified addition of RFC 8032 section 5.1.4, which is also the doubling: on a twisted
	Edwards curve one formula serves both, and taking the cheaper doubling would be a second
	formula to get right for no time that anybody measures here. *)
PROCEDURE AddPoints(VAR r: Point; CONST p, q: Point);
VAR a, b, c, e, f, g, h, t1, t2: Element;
BEGIN
	F.Sub(t1, p.y, p.x); F.Sub(t2, q.y, q.x); F.Mul(a, t1, t2);
	F.Add(t1, p.y, p.x); F.Add(t2, q.y, q.x); F.Mul(b, t1, t2);
	F.Mul(t1, p.t, q.t); F.Mul(c, t1, d2);
	F.Mul(t1, p.z, q.z); F.Add(e, t1, t1);			(* D = 2 Z1 Z2 *)
	F.Sub(f, e, c); F.Add(g, e, c);
	F.Sub(e, b, a); F.Add(h, b, a);
	F.Mul(r.x, e, f); F.Mul(r.y, g, h); F.Mul(r.t, e, h); F.Mul(r.z, f, g)
END AddPoints;

(** keep p when take is 0 and take q when it is 1, in the same time either way *)
PROCEDURE Select(VAR p: Point; CONST q: Point; take: SIGNED64);
VAR mask, t: SIGNED64; i: SIGNED32;
BEGIN
	mask := -take;
	FOR i := 0 TO 9 DO
		t := SIGNED64(SET64(mask) * (SET64(p.x[i]) / SET64(q.x[i]))); p.x[i] := SIGNED64(SET64(p.x[i]) / SET64(t));
		t := SIGNED64(SET64(mask) * (SET64(p.y[i]) / SET64(q.y[i]))); p.y[i] := SIGNED64(SET64(p.y[i]) / SET64(t));
		t := SIGNED64(SET64(mask) * (SET64(p.z[i]) / SET64(q.z[i]))); p.z[i] := SIGNED64(SET64(p.z[i]) / SET64(t));
		t := SIGNED64(SET64(mask) * (SET64(p.t[i]) / SET64(q.t[i]))); p.t[i] := SIGNED64(SET64(p.t[i]) / SET64(t))
	END
END Select;

(*	Always double, always add, and then choose: the addition happens whether the bit is set or
	not, so the time says nothing about the scalar. *)
PROCEDURE MultiplyPoint(VAR r: Point; CONST k: Scalar; CONST p: Point; constantTime: BOOLEAN);
VAR acc, doubled, sum: Point; i, byte: SIGNED32; bit: SIGNED64;
BEGIN
	Neutral(acc);
	FOR i := 255 TO 0 BY -1 DO
		AddPoints(doubled, acc, acc);
		CopyPoint(acc, doubled);
		byte := k[i DIV 8];
		bit := (byte DIV SIGNED32(F.Pow2(i MOD 8))) MOD 2;
		IF constantTime THEN
			AddPoints(sum, acc, p);
			Select(acc, sum, bit)
		ELSIF bit = 1 THEN
			AddPoints(sum, acc, p);
			CopyPoint(acc, sum)
		END
	END;
	CopyPoint(r, acc)
END MultiplyPoint;

(** the thirty-two byte encoding: y, with the low bit of x in the top bit *)
PROCEDURE Compress(VAR b: ARRAY OF CHAR; CONST p: Point);
VAR inv, x, y: Element; xb, yb: ARRAY 32 OF CHAR; i: SIGNED32;
BEGIN
	F.Invert(inv, p.z);
	F.Mul(x, p.x, inv); F.Mul(y, p.y, inv);
	F.ToBytes(xb, x); F.ToBytes(yb, y);
	FOR i := 0 TO 31 DO b[i] := yb[i] END;
	IF ODD(ORD(xb[0])) THEN b[31] := CHR(ORD(b[31]) + 80H) END
END Compress;

(*	x from y, which needs a square root in the field: x^2 = (y^2 - 1) / (d y^2 + 1), and the
	root is the candidate to the power (p+3)/8, multiplied by the square root of -1 when that
	candidate squares to the negative of what was wanted. FALSE when there is no root, which is
	a public key that is not a point. *)
PROCEDURE Decompress(VAR p: Point; CONST b: ARRAY OF CHAR): BOOLEAN;
VAR u, v, v3, t, x, xx, check, neg: Element; enc: ARRAY 32 OF CHAR; i: SIGNED32; wantOdd: BOOLEAN;
BEGIN
	FOR i := 0 TO 31 DO enc[i] := b[i] END;
	wantOdd := ORD(enc[31]) >= 80H;
	F.FromBytes(p.y, enc);						(* FromBytes drops the sign bit itself *)
	F.One(p.z);
	F.Square(u, p.y); F.Sub(t, u, p.z); F.Copy(u, t);		(* u = y^2 - 1 *)
	F.Square(v, p.y); F.Mul(t, v, d); F.Add(v, t, p.z);		(* v = d y^2 + 1 *)
	(* x = u v^3 (u v^7)^((p-5)/8) *)
	F.Square(v3, v); F.Mul(t, v3, v); F.Copy(v3, t);		(* v^3 *)
	F.Square(t, v3); F.Mul(xx, t, v); F.Mul(t, xx, u);		(* u v^7 *)
	Power58(x, t);
	F.Mul(t, x, v3); F.Mul(x, t, u);
	(* check x^2 v = u, or = -u in which case multiply by sqrt(-1) *)
	F.Square(xx, x); F.Mul(check, xx, v);
	F.Sub(t, check, u);
	IF ~IsZero(t) THEN
		F.Add(t, check, u);
		IF ~IsZero(t) THEN RETURN FALSE END;
		F.Mul(t, x, sqrtm1); F.Copy(x, t)
	END;
	F.ToBytes(enc, x);
	IF ODD(ORD(enc[0])) # wantOdd THEN
		F.Zero(neg); F.Sub(t, neg, x); F.Copy(x, t)
	END;
	F.Copy(p.x, x);
	F.Mul(p.t, p.x, p.y);
	RETURN TRUE
END Decompress;

(* z^((p-5)/8), by squaring through the exponent -- public data, so the shape may show *)
PROCEDURE Power58(VAR out: Element; CONST z: Element);
VAR acc, t: Element; i: SIGNED32;
BEGIN
	(* (p-5)/8 = 2^252 - 3: every bit set except bit 1 *)
	F.Copy(acc, z);
	FOR i := 250 TO 0 BY -1 DO
		F.Square(t, acc); F.Copy(acc, t);
		IF i # 1 THEN F.Mul(t, acc, z); F.Copy(acc, t) END
	END;
	F.Copy(out, acc)
END Power58;

PROCEDURE IsZero(CONST e: Element): BOOLEAN;
VAR b: ARRAY 32 OF CHAR; i: SIGNED32;
BEGIN
	F.ToBytes(b, e);
	FOR i := 0 TO 31 DO IF b[i] # 0X THEN RETURN FALSE END END;
	RETURN TRUE
END IsZero;

(* --- scalars modulo the group order ------------------------------------------------------- *)

(*	A 512-bit number modulo L, by long division: shift the order up bit by bit and subtract it
	wherever it fits. The subtraction is always computed and its result selected by a mask, so
	the time does not depend on the number -- which for a signature is the secret nonce. *)
PROCEDURE Reduce(VAR out: Scalar; CONST wide: ARRAY OF SIGNED32; bytes: SIGNED32);
VAR rem: ARRAY 33 OF SIGNED32; diff: ARRAY 33 OF SIGNED32;
	i, k, bit, borrow, carry, fits: SIGNED32; mask: SIGNED32;
BEGIN
	FOR i := 0 TO 32 DO rem[i] := 0 END;
	FOR k := bytes * 8 - 1 TO 0 BY -1 DO
		(* rem := rem * 2 + bit k of wide *)
		carry := (wide[k DIV 8] DIV SIGNED32(F.Pow2(k MOD 8))) MOD 2;
		FOR i := 0 TO 32 DO
			carry := rem[i] * 2 + carry;
			rem[i] := carry MOD 100H;
			carry := carry DIV 100H
		END;
		(* diff := rem - L, and keep it when it did not borrow *)
		borrow := 0;
		FOR i := 0 TO 32 DO
			diff[i] := rem[i] - order[i] - borrow;
			IF diff[i] < 0 THEN diff[i] := diff[i] + 100H; borrow := 1 ELSE borrow := 0 END
		END;
		fits := 1 - borrow;
		mask := -fits;
		FOR i := 0 TO 32 DO
			rem[i] := SIGNED32((SET32(diff[i]) * SET32(mask)) + (SET32(rem[i]) * (-SET32(mask))))
		END
	END;
	FOR i := 0 TO 31 DO out[i] := rem[i] END
END Reduce;

(** (a * b + c) mod L, every argument little endian *)
PROCEDURE MulAdd(VAR out: Scalar; CONST a, b, c: Scalar);
VAR wide: ARRAY 64 OF SIGNED32; i, j, carry: SIGNED32;
BEGIN
	FOR i := 0 TO 63 DO wide[i] := 0 END;
	FOR i := 0 TO 31 DO
		carry := 0;
		FOR j := 0 TO 31 DO
			carry := wide[i + j] + a[i] * b[j] + carry;
			wide[i + j] := carry MOD 100H;
			carry := carry DIV 100H
		END;
		j := i + 32;
		WHILE carry # 0 DO
			carry := wide[j] + carry;
			wide[j] := carry MOD 100H;
			carry := carry DIV 100H;
			INC(j)
		END
	END;
	carry := 0;
	FOR i := 0 TO 31 DO
		carry := wide[i] + c[i] + carry;
		wide[i] := carry MOD 100H;
		carry := carry DIV 100H
	END;
	i := 32;
	WHILE carry # 0 DO
		carry := wide[i] + carry;
		wide[i] := carry MOD 100H;
		carry := carry DIV 100H;
		INC(i)
	END;
	Reduce(out, wide, 64)
END MulAdd;

PROCEDURE ScalarFromBytes(VAR s: Scalar; CONST b: ARRAY OF CHAR);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 31 DO s[i] := ORD(b[i]) END
END ScalarFromBytes;

PROCEDURE ScalarToBytes(VAR b: ARRAY OF CHAR; CONST s: Scalar);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 31 DO b[i] := CHR(s[i]) END
END ScalarToBytes;

PROCEDURE Hash(CONST a: ARRAY OF CHAR; alen: SIZE; CONST b: ARRAY OF CHAR; blen: SIZE;
				CONST c: ARRAY OF CHAR; clen: SIZE; VAR out: ARRAY OF CHAR);
VAR h: CryptoSHA512.Hash;
BEGIN
	NEW(h); h.Initialize;
	IF alen > 0 THEN h.Update(a, 0, alen) END;
	IF blen > 0 THEN h.Update(b, 0, blen) END;
	IF clen > 0 THEN h.Update(c, 0, clen) END;
	h.GetHash(out, 0)
END Hash;

PROCEDURE WideFromHash(VAR wide: ARRAY OF SIGNED32; CONST h: ARRAY OF CHAR);
VAR i: SIGNED32;
BEGIN
	FOR i := 0 TO 63 DO wide[i] := ORD(h[i]) END
END WideFromHash;

(** the public key of a thirty-two byte secret *)
PROCEDURE Public*(CONST secret: ARRAY OF CHAR; VAR public: ARRAY OF CHAR);
VAR h: ARRAY 64 OF CHAR; a: Scalar; p: Point; empty: ARRAY 1 OF CHAR;
BEGIN
	Hash(secret, 32, empty, 0, empty, 0, h);
	(* the same clamping as X25519: a multiple of eight, with a fixed top bit *)
	h[0] := CHR(SIGNED32(SET32(ORD(h[0])) * SET32(0F8H)));
	h[31] := CHR(SIGNED32(SET32(ORD(h[31])) * SET32(7FH)));
	h[31] := CHR(SIGNED32(SET32(ORD(h[31])) + SET32(40H)));
	ScalarFromBytes(a, h);
	MultiplyPoint(p, a, base, TRUE);
	Compress(public, p)
END Public;

(** a sixty-four byte signature of the message *)
PROCEDURE Sign*(CONST secret: ARRAY OF CHAR; CONST message: ARRAY OF CHAR; len: SIZE;
				VAR signature: ARRAY OF CHAR);
VAR h, hram: ARRAY 64 OF CHAR; prefix, public, rEnc: ARRAY 32 OF CHAR;
	a, r, k, s: Scalar; wide: ARRAY 64 OF SIGNED32; p: Point;
	empty: ARRAY 1 OF CHAR; i: SIGNED32;
BEGIN
	Hash(secret, 32, empty, 0, empty, 0, h);
	h[0] := CHR(SIGNED32(SET32(ORD(h[0])) * SET32(0F8H)));
	h[31] := CHR(SIGNED32(SET32(ORD(h[31])) * SET32(7FH)));
	h[31] := CHR(SIGNED32(SET32(ORD(h[31])) + SET32(40H)));
	ScalarFromBytes(a, h);
	FOR i := 0 TO 31 DO prefix[i] := h[32 + i] END;
	MultiplyPoint(p, a, base, TRUE);
	Compress(public, p);

	(* r = H(prefix, M) mod L, which is where a repeated nonce would lose the key *)
	Hash(prefix, 32, message, len, empty, 0, h);
	WideFromHash(wide, h);
	Reduce(r, wide, 64);
	ScalarToBytes(rEnc, r);
	MultiplyPoint(p, r, base, TRUE);
	Compress(rEnc, p);

	Hash(rEnc, 32, public, 32, message, len, hram);
	WideFromHash(wide, hram);
	Reduce(k, wide, 64);
	MulAdd(s, k, a, r);

	FOR i := 0 TO 31 DO signature[i] := rEnc[i] END;
	FOR i := 0 TO 31 DO signature[32 + i] := CHR(s[i]) END
END Sign;

(** TRUE when the signature is this public key's signature of this message *)
PROCEDURE Verify*(CONST public: ARRAY OF CHAR; CONST message: ARRAY OF CHAR; len: SIZE;
					CONST signature: ARRAY OF CHAR): BOOLEAN;
VAR hram: ARRAY 64 OF CHAR; rEnc, sEnc, lhs, rhs: ARRAY 32 OF CHAR;
	k, s, reduced: Scalar; wide: ARRAY 64 OF SIGNED32;
	a, rPoint, sb, ka, sum: Point; i: SIGNED32;
BEGIN
	FOR i := 0 TO 31 DO rEnc[i] := signature[i]; sEnc[i] := signature[32 + i] END;
	(*	S must already be reduced: an implementation that accepts an unreduced S accepts a
		second signature for every message, which is what RFC 8032 calls malleability. *)
	ScalarFromBytes(s, sEnc);
	FOR i := 0 TO 63 DO wide[i] := 0 END;
	FOR i := 0 TO 31 DO wide[i] := s[i] END;
	Reduce(reduced, wide, 64);
	FOR i := 0 TO 31 DO
		IF reduced[i] # s[i] THEN RETURN FALSE END
	END;

	IF ~Decompress(a, public) THEN RETURN FALSE END;
	IF ~Decompress(rPoint, rEnc) THEN RETURN FALSE END;

	Hash(rEnc, 32, public, 32, message, len, hram);
	WideFromHash(wide, hram);
	Reduce(k, wide, 64);

	(* [S]B = R + [k]A *)
	MultiplyPoint(sb, s, base, FALSE);
	MultiplyPoint(ka, k, a, FALSE);
	AddPoints(sum, rPoint, ka);
	Compress(lhs, sb);
	Compress(rhs, sum);
	FOR i := 0 TO 31 DO
		IF lhs[i] # rhs[i] THEN RETURN FALSE END
	END;
	RETURN TRUE
END Verify;

PROCEDURE InitConstants;
VAR i: SIGNED32;
BEGIN
	Set(d, 56195235, 13857412, 51736253, 6949390, 114729, 24766616, 60832955, 30306712, 48412415, 21499315);
	Set(d2, 45281625, 27714825, 36363642, 13898781, 229458, 15978800, 54557047, 27058993, 29715967, 9444199);
	Set(sqrtm1, 34513072, 25610706, 9377949, 3500415, 12389472, 33281959, 41962654, 31548777, 326685, 11406482);
	Set(base.x, 52811034, 25909283, 16144682, 17082669, 27570973, 30858332, 40966398, 8378388, 20764389, 8758491);
	Set(base.y, 40265304, 26843545, 13421772, 20132659, 26843545, 6710886, 53687091, 13421772, 40265318, 26843545);
	F.One(base.z);
	F.Mul(base.t, base.x, base.y);
	(* L = 2^252 + 27742317777372353535851937790883648493 *)
	FOR i := 0 TO 32 DO order[i] := 0 END;
	order[0] := 0EDH; order[1] := 0D3H; order[2] := 0F5H; order[3] := 05CH;
	order[4] := 01AH; order[5] := 063H; order[6] := 012H; order[7] := 058H;
	order[8] := 0D6H; order[9] := 09CH; order[10] := 0F7H; order[11] := 0A2H;
	order[12] := 0DEH; order[13] := 0F9H; order[14] := 0DEH; order[15] := 014H;
	order[31] := 010H
END InitConstants;

BEGIN
	InitConstants
END CryptoEd25519.
