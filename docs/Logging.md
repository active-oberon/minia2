# Structured application logging

`Logging` is the `std/logging` package, shipped with every SDK target. It creates
typed records independently of their destination. `KernelLog` remains available
for boot and kernel diagnostics; existing callers do not need to migrate.

```oberon
IMPORT Logging, Streams, KernelLog;

VAR writer: Streams.Writer; handler: Logging.StreamHandler; log: Logging.Logger;
    context: ARRAY 1 OF Logging.Attr; fields: ARRAY 4 OF Logging.Attr; res: SIGNED32;
BEGIN
    NEW(writer, KernelLog.Send, 4096);
    handler := Logging.NewTextHandler(writer);
    NEW(log, handler);
    context[0] := Logging.String("component", "http"); log := log.With(context);
    res := log.Info("started"); ASSERT(res = Streams.Ok);
    fields[0] := Logging.String("request_id", "r42"); fields[1] := Logging.Int("status", 200);
    fields[2] := Logging.Float("seconds", 0.125); fields[3] := Logging.Bool("cached", FALSE);
    res := log.Log(Logging.LevelInfo, "handled", fields);
    ASSERT(res = Streams.Ok)
END
```

`Debug`, `Info`, `Warn` and `Error` log a message with the logger's existing
context. `Log` accepts an array of per-record attributes and any numeric level.
The constructors `String`, `Int`, `UInt`, `Bool` and `Float` retain their types;
signed and unsigned 64-bit integers are written directly, without a floating
point conversion. Non-finite floats are the strings `NaN`, `+Inf` and `-Inf`.

Pass declared arrays of `Logging.Attr`, as above. Inline array literals containing
attribute constructor calls currently trap in the compiler's generated code; this
module does not modify the compiler.

`With` creates a new logger, copying its fields and their strings. Changing the
caller's array or strings cannot change that context. Later fields replace
earlier fields with the same key, including per-record overrides. No mutable
request context is stored globally.

`NewTextHandler` writes escaped `key=value` lines; application keys have the
`attrs.` prefix. `NewJSONHandler` writes one JSON object per line:

```json
{"time":"2026-10-12T10:00:00Z","level":"INFO","msg":"handled","attrs":{"component":"http","status":200}}
```

Timestamps are UTC with second resolution, using the existing `Clock` and `Dates` modules.
Application fields live inside `attrs`, so keys such as `time` or `msg` cannot
replace the record's metadata. Strings use the existing JSON escaping rules.

Both handlers default to `LevelInfo`. `handler.SetLevel(Logging.LevelDebug)`
changes filtering for every logger sharing that handler. `Enabled` runs before
record construction, but the language evaluates call arguments first. Guard
expensive field construction with `IF log.Enabled(Logging.LevelDebug) THEN`.

One handler owns one writer and serializes complete records, including flushes.
Share that handler through loggers and `With`; do not use the same writer through
another handler or write to it directly while logging. The destination must not
re-enter its own handler. Independent writers to the same destination need that
destination to coordinate their writes.

Logging is synchronous: a slow destination blocks its caller. Every output method
returns the handler's result code. A stream error remains latched in
`Streams.Writer.res`; recover or replace the destination explicitly. Flushing a
writer is not a filesystem durability guarantee: a file owner still controls
`Files.File.Update`. There is no background queue, rotation or network protocol.

For another destination, derive an object from `Logging.Handler` and implement
`Handle(CONST record: Logging.Record): SIGNED32`. Override `Enabled` when needed.
`Record.time` is a UTC `Dates.DateTime`; `Record.attrs` exposes typed `Attr` records, owned
by that record. Custom handlers are responsible for their own synchronization.

`tests/Logging.Test` exercises both formats, UTC timestamps, exact integer
boundaries, string escaping, long records, immutable context, duplicate keys,
filtering, replaceable handlers, output failures and concurrent active objects.
