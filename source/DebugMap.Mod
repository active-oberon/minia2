MODULE DebugMap; (** AUTHOR "Andrii Puhachenko"; PURPOSE "PC to source position, kept from the compilation that wrote the code"; *)

(*	The backend already computes what a debugger needs: FoxBinaryCode.Section.labels maps a code
	offset to the source position it was generated from. It is thrown away with the compiler's data
	structures, and only Backend.FindPC ever looked at it -- by compiling the module a second time.

	Here it is kept instead. Compiler.Generated hands over every module the backend produced, while
	its binary sections are still alive; a debugger in the same process (ob run, ob dap) then asks
	PositionOf where the code under a PC was written. Nothing is written to the object file, so no
	format changes and no bootstrap risk.

	ponytail: the map lives only in the process that compiled the code. Persisting it into the
	references section is the upgrade path -- needed the day a debugger has to attach to a program
	it did not just build. *)

IMPORT Compiler, Formats := FoxFormats, Sections := FoxSections, IntermediateCode := FoxIntermediateCode,
	BinaryCode := FoxBinaryCode, ObjectFile, Reflection;

CONST
	MaxName* = 256;

TYPE
	Name* = ARRAY MaxName OF CHAR;

	(** One place in the code, and the place in the source it came from. *)
	Site* = RECORD
		offset-: SIZE;             (* bytes from the start of the procedure *)
		line-: SIGNED32;           (* 0 when the module was compiled without --lineNumbers *)
		position-: SIGNED64        (* bytes from the start of the source file *)
	END;

	Procedure* = POINTER TO RECORD
		name-: Name;               (* "Module.Procedure", spelled as Reflection spells it *)
		source-: Name;             (* the file it was compiled from *)
		sites-: POINTER TO ARRAY OF Site;  (* ascending by offset *)
		next-: Procedure
	END;

VAR
	procedures: Procedure;

	(* Length walks the label list, which the backend builds in reverse. *)
	PROCEDURE Length (label: BinaryCode.LabelList): SIZE;
	VAR n: SIZE;
	BEGIN
		n := 0; WHILE label # NIL DO INC(n); label := label.prev END;
		RETURN n
	END Length;

	PROCEDURE Take (binary: BinaryCode.Section; CONST name, source: ARRAY OF CHAR);
	VAR p: Procedure; label: BinaryCode.LabelList; i, n, bits: SIZE;
	BEGIN
		n := Length(binary.labels);
		IF n = 0 THEN RETURN END;
		bits := binary.os.unit;
		NEW(p); COPY(name, p.name); COPY(source, p.source);
		NEW(p.sites, n);
		label := binary.labels; i := n - 1;
		WHILE label # NIL DO             (* the list is newest first, so it fills the array backwards *)
			p.sites[i].offset := label.offset * bits DIV 8;
			p.sites[i].line := SIGNED32(label.position.line);
			p.sites[i].position := label.position.start;
			label := label.prev; DEC(i)
		END;
		p.next := procedures; procedures := p
	END Take;

(** Generated keeps the line table of a module the backend has just produced. Install it in Compiler.Generated. *)
PROCEDURE Generated* (generated: Formats.GeneratedModule);
VAR module: Sections.Module; section: Sections.Section; intermediate: IntermediateCode.Section;
	i: SIZE; name, source: Name;
BEGIN
	IF ~(generated IS Sections.Module) THEN RETURN END;
	module := generated(Sections.Module);
	COPY(module.module.sourceName, source);
	FOR i := 0 TO module.allSections.Length() - 1 DO
		section := module.allSections.GetSection(i);
		IF section.IsCode() & (section IS IntermediateCode.Section) THEN
			intermediate := section(IntermediateCode.Section);
			IF intermediate.resolved # NIL THEN
				ObjectFile.SegmentedNameToString(section.name, name);
				Take(intermediate.resolved, name, source)
			END
		END
	END
END Generated;

(** Find returns what was kept for a procedure, NIL if the module was not compiled with --debug. *)
PROCEDURE Find* (CONST name: ARRAY OF CHAR): Procedure;
VAR p: Procedure;
BEGIN
	p := procedures;
	WHILE (p # NIL) & (p.name # name) DO p := p.next END;
	RETURN p
END Find;

(** PositionOf answers where the code under pc was written. *)
PROCEDURE PositionOf* (pc: ADDRESS; VAR source: ARRAY OF CHAR; VAR line: SIGNED32; VAR position: SIGNED64): BOOLEAN;
VAR p: Procedure; name: Name; start: ADDRESS; offset: SIZE; i: SIZE;
BEGIN
	Reflection.GetProcedureName(pc, name, start);
	IF start = 0 THEN RETURN FALSE END;
	p := Find(name);
	IF p = NIL THEN RETURN FALSE END;
	offset := pc - start;
	i := 0;   (* the last site at or before the offset is the statement being executed *)
	WHILE (i + 1 < LEN(p.sites)) & (p.sites[i + 1].offset <= offset) DO INC(i) END;
	COPY(p.source, source); line := p.sites[i].line; position := p.sites[i].position;
	RETURN TRUE
END PositionOf;

(** Forget drops everything kept so far. *)
PROCEDURE Forget*;
BEGIN
	procedures := NIL
END Forget;

BEGIN
	Compiler.Generated := Generated
END DebugMap.
