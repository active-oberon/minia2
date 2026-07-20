# Active Oberon — Current Language Snapshot

**Snapshot date:** 2026-07-20
**Derived from:** the Fox Oberon compiler — `source/FoxScanner.Mod`,
`FoxParser.Mod`, `FoxGlobal.Mod`, `FoxSemanticChecker.Mod` (upstream snapshot dated
2026-04-16; minia2's copies are byte-identical).
**Relationship to the 2019 report:** this is a compiler-derived, dated inventory of
the language *surface* actually accepted today. Where it differs from
`OberonLanguageReport.pdf` (2019), **the compiler wins** — see `CONFORMANCE.md` for
the annotated diff. No commit hash is pinned (this tree is maintained by
cherry-picking upstream; hashes churn). This is a snapshot, not a normative spec.

> Scope: lexical + syntactic + built-in *surface*. Semantics (type compatibility,
> math-array shape algebra, operator resolution) are not restated here — see the
> report chapters §7, §10, §14 and Appendix A.

---

## 1. Keywords (reserved words)

Recognized case-insensitively (both `MODULE` and `module`), from
`FoxScanner.Mod:InitKeywords`.

```
AWAIT BEGIN BY CASE CELL CELLNET CODE CONST DEFINITION DIV DO ELSE ELSIF END ENUM
EXIT EXTERN FALSE FINALLY FOR IF IGNORE IMAG IMPORT IN IS LOOP MOD MODULE NEW NIL
OBJECT OF OPERATOR OR OUT PORT POINTER PROCEDURE RECORD REPEAT RESULT RETURN SELF
THEN TO TRUE TYPE UNTIL VAR WHILE WITH
ANY ARRAY ADDRESS SIZE ALIAS
```

- **`DEFINITION`** (definition / interface modules) is reserved — **not** in the 2019 report.
- `ANY`, `ADDRESS`, `SIZE`, `ALIAS` double as type / expression keywords.

## 2. Operators & delimiters

From `FoxScanner.Mod:InitKeywords` (`EnterSymbol`).

| Group | Tokens |
|-------|--------|
| Grouping | `(` `)` `[` `]` `{` `}` `\|` |
| Punctuation | `,` `.` `..` `:` `;` `:=` |
| Logical / deref | `&` `~` `^` |
| Relations | `=` `#` `<` `<=` `>` `>=` `IN` `IS` |
| Element-wise relations (math arrays) | `.=` `.#` `.<` `.<=` `.>` `.>=` |
| Additive / multiplicative | `+` `-` `*` `/` `DIV` `MOD` |
| Element-wise / matrix | `.*` `./` `**` `+*` `\` `` ` `` (transpose) |
| Communication (statements) | `!` (send) `?` (receive) `<<` `>>` |
| Communication (relations/tests) | `??` `!!` `<<?` `>>?` |

## 3. Statement forms

From `FoxParser.Mod:Statement*`.

- Assignment `:=`
- Communication `!` `?` `<<` `>>`
- Procedure call
- **Inline `VAR` declaration statement** (`VAR x := e, y: T` mid-block) — *not in the report's Appendix B grammar*
- `IF … THEN … {ELSIF … THEN …} [ELSE …] END`
- `WITH ident : QualIdent DO … {| QualIdent DO …} [ELSE …] END`
- `CASE … OF [|] Case {| Case} [ELSE …] END`
- `WHILE … DO … END`
- `REPEAT … UNTIL …`
- `FOR ident := … TO … [BY …] DO … END`
- `LOOP … END` / `EXIT`
- `RETURN [expr]`
- `AWAIT expr`
- `IGNORE expr`
- `BEGIN [ {flags} ] … END` statement block
- `CODE … END` (inline assembler)

## 4. Type forms

From `FoxParser.Mod:Type` / `ArrayType`.

- `ANY`
- `ARRAY`:
  - open `ARRAY OF T`
  - static `ARRAY n [, m …] OF T`
  - **math array** `ARRAY [ … ] OF T` — dimensions: `[n]` static, `[*]` open, `[?]` tensor, multi-dim via `,`
- `RECORD [ (Base) ] … END`
- `POINTER [flags] TO T`
- `OBJECT [flags] [ (Base) ] … END`
- `PROCEDURE [flags] [ (params) [ : [flags] RetType ] ]`
- `ENUM [ (Base) ] name [= expr] {, …} END`
- `CELL` / `CELLNET` `[flags] [ ( PortList ) ] … END`
- `PORT ( IN | OUT ) [ ( expr ) ]`
- `ADDRESS`, `SIZE` (system types usable as a type)
- a qualified identifier (named type)

Type constructors that accept a leading `{…}` flag list: procedure, object, cell/cellnet, pointer, record, array, port, parameters, and return type.

## 5. Built-in procedures & functions (global scope, no import)

From `FoxGlobal.Mod:SetDefaultDeclarations`.

**Functions:**
```
ABS ASH CAP CHR ENTIER FLOOR(=ENTIER) ENTIERH ORD ORD32 LEN LONG SHORT MAX MIN ODD
LSH ROT ROL ROR SHL SHR INCR SUM DIM CAS FIRST LAST STEP RE IM ADDRESSOF SIZEOF
```

**Proper procedures:**
```
ASSERT COPY DEC INC EXCL INCL NEW DISPOSE HALT GETPROCEDURE TRACE RESHAPE ALL
INCMUL DECMUL WAIT CONNECT RECEIVE SEND DELEGATE
```

Not in the 2019 report: `DISPOSE`, `GETPROCEDURE`, `TRACE`, `WAIT`, `CONNECT`,
`RECEIVE`, `SEND`, `DELEGATE` (and the report's §2.7 list is missing `ORD`).

## 6. `SYSTEM` module (low-level, unsafe)

From `FoxGlobal.Mod` SYSTEM scope. Matches the 2019 report exactly.

```
GET PUT  GET8 GET16 GET32 GET64  PUT8 PUT16 PUT32 PUT64
VAL MOVE REF NEW TYPECODE HALT SIZE ADR MSK BIT
GetStackPointer SetStackPointer GetFramePointer SetFramePointer GetActivity SetActivity
```
Plus the `BYTE` type and the `Time` / `Date` constants.

## 7. Predeclared types

From `FoxGlobal.Mod`.

```
BOOLEAN CHAR
INTEGER LONGINTEGER RANGE INTEGERSET
SIGNED8 SIGNED16 SIGNED32 SIGNED64
UNSIGNED8 UNSIGNED16 UNSIGNED32 UNSIGNED64
FLOAT32 FLOAT64 REAL
COMPLEX32 COMPLEX64 COMPLEX
SET SET8 SET16 SET32 SET64
ADDRESS SIZE ANY OBJECT
```
(`LONGREAL` exists only as a deprecated scanner literal form, not as a predeclared type name.)

## 8. Modifiers / attributes (`{ … }` flags)

The parser accepts any `Identifier [ (expr) | = expr ]` as a flag; the semantic
checker assigns meaning to a fixed vocabulary (`FoxGlobal.Mod:9-67`, checked in
`FoxSemanticChecker.Mod`). Unrecognized flags are rejected (`"unexpected modifier"`).

| Category | Flags |
|----------|-------|
| Calling convention | `WINAPI` `C` `PlatformCC` `INTERRUPT` `PCOFFSET` `NORETURN` `ALIGNSTACK` |
| Memory / tracing | `UNTRACED` `UNTRACKED` `MOVABLE` `ALIGNED(n)` `PLAIN` `DISPOSABLE` `UNSAFE` `UNCHECKED` |
| OO | `ABSTRACT` `FINAL` `OVERRIDE` `DELEGATE` |
| Concurrency (object/body) | `ACTIVE` `EXCLUSIVE` `PRIORITY(n)` `SAFE` `REALTIME` `UNCOOPERATIVE` |
| Cells / hardware | `DataMemorySize(n)` `CodeMemorySize(n)` `ChannelWidth(n)` `ChannelDepth(n)` `Channels` `Vector` `FloatingPoint` `NoMul` `HasNonBlockingIO` `FrequencyDivider` `Engine` `TRM` `TRMS` `Backend(s)` `Runtime(s)` `Fingerprint` |
| Misc | `OPENING` `CLOSING` `OFFSET(n)` `TEST` `REGISTER` `DYNAMIC` |

## 9. Conditional compilation

Line-oriented, driven by `-D` definitions passed to the compiler:

```
#if <expr> then … [#elsif <expr> then …] [#else …] #end
```

---

*Regenerate this snapshot by re-reading `source/Fox{Scanner,Parser,Global}.Mod` and
`FoxSemanticChecker.Mod`; bump the snapshot date above.*
