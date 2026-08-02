(**
	AUTHOR: Alexey Morozov
	PURPOSE: high precision timer support for Unix platforms
*)
MODULE PrecisionTimer;

IMPORT
	Unix, KernelLog;

TYPE
	Counter* = SIGNED64; (** Timer counter value type *)

CONST
	(*
		The IDs of the various system clocks (for POSIX.1b interval timers):
	*)
	CLOCK_REALTIME = 0;
	CLOCK_MONOTONIC = 1;
	CLOCK_PROCESS_CPUTIME_ID = 2;
	CLOCK_THREAD_CPUTIME_ID = 3;
	CLOCK_MONOTONIC_RAW = 4;
	CLOCK_REALTIME_COARSE = 5;
	CLOCK_MONOTONIC_COARSE = 6;
	CLOCK_BOOTTIME = 7;
	CLOCK_REALTIME_ALARM = 8;
	CLOCK_BOOTTIME_ALARM = 9;

TYPE
	Timespec = RECORD
		sec: LONGINTEGER;
		nsec: SIGNED32;
	END;

VAR
	clock_gettime: PROCEDURE{C}(clk_id: SIGNED32; CONST tp: Timespec): SIGNED32;
	clock_getres: PROCEDURE{C}(clk_id: SIGNED32; CONST res: Timespec): SIGNED32;

	(*! It is preferable to use CLOCK_MONOTONIC_RAW (not influenced by system time adjustments),
		but for some reason CLOCK_MONOTONIC is ~3 times faster
	*)
	clockType := CLOCK_MONOTONIC: SIGNED32; (* timer clock type *)
	frequency: Counter; (* timer frequency in Hz *)

	(**
		Query timer counter in ticks
	*)
	PROCEDURE GetCounter*(): Counter;
	VAR t: Timespec;
	BEGIN
		IF clock_gettime(clockType, t) = 0 THEN
			RETURN SIGNED64(t.sec)*1000000000 + SIGNED64(t.nsec);
		ELSE
			RETURN 0;
		END;
	END GetCounter;

	(**
		Query timer tick frequency in Hz
	*)
	PROCEDURE GetFrequency*(): Counter;
	VAR t: Timespec;
	BEGIN
		IF clock_getres(clockType, t) = 0 THEN
			(*! a workaround for not known actual clock frequency *)
			RETURN ENTIERH(1.0D9 / t.nsec + 0.5D0);
		ELSE
			RETURN 0;
		END;
	END GetFrequency;

	(*	Resolves one of the POSIX clock functions. Before glibc 2.17 they are not in libc but in
		librt, which `Unix` has then already opened for its own pair of pointers; this module keeps
		its own, because it declares them with the argument types it wants rather than as addresses,
		so the lookup has to be repeated here rather than the pointer copied. *)
	PROCEDURE Resolve(CONST name: ARRAY OF CHAR; address: ADDRESS): BOOLEAN;
	BEGIN
		IF Unix.DlsymOptional(Unix.libc, name, address) THEN RETURN TRUE END;
		IF Unix.librt = 0 THEN RETURN FALSE END;
		RETURN Unix.DlsymOptional(Unix.librt, name, address)
	END Resolve;

	PROCEDURE InitMod;
	VAR frequency: Counter;
	BEGIN
		ASSERT(Resolve("clock_gettime", ADDRESSOF(clock_gettime)));
		ASSERT(Resolve("clock_getres", ADDRESSOF(clock_getres)));

		KernelLog.String("PrecisionTimer: timer tick frequency is "); KernelLog.Int(GetFrequency(),0); KernelLog.String(" Hz"); KernelLog.Ln;
	END InitMod;

BEGIN
	InitMod;
END PrecisionTimer.

System.Free PrecisionTimer ~