# tools/

Build-time scripts. **Nothing here ships.** No file in `tools/` is listed in
`Aegis_Exchange.toc`, the 1.12 client never loads any of it, and adding a file
here is never a **restart** release and never a version bump.

These exist so that constants baked into the addon can be **re-derived** rather
than trusted. A magic number in a Lua file is unfalsifiable; a magic number
with a generator beside it can be checked, argued with, and regenerated when
better data turns up.

---

## Removed: `gen_itemlevel.py`

It generated `core/itemlevel.lua`, a 141 KB table of item levels borrowed from
ShaguScore. Both are gone as of v1.41.0: ClassicAPI exposes the client's own
item level, which is the real number for every item rather than a partial copy
of one — and deleting it retired the question of whether shipping someone
else's unlicensed database was all right. `git log` has it if it is ever
needed again.

---

## `gen_charges.py` — `util.CHARGE_ITEMS` in `core/util.lua`

```sh
python3 tools/gen_charges.py --db ClassicDB_1_12_1_z2815.sql.gz --report
python3 tools/gen_charges.py --db ClassicDB_1_12_1_z2815.sql.gz > /tmp/charges.lua
```

Same database as below. It lists every item whose use spell has **more than one
charge** — Wizard and Mana Oils, the gnomish and goblin devices, 83 in all.
Paste the output between the `BEGIN GENERATED` / `END GENERATED` markers.

**Why it exists.** 1.12 reports a charge item's charges where a stack count
goes, so one Wizard Oil read as five items: priced per charge, offered as a
stack of five, and split when posted "one". `util.ItemUnits` turns a client
count into items, and this list is how it knows which items to do that for.

**Every item on it is non-stacking,** and `--report` says so — it counts the
ones that stack and leaves them out (there are none). That is what makes the
rule safe: an item that can never stack has no real count above one, so a count
above one is its charges. The list is still only a fallback: a max stack the
client has stated wins over it, either way.

aux keeps a hand-typed list of twelve of these; `tests/units/charges_test.lua`
checks that all twelve are in the generated one.

The script checks the dump's column layout against the positions it reads, and
refuses to run if `item_template` has moved them.

---

## `gen_disenchant.py` — the BANDS table in `core/disenchant.lua`

```sh
python3 tools/gen_disenchant.py --db ClassicDB_1_12_1_z2815.sql.gz --report
python3 tools/gen_disenchant.py --db ClassicDB_1_12_1_z2815.sql.gz > /tmp/bands.lua
```

`--report` prints the diagnostics: how many items and loot entries were read,
the inventory-type → ladder split it derived, anything it refused and why, and
every band with its DisenchantID and item count. Without it, the script emits
the Lua table for pasting into `core/disenchant.lua`.

### It reads the rule; it used to infer it

Until v1.54.13 this script derived the table from **8.8 million observed
disenchants** (Enchantrix's `DisenchantList.lua`) grouped by a borrowed
item-level table (ShaguScore). Neither file carried item quality or equip slot,
so both were inferred — quality from the shape of the yields, armour-or-weapon
by clustering on dust share.

It now reads **CMaNGOS Classic-DB**, a 1.12.1 content database.
`disenchant_loot_template` states what each DisenchantID yields, at what chance
and in what quantity; `item_template` states every item's quality, item level,
inventory type and which DisenchantID it uses. That is not a sample of the
rule — it is the rule, as the server runs it.

**The two agree**, which is the best evidence either was right: where the old
method produced a band, the materials match and the mean yields match to two
decimal places. Strange Dust in band 20 measured 2.509 per proc; the loot table
rolls 2–3.

What the samples could not reach, and this does:

| gap | what was wrong |
|---|---|
| epics | nine source items with impossible yields, dropped — so an epic reported *unknown* |
| weapons in bands 25, 30, 65 | no weapon observations survived the depth/breadth gates |
| the 5% shard in bands 55 and 65 | too rare to clear the noise floor — **this is the one a player reported** |
| shields, held-in-off-hand | take the **weapon** ladder; no dust-share clustering could see a slot |
| thrown weapons | cannot be disenchanted at all; the old table said they could |
| item level above 65 | the observations thinned out there; the game does not |

### The input is NOT vendored, on purpose

**CMaNGOS Classic-DB** is **GPL v3** and Aegis is MIT, so the dump must never
be copied in here. Get it from `cmangos/classic-db`, `Full_DB/`.

What *is* copied in is a few dozen derived probabilities — aggregate facts
about how a 1.12 server behaves. Those are facts about the game, not
Classic-DB's expression of them, and they are re-derivable by anyone with the
same dump. Same reasoning that applied to Enchantrix (GPL v2) before it.

### Each row carries its count range

Rows are `{ materialId, chance, meanYield, min, max }`. The **mean** values an
item; the **range** is what lets a player's own disenchants identify a band.
Green bands 60 and 65 yield the same three materials and differ only in count
(Illusion Dust 1–2 against 2–5), so without the range they can never be told
apart. `resolve()` refuses an entry whose range is not a range.

### The one judgement call left

**Mangos loot-group semantics.** Within a group, a row with an explicit chance
takes that chance and a row written as `0` takes whatever the group has left.
Every green entry is three rows — dust 75, essence 20, shard **0** — and that
last zero is the 5%. Reading it as "never drops" is precisely the bug this
rewrite fixes, so `resolve()` makes the remainder explicit and **refuses any
entry whose chances do not come to 100%**.

One entry is refused: DisenchantID 50 (rares above item level 70) holds a
single row at 0.5%, which is not a distribution. Those rares report unknown
rather than have half a percent normalised up to certainty.

### After regenerating

`tests/units/disenchant_test.lua` does **not** restate these constants —
restating generated numbers only proves the paste worked. It asserts what must
hold whatever the generator emits: probabilities summing to one, materials
drawn from the 24 real reagents, the dust ladder climbing in the right order,
armour leading with dust where weapons lead with essence, a shard in every
green band above the first, and an epic out-yielding the rare of the same
level. Run `./tests/run.sh --sabotage` after any regeneration; if the ladder
assertions trip, the generator changed meaning and not just precision.
