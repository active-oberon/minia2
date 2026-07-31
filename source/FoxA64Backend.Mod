MODULE FoxA64Backend; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "backend for AArch64 (ARMv8-A, A64 instruction set)"; *)

(*
	Phase 0 of the AArch64 port: the wiring, without a code generator.

	What is here is everything the compiler needs in order to reach code generation for an A64
	target -- the target description (Global.System), the AAPCS64 rule for which parameters
	travel in registers, and the object file format -- so that a module compiled with
	-p=UnixA64 runs through the front end, the semantic checker and the intermediate backend,
	and stops with one explicit error at the point where machine code would be emitted.

	What is deliberately not here: FoxA64InstructionSet, FoxA64Assembler, and the code
	generator that turns intermediate code into A64 instructions.

	Frame layout the target description assumes, which is the one the standard A64 prologue
	(STP X29, X30, [SP, #-16]!  /  MOV X29, SP) produces:

						param n
						...
						param 1
		FP+16 ->	first parameter passed on the stack
		FP+8 ->	old LR (X30)
		FP ->		old FP (X29)
		FP-8 ->	local 1
						...
						spill 1
						...

	So the first stack-passed parameter sits two words above the frame pointer, which is what
	offsetFirstParameter = 128 bits says -- the same as AMD64, and the constant the shared
	SysV prologue in FoxIntermediateBackend relies on.
*)

IMPORT
	Basic := FoxBasic, SyntaxTree := FoxSyntaxTree, Global := FoxGlobal, Backend := FoxBackend,
	Sections := FoxSections, IntermediateCode := FoxIntermediateCode,
	IntermediateBackend := FoxIntermediateBackend, SemanticChecker := FoxSemanticChecker,
	Formats := FoxFormats, Diagnostics, Streams, Options, ObjectFileFormat := FoxGenericObjectFile;

CONST
	(* Physical register numbers. Backend-private: the intermediate code only carries the
		number back to us through IntermediateCode.InitParameterRegisterClass, so the
		numbering has to agree with this module and with nothing else.

		X0..X30 are the general purpose registers, X30 being the link register. Number 31
		encodes SP or the zero register depending on the instruction, which is an encoding
		matter rather than an allocation one, so it is named twice here. V0..V31 are the
		SIMD and floating point registers. *)
	X0* = 0;  LR* = 30;  SP* = 31;  ZR* = 31;
	V0* = 32;

	(* AAPCS64 5.4.2: the first eight arguments of each class travel in registers *)
	NumIntegerParameterRegisters = 8;
	NumFloatParameterRegisters = 8;

TYPE

	BackendA64* = OBJECT (IntermediateBackend.IntermediateBackend)
	VAR
		system: Global.System;
		intParameterIndex, floatParameterIndex: INTEGER;

		PROCEDURE & InitBackendA64;
		BEGIN
			InitIntermediateBackend;
			system := NIL;
			intParameterIndex := 0;
			floatParameterIndex := 0;
			SetHasLinkRegister;
			SetName("A64");
		END InitBackendA64;

		PROCEDURE Initialize*(diagnostics: Diagnostics.Diagnostics; log: Streams.Writer; flags: SET; checker: SemanticChecker.Checker; system: Global.System);
		BEGIN
			Initialize^(diagnostics, log, flags, checker, system);
		END Initialize;

		PROCEDURE GetSystem*(): Global.System;
		VAR variableOffset: INTEGER;
		BEGIN
			IF system = NIL THEN
				(*
					codeUnit, dataUnit = 8, 8
					addressSize = 64
					minVarAlign, maxVarAlign = 8, 64
					minParAlign, maxParAlign = 64, 64
					offsetFirstPar = 128  (old FP and old LR, see the frame layout above)
				*)
				IF preciseGC THEN variableOffset := -64 ELSE variableOffset := 0 END;
				NEW(system, 8, 8, 64, 8, 64, 64, 64, 128, variableOffset, cooperative);
				Global.SetDefaultDeclarations(system, 8);
				Global.SetDefaultOperators(system);
			END;
			system.SetRegisterPassCallback(CanPassInRegister);
			RETURN system
		END GetSystem;

		(** whether a whole aggregate may travel in a register rather than by address

			AAPCS64 does have a rule for this -- a homogeneous floating-point aggregate of up to
			four members goes in consecutive V registers -- but A2 passes records and arrays by
			address anyway, so nothing reaches here that the rule would apply to. Left FALSE
			until a case turns up that needs it; saying TRUE without a code generator behind it
			would only produce wrong code later.
		**)
		PROCEDURE CanPassInRegister*(type: SyntaxTree.Type): BOOLEAN;
		BEGIN
			RETURN FALSE
		END CanPassInRegister;

		PROCEDURE ResetParameterRegisters*;
		BEGIN
			intParameterIndex := 0;
			floatParameterIndex := 0;
		END ResetParameterRegisters;

		(** the AAPCS64 argument allocation, as far as the intermediate code models it

			Two independent counters, x0..x7 for everything integer or pointer shaped and
			v0..v7 for everything floating point -- the same shape as the SysV rule on AMD64
			and not the WINAPI one, where a float consumes an integer slot too.

			The counters only ever increase, which is the other half of the rule: once an
			argument of a class has gone to the stack, every later argument of that class goes
			to the stack as well, even if a register of that class fell free. AAPCS64 says this
			explicitly (NGRN and NSRN are set to 8 rather than left alone), and the shared
			caller and prologue loops in FoxIntermediateBackend do it by construction.
		**)
		PROCEDURE GetParameterRegister*(callingConvention: SyntaxTree.CallingConvention; type: IntermediateCode.Type; VAR register: INTEGER): BOOLEAN;
		BEGIN
			IF callingConvention # SyntaxTree.CCallingConvention THEN
				register := -1; RETURN FALSE
			END;

			IF type.form IN IntermediateCode.Integer THEN
				IF intParameterIndex >= NumIntegerParameterRegisters THEN
					register := -1; RETURN FALSE
				END;
				register := X0 + intParameterIndex;
				INC(intParameterIndex);
				RETURN TRUE
			ELSIF type.form = IntermediateCode.Float THEN
				IF floatParameterIndex >= NumFloatParameterRegisters THEN
					register := -1; RETURN FALSE
				END;
				register := V0 + floatParameterIndex;
				INC(floatParameterIndex);
				RETURN TRUE
			ELSE
				register := -1; RETURN FALSE
			END
		END GetParameterRegister;

		(** whether the code generator can emit an intermediate code instruction directly,
			and if not, which runtime procedure implements it instead

			TRUE throughout for now: there is no code generator to ask, and answering FALSE
			would make the intermediate backend replace the instruction with a call to a
			runtime procedure that does not exist either.
		**)
		PROCEDURE SupportedInstruction*(CONST instruction: IntermediateCode.Instruction; VAR moduleName, procedureName: ARRAY OF CHAR): BOOLEAN;
		BEGIN
			moduleName := "";
			procedureName := "";
			RETURN TRUE
		END SupportedInstruction;

		PROCEDURE SupportedImmediate*(CONST op: IntermediateCode.Operand): BOOLEAN;
		BEGIN
			RETURN TRUE
		END SupportedImmediate;

		(** intermediate code is produced; machine code is not, yet **)
		PROCEDURE ProcessIntermediateCodeModule*(intermediateCodeModule: Formats.GeneratedModule): Formats.GeneratedModule;
		VAR result: Formats.GeneratedModule;
		BEGIN
			ASSERT(intermediateCodeModule IS Sections.Module);
			result := ProcessIntermediateCodeModule^(intermediateCodeModule);

			IF ~error THEN
				Error(result.module.sourceName, Basic.invalidPosition, Basic.InvalidCode,
					"A64 code generation is not implemented (phase 0: target description only)");
			END;

			RETURN result
		END ProcessIntermediateCodeModule;

		PROCEDURE DefineOptions*(options: Options.Options);
		BEGIN
			DefineOptions^(options);
		END DefineOptions;

		PROCEDURE GetOptions*(options: Options.Options);
		BEGIN
			GetOptions^(options);
		END GetOptions;

		PROCEDURE DefaultObjectFileFormat*(): Formats.ObjectFileFormat;
		BEGIN RETURN ObjectFileFormat.Get()
		END DefaultObjectFileFormat;

		PROCEDURE DefaultSymbolFileFormat*(): Formats.SymbolFileFormat;
		BEGIN RETURN NIL
		END DefaultSymbolFileFormat;

		(** the name that lands in the intermediate code module header and in the object file **)
		PROCEDURE GetDescription*(VAR instructionSet: ARRAY OF CHAR);
		BEGIN instructionSet := "A64"
		END GetDescription;

	END BackendA64;

	(** get an instance of the A64 backend **)
	PROCEDURE Get*(): Backend.Backend;
	VAR result: BackendA64;
	BEGIN
		NEW(result);
		RETURN result
	END Get;

END FoxA64Backend.

System.FreeDownTo FoxA64Backend ~
