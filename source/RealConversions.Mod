MODULE RealConversions;  (* GF *)

IMPORT SYSTEM;

TYPE
	(** Procedure used in ScanReal for peeking the next character from the input character stream.

		An example:

		PROCEDURE Next(): CHAR;
		BEGIN
			INC(streamPos); (* preincrement the stream position *)
			IF streamPos < streamLength THEN
				RETURN stream(streamPos);
			ELSE RETURN 0X;
			END;
		END Next;
	*)
	PeekNext* = PROCEDURE {DELEGATE} ( ): CHAR;

VAR
	H, L: SIGNED16;

	PROCEDURE -IsDigit(ch: CHAR): BOOLEAN;
	BEGIN
		RETURN (ch >= "0") & (ch <= "9")
	END IsDigit;

	(**	Scan a floating-point number.
		EBNF: Real = [{' '}] ['+'|'-'] [Digit {Digit}] '.' Digit {Digit} ['d'|'D|'e'|'E'' ['+'|'-'] Digit {Digit}].

		ch : first peek from the input character stream
		next : a procedure to peek the next character
		r : scanning result

		Returns TRUE in case of a valid conversion. The result value r remains unchanged in case of an error.
	*)
	PROCEDURE ScanReal*( ch: CHAR; next: PeekNext; VAR r: FLOAT64 ): BOOLEAN;
	VAR neg := FALSE, negE := FALSE, rest := FALSE, any := FALSE: BOOLEAN;
		digits: ARRAY BigDigits + 1 OF CHAR;
		count := 0: SIGNED32;  exp10 := 0: SIGNED32;

		(*	One significant digit. Past the fortieth only its being non-zero still matters, and
			whether the ones dropped were before or after the point decides the exponent. *)
		PROCEDURE Digit( ch: CHAR;  fraction: BOOLEAN );
		BEGIN
			any := TRUE;
			IF count < BigDigits THEN
				digits[count] := ch;  INC( count );
				IF fraction THEN  DEC( exp10 )  END
			ELSE
				IF ch # "0" THEN  rest := TRUE  END;
				IF ~fraction THEN  INC( exp10 )  END
			END
		END Digit;

		PROCEDURE ScanFractionalPart;
		BEGIN
			WHILE ("0" <= ch) & (ch <= "9") DO  Digit( ch, TRUE );  ch := next()  END
		END ScanFractionalPart;

	BEGIN
		(* skip leading spaces *)
		WHILE (ch = " ") DO ch := next() END;
		IF ch = "-" THEN  neg := TRUE; ch := next()
		ELSIF ch = "+" THEN ch := next() END;
		IF ch # "." THEN (* expecting the integer part *)
			IF ~IsDigit(ch) THEN RETURN FALSE END;
			WHILE ("0" <= ch) & (ch <= "9") DO  Digit( ch, FALSE );  ch := next()  END;
			IF ch = "." THEN ch := next(); ScanFractionalPart; END;
		ELSE (* no integer part *)
			ch := next();
			IF IsDigit(ch) THEN ScanFractionalPart;
			ELSE RETURN FALSE END; (*! if the point comes without the integer part it must be followed by a digit *)
		END;
		IF (ch = "d") OR (ch = "D") OR (ch = "e") OR (ch = "E") THEN
			ch := next();
			IF ch = "-" THEN negE := TRUE; ch := next()
			ELSIF ch = "+" THEN ch := next()
			END;
			IF ~IsDigit(ch) THEN RETURN FALSE END; (*! the exponent character must be followed either by the sign or a digit *)
			(* skip leading zeros *)
			WHILE (ch = "0") DO ch := next() END;
			(* scan the exponent value *)
			VAR e := 0: SIGNED32;
			WHILE ("0" <= ch) & (ch <= "9") DO
				IF e < 100000 THEN  e := e * 10 + (ORD(ch) - ORD("0"))  END;	(* further digits cannot bring it back *)
				ch := next()
			END;
			IF negE THEN DEC( exp10, e ) ELSE INC( exp10, e ) END
		END;
		IF ~any THEN RETURN FALSE END;
		digits[count] := 0X;
		IF ~DecimalToReal( digits, exp10, rest, r ) THEN RETURN FALSE END;
		IF neg THEN r := -r END;
		RETURN TRUE
	END ScanReal;

	(**	Convert a string to a floating-point number.
		EBNF: Real = [{' '}] ['+'|'-'] [Digit {Digit}] '.' Digit {Digit} ['d'|'D|'e'|'E'' ['+'|'-'] Digit {Digit}] [{' '}].

		s : input null-terminated string; absence of the terminating null can cause an index out of range exception
		r : conversion result

		Returns TRUE in case of a valid conversion. The result value r remains unchanged in case of an error.
	*)
	PROCEDURE StringToReal*( CONST s: ARRAY OF CHAR; VAR r: FLOAT64 ): BOOLEAN;
	VAR neg := FALSE, negE := FALSE, rest := FALSE, any := FALSE: BOOLEAN;
		digits: ARRAY BigDigits + 1 OF CHAR;
		count := 0: SIGNED32;  exp10 := 0: SIGNED32;
		p := 0: SIZE;  ch: CHAR;

		PROCEDURE Digit( ch: CHAR;  fraction: BOOLEAN );
		BEGIN
			any := TRUE;
			IF count < BigDigits THEN
				digits[count] := ch;  INC( count );
				IF fraction THEN  DEC( exp10 )  END
			ELSE
				IF ch # "0" THEN  rest := TRUE  END;
				IF ~fraction THEN  INC( exp10 )  END
			END
		END Digit;

		PROCEDURE ScanFractionalPart;
		BEGIN
			WHILE ("0" <= ch) & (ch <= "9") DO  Digit( ch, TRUE );  INC( p );  ch := s[p]  END
		END ScanFractionalPart;

	BEGIN
		ch := s[0];
		WHILE (ch = " ") DO INC(p); ch := s[p] END;
		IF ch = "-" THEN  neg := TRUE; INC(p); ch := s[p]
		ELSIF ch = "+" THEN INC(p); ch := s[p] END;
		IF ch # "." THEN (* expecting the integer part *)
			IF ~IsDigit(ch) THEN RETURN FALSE END;
			WHILE ("0" <= ch) & (ch <= "9") DO  Digit( ch, FALSE );  INC( p );  ch := s[p]  END;
			IF ch = "." THEN INC(p); ch := s[p]; ScanFractionalPart; END;
		ELSE (* no integer part *)
			INC(p); ch := s[p];
			IF IsDigit(ch) THEN ScanFractionalPart;
			ELSE RETURN FALSE END; (*! if the point comes without the integer part it must be followed by a digit *)
		END;
		IF (ch = "d") OR (ch = "D") OR (ch = "e") OR (ch = "E") THEN
			INC(p); ch := s[p];
			IF ch = "-" THEN negE := TRUE; INC(p); ch := s[p]
			ELSIF ch = "+" THEN INC(p); ch := s[p]
			END;
			IF ~IsDigit(ch) THEN RETURN FALSE END; (*! the exponent character must be followed either by the sign or a digit *)
			VAR e := 0: SIGNED32;
			WHILE ("0" <= ch) & (ch <= "9") DO
				IF e < 100000 THEN  e := e * 10 + (ORD(ch) - ORD("0"))  END;
				INC(p); ch := s[p]
			END;
			IF negE THEN DEC( exp10, e ) ELSE INC( exp10, e ) END
		END;
		WHILE (ch = " ") DO INC(p); ch := s[p] END;
		IF (ch # 0X) THEN RETURN FALSE END; (*! only trailing spaces are allowed, nothing else *)
		IF ~any THEN RETURN FALSE END;
		digits[count] := 0X;
		IF ~DecimalToReal( digits, exp10, rest, r ) THEN RETURN FALSE END;
		IF neg THEN r := -r END;
		RETURN TRUE
	END StringToReal;

	PROCEDURE RealToString*( x: FLOAT64; n: INTEGER; VAR buf: ARRAY OF CHAR );
	(* BM 1993.4.22. Do not simplify rounding! *)
	VAR
		e, h, l, i, pos: SIGNED32;  z: FLOAT64;  d: ARRAY 16 OF CHAR; m: INTEGER;

		PROCEDURE Char( c: CHAR );
		BEGIN
			buf[pos] := c;  INC( pos )
		END Char;

		PROCEDURE String( CONST s: ARRAY OF CHAR );
		VAR i: SIGNED32;
		BEGIN
			i := 0;
			WHILE s[i] # 0X DO  Char( s[i] );  INC( i )  END
		END String;

	BEGIN
		pos := 0;
		e := ExpoL( x );
		IF e = 2047 THEN
			NaNCodeL( x, h, l );
			IF (h # 0) OR (l # 0) THEN  String( "NaN" )
			ELSIF x < 0 THEN  String("-INF" )
			ELSE  String("+INF" )
			END
		ELSE
			IF (e # 0) & (x < 0) THEN
				Char( "-" );
				x := -x
			END;
			IF e = 0 THEN
				h := 0;  l := 0 (* no denormals *)
			ELSE
				e := (e - 1023) * 301029 DIV 1000000;   (* ln(2)/ln(10) = 0.301029996 *)
				z := Ten( e + 1 );
				IF x >= z THEN  x := x / z;  INC( e )  ELSE  x := x * Ten( -e )  END;
				IF x >= 10 THEN  x := x * Ten( -1 ) + 0.5D0 / Ten( 15 );  INC( e )
				ELSE
					x := x + 0.5D0 / Ten( 15 );
					IF x >= 10 THEN  x := x * Ten( -1 );  INC( e )  END
				END;
				x := x * Ten( 7 );  h := ENTIER( x );  x := (x - h) * Ten( 8 );  l := ENTIER( x )
			END;
			i := 15;
			WHILE i > 7 DO  d[i] := CHR( l MOD 10 + ORD( "0" ) );  l := l DIV 10;  DEC( i )  END;
			WHILE i >= 0 DO d[i] := CHR( h MOD 10 + ORD( "0" ) );  h := h DIV 10;  DEC( i )  END;

			Char( d[0] ); Char( "." );
			m := 15;
			WHILE (m>0) & (d[m] = '0') DO
				DEC(m)
			END;
			FOR i := 1 TO m DO
				Char( d[i] );
			END;
			IF e # 0 THEN
				IF e < 0 THEN
					String( "E-" );  e := -e
				ELSE
					String( "E+" )
				END;
				IF e >= 100 THEN Char( CHR( e DIV 100 + ORD( "0" ))) END;
				IF e >= 10 THEN Char( CHR( e MOD 100 DIV 10 + ORD( "0" ))) END;
				Char( CHR( e MOD 10 + ORD( "0" )))
			END;
		END;
		buf[pos] := 0X;
		INC(n);
		IF n > pos THEN
			WHILE(pos >= 0) DO
				buf[n] := buf[pos];
				DEC(pos);
				DEC(n);
			END;
			WHILE (n>=0) DO
				buf[n] := " ";
				DEC(n);
			END;
		END;
	END RealToString;

	(**	Convert FLOAT64 x to string in a fixed point notation.
		n is the overall minimal length for the output field, f the number of fraction digits following the decimal point,
		D the fixed exponent (printed only when D # 0). *)
	PROCEDURE RealToStringFix*( x: FLOAT64;  n, f, D: INTEGER; VAR buf: ARRAY OF CHAR );
	(* BM 1993.4.22. Do not simplify rounding! / JG formatting adjusted *)
	VAR
		e, h, l, i, pos: SIGNED32;  r, z: FLOAT64;
		d: ARRAY 16 OF CHAR;
		s: CHAR;  dot: BOOLEAN;

		PROCEDURE Char( c: CHAR );
		BEGIN
			buf[pos] := c;  INC( pos )
		END Char;

		PROCEDURE String( CONST s: ARRAY OF CHAR );
		VAR i: SIGNED32; ch: CHAR;
		BEGIN
			ch := s[0]; i := 1;
			WHILE ch # 0X DO  Char( ch );  ch := s[i];  INC( i )  END
		END String;

	BEGIN
		pos := 0;
		e := ExpoL( x );
		IF (e = 2047) OR (ABS( D ) > 308) THEN
			WHILE n > 5 DO  Char( " " );  DEC( n )  END;
			NaNCodeL( x, h, l );
			IF (h # 0) OR (l # 0) THEN  String( "  NaN" )
			ELSIF x < 0 THEN  String( " -INF" )
			ELSE  String( "  INF" )
			END
		ELSE
			IF D = 0 THEN
				IF f = 0 THEN  dot := FALSE; DEC( n, 1 )  ELSE  dot := TRUE;  DEC( n, 2 )  END
			ELSE  dot := TRUE;  DEC( n, 7 )
			END;
			IF n < 2 THEN  n := 2  END;
			IF f < 0 THEN  f := 0  END;
			IF n < f + 2 THEN  n := f + 2  END;
			DEC( n, f );
			IF (e # 0) & (x < 0) THEN  s := "-";  x := -x  ELSE  s := " "  END;
			IF e = 0 THEN
				h := 0;  l := 0;  DEC( e, D - 1 ) (* no denormals *)
			ELSE
				e := (e - 1023) * 301029 DIV 1000000;   (* ln(2)/ln(10) = 0.301029996 *)
				z := Ten( e + 1 );
				IF x >= z THEN  x := x / z;  INC( e )  ELSE  x := x * Ten( -e )  END;
				DEC( e, D - 1 );  i := -(e + f);
				IF i <= 0 THEN  r := 5 * Ten( i )  ELSE  r := 0  END;
				IF x >= 10 THEN  x := x * Ten( -1 ) + r;  INC( e )
				ELSE
					x := x + r;
					IF x >= 10 THEN  x := x * Ten( -1 );  INC( e )  END
				END;
				x := x * Ten( 7 );  h := ENTIER( x );  x := (x - h) * Ten( 8 );  l := ENTIER( x )
			END;
			i := 15;
			WHILE i > 7 DO  d[i] := CHR( l MOD 10 + ORD( "0" ) );  l := l DIV 10;  DEC( i )  END;
			WHILE i >= 0 DO  d[i] := CHR( h MOD 10 + ORD( "0" ) );  h := h DIV 10;  DEC( i )  END;
			IF n <= e THEN  n := e + 1  END;
			IF e > 0 THEN
				WHILE n > e DO  Char( " " );  DEC( n )  END;
				Char( s );  e := 0;
				WHILE n > 0 DO
					DEC( n );
					IF e < 16 THEN  Char( d[e] );  INC( e )  ELSE  Char( "0" )  END
				END;
				IF dot THEN  Char( "." )  END;
			ELSE
				WHILE n > 1 DO  Char( " " );  DEC( n )  END;
				Char( s );  Char( "0" );  IF dot  THEN Char( "." )  END;
				WHILE (0 < f) & (e < 0) DO  Char( "0" );  DEC( f );  INC( e )  END
			END;
			WHILE f > 0 DO
				DEC( f );
				IF e < 16 THEN  Char( d[e] );  INC( e )  ELSE  Char( "0" )  END
			END;
			IF D # 0 THEN
				IF D < 0 THEN  String( "E-" );  D := -D  ELSE  String( "E+" )  END;
				Char( CHR( D DIV 100 + ORD( "0" ) ) );  D := D MOD 100;
				Char( CHR( D DIV 10 + ORD( "0" ) ) );  Char( CHR( D MOD 10 + ORD( "0" ) ) )
			END
		END;
		Char( 0X )
	END RealToStringFix;



	(*** the following procedures stem from Reals.Mod *)

	(** Returns the NaN code (0 <= h < 1048576, MIN(SIGNED32) <= l <= MAX(SIGNED32)) or (-1,-1) if not NaN/Infinite. *)
	PROCEDURE NaNCodeL( x: FLOAT64;  VAR h, l: SIGNED32 );
	BEGIN
		SYSTEM.GET( ADDRESSOF( x ) + H, h );  SYSTEM.GET( ADDRESSOF( x ) + L, l );
		IF ASH( h, -20 ) MOD 2048 = 2047 THEN  (* Infinite or NaN *)
			h := h MOD 100000H (* lowest 20 bits *)
		ELSE h := -1;  l := -1
		END
	END NaNCodeL;


	(** Returns the shifted binary exponent (0 <= e < 2048). *)
	PROCEDURE ExpoL( x: FLOAT64 ): SIGNED32;
	VAR i: SIGNED32;
	BEGIN
		SYSTEM.GET( ADDRESSOF( x ) + H, i );  RETURN ASH( i, -20 ) MOD 2048
	END ExpoL;

	(** Convert hexadecimal to FLOAT64. h and l are the high and low parts.*)
	PROCEDURE RealL( h, l: SIGNED32 ): FLOAT64;
	VAR x: FLOAT64;
	BEGIN
		SYSTEM.PUT( ADDRESSOF( x ) + H, h );  SYSTEM.PUT( ADDRESSOF( x ) + L, l );  RETURN x
	END RealL;


	(** Returns 10^e (e <= 308, 308 < e delivers IEEE-code +INF). *)
	PROCEDURE Ten( e: SIGNED32 ): FLOAT64;   (* naiive version *)
	VAR r: FLOAT64;
	BEGIN
		IF e < -307 THEN RETURN 0
		ELSIF 308 < e THEN RETURN RealL( 2146435072, 0 )
		END;
		r := 1;
		WHILE (e > 0) DO r := r * 10;  DEC( e );  END;
		WHILE (e < 0) DO r := r / 10;  INC( e );  END;
		RETURN r;
	END Ten;

	(*	Decimal to binary64, correctly rounded.

		The naive way -- multiply the digits together in FLOAT64 and scale by a power of ten
		computed the same way -- rounds once per operation, and the roundings add up: 1.0E+300
		came out four units in the last place away from the number that was written, and a
		seventeen digit mantissa came out one. Since a literal denotes one real number and
		binary64 has exactly one nearest value to it, "close" is a defect and not a taste.

		So the digits are held as an integer of arbitrary width and scaled exactly, and the one
		and only rounding is the last step: the top 54 bits, the bit below them and whether
		anything at all remains below that (`sticky`) decide the 53 bit mantissa, ties to even.
		Scaling up is a multiplication by 10^q; scaling down is a division by 5^p after a shift
		left, because the 2^p half of 10^p is exact in binary and only the 5^p half is not.
	*)

	CONST
		BigWords = 96;			(* 3072 bits: a literal shifted to where rounding happens, or the exact decimal of any binary64 *)
		BigDigits* = 40;			(* digits that can still change a binary64; what follows only makes the rest non-zero *)
		TenChunk = 1000000000;		(* 10^9, the largest power of ten a word holds *)
		TenChunkDigits = 9;
		FiveChunk = 1220703125;	(* 5^13 *)
		FiveChunkExp = 13;
		Word = 100000000H;			(* 2^32 *)
		Two52 = 4503599627370496;
		Two53 = 9007199254740992;
		MinExp2 = -1074;			(* and the exponent every subnormal has *)
		MaxDecimalDigits* = 767;	(* the longest exact decimal a binary64 has: 5^1074 *)

	TYPE
		Big = RECORD w: ARRAY BigWords OF SIGNED64;  n: SIGNED32 END;

	PROCEDURE PowerTwo( bits: SIGNED32 ): SIGNED64;
	VAR value: SIGNED64;  i: SIGNED32;
	BEGIN
		value := 1;
		FOR i := 1 TO bits DO  value := value * 2  END;
		RETURN value
	END PowerTwo;

	PROCEDURE BigSet( VAR b: Big;  value: SIGNED64 );
	BEGIN
		b.n := 0;
		WHILE value > 0 DO  b.w[b.n] := value MOD Word;  value := value DIV Word;  INC( b.n )  END
	END BigSet;

	(** b := b * m + a, for m and a below 2^31; FALSE when b would need more words than it has. *)
	PROCEDURE BigMulAdd( VAR b: Big;  m, a: SIGNED64 ): BOOLEAN;
	VAR i: SIGNED32;  carry, t: SIGNED64;
	BEGIN
		carry := a;
		FOR i := 0 TO b.n - 1 DO
			t := b.w[i] * m + carry;  b.w[i] := t MOD Word;  carry := t DIV Word
		END;
		WHILE carry > 0 DO
			IF b.n >= BigWords THEN  RETURN FALSE  END;
			b.w[b.n] := carry MOD Word;  carry := carry DIV Word;  INC( b.n )
		END;
		RETURN TRUE
	END BigMulAdd;

	(** b := b DIV d, answering the remainder, for d below 2^31. *)
	PROCEDURE BigDiv( VAR b: Big;  d: SIGNED64 ): SIGNED64;
	VAR i: SIGNED32;  rest, t: SIGNED64;
	BEGIN
		rest := 0;
		FOR i := b.n - 1 TO 0 BY -1 DO
			t := rest * Word + b.w[i];  b.w[i] := t DIV d;  rest := t MOD d
		END;
		WHILE (b.n > 0) & (b.w[b.n - 1] = 0) DO  DEC( b.n )  END;
		RETURN rest
	END BigDiv;

	PROCEDURE BigShiftLeft( VAR b: Big;  bits: SIGNED32 ): BOOLEAN;
	VAR words, i: SIGNED32;
	BEGIN
		words := bits DIV 32;  bits := bits MOD 32;
		(*	In sixteen bit steps: a word times 2^31 plus a carry is past what SIGNED64 holds,
			and the whole point of this arithmetic is that nothing here wraps. *)
		WHILE bits > 0 DO
			IF bits > 16 THEN
				IF ~BigMulAdd( b, 10000H, 0 ) THEN  RETURN FALSE  END;
				DEC( bits, 16 )
			ELSE
				IF ~BigMulAdd( b, PowerTwo( bits ), 0 ) THEN  RETURN FALSE  END;
				bits := 0
			END
		END;
		IF words > 0 THEN
			IF b.n + words > BigWords THEN  RETURN FALSE  END;
			FOR i := b.n - 1 TO 0 BY -1 DO  b.w[i + words] := b.w[i]  END;
			FOR i := 0 TO words - 1 DO  b.w[i] := 0  END;
			INC( b.n, words )
		END;
		RETURN TRUE
	END BigShiftLeft;

	(** b := b DIV 2^bits, answering whether anything was lost. *)
	PROCEDURE BigShiftRight( VAR b: Big;  bits: SIGNED32 ): BOOLEAN;
	VAR words, i: SIGNED32;  lost: BOOLEAN;
	BEGIN
		lost := FALSE;
		words := bits DIV 32;  bits := bits MOD 32;
		IF words > 0 THEN
			FOR i := 0 TO words - 1 DO
				IF (i < b.n) & (b.w[i] # 0) THEN  lost := TRUE  END
			END;
			FOR i := 0 TO b.n - words - 1 DO  b.w[i] := b.w[i + words]  END;
			DEC( b.n, words );
			IF b.n < 0 THEN  b.n := 0  END
		END;
		WHILE bits > 0 DO
			IF bits > 16 THEN
				IF BigDiv( b, 10000H ) # 0 THEN  lost := TRUE  END;
				DEC( bits, 16 )
			ELSE
				IF BigDiv( b, PowerTwo( bits ) ) # 0 THEN  lost := TRUE  END;
				bits := 0
			END
		END;
		WHILE (b.n > 0) & (b.w[b.n - 1] = 0) DO  DEC( b.n )  END;
		RETURN lost
	END BigShiftRight;

	PROCEDURE BigBits( CONST b: Big ): SIGNED32;
	VAR top: SIGNED64;  bits: SIGNED32;
	BEGIN
		IF b.n = 0 THEN  RETURN 0  END;
		top := b.w[b.n - 1];  bits := 0;
		WHILE top > 0 DO  INC( bits );  top := top DIV 2  END;
		RETURN (b.n - 1) * 32 + bits
	END BigBits;

	PROCEDURE BigInteger( CONST b: Big ): SIGNED64;
	VAR i: SIGNED32;  value: SIGNED64;
	BEGIN
		value := 0;
		FOR i := b.n - 1 TO 0 BY -1 DO  value := value * Word + b.w[i]  END;
		RETURN value
	END BigInteger;

	(**	r := d * 2^exp2, rounded to binary64 once and only once; sticky says that something
		non-zero was already dropped below d. FALSE on overflow.

		How many bits the mantissa may keep is not always 53: under 2^-1022 the exponent cannot
		go any lower and the mantissa loses a bit for every power of two below that, which is
		what a subnormal is. Rounding to 53 bits first and to the subnormal width afterwards
		rounds twice, and twice is how 2.2250738585072011E-308 -- the largest subnormal there
		is -- came out as the smallest normal number instead.
	**)
	PROCEDURE Finish( VAR d: Big;  exp2: SIGNED32;  sticky: BOOLEAN;  VAR r: FLOAT64 ): BOOLEAN;
	VAR bits, shift, biased: SIGNED32;  m, bitPattern: SIGNED64;  round: BOOLEAN;
	BEGIN
		bits := BigBits( d );
		IF bits = 0 THEN  r := 0;  RETURN TRUE  END;

		shift := bits - 53;
		IF exp2 + shift < MinExp2 THEN  shift := MinExp2 - exp2  END;	(* subnormal, or below even that *)

		IF shift > 0 THEN
			IF shift > 1 THEN
				IF BigShiftRight( d, shift - 1 ) THEN  sticky := TRUE  END
			END;
			m := BigInteger( d );
			round := ODD( m );  m := m DIV 2;
			IF round & (sticky OR ODD( m )) THEN  INC( m )  END;
			INC( exp2, shift )
		ELSE
			m := BigInteger( d );
			(* up to 53 bits, as long as there is room under the smallest exponent the type has *)
			WHILE (m < Two52) & (m # 0) & (exp2 > MinExp2) DO  m := m * 2;  DEC( exp2 )  END
		END;

		IF m = 0 THEN  r := 0;  RETURN TRUE  END;
		IF m >= Two53 THEN  m := m DIV 2;  INC( exp2 )  END;	(* the rounding carried into a new bit *)

		IF m >= Two52 THEN
			biased := exp2 + 1075;
			IF biased >= 2047 THEN  RETURN FALSE  END;
			DEC( m, Two52 )	(* the leading bit is the one that is not stored *)
		ELSE
			biased := 0		(* subnormal *)
		END;
		bitPattern := biased * Two52 + m;
		SYSTEM.PUT( ADDRESSOF( r ), bitPattern );
		RETURN TRUE
	END Finish;

	(**	The digits of a binary64, correctly rounded to `significant` of them.

		value = <digits as an integer> * 10^exponent, with exactly `significant` digits and no
		sign; a zero answers a string of zeros and exponent 0. Seventeen digits is what a
		binary64 needs to be read back as itself, and RealToString stops at sixteen -- which is
		why a symbol file could not carry a constant unchanged.

		The value is turned into its exact decimal first (a binary64 has at most 767 digits of
		one) and only then rounded, once, ties to even.
	**)
	PROCEDURE RealToDecimal*( value: FLOAT64;  significant: SIGNED32;  VAR digits: ARRAY OF CHAR;  VAR exponent: SIGNED32 );
	VAR d: Big;  m, bitPattern, chunk: SIGNED64;  biased, i, j, len, drop: SIGNED32;
		exact: ARRAY MaxDecimalDigits + 32 OF CHAR;  round, sticky, carry: BOOLEAN;
	BEGIN
		FOR i := 0 TO significant - 1 DO  digits[i] := "0"  END;
		digits[significant] := 0X;  exponent := 0;

		SYSTEM.GET( ADDRESSOF( value ), bitPattern );
		biased := SIGNED32( (bitPattern DIV Two52) MOD 2048 );
		m := bitPattern MOD Two52;
		IF biased = 2047 THEN  RETURN  END;	(* an infinity or a NaN has no decimal; the caller says so *)
		IF biased = 0 THEN
			IF m = 0 THEN  RETURN  END;	(* zero, and the sign is the caller's business *)
			exponent := MinExp2	(* held here for a moment: the binary exponent of a subnormal *)
		ELSE
			INC( m, Two52 );  exponent := biased - 1075
		END;

		BigSet( d, m );
		IF exponent >= 0 THEN
			IF ~BigShiftLeft( d, exponent ) THEN  RETURN  END;
			exponent := 0
		ELSE
			(* m * 2^-p = m * 5^p * 10^-p, and m * 5^p is exact in an integer of this width *)
			i := -exponent;
			exponent := -i;
			WHILE i > 0 DO
				chunk := FiveChunkExp;
				IF chunk > i THEN  chunk := i  END;
				IF chunk = FiveChunkExp THEN  m := FiveChunk
				ELSE
					m := 1;
					FOR j := 1 TO SIGNED32( chunk ) DO  m := m * 5  END
				END;
				IF ~BigMulAdd( d, m, 0 ) THEN  RETURN  END;
				DEC( i, SIGNED32( chunk ) )
			END
		END;

		(* the exact decimal, least significant digit first *)
		len := 0;
		WHILE d.n > 0 DO
			m := BigDiv( d, 10 );	(* the remainder is the digit *)
			exact[len] := CHR( ORD( "0" ) + SIGNED32( m ) );  INC( len )
		END;
		IF len = 0 THEN  RETURN  END;

		(* and now the other way round, most significant first *)
		IF len > significant THEN
			drop := len - significant;
			round := exact[drop - 1] >= "5";
			sticky := exact[drop - 1] > "5";
			FOR i := 0 TO drop - 2 DO
				IF exact[i] # "0" THEN  sticky := TRUE  END
			END;
			FOR i := 0 TO significant - 1 DO  digits[i] := exact[len - 1 - i]  END;
			INC( exponent, drop );
			IF round & (sticky OR ODD( ORD( digits[significant - 1] ) - ORD( "0" ) )) THEN
				(* carry the increment up through the digits *)
				i := significant - 1;  carry := TRUE;
				WHILE carry & (i >= 0) DO
					IF digits[i] = "9" THEN  digits[i] := "0";  DEC( i )
					ELSE  digits[i] := CHR( ORD( digits[i] ) + 1 );  carry := FALSE
					END
				END;
				IF carry THEN	(* all nines: one digit more, and the last one falls off *)
					digits[0] := "1";
					FOR i := 1 TO significant - 1 DO  digits[i] := "0"  END;
					INC( exponent )
				END
			END
		ELSE
			FOR i := 0 TO len - 1 DO  digits[i] := exact[len - 1 - i]  END;
			FOR i := len TO significant - 1 DO  digits[i] := "0"  END;
			DEC( exponent, significant - len )
		END;
		digits[significant] := 0X
	END RealToDecimal;

	(**	Convert a decimal literal to binary64, correctly rounded.

		digits : the significant decimal digits, 0X terminated, no sign and no point
		exponent : the power of ten they are to be multiplied by
		rest : the digits were cut short by the caller and what it dropped was not all zeros

		Returns FALSE when the value does not fit binary64; r is left alone then. A value too
		small to represent is zero and a valid conversion, the way IEEE 754 underflow is.
	*)
	PROCEDURE DecimalToReal*( CONST digits: ARRAY OF CHAR;  exponent: SIGNED32;  rest: BOOLEAN;  VAR r: FLOAT64 ): BOOLEAN;
	VAR d: Big;  first, len, i, chunk, p, shift, bits: SIGNED32;  m, value: SIGNED64;  sticky: BOOLEAN;
	BEGIN
		sticky := rest;
		first := 0;
		WHILE digits[first] = "0" DO  INC( first )  END;	(* leading zeros say nothing *)
		len := 0;
		WHILE digits[first + len] # 0X DO  INC( len )  END;
		IF len = 0 THEN  r := 0;  RETURN TRUE  END;

		IF len > BigDigits THEN	(* what is past here cannot change the value, only the rest *)
			FOR i := BigDigits TO len - 1 DO
				IF digits[first + i] # "0" THEN  sticky := TRUE  END
			END;
			INC( exponent, len - BigDigits );  len := BigDigits
		END;

		(* nowhere near the range: answer without building anything *)
		IF exponent + len > 310 THEN  RETURN FALSE  END;
		IF exponent + len < -350 THEN  r := 0;  RETURN TRUE  END;

		BigSet( d, 0 );
		i := 0;
		WHILE i < len DO
			chunk := TenChunkDigits;
			IF i + chunk > len THEN  chunk := len - i  END;
			m := 0;
			FOR bits := 0 TO chunk - 1 DO  m := m * 10 + (ORD( digits[first + i + bits] ) - ORD( "0" ))  END;
			value := 1;
			FOR bits := 1 TO chunk DO  value := value * 10  END;
			IF ~BigMulAdd( d, value, m ) THEN  RETURN FALSE  END;
			INC( i, chunk )
		END;

		IF exponent > 0 THEN
			i := exponent;
			WHILE i > 0 DO
				chunk := TenChunkDigits;
				IF chunk > i THEN  chunk := i  END;
				value := 1;
				FOR bits := 1 TO chunk DO  value := value * 10  END;
				IF ~BigMulAdd( d, value, 0 ) THEN  RETURN FALSE  END;
				DEC( i, chunk )
			END;
			RETURN Finish( d, 0, sticky, r )
		ELSIF exponent < 0 THEN
			(*	digits / 10^p = (digits / 5^p) / 2^p. The shift buys the bits the division is
				about to consume: log2(5) is under 2.33, and 64 more are left for rounding. *)
			p := -exponent;
			shift := 64 + p * 233 DIV 100 + 1;
			IF ~BigShiftLeft( d, shift ) THEN  RETURN FALSE  END;
			i := p;
			WHILE i > 0 DO
				chunk := FiveChunkExp;
				IF chunk > i THEN  chunk := i  END;
				IF chunk = FiveChunkExp THEN  value := FiveChunk
				ELSE
					value := 1;
					FOR bits := 1 TO chunk DO  value := value * 5  END
				END;
				IF BigDiv( d, value ) # 0 THEN  sticky := TRUE  END;
				DEC( i, chunk )
			END;
			RETURN Finish( d, -shift - p, sticky, r )
		ELSE
			RETURN Finish( d, 0, sticky, r )
		END
	END DecimalToReal;

	PROCEDURE InitHL;
	VAR i: ADDRESS;  dmy: SIGNED16;  littleEndian: BOOLEAN;
	BEGIN
		dmy := 1;  i := ADDRESSOF( dmy );
		SYSTEM.GET( i, littleEndian );   (* indirection via i avoids warning on SUN cc -O *)
		IF littleEndian THEN  H := 4;  L := 0  ELSE  H := 0;  L := 4  END
	END InitHL;

BEGIN
	InitHL
END RealConversions.

