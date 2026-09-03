MODULE Time;
(**
	AUTHOR "Andrii Puhachenko";
	PURPOSE "Two clocks the library did not have: one that never goes backwards, and one that says UTC";
	LIMITATIONS
		"- no time zone database: Zone reports the offset the host is running in, which is what
		   Clock reads from the system for this instant, and that is all -- naming a zone or
		   asking what a past date's offset was needs the IANA database and is not here;
		 - leap seconds are POSIX's, i.e. ignored: a Unix time is 86400 seconds a day."
*)
(*	Both clocks were reachable already and neither was usable. PrecisionTimer.GetCounter is
	monotonic on both hosts but counts nanoseconds on Unix and QueryPerformanceCounter ticks on
	Windows, so every caller carried its own division; and Dates.Now is the wall clock in local
	time, with nothing saying which local. Here the monotonic clock has one unit everywhere and
	the wall clock has an origin: 1970-01-01 UTC. *)

IMPORT Clock, Dates, PrecisionTimer;

CONST
	Second* = 1000000000;			(** nanoseconds, the unit of every duration here *)
	Millisecond* = 1000000;
	Microsecond* = 1000;
	SecondsPerDay = 86400;

TYPE
	Duration* = SIGNED64;			(** nanoseconds *)
	Instant* = SIGNED64;			(** nanoseconds on the monotonic clock; only differences mean anything *)

VAR
	frequency: PrecisionTimer.Counter;

(** A clock that only goes forward. Its zero is unspecified -- subtract two readings. *)
PROCEDURE Monotonic*(): Instant;
VAR c: PrecisionTimer.Counter;
BEGIN
	c := PrecisionTimer.GetCounter();
	IF frequency = Second THEN RETURN c END;		(* Unix: already nanoseconds *)
	IF frequency <= 0 THEN RETURN 0 END;
	(*	c * 1e9 overflows a 64-bit counter after a few seconds at gigahertz frequencies, so the
		whole seconds and the remainder are scaled apart. *)
	RETURN (c DIV frequency) * Second + (c MOD frequency) * Second DIV frequency
END Monotonic;

(** How long since t, in nanoseconds. *)
PROCEDURE Since*(t: Instant): Duration;
BEGIN
	RETURN Monotonic() - t
END Since;

PROCEDURE Milliseconds*(d: Duration): SIGNED64;
BEGIN
	RETURN d DIV Millisecond
END Milliseconds;

PROCEDURE Seconds*(d: Duration): FLOAT64;
BEGIN
	RETURN d / FLOAT64(Second)
END Seconds;

(** The offset the host is running in, in minutes east of UTC. *)
PROCEDURE Zone*(): SIGNED32;
VAR time, date: SIGNED32;
BEGIN
	Clock.Get(time, date);		(* which is also what refreshes Clock.tz *)
	RETURN Clock.tz
END Zone;

(*	Days from 1970-01-01 to the given date, by Howard Hinnant's civil algorithm: the year is
	shifted to start in March so that the leap day is the last day of it and no month table is
	needed. Valid for any year the record can hold, before 1970 included. *)
PROCEDURE DaysFromCivil(y, m, d: SIGNED64): SIGNED64;
VAR era, yoe, doy, doe: SIGNED64;
BEGIN
	IF m <= 2 THEN DEC(y) END;
	IF y >= 0 THEN era := y DIV 400 ELSE era := (y - 399) DIV 400 END;
	yoe := y - era * 400;								(* 0..399 *)
	IF m > 2 THEN doy := (153 * (m - 3) + 2) DIV 5 + d - 1
	ELSE doy := (153 * (m + 9) + 2) DIV 5 + d - 1
	END;
	doe := yoe * 365 + yoe DIV 4 - yoe DIV 100 + doy;	(* 0..146096 *)
	RETURN era * 146097 + doe - 719468
END DaysFromCivil;

PROCEDURE CivilFromDays(z: SIGNED64; VAR y, m, d: SIGNED32);
VAR era, doe, yoe, doy, mp, yy: SIGNED64;
BEGIN
	INC(z, 719468);
	IF z >= 0 THEN era := z DIV 146097 ELSE era := (z - 146096) DIV 146097 END;
	doe := z - era * 146097;							(* 0..146096 *)
	yoe := (doe - doe DIV 1460 + doe DIV 36524 - doe DIV 146096) DIV 365;
	yy := yoe + era * 400;
	doy := doe - (365 * yoe + yoe DIV 4 - yoe DIV 100);
	mp := (5 * doy + 2) DIV 153;						(* 0..11, March is 0 *)
	d := SIGNED32(doy - (153 * mp + 2) DIV 5 + 1);
	IF mp < 10 THEN m := SIGNED32(mp + 3) ELSE m := SIGNED32(mp - 9) END;
	IF m <= 2 THEN INC(yy) END;
	y := SIGNED32(yy)
END CivilFromDays;

(** Seconds since 1970-01-01 00:00 UTC for a date that is already UTC. *)
PROCEDURE ToUnix*(dt: Dates.DateTime): SIGNED64;
BEGIN
	RETURN DaysFromCivil(dt.year, dt.month, dt.day) * SecondsPerDay
		+ SIGNED64(dt.hour) * 3600 + SIGNED64(dt.minute) * 60 + dt.second
END ToUnix;

(** The UTC date of a Unix time. *)
PROCEDURE FromUnix*(t: SIGNED64): Dates.DateTime;
VAR dt: Dates.DateTime; days, rest: SIGNED64;
BEGIN
	days := t DIV SecondsPerDay;			(* DIV floors, which is what a time before 1970 needs *)
	rest := t - days * SecondsPerDay;
	CivilFromDays(days, dt.year, dt.month, dt.day);
	dt.hour := SIGNED32(rest DIV 3600);
	dt.minute := SIGNED32(rest DIV 60 MOD 60);
	dt.second := SIGNED32(rest MOD 60);
	RETURN dt
END FromUnix;

(** Now, as seconds since 1970-01-01 UTC. Dates.Now is the same instant in local time. *)
PROCEDURE Unix*(): SIGNED64;
BEGIN
	RETURN ToUnix(Dates.Now()) - SIGNED64(Zone()) * 60
END Unix;

(** Now, as a UTC date -- which is Dates.Now() with the host's offset taken off. *)
PROCEDURE UTC*(): Dates.DateTime;
BEGIN
	RETURN FromUnix(Unix())
END UTC;

(** A UTC date in the host's local time, and back. *)
PROCEDURE ToLocal*(dt: Dates.DateTime): Dates.DateTime;
BEGIN
	RETURN FromUnix(ToUnix(dt) + SIGNED64(Zone()) * 60)
END ToLocal;

PROCEDURE FromLocal*(dt: Dates.DateTime): Dates.DateTime;
BEGIN
	RETURN FromUnix(ToUnix(dt) - SIGNED64(Zone()) * 60)
END FromLocal;

BEGIN
	frequency := PrecisionTimer.GetFrequency()
END Time.
