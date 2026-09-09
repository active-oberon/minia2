MODULE Blink;	(** AUTHOR "Andrii Puhachenko"; PURPOSE "The smallest program that makes a board do something physical"; *)

(*
	An LED on a pin, ten times on and off:

		ob run Blink.Mod                  # on this machine, if it has a gpiochip
		ob build -t a64 Blink.Mod         # a Raspberry Pi OS 64-bit binary, copied to the board

	`Pin` below is a BCM number, which is what the kernel counts lines in and what the pin diagrams
	call GPIO17 -- physical pin 11 on the header. Change it here rather than on the command line: a
	program the SDK links is entered through Commands.Call, so it is handed no arguments at all.

	Reading is the same shape: `GPIO.Line(0, Pin, GPIO.Input + GPIO.PullUp, "button")` and then
	`line.Read(values)`, where `0 IN values` is that pin -- a button wired to ground reads low
	while it is held.
*)

IMPORT Commands, Objects, GPIO;

CONST
	Pin = 17;
	Times = 10;
	Half = 250;						(* milliseconds of on, and of off *)

	(* `ob run Blink.Mod` invokes the exported command Do. *)
	PROCEDURE Do* (context: Commands.Context);
	VAR led: GPIO.Lines;  i: SIGNED32;
	BEGIN
		led := GPIO.Line(0, Pin, GPIO.Output, "blink");
		IF led = NIL THEN
			context.error.String("Blink: chip 0 line "); context.error.Int(Pin, 0);
			context.error.String(" is not to be had, errno "); context.error.Int(GPIO.error, 0);
			context.error.Ln;
			RETURN
		END;

		FOR i := 1 TO Times DO
			IF ~led.Write({0}) THEN context.error.String("Blink: the kernel refused a write"); context.error.Ln; RETURN END;
			Objects.Sleep(Half);
			IF ~led.Write({}) THEN context.error.String("Blink: the kernel refused a write"); context.error.Ln; RETURN END;
			Objects.Sleep(Half)
		END;

		led.Close;						(* without this the line stays ours until the process ends *)
		context.out.String("Blink: line "); context.out.Int(Pin, 0);
		context.out.String(" went on and off "); context.out.Int(Times, 0);
		context.out.String(" times"); context.out.Ln
	END Do;

END Blink.
