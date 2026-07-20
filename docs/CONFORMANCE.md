# Active Oberon — Spec ⇄ Compiler Conformance

**Analysis date:** 2026-07-20
**Specification:** *ETH Oberon (2019) Language Report* — Felix Friedrich, Florian Negele, 2019-10-31 (`OberonLanguageReport.pdf`, shipped in the upstream `a2oberon/docs/`; not bundled in minia2), marked *"Work in Progress!"*.
**Implementation:** the Fox Oberon compiler — `source/Fox*.Mod` (analyzed from the shared upstream snapshot dated **2026-04-16**; minia2's `FoxScanner/Parser/Global.Mod` are byte-identical, so the analysis applies here directly). No commit hash is cited: the compiler is maintained by cherry-picking from upstream, so hashes are not a stable reference. Re-run the diff against current `source/Fox*.Mod` when in doubt — see *Method*.

## Method

The report's normative artifacts — the keyword/operator lists (§2.7), the built-in
lists (§2.7 + §12), and the EBNF grammar (Appendix B) — were compared against the
compiler's ground truth extracted from source:

- keywords / operators → `FoxScanner.Mod` `InitKeywords` (keywords 1409-1467, symbols 1470-1515);
- statement & type grammar → `FoxParser.Mod` (`Statement*` 996-1272, `Type` 1741-1765, `ArrayType` 1617-1685);
- built-ins & predeclared types → `FoxGlobal.Mod` `SetDefaultDeclarations` (globals 891-951, SYSTEM 820-853, types 815-888);
- modifiers/flags → `FoxGlobal.Mod` 9-67, consumed in `FoxSemanticChecker.Mod` (`CheckModifiers` ~755).

## Verdict

**Conformance is high. The compiler is a strict superset of the report.** There is
**no case** where the report specifies a feature the compiler rejects. Every
divergence is either (A) a defect/omission in the report, or (B) a compiler feature
that post-dates or was never captured by the 2019 report. This matches the report's
self-declared *Work-in-Progress* status: the canonical language lives in the
compiler, and the document is a faithful-but-incomplete, slightly stale snapshot.

---

## A. Report defects (spec is wrong or incomplete; compiler is correct)

| # | Defect | Location | Compiler truth |
|---|--------|----------|----------------|
| A1 | Keyword misspelled **`PORCEDURE`** | §2.7 keyword list | `procedure` — `FoxScanner.Mod:1409-1457` |
| A2 | Operator list omits `:=` `!` `<<` `>>` `??` `!!` `<<?` `>>?` (all used by the Appendix B grammar) | §2.7 delimiter list | all present — `FoxScanner.Mod:1470-1515` (`Becomes`, `ExclamationMark`, `LessLess`, `GreaterGreater`, `Questionmarks`, `ExclamationMarks`, `LessLessQ`, `GreaterGreaterQ`) |
| A3 | Built-in list omits **`ORD`** (and `ORD32`) — a fundamental function | §2.7 built-in reserved words | `ORD`, `ORD32` predeclared — `FoxGlobal.Mod:~908` |
| A4 | `UNSIGNED32` listed twice | §2.7 built-in reserved words | one type `UNSIGNED32` — `FoxGlobal.Mod:869` |
| A5 | `Statement` production omits the inline `VAR` declaration statement that §11.3 *describes* and the compiler accepts | Appendix B vs §11.3 | `FoxParser.Mod:1030` (`Var` branch of `Statement*`) |
| A6 | `Type` production omits the `ANY` type and `ADDRESS`/`SIZE`-as-type, both implemented | Appendix B | `FoxParser.Mod:1746` (`ANY`→`AnyType`), `1756` (`address`/`size` as type) |

## B. Compiler features beyond the report (drift since 2019 / undocumented)

| # | Feature | Compiler location | In report? |
|---|---------|-------------------|-----------|
| B1 | Reserved word **`DEFINITION`** (definition / interface modules) | `FoxScanner.Mod` `InitKeywords` (`definition`) | no |
| B2 | Built-in procedures **`DISPOSE`, `GETPROCEDURE`, `TRACE`** | `FoxGlobal.Mod:931-951` | no |
| B3 | Active-object / cell communication built-ins **`WAIT`, `CONNECT`, `RECEIVE`, `SEND`, `DELEGATE`** | `FoxGlobal.Mod:931-951` | no (only the `!`/`?`/`<<`/`>>` statement forms are documented) |
| B4 | Extensive `{...}` modifier vocabulary — calling conventions (`WINAPI`, `C`, `PlatformCC`), memory/tracing (`UNTRACED`, `UNTRACKED`, `ALIGNED`, `MOVABLE`, `DISPOSABLE`, `PLAIN`, `UNSAFE`), OO (`ABSTRACT`, `FINAL`, `OVERRIDE`, `DELEGATE`), concurrency (`ACTIVE`, `EXCLUSIVE`, `PRIORITY`, `SAFE`, `REALTIME`), and cell/hardware props (`DataMemorySize`, `CodeMemorySize`, `ChannelWidth/Depth`, `Channels`, `Vector`, `FloatingPoint`, `NoMul`, `HasNonBlockingIO`, `Engine`, `TRM`, `TRMS`, `Backend`, `Runtime`, `Fingerprint`) | names `FoxGlobal.Mod:9-67`, checked in `FoxSemanticChecker.Mod` (pointer/record 575-592, procedure 774-794, variable 832-834, cell 1008-1019) | grammar treats `Flag` generically; names not enumerated/documented |

## C. Confirmed matches (the bulk of the language)

All of the following are specified by the report **and** implemented as described:

- **Control statements:** `IF/ELSIF/ELSE`, `CASE`, `WHILE`, `REPEAT/UNTIL`, `FOR ... [BY] ... DO`, `LOOP`, `EXIT`, `RETURN`, `WITH` (multi-branch type guard), `BEGIN` block, `AWAIT`, `CODE`, `IGNORE`, assignment.
- **Communication statements:** `!` `?` `<<` `>>` (`FoxParser.Mod:1015`).
- **Concurrency / hardware types:** `CELL`, `CELLNET`, `PORT` (+ `IN`/`OUT` port direction) — `FoxParser.Mod:1751-1753`.
- **Math arrays:** open `[*]`, tensor `[?]`, static `[expr]`, multi-dimensional; element-wise operators `.*` `./` `**` `+*` `\` `` ` `` (transpose) and dotted relations `.=` `.#` `.<` `.<=` `.>` `.>=` — `FoxScanner.Mod:1470-1515`, `FoxParser.Mod:1617-1685`.
- **`ENUM` enumeration types**, **operator declarations** (`OPERATOR`), **module templates** (`(CONST/TYPE ...)`) and **`IN` contexts**.
- **Expression primaries:** `SELF`, `RESULT`, `NIL`, `IMAG`, `TRUE`/`FALSE`, `NEW`, `ALIAS OF`, `ADDRESS(OF)`, `SIZE(OF)`.
- **`SYSTEM` built-ins — exact match:** `GET PUT PUT8/16/32/64 GET8/16/32/64 VAL MOVE REF NEW TYPECODE HALT SIZE ADR MSK BIT GetStackPointer SetStackPointer GetFramePointer SetFramePointer GetActivity SetActivity`, plus `Time`, `Date`, and the `BYTE` type (`FoxGlobal.Mod:814, 820-853`).
- **Predeclared types:** `BOOLEAN CHAR INTEGER LONGINTEGER RANGE INTEGERSET SET SET8/16/32/64 SIGNED8/16/32/64 UNSIGNED8/16/32/64 FLOAT32/64 COMPLEX32/64 REAL COMPLEX ADDRESS SIZE ANY OBJECT` (`FoxGlobal.Mod:815-888`).
- **Number literals:** `0x…` hex, `0b…` binary, `'` digit separators, `H` suffix, scale factors (§2.2 ⇄ scanner).
- **Conditional compilation:** `#if / #elsif / #else / #end` (§2.9).

---

## Scope & caveats

- This diff is against **this tree's** compiler (`source/Fox*.Mod`, dated 2026-04-16).
  The project is developed by cherry-picking from upstream across many un-merged
  feature branches; other branches — and later cherry-picks — may diverge further
  from both this analysis and the report. Treat this as a dated snapshot, not a
  version-pinned guarantee.
- The comparison is **lexical/syntactic + built-in surface**. It does not verify deep
  *semantic* conformance (type-compatibility rules §14, math-array shape algebra
  Appendix A, operator-resolution). Those chapters are richer and the likeliest place
  for subtle spec↔implementation drift; they warrant a separate pass.
- `LONGREAL` appears as a scanner number-type token but is **not** a predeclared type
  name (the predeclared reals are `REAL`/`FLOAT32`/`FLOAT64`); the report's §2.2 notes
  `LONGREAL` literals are deprecated — consistent.
