MODULE GCProbe;	(* how far a plain collection loop gets *)
IMPORT Commands, Kernel, Streams;

TYPE Node = POINTER TO RECORD next: Node; pad: ARRAY 64 OF CHAR END;

VAR live: Node;

PROCEDURE Run*(context: Commands.Context);
VAR out: Streams.Writer; i, j: SIGNED32; n: Node;
BEGIN
	out := context.out;
	NEW(live); 
	FOR i := 1 TO 20 DO
		FOR j := 1 TO 200 DO NEW(n); n.next := live END;		(* garbage *)
		Kernel.GC;
		out.String("round "); out.Int(i, 0); out.Ln; out.Update
	END;
	out.String("GCProbe: passed"); out.Ln; out.Update
END Run;

END GCProbe.
