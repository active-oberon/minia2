MODULE Hello;
IMPORT KernelLog;

	(* `ob run Hello.Mod` invokes the exported command Do. *)
	PROCEDURE Do*;
	BEGIN
		KernelLog.String("Hello from A2 / Active Oberon!"); KernelLog.Ln
	END Do;

END Hello.
