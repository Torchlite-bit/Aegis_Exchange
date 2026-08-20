# tests/

Desktop checks for Aegis: Exchange. **Nothing here ships.** No file in `tests/`
is listed in `Aegis_Exchange.toc`, and the 1.12 client never loads any of it —
these are Lua **5.1** scripts run from a terminal.

```sh
./tests/run.sh              # lint + syntax + upvalues + definitions + units
./tests/run.sh --sabotage   # ...and prove the suites catch real bugs
```

Needs `lua5.1`, `luac5.1` and `python3`. On Debian/Ubuntu:
`apt install lua5.1 python3`. Run from the repo root.

---

## What this can and cannot tell you

**It covers** logic and API shape: money arithmetic, the price DB's
weighted-median maths, search-term parsing, reading an auction page, the
multi-buyout batch, and the Lua 5.0 language rules.

**It says nothing about how the addon looks.** Layout, colour, clipping,
alignment, and anything involving pfUI are not testable here and are
deliberately not faked into looking testable — `tests/support/wow.lua` builds
frames that answer every method and *draw nothing*. A green run is not evidence
that the window is right. That still needs a real client, and a person looking
at it.

Nor does it replace loading the addon. The single worst failure this project
has had — v1.16.0, which the client refused to load — passed every unit check,
because the failure was a Lua 5.0 limit that Lua 5.1 does not have. Which
brings us to:

---

## Why the lint layer exists

Everything in `tests/lint/` catches something **no test can**, because the
tools we test with are more permissive than the client we ship to.

| Check | Catches | Why nothing else sees it |
|---|---|---|
| `lua50.py` | `string.match`, `#`, `%`, `select()`, `hooksecurefunc`, `table.setn`, modern event handlers | All valid Lua 5.1. `luac5.1 -p` compiles them; the unit suites run them |
| `upvalues.py` | A function reading >32 file-scope locals | 5.0's limit is 32, **5.1's is 60**. The client refuses to load the file; every local tool says it is fine |
| `definitions.py` | A scripted edit that deleted a neighbouring function | The file still compiles. Lua does not care a function is missing until something calls it |
| `scoping.py` | A file-scope local read **above** its declaration | Legal Lua — it reads a nil *global* of the same name. Compiles, loads, fails only when that line runs |
| `modebits.py` | A Buy-tab widget no view shows or hides | Every widget exists; one just never appears, or never goes away |
| `sharedlayout.py` | Two views placed into one space by two different functions | Both look right until one of them is edited |
| `anchorchain.py` | Two widgets anchored below the same one | A fork in a vertical chain. The addon loads, every widget exists, nothing errors — the tab just draws on top of itself |

That middle row is not hypothetical. v1.16.0 shipped an addon that would not
load at all: thirteen new layout constants took `ui.BuildBuyTab` to 36
upvalues. `luac5.1 -p` compiled it and the entire suite passed.

The fix when `upvalues.py` trips is a **table**, not a smaller function.
Thirteen constants as thirteen locals cost thirteen upvalues; the same thirteen
as fields of one table cost one. See `BUYL` in `ui/frame.lua`.

`lua50.py` has its own self-test (`lint/selftest.py`) covering both halves:
every rule fires on a real violation, and none fires on a lookalike — `%` in a
`string.format`, `#` in a comment, `string.gfind` rather than `gmatch`. A lint
with false positives gets ignored within a day, which is the same outcome as
not having one.

---

## Why `sabotage.py` exists

A green suite has two possible causes: the code is right, or the assertions
cannot tell right from wrong. They look identical until something ships broken.

`sabotage.py` plants a real bug — usually the exact mistake the code is written
to avoid — in a **throwaway copy** of the tree, and requires the named suite to
fail. Anything that slips through is reported as `MISSED`, meaning that suite is
not testing what its name claims.

```sh
python3 tests/sabotage.py                 # all of them
python3 tests/sabotage.py batch           # just the ones matching "batch"
```

It found two blind spots the day it was written, both real:

- **`iteminfo-fixed-index`** — replacing `util.ItemInfo`'s "anchor on the last
  number" with a hardcoded `r[7]` changed nothing, because the simulated client
  only ever returned the vanilla 9-value `GetItemInfo`. The anchor exists
  because later clients insert `itemLevel` at slot 4 and shift everything after
  it, so the fix was to make `tests/support/wow.lua` able to return **both**
  shapes (`W.itemInfoShape`) and run the same assertions against each.
- **`batch-skips-opening-gold-check`** — deleting the up-front affordability
  check was invisible, because the per-purchase check further down also
  refuses, and both paths return `false`. The case that separates them is
  affording *some* of the selection: without the up-front check the first
  purchase succeeds and only the second fails, leaving the player poorer and
  holding half of what they asked for.

If a sabotage reports `stale`, the code has moved and that entry needs
rewriting — not deleting.

---

## Layout

```
tests/
  run.sh              one command for everything
  sabotage.py         plants real bugs, requires the suites to notice
  support/
    harness.lua       assertions and reporting
    wow.lua           simulated 1.12 client
  lint/
    lua50.py          Lua 5.0 language rules (CLAUDE.md hard rules 1-7)
    upvalues.py       the 32-upvalue ceiling (hard rule 12a)
    scoping.py        no file-scope local read above its declaration
    definitions.py    every top-level definition still present vs a git ref
                      (compares definition SETS -- it used to ask whether the
                      name appeared in the text, which a comment satisfied;
                      `--selftest` pins that)
    modebits.py       every Buy-tab widget accounted for by every view
    sharedlayout.py   views sharing a space are placed by ONE function
    anchorchain.py    no two widgets hang off the same anchor
    selftest.py       proves lua50.py fires, and does not over-fire
  units/
    util_test.lua           money, strings, tables, GetItemInfo normalisation
    db_test.lua             price DB, settings, ledger, Courier contract
    buy_term_test.lua       search-term parsing and the query contract
    buy_page_test.lua       reading a page; the throttle gate
    buy_batch_test.lua      multi-buyout safety
    sort_results_test.lua   bid-only rows sort last, both directions
    builder_term_test.lua   the Filter Builder's form <-> term round trip
    geometry_test.lua       panel insets, row counts, tab and form layout
    window_point_test.lua   a restored window point you can still reach
    taborder_test.lua       Tab traversal: wrap, hidden boxes, dead ends
    post_filter_test.lua    min-level/max-level/rarity/seller/left, and what
                            a filter does when it cannot answer
    rowchrome_test.lua      the shared zebra/hairline/selection chrome, and
                            the creation order that makes it draw right
    bags_test.lua           bag aggregation, and why "how much do I have" and
                            "what can I post as one stack" are two numbers
    sellslot_test.lua       moving an item into the sell slot without leaving
                            it on the cursor -- the slot button SWAPS
```

`sabotage.py` treats a **lint** as a suite too, not only a Lua unit file: a
lint makes a claim about the source and can be wrong about it the same way an
assertion can. `sharedlayout.py` passed once on a build where the thing it
checks for had been reverted — it was matching the *comment* that named the
function.

---

## The simulated client

`support/wow.lua` stands in for the **client**, not for FrameXML's appearance.
It pins the 1.12 API shapes that this addon has actually broken on, and
`QueryAuctionItems` **asserts** its contract rather than merely accepting a
call — name / minLevel / maxLevel must be strings, and `page` must be
0-indexed — so any query the engine sends is checked simply by being sent.

Two things about it are easy to get wrong and are commented in place:

- **`getglobal` reads `_G`**, not a private registry. Backing it with a side
  table made lookups of client constants (`AUCTION_TIME_LEFT1`) come back nil,
  which is a difference from the real client.
- **`W.Tick(frame, elapsed)` drives `OnUpdate`**, with `this` and the global
  `arg1` set the 1.12 way. The auction query throttle lives in an `OnUpdate`,
  so `buy.Search` on its own sends nothing — it only arms the driver. A test
  that calls `Search` and immediately looks for a query will see none, and that
  is correct behaviour, not a bug.

---

## Writing a new suite

1. Add `tests/units/<thing>_test.lua`, starting from an existing one.
2. End with `os.exit(H.report("<name>"))` and register that name in
   `sabotage.py`'s `SUITES`.
3. **Add at least one sabotage for it** and confirm it is caught. An assertion
   you have not seen fail is decoration.

For code that cannot be loaded here — `ui/frame.lua` needs a real frame API to
mean anything — extract the one function under test from the source **at run
time**, as `sort_results_test.lua` does. Extracted, not copied: a duplicate
drifts, and the test goes on passing against code nobody runs.
