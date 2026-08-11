# Who wrote A2 — the names behind the initials

The `AUTHOR` field of an A2 module usually holds a login or a pair of initials: `pjm`, `fof`,
`staubesv`, `TF`, `adf`, `be`. Twenty years on that is unreadable, and a name is the only thing that
lets the code be credited out loud — in an upstream patch, in a course, in a package registry.

This file is the first pass at resolving them. It is deliberately conservative: **each entry says
what it rests on**, and a guess dressed as a fact is worse than an admitted gap.

## Method

Both vanilla trees were read: `oberon` (2266 modules) and `aos` (4003). Of those, **3089 modules
carry an `AUTHOR` field**, holding **160 distinct values**. Three kinds of evidence were used, in
descending order of weight:

1. **The field itself already holds a name.** Several prolific authors sign in full.
2. **An ETH address in the same module.** `AUTHOR "TF"` in a file that also carries
   `frey@inf.ethz.ch` is not a coincidence at three separate modules.
3. **A full name on the same line as the login**, in a comment or a history entry.

What was NOT used: memory, folklore, or the wider internet. Everything below can be re-derived from
the two trees.

## Resolved

| Login | Name | Modules | Evidence |
| --- | --- | --- | --- |
| `TF`, `tf` | Thomas Frey | 350 | `thomas.frey@alumni.ethz.ch` appears as the `AUTHOR` value itself in 18 modules; `frey@inf.ethz.ch` in 3 more signed `TF` |
| `pjm` | Pieter Muller | 204 (+30 as `pjm, mvt`) | full name in 154 modules signed `pjm`; `muller@inf.ethz.ch` in the tree |
| `fof` | Felix Friedrich | 207 (+27 as `adf, fof`, +27 as `fof & fn`) | full name in 72 modules signed `fof` |
| `adf` | Alan Freed | 108 | full name in 108 modules signed `adf`; the joint `adf, fof` modules are the numerics work |
| `prk` | Patrik Reali | 43 (+27 as `prk / be`) | full name in 35 modules; `reali@inf.ethz.ch` in the tree |
| `swalthert` | Stefan Walthert | 48 | full name in 33 modules signed `swalthert` |
| `rstoll` | Robin Stoll | 21 | full name on the same line as the login |
| `oljeger` | Olivier Jeger | 18 | signs as `oljeger@student.ethz.ch`; full name on the same line |
| `chwassme` | Christian Wassmer | 6 | the field itself reads `Christian Wassmer, chwassme@student.ethz.ch` |
| `SAGE` | Yaroslav Romanchenko | 38 | signs `Yaroslav Romanchenko (SAGE)` in 20 modules |
| `chh` | Christoph Heinzer *(surname certain, given name not)* | 3 | `heinzerc@student.ethz.ch` in the same modules |

Signed in full already, no resolution needed: **Patrick Hunziker** (183), **Timothée Martiel** (45),
**Matthias Frei** (33), **Luc Blaeser** (27), **Simon L. Keel** (24), **BohdanT** — Bohdan
Troshchynskyi, the A2DB author, known to us from correspondence rather than from the tree (50).

## Unresolved

These matter more than the resolved ones, because the largest of them is the most prolific author in
the whole of A2:

| Login | Modules | What is known |
| --- | --- | --- |
| `staubesv` | **489** | the single most frequent `AUTHOR` value in both trees. Performance monitor, USB stack, drivers. No full name and no address anywhere in either tree |
| `be` | 51 (+27 as `prk / be`) | works alongside `prk` on the compiler; no name found |
| `G.F.`, `GF` | 79 together | the Unix port (`Unix.*`, `Linux.Glue`) is signed `G.F.`; no name found |
| `PL` | 39 | no name found |
| `eos` | 34 | no name found |
| `mvt` | 18 (+30 as `pjm, mvt`) | pairs with `pjm` on Native Oberon |
| `ottigerm`, `gubsermi`, `ejz`, `ug`, `cplattner`, `bmoesli`, `heulemar`, `fnecati` | 15–28 each | logins only |

`fn` (27 modules, always as `fof & fn` on the compiler) is a distinct person from `negelef`
(66 modules, Felix Negele by the login) — the trees do not settle which name belongs to `fn`.

## What would settle the rest

Nothing in these two trees will: the addresses that would resolve `staubesv` and `be` are not in
them. The next places to look, in order of likely yield: the ETH Native Oberon and Bluebottle
release notes and `docu/`; the papers under the offline archive; and, for the ones who are still
reachable, asking. `staubesv` alone is worth the ask — 489 modules is more of A2 than any other
single person wrote.
