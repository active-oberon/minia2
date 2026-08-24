# AWAIT against goroutine, select and context

The plan for this SDK says the language's trump is `AWAIT`, and names a way to check it: write a
program where three things happen at once, write the same program in a language with channels,
and compare. This is that measurement. It was made three times: the first answer said Go wins by
twenty-eight lines, the second was worse still, and the third came out even -- and what changed
between them was not the argument but what was in the library. All three are below, because the
wrong answers are the useful part.

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

- Active Oberon: `examples/Radio.Mod` -- the `Arrival` record and the `Keyboard`, `Player`
  and `Clock` objects -- and `source/Channels.Mod`, which is counted separately because it is
  library and is written once.
- Go: `radio.go` in this directory, the section marked *the plumbing*.

Both are standard library only and Linux only. The Go program plays a station from the same
catalogue and takes the same keys; it draws nothing, and its whole 249 lines are therefore not
comparable with the 510 of the Active Oberon program, which has frames, genres, a playlist and
an editor in it.

## The numbers

Three times, because the first two answers were wrong in ways worth keeping.

| | lines of plumbing |
|---|---:|
| Go — `event`, `keyboard`, `mpvLines`, `resizes` | **51** |
| Active Oberon, a ring written by hand | 79 |
| Active Oberon, on `GenericCollections` (Romanchenko's parametric containers) | 84 |
| **Active Oberon, on `Channels(TYPE T)`** | **57** + 45 in the library, once |

The first answer said Go wins by twenty-eight lines. The second, reached by using the generic
container that was in the tree all along, was *worse*: the container saved the ring arithmetic and
charged six lines for a comparator that a queue never calls -- a parametric module takes its
constraint as a parameter, and one has to be passed even where nothing is compared.

The third is the one that means something. What Go has is not a queue, it is a **channel**: a
queue, the waiting on both ends, back-pressure, and closing, in one thing. Written as a
parametric module of our own -- `source/Channels.Mod`, forty-five lines, all of the waiting being
one AWAIT at each end -- the program's own plumbing comes to fifty-seven lines against Go's
fifty-one.

That is parity, and the difference in where it lives: in Go the channel is in the language, and
here it is forty-five lines of library anybody can read. The language earns that by AWAIT: there
is no condition variable to signal and no wakeup to get wrong, which is why a channel is forty-five
lines and not a hundred.

## Where the difference actually is

**What Go has is a channel, not a container.** `make(chan event, 32)` is a queue, the waiting at
both ends, back-pressure and closing, in one word. A2 had the container already -- Yaroslav
Romanchenko's `GenericCollections`, parametric, in `std/data` -- and using it made the program
*longer*, because a container asks for a comparator that a queue never calls. The waiting is what
was missing, and it is what `Channels(TYPE T)` is: forty-five lines, one AWAIT at each end, no
condition variable to signal and no wakeup to get wrong.

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

1. ~~A queue that carries any type~~ -- done, and it was the wrong thing: `source/Channels.Mod`,
   a channel rather than a queue, is what closed the gap.
2. Two traps found on the way, both worth knowing before writing another parametric module: it
   must be in the library as a symbol file before anything can instantiate it -- a module sitting
   beside the program cannot be -- and a container asks for its comparator even when nothing will
   ever be compared.
3. What is still Go's: SIGWINCH as a channel. Everything else in this comparison is now even.

## Running them

```
ob run examples/Radio.Mod        # the Active Oberon side, full screen
go run radio.go                  # the Go side, a line at a time
```

Both need mpv and `~/.config/radio/stations.tsv`.
