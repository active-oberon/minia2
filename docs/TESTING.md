# Testing and coverage: how the work is done here

This is the working brief for whoever carries on the background item — tests and coverage. It is
written for someone starting cold: where the plan and the state live, how to build and run, what a
suite looks like in this tree, the techniques that cost a round of probing each, and where the
defects have been hiding.

The tree is `minia2`, branch `main`. The state of play at the time of writing is at the end.

## Language, and what goes where

- Answer the author in Russian, briefly: the verdict on the first line, then bullets.
- Everything that lands in the repository is English: prose in suite headers, comments in code,
  commit messages.
- Never add a `Co-Authored-By` trailer or a mention of an AI to a commit or a description.

## The gates

- **Never push without permission for that particular push.** Permission for one push does not
  carry to the next.
- **Before asking about a push, give the full report**: what was asked for, what was done — with a
  `path/File.Mod:123` anchor on every claim — what was done beyond it, what was deliberately not
  done, and what is left unverified.
- Do not create tickets. Do not move statuses.

## Where the plan and the state live

- The queue and the journals are in the author's Obsidian vault:
  `/media/andrejjj/DOCS/Obsidian/03_Library/IT-all_topics/Языки_программирования/Active_Oberon/`.
  `Ideas.md` is the plan and the "Ключевые числа" table only; the coverage journals are
  `Ideas-Фон-Покрытие.md`, entries numbered 7.x. Editing rules, which that file states itself:
  python on an exact match, a backup beside it (`Ideas-YYMMDD.txt`, a second one the same day gets
  the suffix b, c, d), numbers only in the key-numbers table, journals of closed items never
  rewritten.
- The state of the work is a directory of notes:
  `~/.claude/projects/-home-andrejjj-Projects-A2-minia2/memory/`, entry point `MEMORY.md`. **Read
  it before starting** — it is files on disk, not something an assistant carries with it. The ones
  that matter here: `coverage-what-is-left.md`, `writing-a-test-suite.md`,
  `running-the-test-suites.md`, `two-defect-families.md`, `task-ob-and-task-test-red-on-head.md`,
  and the `state-*.md` journals.

## Building and running

```sh
task Linux64 && task bundle                       # about a minute; BUILD_DIR defaults to target/
cd target/bundle/tests && A2SDK=$PWD/.. ../ob test Name.Test
# the whole board, against the FULL library:
cd target/bundle/tests && A2SDK=<tree>/target/fullsdk ../ob test -j 8
```

- `ob test` looks for `*.Test` in the current directory and compiles the cases against the SDK's
  own `lib`, so a fix in `source/` is invisible until the bundle is rebuilt.
- Run the board against `target/fullsdk` and not against the payload SDK: the payload has a
  headless core, and every graphical case says "could not import" — about 33 failures that are not
  failures.
- Do not pipe a long run through `tail`: the output is buffered and the run looks like a hang.
  Redirect to a file under `$HOME` and read the file.
- Before a push: the board, `task test` (the two big Oberon suites), and `task ob`.

**`task ob` is red here more often than it is wrong.** Its Windows half runs under wine and fails
roughly one invocation in twelve — `cannot read a MODULE header`, `ob.exe built no binary`, a
different case each time. Measured on an unchanged tree: three runs, two green, one red; and 11 of
12 on a loop over the same binary. Before blaming a change of your own, run `tests/ob-check.sh`
two or three times before and after. The Linux half is deterministic.

## What a suite looks like

A `tests/X.Test` file is `#` comment lines — prose, and the options line the harness reads from
anywhere in that block — then cases introduced by `positive:` (or `negative:`), each holding one
`MODULE Test`.

```
# options --command="System.Free Test XTestShared;System.Load Test"
```

- The shared module is the **first case**, a `positive:` holding `MODULE XTestShared`; every later
  case imports it. Name every helper module in the `System.Free` list or the next case inherits the
  old one.
- The second argument of `ASSERT` is the trap number: `ASSERT(x, 3)` fails as `Trap 5.3`, which is
  how the failing line is found.
- Assert on substrings (`Strings.Pos(what, text) >= 0`), not on whole output: banners get in the
  way.
- The header is prose: what the module is, why it had no test, what was found. When nothing was
  found, say so — "characterisation, not repair" is a result worth writing down for a compressor or
  a parser.

**Prove the case before the fix.** `git stash push -- source/X.Mod`, rebuild, run, write down what
failed, `git stash pop`, rebuild. A defect claimed without that is a defect argued, and the
journals of this tree distinguish the two.

## Techniques that cost a round of probing each

- **Reading the bytes the compiler emitted.** Compile with `--textualObjectFile
  --objectFileExtension=Got` and parse the object file as text. Two properties of that text:
  a run of more than eight zero nibbles is left out and the next segment carries its own offset, so
  segments must be placed at their offsets rather than concatenated (otherwise `MOV RAX, 42` reads
  back as a three-byte instruction); and every byte is written low nibble first, so `B8` appears as
  `8B`. Both are undone in `tests/FoxAssembler.Test`, procedure `Bytes`.
- **Staying independent of the host**: compile for a named platform (`-p=Unix64`, `-p=ARM`) and
  never execute what was compiled. The board also runs on A64, i386 and armhf.
- **A network module**: start the server as an active object inside the case and take the port from
  the system with `TCP.NilPort` — a fixed port loses a race under `-j` and trips over TIME_WAIT.
  The client then talks to 127.0.0.1. Models: `tests/Sockets.Test`, `tests/HTTP.Test`.
- **A stream another implementation made**: embed it as a hexadecimal string and decode it in the
  case. `tests/Compress.Test` does this for zlib, gzip and raw deflate. A round trip cannot tell
  whether both ends are wrong together; a foreign stream can.
- **A case can make its own object file**: write a module with `Files`, run `Compiler.Compile` on
  it through a command context, and the object file lands beside the case's own.
- **`ob test` shows nothing a passing case prints** and runs each case in a temporary directory it
  removes. To *find out* a value rather than assert one, append it to a file at an **absolute** path
  under `$HOME` and read that file afterwards; then turn what was found into `ASSERT`s.
- Language facts that bite: `+` is not defined on strings (build text with `Strings.Append`); a
  string holding a quotation mark is written in the second literal form, `\"…"\`; a VAR parameter of
  a base type will not take a variable of a derived type (assign it to one of the base type first).

## Measuring coverage, and why the number cannot be trusted

The measurement walks `packages/*/*/a2pkg.json`, takes `provides`, and looks for each module name
in `tests/` with comments stripped — `#` lines and `(* … *)`.

**The sign lies in both directions.** It over-counts: a module named in the prose of a header is
not a module under test, which is why comments have to be stripped. And it under-counts:
`tests/FoxAssembler.Test` drives `FoxAMD64Assembler`, `FoxAMD64InstructionSet` and `FoxAssembler`
through `CODE` blocks without ever naming them; `Sockets` is exercised through `TCP`;
`FoxArrayBase` is called by generated code. So **before writing a suite for a hole, follow the
import chain from what already runs** — otherwise the suite is a duplicate. And do not publish the
overall percentage as a fact: two counters with different comment stripping give 242/760 and
248/758 on the same tree.

## Where the defects have been

The catalogue is `memory/two-defect-families.md`. The families that paid best recently:

- **The twin next door does it right** — one procedure of a family does not check what its three
  neighbours check (`PatchStackSize` against the other patchers; the HTTP client writing a header
  field without the colon its own server half writes).
- **A local read before it is assigned** — an error message naming a piece of the stack.
- **The check standing behind the use** — a NIL diagnostic behind a type guard on the same NIL.
- **A reset that does not detach** — `Reset` empties a section but leaves it attached, and the
  generator skips anything attached, so the second pass wrote nothing.
- **A patch in place where an append was meant** — `PutByteAt` restores the program counter it
  saved, so a repeat wrote its copies over the original.
- **Padding without the second MOD** — `size - length MOD size` is a whole extra element when the
  length already fits.
- **A bound taken from the wrong array** — a path copied under `LEN(host)`.
- **A typo in a message somebody compares against** — `"UNKOWN"` against a guard testing
  `"UNKNOWN"`, so the guard never fired.
- **A walk that steps by what a byte claims** — a UTF-8 lead byte promising more than is there
  carried the walk off the end of the array.

## Where it stands, 2026-09-15

The board: **7787 cases, 7758 passed, 0 failed, 29 known-failing**; `Oberon.Compilation` 5450/0,
`Oberon.Execution` 698/0.

- `std` is closed in substance. What the sign still calls uncovered there is `DNS`, which wants a
  resolver, and the Windows API declarations (`User32`, `WSock32`, `Kernel32`), where there is
  nothing to measure.
- Left in `std/compiler`: the block of "ours and unused" — `FoxProgTools`, `FoxProfiler`, `FoxTest`,
  `TestSuite`, `ModuleParser`, `UnixBinary`, `Versioning`, `CompilerInterface`, `FoxA2Interface`,
  `FoxFrontend`. Half of them run on every `ob build` or `ob version`: measure the import chain
  first, then decide which of them a suite would actually tell something new about.
- `lib/` has been started: `http` 2 of 2 (five defects), `compress` closed (no defects).
- Next by the same criterion — small, and no hardware needed: `lib/texts` 2/3, `lib/archive` 1/6,
  `lib/numbers` 8/13, `lib/numerics` 4/10.
- The large ones — `gui` 21/115, `net-clients` 1/42, `ime` 0/14, `media`, `sound` — need a screen,
  a sound device or a network. Those are script checks in the shape of `task display` / `task zoom`,
  not `ob test` cases.

Start by reading `MEMORY.md` and `coverage-what-is-left.md`, pick the next package, show a plan of
three to five lines, and wait for it to be confirmed.
