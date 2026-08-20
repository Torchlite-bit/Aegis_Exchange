# tools/

Build-time scripts. **Nothing here ships.** No file in `tools/` is listed in
`Aegis_Exchange.toc`, the 1.12 client never loads any of it, and adding a file
here is never a **restart** release and never a version bump.

These exist so that constants baked into the addon can be **re-derived** rather
than trusted. A magic number in a Lua file is unfalsifiable; a magic number
with a generator beside it can be checked, argued with, and regenerated when
better data turns up.

---

## `gen_itemlevel.py` — `core/itemlevel.lua`

```sh
python3 tools/gen_itemlevel.py --ilvl <ShaguScore/Database.lua> \
    > core/itemlevel.lua
```

Emits `[itemId] = itemLevel` for every entry with a real level. Only item
level 0 rows are dropped — those are development stubs ("Kazgrim Test Druid
Chest 1"). Levels above 65 are **kept** even though the disenchant ladder
stops there: this is a factual item-level lookup, not a disenchant-band
lookup, and trimming it to what one consumer needs today is the coupling that
bites later. It also lets a caller tell *"level known, above our data"* apart
from *"nothing known"*, which are different things to tell a player.

### Provenance, and the caveat that comes with it

**Source: [ShaguScore](https://github.com/shagu/ShaguScore), by shagu.**

ShaguScore ships with **no licence** — no LICENSE file, no header, nothing in
its README or `.toc`. Aegis is MIT. Including this data is a judgement the
project owner made deliberately, with attribution, rather than something that
happened quietly; ROADMAP 3k parked it as the owner's call precisely because
it is about someone else's work and not a technical question.

If shagu would rather it were not here, it comes out and the addon keeps
working — the disenchant rule degrades to what the player has learned by
disenchanting things themselves, which is the source that outranks this one
anyway.

The input is **not vendored**. Pass it on the command line.

---

## `gen_disenchant.py` — the BANDS table in `core/disenchant.lua`

```sh
python3 tools/gen_disenchant.py --de <DisenchantList.lua> \
                                --ilvl <ShaguScore/Database.lua> --report
python3 tools/gen_disenchant.py --de ... --ilvl ... > /tmp/bands.lua
```

`--report` prints the diagnostics (what was skipped and why, the armour/weapon
centroids, every band with its observation count). Without it, the script emits
the Lua table for pasting into `core/disenchant.lua`.

### Inputs are NOT vendored, on purpose

Neither source file is in this repository and neither should be added.

- **`DisenchantList.lua`** — from **Enchantrix 3.6.1** (`## Interface: 11200`,
  our exact client). 5,214 items, **8,843,728 observed disenchants**,
  community-harvested and credited in the file's own tail. It is **GPL v2**.
  Aegis is MIT, so the file itself must never be copied in here.

  What *is* copied in is a few dozen derived probabilities — aggregate
  statistics describing how a game behaves. Those are facts about vanilla, not
  Enchantrix's expression of them, and they are re-derivable by anyone with the
  same observations.

- **`Database.lua`** — from **ShaguScore**. 12,871 `[itemId] = itemLevel`
  entries, which is what groups the observations into bands. It ships with **no
  licence at all**: no LICENSE file, no header, nothing in its README or `.toc`.
  See the note at the top of `core/itemlevel.lua` for why that matters and what
  is blocked by it (very little).

### What the script does, and the two judgement calls in it

The disenchant result is a function of (item level, quality, weapon-or-armour).
Neither input file carries quality or equip slot, so both are inferred:

- **Quality.** Greens yield dust; rares yield exactly one shard per proc; epics
  yield the same shards several at a time.
- **Class.** Within a band, dust share is sharply bimodal — armour ~82%,
  weapons ~17%, with an empty valley between. Cluster at 0.5 and read both
  centroids off the data. aux hand-types this split as 75/20; the observations
  disagree, which is the whole reason for generating rather than copying.

**Judgement call one — off-signature items are dropped, not blended.**
Enchantrix's file pools logs across vanilla's entire life, and Blizzard changed
the disenchant tables during it. A minority of items therefore carry an essence
tier from a different patch — ilvl 26–30 pieces yielding Greater Magic Essence
where that band's essence is Greater Astral. Those are real observations of a
rule nobody plays under any more. Each band's material set is taken to be the
one **most items** agree on, and items that disagree are dropped and counted
(the `--report` output names the number per band). Averaging them in would
drag the numbers toward a table that no longer exists.

**Judgement call two — a band ships only with depth AND breadth.** Both gates
are enforced, and neither implies the other:

| gate | why |
|---|---|
| `MIN_OBS_PER_BAND` | the probabilities must be stable |
| `MIN_ITEMS_PER_BAND` | they must describe a *rule*, not a few broken logs |

That second gate is what removes epics entirely. The source holds nine epic
items, three of which carry tens of thousands of procs — plenty of depth — with
yields like **4.14 Large Brilliant Shards per disenchant**, which is not a
result any vanilla item produces. Depth alone would have shipped them.

### What comes out, and what deliberately does not

Emitted: greens and rares, bands 15–65, split by armour/weapon where the data
supports it. Absent on purpose, each documented in `core/disenchant.lua`'s
header:

- **anything above item level 65** — the observations thin to a few dozen and
  stop being monotone, while Turtle item levels run to 99;
- **epics** — see above;
- **weapons in a few bands** — where no usable weapon data survives, the band
  ships armour only. The armour numbers are never borrowed for weapons: armour
  is dust-led and weapons essence-led, so borrowing is confidently wrong rather
  than roughly right.

### After regenerating

`tests/units/disenchant_test.lua` does **not** restate these constants —
restating generated numbers only proves the paste worked. It asserts what must
hold whatever the generator emits: probabilities summing to one, materials
drawn from the 24 real reagents, the dust ladder climbing in the right order,
and armour leading with dust where weapons lead with essence. Run
`./tests/run.sh --sabotage` after any regeneration; if the ladder assertions
trip, the generator changed meaning and not just precision.
