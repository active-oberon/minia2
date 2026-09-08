MODULE BindThingProbe;	(* the same answers as tests/bind-thing.c prints, through the module ob bind wrote *)
IMPORT CThing, KernelLog;

	PROCEDURE Say(CONST key: ARRAY OF CHAR; value: SIGNED64);
	BEGIN
		KernelLog.String(key); KernelLog.Char("="); KernelLog.Int(value, 0); KernelLog.Ln
	END Say;

	(* BindThingProbe.Do prints what the binding says, for tests/bind-check.sh to diff against C. *)
	PROCEDURE Do*;
	VAR t: CThing.thing; s: CThing.signs;
	BEGIN
		IF ~CThing.Available THEN KernelLog.String("library not loaded"); KernelLog.Ln; RETURN END;
		Say("sizeof_thing", SIZEOF(CThing.thing));
		Say("offset_payload", ADDRESSOF(t.payload) - ADDRESSOF(t));
		Say("offset_tail", ADDRESSOF(t.tail) - ADDRESSOF(t));
		Say("sizeof_union", SIZEOF(CThing.either));
		Say("sizeof_signs", SIZEOF(CThing.signs));
		Say("THING_BOTH", CThing.THING_BOTH);

		(* the union: written here and read in C, then the other way round *)
		CThing.either_i_set(t.payload, 4242);
		Say("reads_union", CThing.thing_payload_i(ADDRESSOF(t)));
		CThing.thing_payload_set(ADDRESSOF(t), 1234);
		Say("reads_union_back", CThing.either_i(t.payload));

		(* the bit fields, both directions *)
		t.bits0 := 0;
		CThing.thing_flag_a_set(t, 1); CThing.thing_flag_b_set(t, 0); CThing.thing_wide_set(t, 4000);
		Say("reads_flags", CThing.thing_read_flags(ADDRESSOF(t)));
		Say("reads_wide", CThing.thing_read_wide(ADDRESSOF(t)));
		CThing.thing_set(ADDRESSOF(t), 1, 1, 777);
		Say("reads_flags_again", CThing.thing_flag_a(t) + 2 * CThing.thing_flag_b(t));
		Say("reads_wide_again", CThing.thing_wide(t));

		(* a signed bit field, whose sign the generated reader restores by hand *)
		s.bits0 := 0;
		CThing.signs_level_set(s, -5);
		Say("reads_level", CThing.signs_read_level(ADDRESSOF(s)));
		CThing.signs_set(ADDRESSOF(s), -5, 7);
		Say("reads_level_back", CThing.signs_level(s));
		Say("reads_slope_back", CThing.signs_slope(s));

		(* the wrappers over the variadic function *)
		Say("sum1", CThing.thing_sum1("i", 7));
		Say("sum2", CThing.thing_sum2("ii", 10, 20));
		Say("sum3", CThing.thing_sum3("iii", 100, 200, 300))
	END Do;

END BindThingProbe.
