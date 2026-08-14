# AWAIT against goroutine, select and context

The plan for this SDK says the language's trump is `AWAIT`, and names a way to check it: write a
program where three things happen at once, write the same program in a language with channels,
and compare. This is that measurement. It did not come out the way the plan expected, which is
the reason to write it down rather than the reason not to.

## What is compared

The same three sources, in both programs:

- somebody types at the terminal;
- mpv, running as a child, says something on its standard output;
- the window changes size.

Each has to reach one loop, in order, without the program spinning, and when the user leaves,
everything has to stop.

Compared is **the plumbing alone**: the queue between the sources and the loop, and the three
readers. Not the catalogue, not the drawing, not the control socket — those are the same work in
both languages and would only pad both sides.

- Active Oberon: `docker/examples/Radio.Mod`, the `Events`, `Keyboard`, `Player` and `Clock`
  objects.
- Go: `radio.go` in this directory, the section marked *the plumbing*.

Both are standard library only and Linux only. The Go program plays a station from the same
catalogue and takes the same keys; it draws nothing, and its whole 249 lines are therefore not
comparable with the 510 of the Active Oberon program, which has frames, genres, a playlist and
an editor in it.

## The numbers

| | lines of plumbing |
|---|---:|
| Go — `event`, `keyboard`, `mpvLines`, `resizes` | **51** |
| Active Oberon — `Events`, `Keyboard`, `Player`, `Clock` | **79** |

Go is shorter here, and pretending otherwise would be worth nothing.

## Where the difference actually is

**Go gets a bounded queue for free.** `make(chan event, 32)` is one line and does what 34 lines
of `Events` do by hand: a ring, two counters, and two waits so that a source which runs ahead is
made to wait rather than losing what it had. That is not a language difference, it is a library
one — A2 has no such queue, and writing one that carries any type is what parametric modules are
for. With such a module in the library, `Events` would be a dozen lines and the two sides would
be about equal.

**Go pays for cancellation, and Active Oberon does not.** Every goroutine here carries a context
and every hand-over is a `select` with a `case <-ctx.Done()` beside it — twelve lines that exist
only so that a reader can be told to stop. Nothing in the Active Oberon side is cancelled: an
object whose source has ended, ends. Killing a station is closing a pipe; the object reading it
returns from its body and is gone. That is a difference in kind rather than in size, and it is
the part that does not show in the table.

**The window's size is Go's, cleanly.** `signal.Notify` turns SIGWINCH into a channel, and the
source is as ordinary as the others. The Active Oberon side looks at the size every four hundred
milliseconds instead, because A2 chains its own signal handlers and a handler in the wrong place
costs more than this source is worth. On that one source Go is simply better.

**What neither table nor prose shows.** The Active Oberon program is one language from the key
press down to the code the terminal driver runs; the Go program stands on a runtime it did not
write, on a kernel in another language. That is the argument for Active Oberon, and it is not
this argument. This measurement is about three sources reaching one loop, and about that, Go is
fine.

## What to do about it

1. A queue that carries any type, in the library, as a parametric module. It is the missing
   piece, it is the language's other trump, and it would make this comparison a fair one rather
   than a comparison of what happens to be written already.
2. Then measure again, honestly, including the twelve lines of cancellation Go pays and the
   nothing that Active Oberon pays.

## Running them

```
ob run examples/Radio.Mod        # the Active Oberon side, full screen
go run radio.go                  # the Go side, a line at a time
```

Both need mpv and `~/.config/radio/stations.tsv`.
