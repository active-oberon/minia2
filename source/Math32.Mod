(* ETH Oberon, Copyright 2001 ETH Zuerich Institut fuer Computersysteme, ETH Zentrum, CH-8092 Zuerich.
Refer to the "General ETH Oberon System Source License" contract available at: http://www.oberon.ethz.ch/ *)

MODULE Math32;	(** portable *)
(** AUTHOR "?"; PURPOSE "Math utility module (FLOAT32)"; *)

(* Aos version - requires floating-point instruction support. *)

IMPORT SYSTEM;

CONST
	e* = 2.7182818284590452354E0;
	pi* = 3.14159265358979323846E0;
	tau* = pi * 2.0;
	ln2* = 0.693147180559945309417232121458E0;

	Bits = 32;
	ExponentBits = 8;
	MantissaBits = 23;
	ExponentBias = 127;

	SignMask = SetValue(SHL(UIntValue(1), Bits - 1));
	MaxExponent = SHL(UIntValue(1), ExponentBits) - 1;
	ExponentMask = SetValue(SHL(MaxExponent, MantissaBits));
	MaxMantissa = SHL(UIntValue(1), MantissaBits) - 1;
	MantissaMask = SetValue(MaxMantissa);
	NormalizationScale = SHL(UIntValue(1), MantissaBits);

	PosInfMask = ExponentMask;
	NegInfMask = SignMask + ExponentMask;
	nan = UIntValue(0x7FC00001);

TYPE
	Value* = FLOAT32;
	IntValue* = SIGNED32;
	UIntValue* = UNSIGNED32;
	SetValue* = SET32;
	ValueRec* = RECORD
		f*: Value;
		bits*{OFFSET=0}: SetValue;
		u*{OFFSET=0}: UIntValue;
	END;

PROCEDURE Expo*(x: Value): UIntValue;
BEGIN
	RETURN UIntValue(SHR(SYSTEM.VAL(SetValue, x) * ExponentMask, MantissaBits));
END Expo;

PROCEDURE Mantissa*(x: Value): UIntValue;
BEGIN
	RETURN UIntValue(SYSTEM.VAL(SetValue, x) * MantissaMask)
END Mantissa;

#IF ~AMD64 & ~I386 THEN
	PROCEDURE Equal (x, y: Value): BOOLEAN;
	CONST eps = 1.2E-7;
	BEGIN
		IF x > y THEN
			x := x - y
		ELSE
			x := y - x
		END;
		RETURN x < eps
	END Equal;
#END

(** returns positive zero if "sign" >= 0 (default), negative zero if sign < 0 *)
PROCEDURE Zero*(sign := 0: INTEGER): Value;
VAR value: ValueRec;
BEGIN
	value.u := 0;
	IF sign < 0 THEN
		value.bits := SignMask;
	END;
	RETURN value.f;
END Zero;

(** returns positive infinity if "sign" >= 0 (default), negative infinity if sign < 0 *)
PROCEDURE Inf*(sign := 0: INTEGER): Value;
VAR value: ValueRec;
BEGIN
	IF sign >= 0 THEN
		value.bits := PosInfMask;
	ELSE
		value.bits := NegInfMask;
	END;
	RETURN value.f;
END Inf;

(** returns NaN value *)
PROCEDURE NaN*(): Value;
VAR value: ValueRec;
BEGIN
	value.u := nan;
	RETURN value.f;
END NaN;

(** reports whether "x" is zero.
	"sign" = 0: "x" is zero (default)?
	"sign" > 0: "x" is positive zero?
	"sign" < 0: "x" is negative zero?
*)
PROCEDURE iszero*(x: Value; sign := 0: INTEGER): BOOLEAN;
BEGIN
	RETURN (sign >= 0) & (SYSTEM.VAL(SetValue, x) = {})
					OR (sign <= 0) & (SYSTEM.VAL(SetValue, x) = SignMask)
END iszero;

(** reports whether "x" is infinity.
	"sign" = 0: "x" is infinity (default)?
	"sign" > 0: "x" is positive infinity?
	"sign" < 0: "x" is negative infinity?
*)
PROCEDURE isinf*(x: Value; sign := 0: INTEGER): BOOLEAN;
BEGIN
	RETURN (sign >= 0) & (SYSTEM.VAL(SetValue, x) = PosInfMask)
					OR (sign <= 0) & (SYSTEM.VAL(SetValue, x) = NegInfMask)
END isinf;

(** reports whether "x" is a "NaN" value. *)
PROCEDURE isnan*(x: Value): BOOLEAN;
BEGIN
	RETURN (SYSTEM.VAL(SetValue, x) * ExponentMask = ExponentMask)
					& (SYSTEM.VAL(SetValue, x) * MantissaMask # {})
END isnan;

PROCEDURE isfinite*(x: Value): BOOLEAN;
BEGIN
	RETURN SYSTEM.VAL(SetValue, x) * ExponentMask # ExponentMask;
END isfinite;

PROCEDURE isnonfinite*(x: Value): BOOLEAN;
BEGIN
	RETURN SYSTEM.VAL(SetValue, x) * ExponentMask = ExponentMask;
END isnonfinite;

PROCEDURE isnormal*(x: Value): BOOLEAN;
VAR e := SYSTEM.VAL(SetValue, x) * ExponentMask;
BEGIN
	RETURN (e # ExponentMask) & (e # {});
END isnormal;

PROCEDURE issubnormal*(x: Value): BOOLEAN;
BEGIN
	RETURN (SYSTEM.VAL(SetValue, x) * ExponentMask = {})
					& (SYSTEM.VAL(SetValue, x) * MantissaMask # {});
END issubnormal;

PROCEDURE normalize*(x: Value; VAR exp: IntValue): Value;
BEGIN
	IF SYSTEM.VAL(SetValue, x) * ExponentMask = {} THEN
		IF SYSTEM.VAL(SetValue, x) * MantissaMask = {} THEN (* +-0 *)
			exp := 0; RETURN x
		END;
		(* issubnormal *)
		exp := -MantissaBits;
		RETURN x * NormalizationScale
	END;

	(* isnormal *)
	exp := 0;
	RETURN x;
END normalize;

(** returns a value with the magnitude of `x` and the sign of `s` *)
PROCEDURE copysign*(x, s: Value): Value;
BEGIN
	RETURN SYSTEM.VAL(Value, (SYSTEM.VAL(SetValue, x) - SignMask)
					+ (SYSTEM.VAL(SetValue, s) * SignMask));
END copysign;

PROCEDURE frexp*(x: Value; VAR exp: IntValue): Value;
VAR v: ValueRec; nexp: IntValue;
BEGIN
	IF (SYSTEM.VAL(SetValue, x) * ExponentMask = ExponentMask)
			OR (SYSTEM.VAL(SetValue, x) * (ExponentMask + MantissaMask) = {}) THEN (* ~isfinite or iszero *)
		exp := 0;
		RETURN x;
	END;

	v.f := normalize(x, nexp);
	exp := nexp + IntValue(Expo(v.f)) - ExponentBias + 1;

	v.bits := (v.bits - ExponentMask)
							+ SetValue(SHL(UIntValue(ExponentBias - 1), MantissaBits));
	RETURN v.f;
END frexp;

PROCEDURE ldexp*(x: Value; exp: IntValue): Value;
VAR v: ValueRec;
	nexp: IntValue;
	scale: Value;
BEGIN
	IF (SYSTEM.VAL(SetValue, x) * ExponentMask = ExponentMask)
			OR (SYSTEM.VAL(SetValue, x) * (ExponentMask + MantissaMask) = {}) THEN (* ~isfinite or iszero *)
		RETURN x;
	END;

	v.f := normalize(x, nexp);
	exp := exp + nexp + IntValue(Expo(v.f)) - ExponentBias;

	IF exp < -ExponentBias - MantissaBits THEN
		RETURN copysign(0.0, x);
	ELSIF exp >= ExponentBias THEN
		RETURN copysign(Inf(1), x);
	ELSIF exp < -ExponentBias THEN
		exp := exp + MantissaBits;
		scale := 1.0 / NormalizationScale;
	ELSE
	scale := 1.0;
	END;

	v.bits := (v.bits - ExponentMask)
							+ SetValue(SHL(UIntValue(exp + ExponentBias), MantissaBits));

	RETURN v.f * scale;
END ldexp;

CONST scalbn* = ldexp;

PROCEDURE ilogb*(x: Value): IntValue;
BEGIN
	IF isnonfinite(x) THEN
		RETURN MAX(IntValue);
	ELSIF x = 0.0 THEN
		RETURN MIN(IntValue);
	ELSE
		VAR exp: IntValue;
		RETURN IntValue(Expo(normalize(x, exp))) + exp - ExponentBias;
	END;
END ilogb;

PROCEDURE logb*(x: Value): Value;
BEGIN
	IF isnan(x) THEN
		RETURN NaN();
	ELSIF isinf(x) THEN
		RETURN Inf(1); (* +Inf *)
	ELSIF x = 0.0 THEN
		RETURN Inf(-1); (* -Inf *)
	ELSE
		RETURN Value(ilogb(x));
	END;
END logb;

(** returns the next value after x towards to y *)
PROCEDURE nextafter*(x, y: Value): Value;
VAR vx: ValueRec;
BEGIN
	IF isnan(x) OR isnan(y) THEN
		RETURN NaN();
	ELSIF (x = y) THEN
		RETURN x;
	END;

	IF iszero(x) THEN
		vx.u := 1;
		IF y < 0.0 THEN
			vx.bits := vx.bits + SignMask;
		END;
		RETURN vx.f;
	END;

	vx.f := x;
	IF (y > x) = (x > 0.0) THEN
		INC(vx.u);
	ELSE
		DEC(vx.u);
	END;

	RETURN vx.f;
END nextafter;

PROCEDURE hypot*(x, y: Value): Value;
VAR a := ABS(x), b := ABS(y): Value;
BEGIN
	IF isnan(a) OR isnan(b) THEN
		RETURN NaN();
	ELSIF isinf(a) OR isinf(b) THEN
		RETURN Inf(1);
	END;

	IF a < b THEN
		VAR temp := a;
		a := b;
		b := temp;
	END;

	IF a = 0.0 THEN
		RETURN 0.0;
	END;

	VAR maxExp := ilogb(a);
	IF maxExp > (ExponentBias DIV 2) THEN (* ExponentBias=1023, 1023 DIV 2 = 511 *)
		RETURN copysign(Inf(1), a);
	END;

	VAR n := maxExp - MantissaBits;
	a := ldexp(a, -n);
	b := ldexp(b, -n);

	RETURN ldexp(sqrt(a * a + b * b), n);
END hypot;

PROCEDURE mod*(x, y: Value): Value;
VAR absx, absy, chunk: Value; ex, ey, k: IntValue;
BEGIN
	IF iszero(y) OR isnan(y) OR isnonfinite(x) THEN
		RETURN NaN();
	END;

	absx := ABS(x);
	absy := ABS(y);

	IF absx < absy THEN
		RETURN x;
	ELSIF issubnormal(absy) THEN
		RETURN x;
	END;

	ex := IntValue(Expo(absx));
	ey := IntValue(Expo(absy));

	WHILE ex > ey + MantissaBits DO
		k := ex - ey - 1;
		chunk := ldexp(absy, k);
		absx := absx - chunk;
		ex := IntValue(Expo(absx));
	END;

	WHILE absx >= absy DO
		k := IntValue(ilogb(absx)) - IntValue(ilogb(absy));
		chunk := ldexp(absy, k);

		IF chunk > absx THEN
			chunk := ldexp(absy, k - 1);
		END;

		absx := absx - chunk;
	END;

	IF x < 0.0 THEN
		RETURN -absx;
	ELSE
		RETURN absx;
	END;
END mod;

CONST fmod* = mod;

PROCEDURE power*(x, y: Value): Value;
VAR trunc, frac := modf(y, trunc): Value;
BEGIN
	IF isnan(x) OR isnan(y) THEN
		RETURN NaN();
	ELSIF isinf(y) THEN
		IF ABS(x) = 1.0 THEN
			RETURN 1.0D0
		ELSIF (ABS(x) < 1.0) = isinf(y, 1) THEN
			RETURN 0.0;
		ELSE
			RETURN Inf(1)
		END;
	ELSIF iszero(y) THEN
		RETURN 1.0;
	ELSIF isinf(x) THEN
		IF y < 0.0 THEN
			RETURN 0.0
		ELSIF y > 0.0 THEN
			RETURN copysign(Inf(1), x)
		ELSE (* y=0 *)
			RETURN 1.0
		END;
	ELSIF iszero(x) THEN
		IF y > 0.0D0 THEN
			IF (x < 0.0) & ODD(IntValue(trunc)) THEN
				RETURN Zero(-1);
			ELSE
				RETURN 0.0
			END;
		ELSE (* y < 0 *)
			RETURN Inf(1);
		END;
	END;

	IF (ABS(y) <= MAX(IntValue)) & (frac = 0.0) THEN
		RETURN intpower(x, IntValue(trunc));
	ELSIF (x < 0.0D0) & (frac # 0.0D0) THEN
		RETURN NaN();
	END;

	RETURN exp(y * ln(x));
END power;

PROCEDURE intpower*(x: Value; y: IntValue): Value;
VAR answer := 1.0: Value;
BEGIN
	IF y < 0 THEN
		x := 1.0/x;
		y := -y;
	END;

	WHILE y # 0 DO
		IF ODD(y) THEN
			answer := answer * x;
		END;
		y := SHR(y, 1);
		x := x * x;
	END;
	RETURN answer;
END intpower;

PROCEDURE sin*(x: Value): Value;
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FSIN
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT;
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FSIN
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT;
#ELSE
	WHILE x >= 2 * pi DO x := x - 2*pi END;
	WHILE x < 0 DO x := x + 2*pi END;

	VAR res := x, xk := x, k := INTEGER(1);
	VAR prev: Value;
	REPEAT
		prev := res;
		xk := -xk * x * x / (2 * k) / (2 * k + 1);
		res := res + xk;
		INC(k)
	UNTIL Equal(prev, res) OR (k = 5000);
	RETURN res
#END
END sin;

PROCEDURE cos*(x: Value): Value;
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FCOS
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT;
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FCOS
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT;
#ELSE
	WHILE x >= 2 * pi DO x := x - 2*pi END;
	WHILE x < 0 DO x := x + 2*pi END;

	VAR res := Value(1.0), xk := Value(1.0), k := INTEGER(1);
	VAR prev: Value;
	REPEAT
		prev := res;
		xk := -xk * x * x / (2 * k - 1) / (2 * k);
		res := res + xk;
		INC(k, 1)
	UNTIL Equal(xk, 0.0) OR Equal(prev, res) OR (k = 5000);
	RETURN res
#END
END cos;

PROCEDURE sincos*(x: Value; VAR s, c: Value);
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FSINCOS
		MOV EAX, [EBP + s]
		MOV EDX, [EBP + c]
		FSTP [EDX]
		FSTP [EAX]
	END;
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FSINCOS
		MOV RAX, [RBP + s]
		MOV RDX, [RBP + c]
		FSTP [RDX]
		FSTP [RAX]
	END;
#ELSE (*! optimization *)
	s := sin(x);
	c := cos(x);
#END
END sincos;

PROCEDURE tan*(x: Value): Value;
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FSINCOS
		FDIVP
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT;
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FSINCOS
		FDIVP
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT;
#ELSE
	VAR s, c: Value;
	sincos(x, s, c);
	RETURN s/c;
#END
END tan;

PROCEDURE arcsin* (x: Value): Value;
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FLD ST0
		FMUL ST0, ST0
		FLD1
		FSUBRP
		FSQRT
		FNOP
		FPATAN
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FLD ST0
		FMUL ST0, ST0
		FLD1
		FSUBRP
		FSQRT
		FNOP
		FPATAN
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT
#ELSE
	RETURN arctan2(x, sqrt((1.0 - x) * (1.0 + x)));
#END
END arcsin;

PROCEDURE arccos* (x: Value): Value;
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FMUL ST0, ST0
		FLD1
		FSUBRP
		FSQRT
		FLD [EBP + x]
		FPATAN
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FMUL ST0, ST0
		FLD1
		FSUBRP
		FSQRT
		FLD [RBP + x]
		FPATAN
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT
#ELSE
	RETURN arctan2(sqrt((1.0 - x) * (1.0 + x)), x);
#END
END arccos;

#IF ~AMD64 & ~I386 THEN
	PROCEDURE -arctan0(y:Value):Value;
	VAR
		k: INTEGER;
		prev, res, term, yk: Value;
	BEGIN
		IF (y = 1) OR (y = -1) THEN
			RETURN y * pi / 4
		ELSIF (y > 1) OR (y < -1) THEN
			RETURN pi / 2 - arctan(1 / y)
		ELSE
			(* atan(y) = sum_k (-1)^(k) y^{2 k + 1} / (2 k + 1), |y| < 1 *)
			prev := pi / 2;
			res := 0.0;
			yk := y;
			k := 0;
			REPEAT
				prev := res;
				term := 1 / (2 * k + 1) * yk;
				IF ODD(k) THEN
					res := res - term
				ELSE
					res := res + term
				END;
				yk := yk * y * y;
				INC(k)
			UNTIL Equal(prev, res) OR (k = 50000);
			RETURN res
		END
	END arctan0;
#END

(* one-parameter version: res:=arctan(y/x) with the usual loss of the quadrant information
	two-parameter version specific for all quadrants: res:=arctan(y,x) iusing optional second argument*)
PROCEDURE arctan2*(y: Value; x:=1.0:Value): Value;
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + y]
		FLD	[EBP + x]
		FPATAN
		#IF ~LEGACY THEN
			FSTP [EBP + y]
			MOVSS XMM0, [EBP + y]
		#END
	END;
	RETURN RESULT;
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + y]
		FLD [RBP + x]
		FPATAN
		#IF ~LEGACY THEN
			FSTP [RBP + y]
			MOVSS XMM0, [RBP + y]
		#END
	END;
	RETURN RESULT;
#ELSE
	IF (x>0) & (y>=0) THEN RETURN arctan0(y/x)
	ELSIF (x>0) & (y<0) THEN RETURN arctan0(y/x)
(*!	ELSIF x<0 THEN RETURN arctan0(y/x)-pi (*?*)*)
	ELSIF x < 0 THEN
		IF y >= 0 THEN
			RETURN arctan0(y/x) + pi
		ELSE
			RETURN arctan0(y/x) - pi
		END
	ELSIF (x=0) & (y>0) THEN RETURN pi/2
	ELSIF (x=0) & (y<0) THEN RETURN -pi/2
	ELSE (*( x=0) & (y=0) *) RETURN 0
	END
#END
END arctan2;

PROCEDURE arctan*(y: Value): Value;
BEGIN
	RETURN arctan2(y);
END arctan;

PROCEDURE sinh*(x: Value): Value;
BEGIN
	RETURN (exp(x) - exp(-x)) / 2.0;
END sinh;

PROCEDURE cosh*(x: Value): Value;
BEGIN
	RETURN (exp(x) + exp(-x)) / 2.0;
END cosh;

PROCEDURE tanh*(x: Value): Value;
BEGIN
	RETURN sinh(x) / cosh(x);
END tanh;

PROCEDURE asinh*(x: Value): Value;
BEGIN
	RETURN ln(x + sqrt(x * x + 1.0));
END asinh;

PROCEDURE acosh*(x: Value): Value;
BEGIN
	IF x < 1.0 THEN RETURN NaN() END;
	RETURN ln(x + sqrt(x * x - 1.0));
END acosh;

PROCEDURE atanh*(x: Value): Value;
BEGIN
	IF (x >= 1.0) OR (x <= -1.0) THEN RETURN NaN() END;
	RETURN 0.5 * ln((1.0 + x) / (1.0 - x));
END atanh;

PROCEDURE sec*(x: Value): Value;
BEGIN
	RETURN 1.0 / cos(x);
END sec;

PROCEDURE csc*(x: Value): Value;
BEGIN
	RETURN 1.0 / sin(x);
END csc;

PROCEDURE cot*(x: Value): Value;
BEGIN
	RETURN 1.0 / tan(x);
END cot;

PROCEDURE sqrt*(x: Value): Value;
BEGIN
	IF x <= 0 THEN
		IF x = 0 THEN RETURN 0 ELSE HALT(80) END;
	END;
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FSQRT
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT;
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FSQRT
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT;
#ELSE
	RETURN exp(0.5 * ln(x));
#END
END sqrt;

PROCEDURE ln*(x: Value): Value;
BEGIN
	IF x <= 0 THEN
		HALT(80);
	END;
#IF I386 THEN
	CODE
		FLD1
		FLDL2E
		FDIVP
		FLD [EBP + x]
		FYL2X
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT;
#ELSIF AMD64 THEN
	CODE
		FLD1
		FLDL2E
		FDIVP
		FLD [RBP + x]
		FYL2X
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT;
#ELSE
	IF x < 1.0 THEN
		RETURN -ln(1.0 / x)
	ELSIF x >= 2.0 THEN
		(*
			algorithm idea from http://stackoverflow.com/questions/10732034/how-are-logarithms-programmed
			and https://en.wikipedia.org/wiki/Natural_logarithm (Newton's method)

			ln(m * 2^e) = e ln(2) + ln(m)
		*)
		RETURN (Expo(x) - ExponentBias) * ln2 + ln(SYSTEM.VAL(Value, Mantissa(x) + 3F800000H))
	ELSE
		(* ln(x) = 2 * sum_k 1/(2 k + 1) y^k, where y = (x - 1) / (x + 1), x real *)
		VAR y := (x - 1) / (x + 1);
		VAR yk := y;
		VAR res := y;
		VAR k := INTEGER(1);
		REPEAT
			yk := yk * y * y;
			res := res + yk / (2 * k + 1);
			INC(k)
		UNTIL Equal(yk, 0.0) OR (k = 5000);
		RETURN 2.0 * res;
	END
#END
END ln;

PROCEDURE exp*(x: Value): Value;
BEGIN
#IF I386 THEN
	CODE
		FLD [EBP + x]
		FLDL2E
		FMULP
		FLD ST0
		FRNDINT
		FXCH ST1
		FSUB ST0, ST1
		F2XM1
		FLD1
		FADDP
		FSCALE
		FSTP ST1
		#IF ~LEGACY THEN
			FSTP [EBP + x]
			MOVSS XMM0, [EBP + x]
		#END
	END;
	RETURN RESULT;
#ELSIF AMD64 THEN
	CODE
		FLD [RBP + x]
		FLDL2E
		FMULP
		FLD ST0
		FRNDINT
		FXCH ST1
		FSUB ST0, ST1
		F2XM1
		FLD1
		FADDP
		FSCALE
		FSTP ST1
		#IF ~LEGACY THEN
			FSTP [RBP + x]
			MOVSS XMM0, [RBP + x]
		#END
	END;
	RETURN RESULT;
#ELSE
	IF x < 0.0 THEN
		RETURN 1.0 / exp(-x)
	ELSE
		(* exp(x) = sum_k x^(k) / k! *)
		VAR prev := Value(0.0), res := Value(1.0);
		VAR k := INTEGER(1);
		VAR xk := Value(1.0);
		REPEAT
			prev := res;

			xk := xk / k * x;
			res := res + xk;
			INC(k, 1)
		UNTIL Equal(xk, 0.0) OR (k = 5000);
		RETURN res
	END
#END
END exp;

(** returns the integer part of "x" *)
PROCEDURE trunc*(x: Value): Value;
BEGIN
	IF isnonfinite(x) THEN
		RETURN x;
	END;

	VAR e := IntValue(SHR(SYSTEM.VAL(SetValue, x) * ExponentMask, MantissaBits)) - ExponentBias;

	IF e < 0 THEN (* (-1 .. 1) *)
		RETURN copysign(0.0, x);
	ELSIF e < MantissaBits THEN
		RETURN SYSTEM.VAL(Value, SYSTEM.VAL(SetValue, x) - SetValue(SHL(UIntValue(1), MantissaBits - e) - 1))
	END;
	RETURN x;
END trunc;

(** Splits "x" into integer and fractional parts. Both parts have the same sign as "x".
	The integer part is stored in the "int" parameter, and the fractional part is returned by the function.
*)
PROCEDURE modf*(x: Value; VAR int: Value): Value;
BEGIN
	int := x;
	IF isnan(x) THEN
		RETURN x
	ELSIF isinf(x) THEN
		RETURN copysign(0, x)
	ELSIF iszero(x) THEN
		RETURN x;
	END;

	VAR e := IntValue(SHR(SYSTEM.VAL(SetValue, x) * ExponentMask, MantissaBits)) - ExponentBias;

	IF e < 0 THEN
		int := copysign(0.0, x);
	ELSIF e < MantissaBits THEN
		int := SYSTEM.VAL(Value, SYSTEM.VAL(SetValue, x)
					- SetValue(SHL(UIntValue(1), MantissaBits - e) - 1))
	END;

	RETURN copysign(x - int, x);
END modf;

(** Rounds the value of "x" and returns the greatest value less than or equal to "x" *)
PROCEDURE floor*(x: Value): Value;
VAR int := trunc(x);
BEGIN
	IF (x < 0) & (x # int) THEN
		int := int - 1;
	END;
	RETURN int;
END floor;

(** Rounds the value of "x" and returns the least value greater than or equal to x *)
PROCEDURE ceil*(x: Value): Value;
VAR int := trunc(x);
BEGIN
	IF (0 < x) & (x # int) THEN
		int := int + 1
	END;
	RETURN int;
END ceil;

PROCEDURE rint*(x: Value): Value;
BEGIN
	IF x >= 0.0 THEN
		RETURN trunc(x + 0.5);
	ELSE
		RETURN trunc(x - 0.5);
	END;
END rint;

(** returns the fractional part of "x" *)
PROCEDURE frac*(x: Value): Value;
BEGIN
	IF isnan(x) THEN
		RETURN NaN();
	ELSIF isinf(x) THEN
		RETURN copysign(0.0, x);
	ELSIF iszero(x) THEN
		RETURN x;
	END;

	RETURN copysign(x - trunc(x), x);
END frac;

PROCEDURE deg2rad*(deg: Value): Value;
BEGIN
	RETURN deg * pi / 180.0;
END deg2rad;

PROCEDURE rad2deg*(rad: Value): Value;
BEGIN
	RETURN rad * 180.0 / pi;
END rad2deg;

PROCEDURE clamp*(x, min, max: Value): Value;
BEGIN
	IF x < min THEN
		RETURN min;
	ELSIF x > max THEN
		RETURN max;
	ELSE
		RETURN x;
	END;
END clamp;

PROCEDURE lerp*(a, b, t: Value): Value;
BEGIN
	RETURN a + t * (b - a);
END lerp;

PROCEDURE smoothstep*(edge0, edge1, x: Value): Value;
BEGIN
	IF x <= edge0 THEN
		RETURN 0.0;
	ELSIF x >= edge1 THEN
		RETURN 1.0;
	END;
	VAR t := clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
	RETURN t * t * (3.0 - 2.0 * t);
END smoothstep;

END Math32.
