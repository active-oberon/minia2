(** AUTHOR "Andrii Puhachenko"; PURPOSE "A queue that waits: what one activity hands to another" *)

MODULE Channels(TYPE T);

(*	A container is not what one activity needs to hand something to another -- waiting is. This is
	the waiting, once, so that a program which reads a keyboard in one object and a child in
	another does not write it again: put something in and the putting waits while it is full, take
	something out and the taking waits while it is empty, close it and both stop waiting.

	The waiting is AWAIT and nothing else. There is no polling here, no timer, and no condition
	variable to remember to signal: the language wakes whoever is waiting when what they wait for
	becomes true, which is why this module is thirty lines and not a hundred.

	It is a parametric module, so a channel carries one type and the compiler knows which:

		IMPORT Events := Channels(Event);
		VAR arriving: Events.Channel;

	Closing is the only way to end it. A reader is told by Get returning FALSE, which is what an
	object waiting for a source that has gone away must be told -- there is nothing else to
	cancel, and nothing to remember to cancel. *)

CONST
	Room* = 64;                        (** how much may pile up before a writer waits its turn *)

TYPE
	Channel* = OBJECT
	VAR
		item: ARRAY Room OF T;
		in, out: SIGNED32;
		closed: BOOLEAN;

		PROCEDURE &Init*;
		BEGIN in := 0; out := 0; closed := FALSE
		END Init;

		(** Hand something over, waiting while there is no room. FALSE once it has been closed. *)
		PROCEDURE Put* (CONST x: T): BOOLEAN;
		BEGIN {EXCLUSIVE}
			AWAIT((in - out < Room) OR closed);
			IF closed THEN RETURN FALSE END;
			item[in MOD Room] := x; INC(in);
			RETURN TRUE
		END Put;

		(** Take the next thing, waiting for one. FALSE when it is closed and empty. *)
		PROCEDURE Get* (VAR x: T): BOOLEAN;
		BEGIN {EXCLUSIVE}
			AWAIT((in # out) OR closed);
			IF in = out THEN RETURN FALSE END;
			x := item[out MOD Room]; INC(out);
			RETURN TRUE
		END Get;

		(** How much is waiting to be taken. *)
		PROCEDURE Waiting* (): SIGNED32;
		BEGIN {EXCLUSIVE} RETURN in - out
		END Waiting;

		(** Nothing more will be put in. Whoever waits is told, and stops waiting. *)
		PROCEDURE Close*;
		BEGIN {EXCLUSIVE} closed := TRUE
		END Close;

	END Channel;

END Channels.
