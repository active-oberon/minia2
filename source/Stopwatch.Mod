MODULE Stopwatch;
IMPORT PrecisionTimer;

CONST TicksPerMillisecond = Counter(10000);
CONST TicksPerSecond = TicksPerMillisecond * 1000;
CONST TicksPerMinute = TicksPerSecond * 60;
CONST TicksPerHour = TicksPerMinute * 60;

VAR Frequency- := PrecisionTimer.GetFrequency(): Counter;
VAR TicksDivFrequency := FLOAT64(TicksPerSecond) / Frequency: FLOAT64;

TYPE
	Counter* = PrecisionTimer.Counter;

	Ref* = POINTER TO T;
	T* = RECORD
		elapsed, started: Counter;
		isAlive-: BOOLEAN;

		PROCEDURE & Reset*( );
		BEGIN
			elapsed := 0;
			started := 0;
			isAlive := FALSE;
		END Reset;

		PROCEDURE Start*( );
		BEGIN
			IF ~isAlive THEN
				started := PrecisionTimer.GetCounter( );
				isAlive := TRUE;
			END;
		END Start;

		PROCEDURE Restart*( );
		BEGIN
			started := PrecisionTimer.GetCounter( );
			elapsed := 0;
			isAlive := TRUE;
		END Restart;

		PROCEDURE StartNew*( ): T;
		BEGIN
			RESULT.Start( );
			RETURN RESULT;
		END StartNew;

		PROCEDURE StartNewRef*( ): Ref;
		BEGIN
			RESULT := NEW Ref();
			RESULT.Start( );
			RETURN RESULT;
		END StartNewRef;

		PROCEDURE Stop*( );
		BEGIN
			VAR current := PrecisionTimer.GetCounter( );
			IF isAlive THEN
				INC( elapsed, current - started );
				IF elapsed < 0 THEN
					elapsed := 0;
				END;
				isAlive := FALSE;
			END;
		END Stop;

		PROCEDURE Elapsed*( ): Counter;
		BEGIN
			RETURN ENTIERH( ElapsedTicks( ) * TicksDivFrequency + 0.5 );
		END Elapsed;

		PROCEDURE ElapsedReal*( ): FLOAT64;
		BEGIN
			RETURN ElapsedTicks( ) * TicksDivFrequency;
		END ElapsedReal;

		PROCEDURE ElapsedString*( ): ARRAY 32 OF CHAR;
		BEGIN
			VAR t:= ENTIERH( ElapsedTicks( ) * TicksDivFrequency);
			ToString(t, RESULT);
			RETURN RESULT;
		END ElapsedString;

		PROCEDURE ElapsedMilliseconds*( ): Counter;
		BEGIN
			RETURN ENTIERH( ElapsedTicks( ) * TicksDivFrequency + 0.5 ) DIV TicksPerMillisecond;
		END ElapsedMilliseconds;

		PROCEDURE ElapsedTicks*( ): Counter;
		BEGIN
			VAR current := PrecisionTimer.GetCounter( );
			IF isAlive THEN
				RETURN elapsed + ( current - started );
			END;
			RETURN elapsed;
		END ElapsedTicks;

    END (* T *);

	PROCEDURE Append( v: SIGNED32; len: SIZE; VAR s: ARRAY OF CHAR; VAR pos: SIZE );
	VAR i: SIZE;
	BEGIN
		FOR i := 1 TO len DO
			s[ pos + len - i ] := CHR( ORD ( "0" ) + v MOD 10 );
			v := v DIV 10;
		END;
		INC( pos, len );
	END Append;

	(* ToString writes a duration, so the hours do not wrap at a day and the sign is kept. *)
	PROCEDURE ToString*( aTicks: Counter; VAR date: ARRAY OF CHAR );
	VAR i, len: SIZE; hours: Counter;
	BEGIN
		i := 0;
		IF aTicks < 0 THEN date[ i ] := "-"; INC( i ); aTicks := -aTicks; END;
		hours := aTicks DIV TicksPerHour; len := 2;
		WHILE hours DIV 10 >= 10 DO INC( len ); hours := hours DIV 10; END;
		Append( SIGNED32( aTicks DIV TicksPerHour ), len, date, i ); date[ i ] := ":"; INC( i );
		Append( SIGNED32( aTicks DIV TicksPerMinute MOD 60 ), 2, date, i ); date[ i ] := ":"; INC( i );
		Append( SIGNED32( aTicks DIV TicksPerSecond MOD 60 ), 2, date, i ); date[ i ] := "."; INC( i );
		Append( SIGNED32( aTicks MOD TicksPerSecond ), 7, date, i ); date[ i ] := 0X;
	END ToString;

	(* ToStringReal rounds once and defers -- rounding each field on its own made it disagree with ToString by a whole unit. *)
	PROCEDURE ToStringReal*( aTicks: FLOAT64; VAR date: ARRAY OF CHAR );
	BEGIN
		(* ENTIERH floors, so a negative count is rounded by its magnitude and ToString puts the sign back. *)
		IF aTicks < 0 THEN ToString( -ENTIERH( -aTicks + 0.5 ), date ); ELSE ToString( ENTIERH( aTicks + 0.5 ), date ); END;
	END ToStringReal;
END Stopwatch.

System.FreeDownTo Stopwatch~