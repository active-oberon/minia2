MODULE Linker;	(* AUTHOR "negelef"; PURPOSE "Object File Linker"; *)

IMPORT Commands, Options, Diagnostics, Files, GenericLinker, ObjectFile, BitSets, Strings, Streams;

TYPE
	ExportName = ARRAY 128 OF CHAR;

	(*
		One page of the image and the fixups inside it, which is the shape a PE relocation table
		has. `wide` is what kind each one is: a fixup of 64 bits needs DIR64 and one of 32 needs
		HIGHLOW, and until 05.09.2026 every one of them was written as HIGHLOW -- measured on a
		real link, 33205 of the fixups are 64 bits wide and 3 are not. It never showed, because an
		image that loads at its preferred base has its relocations read by nobody; it showed the
		moment ASLR was switched on, as an access violation at startup.
	*)
	PatchBlock*= POINTER TO RECORD
		baseAdr: GenericLinker.Address;
		addresses: SIZE;
		address: ARRAY 1024 OF GenericLinker.Address;
		wide: ARRAY 1024 OF BOOLEAN;
		next: PatchBlock;
	END;

	RelocationInfo= OBJECT
	CONST blockSize=4096;
	VAR
		patchBlock: PatchBlock;

		PROCEDURE & Init;
		BEGIN
			patchBlock := NIL;
		END Init;

		PROCEDURE GetPatchBlock(adr: GenericLinker.Address): PatchBlock;
		VAR p, t: PatchBlock;
		BEGIN
			t := patchBlock;
			IF (patchBlock = NIL) OR (patchBlock.baseAdr > adr) THEN
				NEW(p); p.next := patchBlock; patchBlock := p; p.baseAdr := adr;
			ELSIF patchBlock.baseAdr = adr THEN p := patchBlock
			ELSE
				t := patchBlock;
				WHILE (t.next # NIL) & (t.next.baseAdr <= adr) DO
					t := t.next;
				END;
				IF t.baseAdr = adr THEN p := t
				ELSE
					NEW(p); p.next := t.next; t.next := p; p.baseAdr := adr
				END;
			END;
			RETURN p
		END GetPatchBlock;

		PROCEDURE AddReloc(adr: GenericLinker.Address; wide: BOOLEAN);
		VAR aligned: GenericLinker.Address; p: PatchBlock;
		BEGIN
			aligned := adr - adr MOD blockSize;
			p := GetPatchBlock(aligned);
			p.address[p.addresses] := adr (*- aligned*);
			p.wide[p.addresses] := wide;
			INC(p.addresses);
		END AddReloc;

	END RelocationInfo;

	ExportInfo=OBJECT
	VAR
		exports: SIGNED32;
		name: ExportName;
		symbolNames: POINTER TO ARRAY OF ExportName;
		exportNames: POINTER TO ARRAY OF ExportName;
		exportAddresses: POINTER TO ARRAY OF GenericLinker.Address;

		PROCEDURE &Init;
		BEGIN
			exports := 0;
		END Init;

		PROCEDURE Swap(i,j: SIGNED32);
		VAR name: ExportName; adr: GenericLinker.Address;
		BEGIN
			name := exportNames[i]; exportNames[i] := exportNames[j]; exportNames[j] := name;
			name := symbolNames[i]; symbolNames[i] := symbolNames[j]; symbolNames[j] := name;
			adr := exportAddresses[i]; exportAddresses[i] := exportAddresses[j]; exportAddresses[j] := adr;
		END Swap;

		PROCEDURE QuickSort(lo, hi: SIGNED32);
		VAR
			i, j,m: SIGNED32;
		BEGIN
			i := lo; j := hi; m := (lo + hi) DIV 2;

			WHILE i <= j DO
				WHILE exportNames[i] < exportNames[m] DO INC(i) END;
				WHILE exportNames[m] < exportNames[j] DO DEC(j) END;

				IF i <= j THEN
					IF m = i THEN  m := j (* pivot will be moved by Swap *)
					ELSIF m = j THEN  m := i (* pivot will be moved by Swap *)
					END;
					Swap(i,j);
					INC(i); DEC(j)
				END
			END;

			IF lo < j THEN QuickSort( lo, j) END;
			IF i < hi THEN QuickSort(i, hi) END
		END QuickSort;

		PROCEDURE Sort;
		BEGIN
			QuickSort(0, exports-1)
		END Sort;

	END ExportInfo;

	(*
		What a Windows image says about itself in its own `.rsrc` section: the version block a file's
		properties dialog reads, the manifest the loader reads before the first instruction runs, and
		an icon. Until 05.09.2026 our images had no resource directory at all -- which is what
		"Unknown publisher" is made of, and one more line on every heuristic list besides: a program
		with nothing to say about itself is the shape of a file that would rather not be asked.

		Every string here may be empty, and an empty one is left out of the version block rather than
		written blank: a name nobody gave is not the same thing as a name that is the empty string.
	*)
	Resources* = OBJECT
	VAR
		company*, product*, description*, copyright*, comments*: ARRAY 128 OF CHAR;
		originalName*, internalName*: ARRAY 64 OF CHAR;
		version*: ARRAY 32 OF CHAR;	(* "a.b.c.d"; the same four numbers go into VS_FIXEDFILEINFO *)
		icon*: POINTER TO ARRAY OF CHAR;	(* an .ico file whole, as it was read, or NIL for none *)
		iconLength*: SIZE;

		PROCEDURE &InitResources*;
		BEGIN
			company := ""; product := ""; description := ""; copyright := ""; comments := "";
			originalName := ""; internalName := ""; version := "1.0.0.0";
			icon := NIL; iconLength := 0
		END InitResources;

	END Resources;

	Arrangement* = OBJECT (GenericLinker.Arrangement);
	VAR
		displacement: GenericLinker.Address;
		bits: BitSets.BitSet;
		maxUnitSize: ObjectFile.Bits;
		(*	Where the data begins, in bits, or -1 while nothing but code has been placed. Set when
			the first section that is not code arrives -- which is the first one at all, now that
			GenericLinker gives data and constants their own priorities -- and rounded up to a
			section boundary so that a writer can end the executable section there. *)
		dataStart-: ObjectFile.Bits;

		exportInfo: ExportInfo;
		relocInfo: RelocationInfo;
		(*	What goes into `.rsrc`, or NIL for a target that has no such section -- everything that is
			not a Windows PE, EFI images included. *)
		resources*: Resources;

	PROCEDURE & InitArrangement* (displacement: GenericLinker.Address);
	BEGIN
		SELF.displacement := displacement; maxUnitSize := 1; NEW (bits, 0); exportInfo := NIL; NEW(relocInfo);
		resources := NIL;
		dataStart := -1;
	END InitArrangement;

	PROCEDURE Allocate* (CONST section: ObjectFile.Section): GenericLinker.Address;
	VAR address, alignment, boundary: ObjectFile.Bits; i, j: SIZE; name: ObjectFile.SegmentedName;
	BEGIN
		IF section.unit > maxUnitSize THEN maxUnitSize := section.unit END;
		IF section.fixed THEN
			address := ObjectFile.Bits((section.alignment - displacement) * section.unit);
		ELSE
			address := bits.GetSize (); alignment := section.alignment * section.unit;
			IF alignment = 0 THEN alignment := section.unit; END;
			INC (address, (alignment - address MOD alignment) MOD alignment);
			(*	The first byte of data starts a section of its own. A block placed at a fixed
				address is left out of this: it is put where it was told, and the only targets that
				ask for one are the bare metal ones, whose images are copied whole and have no
				section protection to speak of. *)
			IF (dataStart < 0) & ~ObjectFile.IsCode (section.type) THEN
				boundary := ImageSectionAlignment * 8;
				INC (address, (boundary - address MOD boundary) MOD boundary);
				dataStart := address
			END;
		END;
		IF bits.GetSize () < section.bits.GetSize () + address THEN
			bits.Resize (address + section.bits.GetSize ());
		END;
		(*dest pos is for some reason negative*)
		ASSERT(address>=0);
		BitSets.CopyBits (section.bits, 0, bits, address, section.bits.GetSize ());

		IF exportInfo # NIL THEN
			FOR i := 0 TO exportInfo.exports-1 DO
				ObjectFile.StringToSegmentedName(exportInfo.symbolNames[i], name);
				IF name = section.identifier.name THEN
					exportInfo.exportAddresses[i] := address DIV section.unit + displacement;
				END;
				FOR j := 0 TO section.aliases - 1 DO
					IF name = section.alias[j].identifier.name THEN
						exportInfo.exportAddresses[i] := address DIV section.unit + section.alias[j].offset + displacement;
					END;
				END;
			END
		END;

		RETURN address DIV section.unit + displacement;
	END Allocate;

	PROCEDURE SizeInBits*(): ObjectFile.Bits;
	BEGIN RETURN bits.GetSize()
	END SizeInBits;

	PROCEDURE Patch* (pos, value: GenericLinker.Address; offset, bits, unit: ObjectFile.Bits);
	BEGIN SELF.bits.SetBits ((pos - displacement) * unit + offset, bits, value);
	END Patch;

	(*	How wide the field is that this fixup writes into, in bits. A pattern may be written in
		several pieces -- a displacement that sits inside an instruction word is -- so the pieces
		are added up. *)
	PROCEDURE PatternBits(pattern: ObjectFile.Pattern): ObjectFile.Bits;
	VAR bits: ObjectFile.Bits; i: SIZE;
	BEGIN
		bits := 0;
		FOR i := 0 TO pattern.patterns - 1 DO INC(bits, pattern.pattern[i].bits) END;
		RETURN bits
	END PatternBits;

	PROCEDURE CheckReloc*(target: GenericLinker.Address; pattern: ObjectFile.Pattern; CONST patch: ObjectFile.Patch);
	BEGIN
		IF (pattern.mode = ObjectFile.Absolute) & (relocInfo # NIL) THEN
			relocInfo.AddReloc(target + patch.offset, PatternBits(pattern) > 32);
		END;
	END CheckReloc;

END Arrangement;

TYPE FileFormat = PROCEDURE {DELEGATE} (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);

VAR defaults: Options.Defaults;
	processing, finished: GenericLinker.Block;

(*	What a PE section's address is a multiple of. The arrangement needs it as well as the writer:
	code and data can only be told apart by the loader if the boundary between them falls on one
	of these. *)
CONST ImageSectionAlignment* = 1000H;

PROCEDURE Align(this, to: SIZE): SIZE;
BEGIN
	this := this + (-this) MOD to;
	RETURN this;
END Align;

PROCEDURE ReadObjectFile*(CONST moduleName, path, extension: ARRAY OF CHAR; linker: GenericLinker.Linker; moduleList: GenericLinker.HashTableSegmentedName);
VAR fileName: Files.FileName; file: Files.File; reader: Files.Reader; i: SIZE;
offers, requires: ObjectFile.NameList;name: ARRAY 256 OF CHAR; sn: ObjectFile.SegmentedName;
BEGIN
	sn := moduleName;
	IF (moduleList # NIL) & (moduleList.Get(sn) = finished) THEN
		linker.Warning(moduleName, "duplicate");
		RETURN;
	ELSIF (moduleList # NIL) & (moduleList.Get(sn) = processing) THEN
		linker.Error(moduleName, "cyclic import");
		RETURN;
	END;

	IF path # "" THEN Files.JoinPath (path, moduleName, fileName); ELSE COPY(moduleName,fileName); END;
	file := Files.Old (fileName);
	IF file = NIL THEN (* try with extension *)
		Files.JoinExtension (fileName, extension, fileName);
		file := Files.Old (fileName);
	END;
	IF file = NIL THEN (* try without extension *)

	END;
	IF file = NIL THEN linker.Error (fileName, "failed to open file"); RETURN; END;
	Files.OpenReader (reader, file, 0);

	GenericLinker.OffersRequires(reader, offers, requires);
	IF (moduleList # NIL) & (offers # NIL) THEN
		FOR i := 0 TO LEN(offers)-1 DO
			moduleList.Put(offers[i],processing);
		END;
	END;

	IF (moduleList # NIL) & (requires # NIL) THEN
		FOR i := 0 TO LEN(requires)-1 DO
			IF moduleList.Get(requires[i]) = NIL THEN
				name := requires[i];
				(*linker.Information(name, "auto");*)
				ReadObjectFile(name,path,extension, linker, moduleList);
				IF linker.error THEN RETURN END;
			ELSIF moduleList.Get(requires[i]) = processing THEN
				name := requires[i];
				Strings.Append(name, moduleName);
				linker.Error(name, "cyclic import!");
				RETURN;
			END;
		END;
	END;
	linker.Information (moduleName, "processing");

	reader.SetPos(0);
	GenericLinker.Load (reader, linker);
	linker.EnterBlocks();
	IF (moduleList # NIL) & (offers # NIL) THEN
		FOR i := 0 TO LEN(offers)-1 DO
			moduleList.Put(offers[i],finished);
		END;
	END;
	IF reader.res # Files.Ok THEN linker.Error (fileName, "failed to parse"); END;
END ReadObjectFile;

PROCEDURE WriteRelocations( arr: Arrangement; w: Files.Writer );
VAR pb: PatchBlock; i, relocations: SIZE; binsize: Files.Position;
BEGIN
	binsize := w.Pos();
	pb := arr.relocInfo.patchBlock; relocations := 0;
	WHILE pb # NIL DO
		FOR i := 0 TO pb.addresses -1 DO
			(*	This format keeps its relocations as 32 bit numbers, and did so when the list itself
				was 32 bit wide. Widening the list for the PE writer does not widen this. *)
			w.RawInt32( SIGNED32(pb.address[i]) );  INC( relocations );
		END;
		pb := pb.next;
	END;
	(* now patch header (cf  Unix.Glue.Mod)  *)
	w.SetPos( 24 );
	w.RawInt32( binsize(SIGNED32) );
	w.RawInt32( relocations(SIGNED32) );
END WriteRelocations;

(*
	Where the checksum of the PE being written sits, or 0 when the format is not PE. It is the one
	header field that cannot be written while writing: it is a sum over the finished file, the
	bytes after it included. WritePEFile leaves the field zero and says here where it is;
	WriteOutputFile fills it in once the file is on disk.
*)
VAR peChecksumAt, peChecksum: SIZE;

(*
	The PE checksum: a 16 bit one's complement sum over the whole file plus its length, with the
	checksum field itself counted as the zero it was written as. Real linkers compute it and a
	zero there is one more thing that says "this file was assembled by hand".
*)
(*
	The checksum is the one header field that cannot be written in place: it is a sum over the
	whole file, the bytes after it included. It is therefore summed as the file is written -- and
	NOT by reading the file back, which was tried first and does not work: a file A2 has just
	written and registered reads back 561 to 806 bytes short in the same process, so both the sum
	and the length came out wrong, and on files whose tail was not zeros the sum came out wrong
	invisibly. Only these four bytes go back into the finished file.

	And they go back through the file that is already open, not through its name. Reopening it by
	name is what this did until 05.09.2026, and it silently did nothing whenever the name was
	relative: `Files.Old` resolves a relative name along the **search path** (`UnixFiles.Old0`
	walks it and gives up when it runs out), while `Files.New` and `Files.Register` put the file
	where the **process** stands. The two agree only when no search path is set at all -- and every
	real invocation sets one, which is why `Linker.Link --fileName=oberon.exe` shipped a zero
	checksum while `ob build`, which passes an absolute name, did not. Measured both ways on the
	same linker. A zero checksum is one of the packer traits this whole item is about, so it was
	missing exactly where it was least visible.
*)
PROCEDURE PatchChecksum(file: Files.File; at, checksum: SIZE);
VAR writer: Files.Writer;
BEGIN
	Files.OpenWriter(writer, file, at);
	writer.RawInt32(SIGNED32(checksum MOD 100000000H));
	writer.Update
END PatchChecksum;

PROCEDURE WriteOutputFile* (arrangement: Arrangement; CONST fileName: Files.FileName; linker: GenericLinker.Linker; fileFormat: FileFormat);
VAR file: Files.File; writer: Files.Writer; msg: ARRAY 64 OF CHAR; number: ARRAY 32 OF CHAR;
BEGIN
	file := Files.New (fileName);
	Files.OpenWriter (writer, file, 0);
	peChecksumAt := 0;
	fileFormat (linker, arrangement, writer);
	writer.Update; Files.Register (file);
	IF peChecksumAt # 0 THEN PatchChecksum(file, peChecksumAt, peChecksum) END;
	msg := "written ";
	Strings.IntToStr(arrangement.SizeInBits(), number);
	Strings.Append(msg, number);
	Strings.Append(msg, " bits (= ");
	Strings.IntToStr(arrangement.SizeInBits() DIV arrangement.maxUnitSize, number);
	Strings.Append(msg, number);
	Strings.Append(msg, " units).");
	linker.Information (fileName, msg);
END WriteOutputFile;

PROCEDURE WriteBinaryFile (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
VAR i: ObjectFile.Bits;
BEGIN
	FOR i := 0 TO arrangement.bits.GetSize () - 1 BY 8 DO
		writer.Char (CHR (arrangement.bits.GetBits (i, 8)));
	END;
END WriteBinaryFile;

PROCEDURE WriteUnixBinaryFile (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
VAR i: ObjectFile.Bits;
BEGIN
	FOR i := 0 TO arrangement.bits.GetSize () - 1 BY 8 DO
		writer.Char (CHR (arrangement.bits.GetBits (i, 8)));
	END;
	WriteRelocations( arrangement, writer )
END WriteUnixBinaryFile;

PROCEDURE WriteTRMFile* (arrangement: Arrangement; writer: Files.Writer; bitsPerLine, lines: SIZE);
VAR i, j, size, end, nonZeroInLeadingNibble: SIZE;

	PROCEDURE GetBits(pos: SIZE): INTEGER;
	BEGIN
		IF pos >= size THEN RETURN 0
		ELSIF pos+4 > size THEN RETURN arrangement.bits.GetBits(pos,size-pos)
		ELSE RETURN arrangement.bits.GetBits(pos,4)
		END;
	END GetBits;

	PROCEDURE GetFirstNibble(pos: SIZE): INTEGER;
	BEGIN
		RETURN arrangement.bits.GetBits(pos,nonZeroInLeadingNibble);
	END GetFirstNibble;

BEGIN
	(*allow line size not divisible by 4 by padding the line to a multiple of 4 bits with leading zeros*)
	size := arrangement.bits.GetSize();

	end := (size-1) DIV bitsPerLine + 1;

	(*
	D.String("bits per line: ");D.Int(bitsPerLine,0);
	D.String("  number of bits: ");D.Int(size,0);
	D.String("  number of words: ");D.Int(end,0);D.Ln;
	*)

	nonZeroInLeadingNibble:=bitsPerLine MOD 4;
	FOR i := 0 TO end-1 DO
		(*be aware we are writing msb first here*)
		(*padded first nibble*)
		IF nonZeroInLeadingNibble > 0 THEN
			writer.Char(ObjectFile.NibbleToCharacter(GetFirstNibble(i*bitsPerLine+bitsPerLine-nonZeroInLeadingNibble) ) ) ;
		END;
		(*rest of the instruction word*)
		FOR j := bitsPerLine DIV 4 -1 TO 0 BY -1 DO
			writer.Char(ObjectFile.NibbleToCharacter(GetBits(i*bitsPerLine+j*4)));
		END;
		writer.Ln;
	END;
	IF end > 0 THEN (* allow at least one block, if size = 0 *)
		lines := (((end-1) DIV lines)+1)*lines; (* round up to next multiple of lines *)
	END;
	FOR i := end TO lines -1 DO
		FOR j:=1 TO (bitsPerLine-1) DIV 4 + 1 BY 1 DO
			writer.Char('F');
		END;

		writer.Ln;
	END;
END WriteTRMFile;

PROCEDURE WriteTRMCodeFile* (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN
	WriteTRMFile (arrangement, writer, arrangement.maxUnitSize, 1024);
END WriteTRMCodeFile;

PROCEDURE WriteTRMDataFile* (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WriteTRMFile (arrangement, writer, 32,512);
END WriteTRMDataFile;

(*
	The resource section, and what it is for.

	A Windows image keeps what it says about itself in `.rsrc`: the version block that fills the
	properties dialog, the manifest the loader reads before the program starts, and the icon the
	shell draws. Ours had none of the three until 05.09.2026, and a resource directory that is
	simply absent is on the same list as a zero timestamp and a section that is writable and
	executable at once -- not because an engine can prove anything from it, but because a program
	written to be used names itself and a program written to be run once does not.

	The directory is three levels of one node -- by type, then by name or id, then by language --
	and a descriptor at the bottom that points at the bytes with an RVA. The entries of every
	level must be in ascending order of id, which is why they are appended below in the order
	icon, group icon, version, manifest: 3, 14, 16, 24.
*)
CONST
	ResourceIcon = 3; ResourceGroupIcon = 14; ResourceVersion = 16; ResourceManifest = 24;
	ResourceLanguage = 409H;	(* en-US: what rc.exe writes, and what a neutral lookup falls back to *)
	ResourceCodePage = 4B0H;	(* 1200, the code page id that says "these strings are UTF-16" *)

TYPE
	(*	A string of bytes that grows, with the little endian words a PE is spelled in. *)
	Builder* = OBJECT
	VAR
		bytes-: POINTER TO ARRAY OF CHAR;
		length-: SIZE;

		PROCEDURE &InitBuilder*;
		BEGIN NEW(bytes, 1024); length := 0
		END InitBuilder;

		PROCEDURE Byte* (value: SIZE);
		VAR grown: POINTER TO ARRAY OF CHAR; i: SIZE;
		BEGIN
			IF length = LEN(bytes^) THEN
				NEW(grown, 2 * LEN(bytes^));
				FOR i := 0 TO length - 1 DO grown[i] := bytes[i] END;
				bytes := grown
			END;
			bytes[length] := CHR(value MOD 100H); INC(length)
		END Byte;

		PROCEDURE Word* (value: SIZE);
		BEGIN Byte(value MOD 100H); Byte(value DIV 100H MOD 100H)
		END Word;

		PROCEDURE DWord* (value: SIZE);
		BEGIN Word(value MOD 10000H); Word(value DIV 10000H MOD 10000H)
		END DWord;

		PROCEDURE Take* (CONST source: ARRAY OF CHAR; from, count: SIZE);
		VAR i: SIZE;
		BEGIN FOR i := 0 TO count - 1 DO Byte(ORD(source[from + i])) END
		END Take;

		PROCEDURE Ascii* (CONST text: ARRAY OF CHAR);
		VAR i: SIZE;
		BEGIN
			i := 0;
			WHILE (i < LEN(text)) & (text[i] # 0X) DO Byte(ORD(text[i])); INC(i) END
		END Ascii;

		(*	A NUL terminated UTF-16 string, the only kind a version block holds. What comes in is
			UTF-8, because it came off a command line, and a company name is exactly the place a
			letter outside ASCII turns up. *)
		PROCEDURE Utf16* (CONST text: ARRAY OF CHAR);
		VAR i, lead, code, following: SIZE;
		BEGIN
			i := 0;
			WHILE (i < LEN(text)) & (text[i] # 0X) DO
				lead := ORD(text[i]); INC(i);
				IF lead < 80H THEN code := lead; following := 0
				ELSIF lead < 0C0H THEN code := lead; following := 0	(* a stray continuation byte, kept as it stands *)
				ELSIF lead < 0E0H THEN code := lead MOD 20H; following := 1
				ELSIF lead < 0F0H THEN code := lead MOD 10H; following := 2
				ELSE code := lead MOD 8; following := 3
				END;
				WHILE (following > 0) & (i < LEN(text)) & (ORD(text[i]) DIV 40H = 2) DO
					code := code * 40H + ORD(text[i]) MOD 40H; INC(i); DEC(following)
				END;
				IF code >= 10000H THEN
					DEC(code, 10000H);
					Word(0D800H + code DIV 400H); Word(0DC00H + code MOD 400H)
				ELSE
					Word(code)
				END
			END;
			Word(0)
		END Utf16;

		PROCEDURE Align* (to: SIZE);
		BEGIN WHILE length MOD to # 0 DO Byte(0) END
		END Align;

		PROCEDURE PatchWord* (at, value: SIZE);
		BEGIN bytes[at] := CHR(value MOD 100H); bytes[at + 1] := CHR(value DIV 100H MOD 100H)
		END PatchWord;

	END Builder;

(*	"1.2.3.4" as the two double words VS_FIXEDFILEINFO keeps a version in. Anything that is not a
	digit or a dot is skipped, and a version with fewer than four parts leaves the rest zero. *)
PROCEDURE VersionNumbers* (CONST version: ARRAY OF CHAR; VAR high, low: SIZE);
VAR i, part, value: SIZE; number: ARRAY 4 OF SIZE;
BEGIN
	FOR part := 0 TO 3 DO number[part] := 0 END;
	i := 0; part := 0; value := 0;
	WHILE (i < LEN(version)) & (version[i] # 0X) DO
		IF (version[i] >= "0") & (version[i] <= "9") THEN
			value := value * 10 + (ORD(version[i]) - ORD("0"));
			IF value > 0FFFFH THEN value := 0FFFFH END
		ELSIF (version[i] = ".") & (part < 3) THEN
			number[part] := value; INC(part); value := 0
		END;
		INC(i)
	END;
	number[part] := value;
	high := number[0] * 10000H + number[1];
	low := number[2] * 10000H + number[3]
END VersionNumbers;

(*
	VS_VERSIONINFO, the block the properties dialog reads. Its shape is one kind of node inside
	itself four deep: a length, a value length, a type, a NUL terminated UTF-16 key, and then
	either a value or more nodes -- padded to four bytes wherever a node begins and wherever a
	value begins. The length a node declares does NOT count the padding that follows it; the
	reader rounds up to find the next sibling, and that is the one point the two conventions in
	circulation differ on.
*)
PROCEDURE WriteVersionBlock* (builder: Builder; resources: Resources; isDLL: BOOLEAN);
VAR versionAt, stringInfoAt, tableAt, varInfoAt, translationAt, high, low: SIZE;

	PROCEDURE Open(CONST key: ARRAY OF CHAR; valueLength, type: SIZE): SIZE;
	VAR start: SIZE;
	BEGIN
		builder.Align(4); start := builder.length;
		builder.Word(0); builder.Word(valueLength); builder.Word(type);
		builder.Utf16(key); builder.Align(4);
		RETURN start
	END Open;

	PROCEDURE Close(start: SIZE);
	BEGIN builder.PatchWord(start, builder.length - start)
	END Close;

	(*	One line of the properties dialog. A string nobody gave is left out rather than written
		empty, which is the difference between a field that is not filled in and a field whose
		answer is nothing. *)
	PROCEDURE Pair(CONST key, value: ARRAY OF CHAR);
	VAR start, valueAt: SIZE;
	BEGIN
		IF value # "" THEN
			start := Open(key, 0, 1);
			valueAt := builder.length;
			builder.Utf16(value);
			builder.PatchWord(start + 2, (builder.length - valueAt) DIV 2);	(* in characters, the NUL counted *)
			Close(start)
		END
	END Pair;

BEGIN
	VersionNumbers(resources.version, high, low);

	versionAt := Open("VS_VERSION_INFO", 52, 0);
	builder.DWord(SIGNED32(0FEEF04BDH));	(* dwSignature *)
	builder.DWord(00010000H);	(* dwStrucVersion *)
	builder.DWord(high); builder.DWord(low);	(* dwFileVersion *)
	builder.DWord(high); builder.DWord(low);	(* dwProductVersion *)
	builder.DWord(3FH);	(* dwFileFlagsMask: all six flags below are meaningful *)
	builder.DWord(0);	(* dwFileFlags: not a debug, not a prerelease, not a patched build *)
	builder.DWord(00040004H);	(* dwFileOS = VOS_NT_WINDOWS32 *)
	IF isDLL THEN builder.DWord(2) ELSE builder.DWord(1) END;	(* dwFileType = VFT_DLL / VFT_APP *)
	builder.DWord(0);	(* dwFileSubtype *)
	builder.DWord(0); builder.DWord(0);	(* dwFileDate, which nobody writes and nothing reads *)

	stringInfoAt := Open("StringFileInfo", 0, 1);
	tableAt := Open("040904B0", 0, 1);	(* language 0409 and code page 04B0, spelled as the key wants them *)
	Pair("CompanyName", resources.company);
	Pair("FileDescription", resources.description);
	Pair("FileVersion", resources.version);
	Pair("InternalName", resources.internalName);
	Pair("LegalCopyright", resources.copyright);
	Pair("OriginalFilename", resources.originalName);
	Pair("ProductName", resources.product);
	Pair("ProductVersion", resources.version);
	Pair("Comments", resources.comments);
	Close(tableAt);
	Close(stringInfoAt);

	varInfoAt := Open("VarFileInfo", 0, 1);
	translationAt := Open("Translation", 4, 0);
	builder.Word(ResourceLanguage); builder.Word(ResourceCodePage);
	Close(translationAt);
	Close(varInfoAt);

	Close(versionAt)
END WriteVersionBlock;

(*
	The application manifest. Three things are in it and deliberately nothing else:

	-	an identity, so that the image is not one of the nameless;
	-	`asInvoker`, which is what stops Windows guessing from a file name like `setup.exe` that
		the program means to elevate, and putting a prompt in front of a program that does not;
	-	the operating systems the program was written for. Without that list Windows assumes the
		program predates them and applies its compatibility shims, which is a change of behaviour
		nobody asked for.

	What is NOT here, and left out on purpose: `longPathAware` and `activeCodePage`. Both change
	how the runtime's own path and text calls behave, and both may well be right for this system --
	but that is something to measure, not to acquire as a side effect of adding a manifest.
*)
PROCEDURE WriteManifest* (builder: Builder; CONST name: ARRAY OF CHAR; is64: BOOLEAN);
VAR i, characters: SIZE;
BEGIN
	builder.Ascii('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>');
	builder.Ascii('<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">');
	builder.Ascii('<assemblyIdentity type="win32" name="ActiveOberon.');
	(*	The identity is a name the loader parses, so only what may be in one goes into it: a file
		name belongs to the user and can hold anything at all, and a manifest Windows cannot parse
		is a program that does not start. *)
	characters := 0; i := 0;
	WHILE (i < LEN(name)) & (name[i] # 0X) & (characters < 64) DO
		IF ((name[i] >= "A") & (name[i] <= "Z")) OR ((name[i] >= "a") & (name[i] <= "z"))
				OR ((name[i] >= "0") & (name[i] <= "9")) OR (name[i] = ".") OR (name[i] = "-") OR (name[i] = "_") THEN
			builder.Byte(ORD(name[i])); INC(characters)
		END;
		INC(i)
	END;
	IF characters = 0 THEN builder.Ascii("Application") END;
	builder.Ascii('" version="1.0.0.0" processorArchitecture="');
	IF is64 THEN builder.Ascii("amd64") ELSE builder.Ascii("x86") END;
	builder.Ascii('"/>');
	builder.Ascii('<trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>');
	builder.Ascii('<requestedExecutionLevel level="asInvoker" uiAccess="false"/>');
	builder.Ascii('</requestedPrivileges></security></trustInfo>');
	builder.Ascii('<compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>');
	builder.Ascii('<supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}"/>');	(* Vista *)
	builder.Ascii('<supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>');	(* 7 *)
	builder.Ascii('<supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>');	(* 8 *)
	builder.Ascii('<supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>');	(* 8.1 *)
	builder.Ascii('<supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>');	(* 10 and 11 *)
	builder.Ascii('</application></compatibility>');
	builder.Ascii('</assembly>')
END WriteManifest;

(*
	The whole `.rsrc` section, laid out for the address it will have in the image -- which the
	caller knows, because the file this linker writes is the image byte for byte and a file offset
	and an RVA are the same number here.
*)
PROCEDURE BuildResources* (resources: Resources; address: SIZE; isDLL, is64: BOOLEAN): Builder;
CONST MaxEntries = 64; MaxTypes = 8; DataEntrySize = 16; DirectorySize = 16; DirectoryEntrySize = 8;
VAR
	content, payload: Builder;
	entryType, entryId, entryAt, entrySize, nameDirectoryAt: ARRAY MaxEntries OF SIZE;
	typeId, typeEntries, typeFirst, typeDirectoryAt: ARRAY MaxTypes OF SIZE;
	entries, types, images, i, e, t, at, dataAt, payloadAt: SIZE;

	(*	The high half goes through a SIZE of its own on purpose. `ORD(byte) * 100H` is arithmetic on
		the common type of its operands, which for two small ones is sixteen bits wide, so a byte of
		80H or above comes back negative -- the same trap the note in CryptoPoly1305.Mod records, with
		its case in tests/Numbers.Test, and it caught this code too. It matters here rather than being
		merely wrong: every size and offset below is checked against the length of the icon file, and
		a number that went negative on the way is a bounds check that passes.  *)
	PROCEDURE IconWord(at: SIZE): SIZE;
	VAR high: SIZE;
	BEGIN high := ORD(resources.icon[at + 1]); RETURN ORD(resources.icon[at]) + 100H * high
	END IconWord;

	PROCEDURE IconDWord(at: SIZE): SIZE;
	VAR high: SIZE;
	BEGIN high := IconWord(at + 2); RETURN IconWord(at) + 10000H * high
	END IconDWord;

	(*	How many images the icon file holds -- and zero for anything this cannot vouch for. An
		icon comes from a file the user names, so every offset in it is checked against the length
		before a byte of it is copied into an image. *)
	PROCEDURE IconImages(): SIZE;
	VAR count, i, offset, size: SIZE;
	BEGIN
		IF (resources.icon = NIL) OR (resources.iconLength < 6) THEN RETURN 0 END;
		IF (IconWord(0) # 0) OR (IconWord(2) # 1) THEN RETURN 0 END;
		count := IconWord(4);
		IF (count <= 0) OR (count > MaxEntries - 4) OR (6 + 16 * count > resources.iconLength) THEN RETURN 0 END;
		FOR i := 0 TO count - 1 DO
			size := IconDWord(6 + 16 * i + 8); offset := IconDWord(6 + 16 * i + 12);
			IF (size <= 0) OR (offset < 6 + 16 * count) OR (offset + size > resources.iconLength) THEN RETURN 0 END
		END;
		RETURN count
	END IconImages;

	(*	One resource, whose bytes are already in the blob they all share. *)
	PROCEDURE Entry(type, id, size: SIZE);
	BEGIN
		entryType[entries] := type; entryId[entries] := id;
		entryAt[entries] := payload.length - size; entrySize[entries] := size;
		INC(entries)
	END Entry;

BEGIN
	NEW(content); NEW(payload); entries := 0;

	images := IconImages();
	FOR i := 0 TO images - 1 DO
		payload.Align(8);
		at := payload.length;
		payload.Take(resources.icon^, IconDWord(6 + 16 * i + 12), IconDWord(6 + 16 * i + 8));
		Entry(ResourceIcon, i + 1, payload.length - at)
	END;
	IF images > 0 THEN
		(*	The group the shell picks a size out of: the directory the .ico file starts with, with
			each image's offset in the file replaced by the id it was given above. *)
		payload.Align(8);
		at := payload.length;
		payload.Word(0); payload.Word(1); payload.Word(images);
		FOR i := 0 TO images - 1 DO
			payload.Take(resources.icon^, 6 + 16 * i, 8);	(* width, height, colours, reserved, planes, bits *)
			payload.DWord(IconDWord(6 + 16 * i + 8));	(* bytes in the image *)
			payload.Word(i + 1)	(* the RT_ICON id, where the file has an offset *)
		END;
		Entry(ResourceGroupIcon, 1, payload.length - at)
	END;

	payload.Align(8);
	at := payload.length;
	WriteVersionBlock(payload, resources, isDLL);
	Entry(ResourceVersion, 1, payload.length - at);

	(*	A manifest belongs to a program and not to a library: what is in it -- the level the process
		runs at and the versions of Windows it was written for -- is read once, off the image that
		started the process, and a copy of it inside a DLL is read by nobody. A DLL keeps its version
		block, which is the half of this section that does say something about a library. *)
	IF ~isDLL THEN
		payload.Align(8);
		at := payload.length;
		WriteManifest(payload, resources.internalName, is64);
		Entry(ResourceManifest, 1, payload.length - at)
	END;

	(*	The entries were appended in ascending order of type and, within a type, of id, which is
		the order the three levels of the directory have to be in. Grouping them is therefore a
		single pass. *)
	types := 0;
	FOR e := 0 TO entries - 1 DO
		IF (types = 0) OR (typeId[types - 1] # entryType[e]) THEN
			typeId[types] := entryType[e]; typeFirst[types] := e; typeEntries[types] := 0; INC(types)
		END;
		INC(typeEntries[types - 1])
	END;

	at := DirectorySize + DirectoryEntrySize * types;
	FOR t := 0 TO types - 1 DO
		typeDirectoryAt[t] := at; INC(at, DirectorySize + DirectoryEntrySize * typeEntries[t])
	END;
	FOR e := 0 TO entries - 1 DO
		nameDirectoryAt[e] := at; INC(at, DirectorySize + DirectoryEntrySize)	(* one language apiece *)
	END;
	dataAt := at;
	payloadAt := Align(dataAt + DataEntrySize * entries, 8);

	(*	level one: by type *)
	content.DWord(0); content.DWord(0); content.Word(0); content.Word(0);
	content.Word(0); content.Word(types);	(* no named entries; this many by id *)
	FOR t := 0 TO types - 1 DO
		content.DWord(typeId[t]); content.DWord(80000000H + typeDirectoryAt[t])
	END;

	(*	level two: by id, under each type *)
	FOR t := 0 TO types - 1 DO
		content.DWord(0); content.DWord(0); content.Word(0); content.Word(0);
		content.Word(0); content.Word(typeEntries[t]);
		FOR i := 0 TO typeEntries[t] - 1 DO
			e := typeFirst[t] + i;
			content.DWord(entryId[e]); content.DWord(80000000H + nameDirectoryAt[e])
		END
	END;

	(*	level three: by language, one apiece -- and a leaf points at a descriptor rather than at
		another directory, which is what the top bit being clear says *)
	FOR e := 0 TO entries - 1 DO
		content.DWord(0); content.DWord(0); content.Word(0); content.Word(0);
		content.Word(0); content.Word(1);
		content.DWord(ResourceLanguage); content.DWord(dataAt + DataEntrySize * e)
	END;

	(*	the descriptors, which are the one place in the section that speaks in RVAs *)
	FOR e := 0 TO entries - 1 DO
		content.DWord(address + payloadAt + entryAt[e]);
		content.DWord(entrySize[e]);
		content.DWord(0);	(* code page: the strings say their own *)
		content.DWord(0)	(* reserved *)
	END;

	WHILE content.length < payloadAt DO content.Byte(0) END;
	content.Take(payload.bytes^, 0, payload.length);
	RETURN content
END BuildResources;

PROCEDURE WritePEFile (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer; bitmode, subSystem: SIGNED16; isDLL: BOOLEAN);
CONST DOSText = "This program cannot be run in DOS mode.$";
CONST DOSHeaderSize = 64; DOSCodeSize = 14; DOSTextSize = 40; DOSStubSize = ((DOSHeaderSize + DOSCodeSize + DOSTextSize + 15) DIV 16) * 16;
CONST FileAlignment = 200H; SectionAlignment = 1000H; HeaderSize = 24; SectionHeaderSize = 40; DirectoryEntries = 16;
CONST EFISubsystem = 10;			(* the one subsystem here that is not Windows and keeps firmware's expectations *)
CONST WindowsVersion = 6;			(* the OS and subsystem version a Windows binary declares: Vista and up *)
CONST DynamicBase = 40H;			(* IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE -- the image may be relocated: ASLR *)
CONST NXCompatible = 100H;			(* IMAGE_DLLCHARACTERISTICS_NX_COMPAT -- data pages are not executable: DEP *)
CONST TerminalServerAware = 8000H;	(* IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE *)
(*
	What the two sections of an image are allowed to do. Until 04.09.2026 there was one section,
	`.text`, and it was CODE + EXECUTE + READ + WRITE over code, data and the import table alike --
	a section that can be written and executed at once, which is the single loudest thing a file
	can say about itself to a reputation engine, and the shape a packer has by necessity.

	The import address table stays inside `.text` and the section is nevertheless read-only: that
	is where a Microsoft-linked binary keeps it too (in `.rdata`), and the loader unprotects the
	page it writes. Should a loader somewhere refuse, TextCharacteristics + Writable is the whole
	of the way back.
*)
CONST HighLow = 3;	(* IMAGE_REL_BASED_HIGHLOW: the fixup is a 32 bit absolute address *)
CONST DIR64 = 10;	(* IMAGE_REL_BASED_DIR64: it is a 64 bit one *)
CONST Writable = SIGNED32(80000000H);
CONST TextCharacteristics = 60000020H;	(* CODE | MEM_EXECUTE | MEM_READ *)
CONST DataCharacteristics = SIGNED32(0C0000040H);	(* INITIALIZED_DATA | MEM_READ | MEM_WRITE *)
VAR OptionalHeaderSize, CodeSize, AlignedCodeSize, HeadersSize, BaseCodeAddress: SIZE; BaseAddress: GenericLinker.Address; exportInfo: ExportInfo; relocInfo: RelocationInfo;
	TextSize, AlignedTextSize, DataSize, AlignedDataSize: SIZE;
	resources: Resources; resourceContent: Builder;
	ResourceSize, AlignedResourceSize, ResourceAddress: SIZE;
	stamp, stampIndex: SIZE;
	pos: SIZE;
	sum, carry: SIZE; pending: BOOLEAN;	(* the file's checksum, accumulated as it is written *)

	(*	One byte into the 16 bit one's complement sum the checksum field wants. Every byte written
		below goes through here, which is why the sum cannot disagree with the file. *)
	PROCEDURE Take (byte: SIZE);
	BEGIN
		IF pending THEN
			INC(sum, carry + 100H * byte);
			sum := (sum MOD 10000H) + (sum DIV 10000H);
			pending := FALSE
		ELSE
			carry := byte; pending := TRUE
		END
	END Take;

	PROCEDURE Checksum (): SIZE;
	VAR total: SIZE;
	BEGIN
		total := sum;
		IF pending THEN
			INC(total, carry); total := (total MOD 10000H) + (total DIV 10000H)
		END;
		total := (total DIV 10000H) + (total MOD 10000H);
		RETURN (total MOD 10000H) + pos
	END Checksum;

	PROCEDURE Reserve (size: SIZE);
	BEGIN INC(pos, size); WHILE size # 0 DO writer.Char (0X); Take (0); DEC (size); END;
	END Reserve;

	PROCEDURE WriteBYTE (value: SIZE);
	BEGIN writer.Char (CHR (value)); INC(pos); Take (value MOD 100H);
	END WriteBYTE;

	PROCEDURE WriteWORD (value: SIZE);
	BEGIN WriteBYTE (value MOD 100H); WriteBYTE (value DIV 100H);
	END WriteWORD;

	PROCEDURE WriteDWORD (value: SIZE);
	BEGIN WriteWORD (value MOD 10000H); WriteWORD (value DIV 10000H);
	END WriteDWORD;

	(*	The high half used to be a hard zero, which put a ceiling of 4 GB on every address in the
		optional header -- the image base among them. *)
	PROCEDURE WritePTR (value: GenericLinker.Address);
	BEGIN
		WriteDWORD (value MOD 100000000H);
		IF bitmode = 64 THEN WriteDWORD (value DIV 100000000H) END;
	END WritePTR;

	PROCEDURE WriteString(s: ARRAY OF CHAR);
	VAR i: SIZE;
	BEGIN
		i := 0; WHILE s[i] # 0X DO WriteBYTE(ORD(s[i])); INC(i) END
	END WriteString;

	PROCEDURE WriteString0(s: ARRAY OF CHAR);
	BEGIN
		WriteString(s); WriteBYTE(0);
	END WriteString0;

	PROCEDURE AlignTo(alignment: SIZE);
	BEGIN alignment := Align(pos, alignment); Reserve(alignment - pos);
	END AlignTo;

	PROCEDURE ReserveTo(p: SIZE);
	BEGIN ASSERT(p >= pos); Reserve(p-pos);
	END ReserveTo;

	PROCEDURE HasExports(): BOOLEAN;
	BEGIN
		RETURN (exportInfo # NIL) & (exportInfo.exports # 0)
	END HasExports;

	(*	How many section headers this file has. Counted in one place because two things need the
		same number: the header field, and the room the headers take -- which used to be computed
		as one section header whatever the count, and fitted only because the alignment left
		slack. *)
	PROCEDURE HasData(): BOOLEAN;
	BEGIN RETURN DataSize > 0
	END HasData;

	(*	Whether this image has a `.rsrc` at all. It asks the arrangement and not the built section,
		because the number of sections decides how big the headers are, which decides where the
		sections start, which is the address the resources have to be built for. *)
	PROCEDURE HasResources(): BOOLEAN;
	BEGIN RETURN resources # NIL
	END HasResources;

	PROCEDURE Sections(): SIZE;
	VAR count: SIZE;
	BEGIN
		count := 1;
		IF HasData() THEN INC(count) END;
		IF HasRelocs() THEN INC(count) END;
		IF HasExports() THEN INC(count) END;
		IF HasResources() THEN INC(count) END;
		RETURN count
	END Sections;

	PROCEDURE ExportTableSize(): SIZE;
	VAR i,offset: SIZE;
	BEGIN
		IF ~HasExports() THEN RETURN 0 END;

		offset := 40 + Strings.Length(exportInfo.name)+1;
		FOR i := 0 TO exportInfo.exports-1 DO
			INC(offset, Strings.Length(exportInfo.exportNames[i])+1);
			INC(offset, 10);
		END;
		RETURN offset
	END ExportTableSize;

	PROCEDURE AlignedExportTableSize(): SIZE;
	BEGIN
		RETURN Align(ExportTableSize(), SectionAlignment);
	END AlignedExportTableSize;

	PROCEDURE HasRelocs(): BOOLEAN;
	BEGIN
		RETURN (relocInfo # NIL) & (relocInfo.patchBlock # NIL)
	END HasRelocs;

	PROCEDURE RelocTableSize(): SIZE;
	VAR p: PatchBlock; size: SIZE;
	BEGIN
		IF ~HasRelocs() THEN RETURN 0 END;
		size := 0;
		p := relocInfo.patchBlock;
		WHILE p # NIL DO
			INC(size, 8 + p.addresses * 2);
			IF ODD(p.addresses) THEN INC(size, 2) END;
			p := p.next
		END;
		RETURN size
	END RelocTableSize;

	PROCEDURE AlignedRelocTableSize(): SIZE;
	BEGIN RETURN Align(RelocTableSize(), SectionAlignment);
	END AlignedRelocTableSize;

	(*PROCEDURE SectionHeaderOffset(): SIZE;
	BEGIN RETURN DOSStubSize + HeaderSize + OptionalHeaderSize
	END SectionHeaderOffset;*)

	PROCEDURE WriteDOSStub;
	BEGIN
		WriteWORD (5A4DH);	(* e_magic *)
		WriteWORD (DOSStubSize);	(* e_cblp *)
		WriteWORD (1);	(* e_cp *)
		WriteWORD (0);	(* e_crlc *)
		WriteWORD (DOSHeaderSize DIV 16);	(* e_cparhdr *)
		WriteWORD (0);	(* e_minalloc *)
		WriteWORD (0);	(* e_maxalloc *)
		WriteWORD (0);	(* e_ss *)
		WriteWORD (0);	(* e_sp *)
		WriteWORD (0);	(* e_csum *)
		WriteWORD (0);	(* e_ip *)
		WriteWORD (0);	(* e_cs *)
		WriteWORD (DOSHeaderSize);	(* e_lfarlc *)
		WriteWORD (0);	(* e_ovno *)
		Reserve (32);	(* e_res *)
		WriteDWORD (DOSStubSize);	(* e_lfanew *)

		WriteBYTE (00EH); WriteBYTE (01FH); WriteBYTE (0BAH); WriteWORD (DOSCodeSize);
		WriteBYTE (0B4H); WriteBYTE (009H); WriteBYTE (0CDH); WriteBYTE (021H); WriteBYTE (0B8H);
		WriteBYTE (001H); WriteBYTE (04CH); WriteBYTE (0CDH); WriteBYTE (021H); WriteString (DOSText);

		Reserve (DOSStubSize - DOSHeaderSize - DOSCodeSize - DOSTextSize);
	END WriteDOSStub;

	PROCEDURE WriteHeader;
	VAR characteristics: SIGNED32;
	BEGIN
		WriteDWORD (000004550H);	(* Signature *)
		IF bitmode = 64 THEN
			WriteWORD (08664H);	(* Machine *)
		ELSE
			WriteWORD (0014CH);	(* Machine *)
		END;
		WriteWORD (Sections());	(* NumberOfSections *)
		WriteDWORD (stamp);	(* TimeDateStamp -- of the image, not of the clock; see below *)
		WriteDWORD (0);	(* PointerToSymbolTable *)
		WriteDWORD (0);	(* NumberOfSymbols *)
		WriteWORD (OptionalHeaderSize);	(* SizeOfOptionalHeader *)

		characteristics := 222H;
		IF ~HasRelocs() THEN characteristics := characteristics + 1 END;
		IF isDLL THEN characteristics := characteristics + 2000H END;
		IF bitmode#64 THEN characteristics := characteristics + 100H END;

		WriteWORD(characteristics);
	END WriteHeader;

	PROCEDURE WriteOptionalHeader;
	VAR ImageSize: SIZE;
	BEGIN
		ImageSize := Align(BaseCodeAddress+AlignedCodeSize+AlignedExportTableSize()+AlignedRelocTableSize()+AlignedResourceSize, SectionAlignment);

		(* 0 *) IF bitmode = 64 THEN
			WriteWORD (0020BH);	(* Magic *)
		ELSE
			WriteWORD (0010BH);	(* Magic *)
		END;
		(*	Ours, and not zero: a linker version of 0.0 says "no linker wrote this". *)
		(* 2 *) WriteBYTE (1);	(* MajorLinkerVersion *)
		(* 3 *) WriteBYTE (0);	(* MinorLinkerVersion *)
		(* 4 *) WriteDWORD (TextSize);	(* SizeOfCode *)
		(* 8 *) WriteDWORD (DataSize + ResourceSize);	(* SizeOfInitializedData *)
		(* 12 *) WriteDWORD (0);	(* SizeOfUninitializedData *)
		(* 16 *) WriteDWORD (BaseCodeAddress);	(* AddressOfEntryPoint *)
		(* 20 *) WriteDWORD (BaseCodeAddress);	(* BaseOfCode *)
		(* 24 *) IF bitmode # 64 THEN
			WriteDWORD (ImageSize);	(* BaseOfData *)
		END;
		(* 28 / 24 *) WritePTR (arrangement.displacement - BaseCodeAddress);	(* ImageBase *)
		(* 32 *) WriteDWORD (SectionAlignment);	(* SectionAlignment *)
		(* 36 *)WriteDWORD (FileAlignment);	(* FileAlignment *)
		(*	Windows NT 4.0 was what this said until 04.09.2026, and a subsystem version that old is
			on the same heuristic lists as a zero timestamp. 6.0 is Vista, which is older than any
			Windows this runs on. EFI images (subsystem 10) keep what firmware expects. *)
		(* 40 *)WriteWORD (WindowsVersion);	(* MajorOperatingSystemVersion *)
		(* 42 *)WriteWORD (0);	(* MinorOperatingSystemVersion *)
		(* 44 *)WriteWORD (0);	(* MajorImageVersion *)
		(* 46 *)WriteWORD (0);	(* MinorImageVersion *)
		(* 48 *)WriteWORD (WindowsVersion);	(* MajorSubsystemVersion *)
		(* 50 *)WriteWORD (0);	(* MinorSubsystemVersion *)
		(* 52 *)WriteDWORD (0);	(* Win32VersionValue *)
		(* 56 *)WriteDWORD (ImageSize);	(* SizeOfImage *)
		(* 60 *)WriteDWORD (HeadersSize);	(* SizeOfHeaders *)
		(* 64 *)peChecksumAt := pos; WriteDWORD (0);	(* CheckSum, filled in once the file is written *)
		(* 68 *)WriteWORD (subSystem);	(* Subsystem *)
		(*
			DEP, which this said nothing about until 04.09.2026 -- a PE that does not ask for it is
			both a hole of its own and, to a reputation engine, a binary from before it existed.

			ASLR (DYNAMIC_BASE, 40H) is NOT here, and that is measured rather than assumed: with it
			the image is relocated at every start, and a binary built with it set crashes on
			startup with an access violation -- 05.09.2026, `ob.exe version`, the same binary
			running the moment the flag is patched out of the header. So the relocations this
			linker writes do not survive the image being moved. They are HIGHLOW (type 3, see
			WriteSections), which cannot express a delta outside the low 4 GB, and evidently that
			is not their only trouble. ASLR -- and HIGH_ENTROPY_VA after it -- waits for a
			relocation table that is complete and DIR64 wide. Until then this asks for what it can
			honour.
		*)
		(* 70 *)IF subSystem = EFISubsystem THEN
					IF isDLL THEN WriteWORD (DynamicBase) ELSE WriteWORD (0) END
				ELSE
					WriteWORD (NXCompatible + TerminalServerAware)
				END;
		(* 72 *)WritePTR (0100000H);	(* SizeOfStackReserve *)
		(* 76 / 80 *)WritePTR (01000H);	(* SizeOfStackCommit *)
		(* 80 / 88 *)WritePTR (0100000H);	(* SizeOfHeapReserve *)
		(* 84 / 96 *)WritePTR (01000H);	(* SizeOfHeapCommit *)
		(* 88 / 104 *)WriteDWORD (0);			(* LoaderFlags *)
		(* 92 / 108  *)WriteDWORD (DirectoryEntries);	(* NumberOfRvaAndSizes *)

		IF HasExports() THEN
		(* 96 / 112 *) WriteDWORD(BaseCodeAddress + AlignedCodeSize); WriteDWORD(ExportTableSize());  (* location and size of export table *)
		ELSE Reserve(8)
		END;
		(* 104 / 120 *) WriteDWORD (BaseCodeAddress +8) ; WriteDWORD (40); (* location and size of of idata section *)
		IF HasResources() THEN
			WriteDWORD (ResourceAddress); WriteDWORD (ResourceSize);	(* location and size of the resource table *)
		ELSE Reserve(8)
		END;
		Reserve (2 * 8);
		IF HasRelocs() THEN
			WriteDWORD (BaseCodeAddress + AlignedCodeSize+AlignedExportTableSize()) ; WriteDWORD (RelocTableSize()); (* location and size of of reloc section *)
		ELSE Reserve(8)
		END;
		Reserve ((DirectoryEntries - 6) * 8);
	END WriteOptionalHeader;

	PROCEDURE WriteSections;
	VAR ExportNameTableAddress, i, offset: SIZE; p: PatchBlock;
	BEGIN

		(* code section header *)
		(* 0 *) WriteString (".text"); Reserve (3);	(* Name *)
		(* 8 *) WriteDWORD (TextSize);	(* VirtualSize *)
		(* 12 *) WriteDWORD (BaseCodeAddress);	(* VirtualAddress *)
		(* 16 *) WriteDWORD (AlignedTextSize);	(* SizeOfRawData *)
		(* 20 *) WriteDWORD (BaseCodeAddress);	(* PointerToRawData *)
		(* 24 *) WriteDWORD (0);	(* PointerToRelocations *)
		(* 28 *) WriteDWORD (0);	(* PointerToLinenumbers *)
		(* 32 *) WriteWORD (0);	(* NumberOfRelocations *)
		(* 34 *) WriteWORD (0);	(* NumberOfLinenumbers *)
		(* 36 *) WriteDWORD (TextCharacteristics);	(* Characteristics *)

		IF HasData() THEN
			(* data section header -- the same bytes, the other half, and not executable *)
			(* 0 *) WriteString (".data"); Reserve (3);	(* Name *)
			(* 8 *) WriteDWORD (DataSize);	(* VirtualSize *)
			(* 12 *) WriteDWORD (BaseCodeAddress + AlignedTextSize);	(* VirtualAddress *)
			(* 16 *) WriteDWORD (AlignedDataSize);	(* SizeOfRawData *)
			(* 20 *) WriteDWORD (BaseCodeAddress + AlignedTextSize);	(* PointerToRawData *)
			(* 24 *) WriteDWORD (0);	(* PointerToRelocations *)
			(* 28 *) WriteDWORD (0);	(* PointerToLinenumbers *)
			(* 32 *) WriteWORD (0);	(* NumberOfRelocations *)
			(* 34 *) WriteWORD (0);	(* NumberOfLinenumbers *)
			(* 36 *) WriteDWORD (DataCharacteristics);	(* Characteristics *)
		END;

		IF HasExports() THEN
			(* export table header *)
			(* 0 *) WriteString(".edata"); Reserve(2); (* name *)
			(* 8 *) WriteDWORD(ExportTableSize()); (* virtual size *)
			(* 12 *) WriteDWORD(BaseCodeAddress + AlignedCodeSize (* address *));
			(* 16 *) WriteDWORD(AlignedExportTableSize()); (* raw data size *)
			(* 20 *) WriteDWORD(BaseCodeAddress + AlignedCodeSize); (* raw data pointer *)
			(* 24 *) WriteDWORD (0);	(* PointerToRelocations *)
			(* 28 *) WriteDWORD (0);	(* PointerToLinenumbers *)
			(* 32 *) WriteWORD (0);	(* NumberOfRelocations *)
			(* 34 *) WriteWORD (0);	(* NumberOfLinenumbers *)
			(* 36 *) WriteDWORD (SIGNED32 (040000000H));	(* Characteristics *)
		END;

		IF HasRelocs() THEN
			(* reloc table header *)
			(* 0 *) WriteString(".reloc"); Reserve(2); (* name *)
			(* 8 *) WriteDWORD(RelocTableSize()); (* virtual size *)
			(* 12 *) WriteDWORD(BaseCodeAddress + AlignedCodeSize + AlignedExportTableSize() (* address *));
			(* 16 *) WriteDWORD(AlignedRelocTableSize()); (* raw data size *)
			(* 20 *) WriteDWORD(BaseCodeAddress + AlignedCodeSize+ AlignedExportTableSize()); (* raw data pointer *)
			(* 24 *) WriteDWORD (0);	(* PointerToRelocations *)
			(* 28 *) WriteDWORD (0);	(* PointerToLinenumbers *)
			(* 32 *) WriteWORD (0);	(* NumberOfRelocations *)
			(* 34 *) WriteWORD (0);	(* NumberOfLinenumbers *)
			(* 36 *) WriteDWORD (SIGNED32 (040000000H));	(* Characteristics *)
		END;

		IF HasResources() THEN
			(* resource table header *)
			(* 0 *) WriteString(".rsrc"); Reserve(3); (* name *)
			(* 8 *) WriteDWORD(ResourceSize); (* virtual size *)
			(* 12 *) WriteDWORD(ResourceAddress);
			(* 16 *) WriteDWORD(AlignedResourceSize); (* raw data size *)
			(* 20 *) WriteDWORD(ResourceAddress); (* raw data pointer *)
			(* 24 *) WriteDWORD (0);	(* PointerToRelocations *)
			(* 28 *) WriteDWORD (0);	(* PointerToLinenumbers *)
			(* 32 *) WriteWORD (0);	(* NumberOfRelocations *)
			(* 34 *) WriteWORD (0);	(* NumberOfLinenumbers *)
			(* 36 *) WriteDWORD (40000040H);	(* INITIALIZED_DATA | MEM_READ *)
		END;

		ReserveTo(BaseCodeAddress);

		(**** code section *****)
		(*	Written here rather than by WriteBinaryFile so that every byte passes the checksum and
			is counted: the old line counted GetBits DIV 8 while the loop writes one byte per
			started group of eight, which for a size not a multiple of eight is one byte more. *)
		(* BaseCodeAddress *)
		FOR i := 0 TO arrangement.bits.GetSize () - 1 BY 8 DO
			WriteBYTE (arrangement.bits.GetBits (i, 8))
		END;
		(* BaseCodeAddress +CodeSize *)
		Reserve (AlignedCodeSize-CodeSize);
		(* BaseCodeAddress + AlignedCodeSize *)

		IF HasExports() THEN
			(***** export section *****)
			(* BaseCodeAddress + AlignedCodeSize  *)
			(* 0 *) WriteDWORD(0); (* reserved *)
			(* 4 *) WriteDWORD(0); (* time / date *)
			(* 6 *) WriteWORD(0); (* major version *)
			(* 8 *) WriteWORD(0); (* minor version *)
			(* 12 *) WriteDWORD(BaseCodeAddress+AlignedCodeSize + 40 + 10* exportInfo.exports); (* RVA of DLL name *)
			(* 16 *) WriteDWORD(1); (* start ordinal number *)
			(* 20 *) WriteDWORD(exportInfo.exports); (* number of entries in export table *)
			(* 24 *) WriteDWORD(exportInfo.exports); (* number of entries in name pointer table *)
			(* 28 *) WriteDWORD(BaseCodeAddress+AlignedCodeSize + 40 ); (* export address table RVA *)
			(* 32 *) WriteDWORD(BaseCodeAddress+AlignedCodeSize + 40 + 4* exportInfo.exports); (* name pointer RVA *)
			(* 36 *) WriteDWORD(BaseCodeAddress+AlignedCodeSize + 40 + 8* exportInfo.exports); (* ordinal table RVA *)
			(* 40 *)

			(* export address table *)
			FOR i := 0 TO exportInfo.exports-1 DO
				ASSERT(exportInfo.exportAddresses[i] # 0);
				WriteDWORD(exportInfo.exportAddresses[i]-BaseAddress+BaseCodeAddress); (* RVA ! *)
			END;

			(* export name pointer table *)
			(* 40 + 4 * Number exports *)
			ExportNameTableAddress := BaseCodeAddress + AlignedCodeSize + 40 + 10* exportInfo.exports ;
			offset := Strings.Length(exportInfo.name)+1;
			FOR i := 0 TO exportInfo.exports-1 DO
				WriteDWORD(ExportNameTableAddress + offset);
				INC(offset, Strings.Length(exportInfo.exportNames[i])+1);
			END;

			(* export ordinal table *)
			(* 40 + 8* NumberExports  *)
			FOR i := 0 TO exportInfo.exports-1 DO
				WriteWORD(i);
			END;

			(* 40 + 10* NumberExports *)
			(* export name table *)
			WriteString0(exportInfo.name);
			FOR i := 0 TO exportInfo.exports-1 DO
				WriteString0(exportInfo.exportNames[i]); (* 0x terminated *)
			END;
			Reserve(AlignedExportTableSize() - ExportTableSize());
		END;

		IF HasRelocs() THEN
			p := relocInfo.patchBlock;
			WHILE p # NIL DO
				WriteDWORD(p.baseAdr -BaseAddress+BaseCodeAddress) (* RVA  of block *);
				WriteDWORD(8+p.addresses*2+2*(p.addresses MOD 2)); (* number bytes of this block *)
				FOR i := 0 TO p.addresses-1 DO
					(*	The top four bits are the kind of fixup and the low twelve the offset in the
						page. DIR64 (10) for a field of 64 bits, HIGHLOW (3) for one of 32: a
						relocation that names the wrong width writes half an address and leaves the
						other half as it was. *)
					IF p.wide[i] THEN
						WriteWORD(p.address[i] - p.baseAdr + DIR64 * 1000H)
					ELSE
						WriteWORD(p.address[i] - p.baseAdr + HighLow * 1000H)
					END
				END;
				AlignTo(4);
				p := p.next;
			END;
			Reserve(AlignedRelocTableSize() - RelocTableSize());
		END;

		IF HasResources() THEN
			FOR i := 0 TO ResourceSize - 1 DO WriteBYTE(ORD(resourceContent.bytes[i])) END;
			Reserve(AlignedResourceSize - ResourceSize);
		END;
	END WriteSections;

BEGIN
	pos := 0;
	exportInfo := arrangement.exportInfo;
	relocInfo := arrangement.relocInfo;
	(*	EFI images are PE files by inheritance and firmware images by use: nothing there reads a
		version block or a manifest, and what firmware expects is what it already gets. *)
	IF subSystem = EFISubsystem THEN resources := NIL ELSE resources := arrangement.resources END;
	IF HasExports() THEN exportInfo.Sort END;
	BaseAddress := arrangement.displacement;
	OptionalHeaderSize := 96 + DirectoryEntries * 8;
	IF bitmode = 64 THEN INC (OptionalHeaderSize, 16); END;
	CodeSize := arrangement.bits.GetSize () DIV 8;
	(*	The blob is one piece of bytes and stays one piece in the file; what the two section
		headers do is say which half of it may be executed and which may be written. The
		arrangement put the boundary on a section boundary, so both halves are already aligned. *)
	IF (arrangement.dataStart >= 0) & (arrangement.dataStart DIV 8 < CodeSize) THEN
		TextSize := arrangement.dataStart DIV 8
	ELSE
		TextSize := CodeSize
	END;
	DataSize := CodeSize - TextSize;
	AlignedTextSize := Align(TextSize, SectionAlignment);
	AlignedDataSize := Align(DataSize, SectionAlignment);
	AlignedCodeSize := AlignedTextSize + AlignedDataSize;
	HeadersSize :=  Align(DOSStubSize + HeaderSize + OptionalHeaderSize + Sections() * SectionHeaderSize, FileAlignment);
	BaseCodeAddress := Align(HeadersSize, SectionAlignment);

	(*	The resource section is the last one, so its address is known as soon as the four before it
		have their sizes -- and it needs to be known, because the descriptors inside `.rsrc` point at
		its own bytes with an RVA. *)
	ResourceSize := 0; AlignedResourceSize := 0;
	IF HasResources() THEN
		ResourceAddress := BaseCodeAddress + AlignedCodeSize + AlignedExportTableSize() + AlignedRelocTableSize();
		resourceContent := BuildResources(resources, ResourceAddress, isDLL, bitmode = 64);
		ResourceSize := resourceContent.length;
		AlignedResourceSize := Align(ResourceSize, SectionAlignment);
	END;

	(*
		The timestamp is taken from the image and not from the clock, and that is not a nicety:
		this tree checks that the binary `ob build` writes is byte for byte the one the shell
		version writes, and a stamp read off the clock differs between two links of the same input.
		ELF has no such field, so only the PE targets ever noticed -- CI did, on the first push.

		Zero is what it was before 04.09.2026, and zero is on every heuristic list of things a
		packer leaves behind. A value folded out of the image is neither: it is not zero, it does
		not move unless the image does, and a reproducible stamp is what /Brepro writes for the
		same reason.
	*)
	stamp := 0;
	FOR stampIndex := 0 TO arrangement.bits.GetSize () - 1 BY 8 DO
		stamp := (stamp * 33 + arrangement.bits.GetBits (stampIndex, 8)) MOD 100000000H
	END;
	IF stamp = 0 THEN stamp := 1 END;

	sum := 0; carry := 0; pending := FALSE;
	WriteDOSStub; WriteHeader; WriteOptionalHeader; WriteSections;
	peChecksum := Checksum()
END WritePEFile;

PROCEDURE WriteDLL32File (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 32, 2, TRUE);
END WriteDLL32File;

PROCEDURE WriteDLL64File (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 64, 2, TRUE);
END WriteDLL64File;

PROCEDURE WritePE32File (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 32, 2, FALSE);
END WritePE32File;

PROCEDURE WritePE64File (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 64, 2, FALSE);
END WritePE64File;

PROCEDURE WritePE32CUIFile (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 32, 3, FALSE);
END WritePE32CUIFile;

PROCEDURE WritePE64CUIFile (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 64, 3, FALSE);
END WritePE64CUIFile;

PROCEDURE WriteEFI32File (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 32, 10, FALSE);
END WriteEFI32File;

PROCEDURE WriteEFI64File (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
BEGIN WritePEFile (linker, arrangement, writer, 64, 10, FALSE);
END WriteEFI64File;

PROCEDURE WriteELFFile (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
CONST ELFHeaderSize = 52; ProgramHeaderSize = 32; HeadersSize = ELFHeaderSize + ProgramHeaderSize;
CONST BaseAddress = 08048000H; EntryAddress = BaseAddress + HeadersSize;

	PROCEDURE Reserve (size: SIGNED32);
	BEGIN WHILE size # 0 DO writer.Char (0X); DEC (size); END;
	END Reserve;

	PROCEDURE WriteByte (value: SIGNED32);
	BEGIN writer.Char (CHR (value));
	END WriteByte;

	PROCEDURE WriteHalf (value: SIGNED32);
	BEGIN WriteByte (value MOD 100H); WriteByte (value DIV 100H);
	END WriteHalf;

	PROCEDURE WriteWord (value: SIGNED32);
	BEGIN WriteHalf (value MOD 10000H); WriteHalf (value DIV 10000H);
	END WriteWord;

	PROCEDURE WriteELFHeader;
	BEGIN
		WriteByte (7FH);	(* e_ident[EI_MAG0] *)
		WriteByte (ORD('E'));	(* e_ident[EI_MAG1] *)
		WriteByte (ORD('L'));	(* e_ident[EI_MAG2] *)
		WriteByte (ORD('F'));	(* e_ident[EI_MAG3] *)
		WriteByte (1);		(* e_ident[EI_CLASS] *)
		WriteByte (1);		(* e_ident[EI_DATA] *)
		WriteByte (1);		(* e_ident[EI_VERSION] *)
		WriteByte (0);		(* e_ident[EI_PAD] *)
		Reserve (8);		(* e_ident[EI_NIDENT] *)
		WriteHalf (2);		(* e_type *)
		WriteHalf (3);		(* e_machine *)
		WriteWord (1);	(* e_version *)
		WriteWord (EntryAddress);	(* e_entry *)
		WriteWord (ELFHeaderSize);	(* e_phoff *)
		WriteWord (0);	(* e_phoff *)
		WriteWord (0);	(* e_flags *)
		WriteHalf (ELFHeaderSize);	(* e_ehsize *)
		WriteHalf (ProgramHeaderSize);	(* e_phentsize *)
		WriteHalf (1);		(* e_phnum *)
		WriteHalf (0);		(* e_shentsize *)
		WriteHalf (0);		(* e_shnum *)
		WriteHalf (0);		(* e_shstrndx *)
	END WriteELFHeader;

	PROCEDURE WriteProgramHeader;
	VAR FileSize: SIGNED32;
	BEGIN
		FileSize := (HeadersSize + arrangement.bits.GetSize () DIV 8)(SIGNED32);

		WriteWord (1);		(* p_type *)
		WriteWord (0);		(* p_offset *)
		WriteWord (BaseAddress);	(* p_vaddr *)
		WriteWord (0);		(* p_paddr *)
		WriteWord (FileSize);	(* p_filesz *)
		WriteWord (FileSize);	(* p_memsz *)
		WriteWord (7);		(* p_flags *)
		WriteWord (1000H);	(* p_align *)
	END WriteProgramHeader;

BEGIN
	ASSERT (arrangement.displacement = BaseAddress);
	WriteELFHeader;
	WriteProgramHeader;
	WriteBinaryFile (linker, arrangement, writer);
END WriteELFFile;

PROCEDURE WriteMachOFile (linker: GenericLinker.Linker; arrangement: Arrangement; writer: Files.Writer);
CONST SegmentName = "__TEXT"; SectionName = "__text";
CONST MachHeaderSize = 28; LoadCommandSize = 124; ThreadCommandSize = 80;
CONST CommandsSize = LoadCommandSize + ThreadCommandSize; Start = MachHeaderSize + CommandsSize;
CONST BaseAddress = 000010E8H;

	PROCEDURE Write (value: SIGNED32);
	BEGIN writer.Char (CHR (value)); writer.Char (CHR (value DIV 100H)); writer.Char (CHR (value DIV 10000H)); writer.Char (CHR (value DIV 1000000H));
	END Write;

	PROCEDURE WriteName (CONST name: ARRAY OF CHAR);
	VAR i: SIGNED16;
	BEGIN i := 0; WHILE name[i] # 0X DO writer.Char (name[i]); INC (i); END;
		WHILE i # 16 DO writer.Char (0X); INC (i); END;
	END WriteName;

	PROCEDURE WriteMachHeader;
	BEGIN
		Write (SIGNED32 (0FEEDFACEH));	(* magic *)
		Write (7);	(* cputype *)
		Write (3);	(* cpusubtype *)
		Write (2);	(* filetype *)
		Write (2);	(* ncmds *)
		Write (CommandsSize);	(* sizeofcmds *)
		Write (0);	(* flags *)
	END WriteMachHeader;

	PROCEDURE WriteLoadCommand;
	VAR FileSize: SIGNED32;
	BEGIN
		FileSize := (MachHeaderSize + CommandsSize + arrangement.bits.GetSize () DIV 8)(SIGNED32);

		Write (1);	(* cmd *)
		Write (LoadCommandSize);	(* cmdsize *)
		WriteName (SegmentName);	(* segname *)
		Write (BaseAddress - Start);	(* vmaddr *)
		Write (FileSize);	(* vmsize *)
		Write (0);	(* fileoff *)
		Write (FileSize);	(* filesize *)
		Write (7);	(* maxprot *)
		Write (7);	(* initprot *)
		Write (1);	(* nsects *)
		Write (0);	(* flags *)

		WriteName (SectionName);	(* sectname *)
		WriteName (SegmentName);	(* segname *)
		Write (BaseAddress);	(* addr *)
		Write ((arrangement.bits.GetSize () DIV 8)(SIGNED32));	(* size *)
		Write (Start);	(* offset *)
		Write (2);	(* align *)
		Write (0);	(* reloff *)
		Write (0);	(* nreloc *)
		Write (0);	(* flags *)
		Write (0);	(* reserved1 *)
		Write (0);	(* reserved2 *)
	END WriteLoadCommand;

	PROCEDURE WriteThreadCommand;
	BEGIN
		Write (5);	(* cmd *)
		Write (ThreadCommandSize);	(* cmdsize *)
		Write (1);	(* flavor *)
		Write (16);	(* count *)

		Write (0);	(* eax *)
		Write (0);	(* ebx *)
		Write (0);	(* ecx *)
		Write (0);	(* edx *)
		Write (0);	(* edi *)
		Write (0);	(* esi *)
		Write (0);	(* ebp *)
		Write (0);	(* esp *)
		Write (0);	(* ss *)
		Write (0);	(* eflags *)
		Write (BaseAddress);	(* eip *)
		Write (0);	(* cs *)
		Write (0);	(* ds *)
		Write (0);	(* es *)
		Write (0);	(* fs *)
		Write (0);	(* gs *)
	END WriteThreadCommand;

BEGIN
	ASSERT (arrangement.displacement = BaseAddress);
	WriteMachHeader;
	WriteLoadCommand;
	WriteThreadCommand;
	WriteBinaryFile (linker, arrangement, writer);
END WriteMachOFile;

PROCEDURE GetFileFormat (options: Options.Options; CONST name: Options.Name; default: FileFormat): FileFormat;
VAR format: ARRAY 10 OF CHAR;
BEGIN
	IF ~options.GetString (name, format) THEN RETURN default;
	ELSIF format = "TRMCode" THEN RETURN WriteTRMCodeFile;
	ELSIF format = "TRMData" THEN RETURN WriteTRMDataFile;
	ELSIF format = "PE32" THEN RETURN WritePE32File;
	ELSIF format = "PE64" THEN RETURN WritePE64File;
	ELSIF format = "PE32CUI" THEN RETURN WritePE32CUIFile;
	ELSIF format = "PE64CUI" THEN RETURN WritePE64CUIFile;
	ELSIF format = "EFI32" THEN RETURN WriteEFI32File;
	ELSIF format = "EFI64" THEN RETURN WriteEFI64File;
	ELSIF format = "ELF" THEN RETURN WriteELFFile;
	ELSIF format = "MACHO" THEN RETURN WriteMachOFile;
	ELSIF format = "DLL32" THEN RETURN WriteDLL32File;
	ELSIF format = "DLL64" THEN RETURN WriteDLL64File;
	ELSIF format = "UnixRaw" THEN RETURN WriteUnixBinaryFile;
	ELSE RETURN default; END;
END GetFileFormat;

PROCEDURE ParseExports(CONST names: ARRAY OF CHAR): ExportInfo;
VAR number: SIGNED32; info: ExportInfo; pos: SIGNED32; name: ExportName;

	PROCEDURE SkipWhitespace;
	BEGIN WHILE (names[pos] # 0X) & (names[pos] <= " ") DO INC(pos) END;
	END SkipWhitespace;

	PROCEDURE ReadName(VAR name: ARRAY OF CHAR): BOOLEAN;
	VAR i: SIGNED32;
	BEGIN
		i := 0;
		WHILE (names[pos] # 0X) & (names[pos] > " ") & (names[pos] # ",") & (names[pos] # "=") DO name[i] := names[pos]; INC(i); INC(pos) END;
		name[i] := 0X;
		RETURN i > 0;
	END ReadName;

	PROCEDURE ParseEntry(VAR symbolName, exportName: ARRAY OF CHAR): BOOLEAN;
	BEGIN
		SkipWhitespace;
		IF ReadName(symbolName) THEN
			SkipWhitespace;
			IF names[pos] = "=" THEN
				INC(pos); SkipWhitespace;
				IF ~ReadName(exportName) THEN RETURN FALSE END;
				SkipWhitespace;
			ELSE COPY(symbolName, exportName);
			END;
			IF names[pos] = "," THEN INC(pos); SkipWhitespace END;
			RETURN TRUE
		ELSE RETURN FALSE
		END;
	END ParseEntry;

BEGIN
	pos := 0; number := 0;
	WHILE ParseEntry(name, name) DO INC(number) END;
	IF (names[pos] # 0X) OR (number = 0)  THEN RETURN NIL END;

	NEW(info);
	NEW(info.symbolNames, number);
	NEW(info.exportNames, number);
	NEW(info.exportAddresses, number);
	info.exports := number;

	number := 0; pos := 0;
	WHILE (names[pos] # 0X) & ParseEntry(info.symbolNames[number], info.exportNames[number]) DO
		INC(number)
	END;
	RETURN info
END ParseExports;

PROCEDURE CheckExports(info: ExportInfo; error: Streams.Writer): BOOLEAN;
VAR success: BOOLEAN; i: SIGNED32;
BEGIN
	IF info = NIL THEN RETURN TRUE END;
	success := TRUE;
	FOR i := 0 TO info.exports-1 DO
		IF info.exportAddresses[i] = 0 THEN
			error.String("Export symbol not found: "); error.String(info.symbolNames[i]); error.String(" (= ");
			error.String(info.exportNames[i]); error.String(")"); error.Ln;
			success := FALSE;
		END;
	END;
	RETURN success
END CheckExports;

(*	The last component of a path, whichever separator it was written with. Files.SplitPath knows
	only the separator of the machine it runs on, and this linker cross links: a Windows image is
	regularly written from Linux, and its file name arrives with the other slash. *)
PROCEDURE Basename(CONST fileName: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, start, j: SIZE;
BEGIN
	i := 0; start := 0;
	WHILE (i < LEN(fileName)) & (fileName[i] # 0X) DO
		IF (fileName[i] = "/") OR (fileName[i] = 5CX) OR (fileName[i] = ":") THEN start := i + 1 END;
		INC(i)
	END;
	j := 0;
	WHILE (start < LEN(fileName)) & (fileName[start] # 0X) & (j < LEN(name) - 1) DO
		name[j] := fileName[start]; INC(j); INC(start)
	END;
	name[j] := 0X
END Basename;

PROCEDURE ReadIcon(CONST fileName: ARRAY OF CHAR; resources: Resources): BOOLEAN;
VAR file: Files.File; reader: Files.Reader; length, read: SIZE;
BEGIN
	file := Files.Old(fileName);
	IF file = NIL THEN RETURN FALSE END;
	length := SIZE(file.Length());
	IF length <= 6 THEN RETURN FALSE END;
	NEW(resources.icon, length);
	Files.OpenReader(reader, file, 0);
	reader.Bytes(resources.icon^, 0, length, read);
	resources.iconLength := read;
	RETURN read = length
END ReadIcon;

(*
	What the image will say about itself: from the options where they were given, and otherwise
	from the one thing the linker knows without being told -- the name of the file it is writing.

	The company and the copyright have no default and are left out when nobody names them. Every
	program this links is somebody else's, and a linker that writes a company name into a stranger's
	binary has made something up.
*)
PROCEDURE NewResources(options: Options.Options; CONST fileName: Files.FileName; error: Streams.Writer): Resources;
VAR resources: Resources; base, extension: Files.FileName; iconName: Files.FileName;
BEGIN
	NEW(resources);
	Basename(fileName, resources.originalName);
	Files.SplitExtension(resources.originalName, base, extension);
	COPY(base, resources.internalName);
	IF ~options.GetString("description", resources.description) THEN COPY(base, resources.description) END;
	IF ~options.GetString("product", resources.product) THEN resources.product := "Active Oberon" END;
	IF ~options.GetString("version", resources.version) THEN resources.version := "1.0.0.0" END;
	IF ~options.GetString("company", resources.company) THEN resources.company := "" END;
	IF ~options.GetString("copyright", resources.copyright) THEN resources.copyright := "" END;
	resources.comments := "Built with the Active Oberon compiler";
	IF options.GetString("icon", iconName) & ~ReadIcon(iconName, resources) THEN
		error.String("Cannot read the icon file: "); error.String(iconName); error.Ln;
		RETURN NIL
	END;
	RETURN resources
END NewResources;

PROCEDURE Link* (context: Commands.Context);
VAR options: Options.Options;
	silent, useAll, strict: BOOLEAN;
	codeFileFormat, dataFileFormat: FileFormat;
	codeDisplacement, dataDisplacement: GenericLinker.Address;
	displacement: SIGNED64;
	path, extension, codeFileName, dataFileName, moduleName, logFileName, tempName: Files.FileName;
	diagnostics: Diagnostics.StreamDiagnostics; code, data: Arrangement; linker: GenericLinker.Linker;
	linkRoot: ARRAY 256 OF CHAR; logFile: Files.File; log: Files.Writer;
	use: SET;
	exportString: ARRAY 1024*2 OF CHAR;
	parsed: BOOLEAN;
	position: Streams.Position;
	name: ARRAY 32 OF CHAR;
	reader: Streams.Reader;
	moduleList: GenericLinker.HashTableSegmentedName;
	segmentedName: ObjectFile.SegmentedName;
BEGIN
	NEW (options);
	options.Add('p',"platform", Options.String);
	options.Add (0X, "silent", Options.Flag);
	options.Add ('a', "useAll", Options.Flag);
	options.Add ('s', "strict", Options.Flag);
	options.Add (0X, "path", Options.String); options.Add (0X, "extension", Options.String);
	options.Add (0X, "fileName", Options.String); options.Add (0X, "dataFileName", Options.String);
	options.Add (0X, "displacement", Options.Integer); options.Add (0X, "dataDisplacement", Options.Integer);
	options.Add (0X, "fileFormat", Options.String); options.Add (0X, "dataFileFormat", Options.String);
	options.Add (0X, "logFileName", Options.String);
	options.Add(0X,"linkRoot", Options.String);
	options.Add(0X,"exports", Options.String);
	(*	What the Windows image says about itself in its own `.rsrc`. Every one of them has a default
		that is either true or absent, so an image gets a version block whether or not anyone asked. *)
	options.Add(0X,"company", Options.String);
	options.Add(0X,"product", Options.String);
	options.Add(0X,"description", Options.String);
	options.Add(0X,"copyright", Options.String);
	options.Add(0X,"version", Options.String);
	options.Add(0X,"icon", Options.String);
	options.Add(0X,"noResources", Options.Flag);

	position := context.arg.Pos();
	parsed := options.ParseStaged(context.arg, context.error);
	IF options.GetString("platform", name) THEN
		reader := defaults.Get(name);
		IF reader = NIL THEN
			context.error.String("Unknown platform"); context.error.Ln;
			context.result := Commands.CommandError;
			RETURN;
		ELSE
			parsed := options.ParseStaged(reader, context.error) & parsed;
			context.arg.SetPos(position);
			context.arg.SetPos(position);
			parsed := options.Parse(context.arg, context.error) & parsed; (* reparse overwrites *)
		END;
	END;

	IF ~parsed THEN context.result := Commands.CommandParseError; RETURN; END;
	silent := options.GetFlag ("silent");
	useAll := options.GetFlag ("useAll");
	strict := options.GetFlag ("strict");
	IF ~options.GetString ("path", path) THEN path := ""; END;
	IF ~options.GetString ("extension", extension) THEN extension := ObjectFile.DefaultExtension; END;
	IF ~options.GetString ("fileName", codeFileName) THEN codeFileName := "linker.bin"; END;
	IF ~options.GetString ("dataFileName", dataFileName) THEN dataFileName := codeFileName; END;
	IF ~options.GetString ("logFileName", logFileName) THEN
		COPY(codeFileName, logFileName); Files.SplitExtension(logFileName,logFileName,tempName); Files.JoinExtension(logFileName,"log",logFileName);
	END;
	(*	Read as 64 bits: an image base of 140000000H, which is where a 64 bit Windows image
		conventionally sits, does not fit in the 32 bit reader that used to be here.

		And the second line used to read into `codeDisplacement`: giving `--dataDisplacement` moved
		the code and left the data displacement with whatever was on the stack. *)
	IF options.GetInteger64 ("displacement", displacement) THEN codeDisplacement := displacement ELSE codeDisplacement := 0 END;
	IF options.GetInteger64 ("dataDisplacement", displacement) THEN dataDisplacement := displacement ELSE dataDisplacement := codeDisplacement END;
	codeFileFormat := GetFileFormat (options, "fileFormat", WriteBinaryFile);
	dataFileFormat := GetFileFormat (options, "dataFileFormat", codeFileFormat);

	NEW (code, codeDisplacement);
	IF ~options.GetFlag("noResources") THEN
		code.resources := NewResources(options, codeFileName, context.error);
		IF code.resources = NIL THEN context.result := Commands.CommandError; RETURN END
	END;
	IF options.GetString("exports", exportString) THEN
		code.exportInfo := ParseExports(exportString);
		IF code.exportInfo = NIL THEN
			context.error.String("Syntax error in export list or empty export list."); context.error.Ln;
			context.result := Commands.CommandError;
			RETURN;
		ELSE
			COPY(codeFileName, code.exportInfo.name);
		END;
	END;
	IF codeFileName # dataFileName THEN NEW (data, dataDisplacement); ELSE data := code; END;
	NEW (diagnostics, context.error);
	logFile := Files.New(logFileName);
	IF logFile # NIL THEN NEW(log, logFile,0) ELSE log := NIL END;
	IF useAll THEN use := GenericLinker.UseAll ELSE use := GenericLinker.UseInitCode END;
	NEW (linker, diagnostics, log, use, code, data);

	IF options.GetString("linkRoot",linkRoot) THEN linker.SetLinkRoot(linkRoot) END;

	NEW(moduleList,32);
	segmentedName := "SYSTEM";
	moduleList.Put(segmentedName, finished);
	segmentedName := "system";
	moduleList.Put(segmentedName, finished);

	WHILE ~linker.error & context.arg.GetString (moduleName) DO
		ReadObjectFile (moduleName, path, extension, linker, moduleList);
		IF strict & ~linker.error THEN linker.Resolve END;
	END;
	(* do linking after having read in all blocks to account for potential constraints *)
	IF ~linker.error THEN linker.Link; END;

	IF ~linker.error & CheckExports(code.exportInfo, context.error) THEN
		IF (code.displacement # 0) & (linker.log # NIL) THEN linker.log.String("code displacement 0"); linker.log.Hex(code.displacement,-8); linker.log.String("H"); linker.log.Ln END;
		WriteOutputFile (code, codeFileName, linker, codeFileFormat);
		IF data # code THEN
			IF (data.displacement # 0) & (linker.log # NIL) THEN linker.log.String("data displacement 0"); linker.log.Hex(data.displacement,-8); linker.log.String("H"); linker.log.Ln END;
			WriteOutputFile (data, dataFileName, linker, dataFileFormat);
		END;
		IF ~silent THEN
			context.out.String("Link successful. Written files: ");
			context.out.String(codeFileName);
			IF data # code THEN context.out.String(", "); context.out.String(dataFileName) END;
			IF logFile # NIL THEN context.out.String(", "); context.out.String(logFileName); END;

			context.out.Ln
		END;
		IF log # NIL THEN
			log.Update; Files.Register(logFile);
		END;
	ELSE
		context.result := Commands.CommandError;
	END;
END Link;

PROCEDURE ShowDefaults*(context: Commands.Context);
BEGIN
	defaults.Show(context.out);
END ShowDefaults;

BEGIN
	NEW(processing);
	NEW(finished);
	NEW(defaults);
	defaults.Add("Bios32","--fileName=kernel.img --extension=.Gof --displacement=0100000H");
	defaults.Add("Bios64","--fileName=kernel.img --extension=.Goff --displacement=0100000H");
	defaults.Add("Win32CUI","--fileFormat=PE32CUI --fileName=oberon.exe --extension=GofW --displacement=401000H");
	defaults.Add("Win64CUI","--fileFormat=PE64CUI --fileName=oberon.exe --extension=GofWw --displacement=401000H");
	defaults.Add("Linux32","--fileFormat=Raw --fileName=oberon --extension=.GofU --displacement=08048000H");
	defaults.Add("Linux64","--fileFormat=Raw --fileName=oberon --extension=.GofUu --displacement=08048000H");
	defaults.Add("LinuxARM","--fileFormat=Raw --fileName=oberon --extension=.GofA --displacement=010000H");	
	(* AArch64: the displacement is a whole 64 kilobyte page, because a kernel built with a page that
		large only maps a segment whose address and file offset agree modulo the page size *)
	defaults.Add("LinuxA64","--fileFormat=Raw --fileName=oberon --extension=.GofU8 --displacement=0400000H");
	defaults.Add("RPI","--fileName=kernel.img --extension=.Goa --displacement=8000H -sa ");
	defaults.Add("Solaris32", "--fileFormat=UnixRaw --fileName=oberon.bin --extension=.GofU --displacement=0" );
	defaults.Add("Solaris64", "--fileFormat=UnixRaw --fileName=oberon.bin --extension=.GofUu --displacement=0" );
	defaults.Add("Darwin32",   "--fileFormat=UnixRaw --fileName=oberon.bin --extension=.GofU --displacement=0" );
	defaults.Add("Darwin64",   "--fileFormat=UnixRaw --fileName=oberon.bin --extension=.GofUu --displacement=0" );
END Linker.

Linker.Link --fileName=test.exe --fileFormat=PE32 --displacement=401000H Test ~
Linker.Link --fileName=a.out --fileFormat=ELF --displacement=08048000H Test ~
Linker.Link --fileName=a.out --fileFormat=MACHO --displacement=000010E8H Test ~

System.Free Linker ~

