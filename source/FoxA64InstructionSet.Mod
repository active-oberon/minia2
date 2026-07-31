MODULE FoxA64InstructionSet; (** AUTHOR "Andrii Puhachenko; co-author Claude (Opus 5)"; PURPOSE "the A64 instruction set: how an instruction is written, and how it is encoded"; *)

(*
	A64 is a fixed width instruction set -- every instruction is exactly four bytes -- and its
	encodings are grouped by construction rather than by history. That is why this module does not
	repeat the shape of FoxARMInstructionSet, which matches an instruction against a table of
	several hundred formats and encodes it operand by operand: on A64 the group determines the
	layout, so `Encode` dispatches on the mnemonic to one encoder per group and each encoder writes
	its fields directly. The table that would carry that information is instead the CASE statement,
	where it can be read against the Arm Architecture Reference Manual section it comes from.

	Aliases are resolved here rather than by the caller. CMP is SUBS to the zero register, LSL of an
	immediate is UBFM, CSET is CSINC of two zero registers with the condition inverted; the caller
	writes what it means and this module writes what the processor executes. DumpInstruction prints
	the instruction as it was written, not as it was encoded, because that is what a listing is for.

	Registers are numbered the way FoxA64Backend numbers them, which is the only numbering the
	compiler carries across a module boundary: 0..30 are the general purpose registers, 31 is SP or
	the zero register depending on the instruction, and 32..63 are V0..V31. Whether register 31
	means SP or ZR is a property of the encoding and not of the operand, so the operand records
	which of the two names was written (isStackPointer) and each encoder enforces the one its form
	allows -- getting that wrong does not produce an error, it produces a different instruction.

	Width lives on the operand rather than in the mnemonic, again as the assembly syntax has it:
	`add w0, w1, w2` and `add x0, x1, x2` are one mnemonic and differ in the sf bit, which is read
	off the destination register.

	Not here, deliberately:
	- Decode, and with it a disassembler. Nothing needs it yet; the listing comes from the encoder.
	- The 8-bit floating point immediate of FMOV. It cannot encode zero, which is the constant that
	  actually turns up, and zero is written FMOV Dd, XZR instead. Other constants come from memory.
	- Anything SIMD beyond the scalar floating point instructions.
*)

IMPORT SYSTEM, Commands, Streams, Strings, Basic := FoxBasic, BinaryCode := FoxBinaryCode, ObjectFile;

CONST
	None* = -1;
	MaxOperands* = 5;

	(* register numbers -- these are the numbers FoxA64Backend uses, see the comment there *)
	X0* = 0;  LR* = 30;  SP* = 31;  ZR* = 31;
	V0* = 32;

	(* operand modes *)
	modeNone* = 0;
	modeRegister* = 1;
	modeImmediate* = 2;
	modeMemory* = 3;
	modeCondition* = 4;

	(* shift modes, values refer to the encoding of the shift field, do not modify *)
	shiftLSL* = 0;  shiftLSR* = 1;  shiftASR* = 2;  shiftROR* = 3;

	(* extend options, values refer to the encoding of the option field, do not modify *)
	extendUXTB* = 0;  extendUXTH* = 1;  extendUXTW* = 2;  extendUXTX* = 3;
	extendSXTB* = 4;  extendSXTH* = 5;  extendSXTW* = 6;  extendSXTX* = 7;

	(* addressing modes of a memory operand, values have no meaning in the encoding *)
	indexOffset* = 0;  indexPre* = 1;  indexPost* = 2;

	(* condition codes, values refer to the encoding, do not modify *)
	conditionEQ* = 0;  conditionNE* = 1;
	conditionCS* = 2;  conditionCC* = 3;
	conditionMI* = 4;  conditionPL* = 5;
	conditionVS* = 6;  conditionVC* = 7;
	conditionHI* = 8;  conditionLS* = 9;
	conditionGE* = 10; conditionLT* = 11;
	conditionGT* = 12; conditionLE* = 13;
	conditionAL* = 14; conditionNV* = 15;
	NumberConditions = 16;

	(* mnemonics; the values have no meaning in any encoding, but Init asserts that every one of
		them is given a name, which is what catches a miscounted constant *)

	(* add and subtract, and the comparisons that are aliases of them *)
	opADD* = 0;  opADDS* = 1;  opSUB* = 2;  opSUBS* = 3;
	opCMP* = 4;  opCMN* = 5;  opNEG* = 6;  opNEGS* = 7;

	(* logical operations, and their aliases *)
	opAND* = 8;  opANDS* = 9;  opORR* = 10; opORN* = 11;
	opEOR* = 12; opEON* = 13; opBIC* = 14; opBICS* = 15;
	opTST* = 16; opMVN* = 17; opMOV* = 18;

	(* move wide immediate *)
	opMOVZ* = 19; opMOVN* = 20; opMOVK* = 21;

	(* pc relative addresses *)
	opADR* = 22; opADRP* = 23;

	(* bitfield moves, and the aliases that are the reason anybody writes one *)
	opSBFM* = 24; opBFM* = 25;  opUBFM* = 26;
	opSBFIZ* = 27; opSBFX* = 28; opUBFIZ* = 29; opUBFX* = 30;
	opBFI* = 31;  opBFXIL* = 32;
	opSXTB* = 33; opSXTH* = 34; opSXTW* = 35; opUXTB* = 36; opUXTH* = 37;

	(* shifts: an immediate shift is a bitfield move, a variable shift is its own instruction *)
	opLSL* = 38; opLSR* = 39; opASR* = 40; opROR* = 41; opEXTR* = 42;

	(* multiply and divide *)
	opMUL* = 43;  opMNEG* = 44;  opMADD* = 45;  opMSUB* = 46;
	opSMULL* = 47; opSMNEGL* = 48; opSMADDL* = 49; opSMSUBL* = 50;
	opUMULL* = 51; opUMNEGL* = 52; opUMADDL* = 53; opUMSUBL* = 54;
	opSMULH* = 55; opUMULH* = 56;  opSDIV* = 57;   opUDIV* = 58;

	(* counting and reversing bits *)
	opCLZ* = 59; opCLS* = 60; opRBIT* = 61; opREV* = 62; opREV16* = 63; opREV32* = 64;

	(* conditional select, and the aliases that make a condition into a value *)
	opCSEL* = 65; opCSINC* = 66; opCSINV* = 67; opCSNEG* = 68;
	opCSET* = 69; opCSETM* = 70; opCINC* = 71; opCINV* = 72; opCNEG* = 73;

	(* branches *)
	opB* = 74;  opBL* = 75;  opBCOND* = 76; opBR* = 77; opBLR* = 78; opRET* = 79;
	opCBZ* = 80; opCBNZ* = 81; opTBZ* = 82; opTBNZ* = 83;

	(* system *)
	opNOP* = 84; opBRK* = 85; opSVC* = 86; opHLT* = 87;
	opDMB* = 88; opDSB* = 89; opISB* = 90;

	(* loads and stores *)
	opLDR* = 91;  opLDRB* = 92;  opLDRH* = 93;
	opLDRSB* = 94; opLDRSH* = 95; opLDRSW* = 96;
	opSTR* = 97;  opSTRB* = 98;  opSTRH* = 99;
	opLDUR* = 100; opLDURB* = 101; opLDURH* = 102;
	opLDURSB* = 103; opLDURSH* = 104; opLDURSW* = 105;
	opSTUR* = 106; opSTURB* = 107; opSTURH* = 108;
	opLDP* = 109; opSTP* = 110;

	(* the exclusive and ordered accesses an atomic operation is built out of *)
	opLDXR* = 111; opSTXR* = 112; opLDAXR* = 113; opSTLXR* = 114;
	opLDAR* = 115; opSTLR* = 116;

	(* scalar floating point *)
	opFMOV* = 117; opFADD* = 118; opFSUB* = 119; opFMUL* = 120; opFDIV* = 121; opFNMUL* = 122;
	opFNEG* = 123; opFABS* = 124; opFSQRT* = 125; opFMAX* = 126; opFMIN* = 127;
	opFCMP* = 128; opFCMPE* = 129; opFCVT* = 130;
	opSCVTF* = 131; opUCVTF* = 132; opFCVTZS* = 133; opFCVTZU* = 134;
	opFCVTMS* = 135; opFCVTMU* = 136;
	opFCSEL* = 137;

	(* the byte wide exclusive and ordered accesses. The width of these is in the instruction rather
		than in the register -- the register is a W register in every one of them -- so each needs a
		mnemonic of its own, unlike the loads and stores above. *)
	opLDXRB* = 138; opSTXRB* = 139; opLDAXRB* = 140; opSTLXRB* = 141;
	opLDARB* = 142; opSTLRB* = 143;

	(* the conversions that round to the nearest, ties to even, which is the mode a floating point
		unit is in unless something changed it *)
	opFCVTNS* = 144; opFCVTNU* = 145;

	(* the two moves between a general purpose register and a system register *)
	opMRS* = 146; opMSR* = 147;

	NumberMnemonics = 148;

	(* the system registers the encoder knows by name. The value of each is the sixteen bits the
		instruction carries -- op0, op1, CRn, CRm and op2, in that order -- so that the encoder has
		nothing to assemble and the name is only a name. *)
	NumberSystemRegisters = 6;
	sysFPCR* = 0DA20H;			(* the floating point control register *)
	sysFPSR* = 0DA21H;			(* ... and its status register *)
	sysNZCV* = 0DA10H;
	sysTPIDREL0* = 0DE82H;		(* the thread pointer, which is where a thread local variable is *)
	sysCNTVCTEL0* = 0DF02H;		(* the virtual counter, readable from user space *)
	sysCNTFRQEL0* = 0DF00H;		(* ... and the frequency it counts at *)

TYPE
	Name = ARRAY 10 OF CHAR;
	SystemRegisterName = ARRAY 16 OF CHAR;	(* CNTVCT_EL0 does not fit in a Name *)

	(** one operand of an A64 instruction

		The record covers every operand shape the instruction set has, and each encoder reads only
		the fields its form uses. A memory operand is the one that uses most of them: `register` is
		the base, `index` the offset register when there is one, `shiftMode`/`extend`/`shiftAmount`
		the way that offset register is widened and scaled, and `immediate` the offset when there
		is not.
	**)
	Operand* = RECORD
		mode*: SIGNED8;
		register*: SIGNED32;			(* modeRegister: the register; modeMemory: the base register *)
		size*: SIGNED16;				(* width in bits: 32 or 64 for a general purpose register, 8..128 for a V register *)
		isStackPointer*: BOOLEAN;	(* register 31 was written SP (or WSP) rather than ZR *)
		immediate*: Basic.Integer;
		shiftMode*: SIGNED8;			(* None when the operand carries no shift *)
		extend*: SIGNED8;				(* None when the operand carries no extension *)
		shiftAmount*: SIGNED32;		(* amount of the shift or extension above *)
		index*: SIGNED32;				(* modeMemory: the offset register, None when there is none *)
		indexSize*: SIGNED16;
		indexing*: SIGNED8;			(* modeMemory: indexOffset, indexPre or indexPost *)
		condition*: SIGNED8;			(* modeCondition *)
		fixup*: BinaryCode.Fixup;	(* NIL unless the operand names a symbol *)
	END;

	Instruction* = RECORD
		mnemonic*: SIGNED32;
		operands*: ARRAY MaxOperands OF Operand;
	END;

VAR
	mnemonicNames: ARRAY NumberMnemonics OF Name;
	conditionNames: ARRAY NumberConditions OF Name;
	systemRegisterNames: ARRAY NumberSystemRegisters OF SystemRegisterName;
	systemRegisterValues: ARRAY NumberSystemRegisters OF SIGNED32;

(* ---- 64 bit bit twiddling ---------------------------------------------------------------------

	SET is 32 bits wide, so the logical immediate encoder cannot use it. SET64 can, and going
	through it is the only way to write AND, OR and NOT of two SIGNED64 in this language.
*)

	PROCEDURE And64(a, b: SIGNED64): SIGNED64;
	BEGIN RETURN SYSTEM.VAL(SIGNED64, SYSTEM.VAL(SET64, a) * SYSTEM.VAL(SET64, b))
	END And64;

	PROCEDURE Or64(a, b: SIGNED64): SIGNED64;
	BEGIN RETURN SYSTEM.VAL(SIGNED64, SYSTEM.VAL(SET64, a) + SYSTEM.VAL(SET64, b))
	END Or64;

	PROCEDURE Not64(a: SIGNED64): SIGNED64;
	BEGIN RETURN SYSTEM.VAL(SIGNED64, -SYSTEM.VAL(SET64, a))
	END Not64;

	(** the low n bits set; n = 64 is all of them, which is -1 and not something LSH can produce **)
	PROCEDURE Ones(n: SIGNED32): SIGNED64;
	VAR one: SIGNED64;
	BEGIN
		one := 1;
		IF n <= 0 THEN RETURN 0
		ELSIF n >= 64 THEN RETURN -1
		ELSE RETURN LSH(one, n) - 1
		END
	END Ones;

	(** shift right, filling with zeroes rather than with the sign **)
	PROCEDURE Shr64(a: SIGNED64; n: SIGNED32): SIGNED64;
	BEGIN
		IF n <= 0 THEN RETURN a
		ELSIF n >= 64 THEN RETURN 0
		ELSE RETURN And64(LSH(a, -n), Ones(64 - n))
		END
	END Shr64;

	PROCEDURE Shl64(a: SIGNED64; n: SIGNED32): SIGNED64;
	BEGIN
		IF n <= 0 THEN RETURN a
		ELSIF n >= 64 THEN RETURN 0
		ELSE RETURN LSH(a, n)
		END
	END Shl64;

	PROCEDURE TrailingZeros(a: SIGNED64): SIGNED32;
	VAR n: SIGNED32;
	BEGIN
		IF a = 0 THEN RETURN 64 END;
		n := 0;
		WHILE ~ODD(a) DO a := Shr64(a, 1); INC(n) END;
		RETURN n
	END TrailingZeros;

	PROCEDURE TrailingOnes(a: SIGNED64): SIGNED32;
	VAR n: SIGNED32;
	BEGIN
		n := 0;
		WHILE (n < 64) & ODD(a) DO a := Shr64(a, 1); INC(n) END;
		RETURN n
	END TrailingOnes;

	PROCEDURE LeadingOnes(a: SIGNED64): SIGNED32;
	VAR n: SIGNED32;
	BEGIN
		n := 0;
		WHILE (n < 64) & (And64(Shr64(a, 63 - n), 1) = 1) DO INC(n) END;
		RETURN n
	END LeadingOnes;

	(** whether a is 0^k 1^m 0^n with m > 0: a run of ones and nothing else **)
	PROCEDURE IsShiftedMask(a: SIGNED64): BOOLEAN;
	VAR v: SIGNED64;
	BEGIN
		IF a = 0 THEN RETURN FALSE END;
		v := Or64(a, a - 1);				(* fill the zeroes below the run *)
		RETURN And64(v + 1, v) = 0		(* what is left must be a run reaching bit zero *)
	END IsShiftedMask;

(* ---- the logical immediate --------------------------------------------------------------------

	AND, ORR, EOR and ANDS take an immediate that is not a number but a pattern: a run of ones of
	length imms+1, rotated right by immr, replicated to fill the register. Which values that can
	produce is not obvious, so the encoder is the standard search for the element size, the
	rotation and the run length, in that order.
*)

	(** the second half of the search below, once the element size is known **)
	PROCEDURE EncodeLogicalImmediateSized(value: SIGNED64; size: SIGNED32; VAR n, immr, imms: SIGNED32): BOOLEAN;
	VAR i, cto, clo, nimms: SIGNED32; mask: SIGNED64;
	BEGIN
		mask := Ones(size);
		value := And64(value, mask);

		IF IsShiftedMask(value) THEN
			i := TrailingZeros(value);
			cto := TrailingOnes(Shr64(value, i))
		ELSE
			(* the run wraps around the top of the element: fill the bits above the element and
				look at the run of zeroes instead *)
			value := Or64(value, Not64(mask));
			IF ~IsShiftedMask(Not64(value)) THEN RETURN FALSE END;
			clo := LeadingOnes(value);
			i := 64 - clo;
			cto := clo + TrailingOnes(value) - (64 - size)
		END;

		immr := (size - i) MOD size;

		(* imms is the run length minus one, below a prefix of ones that names the element size;
			bit 6 of that prefix, inverted, is N *)
		nimms := SIGNED32(And64(Shl64(Not64(size - 1), 1), Ones(13)));
		nimms := SIGNED32(Or64(nimms, cto - 1));
		n := 1 - SIGNED32(And64(Shr64(nimms, 6), 1));
		imms := SIGNED32(And64(nimms, 3FH));
		RETURN TRUE
	END EncodeLogicalImmediateSized;

	(** find N, immr and imms such that the pattern they describe is `value` in a register of
		`width` bits; FALSE when no such pattern exists, which includes 0 and all ones **)
	PROCEDURE EncodeLogicalImmediate*(value: SIGNED64; width: SIGNED32; VAR n, immr, imms: SIGNED32): BOOLEAN;
	VAR size: SIGNED32; mask: SIGNED64;
	BEGIN
		IF width # 64 THEN
			(* the pattern is replicated to 64 bits by the processor, so a 32 bit operand must not
				carry anything above bit 31, and all ones is as unrepresentable as zero *)
			IF Shr64(value, width) # 0 THEN RETURN FALSE END;
			IF value = Ones(width) THEN RETURN FALSE END
		END;
		IF (value = 0) OR (value = -1) THEN RETURN FALSE END;

		(* the element size is the smallest one the value repeats in *)
		size := width;
		REPEAT
			size := size DIV 2;
			mask := Ones(size);
			IF And64(value, mask) # And64(Shr64(value, size), mask) THEN
				RETURN EncodeLogicalImmediateSized(value, size * 2, n, immr, imms)
			END
		UNTIL size <= 2;
		RETURN EncodeLogicalImmediateSized(value, size, n, immr, imms)
	END EncodeLogicalImmediate;

	(** the condition that holds exactly when this one does not; AL and NV are each other's
		inverse in the encoding, which is why the aliases below never take them **)
	PROCEDURE InvertCondition*(condition: SIGNED8): SIGNED8;
	BEGIN
		IF ODD(condition) THEN RETURN condition - 1 ELSE RETURN condition + 1 END
	END InvertCondition;

(* ---- operand constructors ---------------------------------------------------------------------- *)

	PROCEDURE InitOperand*(VAR operand: Operand);
	BEGIN
		operand.mode := modeNone;
		operand.register := None;
		operand.size := 0;
		operand.isStackPointer := FALSE;
		operand.immediate := 0;
		operand.shiftMode := None;
		operand.extend := None;
		operand.shiftAmount := 0;
		operand.index := None;
		operand.indexSize := 0;
		operand.indexing := indexOffset;
		operand.condition := None;
		operand.fixup := NIL;
	END InitOperand;

	PROCEDURE InitRegister*(VAR operand: Operand; register: SIGNED32; size: SIGNED16);
	BEGIN
		InitOperand(operand);
		operand.mode := modeRegister;
		operand.register := register;
		operand.size := size;
	END InitRegister;

	(** a general purpose register named SP or WSP rather than ZR **)
	PROCEDURE InitStackPointer*(VAR operand: Operand; size: SIGNED16);
	BEGIN
		InitRegister(operand, SP, size);
		operand.isStackPointer := TRUE;
	END InitStackPointer;

	(** a register operand carrying a shift, as the second source of a data processing instruction **)
	PROCEDURE InitShiftedRegister*(VAR operand: Operand; register: SIGNED32; size: SIGNED16; shiftMode: SIGNED8; amount: SIGNED32);
	BEGIN
		InitRegister(operand, register, size);
		operand.shiftMode := shiftMode;
		operand.shiftAmount := amount;
	END InitShiftedRegister;

	(** a register operand carrying an extension, as the second source of an address computation **)
	PROCEDURE InitExtendedRegister*(VAR operand: Operand; register: SIGNED32; size: SIGNED16; extend: SIGNED8; amount: SIGNED32);
	BEGIN
		InitRegister(operand, register, size);
		operand.extend := extend;
		operand.shiftAmount := amount;
	END InitExtendedRegister;

	PROCEDURE InitImmediate*(VAR operand: Operand; immediate: Basic.Integer);
	BEGIN
		InitOperand(operand);
		operand.mode := modeImmediate;
		operand.immediate := immediate;
	END InitImmediate;

	(** an immediate that is shifted left before it is used, as in MOVZ Xd, #imm, LSL #16 **)
	PROCEDURE InitShiftedImmediate*(VAR operand: Operand; immediate: Basic.Integer; amount: SIGNED32);
	BEGIN
		InitImmediate(operand, immediate);
		operand.shiftMode := shiftLSL;
		operand.shiftAmount := amount;
	END InitShiftedImmediate;

	PROCEDURE InitCondition*(VAR operand: Operand; condition: SIGNED8);
	BEGIN
		InitOperand(operand);
		operand.mode := modeCondition;
		operand.condition := condition;
	END InitCondition;

	(** [base, #offset], or [base, #offset]! and [base], #offset when indexing says so **)
	PROCEDURE InitImmediateOffsetMemory*(VAR operand: Operand; base: SIGNED32; offset: Basic.Integer; indexing: SIGNED8);
	BEGIN
		InitOperand(operand);
		operand.mode := modeMemory;
		operand.register := base;
		operand.size := 64;
		operand.isStackPointer := base = SP;
		operand.immediate := offset;
		operand.indexing := indexing;
	END InitImmediateOffsetMemory;

	(** [base, index, extend #amount] -- extend may be None, which means LSL **)
	PROCEDURE InitRegisterOffsetMemory*(VAR operand: Operand; base, index: SIGNED32; indexSize: SIGNED16; extend: SIGNED8; amount: SIGNED32);
	BEGIN
		InitOperand(operand);
		operand.mode := modeMemory;
		operand.register := base;
		operand.size := 64;
		operand.isStackPointer := base = SP;
		operand.index := index;
		operand.indexSize := indexSize;
		operand.extend := extend;
		operand.shiftAmount := amount;
		operand.indexing := indexOffset;
	END InitRegisterOffsetMemory;

	PROCEDURE AddFixup*(VAR operand: Operand; fixup: BinaryCode.Fixup);
	BEGIN operand.fixup := fixup
	END AddFixup;

	PROCEDURE InitInstruction*(VAR instruction: Instruction; mnemonic: SIGNED32);
	VAR i: SIGNED32;
	BEGIN
		instruction.mnemonic := mnemonic;
		FOR i := 0 TO MaxOperands - 1 DO InitOperand(instruction.operands[i]) END;
	END InitInstruction;

	PROCEDURE MakeInstruction*(VAR instruction: Instruction; mnemonic: SIGNED32; CONST operands: ARRAY OF Operand);
	VAR i: SIZE;
	BEGIN
		InitInstruction(instruction, mnemonic);
		FOR i := 0 TO LEN(operands) - 1 DO
			IF i < MaxOperands THEN instruction.operands[i] := operands[i] END
		END;
	END MakeInstruction;

(* ---- encoding ------------------------------------------------------------------------------- *)

	(** encode one instruction into the 32 bit word the processor reads

		FALSE means the mnemonic and the operands do not name an instruction that exists -- an
		immediate out of range, a register of the wrong width, an addressing mode the form does not
		have. It is never a silent approximation.
	**)
	PROCEDURE Encode*(CONST instruction: Instruction; VAR code: SIGNED32): BOOLEAN;
	VAR
		codeSet: SET32;			(* SET is the width of an address here, and an instruction is 32 bits *)
		error: BOOLEAN;
		o0, o1, o2, o3: Operand;
		zero, temp: Operand;
		width: SIGNED32;

		(* write an unsigned field; everything above the field must be zero *)
		PROCEDURE Put(value: SIGNED64; from, to: SIGNED32);
		VAR i: SIGNED32;
		BEGIN
			FOR i := from TO to DO
				IF ODD(value) THEN INCL(codeSet, i) END;
				value := value DIV 2
			END;
			IF value # 0 THEN error := TRUE END
		END Put;

		(* write a two's complement field; DIV rounds towards minus infinity, so the bits come out
			right and a negative value converges to -1 rather than to 0 *)
		PROCEDURE PutSigned(value: SIGNED64; from, to: SIGNED32);
		VAR i: SIGNED32;
		BEGIN
			FOR i := from TO to DO
				IF ODD(value) THEN INCL(codeSet, i) END;
				value := value DIV 2
			END;
			IF (value # 0) & (value # -1) THEN error := TRUE END
		END PutSigned;

		PROCEDURE Fail;
		BEGIN error := TRUE
		END Fail;

		(* the sf bit: 1 for a 64 bit operation *)
		PROCEDURE Sf(CONST op: Operand): SIGNED32;
		BEGIN
			IF op.size = 64 THEN RETURN 1
			ELSIF op.size = 32 THEN RETURN 0
			ELSE Fail; RETURN 0
			END
		END Sf;

		(* a general purpose register, which is what every form below wants unless it says V *)
		PROCEDURE Gp(CONST op: Operand): SIGNED32;
		BEGIN
			IF (op.mode # modeRegister) OR (op.register < X0) OR (op.register > SP) THEN Fail; RETURN 0 END;
			RETURN op.register
		END Gp;

		(* a general purpose register in a position where 31 means the zero register: writing SP
			there would encode a different operand, so it is refused rather than encoded *)
		PROCEDURE GpZ(CONST op: Operand): SIGNED32;
		BEGIN
			IF op.isStackPointer THEN Fail; RETURN 0 END;
			RETURN Gp(op)
		END GpZ;

		(* the base register of an address; 31 means SP here, which is why it is not GpZ *)
		PROCEDURE Base(CONST op: Operand): SIGNED32;
		BEGIN
			IF (op.mode # modeMemory) OR (op.register < X0) OR (op.register > SP) THEN Fail; RETURN 0 END;
			RETURN op.register
		END Base;

		PROCEDURE Vec(CONST op: Operand): SIGNED32;
		BEGIN
			IF (op.mode # modeRegister) OR (op.register < V0) OR (op.register > V0 + 31) THEN Fail; RETURN 0 END;
			RETURN op.register - V0
		END Vec;

		PROCEDURE SameSize(CONST a, b: Operand);
		BEGIN
			IF a.size # b.size THEN Fail END
		END SameSize;

		(* --- add and subtract --- *)

		(* sf op S 10001 shift(2) imm12 Rn Rd -- C4.1.64.2, add/subtract (immediate) *)
		PROCEDURE AddSubImmediate(CONST rd, rn, src: Operand; op, s: SIGNED32);
		VAR value: SIGNED64; shift: SIGNED32;
		BEGIN
			value := src.immediate;
			(* a negative immediate is the other instruction with the sign taken out, which is what
				every assembler does and what makes ADD Xd, Xn, #-16 mean what it reads as *)
			IF value < 0 THEN op := 1 - op; value := -value END;
			IF src.shiftMode = shiftLSL THEN
				IF src.shiftAmount = 0 THEN shift := 0
				ELSIF src.shiftAmount = 12 THEN shift := 1;
				ELSE Fail; RETURN
				END
			ELSIF src.shiftMode = None THEN
				shift := 0
			ELSE Fail; RETURN
			END;
			IF (shift = 0) & (value > 4095) & (And64(value, Ones(12)) = 0) & (Shr64(value, 24) = 0) THEN
				(* it does not fit in twelve bits but it fits in twelve bits shifted by twelve *)
				shift := 1; value := Shr64(value, 12)
			END;
			IF (value < 0) OR (value > 4095) THEN Fail; RETURN END;
			Put(Sf(rd), 31, 31); Put(op, 30, 30); Put(s, 29, 29);
			Put(11H, 24, 28);
			Put(shift, 22, 23);
			Put(value, 10, 21);
			Put(Gp(rn), 5, 9);
			IF s = 1 THEN Put(GpZ(rd), 0, 4) ELSE Put(Gp(rd), 0, 4) END
		END AddSubImmediate;

		(* sf op S 01011 shift(2) 0 Rm imm6 Rn Rd -- add/subtract (shifted register) *)
		PROCEDURE AddSubShiftedRegister(CONST rd, rn, rm: Operand; op, s: SIGNED32);
		VAR shift, amount: SIGNED32;
		BEGIN
			IF rm.shiftMode = None THEN shift := shiftLSL; amount := 0
			ELSE shift := rm.shiftMode; amount := rm.shiftAmount
			END;
			IF shift = shiftROR THEN Fail; RETURN END;			(* the shifted register form has no ROR *)
			IF (amount < 0) OR (amount >= rd.size) THEN Fail; RETURN END;
			SameSize(rd, rn); SameSize(rd, rm);
			Put(Sf(rd), 31, 31); Put(op, 30, 30); Put(s, 29, 29);
			Put(0BH, 24, 28);
			Put(shift, 22, 23);
			Put(0, 21, 21);
			Put(GpZ(rm), 16, 20);
			Put(amount, 10, 15);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END AddSubShiftedRegister;

		(* sf op S 01011 00 1 Rm option(3) imm3 Rn Rd -- add/subtract (extended register).
			This is the form that can name SP, which is why arithmetic on the stack pointer lands
			here even when nothing is being extended. *)
		PROCEDURE AddSubExtendedRegister(CONST rd, rn, rm: Operand; op, s: SIGNED32);
		VAR option, amount: SIGNED32;
		BEGIN
			IF rm.extend # None THEN
				option := rm.extend; amount := rm.shiftAmount
			ELSIF (rm.shiftMode = None) OR ((rm.shiftMode = shiftLSL) & (rm.shiftAmount = 0)) THEN
				(* no extension written: the one that changes nothing, chosen by the operand width *)
				IF rm.size = 64 THEN option := extendUXTX ELSE option := extendUXTW END;
				amount := 0
			ELSE Fail; RETURN
			END;
			IF (amount < 0) OR (amount > 4) THEN Fail; RETURN END;
			Put(Sf(rd), 31, 31); Put(op, 30, 30); Put(s, 29, 29);
			Put(0BH, 24, 28);
			Put(0, 22, 23);
			Put(1, 21, 21);
			Put(GpZ(rm), 16, 20);
			Put(option, 13, 15);
			Put(amount, 10, 12);
			Put(Gp(rn), 5, 9);
			IF s = 1 THEN Put(GpZ(rd), 0, 4) ELSE Put(Gp(rd), 0, 4) END
		END AddSubExtendedRegister;

		PROCEDURE AddSubRegister(CONST rd, rn, rm: Operand; op, s: SIGNED32);
		BEGIN
			IF (rm.extend # None) OR rd.isStackPointer OR rn.isStackPointer THEN
				AddSubExtendedRegister(rd, rn, rm, op, s)
			ELSE
				AddSubShiftedRegister(rd, rn, rm, op, s)
			END
		END AddSubRegister;

		PROCEDURE AddSub(CONST rd, rn, src: Operand; op, s: SIGNED32);
		BEGIN
			IF src.mode = modeImmediate THEN AddSubImmediate(rd, rn, src, op, s)
			ELSE AddSubRegister(rd, rn, src, op, s)
			END
		END AddSub;

		(* --- logical --- *)

		(* sf opc(2) 100100 N immr imms Rn Rd -- logical (immediate) *)
		PROCEDURE LogicalImmediate(CONST rd, rn, src: Operand; opc: SIGNED32);
		VAR n, immr, imms: SIGNED32;
		BEGIN
			IF ~EncodeLogicalImmediate(src.immediate, rd.size, n, immr, imms) THEN Fail; RETURN END;
			Put(Sf(rd), 31, 31); Put(opc, 29, 30);
			Put(24H, 23, 28);
			Put(n, 22, 22);
			Put(immr, 16, 21);
			Put(imms, 10, 15);
			Put(GpZ(rn), 5, 9);
			IF opc = 3 THEN Put(GpZ(rd), 0, 4) ELSE Put(Gp(rd), 0, 4) END	(* ANDS writes ZR, the rest may write SP *)
		END LogicalImmediate;

		(* sf opc(2) 01010 shift(2) N Rm imm6 Rn Rd -- logical (shifted register) *)
		PROCEDURE LogicalShiftedRegister(CONST rd, rn, rm: Operand; opc, n: SIGNED32);
		VAR shift, amount: SIGNED32;
		BEGIN
			IF rm.shiftMode = None THEN shift := shiftLSL; amount := 0
			ELSE shift := rm.shiftMode; amount := rm.shiftAmount
			END;
			IF (amount < 0) OR (amount >= rd.size) THEN Fail; RETURN END;
			SameSize(rd, rn); SameSize(rd, rm);
			Put(Sf(rd), 31, 31); Put(opc, 29, 30);
			Put(0AH, 24, 28);
			Put(shift, 22, 23);
			Put(n, 21, 21);
			Put(GpZ(rm), 16, 20);
			Put(amount, 10, 15);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END LogicalShiftedRegister;

		PROCEDURE Logical(CONST rd, rn, src: Operand; opc, n: SIGNED32);
		BEGIN
			IF src.mode = modeImmediate THEN
				IF n # 0 THEN Fail; RETURN END;		(* BIC, ORN and EON have no immediate form *)
				LogicalImmediate(rd, rn, src, opc)
			ELSE
				LogicalShiftedRegister(rd, rn, src, opc, n)
			END
		END Logical;

		(* --- move wide --- *)

		(* sf opc(2) 100101 hw(2) imm16 Rd *)
		PROCEDURE MoveWide(CONST rd, src: Operand; opc: SIGNED32);
		VAR hw: SIGNED32;
		BEGIN
			IF src.mode # modeImmediate THEN Fail; RETURN END;
			IF (src.immediate < 0) OR (src.immediate > 0FFFFH) THEN Fail; RETURN END;
			IF src.shiftMode = None THEN hw := 0
			ELSIF src.shiftMode # shiftLSL THEN Fail; RETURN
			ELSIF src.shiftAmount MOD 16 # 0 THEN Fail; RETURN
			ELSE hw := src.shiftAmount DIV 16
			END;
			IF (hw < 0) OR (hw * 16 >= rd.size) THEN Fail; RETURN END;
			Put(Sf(rd), 31, 31); Put(opc, 29, 30);
			Put(25H, 23, 28);
			Put(hw, 21, 22);
			Put(src.immediate, 5, 20);
			Put(GpZ(rd), 0, 4)
		END MoveWide;

		(* MOV of an immediate is whichever of the three ways of writing a constant fits *)
		(* whether `value` is one halfword and otherwise zero, and if so which one; MOVZ and MOVN
			both write a single halfword and give every other one a fixed value, so a constant they
			can produce is one that has nothing outside that halfword *)
		PROCEDURE SingleHalfword(value: SIGNED64; size: SIGNED16; VAR halfword: SIGNED64; VAR shift: SIGNED32): BOOLEAN;
		BEGIN
			shift := 0;
			WHILE shift < size DO
				halfword := And64(Shr64(value, shift), Ones(16));
				IF Shl64(halfword, shift) = value THEN RETURN TRUE END;
				INC(shift, 16)
			END;
			RETURN FALSE
		END SingleHalfword;

		PROCEDURE MoveImmediate(CONST rd, src: Operand);
		VAR value, halfword: SIGNED64; shift: SIGNED32; wide, dummy: Operand;
		BEGIN
			value := src.immediate;
			IF rd.size = 32 THEN value := And64(value, Ones(32)) END;

			IF SingleHalfword(value, rd.size, halfword, shift) THEN
				InitShiftedImmediate(wide, halfword, shift);
				MoveWide(rd, wide, 2);
				RETURN
			END;

			(* the complement may be one halfword even when the value is not: MOVN writes the
				halfword inverted and sets every other bit *)
			IF rd.size = 32 THEN value := And64(Not64(value), Ones(32)) ELSE value := Not64(value) END;
			IF SingleHalfword(value, rd.size, halfword, shift) THEN
				InitShiftedImmediate(wide, halfword, shift);
				MoveWide(rd, wide, 0);
				RETURN
			END;

			(* neither: the constant may still be a logical pattern, ORR of it with zero *)
			InitRegister(dummy, ZR, rd.size);
			LogicalImmediate(rd, dummy, src, 1)
		END MoveImmediate;

		PROCEDURE Move(CONST rd, src: Operand);
		VAR zero, none: Operand;
		BEGIN
			IF src.mode = modeImmediate THEN
				MoveImmediate(rd, src)
			ELSIF rd.isStackPointer OR src.isStackPointer THEN
				(* MOV involving SP is ADD #0, because ORR cannot name the stack pointer *)
				InitImmediate(none, 0);
				AddSubImmediate(rd, src, none, 0, 0)
			ELSE
				InitRegister(zero, ZR, rd.size);
				LogicalShiftedRegister(rd, zero, src, 1, 0)
			END
		END Move;

		(* --- pc relative --- *)

		(* op immlo(2) 10000 immhi(19) Rd *)
		PROCEDURE PCRelative(CONST rd, target: Operand; op: SIGNED32);
		VAR patterns: ObjectFile.FixupPatterns;
		BEGIN
			Put(op, 31, 31);
			Put(10H, 24, 28);
			Put(GpZ(rd), 0, 4);
			IF target.fixup # NIL THEN
				NEW(patterns, 2);
				patterns[0].offset := 29; patterns[0].bits := 2;
				patterns[1].offset := 5;  patterns[1].bits := 19;
				target.fixup.InitFixup(BinaryCode.Relative, 0, target.fixup.symbol, target.fixup.symbolOffset,
					target.fixup.displacement, 0, patterns)
			ELSE
				Put(And64(target.immediate, 3), 29, 30);
				PutSigned(target.immediate DIV 4, 5, 23)
			END
		END PCRelative;

		(* --- bitfield --- *)

		(* sf opc(2) 100110 N immr imms Rn Rd *)
		PROCEDURE Bitfield(CONST rd, rn: Operand; immr, imms, opc: SIGNED32);
		BEGIN
			IF (immr < 0) OR (immr >= rd.size) OR (imms < 0) OR (imms >= rd.size) THEN Fail; RETURN END;
			Put(Sf(rd), 31, 31); Put(opc, 29, 30);
			Put(26H, 23, 28);
			Put(Sf(rd), 22, 22);					(* N equals sf for every A64 bitfield instruction *)
			Put(immr, 16, 21);
			Put(imms, 10, 15);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END Bitfield;

		(* sf 00 100111 N 0 Rm imms Rn Rd *)
		PROCEDURE Extract(CONST rd, rn, rm: Operand; lsb: SIGNED32);
		BEGIN
			IF (lsb < 0) OR (lsb >= rd.size) THEN Fail; RETURN END;
			Put(Sf(rd), 31, 31); Put(0, 29, 30);
			Put(27H, 23, 28);
			Put(Sf(rd), 22, 22);
			Put(0, 21, 21);
			Put(GpZ(rm), 16, 20);
			Put(lsb, 10, 15);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END Extract;

		(* --- data processing, register --- *)

		(* sf 0 0 11010110 Rm opcode(6) Rn Rd -- two source *)
		PROCEDURE DataProcessing2(CONST rd, rn, rm: Operand; opcode: SIGNED32);
		BEGIN
			SameSize(rd, rn); SameSize(rd, rm);
			Put(Sf(rd), 31, 31); Put(0, 30, 30); Put(0, 29, 29);
			Put(0D6H, 21, 28);
			Put(GpZ(rm), 16, 20);
			Put(opcode, 10, 15);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END DataProcessing2;

		(* sf 1 0 11010110 00000 opcode(6) Rn Rd -- one source *)
		PROCEDURE DataProcessing1(CONST rd, rn: Operand; opcode: SIGNED32);
		BEGIN
			SameSize(rd, rn);
			Put(Sf(rd), 31, 31); Put(1, 30, 30); Put(0, 29, 29);
			Put(0D6H, 21, 28);
			Put(0, 16, 20);
			Put(opcode, 10, 15);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END DataProcessing1;

		(* sf op54(2) 11011 op31(3) Rm o0 Ra Rn Rd -- three source *)
		PROCEDURE DataProcessing3(CONST rd, rn, rm, ra: Operand; op31, o0: SIGNED32);
		BEGIN
			Put(Sf(rd), 31, 31); Put(0, 29, 30);
			Put(1BH, 24, 28);
			Put(op31, 21, 23);
			Put(GpZ(rm), 16, 20);
			Put(o0, 15, 15);
			Put(GpZ(ra), 10, 14);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END DataProcessing3;

		(* sf op 0 11010100 Rm cond(4) op2(2) Rn Rd -- conditional select *)
		PROCEDURE CondSelect(CONST rd, rn, rm, cond: Operand; op, op2: SIGNED32);
		BEGIN
			IF cond.mode # modeCondition THEN Fail; RETURN END;
			SameSize(rd, rn); SameSize(rd, rm);
			Put(Sf(rd), 31, 31); Put(op, 30, 30); Put(0, 29, 29);
			Put(0D4H, 21, 28);
			Put(GpZ(rm), 16, 20);
			Put(cond.condition, 12, 15);
			Put(op2, 10, 11);
			Put(GpZ(rn), 5, 9);
			Put(GpZ(rd), 0, 4)
		END CondSelect;

		(* --- branches --- *)

		PROCEDURE BranchFixup(CONST target: Operand; offset, bits: SIGNED32);
		VAR patterns: ObjectFile.FixupPatterns;
		BEGIN
			NEW(patterns, 1);
			patterns[0].offset := offset; patterns[0].bits := bits;
			(* relative to the instruction itself, and counted in instructions: scale -2 divides the
				byte displacement by four *)
			target.fixup.InitFixup(BinaryCode.Relative, 0, target.fixup.symbol, target.fixup.symbolOffset,
				target.fixup.displacement, -2, patterns)
		END BranchFixup;

		(* a branch displacement written as a number is a byte count, and must be a whole number of
			instructions *)
		PROCEDURE BranchOffset(CONST target: Operand; offset, bits: SIGNED32);
		BEGIN
			IF target.fixup # NIL THEN
				BranchFixup(target, offset, bits)
			ELSIF target.immediate MOD 4 # 0 THEN
				Fail
			ELSE
				PutSigned(target.immediate DIV 4, offset, offset + bits - 1)
			END
		END BranchOffset;

		PROCEDURE Branch(CONST target: Operand; op: SIGNED32);
		BEGIN
			Put(op, 31, 31);
			Put(5, 26, 30);
			BranchOffset(target, 0, 26)
		END Branch;

		PROCEDURE BranchConditional(CONST cond, target: Operand);
		BEGIN
			IF cond.mode # modeCondition THEN Fail; RETURN END;
			Put(54H, 24, 31);
			Put(0, 4, 4);
			Put(cond.condition, 0, 3);
			BranchOffset(target, 5, 19)
		END BranchConditional;

		PROCEDURE CompareAndBranch(CONST rt, target: Operand; op: SIGNED32);
		BEGIN
			Put(Sf(rt), 31, 31);
			Put(1AH, 25, 30);
			Put(op, 24, 24);
			Put(GpZ(rt), 0, 4);
			BranchOffset(target, 5, 19)
		END CompareAndBranch;

		PROCEDURE TestAndBranch(CONST rt, bit, target: Operand; op: SIGNED32);
		VAR b: SIGNED64;
		BEGIN
			IF bit.mode # modeImmediate THEN Fail; RETURN END;
			b := bit.immediate;
			IF (b < 0) OR (b >= rt.size) THEN Fail; RETURN END;
			Put(Shr64(b, 5), 31, 31);
			Put(1BH, 25, 30);
			Put(op, 24, 24);
			Put(And64(b, 1FH), 19, 23);
			Put(GpZ(rt), 0, 4);
			BranchOffset(target, 5, 14)
		END TestAndBranch;

		PROCEDURE BranchRegister(CONST rn: Operand; opc: SIGNED32);
		BEGIN
			Put(6BH, 25, 31);
			Put(opc, 21, 24);
			Put(1FH, 16, 20);
			Put(0, 10, 15);
			Put(GpZ(rn), 5, 9);
			Put(0, 0, 4)
		END BranchRegister;

		(* --- system --- *)

		PROCEDURE Exception(CONST imm: Operand; opc, ll: SIGNED32);
		BEGIN
			IF imm.mode # modeImmediate THEN Fail; RETURN END;
			IF (imm.immediate < 0) OR (imm.immediate > 0FFFFH) THEN Fail; RETURN END;
			Put(0D4H, 24, 31);
			Put(opc, 21, 23);
			Put(imm.immediate, 5, 20);
			Put(0, 2, 4);
			Put(ll, 0, 1)
		END Exception;

		(* 1101 0101 0000 0011 0011 CRm op2 1 1111 -- the barriers, which differ only in op2 *)
		PROCEDURE Barrier(CONST imm: Operand; op2: SIGNED32);
		VAR crm: SIGNED64;
		BEGIN
			IF imm.mode = modeNone THEN crm := 15			(* no option written means SY *)
			ELSIF imm.mode # modeImmediate THEN Fail; RETURN
			ELSE crm := imm.immediate
			END;
			IF (crm < 0) OR (crm > 15) THEN Fail; RETURN END;
			Put(0D5033H, 12, 31);
			Put(crm, 8, 11);
			Put(op2, 5, 7);
			Put(1FH, 0, 4)
		END Barrier;

		(* --- loads and stores ---

			The three addressing modes share a size field and an opc field and differ in the middle
			of the word. `scale` is how far the offset of the scaled form is shifted, which is the
			base two logarithm of the number of bytes accessed and is not always the size field: a
			128 bit access has size 00 and scale 4.
		*)

		(* size 111 V 01 opc imm12 Rn Rt -- unsigned offset, the form with the widest range *)
		PROCEDURE LoadStoreUnsignedOffset(CONST rt, mem: Operand; sizeField, v, opc, scale: SIGNED32);
		BEGIN
			Put(sizeField, 30, 31);
			Put(7, 27, 29); Put(v, 26, 26);
			Put(1, 24, 25);
			Put(opc, 22, 23);
			Put(Shr64(mem.immediate, scale), 10, 21);
			Put(Base(mem), 5, 9);
			IF rt.register >= V0 THEN Put(Vec(rt), 0, 4) ELSE Put(GpZ(rt), 0, 4) END
		END LoadStoreUnsignedOffset;

		(* size 111 V 00 opc 0 imm9 idx(2) Rn Rt -- unscaled, and the pre and post indexed forms *)
		PROCEDURE LoadStoreImmediate9(CONST rt, mem: Operand; sizeField, v, opc, idx: SIGNED32);
		BEGIN
			IF (mem.immediate < -256) OR (mem.immediate > 255) THEN Fail; RETURN END;
			Put(sizeField, 30, 31);
			Put(7, 27, 29); Put(v, 26, 26);
			Put(0, 24, 25);
			Put(opc, 22, 23);
			Put(0, 21, 21);
			PutSigned(mem.immediate, 12, 20);
			Put(idx, 10, 11);
			Put(Base(mem), 5, 9);
			IF rt.register >= V0 THEN Put(Vec(rt), 0, 4) ELSE Put(GpZ(rt), 0, 4) END
		END LoadStoreImmediate9;

		(* size 111 V 00 opc 1 Rm option S 10 Rn Rt -- offset in a register, optionally extended *)
		PROCEDURE LoadStoreRegisterOffset(CONST rt, mem: Operand; sizeField, v, opc, scale: SIGNED32);
		VAR option, s: SIGNED32;
		BEGIN
			IF mem.extend # None THEN option := mem.extend
			ELSIF mem.indexSize = 64 THEN option := extendUXTX		(* a plain LSL of a 64 bit index *)
			ELSE Fail; RETURN
			END;
			IF (option # extendUXTW) & (option # extendUXTX) & (option # extendSXTW) & (option # extendSXTX) THEN
				Fail; RETURN									(* the byte and halfword extensions have no meaning for an address *)
			END;
			IF mem.shiftAmount = 0 THEN s := 0
			ELSIF mem.shiftAmount = scale THEN s := 1		(* the only other amount is the access size *)
			ELSE Fail; RETURN
			END;
			Put(sizeField, 30, 31);
			Put(7, 27, 29); Put(v, 26, 26);
			Put(0, 24, 25);
			Put(opc, 22, 23);
			Put(1, 21, 21);
			Put(mem.index, 16, 20);
			Put(option, 13, 15);
			Put(s, 12, 12);
			Put(2, 10, 11);
			Put(Base(mem), 5, 9);
			IF rt.register >= V0 THEN Put(Vec(rt), 0, 4) ELSE Put(GpZ(rt), 0, 4) END
		END LoadStoreRegisterOffset;

		(* choose the addressing form the memory operand asks for; `unscaled` is the LDUR family,
			which names the imm9 form even when the scaled one would fit *)
		PROCEDURE LoadStore(CONST rt, mem: Operand; sizeField, v, opc, scale: SIGNED32; unscaled: BOOLEAN);
		BEGIN
			IF mem.mode # modeMemory THEN Fail; RETURN END;
			IF mem.index # None THEN
				IF mem.indexing # indexOffset THEN Fail; RETURN END;
				LoadStoreRegisterOffset(rt, mem, sizeField, v, opc, scale)
			ELSIF mem.indexing = indexPost THEN
				LoadStoreImmediate9(rt, mem, sizeField, v, opc, 1)
			ELSIF mem.indexing = indexPre THEN
				LoadStoreImmediate9(rt, mem, sizeField, v, opc, 3)
			ELSIF ~unscaled & (mem.immediate >= 0) & (And64(mem.immediate, Ones(scale)) = 0)
					& (Shr64(mem.immediate, scale) <= 4095) THEN
				LoadStoreUnsignedOffset(rt, mem, sizeField, v, opc, scale)
			ELSE
				(* negative, or not a multiple of the access size: the unscaled form is what an
					assembler falls back to, and it is what LDUR names outright *)
				LoadStoreImmediate9(rt, mem, sizeField, v, opc, 0)
			END
		END LoadStore;

		(* the size, opc, scale and V of a load or store, from its mnemonic and the register it
			moves; `load` and `signed` say which of the four opc values applies *)
		PROCEDURE LoadStoreOfWidth(CONST rt, mem: Operand; accessBits: SIGNED32; load, signed: BOOLEAN; unscaled: BOOLEAN);
		VAR sizeField, v, opc, scale: SIGNED32;
		BEGIN
			IF rt.register >= V0 THEN
				v := 1;
				IF accessBits # rt.size THEN Fail; RETURN END;
				CASE accessBits OF
				| 8: sizeField := 0; scale := 0; opc := 1
				| 16: sizeField := 1; scale := 1; opc := 1
				| 32: sizeField := 2; scale := 2; opc := 1
				| 64: sizeField := 3; scale := 3; opc := 1
				| 128: sizeField := 0; scale := 4; opc := 3	(* 128 bits reuses size 00 with the high opc bit *)
				ELSE Fail; RETURN
				END;
				IF ~load THEN DEC(opc) END						(* a store is the load's opc with bit 0 clear *)
			ELSE
				v := 0;
				CASE accessBits OF
				| 8: sizeField := 0; scale := 0
				| 16: sizeField := 1; scale := 1
				| 32: sizeField := 2; scale := 2
				| 64: sizeField := 3; scale := 3
				ELSE Fail; RETURN
				END;
				IF ~load THEN opc := 0
				ELSIF ~signed THEN opc := 1
				ELSIF rt.size = 64 THEN opc := 2				(* sign extend into a 64 bit register *)
				ELSE opc := 3											(* ... or into a 32 bit one *)
				END;
				IF load & ~signed & (accessBits > 16) & (accessBits # rt.size) THEN Fail; RETURN END
			END;
			LoadStore(rt, mem, sizeField, v, opc, scale, unscaled)
		END LoadStoreOfWidth;

		(* opc(2) 011 V 00 imm19 Rt -- load from a literal placed near the instruction.
			The offset counts instructions from the load itself and reaches a megabyte either way,
			which is what makes an inline constant cheaper than building one. *)
		PROCEDURE LoadLiteral(CONST rt, target: Operand);
		VAR opc, v: SIGNED32;
		BEGIN
			IF rt.register >= V0 THEN
				v := 1;
				CASE rt.size OF
				| 32: opc := 0
				| 64: opc := 1
				| 128: opc := 2
				ELSE Fail; RETURN
				END
			ELSE
				v := 0;
				IF rt.size = 32 THEN opc := 0 ELSIF rt.size = 64 THEN opc := 1 ELSE Fail; RETURN END
			END;
			Put(opc, 30, 31);
			Put(3, 27, 29); Put(v, 26, 26);
			Put(0, 24, 25);
			IF rt.register >= V0 THEN Put(Vec(rt), 0, 4) ELSE Put(GpZ(rt), 0, 4) END;
			BranchOffset(target, 5, 19)
		END LoadLiteral;

		(* opc(2) 101 V idx(3) L imm7 Rt2 Rn Rt -- a pair, whose offset is scaled and signed *)
		PROCEDURE LoadStorePair(CONST rt, rt2, mem: Operand; load: BOOLEAN);
		VAR opc, v, scale, idx: SIGNED32; offset: SIGNED64;
		BEGIN
			IF mem.mode # modeMemory THEN Fail; RETURN END;
			IF mem.index # None THEN Fail; RETURN END;
			IF rt.size # rt2.size THEN Fail; RETURN END;
			IF rt.register >= V0 THEN
				v := 1;
				CASE rt.size OF
				| 32: opc := 0; scale := 2
				| 64: opc := 1; scale := 3
				| 128: opc := 2; scale := 4
				ELSE Fail; RETURN
				END
			ELSE
				v := 0;
				IF rt.size = 32 THEN opc := 0; scale := 2
				ELSIF rt.size = 64 THEN opc := 2; scale := 3
				ELSE Fail; RETURN
				END
			END;
			CASE mem.indexing OF
			| indexPost: idx := 1
			| indexOffset: idx := 2
			| indexPre: idx := 3
			END;
			IF And64(mem.immediate, Ones(scale)) # 0 THEN Fail; RETURN END;
			offset := mem.immediate DIV Shl64(1, scale);
			IF (offset < -64) OR (offset > 63) THEN Fail; RETURN END;
			Put(opc, 30, 31);
			Put(5, 27, 29); Put(v, 26, 26);
			Put(idx, 23, 25);
			IF load THEN Put(1, 22, 22) ELSE Put(0, 22, 22) END;
			PutSigned(offset, 15, 21);
			IF rt.register >= V0 THEN Put(Vec(rt2), 10, 14) ELSE Put(GpZ(rt2), 10, 14) END;
			Put(Base(mem), 5, 9);
			IF rt.register >= V0 THEN Put(Vec(rt), 0, 4) ELSE Put(GpZ(rt), 0, 4) END
		END LoadStorePair;

		(* size 001000 o2 L o1 Rs o0 Rt2 Rn Rt -- the exclusive and ordered accesses.
			The address has no offset at all in these forms, which is why they take [Rn] and
			nothing else. *)
		PROCEDURE LoadStoreExclusive(CONST rs, rt, mem: Operand; o2, l, o0, size: SIGNED32; hasStatus: BOOLEAN);
		VAR sizeField: SIGNED32;
		BEGIN
			IF mem.mode # modeMemory THEN Fail; RETURN END;
			IF (mem.index # None) OR (mem.immediate # 0) OR (mem.indexing # indexOffset) THEN Fail; RETURN END;
			IF size >= 0 THEN
				(* a byte or halfword form, whose width the mnemonic named: the register is a W one *)
				IF rt.size # 32 THEN Fail; RETURN END;
				sizeField := size
			ELSIF rt.size = 32 THEN sizeField := 2
			ELSIF rt.size = 64 THEN sizeField := 3
			ELSE Fail; RETURN
			END;
			Put(sizeField, 30, 31);
			Put(8, 24, 29);
			Put(o2, 23, 23);
			Put(l, 22, 22);
			Put(0, 21, 21);
			IF hasStatus THEN Put(GpZ(rs), 16, 20) ELSE Put(1FH, 16, 20) END;
			Put(o0, 15, 15);
			Put(1FH, 10, 14);
			Put(Base(mem), 5, 9);
			Put(GpZ(rt), 0, 4)
		END LoadStoreExclusive;

		(* --- scalar floating point --- *)

		(* the type field: 00 is single, 01 is double, 11 is half *)
		PROCEDURE FpType(CONST op: Operand): SIGNED32;
		BEGIN
			CASE op.size OF
			| 32: RETURN 0
			| 64: RETURN 1
			| 16: RETURN 3
			ELSE Fail; RETURN 0
			END
		END FpType;

		(* 000 11110 type 1 opcode(6) 10000 Rn Rd *)
		PROCEDURE FpDataProcessing1(CONST rd, rn: Operand; ftype, opcode: SIGNED32);
		BEGIN
			Put(0, 29, 31);
			Put(1EH, 24, 28);
			Put(ftype, 22, 23);
			Put(1, 21, 21);
			Put(opcode, 15, 20);
			Put(10H, 10, 14);
			Put(Vec(rn), 5, 9);
			Put(Vec(rd), 0, 4)
		END FpDataProcessing1;

		(* 000 11110 type 1 Rm opcode(4) 10 Rn Rd *)
		PROCEDURE FpDataProcessing2(CONST rd, rn, rm: Operand; opcode: SIGNED32);
		BEGIN
			SameSize(rd, rn); SameSize(rd, rm);
			Put(0, 29, 31);
			Put(1EH, 24, 28);
			Put(FpType(rd), 22, 23);
			Put(1, 21, 21);
			Put(Vec(rm), 16, 20);
			Put(opcode, 12, 15);
			Put(2, 10, 11);
			Put(Vec(rn), 5, 9);
			Put(Vec(rd), 0, 4)
		END FpDataProcessing2;

		(* 000 11110 type 1 Rm 00 1000 Rn opcode2(5) *)
		PROCEDURE FpCompare(CONST rn, rm: Operand; signalling: BOOLEAN);
		VAR opcode2: SIGNED32;
		BEGIN
			IF signalling THEN opcode2 := 10H ELSE opcode2 := 0 END;
			Put(0, 29, 31);
			Put(1EH, 24, 28);
			Put(FpType(rn), 22, 23);
			Put(1, 21, 21);
			IF rm.mode = modeImmediate THEN
				(* the comparison against zero is a different opcode2 and no second register *)
				IF rm.immediate # 0 THEN Fail; RETURN END;
				Put(0, 16, 20);
				INC(opcode2, 8)
			ELSE
				SameSize(rn, rm);
				Put(Vec(rm), 16, 20)
			END;
			Put(0, 14, 15);
			Put(8, 10, 13);
			Put(Vec(rn), 5, 9);
			Put(opcode2, 0, 4)
		END FpCompare;

		(* sf 00 11110 type 1 rmode(2) opcode(3) 000000 Rn Rd -- between a V and a general register *)
		PROCEDURE FpConvert(CONST rd, rn, general, floating: Operand; rmode, opcode: SIGNED32);
		BEGIN
			Put(Sf(general), 31, 31);
			Put(0, 29, 30);
			Put(1EH, 24, 28);
			Put(FpType(floating), 22, 23);
			Put(1, 21, 21);
			Put(rmode, 19, 20);
			Put(opcode, 16, 18);
			Put(0, 10, 15);
			IF rn.register >= V0 THEN Put(Vec(rn), 5, 9) ELSE Put(GpZ(rn), 5, 9) END;
			IF rd.register >= V0 THEN Put(Vec(rd), 0, 4) ELSE Put(GpZ(rd), 0, 4) END
		END FpConvert;

		(* --- system registers --- *)

		(* 1101010100 L 1 op1(3) CRn(4) CRm(4) op2(3) Rt -- the sixteen bits between the L bit and the
			register are the system register itself, which is how SystemRegisterFromName hands it over *)
		PROCEDURE SystemRegisterMove(CONST rt, systemRegister: Operand; load: SIGNED32);
		BEGIN
			IF systemRegister.mode # modeImmediate THEN Fail; RETURN END;
			IF (systemRegister.immediate < 0) OR (systemRegister.immediate > 0FFFFH) THEN Fail; RETURN END;
			IF rt.size # 64 THEN Fail; RETURN END;
			Put(354H, 22, 31);
			Put(load, 21, 21);
			Put(systemRegister.immediate, 5, 20);
			Put(GpZ(rt), 0, 4)
		END SystemRegisterMove;

		(* 000 11110 type 1 Rm cond(4) 11 Rn Rd *)
		PROCEDURE FpCondSelect(CONST rd, rn, rm, cond: Operand);
		BEGIN
			IF cond.mode # modeCondition THEN Fail; RETURN END;
			SameSize(rd, rn); SameSize(rd, rm);
			Put(0, 29, 31);
			Put(1EH, 24, 28);
			Put(FpType(rd), 22, 23);
			Put(1, 21, 21);
			Put(Vec(rm), 16, 20);
			Put(cond.condition, 12, 15);
			Put(3, 10, 11);
			Put(Vec(rn), 5, 9);
			Put(Vec(rd), 0, 4)
		END FpCondSelect;

		PROCEDURE FpMove(CONST rd, rn: Operand);
		BEGIN
			IF (rd.register >= V0) & (rn.register >= V0) THEN
				SameSize(rd, rn);
				FpDataProcessing1(rd, rn, FpType(rd), 0)
			ELSIF rd.register >= V0 THEN
				(* general to floating point: the widths have to agree, W with S and X with D *)
				IF rd.size # rn.size THEN Fail; RETURN END;
				FpConvert(rd, rn, rn, rd, 0, 7)
			ELSIF rn.register >= V0 THEN
				IF rd.size # rn.size THEN Fail; RETURN END;
				FpConvert(rd, rn, rd, rn, 0, 6)
			ELSE Fail
			END
		END FpMove;

	BEGIN
		codeSet := {};
		error := FALSE;
		o0 := instruction.operands[0];
		o1 := instruction.operands[1];
		o2 := instruction.operands[2];
		o3 := instruction.operands[3];
		width := o0.size;
		InitRegister(zero, ZR, SIGNED16(width));

		CASE instruction.mnemonic OF
		(* add and subtract *)
		| opADD:  AddSub(o0, o1, o2, 0, 0)
		| opADDS: AddSub(o0, o1, o2, 0, 1)
		| opSUB:  AddSub(o0, o1, o2, 1, 0)
		| opSUBS: AddSub(o0, o1, o2, 1, 1)
		| opCMP:  InitRegister(zero, ZR, o0.size); AddSub(zero, o0, o1, 1, 1)
		| opCMN:  InitRegister(zero, ZR, o0.size); AddSub(zero, o0, o1, 0, 1)
		| opNEG:  InitRegister(zero, ZR, o0.size); AddSubRegister(o0, zero, o1, 1, 0)
		| opNEGS: InitRegister(zero, ZR, o0.size); AddSubRegister(o0, zero, o1, 1, 1)

		(* logical *)
		| opAND:  Logical(o0, o1, o2, 0, 0)
		| opBIC:  Logical(o0, o1, o2, 0, 1)
		| opORR:  Logical(o0, o1, o2, 1, 0)
		| opORN:  Logical(o0, o1, o2, 1, 1)
		| opEOR:  Logical(o0, o1, o2, 2, 0)
		| opEON:  Logical(o0, o1, o2, 2, 1)
		| opANDS: Logical(o0, o1, o2, 3, 0)
		| opBICS: Logical(o0, o1, o2, 3, 1)
		| opTST:  InitRegister(zero, ZR, o0.size); Logical(zero, o0, o1, 3, 0)
		| opMVN:  InitRegister(zero, ZR, o0.size); LogicalShiftedRegister(o0, zero, o1, 1, 1)
		| opMOV:  Move(o0, o1)

		(* move wide *)
		| opMOVZ: MoveWide(o0, o1, 2)
		| opMOVN: MoveWide(o0, o1, 0)
		| opMOVK: MoveWide(o0, o1, 3)

		(* pc relative *)
		| opADR:  PCRelative(o0, o1, 0)
		| opADRP: PCRelative(o0, o1, 1)

		(* bitfield, and its aliases *)
		| opSBFM: Bitfield(o0, o1, SIGNED32(o2.immediate), SIGNED32(o3.immediate), 0)
		| opBFM:  Bitfield(o0, o1, SIGNED32(o2.immediate), SIGNED32(o3.immediate), 1)
		| opUBFM: Bitfield(o0, o1, SIGNED32(o2.immediate), SIGNED32(o3.immediate), 2)
		| opSBFIZ: Bitfield(o0, o1, SIGNED32((width - o2.immediate) MOD width), SIGNED32(o3.immediate - 1), 0)
		| opSBFX:  Bitfield(o0, o1, SIGNED32(o2.immediate), SIGNED32(o2.immediate + o3.immediate - 1), 0)
		| opBFI:   Bitfield(o0, o1, SIGNED32((width - o2.immediate) MOD width), SIGNED32(o3.immediate - 1), 1)
		| opBFXIL: Bitfield(o0, o1, SIGNED32(o2.immediate), SIGNED32(o2.immediate + o3.immediate - 1), 1)
		| opUBFIZ: Bitfield(o0, o1, SIGNED32((width - o2.immediate) MOD width), SIGNED32(o3.immediate - 1), 2)
		| opUBFX:  Bitfield(o0, o1, SIGNED32(o2.immediate), SIGNED32(o2.immediate + o3.immediate - 1), 2)
		| opSXTB: Bitfield(o0, o1, 0, 7, 0)
		| opSXTH: Bitfield(o0, o1, 0, 15, 0)
		| opSXTW: Bitfield(o0, o1, 0, 31, 0)
		| opUXTB: Bitfield(o0, o1, 0, 7, 2)
		| opUXTH: Bitfield(o0, o1, 0, 15, 2)

		(* shifts: by an immediate they are bitfield moves, by a register they are not *)
		| opLSL:
			IF o2.mode = modeImmediate THEN
				Bitfield(o0, o1, SIGNED32((width - o2.immediate) MOD width), SIGNED32(width - 1 - o2.immediate), 2)
			ELSE DataProcessing2(o0, o1, o2, 8)
			END
		| opLSR:
			IF o2.mode = modeImmediate THEN Bitfield(o0, o1, SIGNED32(o2.immediate), width - 1, 2)
			ELSE DataProcessing2(o0, o1, o2, 9)
			END
		| opASR:
			IF o2.mode = modeImmediate THEN Bitfield(o0, o1, SIGNED32(o2.immediate), width - 1, 0)
			ELSE DataProcessing2(o0, o1, o2, 10)
			END
		| opROR:
			IF o2.mode = modeImmediate THEN Extract(o0, o1, o1, SIGNED32(o2.immediate))
			ELSE DataProcessing2(o0, o1, o2, 11)
			END
		| opEXTR: Extract(o0, o1, o2, SIGNED32(o3.immediate))

		(* multiply and divide *)
		| opMADD: DataProcessing3(o0, o1, o2, o3, 0, 0)
		| opMSUB: DataProcessing3(o0, o1, o2, o3, 0, 1)
		| opMUL:  DataProcessing3(o0, o1, o2, zero, 0, 0)
		| opMNEG: DataProcessing3(o0, o1, o2, zero, 0, 1)
		| opSMADDL: DataProcessing3(o0, o1, o2, o3, 1, 0)
		| opSMSUBL: DataProcessing3(o0, o1, o2, o3, 1, 1)
		| opSMULL:  DataProcessing3(o0, o1, o2, zero, 1, 0)
		| opSMNEGL: DataProcessing3(o0, o1, o2, zero, 1, 1)
		| opUMADDL: DataProcessing3(o0, o1, o2, o3, 5, 0)
		| opUMSUBL: DataProcessing3(o0, o1, o2, o3, 5, 1)
		| opUMULL:  DataProcessing3(o0, o1, o2, zero, 5, 0)
		| opUMNEGL: DataProcessing3(o0, o1, o2, zero, 5, 1)
		| opSMULH:  DataProcessing3(o0, o1, o2, zero, 2, 0)
		| opUMULH:  DataProcessing3(o0, o1, o2, zero, 6, 0)
		| opSDIV: DataProcessing2(o0, o1, o2, 3)
		| opUDIV: DataProcessing2(o0, o1, o2, 2)

		(* counting and reversing bits *)
		| opRBIT:  DataProcessing1(o0, o1, 0)
		| opREV16: DataProcessing1(o0, o1, 1)
		| opREV32: DataProcessing1(o0, o1, 2)
		| opREV:
			(* REV reverses the whole register, so its opcode depends on how wide that is *)
			IF width = 64 THEN DataProcessing1(o0, o1, 3) ELSE DataProcessing1(o0, o1, 2) END
		| opCLZ: DataProcessing1(o0, o1, 4)
		| opCLS: DataProcessing1(o0, o1, 5)

		(* conditional select, and the aliases that invert the condition *)
		| opCSEL:  CondSelect(o0, o1, o2, o3, 0, 0)
		| opCSINC: CondSelect(o0, o1, o2, o3, 0, 1)
		| opCSINV: CondSelect(o0, o1, o2, o3, 1, 0)
		| opCSNEG: CondSelect(o0, o1, o2, o3, 1, 1)
		| opCSET:
			InitCondition(temp, InvertCondition(o1.condition));
			CondSelect(o0, zero, zero, temp, 0, 1)
		| opCSETM:
			InitCondition(temp, InvertCondition(o1.condition));
			CondSelect(o0, zero, zero, temp, 1, 0)
		| opCINC:
			InitCondition(temp, InvertCondition(o2.condition));
			CondSelect(o0, o1, o1, temp, 0, 1)
		| opCINV:
			InitCondition(temp, InvertCondition(o2.condition));
			CondSelect(o0, o1, o1, temp, 1, 0)
		| opCNEG:
			InitCondition(temp, InvertCondition(o2.condition));
			CondSelect(o0, o1, o1, temp, 1, 1)

		(* branches *)
		| opB:  Branch(o0, 0)
		| opBL: Branch(o0, 1)
		| opBCOND: BranchConditional(o0, o1)
		| opBR:  BranchRegister(o0, 0)
		| opBLR: BranchRegister(o0, 1)
		| opRET:
			IF o0.mode = modeRegister THEN BranchRegister(o0, 2)
			ELSE InitRegister(temp, LR, 64); BranchRegister(temp, 2)
			END
		| opCBZ:  CompareAndBranch(o0, o1, 0)
		| opCBNZ: CompareAndBranch(o0, o1, 1)
		| opTBZ:  TestAndBranch(o0, o1, o2, 0)
		| opTBNZ: TestAndBranch(o0, o1, o2, 1)

		(* system *)
		| opNOP: Put(0D503201FH, 0, 31)
		| opBRK: Exception(o0, 1, 0)
		| opSVC: Exception(o0, 0, 1)
		| opHLT: Exception(o0, 2, 0)
		| opDMB: Barrier(o0, 5)
		| opDSB: Barrier(o0, 4)
		| opISB: Barrier(o0, 6)

		(* loads and stores; the width of a plain LDR or STR is the width of the register *)
		| opLDR:
			(* an immediate rather than an address means the literal form *)
			IF o1.mode = modeImmediate THEN LoadLiteral(o0, o1)
			ELSE LoadStoreOfWidth(o0, o1, o0.size, TRUE, FALSE, FALSE)
			END
		| opLDRB:  LoadStoreOfWidth(o0, o1, 8, TRUE, FALSE, FALSE)
		| opLDRH:  LoadStoreOfWidth(o0, o1, 16, TRUE, FALSE, FALSE)
		| opLDRSB: LoadStoreOfWidth(o0, o1, 8, TRUE, TRUE, FALSE)
		| opLDRSH: LoadStoreOfWidth(o0, o1, 16, TRUE, TRUE, FALSE)
		| opLDRSW: LoadStoreOfWidth(o0, o1, 32, TRUE, TRUE, FALSE)
		| opSTR:   LoadStoreOfWidth(o0, o1, o0.size, FALSE, FALSE, FALSE)
		| opSTRB:  LoadStoreOfWidth(o0, o1, 8, FALSE, FALSE, FALSE)
		| opSTRH:  LoadStoreOfWidth(o0, o1, 16, FALSE, FALSE, FALSE)
		| opLDUR:   LoadStoreOfWidth(o0, o1, o0.size, TRUE, FALSE, TRUE)
		| opLDURB:  LoadStoreOfWidth(o0, o1, 8, TRUE, FALSE, TRUE)
		| opLDURH:  LoadStoreOfWidth(o0, o1, 16, TRUE, FALSE, TRUE)
		| opLDURSB: LoadStoreOfWidth(o0, o1, 8, TRUE, TRUE, TRUE)
		| opLDURSH: LoadStoreOfWidth(o0, o1, 16, TRUE, TRUE, TRUE)
		| opLDURSW: LoadStoreOfWidth(o0, o1, 32, TRUE, TRUE, TRUE)
		| opSTUR:   LoadStoreOfWidth(o0, o1, o0.size, FALSE, FALSE, TRUE)
		| opSTURB:  LoadStoreOfWidth(o0, o1, 8, FALSE, FALSE, TRUE)
		| opSTURH:  LoadStoreOfWidth(o0, o1, 16, FALSE, FALSE, TRUE)
		| opLDP: LoadStorePair(o0, o1, o2, TRUE)
		| opSTP: LoadStorePair(o0, o1, o2, FALSE)

		(* the exclusive and ordered accesses; a store returns its status in a register, a load
			does not, which is why the operands are shifted along *)
		| opLDXR:  LoadStoreExclusive(o0, o0, o1, 0, 1, 0, -1, FALSE)
		| opLDAXR: LoadStoreExclusive(o0, o0, o1, 0, 1, 1, -1, FALSE)
		| opLDAR:  LoadStoreExclusive(o0, o0, o1, 1, 1, 1, -1, FALSE)
		| opSTXR:  LoadStoreExclusive(o0, o1, o2, 0, 0, 0, -1, TRUE)
		| opSTLXR: LoadStoreExclusive(o0, o1, o2, 0, 0, 1, -1, TRUE)
		| opSTLR:  LoadStoreExclusive(o0, o0, o1, 1, 0, 1, -1, FALSE)
		| opLDXRB:  LoadStoreExclusive(o0, o0, o1, 0, 1, 0, 0, FALSE)
		| opLDAXRB: LoadStoreExclusive(o0, o0, o1, 0, 1, 1, 0, FALSE)
		| opLDARB:  LoadStoreExclusive(o0, o0, o1, 1, 1, 1, 0, FALSE)
		| opSTXRB:  LoadStoreExclusive(o0, o1, o2, 0, 0, 0, 0, TRUE)
		| opSTLXRB: LoadStoreExclusive(o0, o1, o2, 0, 0, 1, 0, TRUE)
		| opSTLRB:  LoadStoreExclusive(o0, o0, o1, 1, 0, 1, 0, FALSE)

		(* scalar floating point *)
		| opFMOV: FpMove(o0, o1)
		| opFADD: FpDataProcessing2(o0, o1, o2, 2)
		| opFSUB: FpDataProcessing2(o0, o1, o2, 3)
		| opFMUL: FpDataProcessing2(o0, o1, o2, 0)
		| opFDIV: FpDataProcessing2(o0, o1, o2, 1)
		| opFNMUL: FpDataProcessing2(o0, o1, o2, 8)
		| opFMAX: FpDataProcessing2(o0, o1, o2, 4)
		| opFMIN: FpDataProcessing2(o0, o1, o2, 5)
		| opFABS:  FpDataProcessing1(o0, o1, FpType(o0), 1)
		| opFNEG:  FpDataProcessing1(o0, o1, FpType(o0), 2)
		| opFSQRT: FpDataProcessing1(o0, o1, FpType(o0), 3)
		(* the opcode of FCVT names the destination type, the type field the source *)
		| opFCVT: FpDataProcessing1(o0, o1, FpType(o1), 4 + FpType(o0))
		| opFCMP:  FpCompare(o0, o1, FALSE)
		| opFCMPE: FpCompare(o0, o1, TRUE)
		| opSCVTF:  FpConvert(o0, o1, o1, o0, 0, 2)
		| opUCVTF:  FpConvert(o0, o1, o1, o0, 0, 3)
		(* rmode names the rounding: 11 is towards zero, 10 towards minus infinity, which is the
			one Oberon's ENTIER asks for *)
		| opFCVTZS: FpConvert(o0, o1, o0, o1, 3, 0)
		| opFCVTZU: FpConvert(o0, o1, o0, o1, 3, 1)
		| opFCVTMS: FpConvert(o0, o1, o0, o1, 2, 0)
		| opFCVTMU: FpConvert(o0, o1, o0, o1, 2, 1)
		| opFCVTNS: FpConvert(o0, o1, o0, o1, 0, 0)
		| opFCVTNU: FpConvert(o0, o1, o0, o1, 0, 1)
		| opMRS: SystemRegisterMove(o0, o1, 1)
		| opMSR: SystemRegisterMove(o1, o0, 0)
		| opFCSEL: FpCondSelect(o0, o1, o2, o3)
		ELSE
			error := TRUE
		END;

		code := SYSTEM.VAL(SIGNED32, codeSet);
		RETURN ~error
	END Encode;

(* ---- writing an instruction out ---------------------------------------------------------------

	The listing prints what was written rather than what was encoded -- CMP rather than the SUBS it
	becomes -- and in the syntax the Arm assembler uses, so that a line of a listing can be pasted
	into an assembler and produce the same word back.
*)

	PROCEDURE WriteRegister*(w: Streams.Writer; register: SIGNED32; size: SIGNED16; isStackPointer: BOOLEAN);
	BEGIN
		IF register >= V0 THEN
			CASE size OF
			| 8: w.Char('b')
			| 16: w.Char('h')
			| 32: w.Char('s')
			| 64: w.Char('d')
			| 128: w.Char('q')
			ELSE w.Char('v')
			END;
			w.Int(register - V0, 0)
		ELSIF register = SP THEN
			IF isStackPointer THEN
				IF size = 32 THEN w.String("wsp") ELSE w.String("sp") END
			ELSE
				IF size = 32 THEN w.String("wzr") ELSE w.String("xzr") END
			END
		ELSE
			IF size = 32 THEN w.Char('w') ELSE w.Char('x') END;
			w.Int(register, 0)
		END
	END WriteRegister;

	PROCEDURE WriteShift(w: Streams.Writer; mode: SIGNED8; amount: SIGNED32);
	BEGIN
		CASE mode OF
		| shiftLSL: w.String("lsl")
		| shiftLSR: w.String("lsr")
		| shiftASR: w.String("asr")
		| shiftROR: w.String("ror")
		END;
		w.String(" #"); w.Int(amount, 0)
	END WriteShift;

	PROCEDURE WriteExtend(w: Streams.Writer; extend: SIGNED8; amount: SIGNED32);
	BEGIN
		CASE extend OF
		| extendUXTB: w.String("uxtb")
		| extendUXTH: w.String("uxth")
		| extendUXTW: w.String("uxtw")
		| extendUXTX: w.String("uxtx")
		| extendSXTB: w.String("sxtb")
		| extendSXTH: w.String("sxth")
		| extendSXTW: w.String("sxtw")
		| extendSXTX: w.String("sxtx")
		END;
		IF amount # 0 THEN w.String(" #"); w.Int(amount, 0) END
	END WriteExtend;

	(** the name of a system register, or the number itself when it has none **)
	PROCEDURE WriteSystemRegister*(w: Streams.Writer; value: Basic.Integer);
	VAR i: SIGNED32;
	BEGIN
		FOR i := 0 TO NumberSystemRegisters - 1 DO
			IF systemRegisterValues[i] = value THEN w.String(systemRegisterNames[i]); RETURN END
		END;
		w.String("#"); w.Int(value, 0)
	END WriteSystemRegister;

	PROCEDURE WriteOperand*(w: Streams.Writer; CONST operand: Operand);
	BEGIN
		CASE operand.mode OF
		| modeNone:
		| modeRegister:
			WriteRegister(w, operand.register, operand.size, operand.isStackPointer);
			IF operand.extend # None THEN
				w.String(", "); WriteExtend(w, operand.extend, operand.shiftAmount)
			ELSIF (operand.shiftMode # None) & (operand.shiftAmount # 0) THEN
				w.String(", "); WriteShift(w, operand.shiftMode, operand.shiftAmount)
			END
		| modeImmediate:
			IF operand.fixup # NIL THEN
				Basic.WriteSegmentedName(w, operand.fixup.symbol.name)
			ELSE
				w.String("#"); w.Int(operand.immediate, 0);
				IF (operand.shiftMode # None) & (operand.shiftAmount # 0) THEN
					w.String(", "); WriteShift(w, operand.shiftMode, operand.shiftAmount)
				END
			END
		| modeCondition:
			w.String(conditionNames[operand.condition])
		| modeMemory:
			w.Char('[');
			WriteRegister(w, operand.register, 64, TRUE);
			IF operand.indexing = indexPost THEN
				w.String("], #"); w.Int(operand.immediate, 0)
			ELSE
				IF operand.index # None THEN
					w.String(", ");
					WriteRegister(w, operand.index, operand.indexSize, FALSE);
					IF (operand.extend = extendUXTX) OR (operand.extend = None) THEN
						(* an index that is neither widened nor narrowed is written as a shift,
							which is what UXTX of a 64 bit register amounts to *)
						IF operand.shiftAmount # 0 THEN
							w.String(", "); WriteShift(w, shiftLSL, operand.shiftAmount)
						END
					ELSE
						w.String(", "); WriteExtend(w, operand.extend, operand.shiftAmount)
					END
				ELSIF operand.immediate # 0 THEN
					w.String(", #"); w.Int(operand.immediate, 0)
				END;
				w.Char(']');
				IF operand.indexing = indexPre THEN w.Char('!') END
			END
		END
	END WriteOperand;

	PROCEDURE DumpInstruction*(w: Streams.Writer; CONST instruction: Instruction);
	VAR i, last: SIGNED32;
	BEGIN
		w.String(mnemonicNames[instruction.mnemonic]);
		IF instruction.mnemonic = opBCOND THEN
			w.Char('.'); w.String(conditionNames[instruction.operands[0].condition])
		END;
		last := -1;
		FOR i := 0 TO MaxOperands - 1 DO
			IF instruction.operands[i].mode # modeNone THEN last := i END
		END;
		FOR i := 0 TO last DO
			IF (instruction.mnemonic = opBCOND) & (i = 0) THEN
				(* the condition was printed as part of the mnemonic *)
			ELSE
				IF (i = 0) OR ((instruction.mnemonic = opBCOND) & (i = 1)) THEN w.Char(09X) ELSE w.String(", ") END;
				IF ((instruction.mnemonic = opMRS) & (i = 1)) OR ((instruction.mnemonic = opMSR) & (i = 0)) THEN
					WriteSystemRegister(w, instruction.operands[i].immediate)
				ELSIF ((instruction.mnemonic = opFCMP) OR (instruction.mnemonic = opFCMPE))
						& (instruction.operands[i].mode = modeImmediate) THEN
					(* the only immediate a floating point comparison takes, and it is written as
						a floating point number rather than as the integer it is stored as *)
					w.String("#0.0")
				ELSE
					WriteOperand(w, instruction.operands[i])
				END
			END
		END
	END DumpInstruction;

(* ---- emitting --------------------------------------------------------------------------------- *)

	PROCEDURE EmitInstruction*(CONST instruction: Instruction; code: BinaryCode.Section): BOOLEAN;
	VAR encoding: SIGNED32; i: SIGNED32;
	BEGIN
		IF code.comments # NIL THEN
			DumpInstruction(code.comments, instruction);
			code.comments.Ln;
			code.comments.Update
		END;
		IF ~Encode(instruction, encoding) THEN RETURN FALSE END;
		(* Encode filled in the fixup patterns; the offset is only known here *)
		FOR i := 0 TO MaxOperands - 1 DO
			IF instruction.operands[i].fixup # NIL THEN
				instruction.operands[i].fixup.SetFixupOffset(code.pc);
				code.fixupList.AddFixup(instruction.operands[i].fixup)
			END
		END;
		code.PutBits(encoding, 32);
		RETURN TRUE
	END EmitInstruction;

	PROCEDURE Emit*(mnemonic: SIGNED32; CONST operands: ARRAY OF Operand; code: BinaryCode.Section);
	VAR instruction: Instruction;
	BEGIN
		MakeInstruction(instruction, mnemonic, operands);
		ASSERT(EmitInstruction(instruction, code))
	END Emit;

(* ---- naming ------------------------------------------------------------------------------------ *)

	(** the register a name denotes, along with the width the name implies

		Returns None when the name is not a register. LR and FP are accepted as the names of X30 and
		X29 because they are what the calling convention calls them.
	**)
	PROCEDURE RegisterFromName*(CONST registerName: ARRAY OF CHAR; VAR register: SIGNED32; VAR size: SIGNED16; VAR isStackPointer: BOOLEAN): BOOLEAN;
	VAR name: ARRAY 16 OF CHAR; number, i: SIGNED32; prefix: CHAR;
	BEGIN
		register := None; size := 0; isStackPointer := FALSE;
		IF Strings.Length(registerName) >= LEN(name) THEN RETURN FALSE END;
		COPY(registerName, name);
		Strings.LowerCase(name);

		IF name = "sp" THEN register := SP; size := 64; isStackPointer := TRUE; RETURN TRUE END;
		IF name = "wsp" THEN register := SP; size := 32; isStackPointer := TRUE; RETURN TRUE END;
		IF name = "xzr" THEN register := ZR; size := 64; RETURN TRUE END;
		IF name = "wzr" THEN register := ZR; size := 32; RETURN TRUE END;
		IF name = "lr" THEN register := LR; size := 64; RETURN TRUE END;
		IF name = "fp" THEN register := 29; size := 64; RETURN TRUE END;

		prefix := name[0];
		i := 1;
		IF (name[i] < '0') OR (name[i] > '9') THEN RETURN FALSE END;
		number := 0;
		WHILE (name[i] >= '0') & (name[i] <= '9') DO
			number := number * 10 + (ORD(name[i]) - ORD('0'));
			INC(i)
		END;
		IF name[i] # 0X THEN RETURN FALSE END;

		CASE prefix OF
		| 'w': IF number > 30 THEN RETURN FALSE END; register := number; size := 32
		| 'x': IF number > 30 THEN RETURN FALSE END; register := number; size := 64
		| 'b': IF number > 31 THEN RETURN FALSE END; register := V0 + number; size := 8
		| 'h': IF number > 31 THEN RETURN FALSE END; register := V0 + number; size := 16
		| 's': IF number > 31 THEN RETURN FALSE END; register := V0 + number; size := 32
		| 'd': IF number > 31 THEN RETURN FALSE END; register := V0 + number; size := 64
		| 'q': IF number > 31 THEN RETURN FALSE END; register := V0 + number; size := 128
		ELSE RETURN FALSE
		END;
		RETURN TRUE
	END RegisterFromName;

	PROCEDURE ConditionFromName*(CONST conditionName: ARRAY OF CHAR): SIGNED32;
	VAR name: ARRAY 8 OF CHAR; i: SIGNED32;
	BEGIN
		IF Strings.Length(conditionName) >= LEN(name) THEN RETURN None END;
		COPY(conditionName, name);
		Strings.LowerCase(name);
		(* HS and LO are the other names of CS and CC, and turn up in unsigned comparisons *)
		IF name = "hs" THEN RETURN conditionCS END;
		IF name = "lo" THEN RETURN conditionCC END;
		FOR i := 0 TO NumberConditions - 1 DO
			IF name = conditionNames[i] THEN RETURN i END
		END;
		RETURN None
	END ConditionFromName;

	(** the sixteen bits that name a system register, or None when the identifier names none **)
	PROCEDURE SystemRegisterFromName*(CONST registerName: ARRAY OF CHAR): SIGNED32;
	VAR name: ARRAY 16 OF CHAR; i: SIGNED32;
	BEGIN
		IF Strings.Length(registerName) >= LEN(name) THEN RETURN None END;
		COPY(registerName, name);
		Strings.LowerCase(name);
		FOR i := 0 TO NumberSystemRegisters - 1 DO
			IF name = systemRegisterNames[i] THEN RETURN systemRegisterValues[i] END
		END;
		RETURN None
	END SystemRegisterFromName;

	PROCEDURE ShiftFromName*(CONST shiftName: ARRAY OF CHAR): SIGNED32;
	VAR name: ARRAY 8 OF CHAR;
	BEGIN
		IF Strings.Length(shiftName) >= LEN(name) THEN RETURN None END;
		COPY(shiftName, name);
		Strings.LowerCase(name);
		IF name = "lsl" THEN RETURN shiftLSL END;
		IF name = "lsr" THEN RETURN shiftLSR END;
		IF name = "asr" THEN RETURN shiftASR END;
		IF name = "ror" THEN RETURN shiftROR END;
		RETURN None
	END ShiftFromName;

	PROCEDURE ExtendFromName*(CONST extendName: ARRAY OF CHAR): SIGNED32;
	VAR name: ARRAY 8 OF CHAR;
	BEGIN
		IF Strings.Length(extendName) >= LEN(name) THEN RETURN None END;
		COPY(extendName, name);
		Strings.LowerCase(name);
		IF name = "uxtb" THEN RETURN extendUXTB END;
		IF name = "uxth" THEN RETURN extendUXTH END;
		IF name = "uxtw" THEN RETURN extendUXTW END;
		IF name = "uxtx" THEN RETURN extendUXTX END;
		IF name = "sxtb" THEN RETURN extendSXTB END;
		IF name = "sxth" THEN RETURN extendSXTH END;
		IF name = "sxtw" THEN RETURN extendSXTW END;
		IF name = "sxtx" THEN RETURN extendSXTX END;
		RETURN None
	END ExtendFromName;

	(** the mnemonic a name denotes; a conditional branch carries its condition in the name **)
	PROCEDURE FindMnemonic*(CONST mnemonicName: ARRAY OF CHAR; VAR mnemonic, condition: SIGNED32): BOOLEAN;
	VAR name: ARRAY 16 OF CHAR; suffix: ARRAY 8 OF CHAR; i: SIGNED32;
	BEGIN
		mnemonic := None; condition := None;
		IF Strings.Length(mnemonicName) >= LEN(name) THEN RETURN FALSE END;
		COPY(mnemonicName, name);
		Strings.LowerCase(name);

		IF (name[0] = 'b') & (name[1] = '.') THEN
			FOR i := 0 TO LEN(suffix) - 1 DO suffix[i] := 0X END;
			i := 0;
			WHILE (name[i + 2] # 0X) & (i < LEN(suffix) - 1) DO suffix[i] := name[i + 2]; INC(i) END;
			condition := ConditionFromName(suffix);
			IF condition = None THEN RETURN FALSE END;
			mnemonic := opBCOND;
			RETURN TRUE
		END;

		FOR i := 0 TO NumberMnemonics - 1 DO
			IF name = mnemonicNames[i] THEN mnemonic := i; RETURN TRUE END
		END;
		RETURN FALSE
	END FindMnemonic;

	PROCEDURE MnemonicName*(mnemonic: SIGNED32): Name;
	BEGIN RETURN mnemonicNames[mnemonic]
	END MnemonicName;

(* ---- the self test ------------------------------------------------------------------------------

	`Test` writes one line per instruction: the encoding as eight hexadecimal digits, a tab, and the
	instruction as DumpInstruction writes it. Both halves are under test, because the text is fed to
	an assembler that is known to be right -- llvm-mc -- and the word it produces is compared with
	the one printed here. A mistake in the encoder and a matching mistake in the printer would have
	to agree with the Arm Architecture Reference Manual to survive that, which is the point.

	The list is not exhaustive over operand values; it covers every encoding path, both register
	widths where the sf bit selects between them, and the boundary of every immediate field.
*)

	PROCEDURE Test*(context: Commands.Context);
	VAR w: Streams.Writer; failures: SIGNED32;

		PROCEDURE Hex(code: SIGNED32);
		VAR i, nibble: SIGNED32; value: SIGNED64;
		BEGIN
			value := And64(code, Ones(32));
			FOR i := 7 TO 0 BY -1 DO
				nibble := SIGNED32(And64(Shr64(value, i * 4), 15));
				IF nibble < 10 THEN w.Char(CHR(ORD('0') + nibble))
				ELSE w.Char(CHR(ORD('a') + nibble - 10))
				END
			END
		END Hex;

		PROCEDURE Check(mnemonic: SIGNED32; CONST operands: ARRAY OF Operand);
		VAR instruction: Instruction; code: SIGNED32;
		BEGIN
			MakeInstruction(instruction, mnemonic, operands);
			IF Encode(instruction, code) THEN Hex(code)
			ELSE w.String("--------"); INC(failures)
			END;
			w.Char(09X);
			DumpInstruction(w, instruction);
			w.Ln
		END Check;

		PROCEDURE Check0(mnemonic: SIGNED32);
		VAR operands: ARRAY 1 OF Operand;
		BEGIN InitOperand(operands[0]); Check(mnemonic, operands)
		END Check0;

		PROCEDURE Check1(mnemonic: SIGNED32; CONST a: Operand);
		VAR operands: ARRAY 1 OF Operand;
		BEGIN operands[0] := a; Check(mnemonic, operands)
		END Check1;

		PROCEDURE Check2(mnemonic: SIGNED32; CONST a, b: Operand);
		VAR operands: ARRAY 2 OF Operand;
		BEGIN operands[0] := a; operands[1] := b; Check(mnemonic, operands)
		END Check2;

		PROCEDURE Check3(mnemonic: SIGNED32; CONST a, b, c: Operand);
		VAR operands: ARRAY 3 OF Operand;
		BEGIN operands[0] := a; operands[1] := b; operands[2] := c; Check(mnemonic, operands)
		END Check3;

		PROCEDURE Check4(mnemonic: SIGNED32; CONST a, b, c, d: Operand);
		VAR operands: ARRAY 4 OF Operand;
		BEGIN operands[0] := a; operands[1] := b; operands[2] := c; operands[3] := d; Check(mnemonic, operands)
		END Check4;

		PROCEDURE X(number: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitRegister(o, number, 64); RETURN o
		END X;

		PROCEDURE Wr(number: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitRegister(o, number, 32); RETURN o
		END Wr;

		PROCEDURE Sp(): Operand;
		VAR o: Operand;
		BEGIN InitStackPointer(o, 64); RETURN o
		END Sp;

		PROCEDURE Sh(number: SIGNED32; size: SIGNED16; mode: SIGNED8; amount: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitShiftedRegister(o, number, size, mode, amount); RETURN o
		END Sh;

		PROCEDURE Ext(number: SIGNED32; size: SIGNED16; extend: SIGNED8; amount: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitExtendedRegister(o, number, size, extend, amount); RETURN o
		END Ext;

		PROCEDURE Im(value: Basic.Integer): Operand;
		VAR o: Operand;
		BEGIN InitImmediate(o, value); RETURN o
		END Im;

		PROCEDURE ImSh(value: Basic.Integer; amount: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitShiftedImmediate(o, value, amount); RETURN o
		END ImSh;

		PROCEDURE Cc(condition: SIGNED8): Operand;
		VAR o: Operand;
		BEGIN InitCondition(o, condition); RETURN o
		END Cc;

		PROCEDURE Dr(number: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitRegister(o, V0 + number, 64); RETURN o
		END Dr;

		PROCEDURE Sr(number: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitRegister(o, V0 + number, 32); RETURN o
		END Sr;

		PROCEDURE Mem(base: SIGNED32; offset: Basic.Integer): Operand;
		VAR o: Operand;
		BEGIN InitImmediateOffsetMemory(o, base, offset, indexOffset); RETURN o
		END Mem;

		PROCEDURE MemSp(offset: Basic.Integer): Operand;
		VAR o: Operand;
		BEGIN InitImmediateOffsetMemory(o, SP, offset, indexOffset); RETURN o
		END MemSp;

		PROCEDURE MemIndexed(base: SIGNED32; offset: Basic.Integer; indexing: SIGNED8): Operand;
		VAR o: Operand;
		BEGIN InitImmediateOffsetMemory(o, base, offset, indexing); RETURN o
		END MemIndexed;

		PROCEDURE MemReg(base, index: SIGNED32; indexSize: SIGNED16; extend: SIGNED8; amount: SIGNED32): Operand;
		VAR o: Operand;
		BEGIN InitRegisterOffsetMemory(o, base, index, indexSize, extend, amount); RETURN o
		END MemReg;

	BEGIN
		w := context.out;
		failures := 0;

		(* add and subtract, register and immediate, both widths *)
		Check3(opADD, X(0), X(1), X(2));
		Check3(opADD, Wr(0), Wr(1), Wr(2));
		Check3(opADD, X(0), X(1), Im(16));
		Check3(opADD, X(0), X(1), Im(4095));
		Check3(opADD, X(0), X(1), ImSh(1, 12));
		Check3(opADD, X(0), X(1), Im(4096));				(* fits only shifted, and is shifted *)
		Check3(opADD, X(0), X(1), Im(-16));					(* the sign moves into the mnemonic *)
		Check3(opADD, X(3), X(4), Sh(5, 64, shiftLSL, 3));
		Check3(opADD, X(3), X(4), Sh(5, 64, shiftASR, 7));
		Check3(opADD, Sp(), Sp(), Im(32));
		Check3(opADD, X(0), Sp(), X(1));						(* naming SP forces the extended form *)
		Check3(opADD, X(0), X(1), Ext(2, 32, extendUXTW, 2));
		Check3(opADDS, X(0), X(1), X(2));
		Check3(opSUB, X(0), X(1), X(2));
		Check3(opSUB, Wr(0), Wr(1), Im(1));
		Check3(opSUBS, X(0), X(1), X(2));
		Check2(opCMP, X(1), X(2));
		Check2(opCMP, X(1), Im(7));
		Check2(opCMP, Wr(1), Wr(2));
		Check2(opCMN, X(1), X(2));
		Check2(opNEG, X(0), X(1));
		Check2(opNEGS, Wr(0), Wr(1));

		(* logical *)
		Check3(opAND, X(0), X(1), X(2));
		Check3(opAND, X(0), X(1), Im(255));
		Check3(opAND, Wr(0), Wr(1), Im(7));
		Check3(opAND, X(0), X(1), Im(0FFFFFFFFH));
		Check3(opORR, X(0), X(1), X(2));
		Check3(opORR, X(0), X(1), Sh(2, 64, shiftROR, 8));
		Check3(opEOR, X(0), X(1), X(2));
		Check3(opBIC, X(0), X(1), X(2));
		Check3(opORN, X(0), X(1), X(2));
		Check3(opEON, X(0), X(1), X(2));
		Check3(opANDS, X(0), X(1), X(2));
		Check3(opBICS, X(0), X(1), X(2));
		Check2(opTST, X(1), X(2));
		Check2(opTST, X(1), Im(1));
		Check2(opMVN, X(0), X(1));
		Check2(opMOV, X(0), X(1));
		Check2(opMOV, Wr(0), Wr(1));
		Check2(opMOV, Sp(), X(1));
		Check2(opMOV, X(0), Im(0));
		Check2(opMOV, X(5), Im(305397760));					(* one halfword, shifted: MOVZ *)
		Check2(opMOV, X(0), Im(-1));							(* the complement is zero: MOVN *)
		Check2(opMOV, X(0), Im(255));

		(* move wide *)
		Check2(opMOVZ, X(5), ImSh(1234H, 16));
		Check2(opMOVZ, Wr(5), Im(1));
		Check2(opMOVN, X(0), Im(0));
		Check2(opMOVK, X(0), ImSh(0ABCDH, 48));

		(* bitfield and its aliases *)
		Check4(opUBFM, X(0), X(1), Im(3), Im(20));
		Check4(opSBFM, X(0), X(1), Im(3), Im(20));
		Check4(opBFM, X(0), X(1), Im(3), Im(20));
		Check4(opUBFX, X(0), X(1), Im(4), Im(8));
		Check4(opSBFX, X(0), X(1), Im(4), Im(8));
		Check4(opUBFIZ, X(0), X(1), Im(4), Im(8));
		Check4(opSBFIZ, X(0), X(1), Im(4), Im(8));
		Check4(opBFI, X(0), X(1), Im(4), Im(8));
		Check4(opBFXIL, X(0), X(1), Im(4), Im(8));
		Check2(opSXTB, X(0), Wr(1));
		Check2(opSXTH, X(0), Wr(1));
		Check2(opSXTW, X(0), Wr(1));
		Check2(opUXTB, Wr(0), Wr(1));
		Check2(opUXTH, Wr(0), Wr(1));

		(* shifts, by an immediate and by a register *)
		Check3(opLSL, X(0), X(1), Im(4));
		Check3(opLSL, Wr(0), Wr(1), Im(4));
		Check3(opLSR, X(0), X(1), Im(4));
		Check3(opASR, X(0), X(1), Im(4));
		Check3(opROR, X(0), X(1), Im(4));
		Check3(opLSL, X(0), X(1), X(2));
		Check3(opLSR, X(0), X(1), X(2));
		Check3(opASR, X(0), X(1), X(2));
		Check3(opROR, X(0), X(1), X(2));
		Check4(opEXTR, X(0), X(1), X(2), Im(20));

		(* multiply and divide *)
		Check3(opMUL, X(0), X(1), X(2));
		Check3(opMUL, Wr(0), Wr(1), Wr(2));
		Check3(opMNEG, X(0), X(1), X(2));
		Check4(opMADD, X(0), X(1), X(2), X(3));
		Check4(opMSUB, X(0), X(1), X(2), X(3));
		Check3(opSMULL, X(0), Wr(1), Wr(2));
		Check3(opUMULL, X(0), Wr(1), Wr(2));
		Check3(opSMNEGL, X(0), Wr(1), Wr(2));
		Check3(opUMNEGL, X(0), Wr(1), Wr(2));
		Check4(opSMADDL, X(0), Wr(1), Wr(2), X(3));
		Check4(opUMSUBL, X(0), Wr(1), Wr(2), X(3));
		Check3(opSMULH, X(0), X(1), X(2));
		Check3(opUMULH, X(0), X(1), X(2));
		Check3(opSDIV, X(0), X(1), X(2));
		Check3(opUDIV, Wr(0), Wr(1), Wr(2));

		(* counting and reversing bits *)
		Check2(opCLZ, X(0), X(1));
		Check2(opCLZ, Wr(0), Wr(1));
		Check2(opCLS, X(0), X(1));
		Check2(opRBIT, X(0), X(1));
		Check2(opREV, X(0), X(1));
		Check2(opREV, Wr(0), Wr(1));
		Check2(opREV16, X(0), X(1));
		Check2(opREV32, X(0), X(1));

		(* conditional select *)
		Check4(opCSEL, X(0), X(1), X(2), Cc(conditionEQ));
		Check4(opCSINC, X(0), X(1), X(2), Cc(conditionNE));
		Check4(opCSINV, X(0), X(1), X(2), Cc(conditionGE));
		Check4(opCSNEG, X(0), X(1), X(2), Cc(conditionLT));
		Check2(opCSET, X(0), Cc(conditionEQ));
		Check2(opCSETM, Wr(0), Cc(conditionNE));
		Check3(opCINC, X(0), X(1), Cc(conditionGT));
		Check3(opCINV, X(0), X(1), Cc(conditionLE));
		Check3(opCNEG, X(0), X(1), Cc(conditionMI));

		(* branches; a displacement written as a number counts bytes from the branch itself *)
		Check1(opB, Im(16));
		Check1(opB, Im(-16));
		Check1(opBL, Im(16));
		Check2(opBCOND, Cc(conditionEQ), Im(16));
		Check2(opBCOND, Cc(conditionLS), Im(-8));
		Check1(opBR, X(3));
		Check1(opBLR, X(3));
		Check0(opRET);
		Check1(opRET, X(3));
		Check2(opCBZ, X(0), Im(16));
		Check2(opCBNZ, Wr(0), Im(-4));
		Check3(opTBZ, X(0), Im(40), Im(16));
		Check3(opTBNZ, Wr(0), Im(3), Im(-4));

		(* system *)
		Check0(opNOP);
		Check1(opBRK, Im(1));
		Check1(opSVC, Im(0));
		Check1(opHLT, Im(0F000H));
		Check1(opDMB, Im(15));
		Check1(opDSB, Im(15));
		Check1(opISB, Im(15));
		Check2(opMRS, X(0), Im(sysFPCR));
		Check2(opMSR, Im(sysFPCR), X(1));
		Check2(opMRS, X(2), Im(sysCNTVCTEL0));

		(* loads and stores: every addressing form, every width, both signednesses *)
		Check2(opLDR, X(3), Im(8));								(* the literal form *)
		Check2(opLDR, Dr(3), Im(-8));
		Check2(opLDR, X(3), Mem(4, 16));
		Check2(opLDR, X(3), Mem(4, 32760));					(* the top of the scaled range *)
		Check2(opLDR, Wr(3), Mem(4, 16));
		Check2(opLDR, X(3), Mem(4, 0));
		Check2(opLDR, X(3), Mem(4, -8));						(* not representable scaled: the unscaled form *)
		Check2(opLDR, X(3), Mem(4, 4));							(* not a multiple of eight: likewise *)
		Check2(opLDR, X(3), MemSp(16));
		Check2(opLDR, X(3), MemIndexed(4, 16, indexPre));
		Check2(opLDR, X(3), MemIndexed(4, 16, indexPost));
		Check2(opLDR, X(3), MemReg(4, 5, 64, None, 0));
		Check2(opLDR, X(3), MemReg(4, 5, 64, extendUXTX, 3));
		Check2(opLDR, X(3), MemReg(4, 5, 32, extendUXTW, 3));
		Check2(opLDR, X(3), MemReg(4, 5, 32, extendSXTW, 0));
		Check2(opLDRB, Wr(3), Mem(4, 1));
		Check2(opLDRH, Wr(3), Mem(4, 2));
		Check2(opLDRSB, X(3), Mem(4, 1));
		Check2(opLDRSB, Wr(3), Mem(4, 1));
		Check2(opLDRSH, X(3), Mem(4, 2));
		Check2(opLDRSW, X(3), Mem(4, 4));
		Check2(opSTR, X(3), Mem(4, 16));
		Check2(opSTR, Wr(3), Mem(4, 16));
		Check2(opSTRB, Wr(3), Mem(4, 1));
		Check2(opSTRH, Wr(3), Mem(4, 2));
		Check2(opSTR, X(3), MemIndexed(4, -16, indexPre));
		Check2(opLDUR, X(3), Mem(4, 16));						(* scaled would fit, but LDUR was written *)
		Check2(opSTUR, X(3), Mem(4, -16));
		Check2(opLDURB, Wr(3), Mem(4, 3));
		Check2(opLDURSW, X(3), Mem(4, 3));

		(* pairs *)
		Check3(opSTP, X(29), X(30), MemIndexed(SP, -16, indexPre));
		Check3(opLDP, X(29), X(30), MemIndexed(SP, 16, indexPost));
		Check3(opSTP, X(0), X(1), MemSp(16));
		Check3(opLDP, Wr(0), Wr(1), Mem(2, 8));
		Check3(opSTP, Dr(0), Dr(1), MemSp(16));
		Check3(opLDP, Sr(0), Sr(1), Mem(2, 8));

		(* the exclusive and ordered accesses *)
		Check2(opLDXR, X(0), Mem(1, 0));
		Check2(opLDXR, Wr(0), Mem(1, 0));
		Check2(opLDAXR, X(0), Mem(1, 0));
		Check3(opSTXR, Wr(2), X(0), Mem(1, 0));
		Check3(opSTLXR, Wr(2), Wr(0), Mem(1, 0));
		Check2(opLDAR, X(0), Mem(1, 0));
		Check2(opSTLR, X(0), Mem(1, 0));
		Check2(opLDXRB, Wr(0), Mem(1, 0));
		Check2(opLDAXRB, Wr(0), Mem(1, 0));
		Check2(opLDARB, Wr(0), Mem(1, 0));
		Check3(opSTXRB, Wr(2), Wr(0), Mem(1, 0));
		Check3(opSTLXRB, Wr(2), Wr(0), Mem(1, 0));
		Check2(opSTLRB, Wr(0), Mem(1, 0));

		(* floating point loads and stores go through the same forms with V set *)
		Check2(opLDR, Dr(0), Mem(1, 16));
		Check2(opLDR, Sr(0), Mem(1, 16));
		Check2(opSTR, Dr(0), Mem(1, 16));
		Check2(opSTR, Sr(0), MemIndexed(1, 4, indexPost));
		Check2(opLDR, Dr(0), MemReg(1, 2, 64, extendUXTX, 3));

		(* scalar floating point arithmetic *)
		Check3(opFADD, Dr(0), Dr(1), Dr(2));
		Check3(opFADD, Sr(0), Sr(1), Sr(2));
		Check3(opFSUB, Dr(0), Dr(1), Dr(2));
		Check3(opFMUL, Dr(0), Dr(1), Dr(2));
		Check3(opFDIV, Dr(0), Dr(1), Dr(2));
		Check3(opFNMUL, Dr(0), Dr(1), Dr(2));
		Check3(opFMAX, Dr(0), Dr(1), Dr(2));
		Check3(opFMIN, Sr(0), Sr(1), Sr(2));
		Check2(opFNEG, Dr(0), Dr(1));
		Check2(opFABS, Sr(0), Sr(1));
		Check2(opFSQRT, Dr(0), Dr(1));
		Check2(opFMOV, Dr(0), Dr(1));
		Check2(opFMOV, Sr(0), Sr(1));
		Check2(opFMOV, X(0), Dr(1));							(* out of a floating point register *)
		Check2(opFMOV, Dr(0), X(1));							(* and into one *)
		Check2(opFMOV, Wr(0), Sr(1));
		Check2(opFCMP, Dr(0), Dr(1));
		Check2(opFCMP, Dr(0), Im(0));							(* against zero, which is its own encoding *)
		Check2(opFCMPE, Sr(0), Sr(1));
		Check2(opFCVT, Sr(0), Dr(1));
		Check2(opFCVT, Dr(0), Sr(1));
		Check2(opSCVTF, Dr(0), X(1));
		Check2(opSCVTF, Sr(0), Wr(1));
		Check2(opUCVTF, Dr(0), X(1));
		Check2(opFCVTZS, X(0), Dr(1));
		Check2(opFCVTZS, Wr(0), Sr(1));
		Check2(opFCVTZU, X(0), Dr(1));
		Check2(opFCVTMS, X(0), Dr(1));
		Check2(opFCVTMS, Wr(0), Sr(1));
		Check2(opFCVTNS, X(0), Dr(1));
		Check2(opFCVTNS, Wr(0), Sr(1));
		Check2(opFCVTNU, X(0), Dr(1));
		Check2(opFCVTMU, X(0), Dr(1));
		Check4(opFCSEL, Dr(0), Dr(1), Dr(2), Cc(conditionEQ));

		IF failures # 0 THEN
			context.error.String("instructions that did not encode: ");
			context.error.Int(failures, 0); context.error.Ln;
			context.error.Update
		END;
		w.Update
	END Test;

(* ---- initialization --------------------------------------------------------------------------- *)

	PROCEDURE SetMnemonic(mnemonic: SIGNED32; CONST name: Name);
	BEGIN
		ASSERT(mnemonicNames[mnemonic] = "");	(* two constants with the same value *)
		mnemonicNames[mnemonic] := name
	END SetMnemonic;

	PROCEDURE Init;
	VAR i: SIGNED32;
	BEGIN
		FOR i := 0 TO NumberMnemonics - 1 DO mnemonicNames[i] := "" END;

		conditionNames[conditionEQ] := "eq"; conditionNames[conditionNE] := "ne";
		conditionNames[conditionCS] := "cs"; conditionNames[conditionCC] := "cc";
		conditionNames[conditionMI] := "mi"; conditionNames[conditionPL] := "pl";
		conditionNames[conditionVS] := "vs"; conditionNames[conditionVC] := "vc";
		conditionNames[conditionHI] := "hi"; conditionNames[conditionLS] := "ls";
		conditionNames[conditionGE] := "ge"; conditionNames[conditionLT] := "lt";
		conditionNames[conditionGT] := "gt"; conditionNames[conditionLE] := "le";
		conditionNames[conditionAL] := "al"; conditionNames[conditionNV] := "nv";

		systemRegisterNames[0] := "fpcr";        systemRegisterValues[0] := sysFPCR;
		systemRegisterNames[1] := "fpsr";        systemRegisterValues[1] := sysFPSR;
		systemRegisterNames[2] := "nzcv";        systemRegisterValues[2] := sysNZCV;
		systemRegisterNames[3] := "tpidr_el0";   systemRegisterValues[3] := sysTPIDREL0;
		systemRegisterNames[4] := "cntvct_el0";  systemRegisterValues[4] := sysCNTVCTEL0;
		systemRegisterNames[5] := "cntfrq_el0";  systemRegisterValues[5] := sysCNTFRQEL0;

		SetMnemonic(opADD, "add");    SetMnemonic(opADDS, "adds");
		SetMnemonic(opSUB, "sub");    SetMnemonic(opSUBS, "subs");
		SetMnemonic(opCMP, "cmp");    SetMnemonic(opCMN, "cmn");
		SetMnemonic(opNEG, "neg");    SetMnemonic(opNEGS, "negs");

		SetMnemonic(opAND, "and");    SetMnemonic(opANDS, "ands");
		SetMnemonic(opORR, "orr");    SetMnemonic(opORN, "orn");
		SetMnemonic(opEOR, "eor");    SetMnemonic(opEON, "eon");
		SetMnemonic(opBIC, "bic");    SetMnemonic(opBICS, "bics");
		SetMnemonic(opTST, "tst");    SetMnemonic(opMVN, "mvn");
		SetMnemonic(opMOV, "mov");

		SetMnemonic(opMOVZ, "movz");  SetMnemonic(opMOVN, "movn");
		SetMnemonic(opMOVK, "movk");

		SetMnemonic(opADR, "adr");    SetMnemonic(opADRP, "adrp");

		SetMnemonic(opSBFM, "sbfm");  SetMnemonic(opBFM, "bfm");
		SetMnemonic(opUBFM, "ubfm");
		SetMnemonic(opSBFIZ, "sbfiz"); SetMnemonic(opSBFX, "sbfx");
		SetMnemonic(opUBFIZ, "ubfiz"); SetMnemonic(opUBFX, "ubfx");
		SetMnemonic(opBFI, "bfi");    SetMnemonic(opBFXIL, "bfxil");
		SetMnemonic(opSXTB, "sxtb");  SetMnemonic(opSXTH, "sxth");
		SetMnemonic(opSXTW, "sxtw");  SetMnemonic(opUXTB, "uxtb");
		SetMnemonic(opUXTH, "uxth");

		SetMnemonic(opLSL, "lsl");    SetMnemonic(opLSR, "lsr");
		SetMnemonic(opASR, "asr");    SetMnemonic(opROR, "ror");
		SetMnemonic(opEXTR, "extr");

		SetMnemonic(opMUL, "mul");    SetMnemonic(opMNEG, "mneg");
		SetMnemonic(opMADD, "madd");  SetMnemonic(opMSUB, "msub");
		SetMnemonic(opSMULL, "smull"); SetMnemonic(opSMNEGL, "smnegl");
		SetMnemonic(opSMADDL, "smaddl"); SetMnemonic(opSMSUBL, "smsubl");
		SetMnemonic(opUMULL, "umull"); SetMnemonic(opUMNEGL, "umnegl");
		SetMnemonic(opUMADDL, "umaddl"); SetMnemonic(opUMSUBL, "umsubl");
		SetMnemonic(opSMULH, "smulh"); SetMnemonic(opUMULH, "umulh");
		SetMnemonic(opSDIV, "sdiv");  SetMnemonic(opUDIV, "udiv");

		SetMnemonic(opCLZ, "clz");    SetMnemonic(opCLS, "cls");
		SetMnemonic(opRBIT, "rbit");  SetMnemonic(opREV, "rev");
		SetMnemonic(opREV16, "rev16"); SetMnemonic(opREV32, "rev32");

		SetMnemonic(opCSEL, "csel");  SetMnemonic(opCSINC, "csinc");
		SetMnemonic(opCSINV, "csinv"); SetMnemonic(opCSNEG, "csneg");
		SetMnemonic(opCSET, "cset");  SetMnemonic(opCSETM, "csetm");
		SetMnemonic(opCINC, "cinc");  SetMnemonic(opCINV, "cinv");
		SetMnemonic(opCNEG, "cneg");

		SetMnemonic(opB, "b");        SetMnemonic(opBL, "bl");
		SetMnemonic(opBCOND, "b");    SetMnemonic(opBR, "br");
		SetMnemonic(opBLR, "blr");    SetMnemonic(opRET, "ret");
		SetMnemonic(opCBZ, "cbz");    SetMnemonic(opCBNZ, "cbnz");
		SetMnemonic(opTBZ, "tbz");    SetMnemonic(opTBNZ, "tbnz");

		SetMnemonic(opNOP, "nop");    SetMnemonic(opBRK, "brk");
		SetMnemonic(opSVC, "svc");    SetMnemonic(opHLT, "hlt");
		SetMnemonic(opDMB, "dmb");    SetMnemonic(opDSB, "dsb");
		SetMnemonic(opISB, "isb");

		SetMnemonic(opLDR, "ldr");    SetMnemonic(opLDRB, "ldrb");
		SetMnemonic(opLDRH, "ldrh");  SetMnemonic(opLDRSB, "ldrsb");
		SetMnemonic(opLDRSH, "ldrsh"); SetMnemonic(opLDRSW, "ldrsw");
		SetMnemonic(opSTR, "str");    SetMnemonic(opSTRB, "strb");
		SetMnemonic(opSTRH, "strh");
		SetMnemonic(opLDUR, "ldur");  SetMnemonic(opLDURB, "ldurb");
		SetMnemonic(opLDURH, "ldurh"); SetMnemonic(opLDURSB, "ldursb");
		SetMnemonic(opLDURSH, "ldursh"); SetMnemonic(opLDURSW, "ldursw");
		SetMnemonic(opSTUR, "stur");  SetMnemonic(opSTURB, "sturb");
		SetMnemonic(opSTURH, "sturh");
		SetMnemonic(opLDP, "ldp");    SetMnemonic(opSTP, "stp");

		SetMnemonic(opLDXR, "ldxr");  SetMnemonic(opSTXR, "stxr");
		SetMnemonic(opLDAXR, "ldaxr"); SetMnemonic(opSTLXR, "stlxr");
		SetMnemonic(opLDAR, "ldar");  SetMnemonic(opSTLR, "stlr");
		SetMnemonic(opFCVTNS, "fcvtns"); SetMnemonic(opFCVTNU, "fcvtnu");
		SetMnemonic(opMRS, "mrs");    SetMnemonic(opMSR, "msr");

		SetMnemonic(opLDXRB, "ldxrb");  SetMnemonic(opSTXRB, "stxrb");
		SetMnemonic(opLDAXRB, "ldaxrb"); SetMnemonic(opSTLXRB, "stlxrb");
		SetMnemonic(opLDARB, "ldarb");  SetMnemonic(opSTLRB, "stlrb");

		SetMnemonic(opFMOV, "fmov");  SetMnemonic(opFADD, "fadd");
		SetMnemonic(opFSUB, "fsub");  SetMnemonic(opFMUL, "fmul");
		SetMnemonic(opFDIV, "fdiv");  SetMnemonic(opFNMUL, "fnmul");
		SetMnemonic(opFNEG, "fneg");  SetMnemonic(opFABS, "fabs");
		SetMnemonic(opFSQRT, "fsqrt"); SetMnemonic(opFMAX, "fmax");
		SetMnemonic(opFMIN, "fmin");
		SetMnemonic(opFCMP, "fcmp");  SetMnemonic(opFCMPE, "fcmpe");
		SetMnemonic(opFCVT, "fcvt");
		SetMnemonic(opSCVTF, "scvtf"); SetMnemonic(opUCVTF, "ucvtf");
		SetMnemonic(opFCVTZS, "fcvtzs"); SetMnemonic(opFCVTZU, "fcvtzu");
		SetMnemonic(opFCVTMS, "fcvtms"); SetMnemonic(opFCVTMU, "fcvtmu");
		SetMnemonic(opFCSEL, "fcsel");

		(* every mnemonic constant is named: an unnamed slot is a miscounted constant *)
		FOR i := 0 TO NumberMnemonics - 1 DO
			ASSERT(mnemonicNames[i] # "")
		END
	END Init;

BEGIN
	Init
END FoxA64InstructionSet.

System.FreeDownTo FoxA64InstructionSet ~
