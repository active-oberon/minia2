MODULE FoxA64Assembler; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "parse A64 assembly written inside a module"; *)

(*
	The parser behind a CODE block in a module compiled for an A64 target. It reads the syntax the
	Arm assembler reads, turns it into a FoxA64InstructionSet.Instruction, and hands that to the
	encoder; every rule about which operands an instruction accepts lives in the encoder, so a
	mistake is reported once, from one place, rather than checked twice and disagreed about.

	Two places in the grammar need a decision that a token alone does not settle:

	- After a register, a comma may introduce a modifier of that operand (`x2, lsl #3`) or the next
	  operand (`x1, x2`). Which it is depends on whether the identifier after the comma names a
	  shift or an extension, so the parser looks, and puts the token back by not consuming it.

	- Inside brackets, `[x1], #8` is post indexing and `[x1, #8]` is not, so the closing bracket is
	  looked for before the comma rather than after it.

	Widths come from the register names, as they do in the architecture's own syntax: `add w0, w1,
	w2` and `add x0, x1, x2` differ in the registers and in nothing else.
*)

IMPORT
	InstructionSet := FoxA64InstructionSet, FoxAssembler, Scanner := FoxScanner,
	Diagnostics, Basic := FoxBasic, Commands, Sections := FoxSections,
	IntermediateCode := FoxIntermediateCode, BinaryCode := FoxBinaryCode;

CONST
	InstructionSize = 4;		(* every A64 instruction, without exception *)

TYPE
	Assembler* = OBJECT (FoxAssembler.Assembler)

		PROCEDURE & Init2*(diagnostics: Diagnostics.Diagnostics);
		BEGIN Init(diagnostics)
		END Init2;

		(** a register name, which carries the width the instruction will use **)
		PROCEDURE GetRegister*(VAR register: SIGNED32; VAR size: SIGNED16; VAR isStackPointer: BOOLEAN): BOOLEAN;
		BEGIN
			IF token.symbol # Scanner.Identifier THEN RETURN FALSE END;
			IF ~InstructionSet.RegisterFromName(token.identifierString, register, size, isStackPointer) THEN
				RETURN FALSE
			END;
			NextToken;
			RETURN TRUE
		END GetRegister;

		(** LSL, LSR, ASR or ROR **)
		PROCEDURE GetShift*(VAR shift: SIGNED32): BOOLEAN;
		BEGIN
			IF token.symbol # Scanner.Identifier THEN RETURN FALSE END;
			shift := InstructionSet.ShiftFromName(token.identifierString);
			IF shift = InstructionSet.None THEN RETURN FALSE END;
			NextToken;
			RETURN TRUE
		END GetShift;

		(** one of the eight extensions, UXTB through SXTX **)
		PROCEDURE GetExtend*(VAR extend: SIGNED32): BOOLEAN;
		BEGIN
			IF token.symbol # Scanner.Identifier THEN RETURN FALSE END;
			extend := InstructionSet.ExtendFromName(token.identifierString);
			IF extend = InstructionSet.None THEN RETURN FALSE END;
			NextToken;
			RETURN TRUE
		END GetExtend;

		PROCEDURE GetCondition*(VAR condition: SIGNED32): BOOLEAN;
		BEGIN
			IF token.symbol # Scanner.Identifier THEN RETURN FALSE END;
			condition := InstructionSet.ConditionFromName(token.identifierString);
			IF condition = InstructionSet.None THEN RETURN FALSE END;
			NextToken;
			RETURN TRUE
		END GetCondition;

		(** any expression that evaluates to a constant **)
		PROCEDURE GetPlainValue*(VAR value: Basic.Integer): BOOLEAN;
		VAR result: FoxAssembler.Result;
		BEGIN
			IF Expression(result, FALSE) & ((result.type = FoxAssembler.ConstantInteger) OR (result.type = FoxAssembler.Offset)) THEN
				value := result.value;
				RETURN TRUE
			ELSE
				value := 0;
				RETURN FALSE
			END
		END GetPlainValue;

		(** an immediate: '#' and then a constant expression

			The one floating point immediate A64 has is the zero of `fcmp d0, #0.0`, and it is read
			here rather than through the shared expression parser, which builds an integer out of
			every number it is given. Nothing else in the instruction set takes a floating point
			constant: the others are loaded from memory.
		**)
		PROCEDURE GetImmediateValue*(VAR value: Basic.Integer): BOOLEAN;
		BEGIN
			(* the scanner reads '#' as the unequal sign, there being no other use for it *)
			IF ~ThisSymbol(Scanner.Unequal) THEN RETURN FALSE END;
			IF (token.symbol = Scanner.Number)
					& ((token.numberType = Scanner.Real) OR (token.numberType = Scanner.Longreal)) THEN
				IF token.real # 0 THEN
					Error(errorPosition, "the only floating point immediate is zero");
					RETURN FALSE
				END;
				value := 0;
				NextToken;
				RETURN TRUE
			END;
			RETURN GetPlainValue(value)
		END GetImmediateValue;

		(** whether the identifier the parser is looking at names a modifier of the operand just
			read rather than the beginning of the next one **)
		PROCEDURE AtModifier(): BOOLEAN;
		BEGIN
			IF token.symbol # Scanner.Identifier THEN RETURN FALSE END;
			RETURN (InstructionSet.ShiftFromName(token.identifierString) # InstructionSet.None)
				OR (InstructionSet.ExtendFromName(token.identifierString) # InstructionSet.None)
		END AtModifier;

		PROCEDURE Instruction*(CONST mnemonic: ARRAY OF CHAR);
		VAR
			instruction: InstructionSet.Instruction;
			operands: ARRAY InstructionSet.MaxOperands OF InstructionSet.Operand;
			position: Basic.Position;
			opCode, condition, i, operandNumber: SIGNED32;
			moreOperands: BOOLEAN;

			(* parse one operand, and the comma after it when another one follows *)
			PROCEDURE ParseOperand;
			VAR
				operand: InstructionSet.Operand;
				register, index, shift, extend: SIGNED32;
				size, indexSize: SIGNED16;
				isStackPointer: BOOLEAN;
				amount, value: Basic.Integer;
				indexing: SIGNED8;
				result: FoxAssembler.Result;
				position: Basic.Position;

				(* the shift or extension a register operand may carry *)
				PROCEDURE ParseModifier(VAR shift, extend: SIGNED32; VAR amount: Basic.Integer): BOOLEAN;
				BEGIN
					shift := InstructionSet.None; extend := InstructionSet.None; amount := 0;
					IF GetShift(shift) THEN
						IF ~GetImmediateValue(amount) THEN
							Error(errorPosition, "shift amount expected"); RETURN FALSE
						END
					ELSIF GetExtend(extend) THEN
						(* the amount is optional in an extension, and defaults to nothing *)
						IF token.symbol = Scanner.Unequal THEN
							IF ~GetImmediateValue(amount) THEN
								Error(errorPosition, "extension amount expected"); RETURN FALSE
							END
						END
					ELSE
						RETURN FALSE
					END;
					RETURN TRUE
				END ParseModifier;

				(* after an operand, a comma introduces either a modifier of it -- `x2, lsl #3`,
					`#1, lsl #12` -- or the next operand. Which one is decided by looking at the
					identifier behind the comma; FALSE means the line is in error. *)
				PROCEDURE ParseTrailingModifier(VAR operand: InstructionSet.Operand): BOOLEAN;
				VAR shift, extend: SIGNED32; amount: Basic.Integer;
				BEGIN
					IF error OR (token.symbol # Scanner.Comma) THEN RETURN TRUE END;
					NextToken;
					IF ~AtModifier() THEN moreOperands := TRUE; RETURN TRUE END;
					IF ~ParseModifier(shift, extend, amount) THEN RETURN FALSE END;
					operand.shiftMode := SIGNED8(shift);
					operand.extend := SIGNED8(extend);
					operand.shiftAmount := SIGNED32(amount);
					RETURN TRUE
				END ParseTrailingModifier;

			BEGIN
				moreOperands := FALSE;
				position := errorPosition;
				IF operandNumber >= InstructionSet.MaxOperands THEN
					Error(position, "too many operands");
					RETURN
				END;
				InstructionSet.InitOperand(operand);

				IF ThisSymbol(Scanner.LeftBracket) THEN
					(* an address: [base], [base, #offset], [base, #offset]!, [base], #offset,
						[base, index] or [base, index, extend #amount] *)
					indexing := InstructionSet.indexOffset;
					IF ~GetRegister(register, size, isStackPointer) THEN
						Error(errorPosition, "base register expected"); RETURN
					END;
					IF size # 64 THEN Error(position, "the base of an address is a 64 bit register") END;

					IF ThisSymbol(Scanner.RightBracket) THEN
						(* the bracket closed before any offset: either there is none, or what
							follows the comma is a post indexed one *)
						IF (token.symbol = Scanner.Comma) & ~error THEN
							NextToken;
							IF ~GetImmediateValue(value) THEN
								Error(errorPosition, "offset expected after ']'"); RETURN
							END;
							indexing := InstructionSet.indexPost;
							InstructionSet.InitImmediateOffsetMemory(operand, register, value, indexing)
						ELSE
							InstructionSet.InitImmediateOffsetMemory(operand, register, 0, indexing)
						END
					ELSIF ThisSymbol(Scanner.Comma) THEN
						IF GetImmediateValue(value) THEN
							IF ~ExpectSymbol(Scanner.RightBracket) THEN RETURN END;
							IF ThisSymbol(Scanner.ExclamationMark) THEN indexing := InstructionSet.indexPre END;
							InstructionSet.InitImmediateOffsetMemory(operand, register, value, indexing)
						ELSIF GetRegister(index, indexSize, isStackPointer) THEN
							shift := InstructionSet.None; extend := InstructionSet.None; amount := 0;
							IF ThisSymbol(Scanner.Comma) THEN
								IF ~ParseModifier(shift, extend, amount) THEN
									Error(errorPosition, "shift or extension expected"); RETURN
								END;
								(* an index shifted rather than extended is an unextended index,
									which is what UXTX encodes *)
								IF shift = InstructionSet.shiftLSL THEN extend := InstructionSet.extendUXTX
								ELSIF shift # InstructionSet.None THEN
									Error(position, "the index of an address can only be shifted left"); RETURN
								END
							END;
							IF ~ExpectSymbol(Scanner.RightBracket) THEN RETURN END;
							InstructionSet.InitRegisterOffsetMemory(operand, register, index, indexSize,
								SIGNED8(extend), SIGNED32(amount))
						ELSE
							Error(errorPosition, "offset or index register expected"); RETURN
						END
					ELSE
						Error(errorPosition, "',' or ']' expected"); RETURN
					END

				ELSIF GetRegister(register, size, isStackPointer) THEN
					InstructionSet.InitRegister(operand, register, size);
					operand.isStackPointer := isStackPointer;
					IF ~ParseTrailingModifier(operand) THEN RETURN END

				ELSIF GetCondition(condition) THEN
					InstructionSet.InitCondition(operand, SIGNED8(condition))

				ELSIF GetImmediateValue(value) THEN
					InstructionSet.InitImmediate(operand, value);
					IF ~ParseTrailingModifier(operand) THEN RETURN END

				ELSIF (token.symbol = Scanner.Identifier)
						& ((opCode = InstructionSet.opMRS) OR (opCode = InstructionSet.opMSR))
						& (InstructionSet.SystemRegisterFromName(token.identifierString) # InstructionSet.None) THEN
					(* a system register, which only these two instructions take and which is
						therefore not looked for anywhere else: FPCR is a plausible name for a
						variable of a module *)
					InstructionSet.InitImmediate(operand, InstructionSet.SystemRegisterFromName(token.identifierString));
					NextToken

				ELSIF (token.symbol = Scanner.Identifier) & GetNonConstant(errorPosition, token.identifierString, result) THEN
					(* a label that is not resolved yet: the encoder turns it into a fixup *)
					InstructionSet.InitImmediate(operand, result.value);
					IF result.fixup # NIL THEN InstructionSet.AddFixup(operand, result.fixup) END;
					NextToken

				ELSIF GetPlainValue(value) THEN
					InstructionSet.InitImmediate(operand, value)

				ELSE
					Error(position, "invalid operand"); RETURN
				END;

				IF ~moreOperands THEN moreOperands := ThisSymbol(Scanner.Comma) END;
				operands[operandNumber] := operand
			END ParseOperand;

		BEGIN
			position := errorPosition;
			IF ~InstructionSet.FindMnemonic(mnemonic, opCode, condition) THEN
				ErrorSS(position, "unknown mnemonic: ", mnemonic);
				RETURN
			END;

			FOR i := 0 TO InstructionSet.MaxOperands - 1 DO
				InstructionSet.InitOperand(operands[i])
			END;
			operandNumber := 0;

			IF opCode = InstructionSet.opBCOND THEN
				(* the condition was written in the mnemonic, and is the first operand *)
				InstructionSet.InitCondition(operands[0], SIGNED8(condition));
				operandNumber := 1
			END;

			(* an instruction without operands runs into the end of the line, or into the end of the
				text when it is the last one *)
			IF (token.symbol # Scanner.Ln) & (token.symbol # Scanner.EndOfText) THEN
				REPEAT
					ParseOperand;
					INC(operandNumber)
				UNTIL error OR ~moreOperands
			END;

			IF error THEN RETURN END;

			InstructionSet.MakeInstruction(instruction, opCode, operands);
			IF pass < FoxAssembler.MaxPasses THEN
				(* not the last pass: the only thing that matters is how far the pc moves *)
				section.resolved.SetPC(section.resolved.pc + InstructionSize)
			ELSIF ~InstructionSet.EmitInstruction(instruction, section.resolved) THEN
				ErrorSS(position, "operands do not name an instruction: ", mnemonic)
			END
		END Instruction;

	END Assembler;

	(** assemble the text that follows the command and write the words it produced, one per line

		Nothing in the compiler drives the parser without a code generator behind it, so this is how
		it is exercised: the same instructions the encoder's own self test prints are read back
		through the parser here, and the words have to come out the same. That checks the parser
		against the encoder, and -- since the encoder's output is checked against llvm-mc -- the
		parser against llvm-mc as well.

		The section and module the parser writes into are the smallest ones that satisfy it: it
		needs somewhere to put bits and somewhere to look a symbol up, and neither has to belong to
		a real compilation.
	**)
	PROCEDURE Test*(context: Commands.Context);
	VAR
		diagnostics: Diagnostics.StreamDiagnostics;
		assembler: Assembler;
		scanner: Scanner.AssemblerScanner;
		section: IntermediateCode.Section;
		binary: BinaryCode.Section;
		module: Sections.Module;
		name: Basic.SegmentedName;
		position: SIZE; word: SIGNED64; i, nibble: SIGNED32;
	BEGIN
		NEW(diagnostics, context.error);
		Basic.ToSegmentedName("A64Test", name);
		NEW(binary, Sections.CodeSection, 8, name, FALSE, FALSE);
		NEW(section, Sections.CodeSection, name, NIL, FALSE);
		section.SetResolved(binary);
		NEW(module, NIL, NIL);

		scanner := Scanner.NewAssemblerScanner("a64", context.arg, 0, diagnostics);
		NEW(assembler, diagnostics);
		assembler.InlineAssemble(scanner, section, NIL, module);
		IF assembler.error THEN context.result := Commands.CommandError; RETURN END;

		position := 0;
		WHILE position < binary.pc DO
			word := binary.os.bits.GetBits(position * 8, 32);
			FOR i := 7 TO 0 BY -1 DO
				nibble := SIGNED32(word DIV ASH(1, i * 4)) MOD 16;
				IF nibble < 10 THEN context.out.Char(CHR(ORD('0') + nibble))
				ELSE context.out.Char(CHR(ORD('a') + nibble - 10))
				END
			END;
			context.out.Ln;
			INC(position, InstructionSize)
		END;
		context.out.Update
	END Test;

END FoxA64Assembler.

System.FreeDownTo FoxA64Assembler ~
