MODULE JsonDemo;
(* Parse a JSON string, read a field, then build and serialize a value.
   Build & run:  ob build JsonDemo.Mod -o jsondemo && ./jsondemo  *)
IMPORT JSON, Strings, KernelLog;

	PROCEDURE Do*;
	VAR v, item: JSON.Value; o, out: JSON.Object; a: JSON.Array; ok: BOOLEAN;
		src: ARRAY 128 OF CHAR;
	BEGIN
		src := '{"name":"minia2","tags":["a2","oberon"],"stars":42}';
		ok := JSON.Parse(src, v);
		IF ~ok THEN KernelLog.String("parse failed"); KernelLog.Ln; RETURN END;

		o := v(JSON.Object);
		item := o.Get("name");
		KernelLog.String("name = "); KernelLog.String(item(JSON.String).value^); KernelLog.Ln;

		out := JSON.NewObject();
		out.Set("greeting", JSON.NewString("hello"));
		a := JSON.NewArray(); a.Add(JSON.NewNumber(1)); a.Add(JSON.NewNumber(2));
		out.Set("nums", a);
		KernelLog.String("built = "); KernelLog.String(JSON.ToString(out)^); KernelLog.Ln
	END Do;

END JsonDemo.
