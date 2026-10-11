# Configuration YAML

`YAML` is the standard `std/encoding` reader for bounded configuration files.
Its tree uses the existing `JSON.Value` hierarchy: `Object`, `Array`, `String`,
`Number`, `Bool` and `Null`. Numbers use `FLOAT64`; integers beyond its exact
precision must be stored as quoted strings when precision matters.

```oberon
MODULE ConfigExample;
IMPORT YAML, JSON;
VAR value: JSON.Value;
    error: ARRAY 256 OF CHAR;
BEGIN
    IF YAML.Load("settings.yaml", value, error) THEN
        ASSERT(value IS JSON.Object)
    END
END ConfigExample.
```

`Load(path, value, error)` reads a file. `Parse(text, value, error)` reads a
NUL-terminated string. `ParseStream(reader, value, error)` reads a `Streams.Reader`.
They return `FALSE`, clear `value` to `NIL`, and fill `error` on failure. Syntax
errors identify the line; file/stream errors also return through `error`.
Consumers still validate their own keys, types, ranges and relationships.

Supported configuration syntax:

- One UTF-8 document, with optional UTF-8 BOM, `---`/`...` marker lines and comments.
- Nested block mappings with string keys, block sequences and compact sequence
  mappings (`- name: value`). Plain mapping keys require whitespace after `:`;
  quoted flow keys also accept JSON-style `"key":value`.
- Flow mappings/sequences on one line, including empty collections and trailing commas.
- Plain strings, single quotes with doubled quote escapes, double quotes with
  `\"`, `\\`, `\/`, escaped space, `\b`, `\f`, `\n`, `\r`, `\t`,
  `\xXX`, `\uXXXX` and `\UXXXXXXXX`. Unicode escapes produce UTF-8.
- Null (`null`/`Null`/`NULL`, `~`, empty mapping values), booleans in the usual
  three case variants, finite decimal numbers with signs/exponents, hexadecimal
  and octal integers. YAML 1.1 words such as `yes` and `on` remain strings.
- Duplicate string keys are errors. Quote a key that would resolve as a typed
  scalar (`"1"`, `"true"`); complex or typed mapping keys are unsupported.

This is a configuration subset, not a complete YAML 1.2 implementation. It rejects
anchors, aliases, tags, directives, multiple documents, block/multiline scalars,
multiline flow collections, indentation tabs, nonfinite numbers, NUL characters
and unsupported escapes. Indentless nested sequences are unsupported. Use an
indented sequence under its mapping key. Unicode surrogate escapes are rejected;
use a full `\U` code point instead. Unsupported syntax is not silently expanded.

Limits: 1 MiB input, 4096 bytes per line, nesting depth 32, and 4096 allocated tree
nodes. The node budget includes collection nodes and placeholders for empty
mapping values. Input and work limits apply before a partial tree is returned.
Raw UTF-8 scalar bytes are preserved; this reader does not validate their encoding.

Seven `{TEST}` procedures beside the implementation cover parsing, malformed
input, scalar/collection behavior, quoted keys, Unicode, files/streams and budgets.
`tests/YAML.Test` invokes the same procedures in the standard suite and SDK bundle.
Run `(cd source && ob test YAML.Mod -v)` or `ob test tests/YAML.Test -v`
against a freshly built SDK. The direct source tests need the source directory
as their working directory.

Syntax reference: [YAML 1.2.2 specification](https://yaml.org/spec/1.2.2/).
