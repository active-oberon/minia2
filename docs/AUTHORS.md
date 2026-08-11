# Who wrote A2 — the names behind the initials

The `AUTHOR` field of an A2 module usually holds a login or a pair of initials: `pjm`, `fof`,
`staubesv`, `TF`, `adf`, `be`. Twenty years on that is unreadable, and a name is the only thing that
lets the code be credited out loud — in an upstream patch, in a course, in a package registry.

This file resolves what can be resolved. It is deliberately conservative: **each entry says what the
claim rests on**, and a guess dressed as a fact is worse than an admitted gap.

## What was read, and how much each source is worth

- **The two vanilla trees**, `oberon` (2266 modules) and `aos` (4003). Of these, **3089 modules carry
  an `AUTHOR` field**, holding **160 distinct values**. Some sign in full; some carry an ETH address
  in the same file; some name a person on the same line as the login.
- **The ETH `oberon` mailing-list archive** (`lists.inf.ethz.ch/pipermail/oberon`). Authoritative and
  external: the messages carry real names in their headers.
- **The Oberon authors list** on Wikibooks, derived from an ETH document: abbreviation → name → contact.
- **Git identities** in a clone of the ETH repository assembled locally. Two warnings about this one,
  and they are the reason it is listed last:
  - it is a working copy put together for our own purposes, not an authoritative upstream;
  - **who added a file there is not who wrote it.** The import is a bulk one: the same person appears
    as the "adder" of files signed `TF`, `pjm`, `adf`, `be`, `PL`, `eos` and `prk`. What that history
    *does* establish is the identity of the committers themselves — a login with a real name and
    address attached to it — and only that is used below.

### Where those git identities came from

They are not free evidence either: they exist because the SVN commit authors were pulled out and
mapped to names by hand (Andrii Puhachenko, June 2024), with help from **Bohdan Troschynsky**, who
knew several of the people. That is why some entries in the history carry a full name and others are
a bare login — **the bare ones are exactly the people nobody could put a name to at the time.**

Two things from that exchange are recorded here as what they are, someone's testimony rather than a
document:

- Bohdan on `tfrey`: **"автор системы"** — the author of the system. Thomas Frey signs 350 modules
  as `TF`/`tf`, the second-largest body of work in the tree, which is consistent with it.
- Bohdan on `eth.metacore`: **"Константин, если не ошибаюсь"** — Konstantin, if he is not mistaken.
  Left unresolved below, because that is what "if I am not mistaken" means.

One gap worth naming: the 2024 map carried `guenter = Guenter <guenter@ethz.ch>`, with **no
surname**. The surname Feldmann appears in the history as it stands now, so it was established after
that map was written; it is consistent with `G.F.` signing the Unix port, but the map itself does
not carry it.

## Resolved

| Login | Name | Modules | Evidence |
| --- | --- | --- | --- |
| `staubesv` | **Sven Stauber** | 489 | ETH mailing list, 2007: header `Stauber Sven Philipp`, address `staubesv@student.ethz.ch`, signed "Cheers, Sven Stauber". Independently, the git identity `Sven Stauber <staubesv@inf.ethz.ch>` |
| `TF`, `tf` | Thomas Frey | 350 | `thomas.frey@alumni.ethz.ch` is itself the `AUTHOR` value of 18 modules; `frey@inf.ethz.ch` in 3 more signed `TF`; git identity `Thomas Frey <tfrey@inf.ethz.ch>` |
| `fof` | Felix Oliver Friedrich | 207 (+27 `adf, fof`, +27 `fof & fn`) | full name in 72 modules signed `fof`; the git identity appears both as `Felix Friedrich` and `Felix Oliver Friedrich`, which is where the three initials come from |
| `pjm` | Pieter J. Muller | 204 (+30 `pjm, mvt`) | full name in 154 modules signed `pjm`; the Oberon authors list gives `Pieter J. Muller`, and the middle initial is the `j` |
| `adf` | Alan D. Freed | 108 (+27 `adf, fof`) | full name in 108 modules signed `adf` — the numerics and tensor work |
| `negelef` | **Florian** Negele | 66 | git identity `Florian Negele <negelef@ethz.ch>`. Not Felix: the earlier reading of this login was wrong |
| `G.F.`, `GF` | Günter Feldmann | 79 | git identity `Günter Feldmann <guenter@ethz.ch>`, and he is himself the one who added the `GF`-signed files. This is the Unix port (`Unix.*`, `Linux.Glue`) |
| `swalthert` | Stefan Walthert | 48 | full name in 33 modules signed `swalthert` |
| `prk` | Patrik Reali | 43 (+27 `prk / be`) | full name in 35 modules; `reali@inf.ethz.ch` in the tree |
| `SAGE` | Yaroslav Romanchenko | 38 | signs `Yaroslav Romanchenko (SAGE)` in 20 modules; git identity `Yaroslav Romanchenko <sage@inf.ethz.ch>` |
| `eos` | Erich Oswald | 34 | the Oberon authors list: `Erich Oswald - erich.oswald at ergon.ch`; `oswald@inf.ethz.ch` appears in the trees |
| `rstoll` | Robin Stoll | 21 | full name on the same line as the login; git identity `rstoll@inf.ethz.ch` |
| `oljeger` | Olivier Jeger | 18 | signs as `oljeger@student.ethz.ch`; full name on the same line |
| `bmoesli` | Bernd Mösli | 9 | the Oberon authors list: `Bernd Mösli - moesli at arithmetica.ch` |
| `chwassme` | Christian Wassmer | 6 | the field itself reads `Christian Wassmer, chwassme@student.ethz.ch` |
| `chh` | Heinzer *(given name not established)* | 3 | `heinzerc@student.ethz.ch` in the same modules |
| `easthope` | Peter Easthope | — | the 2024 SVN map, and the history: `Peter Easthope <easthope@inf.ethz.ch>` |
| `skoster` | Stephan Koster | — | the same map: `skoster@student.ethz.ch` |
| `shulga` | Dmytro Shulga | — | the history: `Dmytro Shulga <shulga@inf.ethz.ch>` |
| `andre` | Andre Fischer | — | the 2024 SVN map: `andref@inf.ethz.ch`. Not to be confused with `adf`, which is Alan D. Freed |
| `morozova` | Oleksii Morozov | — | the same map, across three servers (`highdim.com`, `ethz.ch`, `inf.ethz.ch`) |
| `sergundo` | Sergey Durmanov | — | the same map; the correspondent our upstream patches go to |

Signed in full already: **Patrick Hunziker** (183), **Timothée Martiel** (45), **Matthias Frei** (33),
**Luc Blaeser** (27), **Simon L. Keel** (24). **BohdanT** (50) is Bohdan Troshchynskyi, the A2DB
author — known from correspondence, not from the trees.

## Unresolved

| Login | Modules | What it is |
| --- | --- | --- |
| `be` | 51 (+27 `prk / be`) | Bluetooth stack, `FATFiles`, `Autostart`; also compiler work beside `prk`. No name in the trees, none in the authors list |
| `PL` | 39 | the DTP editor family (`DTPData`, `DTPEditor`, `DTPText`), Cyberbit font install |
| `mvt` | 18 (+30 `pjm, mvt`) | the Native Oberon network stack: `ICMP`, `Ping`, `TraceRoute`, `Loopback`, `InitNetwork` |
| `ottigerm` | 23 | the USB HID driver family |
| `ug` | 15 | `WMFileManager`, `WMSearchTool`, `Looks`, the skin loaders |
| `ejz` | 21 | `Inflate`, `Unzip`, `LPR`, `XYModem` |
| `heulemar` | 18 | the OSC (Open Sound Control) family |
| `cplattner` | — | pairs with `staubesv` on USB (`cplattner/staubesv`) |
| `gubsermi`, `fnecati`, `PL`, `fn` | 24–39 | `fn` always appears as `fof & fn` on the compiler and is a different person from `negelef` |

Bare logins in the history with no name anywhere: `metacore`, `ulrikeg`, `tom`, `lisa`, `clerco`,
`ursf`, `pboenhof`, `pnonava`, `rschmid`, `sedlacek`, `bomarie`, `ofgeorg`, `gubsermi`, `mancos`,
`infos`.

## What would settle the rest — and what probably will not

The likeliest explanation for most of the remainder is the plainest one, and it was Andrii's reading
of the SVN map when he made it: **semester and diploma students.** Someone wrote the USB HID stack or
the DTP editor for one term, signed it with two letters, and left; the name never entered the
repository because the repository was never where names lived.

That sets the expectation honestly. What worked for `staubesv` was the ETH mailing-list archive, and
it worked because he was there for years and wrote to it. A student who wrote one driver family in a
semester will not be found that way. Worth trying anyway, in this order: the mailing list **by module
name and date** rather than by login (a two-letter login is unsearchable); the Native Oberon and
Bluebottle release notes, which credited semester work; and asking the people who are still
reachable — Bohdan Troschynsky and Sergey Durmanov both knew that generation.

Where a name is never found, the login stays. A login is not anonymity: it is the name the person
chose to sign with, and it is better than an invented attribution.

## Sources

- ETH `oberon` mailing list: <https://lists.inf.ethz.ch/pipermail/oberon/2007/005138.html>
- Oberon authors list: <https://en.wikibooks.org/wiki/Oberon/authors>
- ETH Oberon project pages: <http://www.ethoberon.ethz.ch/projects.html>
