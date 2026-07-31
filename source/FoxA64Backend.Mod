MODULE FoxA64Backend; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "backend for AArch64 (ARMv8-A, A64 instruction set)"; *)

(*
	The AArch64 target: the description the front end compiles against, and the code generator that
	turns intermediate code into A64 instructions.

	Frame layout, which is the one the standard A64 prologue produces and the one the shared
	intermediate backend builds by emitting `push lr`, `push fp`, `mov fp, sp`:

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
	offsetFirstParameter = 128 bits says -- the same as AMD64.

	Three decisions shape the code generator, and each is forced rather than chosen:

	1.	The stack pointer is eight byte granular, because the intermediate backend aligns every
		stack allocation to the address size and there is no knob that changes that. A64 faults on
		a load or store that uses SP as its base register while SP is not sixteen byte aligned, and
		Linux leaves that check on. So SP is never used as the base of a memory access here: an
		address that reads `[sp + n]` in intermediate code is computed into a register first. The
		cost is one instruction per stack access, and the way to remove it later is to pair pushes
		so that SP returns to sixteen byte alignment after each pair.

	2.	Only the caller saved registers are allocated -- X0..X15 and V0..V7, V16..V31. A2 procedures
		preserve nothing across a call, which the intermediate backend relies on, and a procedure
		called with the C convention preserves exactly the registers this generator never touches.
		X16 and X17 are held back as scratch for the places that cannot ask the allocator, which is
		the prologue. X18 is the platform register and X19..X28 are callee saved: both are left
		alone.

	3.	A constant is built with MOVZ and MOVK rather than loaded from a pool -- four instructions
		in the worst case, usually one. An address is loaded from a literal placed inline behind a
		branch, because a fixup patches one instruction and no single A64 instruction can carry a
		64 bit address. A literal pool at the end of the section is the optimisation that removes
		the branch; it is not here yet.
*)

IMPORT
	Basic := FoxBasic, SyntaxTree := FoxSyntaxTree, Global := FoxGlobal, Backend := FoxBackend,
	Sections := FoxSections, IntermediateCode := FoxIntermediateCode,
	IntermediateBackend := FoxIntermediateBackend, CodeGenerators := FoxCodeGenerators,
	BinaryCode := FoxBinaryCode, SemanticChecker := FoxSemanticChecker,
	Formats := FoxFormats, InstructionSet := FoxA64InstructionSet, Assembler := FoxA64Assembler,
	SYSTEM, Diagnostics, Streams, Options, Strings, ObjectFile, Scanner := FoxScanner,
	ObjectFileFormat := FoxGenericObjectFile, Compiler;

CONST
	(* Physical register numbers. Backend-private: the intermediate code only carries the
		number back to us through IntermediateCode.InitParameterRegisterClass, so the
		numbering has to agree with this module and with nothing else.

		X0..X30 are the general purpose registers, X30 being the link register. Number 31
		encodes SP or the zero register depending on the instruction, which is an encoding
		matter rather than an allocation one, so it is named twice here. V0..V31 are the
		SIMD and floating point registers. *)
	X0* = 0;  FP* = 29;  LR* = 30;  SP* = 31;  ZR* = 31;
	V0* = 32;
	NumberOfRegisters = 64;

	(* the two registers the prologue uses before the allocator is usable; AAPCS64 reserves
		exactly these for a caller that needs scratch it did not ask for *)
	IP0 = 16;  IP1 = 17;

	(* AAPCS64 5.4.2: the first eight arguments of each class travel in registers *)
	NumIntegerParameterRegisters = 8;
	NumFloatParameterRegisters = 8;

	None = -1;

	(* an intermediate register number is a part index away from a ticket; A64 registers hold a
		whole 64 bit value, so there is one part and it is always this one *)
	Low = 0;

TYPE
	Operand = InstructionSet.Operand;
	Ticket = CodeGenerators.Ticket;

	(** which physical register is free, and which may be used at all

		Allocation is simpler here than on ARM because nothing overlaps: a V register named S and
		the same register named D are the same allocation unit, and a ticket carries the type that
		says which name to use.
	**)
	PhysicalRegisters = OBJECT (CodeGenerators.PhysicalRegisters)
	VAR
		toVirtual: ARRAY NumberOfRegisters OF Ticket;
		reserved: ARRAY NumberOfRegisters OF BOOLEAN;
		unusable: Ticket;
		hint: SIGNED32;

		PROCEDURE & InitPhysicalRegisters(cooperative: BOOLEAN);
		VAR i: SIGNED32;
		BEGIN
			FOR i := 0 TO NumberOfRegisters - 1 DO
				toVirtual[i] := NIL; reserved[i] := FALSE
			END;
			NEW(unusable);

			(* the registers that have a job of their own *)
			toVirtual[IP0] := unusable;			(* scratch for the prologue *)
			toVirtual[IP1] := unusable;
			toVirtual[18] := unusable;				(* the platform register, which is not ours *)
			FOR i := 19 TO 28 DO toVirtual[i] := unusable END;		(* callee saved, and we save none *)
			toVirtual[FP] := unusable;
			toVirtual[LR] := unusable;
			toVirtual[SP] := unusable;

			(* V8..V15 are callee saved in their low 64 bits *)
			FOR i := V0 + 8 TO V0 + 15 DO toVirtual[i] := unusable END;

			hint := None
		END InitPhysicalRegisters;

		PROCEDURE NumberRegisters*(): SIGNED32;
		BEGIN RETURN NumberOfRegisters
		END NumberRegisters;

		PROCEDURE Allocate*(physicalRegisterNumber: SIGNED32; ticket: Ticket);
		BEGIN
			ASSERT(~ticket.spilled);
			ASSERT(toVirtual[physicalRegisterNumber] = NIL);
			toVirtual[physicalRegisterNumber] := ticket
		END Allocate;

		PROCEDURE SetReserved*(physicalRegisterNumber: SIGNED32; isReserved: BOOLEAN);
		BEGIN reserved[physicalRegisterNumber] := isReserved
		END SetReserved;

		PROCEDURE Reserved*(physicalRegisterNumber: SIGNED32): BOOLEAN;
		BEGIN RETURN (physicalRegisterNumber >= 0) & reserved[physicalRegisterNumber]
		END Reserved;

		PROCEDURE Free*(physicalRegisterNumber: SIGNED32);
		BEGIN
			ASSERT(toVirtual[physicalRegisterNumber] # NIL);
			toVirtual[physicalRegisterNumber] := NIL
		END Free;

		(** the next free register of the class the type asks for, preferring the hinted one **)
		PROCEDURE NextFree*(CONST type: IntermediateCode.Type): SIGNED32;
		VAR result, i: SIGNED32;
		BEGIN
			result := None;
			IF type.form IN IntermediateCode.Integer THEN
				(* count downwards so that X0..X7 -- the argument registers, which a call is about
					to want -- are the last ones handed out *)
				FOR i := 15 TO 0 BY -1 DO
					IF (toVirtual[i] = NIL) & ((result = None) OR (i = hint)) THEN result := i END
				END
			ELSIF type.form = IntermediateCode.Float THEN
				FOR i := V0 + 31 TO V0 + 16 BY -1 DO
					IF (toVirtual[i] = NIL) & ((result = None) OR (i = hint)) THEN result := i END
				END;
				FOR i := V0 + 7 TO V0 BY -1 DO
					IF (toVirtual[i] = NIL) & ((result = None) OR (i = hint)) THEN result := i END
				END
			ELSE
				HALT(100)
			END;
			RETURN result
		END NextFree;

		PROCEDURE AllocationHint*(physicalRegisterNumber: SIGNED32);
		BEGIN hint := physicalRegisterNumber
		END AllocationHint;

		PROCEDURE Mapped*(physicalRegisterNumber: SIGNED32): Ticket;
		BEGIN RETURN toVirtual[physicalRegisterNumber]
		END Mapped;

		PROCEDURE Dump*(w: Streams.Writer);
		VAR i: SIGNED32; virtual: Ticket;
		BEGIN
			w.String("---- registers ----"); w.Ln;
			FOR i := 0 TO NumberOfRegisters - 1 DO
				virtual := toVirtual[i];
				IF virtual # unusable THEN
					w.String("reg "); w.Int(i, 1); w.String(": ");
					IF virtual = NIL THEN w.String("free") ELSE w.String("r"); w.Int(virtual.register, 1) END;
					IF reserved[i] THEN w.String(" reserved") END;
					w.Ln
				END
			END
		END Dump;

	END PhysicalRegisters;

	CodeGeneratorA64 = OBJECT (CodeGenerators.GeneratorWithTickets)
	VAR
		backend: BackendA64;
		emptyOperand: Operand;
		opSP, opFP, opLR, opZR, opIP0, opIP1: Operand;

		(* bytes allocated below the frame pointer for locals; the spill area starts under it *)
		localsSize: SIZE;
		spillStackStart: SIZE;
		spilled: BOOLEAN;			(* whether this pass needed the spill area at all *)

		PROCEDURE & InitGeneratorA64(diagnostics: Diagnostics.Diagnostics; backend: BackendA64);
		VAR physicalRegisters: PhysicalRegisters;
		BEGIN
			SELF.backend := backend;
			NEW(physicalRegisters, backend.cooperative);
			InitTicketGenerator(diagnostics, backend.optimize, 1, physicalRegisters);
			error := FALSE;
			InstructionSet.InitOperand(emptyOperand);
			InstructionSet.InitStackPointer(opSP, 64);
			InstructionSet.InitRegister(opFP, FP, 64);
			InstructionSet.InitRegister(opLR, LR, 64);
			InstructionSet.InitRegister(opZR, ZR, 64);
			InstructionSet.InitRegister(opIP0, IP0, 64);
			InstructionSet.InitRegister(opIP1, IP1, 64);
			dump := NIL
		END InitGeneratorA64;

		(*------------------- the driver ----------------------*)

		(** generate one section, as many times as it takes for the frame size to stop changing

			The prologue reserves the spill area, and how large it has to be is only known once the
			section has been generated. So a section that spilled is generated a second time, with
			the size the first pass measured; the second pass cannot spill more, because it starts
			from the same instruction sequence.
		**)
		PROCEDURE Section*(in: IntermediateCode.Section; out: BinaryCode.Section);
		VAR firstPassSpillSize: SIGNED32;
		BEGIN
			tickets.Init; spillStack.Init;
			localsSize := 0; spillStackStart := 0; spilled := FALSE;

			Section^(in, out);

			IF ~error & (spillStack.MaxSize() > 0) THEN
				firstPassSpillSize := spillStack.MaxSize();
				tickets.Init; spillStack.Init;
				out.Reset;
				spilled := TRUE;
				Section^(in, out);
				IF spillStack.MaxSize() > firstPassSpillSize THEN
					Error(Basic.invalidPosition, "spill area grew in the second pass")
				END
			END;

			IF spillStack.Size() # 0 THEN
				Error(Basic.invalidPosition, "implementation error, spill stack not cleared")
			END
		END Section;

		(** whether an intermediate instruction can be generated, and if not what implements it

			A64 divides, multiplies and converts in hardware, so everything is generated here; the
			cases that are hard are hard in code rather than in a runtime call.
		**)
		PROCEDURE Supported*(CONST instruction: IntermediateCode.Instruction; VAR moduleName, procedureName: ARRAY OF CHAR): BOOLEAN;
		BEGIN
			moduleName := ""; procedureName := "";
			RETURN TRUE
		END Supported;

		(* a 64 bit register holds a whole value: there is one part *)
		PROCEDURE GetPartType*(CONST type: IntermediateCode.Type; part: SIGNED32; VAR typePart: IntermediateCode.Type);
		BEGIN typePart := type
		END GetPartType;

		(*------------------- emitting ----------------------*)

		PROCEDURE EmitOperands(mnemonic: SIGNED32; CONST operands: ARRAY OF Operand);
		VAR instruction: InstructionSet.Instruction; message: Basic.MessageString;
		BEGIN
			InstructionSet.MakeInstruction(instruction, mnemonic, operands);
			IF ~InstructionSet.EmitInstruction(instruction, out) THEN
				message := "operands do not name an A64 instruction: ";
				Strings.Append(message, InstructionSet.MnemonicName(mnemonic));
				Error(Basic.invalidPosition, message)
			END
		END EmitOperands;

		PROCEDURE Emit0(mnemonic: SIGNED32);
		VAR operands: ARRAY 1 OF Operand;
		BEGIN InstructionSet.InitOperand(operands[0]); EmitOperands(mnemonic, operands)
		END Emit0;

		PROCEDURE Emit1(mnemonic: SIGNED32; CONST a: Operand);
		VAR operands: ARRAY 1 OF Operand;
		BEGIN operands[0] := a; EmitOperands(mnemonic, operands)
		END Emit1;

		PROCEDURE Emit2(mnemonic: SIGNED32; CONST a, b: Operand);
		VAR operands: ARRAY 2 OF Operand;
		BEGIN operands[0] := a; operands[1] := b; EmitOperands(mnemonic, operands)
		END Emit2;

		PROCEDURE Emit3(mnemonic: SIGNED32; CONST a, b, c: Operand);
		VAR operands: ARRAY 3 OF Operand;
		BEGIN operands[0] := a; operands[1] := b; operands[2] := c; EmitOperands(mnemonic, operands)
		END Emit3;

		PROCEDURE Emit4(mnemonic: SIGNED32; CONST a, b, c, d: Operand);
		VAR operands: ARRAY 4 OF Operand;
		BEGIN operands[0] := a; operands[1] := b; operands[2] := c; operands[3] := d;
			EmitOperands(mnemonic, operands)
		END Emit4;

		(*------------------- types, registers and operands ----------------------*)

		(** the register width an intermediate type is held in

			A64 general purpose registers come in two widths, so everything narrower than 64 bits
			lives in a W register and is extended when its narrowness matters.
		**)
		PROCEDURE RegisterWidth(CONST type: IntermediateCode.Type): SIGNED16;
		BEGIN
			IF type.form = IntermediateCode.Float THEN RETURN SIGNED16(type.sizeInBits)
			ELSIF type.sizeInBits = 64 THEN RETURN 64
			ELSE RETURN 32
			END
		END RegisterWidth;

		PROCEDURE IsFloat(CONST operand: IntermediateCode.Operand): BOOLEAN;
		BEGIN RETURN operand.type.form = IntermediateCode.Float
		END IsFloat;

		PROCEDURE IsFloatRegister(register: SIGNED32): BOOLEAN;
		BEGIN RETURN register >= V0
		END IsFloatRegister;

		PROCEDURE IsRegisterForType(register: SIGNED32; CONST type: IntermediateCode.Type): BOOLEAN;
		BEGIN RETURN IsFloatRegister(register) = (type.form = IntermediateCode.Float)
		END IsRegisterForType;

		(* Register 31 is SP or the zero register depending on the instruction, and the operand has
			to say which. Nothing here ever wants the zero register by number -- the places that do
			name opZR -- so a 31 that comes out of the register mapping is always the stack pointer,
			and saying so is what keeps `mov fp, sp` from encoding as `mov fp, xzr`. *)
		PROCEDURE RegisterOperand(register: SIGNED32; CONST type: IntermediateCode.Type): Operand;
		VAR result: Operand;
		BEGIN
			IF register = SP THEN
				InstructionSet.InitStackPointer(result, RegisterWidth(type))
			ELSE
				InstructionSet.InitRegister(result, register, RegisterWidth(type))
			END;
			RETURN result
		END RegisterOperand;

		PROCEDURE AddressRegister(register: SIGNED32): Operand;
		VAR result: Operand;
		BEGIN
			IF register = SP THEN InstructionSet.InitStackPointer(result, 64)
			ELSE InstructionSet.InitRegister(result, register, 64)
			END;
			RETURN result
		END AddressRegister;

		PROCEDURE AddressType(): IntermediateCode.Type;
		BEGIN RETURN IntermediateCode.GetType(module.system, module.system.addressType)
		END AddressType;

		PROCEDURE Immediate(value: Basic.Integer): Operand;
		VAR result: Operand;
		BEGIN InstructionSet.InitImmediate(result, value); RETURN result
		END Immediate;

		PROCEDURE PhysicalRegisterNumber(virtualRegisterNumber: SIZE): SIGNED32;
		VAR ticket: Ticket;
		BEGIN
			IF virtualRegisterNumber = IntermediateCode.FP THEN RETURN FP
			ELSIF virtualRegisterNumber = IntermediateCode.SP THEN RETURN SP
			ELSIF virtualRegisterNumber = IntermediateCode.LR THEN RETURN LR
			END;
			ticket := virtualRegisters.Mapped(virtualRegisterNumber, Low);
			IF ticket = NIL THEN RETURN None ELSE RETURN ticket.register END
		END PhysicalRegisterNumber;

		(*------------------- spilling ----------------------*)

		(** where a spilled ticket lives: eight bytes per slot, below the locals, addressed
			through the frame pointer because SP cannot be a base register here **)
		PROCEDURE GetSpillOperand(ticket: Ticket): Operand;
		VAR result: Operand; offset: SIZE;
		BEGIN
			ASSERT(ticket.spilled);
			offset := spillStackStart + (ticket.offset + 1) * 8;
			InstructionSet.InitImmediateOffsetMemory(result, FP, -offset, InstructionSet.indexOffset);
			RETURN result
		END GetSpillOperand;

		PROCEDURE ToSpillStack*(ticket: Ticket);
		BEGIN
			Store(RegisterOperand(ticket.register, ticket.type), GetSpillOperand(ticket), ticket.type)
		END ToSpillStack;

		(* the area is reserved once, by the prologue, from the size the previous pass measured *)
		PROCEDURE AllocateSpillStack*(size: SIGNED32);
		BEGIN
		END AllocateSpillStack;

		PROCEDURE ToRegister*(ticket: Ticket);
		BEGIN
			Load(RegisterOperand(ticket.register, ticket.type), GetSpillOperand(ticket), ticket.type)
		END ToRegister;

		PROCEDURE ExchangeTickets*(ticket1, ticket2: Ticket);
		VAR temporary, first, second: Operand;
		BEGIN
			temporary := GetFreeRegister(AddressType());
			first := OperandFromTicket(ticket1);
			second := OperandFromTicket(ticket2);
			MoveOperand(temporary, first, ticket1.type);
			MoveOperand(first, second, ticket1.type);
			MoveOperand(second, temporary, ticket2.type);
			ReleaseHint(temporary.register)
		END ExchangeTickets;

		PROCEDURE OperandFromTicket(ticket: Ticket): Operand;
		BEGIN
			ASSERT(ticket # NIL);
			IF ticket.spilled THEN RETURN GetSpillOperand(ticket)
			ELSE RETURN RegisterOperand(ticket.register, ticket.type)
			END
		END OperandFromTicket;

		(*------------------- getting hold of a register ----------------------*)

		PROCEDURE GetFreeRegister(CONST type: IntermediateCode.Type): Operand;
		BEGIN RETURN OperandFromTicket(TemporaryTicket(IntermediateCode.GeneralPurposeRegister, type))
		END GetFreeRegister;

		PROCEDURE GetFreeRegisterOrHint(CONST type: IntermediateCode.Type; CONST registerHint: Operand): Operand;
		BEGIN
			IF (registerHint.mode = InstructionSet.modeRegister) & IsRegisterForType(registerHint.register, type) THEN
				RETURN registerHint
			END;
			RETURN GetFreeRegister(type)
		END GetFreeRegisterOrHint;

		(*------------------- moving between registers ----------------------*)

		PROCEDURE IsSameRegister(CONST a, b: Operand): BOOLEAN;
		BEGIN
			RETURN (a.mode = InstructionSet.modeRegister) & (b.mode = InstructionSet.modeRegister)
				& (a.register = b.register)
		END IsSameRegister;

		(** move between two registers, whichever files they are in

			FMOV crosses between a general purpose and a floating point register and needs the two
			to be the same width, which is what the caller's types already guarantee.
		**)
		PROCEDURE MoveOperand(CONST destination, source: Operand; CONST type: IntermediateCode.Type);
		BEGIN
			IF IsSameRegister(destination, source) THEN RETURN END;
			IF destination.mode = InstructionSet.modeMemory THEN
				Store(source, destination, type)
			ELSIF source.mode = InstructionSet.modeMemory THEN
				Load(destination, source, type)
			ELSIF IsFloatRegister(destination.register) OR IsFloatRegister(source.register) THEN
				Emit2(InstructionSet.opFMOV, destination, source)
			ELSE
				Emit2(InstructionSet.opMOV, destination, source)
			END
		END MoveOperand;

		PROCEDURE MovIfDifferent(CONST a, b: Operand);
		VAR type: IntermediateCode.Type;
		BEGIN
			IF IsSameRegister(a, b) THEN RETURN END;
			IF IsFloatRegister(a.register) THEN type := IntermediateCode.FloatType(a.size)
			ELSE type := IntermediateCode.UnsignedIntegerType(a.size)
			END;
			MoveOperand(a, b, type)
		END MovIfDifferent;

		(*------------------- loads and stores ----------------------*)

		PROCEDURE Load(CONST targetRegister, memoryOperand: Operand; CONST type: IntermediateCode.Type);
		BEGIN
			IF type.form = IntermediateCode.Float THEN
				Emit2(InstructionSet.opLDR, targetRegister, memoryOperand)
			ELSE
				CASE type.sizeInBits OF
				| 8:
					IF type.form = IntermediateCode.SignedInteger THEN
						Emit2(InstructionSet.opLDRSB, targetRegister, memoryOperand)
					ELSE
						Emit2(InstructionSet.opLDRB, targetRegister, memoryOperand)
					END
				| 16:
					IF type.form = IntermediateCode.SignedInteger THEN
						Emit2(InstructionSet.opLDRSH, targetRegister, memoryOperand)
					ELSE
						Emit2(InstructionSet.opLDRH, targetRegister, memoryOperand)
					END
				| 32, 64:
					Emit2(InstructionSet.opLDR, targetRegister, memoryOperand)
				ELSE
					Error(Basic.invalidPosition, "cannot load a value of this size")
				END
			END
		END Load;

		PROCEDURE Store(CONST sourceRegister, memoryOperand: Operand; CONST type: IntermediateCode.Type);
		VAR source: Operand;
		BEGIN
			(* No store can name SP as the value it writes: in that field register 31 is the zero
				register and nothing else. So the stack pointer is copied into a register first, which
				is what `mov x, sp` does with an ADD of zero. The intermediate code asks for this
				wherever a process saves its own stack pointer. *)
			IF sourceRegister.isStackPointer THEN
				source := GetFreeRegister(AddressType());
				Emit2(InstructionSet.opMOV, source, opSP)
			ELSE
				source := sourceRegister
			END;
			IF type.form = IntermediateCode.Float THEN
				Emit2(InstructionSet.opSTR, source, memoryOperand)
			ELSE
				CASE type.sizeInBits OF
				| 8: Emit2(InstructionSet.opSTRB, source, memoryOperand)
				| 16: Emit2(InstructionSet.opSTRH, source, memoryOperand)
				| 32, 64: Emit2(InstructionSet.opSTR, source, memoryOperand)
				ELSE
					Error(Basic.invalidPosition, "cannot store a value of this size")
				END
			END
		END Store;

		(*------------------- materialising constants and addresses ----------------------*)

		(** put a constant into a register with MOVZ and as many MOVKs as its halfwords need

			MOVN first when the complement is shorter, which is what makes a small negative number
			one instruction rather than four.
		**)
		PROCEDURE EmitConstant(CONST target: Operand; value: Basic.Integer);
		VAR halfword, remaining: Basic.Integer; shift: SIGNED32; first: BOOLEAN; immediate: Operand;
			width: SIGNED32; inverted: Basic.Integer;

			PROCEDURE Halfwords(v: Basic.Integer): SIGNED32;
			VAR count, i: SIGNED32;
			BEGIN
				count := 0;
				FOR i := 0 TO width DIV 16 - 1 DO
					IF (v DIV Pow2(i * 16)) MOD 65536 # 0 THEN INC(count) END
				END;
				RETURN count
			END Halfwords;

		BEGIN
			width := target.size;
			IF width = 32 THEN value := value MOD 100000000H END;
			inverted := Not(value, width);

			IF Halfwords(inverted) < Halfwords(value) THEN
				(* MOVN writes one halfword inverted and sets every other bit *)
				remaining := inverted; first := TRUE; shift := 0;
				WHILE shift < width DO
					halfword := (remaining DIV Pow2(shift)) MOD 65536;
					IF (halfword # 0) OR (first & (shift + 16 >= width)) THEN
						InstructionSet.InitShiftedImmediate(immediate, halfword, shift);
						IF first THEN Emit2(InstructionSet.opMOVN, target, immediate); first := FALSE
						ELSE
							(* the bits MOVN already set are right; only the ones that differ from
								all-ones need a MOVK, and those carry the uninverted halfword *)
							InstructionSet.InitShiftedImmediate(immediate, (value DIV Pow2(shift)) MOD 65536, shift);
							Emit2(InstructionSet.opMOVK, target, immediate)
						END
					END;
					INC(shift, 16)
				END;
				IF first THEN Emit2(InstructionSet.opMOVN, target, Immediate(0)) END
			ELSE
				remaining := value; first := TRUE; shift := 0;
				WHILE shift < width DO
					halfword := (remaining DIV Pow2(shift)) MOD 65536;
					IF halfword # 0 THEN
						InstructionSet.InitShiftedImmediate(immediate, halfword, shift);
						IF first THEN Emit2(InstructionSet.opMOVZ, target, immediate); first := FALSE
						ELSE Emit2(InstructionSet.opMOVK, target, immediate)
						END
					END;
					INC(shift, 16)
				END;
				IF first THEN Emit2(InstructionSet.opMOVZ, target, Immediate(0)) END
			END
		END EmitConstant;

		PROCEDURE RegisterFromValue(value: Basic.Integer; CONST type: IntermediateCode.Type; CONST registerHint: Operand): Operand;
		VAR result: Operand;
		BEGIN
			result := GetFreeRegisterOrHint(type, registerHint);
			EmitConstant(result, value);
			RETURN result
		END RegisterFromValue;

		(** load the address of a symbol out of a literal placed right behind a branch over it

			A fixup patches one instruction, and no A64 instruction carries a 64 bit address, so the
			address is data. Putting the data inline costs a branch and eight bytes; a pool at the
			end of the section is what removes them, and it is not here yet.
		**)
		PROCEDURE RegisterFromSymbol(CONST symbol: ObjectFile.Identifier; symbolOffset: SIZE; CONST registerHint: Operand): Operand;
		VAR result, literal: Operand; patterns: ObjectFile.FixupPatterns; fixup: BinaryCode.Fixup;
		BEGIN
			result := GetFreeRegisterOrHint(AddressType(), registerHint);

			(* LDR Xd, #8 -- the literal is two instructions along *)
			InstructionSet.InitImmediate(literal, 8);
			Emit2(InstructionSet.opLDR, result, literal);
			(* B #12 -- over the eight bytes of the literal *)
			Emit1(InstructionSet.opB, Immediate(12));

			NEW(patterns, 1);
			patterns[0].offset := 0; patterns[0].bits := 64;
			fixup := BinaryCode.NewFixup(BinaryCode.Absolute, out.pc, symbol, symbolOffset, 0, 0, patterns);
			out.fixupList.AddFixup(fixup);
			out.PutBits(0, 32); out.PutBits(0, 32);

			RETURN result
		END RegisterFromSymbol;

		PROCEDURE Resolve(VAR operand: IntermediateCode.Operand);
		BEGIN
			IF (operand.symbol.name # "") & (operand.resolved = NIL) THEN
				operand.resolved := module.allSections.FindByName(operand.symbol.name)
			END
		END Resolve;

		(*------------------- addresses ----------------------*)

		(** a register holding `base + offset`, which is the base itself when the offset is zero **)
		PROCEDURE RegisterAfterAppliedOffset(CONST register: Operand; offset: SIZE; CONST registerHint: Operand): Operand;
		VAR result, amount: Operand;
		BEGIN
			IF offset = 0 THEN RETURN register END;
			result := GetFreeRegisterOrHint(AddressType(), registerHint);
			IF (offset > 0) & (offset < 4096) THEN
				Emit3(InstructionSet.opADD, result, register, Immediate(offset))
			ELSIF (offset < 0) & (-offset < 4096) THEN
				Emit3(InstructionSet.opSUB, result, register, Immediate(-offset))
			ELSE
				amount := GetFreeRegister(AddressType());
				EmitConstant(amount, offset);
				Emit3(InstructionSet.opADD, result, register, amount);
				ReleaseHint(amount.register)
			END;
			RETURN result
		END RegisterAfterAppliedOffset;

		(** the base register of a memory access

			This is where the eight byte stack pointer is dealt with: an access based on SP is
			turned into an access based on a copy of it, because A64 checks the alignment of SP
			whenever SP itself is the base register and the intermediate backend does not keep it
			sixteen byte aligned.
		**)
		PROCEDURE BaseRegister(register: SIGNED32): SIGNED32;
		VAR copy: Operand;
		BEGIN
			IF register # SP THEN RETURN register END;
			copy := GetFreeRegister(AddressType());
			Emit2(InstructionSet.opMOV, copy, opSP);
			RETURN copy.register
		END BaseRegister;

		PROCEDURE MemoryOperandFromIrMemoryOperand(VAR irMemoryOperand: IntermediateCode.Operand; CONST registerHint: Operand): Operand;
		VAR result, base, offsetRegister: Operand; baseNumber: SIGNED32; offset: SIZE; scale: SIGNED32;
		BEGIN
			ASSERT(irMemoryOperand.mode = IntermediateCode.ModeMemory);

			IF irMemoryOperand.register # IntermediateCode.None THEN
				baseNumber := BaseRegister(PhysicalRegisterNumber(irMemoryOperand.register))
			ELSIF irMemoryOperand.symbol.name # "" THEN
				Resolve(irMemoryOperand);
				base := RegisterFromSymbol(irMemoryOperand.symbol, irMemoryOperand.symbolOffset, registerHint);
				baseNumber := base.register
			ELSE
				ASSERT(irMemoryOperand.offset = 0);
				base := RegisterFromValue(irMemoryOperand.intValue, AddressType(), registerHint);
				baseNumber := base.register
			END;
			ASSERT(baseNumber # None);

			offset := irMemoryOperand.offset;
			scale := irMemoryOperand.type.sizeInBits DIV 8;

			IF (offset >= 0) & (offset MOD scale = 0) & (offset DIV scale <= 4095)
					OR (offset >= -256) & (offset <= 255) THEN
				(* the scaled form, or the unscaled one that takes a small signed offset *)
				InstructionSet.InitImmediateOffsetMemory(result, baseNumber, offset, InstructionSet.indexOffset)
			ELSE
				offsetRegister := GetFreeRegister(AddressType());
				EmitConstant(offsetRegister, offset);
				InstructionSet.InitRegisterOffsetMemory(result, baseNumber, offsetRegister.register, 64,
					InstructionSet.extendUXTX, 0)
			END;
			RETURN result
		END MemoryOperandFromIrMemoryOperand;

		(*------------------- intermediate operands ----------------------*)

		PROCEDURE RegisterFromIrRegister(CONST irRegisterOperand: IntermediateCode.Operand; CONST registerHint: Operand): Operand;
		VAR result: Operand;
		BEGIN
			ASSERT(irRegisterOperand.mode = IntermediateCode.ModeRegister);
			IF virtualRegisters.Mapped(irRegisterOperand.register, Low) = NIL THEN
				TryAllocate(irRegisterOperand, Low)
			END;
			result := RegisterOperand(PhysicalRegisterNumber(irRegisterOperand.register), irRegisterOperand.type);
			IF irRegisterOperand.register < 0 THEN result := AddressRegister(result.register) END;
			RETURN RegisterAfterAppliedOffset(result, irRegisterOperand.offset, registerHint)
		END RegisterFromIrRegister;

		PROCEDURE RegisterFromIrOperand(VAR irOperand: IntermediateCode.Operand; CONST registerHint: Operand): Operand;
		VAR result: Operand;
		BEGIN
			CASE irOperand.mode OF
			| IntermediateCode.ModeRegister:
				result := RegisterFromIrRegister(irOperand, registerHint)
			| IntermediateCode.ModeMemory:
				result := GetFreeRegisterOrHint(irOperand.type, registerHint);
				Load(result, MemoryOperandFromIrMemoryOperand(irOperand, result), irOperand.type)
			| IntermediateCode.ModeImmediate:
				IF irOperand.symbol.name # "" THEN
					Resolve(irOperand);
					result := RegisterFromSymbol(irOperand.symbol, irOperand.symbolOffset, registerHint);
					result := RegisterAfterAppliedOffset(result, irOperand.offset, registerHint)
				ELSIF IsFloat(irOperand) THEN
					result := FloatRegisterFromValue(irOperand.floatValue, irOperand.type, registerHint)
				ELSE
					result := RegisterFromValue(irOperand.intValue, irOperand.type, registerHint)
				END
			ELSE
				Error(Basic.invalidPosition, "operand cannot be put in a register");
				result := emptyOperand
			END;
			RETURN result
		END RegisterFromIrOperand;

		(** a floating point constant, built in a general purpose register and moved across

			A64's own floating point immediate cannot encode zero, which is the constant that
			actually turns up, so the bit pattern goes through an integer register instead.
		**)
		PROCEDURE FloatRegisterFromValue(value: FLOAT64; CONST type: IntermediateCode.Type; CONST registerHint: Operand): Operand;
		VAR result, bits: Operand; pattern: Basic.Integer;
		BEGIN
			result := GetFreeRegisterOrHint(type, registerHint);
			IF type.sizeInBits = 32 THEN
				pattern := SIGNED32(SYSTEMBits32(FLOAT32(value)));
				bits := GetFreeRegister(IntermediateCode.UnsignedIntegerType(32))
			ELSE
				pattern := SYSTEMBits64(value);
				bits := GetFreeRegister(IntermediateCode.UnsignedIntegerType(64))
			END;
			EmitConstant(bits, pattern);
			Emit2(InstructionSet.opFMOV, result, bits);
			ReleaseHint(bits.register);
			RETURN result
		END FloatRegisterFromValue;

		(** an immediate operand when the instruction can take one, a register otherwise **)
		PROCEDURE RegisterOrImmediateFromIrOperand(VAR irOperand: IntermediateCode.Operand; limit: Basic.Integer; CONST registerHint: Operand): Operand;
		BEGIN
			IF (irOperand.mode = IntermediateCode.ModeImmediate) & (irOperand.symbol.name = "")
					& ~IsFloat(irOperand) & (irOperand.intValue >= 0) & (irOperand.intValue <= limit) THEN
				RETURN Immediate(irOperand.intValue)
			END;
			RETURN RegisterFromIrOperand(irOperand, registerHint)
		END RegisterOrImmediateFromIrOperand;

		(** the register an instruction writes its result into

			A destination that is the stack pointer is given a temporary instead: only the immediate
			and extended-register forms of ADD and SUB can name SP, and everything else -- a load, a
			logical operation, a multiply -- reads a 31 in that field as the zero register and would
			throw the result away. WriteBack moves the temporary into SP afterwards, which is the
			one form that can.
		**)
		PROCEDURE AcquireDestinationRegister(CONST irDestinationOperand: IntermediateCode.Operand; CONST registerHint: Operand): Operand;
		VAR register: SIGNED32;
		BEGIN
			IF irDestinationOperand.mode = IntermediateCode.ModeMemory THEN
				RETURN GetFreeRegisterOrHint(irDestinationOperand.type, registerHint)
			ELSIF irDestinationOperand.mode = IntermediateCode.ModeRegister THEN
				ASSERT(irDestinationOperand.offset = 0);
				IF virtualRegisters.Mapped(irDestinationOperand.register, Low) = NIL THEN
					TryAllocate(irDestinationOperand, Low)
				END;
				register := PhysicalRegisterNumber(irDestinationOperand.register);
				IF register = SP THEN
					RETURN GetFreeRegisterOrHint(irDestinationOperand.type, registerHint)
				END;
				RETURN RegisterOperand(register, irDestinationOperand.type)
			END;
			Error(Basic.invalidPosition, "destination is neither a register nor a memory location");
			RETURN emptyOperand
		END AcquireDestinationRegister;

		(** the same value in a register that is not the stack pointer

			Register 31 is the zero register everywhere except in the few forms that name SP, so an
			operand that reads `sp` has to be copied before it can be an ordinary source. `MOV Xd,
			SP` is ADD with a zero immediate, which is one of the forms that can. *)
		PROCEDURE WithoutStackPointer(CONST register: Operand): Operand;
		VAR copy: Operand;
		BEGIN
			IF ~register.isStackPointer THEN RETURN register END;
			copy := GetFreeRegister(AddressType());
			Emit2(InstructionSet.opMOV, copy, opSP);
			RETURN copy
		END WithoutStackPointer;

		PROCEDURE WriteBack(VAR irDestinationOperand: IntermediateCode.Operand; CONST register: Operand);
		VAR mapped: Operand;
		BEGIN
			IF irDestinationOperand.mode = IntermediateCode.ModeMemory THEN
				Store(register, MemoryOperandFromIrMemoryOperand(irDestinationOperand, emptyOperand), irDestinationOperand.type)
			ELSIF irDestinationOperand.mode = IntermediateCode.ModeRegister THEN
				mapped := RegisterOperand(PhysicalRegisterNumber(irDestinationOperand.register), irDestinationOperand.type);
				IF irDestinationOperand.register < 0 THEN mapped := AddressRegister(mapped.register) END;
				MovIfDifferent(mapped, register)
			ELSE
				Error(Basic.invalidPosition, "destination is neither a register nor a memory location")
			END;
			ReleaseHint(register.register)
		END WriteBack;

		(*------------------- the stack ----------------------*)

		(** move the stack pointer; the immediate form reaches 4095 and anything larger goes
			through IP0, which is free precisely because nothing else may use it **)
		PROCEDURE ModifyStackPointer(delta: SIZE);
		VAR amount: Operand;
		BEGIN
			IF delta = 0 THEN RETURN END;
			IF ABS(delta) < 4096 THEN
				IF delta > 0 THEN Emit3(InstructionSet.opSUB, opSP, opSP, Immediate(delta))
				ELSE Emit3(InstructionSet.opADD, opSP, opSP, Immediate(-delta))
				END
			ELSE
				amount := opIP0;
				EmitConstant(amount, ABS(delta));
				IF delta > 0 THEN Emit3(InstructionSet.opSUB, opSP, opSP, amount)
				ELSE Emit3(InstructionSet.opADD, opSP, opSP, amount)
				END
			END
		END ModifyStackPointer;

		(** clear the locals of the frame just entered

			Up to a point one store per word is the shortest code there is. Past it the loop is
			shorter, and past 32760 bytes the straight line does not encode at all: the scaled offset
			of a store reaches 4095 words and a frame can be larger than that -- Files.CopyFile has
			34040 bytes of locals.
		**)
		PROCEDURE ClearStack(size: SIZE);
		CONST Unrolled = 16 * 8;		(* the size up to which a store per word is emitted *)
		VAR offset: SIZE; base, count, memory: Operand;
		BEGIN
			IF size <= 0 THEN RETURN END;
			base := opIP0;
			Emit2(InstructionSet.opMOV, base, opSP);
			InstructionSet.InitImmediateOffsetMemory(memory, base.register, 0, InstructionSet.indexOffset);
			IF size <= Unrolled THEN
				offset := 0;
				WHILE offset < size DO
					InstructionSet.InitImmediateOffsetMemory(memory, base.register, offset, InstructionSet.indexOffset);
					Emit2(InstructionSet.opSTR, opZR, memory);
					INC(offset, 8)
				END
			ELSE
				count := opIP1;
				EmitConstant(count, size);
				(* str xzr, [base]; add base, base, #8; sub count, count, #8; cbnz count, back *)
				Emit2(InstructionSet.opSTR, opZR, memory);
				Emit3(InstructionSet.opADD, base, base, Immediate(8));
				Emit3(InstructionSet.opSUB, count, count, Immediate(8));
				Emit2(InstructionSet.opCBNZ, count, Immediate(-12))
			END
		END ClearStack;

		PROCEDURE EmitPush(VAR irOperand: IntermediateCode.Operand);
		VAR register, base, memory: Operand; size: SIZE;
		BEGIN
			register := RegisterFromIrOperand(irOperand, emptyOperand);
			size := irOperand.type.sizeInBits DIV 8;
			IF size < 8 THEN size := 8 END;
			ModifyStackPointer(size);
			base := GetFreeRegister(AddressType());
			Emit2(InstructionSet.opMOV, base, opSP);
			InstructionSet.InitImmediateOffsetMemory(memory, base.register, 0, InstructionSet.indexOffset);
			Store(register, memory, irOperand.type);
			ReleaseHint(base.register)
		END EmitPush;

		PROCEDURE EmitPop(VAR irOperand: IntermediateCode.Operand);
		VAR register, base, memory: Operand; size: SIZE;
		BEGIN
			register := AcquireDestinationRegister(irOperand, emptyOperand);
			base := GetFreeRegister(AddressType());
			Emit2(InstructionSet.opMOV, base, opSP);
			InstructionSet.InitImmediateOffsetMemory(memory, base.register, 0, InstructionSet.indexOffset);
			Load(register, memory, irOperand.type);
			ReleaseHint(base.register);
			size := irOperand.type.sizeInBits DIV 8;
			IF size < 8 THEN size := 8 END;
			ModifyStackPointer(-size);
			WriteBack(irOperand, register)
		END EmitPop;

		(*------------------- procedure frames ----------------------*)

		(* enter <callingConvention>, <pafSize>, <numRegParams> *)
		PROCEDURE EmitEnter(CONST irInstruction: IntermediateCode.Instruction);
		VAR allocationSize: SIZE;
		BEGIN
			localsSize := irInstruction.op2.intValue;
			Basic.Align(localsSize, 8);
			allocationSize := localsSize;
			spillStackStart := localsSize;
			IF spilled THEN INC(allocationSize, spillStack.MaxSize() * 8) END;
			ModifyStackPointer(allocationSize);
			IF backend.initLocals THEN ClearStack(localsSize) END
		END EmitEnter;

		(* leave <callingConvention> *)
		PROCEDURE EmitLeave(CONST irInstruction: IntermediateCode.Instruction);
		BEGIN
		END EmitLeave;

		(* exit <pcOffset>, <callingConvention>, <unwind>

			The frame was built by intermediate code -- push lr, push fp, mov fp, sp -- and all of
			it has been taken down again by the time this runs, except the return address: that one
			is the machine's business, because only the machine knows it lives in a register. So
			exit pops it back into the link register, drops whatever the caller left on the stack,
			and branches through it. *)
		PROCEDURE EmitExit(CONST irInstruction: IntermediateCode.Instruction);
		VAR base, memory: Operand;
		BEGIN
			base := opIP0;
			Emit2(InstructionSet.opMOV, base, opSP);
			InstructionSet.InitImmediateOffsetMemory(memory, base.register, 0, InstructionSet.indexOffset);
			Emit2(InstructionSet.opLDR, opLR, memory);
			ModifyStackPointer(-8);
			IF irInstruction.op3.intValue # 0 THEN
				ModifyStackPointer(-irInstruction.op3.intValue)
			END;
			Emit1(InstructionSet.opRET, opLR)
		END EmitExit;

		(* call <address>, <parSize> *)
		PROCEDURE EmitCall(VAR irInstruction: IntermediateCode.Instruction);
		VAR code: BinaryCode.Section; fixup, newFixup: BinaryCode.Fixup;
			patterns: ObjectFile.FixupPatterns; target: Operand;
		BEGIN
			Resolve(irInstruction.op1);
			IF (irInstruction.op1.resolved # NIL) & (irInstruction.op1.resolved.type = Sections.InlineCodeSection) THEN
				(* an inline procedure: its code is copied in, fixups and all *)
				code := irInstruction.op1.resolved(IntermediateCode.Section).resolved;
				ASSERT(code # NIL);
				IF out.comments # NIL THEN
					out.comments.String("inlined code sequence:"); out.comments.Ln; out.comments.Update
				END;
				out.CopyBits(code.os.bits, 0, code.os.bits.GetSize());
				fixup := code.fixupList.firstFixup;
				WHILE fixup # NIL DO
					newFixup := BinaryCode.NewFixup(fixup.mode, fixup.offset + code.pc, fixup.symbol,
						fixup.symbolOffset, fixup.displacement, fixup.scale, fixup.pattern);
					out.fixupList.AddFixup(newFixup);
					fixup := fixup.nextFixup
				END
			ELSIF (irInstruction.op1.mode = IntermediateCode.ModeImmediate) & (irInstruction.op1.symbol.name # "")
					& (irInstruction.op1.offset = 0) THEN
				(* a direct call: BL reaches 128 megabytes either way, which is every call inside a
					module and every call the loader places nearby *)
				NEW(patterns, 1);
				patterns[0].offset := 0; patterns[0].bits := 26;
				fixup := BinaryCode.NewFixup(BinaryCode.Relative, out.pc, irInstruction.op1.symbol,
					irInstruction.op1.symbolOffset, 0, -2, patterns);
				out.fixupList.AddFixup(fixup);
				Emit1(InstructionSet.opBL, Immediate(0));
				ModifyStackPointer(-irInstruction.op2.intValue)
			ELSE
				target := RegisterFromIrOperand(irInstruction.op1, emptyOperand);
				Emit1(InstructionSet.opBLR, AddressRegister(target.register));
				ReleaseHint(target.register);
				ModifyStackPointer(-irInstruction.op2.intValue)
			END
		END EmitCall;

		PROCEDURE ResultRegister(CONST type: IntermediateCode.Type): Operand;
		BEGIN
			IF type.form = IntermediateCode.Float THEN RETURN RegisterOperand(V0, type) END;
			RETURN RegisterOperand(X0, type)
		END ResultRegister;

		PROCEDURE EmitReturn(VAR irInstruction: IntermediateCode.Instruction);
		VAR source: Operand;
		BEGIN
			source := RegisterFromIrOperand(irInstruction.op1, ResultRegister(irInstruction.op1.type));
			MovIfDifferent(ResultRegister(irInstruction.op1.type), source)
		END EmitReturn;

		PROCEDURE EmitResult(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination: Operand;
		BEGIN
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			MovIfDifferent(destination, ResultRegister(irInstruction.op1.type));
			WriteBack(irInstruction.op1, destination)
		END EmitResult;

		PROCEDURE EmitTrap(CONST irInstruction: IntermediateCode.Instruction);
		BEGIN
			Emit1(InstructionSet.opBRK, Immediate(irInstruction.op1.intValue))
		END EmitTrap;

		(*------------------- moving and converting ----------------------*)

		PROCEDURE EmitMov(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, source: Operand;
		BEGIN
			IF irInstruction.op1.mode # IntermediateCode.ModeRegister THEN
				source := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
				destination := GetFreeRegisterOrHint(irInstruction.op2.type, source)
			ELSE
				destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
				source := RegisterFromIrOperand(irInstruction.op2, destination)
			END;
			MovIfDifferent(destination, source);
			WriteBack(irInstruction.op1, destination)
		END EmitMov;

		(** conv <destination>, <source> -- every widening, narrowing and float conversion **)
		PROCEDURE EmitConv(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, source: Operand; from, to: IntermediateCode.Type;
		BEGIN
			from := irInstruction.op2.type;
			to := irInstruction.op1.type;
			source := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);

			IF (from.form = IntermediateCode.Float) & (to.form = IntermediateCode.Float) THEN
				IF from.sizeInBits = to.sizeInBits THEN MovIfDifferent(destination, source)
				ELSE Emit2(InstructionSet.opFCVT, destination, source)
				END
			ELSIF (from.form = IntermediateCode.Float) & (to.form IN IntermediateCode.Integer) THEN
				(* rounding towards minus infinity rather than towards zero: the intermediate code
					means ENTIER by this conversion, and ENTIER is the floor. AMD64 has to convert
					towards zero and then correct in six instructions; A64 has the rounding mode in
					the instruction. *)
				IF to.form = IntermediateCode.UnsignedInteger THEN
					Emit2(InstructionSet.opFCVTMU, AddressOrWord(destination, to), source)
				ELSE
					Emit2(InstructionSet.opFCVTMS, AddressOrWord(destination, to), source)
				END;
				NarrowInteger(destination, to)
			ELSIF (from.form IN IntermediateCode.Integer) & (to.form = IntermediateCode.Float) THEN
				IF from.form = IntermediateCode.UnsignedInteger THEN
					Emit2(InstructionSet.opUCVTF, destination, ExtendedInteger(source, from))
				ELSE
					Emit2(InstructionSet.opSCVTF, destination, ExtendedInteger(source, from))
				END
			ELSE
				(* integer to integer: the value is widened according to the source and then kept
					in whatever width the destination is held in *)
				ConvertInteger(destination, source, from, to)
			END;
			WriteBack(irInstruction.op1, destination)
		END EmitConv;

		(* the register a conversion writes into, in the width the target type is held in *)
		PROCEDURE AddressOrWord(CONST register: Operand; CONST type: IntermediateCode.Type): Operand;
		VAR result: Operand;
		BEGIN
			InstructionSet.InitRegister(result, register.register, RegisterWidth(type));
			RETURN result
		END AddressOrWord;

		(* make the bits above the type's width agree with the type, in place *)
		PROCEDURE NarrowInteger(CONST register: Operand; CONST type: IntermediateCode.Type);
		BEGIN
			IF type.sizeInBits >= 32 THEN RETURN END;
			IF type.form = IntermediateCode.UnsignedInteger THEN
				IF type.sizeInBits = 8 THEN Emit2(InstructionSet.opUXTB, register, register)
				ELSE Emit2(InstructionSet.opUXTH, register, register)
				END
			ELSE
				IF type.sizeInBits = 8 THEN Emit2(InstructionSet.opSXTB, register, register)
				ELSE Emit2(InstructionSet.opSXTH, register, register)
				END
			END
		END NarrowInteger;

		(* a register whose whole width carries the value of a narrower type *)
		PROCEDURE ExtendedInteger(CONST register: Operand; CONST type: IntermediateCode.Type): Operand;
		BEGIN
			IF type.sizeInBits >= 32 THEN RETURN register END;
			NarrowInteger(register, type);
			RETURN register
		END ExtendedInteger;

		PROCEDURE ConvertInteger(CONST destination, source: Operand; CONST from, to: IntermediateCode.Type);
		VAR wide: Operand;
		BEGIN
			IF (to.sizeInBits = 64) & (from.sizeInBits < 64) THEN
				(* widening into a 64 bit register: the source is a W register and the extension
					names the width it actually carries *)
				InstructionSet.InitRegister(wide, source.register, 32);
				IF from.form = IntermediateCode.SignedInteger THEN
					CASE from.sizeInBits OF
					| 8: Emit2(InstructionSet.opSXTB, destination, wide)
					| 16: Emit2(InstructionSet.opSXTH, destination, wide)
					ELSE Emit2(InstructionSet.opSXTW, destination, wide)
					END
				ELSE
					CASE from.sizeInBits OF
					| 8: Emit2(InstructionSet.opUXTB, AddressOrWord(destination, IntermediateCode.UnsignedIntegerType(32)), wide)
					| 16: Emit2(InstructionSet.opUXTH, AddressOrWord(destination, IntermediateCode.UnsignedIntegerType(32)), wide)
					ELSE
						(* a write to a W register clears the top half, which is the zero extension *)
						Emit2(InstructionSet.opMOV, AddressOrWord(destination, IntermediateCode.UnsignedIntegerType(32)), wide)
					END
				END
			ELSE
				MovIfDifferent(destination, AddressOrWord(source, to));
				NarrowInteger(destination, to)
			END
		END ConvertInteger;

		(*------------------- arithmetic and logic ----------------------*)

		(* the shape every three operand instruction has: destination, left, right *)
		PROCEDURE PrepareThree(VAR irInstruction: IntermediateCode.Instruction; limit: Basic.Integer;
			VAR destination, left, right: Operand);
		BEGIN
			left := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
			(* the second source is Rm, which is the zero register when it is 31; the first is Rn,
				which the extended-register form of ADD and SUB can read as SP *)
			right := RegisterOrImmediateFromIrOperand(irInstruction.op3, limit, emptyOperand);
			IF right.mode = InstructionSet.modeRegister THEN right := WithoutStackPointer(right) END;
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand)
		END PrepareThree;

		PROCEDURE EmitArithmetic(VAR irInstruction: IntermediateCode.Instruction; mnemonic: SIGNED32; limit: Basic.Integer);
		VAR destination, left, right: Operand;
		BEGIN
			PrepareThree(irInstruction, limit, destination, left, right);
			Emit3(mnemonic, destination, left, right);
			NarrowInteger(destination, irInstruction.op1.type);
			WriteBack(irInstruction.op1, destination)
		END EmitArithmetic;

		PROCEDURE EmitAddOrSub(VAR irInstruction: IntermediateCode.Instruction);
		BEGIN
			IF IsFloat(irInstruction.op1) THEN
				IF irInstruction.opcode = IntermediateCode.add THEN
					EmitFloatArithmetic(irInstruction, InstructionSet.opFADD)
				ELSE
					EmitFloatArithmetic(irInstruction, InstructionSet.opFSUB)
				END
			ELSIF irInstruction.opcode = IntermediateCode.add THEN
				EmitArithmetic(irInstruction, InstructionSet.opADD, 4095)
			ELSE
				EmitArithmetic(irInstruction, InstructionSet.opSUB, 4095)
			END
		END EmitAddOrSub;

		PROCEDURE EmitFloatArithmetic(VAR irInstruction: IntermediateCode.Instruction; mnemonic: SIGNED32);
		VAR destination, left, right: Operand;
		BEGIN
			left := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
			right := RegisterFromIrOperand(irInstruction.op3, emptyOperand);
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			Emit3(mnemonic, destination, left, right);
			WriteBack(irInstruction.op1, destination)
		END EmitFloatArithmetic;

		PROCEDURE EmitLogical(VAR irInstruction: IntermediateCode.Instruction; mnemonic: SIGNED32);
		VAR destination, left, right: Operand;
		BEGIN
			(* the immediate a logical instruction takes is a bit pattern rather than a range, so
				the encoder is asked rather than a limit compared against *)
			left := WithoutStackPointer(RegisterFromIrOperand(irInstruction.op2, emptyOperand));
			right := LogicalOperand(irInstruction.op3, left.size);
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			Emit3(mnemonic, destination, left, right);
			WriteBack(irInstruction.op1, destination)
		END EmitLogical;

		PROCEDURE LogicalOperand(VAR irOperand: IntermediateCode.Operand; width: SIGNED16): Operand;
		VAR n, immr, imms: SIGNED32;
		BEGIN
			IF (irOperand.mode = IntermediateCode.ModeImmediate) & (irOperand.symbol.name = "")
					& ~IsFloat(irOperand)
					& InstructionSet.EncodeLogicalImmediate(irOperand.intValue, width, n, immr, imms) THEN
				RETURN Immediate(irOperand.intValue)
			END;
			RETURN WithoutStackPointer(RegisterFromIrOperand(irOperand, emptyOperand))
		END LogicalOperand;

		PROCEDURE EmitMul(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, left, right: Operand;
		BEGIN
			IF IsFloat(irInstruction.op1) THEN
				EmitFloatArithmetic(irInstruction, InstructionSet.opFMUL); RETURN
			END;
			left := WithoutStackPointer(RegisterFromIrOperand(irInstruction.op2, emptyOperand));
			right := WithoutStackPointer(RegisterFromIrOperand(irInstruction.op3, emptyOperand));
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			Emit3(InstructionSet.opMUL, destination, left, right);
			NarrowInteger(destination, irInstruction.op1.type);
			WriteBack(irInstruction.op1, destination)
		END EmitMul;

		(** div and mod, with the correction that turns a truncating quotient into a floor one

			A64 divides towards zero and Oberon divides towards minus infinity, so the remainder is
			computed, its sign inspected, and one subtracted from the quotient -- or the divisor
			added to the remainder -- when they disagree. This is the same correction the AMD64
			backend makes, and it is right for a positive divisor, which is the case the language
			report defines.
		**)
		PROCEDURE EmitDivOrMod(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, left, right, quotient, remainder, adjusted: Operand;
			unsigned: BOOLEAN; type: IntermediateCode.Type;
		BEGIN
			IF IsFloat(irInstruction.op1) THEN
				EmitFloatArithmetic(irInstruction, InstructionSet.opFDIV); RETURN
			END;
			type := irInstruction.op1.type;
			unsigned := type.form = IntermediateCode.UnsignedInteger;

			left := WithoutStackPointer(RegisterFromIrOperand(irInstruction.op2, emptyOperand));
			right := WithoutStackPointer(RegisterFromIrOperand(irInstruction.op3, emptyOperand));
			quotient := GetFreeRegister(type);
			IF unsigned THEN Emit3(InstructionSet.opUDIV, quotient, left, right)
			ELSE Emit3(InstructionSet.opSDIV, quotient, left, right)
			END;
			remainder := GetFreeRegister(type);
			Emit4(InstructionSet.opMSUB, remainder, quotient, right, left);

			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			IF unsigned THEN
				IF irInstruction.opcode = IntermediateCode.div THEN MovIfDifferent(destination, quotient)
				ELSE MovIfDifferent(destination, remainder)
				END
			ELSE
				Emit2(InstructionSet.opCMP, remainder, Immediate(0));
				adjusted := GetFreeRegister(type);
				IF irInstruction.opcode = IntermediateCode.div THEN
					Emit3(InstructionSet.opSUB, adjusted, quotient, Immediate(1));
					Emit4(InstructionSet.opCSEL, destination, adjusted, quotient, Condition(InstructionSet.conditionMI))
				ELSE
					Emit3(InstructionSet.opADD, adjusted, remainder, right);
					Emit4(InstructionSet.opCSEL, destination, adjusted, remainder, Condition(InstructionSet.conditionMI))
				END;
				ReleaseHint(adjusted.register)
			END;
			ReleaseHint(remainder.register); ReleaseHint(quotient.register);
			NarrowInteger(destination, type);
			WriteBack(irInstruction.op1, destination)
		END EmitDivOrMod;

		PROCEDURE Condition(condition: SIGNED8): Operand;
		VAR result: Operand;
		BEGIN InstructionSet.InitCondition(result, condition); RETURN result
		END Condition;

		PROCEDURE EmitNeg(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, source: Operand;
		BEGIN
			source := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			IF IsFloat(irInstruction.op1) THEN
				Emit2(InstructionSet.opFNEG, destination, source)
			ELSE
				Emit2(InstructionSet.opNEG, destination, source);
				NarrowInteger(destination, irInstruction.op1.type)
			END;
			WriteBack(irInstruction.op1, destination)
		END EmitNeg;

		PROCEDURE EmitNot(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, source: Operand;
		BEGIN
			source := WithoutStackPointer(RegisterFromIrOperand(irInstruction.op2, emptyOperand));
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			Emit2(InstructionSet.opMVN, destination, source);
			NarrowInteger(destination, irInstruction.op1.type);
			WriteBack(irInstruction.op1, destination)
		END EmitNot;

		PROCEDURE EmitAbs(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, source, negated: Operand;
		BEGIN
			source := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			IF IsFloat(irInstruction.op1) THEN
				Emit2(InstructionSet.opFABS, destination, source)
			ELSE
				(* compare against zero and pick the negation when it was negative *)
				negated := GetFreeRegister(irInstruction.op1.type);
				Emit2(InstructionSet.opNEG, negated, source);
				Emit2(InstructionSet.opCMP, source, Immediate(0));
				Emit4(InstructionSet.opCSEL, destination, negated, source, Condition(InstructionSet.conditionMI));
				ReleaseHint(negated.register)
			END;
			WriteBack(irInstruction.op1, destination)
		END EmitAbs;

		(** shl, shr, rol and ror

			A64 has no rotate left, so a rotation by n to the left is a rotation by width minus n
			to the right; and no shift instruction takes a register operand wider than the value,
			so everything happens in the width the value is held in.
		**)
		PROCEDURE EmitShiftOrRotation(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, left, right, amount: Operand; width: SIGNED32; mnemonic: SIGNED32;
		BEGIN
			left := WithoutStackPointer(RegisterFromIrOperand(irInstruction.op2, emptyOperand));
			width := left.size;

			IF irInstruction.opcode = IntermediateCode.rol THEN
				(* rotate left by n = rotate right by width - n *)
				IF (irInstruction.op3.mode = IntermediateCode.ModeImmediate) & (irInstruction.op3.symbol.name = "") THEN
					right := Immediate((width - irInstruction.op3.intValue) MOD width)
				ELSE
					amount := RegisterFromIrOperand(irInstruction.op3, emptyOperand);
					right := GetFreeRegister(irInstruction.op2.type);
					EmitConstant(right, width);
					Emit3(InstructionSet.opSUB, right, right, AddressOrWord(amount, irInstruction.op2.type))
				END;
				mnemonic := InstructionSet.opROR
			ELSE
				right := RegisterOrImmediateFromIrOperand(irInstruction.op3, width - 1, emptyOperand);
				IF right.mode = InstructionSet.modeRegister THEN
					right := AddressOrWord(right, irInstruction.op2.type)
				END;
				CASE irInstruction.opcode OF
				| IntermediateCode.shl: mnemonic := InstructionSet.opLSL
				| IntermediateCode.ror: mnemonic := InstructionSet.opROR
				ELSE
					IF irInstruction.op1.type.form = IntermediateCode.SignedInteger THEN
						mnemonic := InstructionSet.opASR
					ELSE
						mnemonic := InstructionSet.opLSR
					END
				END
			END;

			destination := AcquireDestinationRegister(irInstruction.op1, emptyOperand);
			Emit3(mnemonic, destination, left, right);
			NarrowInteger(destination, irInstruction.op1.type);
			WriteBack(irInstruction.op1, destination)
		END EmitShiftOrRotation;

		(*------------------- branches ----------------------*)

		PROCEDURE BranchTarget(VAR irInstruction: IntermediateCode.Instruction; bits: SIGNED32; offset: SIGNED32): Operand;
		VAR result: Operand; patterns: ObjectFile.FixupPatterns; fixup: BinaryCode.Fixup;
			identifier: ObjectFile.Identifier; distance: SIZE;
		BEGIN
			IF (irInstruction.op1.mode = IntermediateCode.ModeImmediate)
					& (irInstruction.op1.symbol.name = in.name) & (irInstruction.op1.offset = 0) THEN
				IF irInstruction.op1.symbolOffset <= inPC THEN
					(* backwards: the distance is known, no fixup needed *)
					distance := in.instructions[irInstruction.op1.symbolOffset].pc - out.pc;
					RETURN Immediate(distance)
				END;
				(* forwards: the fixup patches the field once the target's position is known *)
				NEW(patterns, 1);
				patterns[0].offset := offset; patterns[0].bits := bits;
				identifier.name := in.name;
				identifier.fingerprint := in.fingerprint;
				fixup := BinaryCode.NewFixup(BinaryCode.Relative, out.pc, identifier,
					irInstruction.op1.symbolOffset, 0, -2, patterns);
				out.fixupList.AddFixup(fixup);
				RETURN Immediate(0)
			END;
			RETURN emptyOperand
		END BranchTarget;

		PROCEDURE EmitBr(VAR irInstruction: IntermediateCode.Instruction);
		VAR left, right, target: Operand; condition: SIGNED8; unsigned: BOOLEAN;
		BEGIN
			IF irInstruction.opcode = IntermediateCode.br THEN
				target := BranchTarget(irInstruction, 26, 0);
				IF target.mode = InstructionSet.modeNone THEN
					target := RegisterFromIrOperand(irInstruction.op1, emptyOperand);
					Emit1(InstructionSet.opBR, AddressRegister(target.register))
				ELSE
					Emit1(InstructionSet.opB, target)
				END;
				RETURN
			END;

			unsigned := irInstruction.op2.type.form = IntermediateCode.UnsignedInteger;
			left := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
			IF IsFloat(irInstruction.op2) THEN
				right := RegisterFromIrOperand(irInstruction.op3, emptyOperand);
				Emit2(InstructionSet.opFCMP, left, right)
			ELSE
				right := RegisterOrImmediateFromIrOperand(irInstruction.op3, 4095, emptyOperand);
				IF right.mode = InstructionSet.modeRegister THEN right := WithoutStackPointer(right) END;
				Emit2(InstructionSet.opCMP, left, right)
			END;

			CASE irInstruction.opcode OF
			| IntermediateCode.breq: condition := InstructionSet.conditionEQ
			| IntermediateCode.brne: condition := InstructionSet.conditionNE
			| IntermediateCode.brge:
				IF unsigned THEN condition := InstructionSet.conditionCS
				ELSE condition := InstructionSet.conditionGE
				END
			| IntermediateCode.brlt:
				IF unsigned THEN condition := InstructionSet.conditionCC
				ELSE condition := InstructionSet.conditionLT
				END
			END;

			target := BranchTarget(irInstruction, 19, 5);
			IF target.mode = InstructionSet.modeNone THEN
				Error(Basic.invalidPosition, "a conditional branch must name a label")
			ELSE
				Emit2(InstructionSet.opBCOND, Condition(condition), target)
			END
		END EmitBr;

		(*------------------- the remaining instructions ----------------------*)

		(** copy <destination>, <source>, <length> -- a byte at a time, which is correct and slow **)
		PROCEDURE EmitCopy(VAR irInstruction: IntermediateCode.Instruction);
		VAR destination, source, length, last, value, memory: Operand; loop: SIZE;
		BEGIN
			destination := GetFreeRegister(AddressType());
			MovIfDifferent(destination, RegisterFromIrOperand(irInstruction.op1, destination));
			source := GetFreeRegister(AddressType());
			MovIfDifferent(source, RegisterFromIrOperand(irInstruction.op2, source));
			length := RegisterFromIrOperand(irInstruction.op3, emptyOperand);
			last := GetFreeRegister(AddressType());
			Emit3(InstructionSet.opADD, last, source, AddressRegister(length.register));

			value := GetFreeRegister(IntermediateCode.UnsignedIntegerType(32));
			loop := out.pc;
			Emit2(InstructionSet.opCMP, source, last);
			(* over the three instructions of the body -- the two byte accesses and the branch back --
				and a branch displacement counts from the branch itself, so sixteen and not twenty *)
			Emit2(InstructionSet.opBCOND, Condition(InstructionSet.conditionCS), Immediate(16));
			InstructionSet.InitImmediateOffsetMemory(memory, source.register, 1, InstructionSet.indexPost);
			Emit2(InstructionSet.opLDRB, value, memory);
			InstructionSet.InitImmediateOffsetMemory(memory, destination.register, 1, InstructionSet.indexPost);
			Emit2(InstructionSet.opSTRB, value, memory);
			Emit1(InstructionSet.opB, Immediate(loop - out.pc));

			ReleaseHint(value.register); ReleaseHint(last.register);
			ReleaseHint(source.register); ReleaseHint(destination.register)
		END EmitCopy;

		(** cas <address>, <comparand>, <comparator> -- the load-exclusive, store-exclusive loop **)
		PROCEDURE EmitCas(VAR irInstruction: IntermediateCode.Instruction);
		VAR address, comparand, comparator, status, loaded, memory: Operand;
			type: IntermediateCode.Type; loop: SIZE;
		BEGIN
			type := irInstruction.op2.type;
			address := GetFreeRegister(AddressType());
			MovIfDifferent(address, RegisterFromIrOperand(irInstruction.op1, address));
			InstructionSet.InitImmediateOffsetMemory(memory, address.register, 0, InstructionSet.indexOffset);
			loaded := ResultRegister(type);

			IF IntermediateCode.OperandEquals(irInstruction.op2, irInstruction.op3) THEN
				Emit2(InstructionSet.opLDAR, loaded, memory)
			ELSE
				comparand := RegisterFromIrOperand(irInstruction.op2, emptyOperand);
				comparator := RegisterFromIrOperand(irInstruction.op3, emptyOperand);
				status := GetFreeRegister(IntermediateCode.UnsignedIntegerType(32));
				loop := out.pc;
				Emit2(InstructionSet.opLDAXR, loaded, memory);
				Emit2(InstructionSet.opCMP, loaded, comparand);
				Emit2(InstructionSet.opBCOND, Condition(InstructionSet.conditionNE), Immediate(12));
				Emit3(InstructionSet.opSTLXR, status, comparator, memory);
				Emit2(InstructionSet.opCBNZ, status, Immediate(loop - out.pc));
				ReleaseHint(status.register)
			END;
			ReleaseHint(address.register)
		END EmitCas;

		PROCEDURE EmitFill(CONST irInstruction: IntermediateCode.Instruction);
		BEGIN
			Error(Basic.invalidPosition, "fill is not implemented for A64")
		END EmitFill;

		PROCEDURE EmitAsm(CONST irInstruction: IntermediateCode.Instruction);
		VAR reader: Streams.StringReader; procedure: SyntaxTree.Procedure; scope: SyntaxTree.Scope;
			symbol: SyntaxTree.Symbol; assembler: Assembler.Assembler;
			scanner: Scanner.AssemblerScanner; length: SIZE;
		BEGIN
			length := Strings.Length(irInstruction.op1.string^);
			NEW(reader, length);
			reader.Set(irInstruction.op1.string^);

			symbol := in.symbol;
			IF symbol = NIL THEN scope := NIL
			ELSE procedure := symbol(SyntaxTree.Procedure); scope := procedure.procedureScope
			END;

			NEW(assembler, diagnostics);
			NEW(scanner, module.moduleName, reader, irInstruction.textPosition, diagnostics);
			scanner.useLineNumbers := Compiler.UseLineNumbers IN backend.flags;
			assembler.InlineAssemble(scanner, in, scope, module);
			error := error OR assembler.error
		END EmitAsm;

		PROCEDURE EmitSpecial(VAR irInstruction: IntermediateCode.Instruction);
		BEGIN
			Error(Basic.invalidPosition, "this special instruction is not implemented for A64")
		END EmitSpecial;

		(*------------------- the instruction switch ----------------------*)

		PROCEDURE Generate*(VAR irInstruction: IntermediateCode.Instruction);
		BEGIN
			ReserveOperandRegisters(irInstruction.op1, TRUE);
			ReserveOperandRegisters(irInstruction.op2, TRUE);
			ReserveOperandRegisters(irInstruction.op3, TRUE);

			CASE irInstruction.opcode OF
			| IntermediateCode.nop:
			| IntermediateCode.mov: EmitMov(irInstruction)
			| IntermediateCode.conv: EmitConv(irInstruction)
			| IntermediateCode.call: EmitCall(irInstruction)
			| IntermediateCode.enter: EmitEnter(irInstruction)
			| IntermediateCode.leave: EmitLeave(irInstruction)
			| IntermediateCode.exit: EmitExit(irInstruction)
			| IntermediateCode.return: EmitReturn(irInstruction)
			| IntermediateCode.result: EmitResult(irInstruction)
			| IntermediateCode.trap: EmitTrap(irInstruction)
			| IntermediateCode.br .. IntermediateCode.brlt: EmitBr(irInstruction)
			| IntermediateCode.pop: EmitPop(irInstruction.op1)
			| IntermediateCode.push: EmitPush(irInstruction.op1)
			| IntermediateCode.neg: EmitNeg(irInstruction)
			| IntermediateCode.not: EmitNot(irInstruction)
			| IntermediateCode.abs: EmitAbs(irInstruction)
			| IntermediateCode.mul: EmitMul(irInstruction)
			| IntermediateCode.div, IntermediateCode.mod: EmitDivOrMod(irInstruction)
			| IntermediateCode.sub, IntermediateCode.add: EmitAddOrSub(irInstruction)
			| IntermediateCode.and: EmitLogical(irInstruction, InstructionSet.opAND)
			| IntermediateCode.or: EmitLogical(irInstruction, InstructionSet.opORR)
			| IntermediateCode.xor: EmitLogical(irInstruction, InstructionSet.opEOR)
			| IntermediateCode.shl, IntermediateCode.shr, IntermediateCode.rol, IntermediateCode.ror:
				EmitShiftOrRotation(irInstruction)
			| IntermediateCode.cas: EmitCas(irInstruction)
			| IntermediateCode.copy: EmitCopy(irInstruction)
			| IntermediateCode.fill: EmitFill(irInstruction)
			| IntermediateCode.asm: EmitAsm(irInstruction)
			| IntermediateCode.special: EmitSpecial(irInstruction)
			END;

			ReserveOperandRegisters(irInstruction.op3, FALSE);
			ReserveOperandRegisters(irInstruction.op2, FALSE);
			ReserveOperandRegisters(irInstruction.op1, FALSE)
		END Generate;

		PROCEDURE PostGenerate*(CONST irInstruction: IntermediateCode.Instruction);
		VAR ticket: Ticket;
		BEGIN
			TryUnmap(irInstruction.op3); TryUnmap(irInstruction.op2); TryUnmap(irInstruction.op1);
			ticket := tickets.live;
			WHILE (ticket # NIL) & (ticket.lastuse = inPC) DO
				UnmapTicket(ticket);
				ticket := tickets.live
			END
		END PostGenerate;

	END CodeGeneratorA64;

	BackendA64* = OBJECT (IntermediateBackend.IntermediateBackend)
	VAR
		system: Global.System;
		intParameterIndex, floatParameterIndex: INTEGER;
		initLocals-: BOOLEAN;
		cg: CodeGeneratorA64;

		PROCEDURE & InitBackendA64;
		BEGIN
			InitIntermediateBackend;
			system := NIL;
			intParameterIndex := 0;
			floatParameterIndex := 0;
			initLocals := TRUE;
			SetHasLinkRegister;
			SetName("A64");
			NEW(cg, diagnostics, SELF)
		END InitBackendA64;

		PROCEDURE Initialize*(diagnostics: Diagnostics.Diagnostics; log: Streams.Writer; flags: SET; checker: SemanticChecker.Checker; system: Global.System);
		BEGIN
			Initialize^(diagnostics, log, flags, checker, system);
			NEW(cg, diagnostics, SELF)
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

		(** whether the code generator can emit an intermediate code instruction directly **)
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

		PROCEDURE ProcessIntermediateCodeModule*(intermediateCodeModule: Formats.GeneratedModule): Formats.GeneratedModule;
		VAR result: Formats.GeneratedModule;
		BEGIN
			ASSERT(intermediateCodeModule IS Sections.Module);
			result := ProcessIntermediateCodeModule^(intermediateCodeModule);
			IF ~error THEN
				GenerateBinary(result(Sections.Module), dump);
				IF dump # NIL THEN
					dump.Ln; dump.Ln;
					dump.String("------------------ binary code -------------------"); dump.Ln;
					IF (traceString = "") OR (traceString = "*") THEN
						result.Dump(dump); dump.Update
					ELSE
						Sections.DumpFiltered(dump, result(Sections.Module), traceString); dump.Update
					END
				END
			END;
			RETURN result
		END ProcessIntermediateCodeModule;

		(** generate machine code for every section of the module **)
		PROCEDURE GenerateBinary(module: Sections.Module; dump: Streams.Writer);
		VAR in: Sections.Section; out: BinaryCode.Section; procedure: SyntaxTree.Procedure;
			i, j, initialSectionCount: SIZE;

			(* a fixup names a section and an offset within it; once that section has machine code,
				the offset becomes a displacement in bytes *)
			PROCEDURE PatchFixups(section: BinaryCode.Section);
			VAR resolved: BinaryCode.Section; fixup: BinaryCode.Fixup; displacement, symbolOffset: SIZE;
				in: IntermediateCode.Section; symbol: Sections.Section;
			BEGIN
				fixup := section.fixupList.firstFixup;
				WHILE fixup # NIL DO
					symbol := module.allSections.FindByName(fixup.symbol.name);
					IF (symbol # NIL) & (symbol(IntermediateCode.Section).resolved # NIL) THEN
						resolved := symbol(IntermediateCode.Section).resolved(BinaryCode.Section);
						in := symbol(IntermediateCode.Section);
						symbolOffset := fixup.symbolOffset;
						IF symbolOffset = in.pc THEN displacement := resolved.pc
						ELSIF symbolOffset # 0 THEN
							ASSERT(in.pc > symbolOffset);
							displacement := in.instructions[symbolOffset].pc
						ELSE displacement := 0
						END;
						fixup.SetSymbol(fixup.symbol.name, fixup.symbol.fingerprint, 0, fixup.displacement + displacement)
					END;
					fixup := fixup.nextFixup
				END
			END PatchFixups;

		BEGIN
			cg.SetModule(module);
			cg.dump := dump;

			FOR i := 0 TO module.allSections.Length() - 1 DO
				in := module.allSections.GetSection(i);
				IF in.type = Sections.InlineCodeSection THEN
					out := ResolvedSection(in(IntermediateCode.Section));
					cg.dump := out.comments;
					cg.Section(in(IntermediateCode.Section), out);
					IF in.symbol # NIL THEN
						procedure := in.symbol(SyntaxTree.Procedure);
						procedure.procedureScope.body.code.SetBinaryCode(out.os.bits)
					END
				END
			END;

			initialSectionCount := 0;
			REPEAT
				j := initialSectionCount;
				initialSectionCount := module.allSections.Length();
				FOR i := j TO initialSectionCount - 1 DO
					in := module.allSections.GetSection(i);
					IF in.type # Sections.InlineCodeSection THEN
						out := ResolvedSection(in(IntermediateCode.Section));
						cg.Section(in(IntermediateCode.Section), out)
					END
				END
			UNTIL initialSectionCount = module.allSections.Length();

			FOR i := 0 TO module.allSections.Length() - 1 DO
				in := module.allSections.GetSection(i);
				PatchFixups(in(IntermediateCode.Section).resolved)
			END;

			IF cg.error THEN Error("", Basic.invalidPosition, Streams.Invalid, "") END
		END GenerateBinary;

		PROCEDURE DefineOptions*(options: Options.Options);
		BEGIN
			DefineOptions^(options);
		END DefineOptions;

		PROCEDURE GetOptions*(options: Options.Options);
		BEGIN
			IF options.GetFlag("noInitLocals") THEN initLocals := FALSE END;
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

	(** the binary section an intermediate section writes into, created on first demand **)
	PROCEDURE ResolvedSection(irSection: IntermediateCode.Section): BinaryCode.Section;
	VAR result: BinaryCode.Section;
	BEGIN
		IF irSection.resolved = NIL THEN
			NEW(result, irSection.type, 8, irSection.name, irSection.comments # NIL, FALSE);
			(* every A64 instruction is four bytes and must be four byte aligned *)
			IF ~irSection.fixed & (irSection.positionOrAlignment < 4) THEN
				result.SetAlignment(FALSE, 4)
			ELSE
				result.SetAlignment(irSection.fixed, irSection.positionOrAlignment)
			END;
			irSection.SetResolved(result)
		ELSE
			result := irSection.resolved
		END;
		RETURN result
	END ResolvedSection;

	(** two to the power of n, for the halfword walk of a constant **)
	PROCEDURE Pow2(n: SIGNED32): Basic.Integer;
	VAR result: Basic.Integer; i: SIGNED32;
	BEGIN
		result := 1;
		FOR i := 1 TO n DO result := result * 2 END;
		RETURN result
	END Pow2;

	(** the bitwise complement, within a given width **)
	PROCEDURE Not(value: Basic.Integer; width: SIGNED32): Basic.Integer;
	BEGIN
		IF width = 32 THEN RETURN (-value - 1) MOD 100000000H END;
		RETURN -value - 1
	END Not;

	(** the bit pattern of a floating point number, which is what a constant is built out of **)
	PROCEDURE SYSTEMBits32(value: FLOAT32): SIGNED32;
	VAR result: SIGNED32;
	BEGIN
		result := 0;
		SYSTEM.MOVE(ADDRESS OF value, ADDRESS OF result, 4);
		RETURN result
	END SYSTEMBits32;

	PROCEDURE SYSTEMBits64(value: FLOAT64): SIGNED64;
	VAR result: SIGNED64;
	BEGIN
		result := 0;
		SYSTEM.MOVE(ADDRESS OF value, ADDRESS OF result, 8);
		RETURN result
	END SYSTEMBits64;

	(** get an instance of the A64 backend **)
	PROCEDURE Get*(): Backend.Backend;
	VAR result: BackendA64;
	BEGIN
		NEW(result);
		RETURN result
	END Get;

END FoxA64Backend.

System.FreeDownTo FoxA64Backend ~
