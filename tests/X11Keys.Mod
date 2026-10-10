MODULE X11Keys;

IMPORT Inputs, KernelLog;

TYPE
	Keyboard = OBJECT (Inputs.Sink)
	VAR pressed, released: SET;
		lost, gained: BOOLEAN;

		PROCEDURE Handle*(VAR message: Inputs.Message);
		VAR bit: SIGNED32;
		BEGIN {EXCLUSIVE}
			IF message IS Inputs.FocusMsg THEN
				WITH message: Inputs.FocusMsg DO
					IF message.focused THEN
						gained := TRUE
					ELSE
						lost := TRUE
					END
				END
			ELSIF message IS Inputs.KeyboardMsg THEN
				WITH message: Inputs.KeyboardMsg DO
					bit := -1;
					CASE message.keysym OF
						077H:
							bit := 0
						| Inputs.KsUp:
							bit := 1
						| Inputs.KsShiftL:
							bit := 2
						| Inputs.KsEscape:
							bit := 3
					ELSE
					END;
					IF bit >= 0 THEN
						IF Inputs.Release IN message.flags THEN
							ASSERT(bit IN pressed);
							INCL(released, bit)
						ELSE
							INCL(pressed, bit)
						END
					END
				END
			END
		END Handle;

		PROCEDURE Wait;
		BEGIN {EXCLUSIVE}
			AWAIT((released = {0..3}) & lost & gained);
			ASSERT(pressed = {0..3})
		END Wait;
	END Keyboard;

PROCEDURE Do*;
VAR keyboard: Keyboard;
BEGIN
	NEW(keyboard);
	Inputs.keyboard.Register(keyboard);
	KernelLog.String("X11Keys: ready");
	KernelLog.Ln;
	keyboard.Wait;
	Inputs.keyboard.Unregister(keyboard);
	KernelLog.String("X11Keys: key release and focus messages passed");
	KernelLog.Ln
END Do;

END X11Keys.
