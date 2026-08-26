# Roadmap

What's next for **Aegis: Exchange**, and how it splits across this repo and
its planned companion, **Aegis: Courier**.

Phases are ordered by **dependency**, not by importance — a later phase
builds on a data shape or API an earlier phase establishes. Within a phase,
sub-items are staged so each one ships something usable on its own rather
than landing as one giant cut.

Some design questions below are marked **Decided** (settled in the planning
conversation that produced this doc) vs **Open** (still needs a call before
implementation starts). Don't start Open items without confirming first.

Inspiration credit: several ideas here (the historical-value algorithm's
shape, the search query language) are inspired by
[aux-addon](https://github.com/zanthor/aux-addon)'s design. Per CLAUDE.md's
"Reference addons" note, that's **All Rights Reserved** — every item below
means an original Aegis implementation of the *idea*, never ported code.

---

## Phase 0 — Foundations

Small, self-contained changes that later phases assume are already true.
Doing these first avoids redoing work once Phase 2/3 build on top.

### 0.1 Realm-keyed price data — ✅ **DONE** (v1.1.6)
**The premise here was backwards, and the audit caught it.** This item assumed
price data might be scoped *narrower* than the realm and need widening. It was
scoped *wider*: `## SavedVariables` is account-wide across **every realm**, so
Octo WoW and Capy WoW characters were folding buyouts into the same daily
minimum — two unrelated economies blended into one median. The work was
narrowing, not widening.

Shipped shape: market data hangs off `realms[realmName].items`; things that are
game constants rather than economy facts stay account-wide and shared — vendor
prices (an NPC charges the same on every server, so siloing them per realm
would force you to re-learn them), the name→ID map, shopping lists, crafting
projects, settings and the ledger. All price access routes through
`db.Items()`, so the split lives in one place.

Migration v2→v3 preserves existing history by attributing it to the realm you
first log in on after updating — the data carries no realm tag, so there's no
better attribution available, and it self-corrects within `KEEP_DAYS` as fresh
scans age the old dailies out. Discarding history on upgrade would have been
worse for everyone.

### 0.2 Aegis: Courier integration surface — ✅ **DONE** (v1.1.7)

Shipped in `core/db.lua` under a single "Companion-addon integration surface"
block — that block is the whole contract. **This is what Courier calls:**

```lua
-- Guard every use; Aegis may not be installed.
if AegisExchange and AegisExchange.INTEGRATION_VERSION then

    -- 1. Take ownership of the mailbox. Aegis's own scanner stands down.
    --    Call from Courier's ADDON_LOADED.
    AegisExchange.ClaimMailScanning("Aegis: Courier")

    -- 2. Push the matched transaction. ONE TABLE -- see the warning below.
    local ok, why = AegisExchange.RecordExternalTxn({
        kind   = "sale",        -- or "buy"
        item   = "Silk Cloth",
        amount = netProceeds,   -- copper, AFTER the 5% cut (what actually
                                -- arrived in the mail)
        itemId = 4306,          -- optional
        -- key = ...            -- OPTIONAL, and usually WRONG. See below.
    })
end
```

> 🚨 **It takes ONE TABLE, and calling it positionally fails SILENTLY.**
> `RecordExternalTxn` reports a bad payload by **returning** `false, reason` —
> it does not raise — so a caller that wraps it in `pcall` and checks only the
> ok flag sees success while every entry is dropped. Courier shipped exactly
> that bug and it survived from its first release to v1.0.2, because its test
> double had the same wrong signature and agreed with it. **Check the returned
> value, not just that the call didn't error.**

`RecordExternalTxn` returns `true`, or `false` plus a short reason
(`"duplicate"`, `"kind must be 'sale' or 'buy'"`, …) so Courier can surface
failures rather than miscounting silently. `INTEGRATION_VERSION` is currently
**1**; it bumps whenever a signature or field meaning changes.

**Why `MailTxnKey` is exposed — and why Courier does NOT use it.** It was put
here for a caller that books mail on **arrival**, as Aegis's own scanner does:
such a caller sees the same mail on every inbox refresh and needs a fingerprint
to avoid re-reporting it, and sharing Aegis's own key scheme means a user who
ran Aegis alone doesn't get their existing entries double-counted on the day
the companion is installed.

**That advice is wrong for a caller that books on collection, and Courier is
one.** `MailTxnKey` buckets `subject | money | arrival-hour`, so **two identical
stacks sold at the same price within the same hour produce the same key** — the
second is rejected as `"duplicate"` and lost. A collision *under*-counts, and a
missing sale is invisible in a way a doubled one is not. Courier books when a
mail is emptied (`take.Confirm`), which is self-limiting: an emptied mail has
nothing left to book, so it sends no key at all.

The residual overlap is accepted on both sides and written down in Courier's
`bridge.lua`: mail Aegis already booked on arrival that is **still uncollected**
when Courier is installed gets counted twice. That is a one-time, bounded
handover window, not an ongoing defect.

So: keep `MailTxnKey` exposed — Aegis's own standalone scanner uses it, and an
arrival-time companion would want it — but it is **not** part of the recommended
Courier path.

**Mail ownership** is an explicit handshake (`ClaimMailScanning` /
`ReleaseMailScanning`) rather than Aegis sniffing for a global, because explicit
survives Courier being renamed. There *is* a global-name fallback for a Courier
that loads without claiming, but it is a safety net, not the contract.

**Closed (v1.7.0):** the fallback used to guess at `AegisCourier` /
`Aegis_Courier`. Courier's `core/init.lua` declares **`AegisCourier`**, and
`Aegis_Courier` is only the folder / `.toc` name — never a global — so the list
is now the single confirmed name. A test pins it: sniffing the folder name must
NOT stand Aegis's scanner down.

**The seam was dead from Courier's first release until its v1.0.2.** Courier
called `RecordExternalTxn` with four positional arguments instead of the table.
Aegis saw `txn = "sale"`, failed its own type check and **returned** false —
without erroring — so Courier's `pcall` reported success and every push was
dropped with no warning on either side. Both repos claimed
`INTEGRATION_VERSION = 1`, so the version guard could not catch it.

**Fixed entirely on Courier's side** (its PR #7); nothing in Aegis changed and
`INTEGRATION_VERSION` stays at **1** — the table shape was always the published
contract, and Aegis had no wrong caller to accommodate. Courier now also reads
the returned value rather than just `pcall`'s ok flag, which is the part that
kept the bug invisible.

Worth remembering when the next companion is written: **this API's failure mode
is a silent false success.** Returning `false, reason` is friendlier than
erroring right up until a caller ignores the return. If a third integration
ever appears, consider having `RecordExternalTxn` print a one-time developer
warning when it is handed a string where a table belongs — the positional call
is unmistakable, and it would turn this exact mistake into something visible.

Full design (data-flow direction, standalone requirement) below in **Phase 1**.

**The other cross-addon convention: event-handler cost.** The integration
contract above is about *data*; this one is about *not freezing the client*,
and it binds all four Aegis addons. A 1.12 client populates its item cache
lazily, so the first mailbox open of a session with unseen attachments fires
`MAIL_INBOX_UPDATE` / `BAG_UPDATE` dozens of times in a few frames. Any
handler that does an unbounded rescan, a `GetItemInfo` per item, a
`GameTooltip:Set*` per item, or a list repaint inline gets multiplied by that
storm — which is what froze Courier and stalled RallyPower (~18s, from a bag
event, with no mailbox feature at all) while Exchange stayed clean.

**Exchange is the reference implementation; the rule and the three safe
shapes are HARD RULE 16 in [`CLAUDE.md`](CLAUDE.md).** Port that rule and its
self-check line into the other repos' `CLAUDE.md` verbatim rather than
restating it here — one wording, four addons.

### 0.3 Historical-value weighting audit — ✅ **DONE** (v1.4.0)
**The gap was real, and it was both halves of the intent.** Target behaviour was
"recent days weighted more, decreasing effect past roughly a month". Neither
held:

- **The window was 11 days**, and `PruneDaily` deletes everything past it — so
  nothing survived to a month for its effect to decrease.
- **The curve was nearly flat.** At `DECAY = 0.95` the oldest retained value
  still carried 57% of today's weight. Measured against an *unweighted* median
  over 3000 random series, the shipped weighting changed the answer in **6.9% of
  cases**. It was a flat 11-day median wearing a decay curve's name.

The audit method is worth repeating for Phase 3: reimplement the algorithm
independently, prove the reimplementation matches `db.MarketValue` exactly on
hundreds of random series, *then* sweep parameters with the verified model.
Sweeping an unverified model measures the model, not the addon.

Shipped: `KEEP_DAYS 11 → 30`, `DECAY 0.95 → 0.85`.

| | today | 3d | 7d | 14d | 21d | 30d |
|---|---|---|---|---|---|---|
| weight | 100% | 61% | 32% | 10% | 3% | 1% |

Chosen because it costs nothing to get: step response (100 → 200 and stays)
is **5 days, identical to the old setting**; the weighting now changes the
answer in 88% of cases instead of 7%; outlier rejection is untouched; and it
fixes casual scanning — in an 11-day window someone scanning weekly had **one**
sample, and a weighted median of one sample is just that sample. Thirty days
gives them four.

Storage cost is real but modest: ~3.4 MB of SavedVariables at 6000 items ×
30 days, up from ~1.3 MB. No migration — existing DBs simply stop being pruned
so hard and ramp to the full window over three weeks.

> **Note for Phase 3's line graph:** the value being plotted is a *median*, so
> it returns one of the observed daily values rather than a smooth average.
> Expect a step-shaped series, not a curve.

### 0.4 Dynamic Window Scaling & Resizing — ✅ **DONE** (v1.2.0)
Grab-and-drag grip on the bottom-right corner, size remembered per character,
every list re-fitting itself to the new height on release.

One thing turned out not to be possible as written: "inner UI panels, tables,
and buttons dynamically rescale". **Vanilla frames do not reflow** — a 1.12
layout is fixed anchors and fixed font sizes, so a bigger window can only ever
show *more rows*, never larger ones. That is a client limit, not a shortcut.
So the item shipped as **two** controls rather than one: resizing for more
rows, and a separate **window scale** setting (70–150%, also per character) for
physically bigger. On a large monitor you generally want both.

---

## Phase 1 — Aegis: Courier (separate repo, parallel track)

**New repo**, not a branch of this one. Runs on its own timeline once
Phase 0.2 lands — the integration surface is the only thing it depends on
from this side.

**Decided design:**

- **Data flow: Courier → Aegis, one direction only.** Courier owns mailbox
  scanning and pushes matched transactions into Aegis's ledger through the
  `RecordExternalTxn` API from 0.2. Aegis never reads Courier's
  SavedVariables. This keeps the maintenance boundary at one small function
  signature instead of two repos both depending on each other's internal
  table shapes.
- **Fully standalone.** Courier ships its own minimal SavedVariables and
  works as a complete TurtleMail replacement with zero Aegis Exchange
  installed. It only checks `if AegisExchange and
  AegisExchange.RecordExternalTxn` and layers the integration on top when
  Aegis is present. Mail-only users never need to install the AH addon.

**Feature scope** (TurtleMail replacement + Aegis integration):

- Open-all / take-all / delete-read and other standard mailbox convenience
  actions.
- Detect "Auction successful" / outbid / won-auction mail, match to the
  underlying item and gold.
- Show sale price, the 5% consignment cut, and net proceeds per mail.
- Finalize a ledger entry only once gold/items are actually **collected**,
  not merely when the mail arrives.
- Dedupe via a stable per-mail id — never double-count a mail re-scanned on
  a later mailbox visit (mirrors the `WasSeen`/`MarkSeen` pattern already in
  `core/db.lua`, reimplemented independently since Courier keeps its own
  ledger).

**Kickoff prompt** for the new session (paste as the opening message once
the new repo exists):

```
Aegis: Courier — a standalone mailbox companion for WoW 1.12 (Turtle WoW),
replacing TurtleMail, with optional integration into Aegis: Exchange.

Same hard constraints as Aegis: Exchange (Lua 5.0, 1.12 API only, no
string.match/gmatch, no # operator, no % operator, no hooksecurefunc,
getglobal/setglobal for dynamic frame names, table.getn/math.mod). Pull
CLAUDE.md's HARD RULES section verbatim as this repo's own CLAUDE.md
starting point — the client-level constraints are identical.

Architecture:
- Fully standalone. Own .toc, own SavedVariables (CourierDB /
  CourierCharDB), own mailbox UI. Zero dependency on Aegis: Exchange being
  installed.
- Optional integration: at ADDON_LOADED, check `if AegisExchange and
  AegisExchange.RecordExternalTxn`. When present, matched sale/purchase
  mail gets pushed through that function rather than any direct access to
  AegisExchangeDB's internal shape. Never read or write Aegis's
  SavedVariables table directly. Data flows Courier -> Aegis only, never
  the reverse.
- Own local ledger always maintained regardless of Aegis's presence, so
  standalone users get full transaction history without Aegis installed.

Core features (TurtleMail replacement):
- Open-all / take-all / delete-read convenience actions on the mailbox.
- Detect "Auction successful"/"Auction won"/outbid mail, match to the
  underlying item + gold, and log sale price, the 5% consignment cut, and
  net proceeds.
- Only finalize a ledger entry once gold/items are actually collected, not
  merely when the mail arrives.
- Dedupe via mail GUID or equivalent stable id -- never double-count a
  mail re-scanned on a later mailbox visit.

Reference AegisExchange.db's existing ledger shape (RecordTxn / Ledger /
LedgerTotals / WasSeen / MarkSeen in core/db.lua of the Aegis_Exchange
repo) for the integration payload shape -- Courier's push into Aegis should
produce entries indistinguishable from Aegis's own.

Start with: a read-only audit of TurtleMail's actual feature set (what
"convenient mailbox features similar to TurtleMail" concretely means),
then a Stage A shell (own window, mailbox takeover on mail frame show,
same replace-don't-overlay approach Aegis: Exchange uses for the AH) before
any scanning logic.
```

---

## Phase 2 — Search Query Language

The largest single piece of work here. Staged so each sub-phase ships
something real rather than landing as one cut.

**Decided — the grammar is aux's**, not a new Aegis-native dialect:
slash-delimited terms, semicolon-separated OR at the top level, keyword
modifiers (`exact`, `quality2`, `tooltip`, price/time-left primitives),
prefix-notation `and`/`or`/`not` for post-filter combination. "Keep true to
Aegis" turned out to mean the surrounding UI and workflow polish, not the
syntax itself — so this phase is an original implementation of a known-good
grammar, not language design from scratch.

**Decided — no Auto Buy.** Matches get surfaced (colored, flagged, sortable,
one click away); every purchase stays a manual click, always. Revisit only
if explicitly requested later.

**Decided — three-way UI inside the existing Buy tab**, matching aux's
Search Results / Saved Searches / Filter Builder split, mapped onto Aegis's
current layout rather than replacing it:

- The existing **Shopping Lists sidebar** (`ui/frame.lua` `BuildBuyTab`,
  named multi-item lists searched sequentially) stays — aux doesn't have an
  equivalent concept, and it's a genuinely different use case from a single
  saved query. It is not being merged into Saved Searches. (Since 2e it
  lives behind the left column's **Advanced** toggle, sharing the space
  with the category tree; nothing about how it works changed.)
- The right-hand content area gains a row of switchable views — **Search
  Results** (today's results table, now also accepting typed query syntax),
  **Saved Searches**, and **Filter Builder** — reusing the sidebar's screen
  real estate rather than adding a fourth top-level sub-tab.

### 2a — Parser, compiler, core primitives — ✅ **DONE** (v1.5.0)
Casual usage is untouched: a bare word with no keyword is just name text, so
typing an item name searches by name exactly as before. Shipped in the same box:

- **Blizzard-query / post-filter split.** `buy.CompileTerm` returns `{ blizz,
  filter }` — one 9-arg `QueryAuctionItems` per term, plus a closure applied to
  each row as `buy.ReadPage` loads it. Server-side: name, level range, quality,
  usable. Client-side: exact, buyout-only, fully-stacked, tooltip substring.
- **`exact`**, **buyout-only**, **fully-stacked-only**, and **tooltip
  substring** — including the `container/bag/tooltip/8` vs `container/bag/8`
  disambiguation, which is a test.
- **Semicolon OR** browses as ONE list: `buy.NextPage` rolls past the last page
  of a term into the next term rather than stopping. (`PrevPage` crossing
  backwards lands on the previous term's *first* page — we don't know its page
  count until we query it, and a round trip just to deep-link "its last page"
  isn't worth it.)
- Quick wins: right-click a bag item on the Buy tab to search it (Sell tab's
  right-click-to-slot untouched — each fires only on its own tab), shift-click
  any item anywhere to search it, Tab-completion from every learned item name.

**Categories** (`armor/leather`, `container/bag`, `armor/plate/chest`) landed
in v1.5.1 after the first cut shipped without them and immediately read as
broken — they fell through to name text, so `armor/leather` searched for an
item *called* "armor leather". `buy.Categories()` caches the class → subclass
map from the client's own localized names and `SlotsFor()` does slots; **2b's
Filter Builder should populate its dropdowns from those same two, not build a
parallel map.** Subclasses are keyed BY CLASS deliberately: names repeat
("Leather" under both Armor and Trade Goods) and "Mail" exists only under
Armor, so a flat map silently searches a category the user never asked for.

**One note for 2d:** this slice's post-filters all apply together — an implicit
AND. Prefix `and`/`or`/`not` combination is 2d's job, and `CompileTerm`'s
single `filter` closure is the seam it should compose into.

**Watch out for** (all found the hard way):

- `local a, b = cond and f()` silently drops `f`'s second return whenever `and`
  truncates to one value. Cost a half-parsed level range until a test caught it.
- **`GameTooltipTemplate` reuses its `TextLeftN` FontStrings.** Reading them
  "until one comes back empty" walks off the end of the current tooltip into
  whatever longer tooltip was shown before. Bound the loop with `NumLines()`,
  and copy `sell.lua`'s owner → clear → set sequence rather than inventing one.
- **Do not build a filter on `GetItemInfo` at all if you can avoid it.** The
  fully-stacked filter took four attempts: fail-closed emptied every page,
  fail-open filtered nothing, and two different theories about which return
  slot holds the stack count were both wrong in the field. What finally worked
  was letting the user state the number (`stack 20`) so no item lookup is
  needed, with a page-derived fallback for the bare form. When a 1.12 API is
  this unreliable, prefer a design that does not need it over a cleverer way
  of calling it.
- **`GetItemInfo`'s return list is not the same on every client** -- vanilla
  1.12 has no `itemLevel`, so every slot after position 3 shifts by one
  against later clients. Never index it positionally. `stackCount` is the last
  NUMBER in the list on both, which is how `buy.StackCountFromItemInfo` finds
  it.
- **`canUse` from `GetAuctionItemInfo` is `1`-or-`nil`** — `nil` means cannot
  use, not "unknown". Treating nil as unknown made a warning unreachable for
  the entire life of the Buy tab.

**Also fixed on the way:** `core/buy.lua` was folding every browsed listing
into the price DB, which `core/scan.lua`'s `RecordVisiblePage` already does for
every result page anyone looks at — same event, identical values. The duplicate
is gone; the price feed still works because it always came from scan.lua.

### 2b — Filter Builder tab — ✅ **DONE** (v1.7.0)
Form-driven query construction, reached from the **Results / Builder** switch
on the Buy tab (the Shopping Lists sidebar is untouched). Layout mirrors aux's:
Name / Exact / Level Range / Item Class / Subclass / Slot / Min Quality /
Usable on the Blizzard-filter side, post-filter primitives on the other.
Search / Export / Import, same as aux — but the user never types polish
notation, which was the whole point.

**How it stays honest — round-trip is the acceptance test.** The form emits a
string, the string parses back to a term, and the term repaints the form.
That is checked **by value, not by string**: `buy.TermsEqual` compares all 13
term keys (normalising `false` → `nil`), so a cosmetic difference in how the
string was spelled can't mask a dropped field. 15 engine-level cases cover it,
and they were written *before* any UI existed on top.

**Settled while building it:**

- **Dropdowns read `buy.Categories()` / `buy.SlotOptions()`** — the same maps
  `armor/leather` searches through, exactly as this file asked. No parallel
  category table exists anywhere in the addon.
- **Class gates Subclass gates Slot.** Changing the class repopulates the
  subclass list and drops a subclass the new class doesn't offer; same one
  level down. `SetOptions` enforces that itself rather than trusting the
  gating callback — a sabotage proved the callback alone would have hidden it.
- **`buy.TermToQuery` emits in a fixed order**: name first, then
  class/subclass/slot, then quality/level/usable/buyout/stack, **tooltip
  last**. Not cosmetic — `container/bag/tooltip/8` only disambiguates from
  `container/bag/8` if tooltip text can't be mistaken for a trailing category
  token.
- **The form edits ONE term.** `+ OR` appends it to the query box as a
  semicolon term, which is the only combinator the engine has today.
  Prefix `and`/`or`/`not` over post-filters is still **2d's** job, and the
  builder's nesting-free promise above is a claim about 2d's UI, not this
  slice's.
- **Dropdowns are hand-built from `Frame` + `Button`**, following
  `MakeHSlider`'s precedent, rather than inheriting a `UIDropDownMenu`
  template whose 1.12 helper surface we couldn't verify against the Turtle UI
  source. Popups parent to `ui.frame` so they aren't clipped by the panel;
  one module-level `openDropdown` closes the previous one.
- **Repainting the form must not fire the gating callbacks** — `SetValue(v,
  silent)` and a `ui.builderPainting` re-entry guard, or importing a query
  clears the very fields it just set.

**Precursor shipped with it:** `util.ItemInfo(link)` normalises `GetItemInfo`
into a named table (`name, link, quality, minLevel, type, subType, stackCount,
equipLoc, texture`) by locating `stackCount` as the last number in the list, so
the vanilla-vs-later 9/10-value shift can't bite again. `sell.ScanBags` and
`buy.StackCountFromItemInfo` both route through it; **no caller indexes
`GetItemInfo` positionally any more**, and the suite runs under both layouts.

### 2c — Saved Searches tab — ✅ **DONE** (v1.10.0, as 2j)
Favorites and Recent, styled after aux's split-column layout. Hover for a
formatted tooltip, left-click to run, right-click for a context menu,
shift-click to copy the query into the search box, shift-right-click to
append to whatever's already there. No Auto Buy toggle (decided above).

### 2d — Full primitive set + boolean combinators — partly **DONE** (v1.10.0)
`and` / `or` / `not` shipped with the post-filter system in 2i, over the
clause list rather than as prefix polish notation. `seller` and `left` (plus
`min-level`, `max-level` and `rarity`) landed in 3c (v1.22.0). What remains
here is stat-suffix matching — the combinator
work itself is done.

### 2d (original scope) — Full primitive set + boolean combinators
Everything from 2a's primitive set generalized under full `and`/`or`/`not`
prefix-notation combination, plus stat-suffix matching (the
`+3 stamina/+3 agility` wristband-suffix case) and any remaining aux
primitives worth carrying over.

### 2e — Blizzard-style Category Navigation Tree — ✅ **DONE** (v1.8.0)
(Numbered 3e when it was written; it shipped inside Phase 2, out of order,
because the user asked for it ahead of 2c/2d.)

The Buy tab's left column now opens as a collapsible **class > subclass >
slot** tree (Weapons > Two-Handed Swords; Armor > Leather > Chest). Clicking
a node searches it immediately. A **Categories / Advanced** toggle at the top
swaps between the tree and the original Shopping Lists sidebar (lists +
recent searches); the choice persists per character, tree by default.

**Settled while building it:**

- **Tree picks COMPOSE with the query box.** A click parses the box's first
  term, swaps only class/subclass/slot, regenerates and searches — so typed
  name/quality/stack/tooltip filters stay applied on top of the picked
  category, and extra `;` terms are regenerated untouched (TermToQuery
  round-trips by value, so this loses nothing). This is the "feed cleanly
  into the underlying search engine" requirement, and it is pinned by a
  sabotage-verified test.
- **The tree reads `buy.ClassOptions` / `SubclassOptions` / `SlotOptions`** —
  the exact three calls the Builder's dropdowns use. Still no second category
  list anywhere.
- **The paint paths are mode-guarded**, not just the widgets hidden: every
  search refreshes the recent list, and an unguarded sidebar repaint would
  `Show()` its rows straight over the tree. A test drives a search from the
  tree and asserts the sidebar stays down.
- **"Advanced replaces the tree"** was first read as a left-column swap.
  **Superseded by the 2g redesign below**, where Advanced replaces the whole
  content area. The tree itself carried over unchanged and is now the default
  view's left column, which is what it should always have been.

### 2g — Blizzlike default view + Advanced (Phase 2 of the Buy redesign) — ✅ **DONE** (v1.9.0)

Approved from a mockup before any code. The Buy tab now has two faces:

- **DEFAULT** is the stock auction house: Name / Level Range / Min Quality /
  Usable / Search, the category list on the left, and gold + Bid / Buyout /
  Close along the bottom. Rows have no buttons — click to select, act from the
  bottom bar. Two Aegis columns survive: **Unit** and **% Mkt**.
- **ADVANCED** (one button, in the slot Blizzard used for "Display on
  Character") swaps in the query box, the Shopping Lists sidebar and the
  Filter Builder. **< Back** returns.

**Settled while building it:**

- **Everything on the strip composes into ONE term.** `ui.DefaultTerm()`
  folds Name + level range + quality + usable together with the category the
  tree has selected, and hands it to the same `buy.TermToQuery` /
  `buy.CompileTerm` the typed language uses. That is what makes "the Name
  field searches within the selected category" true with no special casing —
  the category is just three more fields on the term. It is also why clicking
  through categories no longer resets the rest of the strip.
- **The category is STATE, not text.** 2e wrote picks into the search box;
  that box is now Blizzard's Name field, so a pick would have overwritten what
  the user typed. Held in `ui.buyCatClass/Subclass/Slot` instead and merged at
  search time.
- **The mode switch round-trips through the term**, both directions. Post-
  filters the default view cannot express are dropped on the way back **and
  said out loud** in the status line. A filter you cannot see but that still
  narrows results is the failure mode this whole area keeps producing (see the
  empty-page message in 1.8.0), so it gets an explicit test.
- **Max moved to Advanced and is no longer READ in default mode.** Hiding the
  box alone would have left a stale value silently filtering — the same class
  of bug. Gated at the read, with a test that drives it both ways.
- **Selection compares index AND name.** The page can be re-queried between
  the click and the button press; matching on index alone would light up
  whatever slid into that slot. A sabotage that only removed the name half
  passed at first — the test was missing, not the code — so the stale-page
  case is now covered directly.
- **`BuildResultRow` grew a `selectable` flag** rather than being forked. The
  Crafting tab shares it and keeps its per-row buttons; only Buy rows get the
  selection tint.
- **Import was removed** at the owner's request, and with it
  `ui.BuilderImport` — an unreachable function is worse than a missing one.
  The round-trip acceptance test now drives `ParseTerm` → `BuilderSetTerm`
  directly, which is what Import called anyway once it had read the box.

**Still to come in this redesign:** Phase 3 rebuilds the Advanced side to the
approved mockup — Recent/Favorites with right-click promotion and a reorder
menu, and the component/post-filter builder (stacked entries are ANDed;
`and`/`or`/`not` only to override that). Phase 4 is the tooltip parser's
abbreviation expansion. Both need the one parser change already identified:
`tooltip` must take a single token instead of swallowing the rest of the
term, so several tooltip clauses can coexist.

### 2i — Post-filter clauses + combinators — ✅ **DONE** (v1.10.0)

The parser change 2g flagged, plus the semantics the owner specified.

- **`tooltip` takes ONE token**, like `quality` and `level`, instead of
  switching into a sticky mode that swallowed the rest of the term. That is
  what makes a second tooltip clause possible at all. Tokens split on `/`
  only, so multi-word values still work and `container/bag/tooltip/8` is
  untouched. It also retires the "tooltip must be emitted last" rule in
  `TermToQuery`.
- **The term carries an ordered `post` list** of clauses and combinators.
  `buy.CompilePost` folds it **left to right with no precedence**:
  consecutive clauses AND, an explicit `or`/`and` overrides, `not` is unary
  over the clause that follows. No precedence table means nothing to
  memorise, and the builder lists the clauses in the order they apply.
- **Compiled once per search, not per row.** `TooltipContainsAt` is the
  expensive call in this addon and a page holds 50 rows, so the expression is
  built in `CompilePost` and only evaluated in the closure — with
  short-circuiting, so an `or` that is already satisfied skips a tooltip scan
  it does not need.

**The correction worth recording:** the original Phase 4 spec asked for
`stam/agi` inside ONE tooltip value to mean AND. That collided head-on with
`/` being the term separator. The owner's clarification removed the conflict
entirely — two stats are two clauses, and stacking already means AND. No
change to what `/` means, and no existing query changed meaning. Worth
remembering that the cheapest fix for a syntax collision was to not need the
syntax.

### 2j — Saved Searches — ✅ **DONE** (v1.10.0)

Recent | Favorites, sharing the results area as a third view. Right-click a
recent to promote it; right-click a favorite for Move Up / Move Down /
Delete; left-click runs, shift-left-click loads into the Builder.

Favorites are an **ordered array** in SavedVariables, and every mutator
preserves that order: promoting appends rather than sorting, re-promoting an
existing entry is a no-op rather than a jump to the bottom, and the ends of
the list are walls rather than wrap-arounds. The order is the user's, so
nothing is allowed to quietly rearrange it.

### 2k — Buy tab layout pass — ✅ **DONE** (v1.11.0)

Reported against the concept with screenshots; every finding fixed.

**All three "widget is somewhere it cannot be used" bugs had one cause:** a
widget anchored to ANOTHER widget that later moved. The view switcher was
pinned 232px right of the Search button, which was correct until 2g moved
Search to the right edge and threw all three tabs clean off the window. The
pager and the Advanced button were both anchored to the panel's top-right,
so they landed on top of each other. Both now hang off the panel at fixed
corners, and three tests assert the anchor RELATIONSHIP rather than a
coordinate, so the next widget that moves cannot drag them with it.

**Advanced has no left column.** The Shopping Lists sidebar is gone, and with
it `+ Add` / `Rename` / `Del` / `Search entire list`, the `Max` box and
`Add to list`. The Builder and Saved views span the full content width, which
is what the concept shows and what was clipping the form's headings.

The list ENGINE (`buy.Lists` and friends) is deliberately left in place and
still tested. The saved data is untouched, so nothing a user built is lost
and re-homing the feature costs a UI rather than a rewrite.

**Placeholder components are LABELLED, not silent.** `item`, `min-level`,
`max-level`, `rarity`, `seller`, `percent`, `vendor-profit`, `left` and
`disenchant-profit` are in the dropdown so the finished shape is visible, and
they parse and round-trip so a query containing one survives an edit. They
narrow nothing yet, so each is marked `(soon)` in the list and drawn dim with
"not wired up yet — ignored" in the Post Filter. **This addon has twice
shipped a filter that silently matched nothing**, so an unimplemented
component that quietly did nothing was not an option.

> Superseded in part by **3c (v1.22.0)** and **3f (v1.25.0)**: `min-level`,
> `max-level`, `rarity`, `seller`, `left`, `percent` and `vendor-profit` are
> implemented and no longer dim. `item` and `disenchant-profit` still are.

> ⚠️ **Import is absent from the bottom row on purpose.** The concept PNG
> still shows it because that image predates the "you can remove the import
> button" instruction. `ui.BuilderImport` went with the button. One line to
> put back if the concept is the intent.

### 2l — Concept-parity polish — ✅ **DONE** (v1.12.0)

> **⚠️ TWO decisions below were later reversed.** The button colour, in
> v1.14.0 (see 2n) and again in v1.15.0 (see 2p). The removal of the +/- fold
> glyphs, in v1.15.1 (see 2q) — that argument held for a one-level list and
> this tree turned out to nest three.
>
> **⚠️ The button-colour decision below was REVERSED in v1.14.0 — see 2n.**
> The analysis still holds (the plates really were vanilla's own art, and
> matching the concept really did mean drawing every button ourselves); the
> conclusion changed once the question was the whole addon rather than one
> tab. Everything else in this entry stands.

**Settled: the button colour was never a bug.** The warm red-brown plates are
vanilla's own `UIPanelButtonTemplate` art, which is what every stock button
looks like unskinned. The concept's flat dark plates with thin gold borders
were CSS in an HTML mockup; no vanilla template produces them, and matching
them would mean backdrop-drawing every button in the addon, not just the Buy
tab's. **Decision: keep the stock art**, since "the default view looks like
the stock auction house" is the whole premise of 2g, with a subtle accent tint
on Advanced and Build only so the two non-stock actions read as different.
Recorded here because it will look like an unfixed bug to anyone comparing
the concept PNGs to a screenshot.

Everything else in the pass:

- **Bid entry reuses the Sell tab's g/s/c control** rather than a second
  implementation. That widget emulates the plain box's GetText/SetText, so
  `SetMoneyBox` and every existing caller worked against it untouched.
- **The Browse tree follows Blizzard's shape**: plates on top-level rows,
  bare indented children, a bordered well, blue selection bar, and **no +/-
  fold glyphs** — the stock list signals expansion by highlighting the parent
  and showing its children.
- **`MakeDropdown` gained a `noAll` flag.** Component opts out; Class /
  Subclass / Slot / Quality keep the row, because "no filter" is a real
  choice there and "all components" is not.
- **One function owns component colour** (`ui.ComponentColor`), read by both
  the dropdown's selected text and the Post Filter line, so the two cannot
  drift.
- **Clear empties the search bar too.** Leaving the query behind meant the
  next Search ran something the form no longer described.
- **Import came back**, reversing the removal in 2g. The reasoning changed
  with the feature set: the Builder used to be somewhere you only LEFT from,
  and 2j's shift-click made it somewhere you LAND, at which point a
  hand-typed query had no route into the form.
- **Anchors, again.** The component value box had a fixed width that ran off
  the frame; the Saved columns sat at fixed offsets. Both are anchored on two
  edges now and stretch with the window. That is the same class of bug as
  2k's off-screen tabs — **fixed offsets into a resizable frame keep
  producing it**, so prefer two-edge anchors for anything that should fill
  its space.

### 2m — Buy tab fixes & layout — ✅ **DONE** (v1.13.0)

- **The paint guard belongs in the paint function, not at the switch.** A scan
  finishing after you left Results repainted the list straight through Saved
  Searches or the Builder, because the guard sat where the view was changed
  and the reply arrived later. `ui.UpdateBuyList` and `ui.RefreshBuyStatus`
  now each check the visible view themselves and return early. **This is the
  third time this exact shape has bitten** (sidebar rows, the pager, now the
  results list). An async callback can fire in any view; only the paint
  function knows which view is on screen when it actually runs, so that is
  where the check has to live.
- **`ui.DoBuySearch` switches on `~= "results"`**, not `== "builder"`. It only
  ever left the Builder, so a query launched from Saved Searches ran with
  nothing visible to show it.
- **Clipping, again — the same 2k/2l class.** The category well's backdrop
  draws ~6px outside its scroll frame, so a bottom offset that looked correct
  cut through the gold total; the results column started at `SIDE_W + 24`,
  inside that same border. Well and column now allow for the border.
  **Backdrop borders extend past the frame rect** — budget for them when
  anchoring anything against a bordered well.
- **`MakeMoneyDisplay`** — read-only coin readout for the gold total, built on
  `UI-MoneyIcons` with `SetTexCoord` (one sprite sheet, not three files).
  It is anchored by its **copper** coin and grows leftwards, so the figure
  never shifts the layout as your gold changes, and denominations above the
  value are hidden.
- **`+ OR` removed.** It appended a bare combinator with nothing decided about
  its operands; the Component dropdown already carries `and` / `or` / `not`
  next to the clause they apply to. `BuilderExport(true)`'s append mode stays
  — that is a separate path and still covered.
- **Bid / Buyout / bid entry hide outside Results.** `MakeMoneyGSC` needed
  `Show`/`Hide` for this: its coin textures parent to the PANEL, not to the
  boxes, so hiding the three edit boxes alone leaves three coins floating.
- **The favourite menu opens below its row**, inside the favourites column.
  1.12 has no menu-flip logic — placement is whatever you anchor, so anchor
  it somewhere it cannot cover either column.

### 2n — Custom button art — ✅ **DONE** (v1.14.0)

**This REVERSES 2l's "keep the stock art" decision. Read that entry first.**
2l settled that the warm red-brown plates were vanilla's own
`UIPanelButtonTemplate` and not a bug, and that matching the concept would
mean backdrop-drawing every button in the addon. Both of those statements are
still true — what changed is the answer, not the analysis. 2l was weighing the
concept against *the Buy tab's* Blizzlike premise; applied to all six tabs,
the concept art is simply what the addon was always meant to look like, and
the half-and-half state 2l implicitly preferred reads as an unfinished port
rather than a deliberate choice.

- **`ui.MakeButton(parent, kind, name)`** is a drop-in for the template: it
  answers `SetText` / `GetText` / `GetFontString` / `Enable` / `Disable` /
  `IsEnabled` the same way, so the 56 call sites changed only their
  constructor.
- **Two kinds, from the concept's own stylesheet.** `primary` is the deep red
  plate with the gold label (`.btn`), and there is exactly ONE per area — the
  thing that area exists to do. `quiet` is the dark neutral plate
  (`.btn-quiet`) and is the default.
- **The four states are now ours to draw.** Normal, hover, pressed and
  disabled, plus the 1px label nudge on press. Disabled is the one that
  matters: the template supplied it free, and a hand-drawn plate that skips
  it ships a button which looks live and silently ignores clicks. It is
  DERIVED from each kind's colours rather than hand-picked, so a palette edit
  cannot leave it behind.
- **Scripts close over their own button rather than reading `this`.** `this`
  is right for a handler SHARED across frames, but it is only set when the
  CLIENT invokes the script — and the Filter Builder hides its action buttons
  from Lua the moment it builds them. That path errored on a nil `this`.
- **pfUI**: the plates ride on pfUI's backdrop child, resolved at PAINT time
  because it does not exist until `skin.Apply` runs. The generic `SkinButton`
  pass skips ours, which would otherwise double-border a button that already
  has a backdrop. Same arrangement the sub-tab pills use.
- **`ui.TintButton` is gone.** It vertex-coloured template textures; there are
  none left. `ui.SetButtonKind` replaces it.

**Process note, because this bit twice in one session.** The bulk conversion
was first attempted with a DOTALL regex over the whole file. Its `.+?` spanned
from an unrelated `CreateFrame("Button", ...)` to the next template match and
ate two buttons' parent arguments — leaving valid Lua that still took clicks
and still painted, attached to nothing. **Every test passed.** Do bulk edits
line-oriented, with a bounded window, and diff-audit every deletion; and note
that the suite could not see this class of bug at all until 2n added a
parentage check and a source lint for a Button constructed without a parent.

### 2o — Post-1.14.0 cleanup — ✅ **DONE** (v1.14.1)

From screenshots of the button conversion in-game.

- **Fixed offsets into a resizable frame, a FOURTH time** (2k, 2l, 2m, now
  here). The default filter strip chained left-to-right off the Name box
  while Search and Advanced were pinned a fixed distance from the right
  edge, and nothing joined the halves — so they overlapped, printing Search
  through the "Usable" label. The strip is now built from BOTH ENDS with the
  Name box absorbing the slack. **The rule, restated because writing it down
  three times has not stopped it: exactly one widget in a row may stretch,
  it anchors on two edges, and every fixed-width widget hangs off an end.**
- **Empty space needs a container.** Saved Searches and the Builder both ran
  out of content partway down and left bare window below. That is not a
  layout bug — a top-aligned form is normal — it is a *missing well*: with
  nothing drawn around it the leftover space reads as a hole in the window.
  `ui.MakeWell` now factors out the pattern the category tree already used.
- **A child frame draws above ALL of its parent's regions.** Putting a well
  on the Builder frame buried every label on it, because those were font
  strings of that same frame. The text moved to a content layer created
  after the well. Worth remembering before adding a background to any frame
  that already carries its own font strings.
- **Lists ask their height at paint time.** Saved Searches was pinned at 12
  rows however tall the window was. Note the floor passed to `ui.RowsFor`
  must be a real row count, not 1: a two-edge-anchored frame reports height
  0 until the client lays it out, and a floor of 1 paints a single row on
  that first pass.
- **The active view button is marked** by swapping it to the primary plate.
  `LockHighlight` used to do this and silently stopped working at 1.14.0 —
  it drives a template highlight texture our buttons do not have.
- **Button borders went dark.** See the CHANGELOG for why they are not
  literally the concept's `#14120f`: the concept's panel is lighter than its
  buttons and ours is darker, so an exactly-black edge erases the outline
  instead of defining it.

### 2p — Mockup parity + multi-buyout — ✅ **DONE** (v1.15.0)

**Time Left IS available on 1.12 — this closes a long-open question.**
`GetAuctionItemTimeLeft("list", i)` is called by stock 1.12.1 FrameXML on the
line immediately after `GetAuctionItemInfo` in `AuctionFrameBrowse_Update`
(verified against five independent 1.12.1 Interface mirrors). It returns 1..4,
rendered through `AUCTION_TIME_LEFT1..4`. It is page data the client already
holds, not an item-cache lookup, so it adds no per-item query to the scan and
does not engage HARD RULE 16. **The `left` filter component is unblocked.**

- **The mockup supersedes `design/07-buy-tab.png` where they disagree.** The
  older PNG styles the primary button `#5a1414` (deep red); the "A - Default
  view" mockup draws Search and Buyout warm brown-gold and adds a purple
  Advanced. 1.14.0 took the red from the PNG. Written down because this has
  now flipped once and the two files still both exist.
- **Advanced is a third BTN_KIND, not a tint.** 1.14.0 removed a purple vertex
  tint for reading as a smudge; that was correct, and is a different thing
  from a plate of its own.
- **MIN_W 832 -> 1000, from arithmetic rather than taste.** `ui.StripFitsAt(w)`
  computes whether the sidebar, the fixed-width strip and the right-hand pair
  fit; the first attempt at this pass set 1020 and the function immediately
  showed it was ~14px short. **Make the constraint computable, not a number
  someone did in their head** -- that is the only reason the overlap did not
  ship a third time.
- **Category rows opt out of the pfUI skin** via the existing `aegisNoSkin`,
  not a new flag. They are Buttons (a row must be clickable), so pfUI's
  SkinButton plated every one and erased the plated-parent / bare-child
  distinction the tree uses. Result rows were never affected because they are
  Frames. A first attempt added a second, redundant opt-out mechanism before
  noticing `aegisNoSkin` already meant exactly this.

**Batch buyout — the design, because the naive version spends real gold
wrongly.** 1.12 has no bulk buy and no auction ID. Each buyout is
`PlaceAuctionBid` against an INDEX into the currently-held page; the purchase
removes that auction and re-sends the page, shifting every later index. So:

- **Identity is unachievable and unnecessary.** Eleven identical Linen
  Bandages at 8c cannot be told apart, and the buyer does not care which they
  get. The property that matters is: *every purchase matches the (name, count,
  buyout) of a ticked row, and no more than the ticked count of each.*
- **The batch is a multiset of fingerprints**, and each step re-derives the
  index from the LIVE page. Nothing is ever bought against a remembered index.
- **It steps from `ReadPage`**, once the page invalidated by the purchase has
  been re-read -- never straight after `PlaceAuctionBid`.
- **Anything unexpected aborts**: a fingerprint that is owed but absent stops
  the batch and reports what completed. Substitution is never acceptable.
- **Gold is re-checked before every purchase**, not only at the start, because
  mail/repairs/vendors move money while the AH is open.

### 2q — Mockup second pass — ✅ **DONE** (v1.15.1)

- **`ui.RowsFor`'s `minRows` was two different ideas wearing one name**, and
  the collision produced a table that drew over the bottom of the window. It
  meant both "the answer when the frame has not been laid out" (correct, and
  what 1.14.1 raised from 1 to 12 for Saved Searches) and "never paint fewer
  than this" (wrong, and what forced eleven 26px rows into space for eight).
  A measured fit now always wins; `minRows` applies only when the height is
  0. Every list in the addon shares the function, so this was one edit.
  **When a parameter has to be explained with "except when", it is two
  parameters.**
- **NO SELLER COLUMN**, deliberately and against the mockup. `owner` is nil
  until the client resolves the name, so it was blank on nearly every row.
  The FIELD is still read — it sets `r.mine`, which dims your own rows and
  keeps them out of a buyout batch — so do not delete it as dead code when
  the column is gone. Freed width went to the Lvl / Time Left gap.
- **`ui.ColumnsFitAt(w)`** joins `ui.StripFitsAt(w)`. Removing a column moved
  every offset after it, and the failure mode is the last column drawn under
  the scrollbar. Both are asserted to have teeth: they must REJECT a width
  that genuinely does not fit, or they are decoration.
- **The table's box encloses the headings.** It wrapped the scroll frame
  alone, so the headings floated above it. Its right edge is flush with the
  scroll frame's, because FauxScrollFrameTemplate hangs the scrollbar outward
  from exactly that line — a positive offset there puts the box back under
  the scrollbar.
- **`ui.FlattenEditBox`** strips `InputBoxTemplate`'s three textures and
  applies our own plate. The template stays for its cursor, selection and
  focus behaviour; only what it DRAWS is replaced. Textures are found via
  `GetRegions()`, not `$parentLeft` etc., because most of these boxes have no
  name for `getglobal` to resolve.
- **Fold glyphs restored, reversing 2l.** 2l reasoned from the stock 1.12
  filter list, which is one level deep; ours is three (Armor > Leather >
  Chest), and highlight-the-parent cannot express which of two open levels
  you are in. Only EXPANDED rows are marked — a `+` on every collapsed row is
  noise the mockup does not draw either.
- **No box around the category tree**, and a selected leaf is bright text
  rather than a highlight bar. The mockup boxes the results table and nothing
  else.

### 2r — Mockup structural parity — ✅ **DONE** (v1.16.0)

**The strip's left edge was the whole problem.** Every previous pass treated
the Buy tab as "sidebar on the left, everything else to its right" and tuned
details inside that frame. The mockup is not built that way: the control strip
spans the full panel width at its left edge, and BOTH columns hang below it,
sharing that edge with the Name field. Once that moved, half the remaining
differences stopped being differences.

Worth remembering as a method point: four passes of detail work did not close
a gap that one structural change did. **When repeated polish is not converging
on a reference, check whether the two are built on the same skeleton before
tuning anything else.**

- **The columns are deliberately unequal lengths.** Table short, tree long.
  **REVERSED in v1.17.0 — see 2s.** The table fills its height now. The
  mockup's short table is one screenshot with five results; a real page has
  fifty, and rows are what the tab is for.
  Ours had them the wrong way round — the table nearly reached the action bar
  while the tree stopped halfway down.
- **`MIN_W`: the binding constraint MOVED.** It was the strip; it is now the
  result columns. Moving the strip to the left edge gave it back ~190px and it
  now fits 832. The columns' floor is ~970, so 1000 stands. Both fit functions
  assert they still REJECT a too-narrow window, so neither is decoration.
- **Variable row heights in the tree.** `FauxScrollFrame` assumes uniform rows,
  and that is usually the end of the discussion — but its offset is counted in
  ROWS, not pixels, so a ragged list works provided the visible count is
  derived by ACCUMULATING heights rather than dividing by one. Plated rows are
  taller than bare ones, which is what gives the mockup's list its rhythm.
- **`% Mkt` at exactly 100% went from yellow to neutral.** Yellow is a warning
  colour and market price is the unremarkable case. Green and red carry
  meaning because the middle does not.
- **Selection in the tree is a lighter plate plus a gold edge**, not a
  blue-green highlight bar. The bar appears nowhere in the reference.

**Known un-matchable, do not keep trying.** The mockup is HTML and uses Cinzel
for headings and buttons; 1.12 offers only the game's font objects and cannot
load a face. Weight and colour are matched; the typeface is not, and that is
final unless someone ships a font with the addon.

### 2s — Alignment, clipping and colour — ✅ **DONE** (v1.17.0)

- **The BROWSE scrollbar overlapped the results box**, because
  `FauxScrollFrameTemplate` hangs it OUTWARD from the scroll frame's right
  edge — into the gutter the table starts in. Hidden, as the mockup has it.
  **Hiding it once is not enough**: `FauxScrollFrame_Update` re-shows the bar
  whenever content overflows, so `Show` is neutralised as well. The wheel
  still scrolls, because the template's OnMouseWheel drives the bar's VALUE
  and a hidden frame still holds one.
- **The table fills its height, whole rows only.** This REVERSES 2r's "table
  is the shorter column". Rows are not the scroll frame's scroll-child, so
  nothing clips a partial row — it would draw over the count line — which is
  why the count floors and is asserted to.
- **`ui.TableSlack()` exists because `ui.TableAreaAt` was not enough.** The
  area check passes just as happily for a table that stops halfway up; only a
  direct measure of the dead band below it can tell the two apart. Worth
  remembering when writing a geometry assertion: check the thing you changed,
  not a thing that merely correlates with it.
- **The gold readout is left-aligned and grows rightward**, reversing the
  1.13.0 choice to anchor it by its copper coin. That existed so a growing
  total could not shove the layout; on the left margin nothing is to its
  right. Blizzard hides denominations above the value, so the margin anchor
  moves to whichever denomination is leftmost — otherwise 43 copper leaves a
  hole.
- **`% Mkt` at 100% on every row is NOT a bug.** Market value is a weighted
  median of daily minimums; an item first seen in the current scan has a
  market value equal to that page's cheapest listing, so the ratio is the
  number against itself. Verified rather than "fixed". It resolves itself as
  the DB gains history.
- **"Miscellaneous" first under Armor is the client's own subclass order**,
  and the stock AH does the same. Left alone: this view is the Blizzlike one.

### 2t — Category selection, list sizing, one check box — ✅ **DONE** (v1.18.0)

- **Selecting a category no longer searches.** `ui.CatApply` sets a pending
  selection and a status line; only Search issues the query. The results
  already on screen are LEFT there rather than cleared — a fold click that
  blanked a real search is worse than one that leaves it, and the status line
  names the pending selection so the rows cannot be mistaken for it. Decided
  once, recorded here, and written in the code at `ui.NotePendingCat`.
- **The dead band under the results and the categories cut off at the smallest
  window were ONE bug, not two.** `ui.TableAreaAt` subtracted 22 where the
  panel's real vertical inset is 108 — an 86px error — so both lists sized
  themselves from a height that was wrong in opposite-looking ways. `GetHeight()`
  on a two-edge-anchored frame returns the LAST LAID-OUT height, one frame
  stale, which is why measuring looked right and was not. Everything now
  derives from `ui.frame:GetHeight()`, the one number that is explicitly set,
  via `ui.PanelHeightAt`. At MIN_H all eleven top-level categories fit — the
  arithmetic, not a nudge: 262px available against 242px needed.
- **One check box helper, `ui.MakeCheckBox`, behind every check box.** Two
  separate failures met here. A `SetBackdrop` whose `edgeSize` approaches the
  frame size CANNOT draw a border — two corner pieces of `edgeSize` square do
  not fit across a 14px frame — so it drew a cross; and pfUI reskins anything
  reporting `CheckButton`, so under the skin it became a circle. Borders are
  four 1px textures, and `aegisNoSkin` opts out of the pfUI pass.
- **The helper does NOT override `SetChecked`/`GetChecked`.** A `CheckButton`
  toggles itself before `OnClick` runs and every handler in the file is written
  against that. Shadowing those two methods with our own flag leaves the
  widget's state and ours disagreeing, and each handler silently reads the
  wrong one. Only the ART is replaced: the tick is the widget's own CHECKED
  texture, so the client shows and hides it and it cannot drift. **Do not
  "simplify" this into a private boolean.**
- **Field labels are placed by ONE rule.** "Name" hung off the panel while
  "Level Range" and "Min Quality" hung off their controls — two rules, so no
  single number could hold the three in line. Every label now hangs off its own
  control, and the controls already share one top edge. When a layout will not
  come into line after repeated nudging, count the rules before adding another
  constant.
- **Min Quality is coloured from `ITEM_QUALITY_COLORS`**, FrameXML's own table,
  so a Rare here is the blue a Rare is everywhere. "All" stays neutral — no
  filter is not a quality. The button's colour is applied inside
  `RepaintButton` via `aegisTextColor`, not by the caller: that function runs on
  every hover and press, so a colour set from outside is wiped by the first
  mouseover.
- **Bid-only auctions sort last in BOTH directions** — verified by running the
  code, not by reading it. The nil guards in `ui.SortResults` sit BEFORE the
  direction branch deliberately; folded into it, a descending sort floats
  priceless rows to the top where they read as the most expensive.
  `tests/sort_results.lua` pins this, and was itself checked against two
  sabotaged copies of the function.
- **`tests/` now exists, in the repo.** The previous test harness lived in
  `/tmp`, was never version-controlled, and was destroyed with the container —
  twice. Tests extract the function under test from the source at run time
  rather than copying it, so they cannot pass against a stale duplicate.
  Nothing in `tests/` is in the `.toc`; the 1.12 client never sees it.

### 2u — Test harness, rebuilt in the repo — ✅ **DONE** (no version change)

Not a release: nothing in `Aegis_Exchange.toc` changed, so there is no version
bump and no CHANGELOG entry. `./tests/run.sh`; see `tests/README.md`.

- **The lint layer catches what no test can**, because Lua 5.1 (what we test
  with) is more permissive than Lua 5.0 (what we ship to). `lua50.py` flags
  `string.match` / `#` / `%` / `select()` / `hooksecurefunc` / modern event
  handlers, all of which `luac5.1 -p` compiles happily and the unit suites run
  happily. `upvalues.py` is the 32-ceiling — **5.1's limit is 60**, which is
  why v1.16.0 passed everything and would not load. `definitions.py` is the
  scripted-edit-ate-a-function guard, which has earned its place three times.
- **`lua50.py` has a self-test, and half of it is false POSITIVES.** `%`
  appears in every `string.format`, `#` throughout the comments. A checker that
  flags those gets ignored within a day, which is the same outcome as not
  having one.
- **`sabotage.py` is the answer to "is this suite actually testing anything".**
  It plants a real bug in a throwaway copy and requires the named suite to
  fail. It found two blind spots on the day it was written: the simulated
  client only ever returned the **vanilla** 9-value `GetItemInfo`, so a
  hardcoded index passed every `util.ItemInfo` assertion (fixed by making the
  stub able to return both client shapes and running the same checks against
  each); and deleting the batch's up-front gold check was invisible, because
  the per-purchase check also refuses — the case that separates them is
  affording SOME of the selection, where the missing check means a partial
  spend.
- **What the harness deliberately cannot do is anything visual.** Frames in
  `tests/support/wow.lua` answer every method and draw nothing, and that is on
  purpose: faking geometry would make layout look testable when it is not. A
  green run says nothing about whether the window is right.
- **The simulated client's `getglobal` reads `_G`**, not a side table. Backing
  it with a private registry made lookups of client constants come back nil —
  a difference from the real client that a test would have "proved" was fine.

### 2v — Advanced view: concept parity — ✅ **DONE** (v1.19.0)

- **Advanced anchored to the RESULTS column, not the panel.** `RX` is where the
  results table starts *because the category tree sits to its left*. Advanced
  hides the tree, so anchoring its content at `RX` left the tree's whole width
  as dead window. `AX = BUYL.side_x` is the Advanced origin now, and
  `ui.BuildFilterBuilder` / `ui.BuildSavedSearches` take it as `advLeft`.
  **When one mode hides a column, the other mode's origin is not a constant it
  can borrow.**
- **`ui.buyHdrTicks` was in no show/hide list at all** and drew across every
  view for several releases. It escaped because it is an ARRAY of textures
  rather than a single widget, and the lists hold widgets. `tests/lint/
  modebits.py` now enumerates every `ui.buy*` assigned in `BuildBuyTab` against
  the union of the lists and fails on anything unaccounted for — with the
  allowlist split into "not a widget" and "deliberately always shown", each
  needing a reason. It reproduces the original bug when the hide loop is
  removed.
- **There is deliberately no "handled by a loop" allowlist in that lint.**
  Widgets raised by a `while` are NAMED in it, so the scan finds them anyway;
  exempting them would exempt exactly the names most likely to lose their loop
  in a refactor, which is how the ticks went unhidden in the first place.
- **The Builder dropped `buyout` / `stack` / `stack/N` on Build.**
  `ui.BuilderTerm` never read them although `ParseTerm` and `TermToQuery` have
  always handled them, so importing a query and rebuilding it ran a *wider*
  search than the one loaded. Both directions are wired now and pinned by
  `tests/units/builder_term_test.lua` with eight sabotages.
- **`stack/N` and bare `stack` are ALTERNATIVES, not additions.** The form can
  no longer hold both: the size box clears the tick as you type, and
  `BuilderTerm` drops the tick if a size is set. A form that can express a
  state the query language cannot spell will lose one of them at Build, and
  which one is an implementation detail rather than a decision.
- **The illegal pair needed a test that `ParseTerm` cannot produce.** The
  sabotage for "SetTerm ticks both" passed at first, because `stack/20` never
  sets `stackOnly` — the pair only arrives from a hand-built or restored term.
  Worth remembering: a defensive guard needs a test that reaches it by the
  door it actually defends.
- **The Post Filter value box was the last raw `InputBoxTemplate`** in the
  window and rendered as `( )` — the template's own end-caps with nothing
  drawn between. The previous diagnosis (clipped by a fixed width) was wrong
  and its comment said so; both are corrected.
- **pfUI plates every Button, and saved-search rows are Buttons.** Same fix as
  the category tree, `aegisNoSkin`. Unskinned they were always correct, which
  is why only a skinned screenshot showed it.
- **`ui.LayoutBuyTable` lives at FILE scope, reading `ui.buyPanel`.** Nested
  inside `ui.BuildBuyTab` it cost two more upvalues and took that function to
  27 of 32 — the ceiling it has already broken once. The lint's warn threshold
  at 26 is what surfaced it.
- **Layout that depends on WIDTH is recomputed, never fixed.**
  `ui.LayoutViewTabs`, `ui.LayoutBuilderForm` and `ui.LayoutBuyTable` all run
  from the deferred repaint and from the resize grip, because the window spans
  1000–1400px and a constant that looks right at one end looks stranded at the
  other.
- **Syntax highlighting deferred, not dropped.** A 1.12 `EditBox` prints `|c`
  escapes literally, so the concept's coloured query needs an overlay
  FontString swapped on focus — and every path that writes the query has to go
  through one rebuild or the overlay shows something the box does not contain.

### 2w — Advanced view: clipping and proportion — ✅ **DONE** (v1.19.2)

- **The same measurement bug, in the other axis.** `ui.PanelHeightAt` exists
  because `GetHeight()` on a two-edge-anchored frame reports the height it was
  LAST LAID OUT at. 2v then added two width-driven layouts that measured a
  frame — and got the window's creation width, giving a tab strip at 69% and a
  builder column at 29% of a resized panel. `ui.PanelWidthAt` /
  `ui.AdvContentWidth` are the horizontal twins. **Any layout that divides the
  panel must come through them; measuring a child frame is the bug.**
- **A widget hidden by mode still has a position.** The Search button hung off
  the Advanced button in BOTH modes. Advanced hides that button, so Search
  inherited a slot 10px low and 102px in from the edge — and the query box's
  right margin was a constant (172) that had to agree with the button's real
  left edge (196) and could not see it. `ui.AnchorSearchButton` places it per
  mode and the box hangs off the button. **Anchoring to the widget you must
  clear beats a constant computed to clear it.**
- **Filling a column and putting something after it are contradictory.** Every
  control was stretched to fill the left column, then Exact was anchored to the
  Name box's right — so it landed past the column and drew on the next panel.
  The concept had it right all along: TWO widths, a short Name box with its
  checkbox beside it and full-width dropdowns running past. The reserve is
  measured off the label rather than guessed.
- **Clipping coloured text needs the clip BEFORE the colour.** Post-filter
  clauses carry `|cffRRGGBB` escapes; `ui.SetTextClipped` binary-searches on
  `string.sub`, so clipping the assembled string would eventually cut an escape
  in half — literal garbage plus a colour that leaks into every later line. The
  value is clipped first, then decorated.
- **U+21B5 is not in the 1.12 font.** The concept's "↵ adds" rendered as a
  blank followed by "adds". An invisible glyph reads as a layout fault, which
  is worse than a longer label; it says "Enter adds".
- **Centre-anchor a row that is meant to fill its space.** From the left, every
  rounding shortfall pools into one gap on the right and reads as misalignment;
  from the centre it splits evenly and reads as intentional.
- **Geometry is now testable, and tested.** `tests/units/geometry_test.lua`
  pins the insets, `PanelWidthAt`/`PanelHeightAt`, and the derived tab and
  column widths at five window sizes from MIN_W to MAX_W — including that the
  tabs fill without overflowing and that the Name box's checkbox lands inside
  its column. Three sabotages, all caught. This is the part of layout that is
  arithmetic rather than appearance, and it was the part that kept breaking.

#### Decisions recorded rather than left implicit

- **The Results view carries no action row** — Bid / Buyout / Close only. 2v's
  spec said it should also have Search / Build / Import / Clear. Reversed after
  seeing it: Search is redundant beside the strip's own Search button, and
  Import / Clear are Builder verbs.
- **The results table keeps its scrollbar**, arrows outside the well and all,
  which is inherent to `FauxScrollFrameTemplate`. The BROWSE tree's was hidden
  in 1.17.0 because that list is short and the mockup has none; a fifty-row
  results page needs the affordance, and it is identical in the Blizzlike view
  which is already signed off.

### 2x — Advanced view: alignment and spacing — ✅ **DONE** (v1.19.3)

- **Centre on the CONTENT, not the container.** The tab row was centred on the
  panel, but the content is inset 10 left and 12 right, so the row sat 1–2px
  off every well below it — and by a different amount at each window size,
  because `math.floor` discards the remainder. Whenever a thing must line up
  with its neighbours, centre it on THEM.
- **A number measured for one layout is wrong in another.** `BUYL.well_top`
  (56) was measured against the Blizzlike control strip. Advanced has a tab
  strip there, ending at 58 — so the results table's box began 2px above the
  tabs and ten pixels above where Saved and Builder start. All three now come
  from `ADVL.body_y`, and `ui.TableRowsTop` exists so the ROW COUNT knows about
  it too: a table that fills a Blizzlike height inside a shorter Advanced box
  draws its last row past the bottom, and nothing clips it.
- **Clearing something by accident is not clearing it.** The footer rule sits
  38px up; the overlay wells stopped at 36 and drew over it. Search Results
  looked right only because its table stops at 82 for the count and pager. A
  gap that exists as a side effect of an unrelated number is not a gap anyone
  chose.
- **Two views sharing a space need ONE placement function.** Saved Searches and
  the Filter Builder each had their own copy of the two-column split: a 16px
  gutter measured off the frame against a 12px one measured off the window.
  Both columns differed by 2px, which is the jump when clicking between the
  tabs. `ui.SplitAdvColumns` places both.
- **Sized to content beats sized to container, for tabs.** Three equal thirds
  of the panel gave a 442px pill for a 110px label at MAX_W and 308px at MIN_W.
  Tabs are now the widest label plus padding, clamped, and the row is centred —
  the same size wherever the window is, which is what a tab strip should be.
  This is a deliberate departure from the concept's full-width strip, made at
  the owner's request after seeing it in game.

#### What the tests learned

- **A restated formula tests the author, not the code.** The first version of
  the tab assertions re-implemented the centring arithmetic in the test file.
  It passed against the buggy build, because a restatement reproduces the
  intent faithfully while the code does something else. The suite now extracts
  and RUNS `ui.LayoutViewTabs` against stub buttons, and the sabotage that
  restores panel-centring is caught.
- **A test carrying its own copy of a constant tests nothing about that
  constant.** `body_bot = 52` written into the test would have sailed straight
  past a sabotage setting the real one back to 36. Every layout number is read
  out of `ui/frame.lua` now.
- **Some properties are structural and cannot be unit-tested.** The split's
  arithmetic was never wrong — having two of it was. A test on the numbers
  passes either way, so `tests/lint/sharedlayout.py` checks the shape instead:
  both builders call the shared splitter and neither anchors its own columns.
- **A checker fooled by its own documentation is worse than none.** That lint
  first passed on a reverted build because the comment above the column block
  names `ui.SplitAdvColumns`, and the scan counted the mention as a call. It
  strips comments and requires a paren now.
- **Two of the four sabotages written for this pass were INVALID and were
  deleted rather than papered over.** Changing `tab_max` altered nothing
  because `tab_min` governs at every real label width; changing the single
  gutter constant altered nothing because a single source cannot disagree with
  itself. A sabotage that cannot fail proves as little as a test that cannot.

### 2y — Form height and saved-list scrolling — ✅ **DONE** (v1.19.4)

- **A fixed layout with no fit check will eventually not fit.** The Filter
  Builder's rows were ten hand-written offsets ending at 276, in a column that
  is 254px tall at MIN_H. Three rows were added in 1.19.0 and nothing anywhere
  could say the form had run out of room, so it clipped. Rows come from a pitch
  constant now and the suite asserts the last one lands inside the column at
  every window height — **add a tenth row and the suite goes red, not the
  screenshot.**
- **A status line is not a form field.** `ui.fbNote` sat below the last row at
  a fixed offset and, at the minimum height, escaped the well and drew across
  the money readout. It lives on the action bar now, behind one
  `ui.BuilderNote` writer — eight call sites each remembering to Show and Hide
  is seven chances to forget.
- **`ui.RowsFor` measures a frame, and that is the trap.** Third bug from it:
  the Buy table's row count (fixed by `ui.PanelHeightAt`), the Advanced widths
  (`ui.PanelWidthAt`, 1.19.2) and now the saved lists (`ui.SavedRowsAt`). It
  carries a warning naming all three. **Six callers on other tabs are
  unaudited** — Crafting, Auctions, History, the bag and list pickers — and any
  "list does not fill its box" report should start there.

  > Audited in **3d (v1.23.0)**: all six were carrying the fault, and
  > `ui.RowsFor` has been deleted rather than left available.
- **A capped list needs an OFFSET, not just a count.** `SAVED_ROWS` was a pool
  ceiling and `fit` a visible count, and nothing carried a position — so a
  thirteenth favourite could not be reached at all. Both columns scroll on the
  wheel, independently, and the clamp lives in the PAINT so it re-applies when
  the list shrinks under a scrolled view.
- **A row is a Button and eats the wheel.** The handler is on the column's area
  *and* on every row, or scrolling only works in the empty band below the last
  entry — which is exactly where the pointer is not.
- **`ui.SavedRowsAt` was written 900 lines above the constants it reads**, and
  `tests/lint/scoping.py` caught it before it shipped. That lint was added in
  1.19.1 after the same mistake took the window out; this is the first time it
  has paid for itself.

#### The restatement mistake, twice

- **A restated formula tests the author, not the code — and I did it again.**
  1.19.3 recorded this lesson for the tab strip. The first draft of this pass's
  `ui.SavedRowsAt` assertions restated its arithmetic, and the sabotage that
  makes the lists stop three rows short sailed straight past. **The rule is now
  explicit in the test file: if a function can be extracted, extract it.**
- **A "headroom for one more row" assertion was the wrong trade** and was
  replaced. It forced a cramped pitch today to reserve space for a field nobody
  has asked for; the plain fit check already makes the next field fail the
  suite. When an assertion starts dictating the design rather than describing
  it, it is the assertion that is wrong.
- **One reported difference turned out not to be one.** The two Filter Builder
  wells were said to end on different lines; they do not. The right column's
  clause box is nested inside its well and inset on purpose. Recorded rather
  than "fixed".

### 3a — Feature batch, phase one — ✅ **DONE** (v1.20.0)

First of three phases. Phase two (Tab traversal, the `tooltip` run-on syntax)
shipped in v1.21.0 — see 3b below. Phase three (the pending filter components,
restyling Sell / Auctions / Crafting / History) is NOT started; each waits on
the previous one being confirmed in game.

- **A fix applied in one place and left in six others is not a fix.**
  `LockHighlight` drives a template highlight texture that `ui.MakeButton` has
  no such texture for, so it does nothing. That was discovered and fixed for
  the Advanced view tabs in 1.15.1 — and the same dead call was still marking
  the chosen post duration, sell mode, undercut mode, scan pacing, history
  period and Sell-tab duration. **When a bug turns out to be a pattern, grep
  for the pattern before closing it.** It is `ui.MarkChosen` now, one function.
- **A "not chosen" button restores the kind it was BUILT with**, captured on
  first use, not a hardcoded "quiet". A row of accent buttons would otherwise
  come back wrong the first time one was deselected.
- **The window saved its size but not its point.** Restoring one needs a guard
  the size never did: the title bar is the only drag handle, so a point saved
  near the edge of a large monitor and restored on a smaller one strands the
  window with no way back. `ui.PointIsReachable` decides, and it is deliberately
  generous — half off the edge is a choice, unreachable is a bug. When it
  refuses it also CLEARS the bad point, so the fallback runs once rather than
  every login.
- **The reachability check needs the window's HEIGHT, not just its width.** A
  BOTTOM anchor fixes the frame's bottom edge, so its top depends on how tall
  the frame is. The first version ignored that and reported a perfectly normal
  BOTTOMLEFT window as off-screen; the test caught it before it shipped.
- **It refuses to judge a screen it has not measured.** UIParent reporting 0
  means it has not been laid out yet, and treating that as "unreachable" would
  move the window to CENTER on some logins — worse than the fault guarded
  against.
- **pfUI's backdrop is a CHILD FRAME and a child draws above all of its
  parent's regions**, label included. Pushed one frame level behind now. The
  same layering rule already governs the Filter Builder's text; it applies to
  every button, not just the ones a screenshot happened to show.

#### One diagnosis in the prompt was wrong

The brief stated as a "confirmed structural fact" that the settings panel is
built lazily AFTER `A.skin.Apply()`, and that its buttons therefore never reach
skin.lua's `aegisButton` branch. **That is not true**:
`ui.BuildAegisSettings` is called at ui/frame.lua:1172 and `A.skin.Apply()` at
1203, so the panel is skinned normally. The layering fix above was made on the
remaining hypothesis and on its own merits, not on that one — worth recording,
because a confident wrong premise is more expensive than an open question.

### 3a-fix — What 1.20.0 got wrong — ✅ **DONE** (v1.20.1)

Both items here are 1.20.0's own, not older faults it uncovered.

- **The clipping the user reported was self-inflicted.** Adding the
  "Ask before posting" checkbox to the settings panel put a new link in the
  middle of a vertical anchor chain, and the row below it kept anchoring to the
  widget the new one displaced — so the new checkbox, the pacing label, its
  buttons, the price-data line and Clear price data all drew in one spot.
  **Inserting a widget into a chain is TWO edits**, and only one was made.
  Nothing else could have noticed: the addon loads, every widget exists,
  nothing errors. It is a lint now — `tests/lint/anchorchain.py` — because the
  fault is a property of how the file is written (one anchor named twice) and
  reading it back off a stub frame would only restate the two `SetPoint` calls,
  which is the mistake this repo has already made twice.
- **Sinking pfUI's backdrop a frame level was the wrong fix for the right
  diagnosis.** The layering rule was correctly identified; the remedy was not
  strong enough. Frame level orders SIBLINGS, and "a child frame draws over
  its parent's regions" is a separate rule — so the sink helped the scan
  strip's buttons (one frame under the window) and did nothing for the Aegis
  settings buttons, three frames deep inside a ScrollFrame's scroll child.
  **The discriminator was depth, and it was visible in the screenshots
  before the fix was written.** The label is rebuilt on the backdrop frame
  now: inside one frame the draw layer is the whole ordering rule, so there is
  no level left to lose to.
- **And the same fix was missing in four more places** — `skin.ApplyExternal`
  was handing our buttons on other addons' frames to pfUI's *generic* button
  skinner rather than to the `aegisButton` branch, which both double-bordered
  them and buried their labels. This is the second consecutive release where
  the pattern-grep rule from 3a earned its place; the rule is to grep for the
  pattern **as part of the fix**, not after the next report.
- **A lint is a suite.** `tests/sabotage.py` runs Python lints as well as Lua
  unit files now. A lint makes a claim about the source and can be wrong about
  it exactly the way an assertion can — `sharedlayout.py` already passed once
  on a reverted build.

#### And a third, found on the next screenshot (v1.20.2)

- **A ScrollFrame CLIPS, and the clip line is its child's edge.** The settings
  block started at x=0 — flush with it — and the top-level check box column is
  nudged 2px *further* left than the labels so the boxes line up under the text.
  So they hung outside the frame and came back shaved. **Text hides this and
  textures do not**: a glyph carries its own side bearing, a 1px edge texture
  does not, which is why five check boxes showed it and nothing else on the tab
  did. Anything placed in a clipping frame needs a margin, not an alignment.
- The guard is a **chain walk in the geometry suite**, not a restated constant:
  it reads every vertical link out of `ui.BuildAegisSettings` with the offsets
  the file carries, resolves each widget's x, and requires the leftmost to land
  strictly inside. It also asserts the chain really does step left of its root,
  so it cannot pass for the wrong reason, and that the one caller still passes
  no `anchorAbove` — the branch the walk skips.
- **Three consecutive releases have been screenshot-driven.** Each fault was
  invisible to every check that existed and obvious to a person looking at the
  tab. That is the standing division of labour, not a failure of the suite —
  but each one has since been converted into something automatic, which is the
  part that has to keep happening.

### 3b — Feature batch, phase two — ✅ **DONE** (v1.21.0)

Tab traversal and the `tooltip` run-on. Phase three (the pending filter
components, restyling Sell / Auctions / Crafting / History) is NOT started and
waits on this one being confirmed in game.

- **A key that is already bound is a DECISION, not an obstacle.** Tab
  autocompletes item names on the Buy tab's Name field and on the Advanced
  query box, and traversal wanted the same key. Three ways out were on the
  table; the one taken is that the two search boxes keep autocomplete and
  nothing else does. Moving autocomplete elsewhere would have broken a binding
  people already have in their fingers to gain consistency nobody asked for,
  and "Tab completes when there is a completion pending, otherwise traverses"
  is unpredictable in exactly the way that annoys. **The exception is in the
  changelog and the README**, because an undocumented exception is
  indistinguishable from a bug.
- **The traversal order is written out per form, never derived from
  positions.** Deriving it would hand the cursor to whichever box the layout
  happens to place next — including one in a column the eye reads second — and
  every layout change would silently re-order the form.
- **Hidden boxes have to be stepped over, and that is most of the function.**
  The Sell tab's money triplets, the settings panel's flat-amount fields and
  the Buy tab's bid entry all come and go with their mode. Tabbing into one
  that is not on screen puts the cursor where the eye cannot follow it and the
  keystrokes go with it.
- **A dead end must not clear focus.** Nothing else visible to move to means
  stay put; losing the cursor is a worse answer than not moving it.
- **`math.mod` is `fmod` on Lua 5.0** and returns a NEGATIVE remainder for a
  negative left side, so Shift-Tab off the front of a form indexes nothing at
  all. Biased positive, and sabotage-tested — this is the kind of fault that
  passes every review because the forward direction works perfectly.

#### The parser side

- **Making one token consume more than one brings back the ambiguity that
  one-token consumption was introduced to kill.** `tooltip/Stamina/Weapon` —
  second needle, or the item class? The run stops at the first token
  `ParseTerm` would claim for itself, which keeps
  `cloak/tooltip/stamina/exact` and `container/bag/tooltip/8` meaning what
  they always did. The trade is stated in the code, the changelog and the
  README rather than left to be found: a needle that IS a keyword must be
  written `tooltip/Stamina/tooltip/Weapon`, and that escape hatch is
  permanent.
- **Both spellings had to parse to the SAME term, and that fell out of the
  existing design rather than being engineered.** Consecutive operands with no
  combinator between them were already ANDed, which is exactly what the
  repeated spelling meant — so every saved search and favourite on disk keeps
  working with no migration. The suite asserts the long form on its own, which
  is the assertion that says an upgrade cannot break stored data.
- **ONE keyword predicate, two readers.** `buy.IsTermKeyword` is asked by the
  parser's run-on and by `TermToQuery` before it dares emit a needle bare.
  Written twice they would drift, and the drift would be silent: a query that
  round-trips into a *different* search. It takes the term as well as the
  token, because a subclass is a keyword only once its class is known — the
  same word is a keyword in one position and free text in another.
- **The emitter needs a second guard nobody would think to write.** A
  combinator breaks the run, so a needle after `or` cannot go bare either;
  `tooltip/A/or/B` would leave B as name text. Both guards have their own
  sabotage.
- **A keyword list in a test is only worth what proves it current.** Each
  "the run stops here" assertion is paired with one that the token really is
  part of the parser's vocabulary, so a list that has drifted fails loudly
  rather than passing for the wrong reason.

### 3b-fix — The Usable flag never reached the client — ✅ **DONE** (v1.21.1)

Reported and diagnosed from outside the project, which is the part worth
recording: the fault had survived sixteen releases of a suite that gets
sabotage-tested.

- **A wrong TYPE in an argument slot is invisible to every check here.**
  `isUsable` was handed a Lua boolean. The addon loads, the query is sent, the
  client accepts the call, and the only symptom is a filter that quietly does
  not apply. It has been that way since **v1.5.0** — the release that added
  the query language — and the box has been on the Buy tab the whole time.
- **The harness asserted three of the nine args.** `name`, `minLevel`,
  `maxLevel` and `page` were pinned because those are what the addon had
  broken on before; the flag and index args were merely passed through and
  recorded. A contract file that checks the arguments you already got wrong
  is a regression test, not a contract. All nine are checked now.
- **The obvious fix was the wrong one, and the reason is a language rule.**
  The proposed change was `1 or 0`. **0 is TRUTHY in Lua**, so a client
  reading that slot as a flag would take "off" as "usable only" and narrow
  every search — and the results would still look plausible, so it would not
  be reported as a bug for a long time. `nil` is right under either reading
  and is what CLAUDE.md rule 9 already required. **The diagnosis was right and
  the remedy was not**, which is the same shape as the pfUI backdrop fix in
  3a-fix; both times the fix had to be re-derived from the diagnosis rather
  than accepted with it.
- The `0` spelling is now a sabotage in its own right, so the tempting version
  cannot be reintroduced quietly.

### 3c — Feature batch, phase three (first group) — ✅ **DONE** (v1.22.0)

Five of the nine placeholder components implemented: `min-level`,
`max-level`, `rarity`, `seller`, `left`. These are the group that needs
**nothing but the page** — every field is one `buy.ReadPage` already captured,
so they answer on the first search for any item however cold the client is,
and they add no per-item query to a loop HARD RULE 16 governs.

Remaining after this one: `percent` and `vendor-profit` (shipped in 3f,
v1.25.0), `item`
(needs the item cache), `disenchant-profit` (needs a data source 1.12 does not
provide; still unscheduled, and deliberately alone).

- **`rarity` is EXACT, and choosing that was the whole design decision.** The
  server-side `quality/N` is already the minimum — it is literally the form's
  Min Quality dropdown — so a post-filter minimum would have been a second
  spelling of a thing that already had one. Exact is the sentence you could
  not otherwise write: "rares, and not the epics above them." A component that
  duplicates its neighbour is worse than an absent one, because both look
  like they work.
- **`left` is a BOUND, not an exact match, and the reason is composition.**
  "At most this much time left" answers the question people actually have
  (what is ending soon), and exactly-medium is still reachable as
  `left/medium/not/left/short`. An exact match would have answered a narrower
  question and lost the common one.
- **Two of the five cannot always ANSWER, and that is a third state, not a
  non-match.** `owner` is nil until the client resolves the name (rule 8) and
  `timeLeft` is guarded because a server may not report it. The row is dropped
  — a positive filter cannot honestly keep what it cannot verify — but it is
  counted and named in the status line. **This addon has twice shipped a
  filter that silently matched nothing**, and the confession is the only
  reason bare `stack`'s fault was reportable rather than merely annoying.
- **A short-circuited AND counts only what it asked, and that is correct.**
  `buy.CompilePost` skips operands the running result already decides — the
  thing that keeps an or-chain from running a tooltip scan it does not need —
  so the note describes what was evaluated, not what might have been. Asserted
  rather than discovered later.

#### One table, four readers

- **`COMPONENT_VALUE` says what each component's value is made of**, and the
  parser, the query writer, the Builder's Enter key and the Post Filter list
  all ask it. Four hand-written copies of "min-level takes a number" is
  exactly the shape that produced the Saved-vs-Builder drift in 1.19.3.
- **It surfaced a latent fault immediately.** The Builder assumed every
  non-`tooltip` component took MONEY — true only while the price bounds were
  the only implemented ones — so a level typed into that box would have been
  parsed as a price. The same assumption sat in the Post Filter list's
  drawing code. Neither was reachable before this release, which is why
  neither had been noticed.
- **A value that does not parse is not a clause.** `min-level/soon` leaves the
  words as name text, the rule `quality` and `level` already follow. Accepting
  it would build a clause that can never match, which is the failure mode this
  repo keeps returning to.
- **Time left goes back into the query as a WORD and quality as an INDEX**, and
  the inconsistency is deliberate: `left/1` is unreadable in a saved search,
  while `rarity/3` matches the `quality/2` its neighbour already emits. The
  English time-left keys are the language and never the client's localized
  strings, or a saved search would stop meaning the same thing on a German
  client.

#### What the tests learned

- **`Row({ owner = nil })` sets no key at all.** A table constructor with a
  nil value stores nothing, so `pairs()` never sees it and the default
  survived — four assertions about unresolved owners were passing against a
  row that had an owner. Caught only because the sabotage-first habit made the
  "does not match" assertion fail loudly rather than pass vacuously. A
  sentinel is the only way to say "absent" through a table.

### 3d — Feature batch, phase three (the tables) — ✅ **DONE** (v1.23.0)

The restyle's structural half: the row chrome shared by every table, and the
`ui.RowsFor` audit. The headers half shipped in v1.24.0 — see 3e below.

- **The `ui.RowsFor` warning was right about all six.** It named Crafting, the
  recipe tree, Auctions, History and the two Sell columns as unaudited, and
  every single one was carrying the fault — each measured a scroll frame
  anchored by two corners, so each kept the row count it computed at the
  window's creation size. Fourth, fifth, sixth, seventh, eighth and ninth
  instances of the same trap, found by reading the warning rather than by a
  report.
- **The measuring function is DELETED, not kept as a shim.** A trap four
  separate bugs walked into does not want a convenient spelling. `ui.RowsFor`
  is gone and `ui.ListRowsAt` derives from the window's height.
- **The insets live in ONE table that both readers use.** `LISTBOX` carries
  each list's top and bottom inset, and the `SetPoint` that positions the box
  reads the same fields the row count does. Before this the second reader did
  not exist at all — which is how a box and its contents could disagree.
- **A test that reads a number cannot detect that number changing**, and one
  sabotage written for this pass was deleted for exactly that. The geometry
  suite reads `LISTBOX` out of the file on purpose, so nudging an inset moves
  both sides of the comparison. The assertion that DOES bite is
  "a taller window shows more rows" — that is the one a revert fails.

#### The chrome

- **The Buy table had the only copy, and that is why every other tab read as a
  different addon.** One `ui.AddRowChrome` now serves five tables. Four copies
  would have been the Saved-vs-Builder drift of 1.19.3 all over again, in a
  place where the difference is visible on every row.
- **Creation order is the whole function.** All three textures share the
  BACKGROUND layer, where draw order IS creation order: stripe, then hairline,
  then tint. Any other order is a silent visual bug — nothing errors, every row
  still draws, and a selected row wears a hairline scar or reads as
  striped-and-selected.
- **That order is testable, and the look is not.** The function is extracted
  and RUN against a row that records what it was asked to make, so the
  ordering rule is an assertion rather than a comment. This is the division of
  labour the last three releases kept discovering: the visible result needs a
  person, the rule underneath it does not.

#### The lint that had never worked

- **`definitions.py` asked whether a NAME appeared anywhere in the file
  text.** So a rename passed as a substring (`ui.TableRowsAt` is inside
  `ui.TableRowsAtNew`) and a deletion passed whenever a comment mentioned the
  name — which is exactly how it waved through the `ui.RowsFor` removal in
  this very release. It compares definition SETS now.
- **It also reported ok having compared nothing.** With no git repo every file
  is skipped as "new" and the run exits 0, which is indistinguishable from a
  clean pass — and is how it sat in `sabotage.py`'s suite list looking green
  while being completely inert. It fails on an empty comparison now, and it
  is not a sabotage suite (the throwaway copy has no `.git`); it proves itself
  with `--selftest`, the way `lua50.py` always has.
- **This is the second checker in this repo fooled by its own documentation.**
  `sharedlayout.py` was the first. The rule earns restating: when a lint reads
  source text, it must strip or exclude the places where a name can appear
  without meaning anything.
- **Deliberate removals are now expressible**, and the mechanism checks itself
  both ways: an entry naming something still defined is reported as stale, so
  the exemption list cannot quietly become a blanket one.

### 3e — Feature batch, phase three (the headers) — ✅ **DONE** (v1.24.0)

The restyle's second half, and the end of §8. Auctions and History gained
clickable sort headers, the Sell tab's hand-rolled copy of the header builder
was folded into the shared one, and the quality-colour question was settled.

- **Three copies of a four-line rule is how tables start disagreeing.**
  `SetBuySort`, `SetCraftSort` and `SetSellSort` each carried their own "same
  column flips, new column starts ascending" — and Auctions and History wanted
  a fourth and a fifth. `ui.NextSort` is one copy.
- **The nil rule was one table's private comparator and is now everyone's.**
  `ui.SortByKey` holds it: a missing value ALWAYS sinks, in both directions.
  It had a suite of its own tested only THROUGH the Buy table; now the rule
  itself is asserted, which matters because five tables borrow it.
- **The Sell tab's columns were two disagreeing sets of numbers** — headers
  panel-relative with their own widths, rows row-relative with different ones,
  a few pixels apart on every numeric column. Nobody would have found that by
  looking; it surfaced only when both were made to read one table.

#### A sabotage that found the wrong bug, and was right to

- **The entry meant to invert Auctions' `vs market` ratio matched an
  identical line in the Buy tab's `% Mkt` sort first**, because `str.replace`
  takes the first occurrence — and the suite did not notice THAT either.
  Nothing checked pct ORDERING, only that bid-only rows sank, so the ratio
  could have been upside down since it was written.
- The lesson is about the sabotage, not the code: **a sabotage whose `find`
  is not unique is testing a function you did not choose.** Both entries now
  include enough context to name their own function, and pct has assertions
  that a ratio is a ratio rather than unit price under another name.
- **An assertion pinned an unstable sort's tie order** and was replaced.
  `table.sort` is not stable in Lua, so naming which of two equal rows lands
  second records an accident and fails on a different build rather than on a
  real change.

#### The quality-colour question, answered by NOT doing it

- **History's item names stay uncoloured, deliberately.** Every other table's
  item column is quality-coloured already, so "quality colours wherever the
  data exists" turned out to be a finding rather than a task — except here,
  where the ledger stores a name and an item id and no quality.
- Colouring them would mean a `GetItemInfo` per row inside a repaint that
  `ui.ScanMailSales` can trigger while the client is storming
  `MAIL_INBOX_UPDATE` and resolving item data. That is exactly the shape HARD
  RULE 16 forbids and what froze Courier. **Recording quality at log time**
  would be the honest route if this is ever wanted — a data-model change that
  would not colour existing history — and it is not worth it for a cosmetic
  gain. The decision is commented at the paint site so it is not "fixed"
  later.

### 3f — The price-DB filters — ✅ **DONE** (v1.25.0)

`percent` and `vendor-profit`. Seven of the nine placeholder components are
implemented now; `item` (needs the client's item cache) and
`disenchant-profit` (needs a data source 1.12 does not provide) remain.

- **`percent` is a ceiling and `vendor-profit` is a floor**, and each is the
  only useful direction for the question it answers: one finds deals, the
  other finds flips. `not/` still gives the other side of either, which is why
  neither needed a second component.
- **Per UNIT on both sides.** Market value and vendor price are both stored
  per unit and the row's `unit` is per unit, so a stack of 20 compares
  honestly with a stack of one. Any other reading would make the filter agree
  with itself only at stack size 1.
- **The advice was wrong before this release, and that was worse than no
  advice.** The unanswered note ended `— search again` for every cause. There
  is no sell price in 1.12's `GetItemInfo`; a vendor price is learned by
  standing at a merchant, so "search again" was a loop that cannot succeed.
  Each cause carries its own remedy now, and **mixed causes get none** — two
  cures cannot be summed up in one clause without telling half the readers to
  do the wrong thing.

#### The distinction that took the most thought

- **A bid-only auction is NOT a row we failed to judge.** It has no unit price
  because the seller set no buyout: a fact about the auction, visible on the
  row, that no scanning changes. Our ignorance of a market value is a
  different thing entirely, and only that gets confessed.
- The rule is worth stating because the tempting version — confess anything
  the predicate could not evaluate — would put the note on nearly every
  search, at which point it stops being read. **A confession that fires
  constantly is the same as no confession**, which is the failure mode
  `unknownStack` was designed around in the first place.
- `max-unit-buy` had already settled this, silently, by returning
  `row.unit and row.unit <= cap`. Following an existing precedent rather than
  inventing a rule is what made it obvious once found.

### 3g — The window opened below its own minimum — ✅ **DONE** (v1.25.1)

Two users reported the window clipping; neither could be helped by anything
about their setup, and the reporter could not reproduce it at all. The cause
was in the source and needed no reproduction once the right question was asked.

- **`f:SetWidth(832) / f:SetHeight(460)` were the size the window used when
  `MIN_W` was 832.** When the minimum rose to 1000 × 492 those literals stayed,
  and `ui.ColumnsFitAt` puts the true column floor at ~970 — so a window that
  opened at 832 had the Buy table's right-hand columns off the panel.
- **The note above `MIN_W` reasoned about the SAVED size and never about its
  absence.** "A saved width below the minimum is clamped UP by
  RestoreWindowSize, so an existing character just gets a wider window on first
  login" — true, and it is exactly why the fault was invisible to everyone who
  had ever dragged the window. `RestoreWindowSize` then returned early when
  there was no `ui` table at all, which is every fresh install.
- **"Fixed by the resize grip" was the whole diagnosis.** `SetMinResize` snaps
  the frame to the minimum the moment sizing begins and `OnMouseUp` saves it,
  so a single drag cured it permanently. A bug that a user action silently and
  permanently repairs is a bug almost nobody will report twice — and the two
  who did looked like they had nothing in common.
- **Neither reported environment detail mattered.** 4K, 2560×1600, pfUI, UI
  scale, a renamed `WTF` — the only common factor was never having dragged the
  window, which a settings reset guarantees. **The clean-room test that was
  meant to eliminate variables was in fact the thing that created the
  symptom**, and it read as the opposite.

#### What the tests learned

- **Nothing checked the size the window OPENS at.** Every layout assertion in
  the geometry suite is written "at MIN_H" or "at MIN_W", which is correct and
  which the code satisfied — while the frame quietly started life below both.
  A floor that everything is measured against, and that nothing verifies the
  window actually starts at, is a floor in name only.
- The creation size is read out of the source and required to sit in range,
  and the result columns are required to fit **at it**. Paired with an
  assertion that the old 832 genuinely fails `ColumnsFitAt`, so the check
  cannot pass for the wrong reason.
- `ui.ClampWindowSize` was split out as pure arithmetic. The clamp existed
  before; it was welded to `SetWidth`/`SetHeight` and therefore untestable, and
  the branch that skipped it entirely was the bug.

### 3h — The bag list: one row per item, and the Buy table's look — ✅ **DONE** (v1.26.0)

Reported as a display bug and it was not only one. `sell.ScanBags` emitted a
row per bag SLOT, and four things read that list: the display, the vendor
list, the batch scanner and the post-scan sell queue. Three of the four were
silently doing the same item two and three times over.

- **THREE NUMBERS, and keeping them apart is the whole design.** `count` is
  the holdings total, `stackMax` the largest single stack, `slots` every
  physical stack. 1.12 cannot merge two partial stacks, so thirty held as
  three tens is thirty items, a largest stack of ten, and **zero** postable
  stacks of thirty.
- **The tempting version of this fix ships a worse bug.** Aggregating the row
  to "x30" while the stack-size slider still ranged to the total lets someone
  ask for a stack that can never be assembled — `sell.MaxStacks` returns 0 and
  the count reads zero with no explanation. The slider ranges to
  `sell.LargestStack` now, and the total is still shown because it is still
  the useful thing to know.
- **One consumer must NOT see the aggregate**, and it is the one that spends
  items: `sell.MarkedInBags` still emits a row per physical stack, because
  `SellMarkedToVendor` calls `UseContainerItem(bag, slot)` once per row and
  that sells exactly one stack. An aggregated row there would sell a third of
  what was marked and report success. Sabotaged in that direction on purpose.
- **The other two consumers were improved by the same change**, which is the
  sign the aggregate is the right model: the vendor list stops listing an item
  three times and the batch scanner stops scanning it three times.

#### The look

- 26px rows, the shared chrome, 20px icons, quality-coloured names, banded
  category headers. The reference screenshot was an icon GRID; the list was
  kept and the things actually being complained about were taken from it.
  **Recorded as a decision, not a shortfall** — a grid is a different widget
  and is its own job, possibly as a toggle.
- **The bag column was 156px and truncated most names.** Widening it meant
  moving the listings column, and those two numbers were four literals across
  five call sites. `SELLL` holds both now, and the geometry suite requires the
  listings columns to fit beside the bag column **at the smallest window**,
  and the gutter to clear the bag list's scrollbar — a FauxScrollFrame's bar
  sits outside its right edge, so that gap is structural rather than
  decorative.

#### What the tests learned

- **A cold item cache is the normal state, not an edge case.** `GetItemInfo`
  answers nil until the client has the item, so the first open of a session
  categorises everything as "Other". The row must survive that, must recover
  the name from the item LINK, and must **not claim a quality it does not
  know** — defaulting to 1 would paint an epic white. All three asserted.
- The geometry suite's table-field reader could not see a field on a table's
  **opening line**, so `SCX`-shaped tables reported their first field missing.
  It read as "the table moved" rather than "the table is formatted
  differently", which is the worst kind of wrong error.

### 3i — The listings table, drawn like the Buy table — ✅ **DONE** (v1.27.0)

The stated top priority of the report, and the last of the Sell-tab restyle.

- **The table had no BOX**, which was the difference the screenshots were
  actually showing. Zebra banding and warm-tan sortable headings had already
  landed (1.23.0, 1.24.0) and were visible in the "current" capture — what was
  missing was the border around the headings and rows together, the rule under
  the headings, and the ticks between header cells.
- **The Buy table's construction was copied in its REASONING, not its
  numbers.** The box is anchored explicitly rather than through `ui.MakeWell`
  for the two reasons already recorded there: it has to reach up past the
  scroll frame to enclose the headings, and its right edge must stop AT the
  scroll frame's, because FauxScrollFrameTemplate hangs its scrollbar outward
  from that line.
- **Every numeric column was LEFT-aligned**, which is the single thing that
  made the table read as assembled rather than designed. `ui.MakeSortHeaders`
  has taken a `just` flag since it was written and this tab never passed one;
  the heading follows the cells from the same flag, so the two halves cannot
  disagree.
- **The status line was above the headings** and is below the box now, where
  the Buy table's count sits. A caption above a table competes with its own
  column headings.
- Four vertical numbers have to stay in step — box top, heading top, heading
  band height, first row — and getting any wrong leaves headings outside the
  box or a rule across its top edge. That is what the Buy table did before
  v1.15.0, so the suite asserts the relationships rather than the values,
  including that the gap from box to headings MATCHES the Buy table's.

### 3j — Sell-tab flow: the cursor, leftovers, and Max — ✅ **DONE** (v1.28.0)

- **The cursor bug was diagnosed wrong for a whole release, and the code said
  so.** The report asked for a `ClearCursor()` / `PutItemInBag()` snippet;
  `sell.ClearSlot` already did the documented Auctionator pattern and
  `PlaceFromBag` already opened with `ClearCursor()`. Both true, and neither
  was the fault.
- **`ClickAuctionSellItemButton` SWAPS.** It gives the slot what the cursor
  holds and hands back what was already there. So placing a second item while
  the first was still slotted handed the first onto the cursor. The existing
  `ClearCursor()` could not help: it runs BEFORE the pickup and is finished by
  the time the swap happens. Emptying the SLOT first turns the click back into
  the plain placement everything assumed it was.
- **It was unreproducible because the harness stubbed the mechanic away.**
  `ClickAuctionSellItemButton` was a metatable no-op, so no test could have
  shown the swap. The cursor and slot are MODELLED now -- bags mutable,
  `ClearCursor` returning a held item where it came from -- and the bug
  reproduces in three lines. **A stub that erases the mechanism erases the
  bug with it**, which is how this stayed a guess.
- **Leftover retention is gated on the ITEM MATCHING**, and that gate is the
  whole safety of the feature rather than a detail of it. `sellPrefilledFor`
  is what stops the price boxes being refilled from the market; carrying it
  across a DIFFERENT item would post that one at a stale price, which is the
  worst thing this tab could do.
- **"Max" was nearly free and the brief said so.** `sell.MaxStacks` existed,
  the slider was already clamped to it, the readout already printed it. The
  only real work was routing the write through `ui.SetStackCount` -- size and
  count re-range each other on every repaint, so a raw `SetText` leaves the
  slider disagreeing with the number beside it.

#### What the tests learned

- **A test world that leaks is worse than no fixture.** `W.SetBags` replaced
  the bags while the sell slot still held an item from the previous case, so
  clearing the slot put a second copy back: five copper bars became ten and
  read as a duplication bug in the ADDON. `SetBags` empties the cursor and
  slot now, because "here are the bags" is a statement about the whole world.
- **Inserting the new checkbox moved an anchor a sabotage named**, and
  `anchorchain.py` reported it stale rather than passing. That is the lint
  and the sabotage system doing exactly what they were built for, on the very
  mistake they were built for.

### 3k — Disenchant value — **BUILDING**, phased from v1.29.0

Asked for as a way to tell whether an item is worth more broken than posted.
Spiked in v1.28.1, answered **no**, and that answer was **wrong** — two of its
three load-bearing claims did not survive being checked. The original spike is
summarised below rather than deleted, because the way it went wrong is
instructive.

#### The reframe that unlocked it

**There is no disenchant table. There is a rule, and an item level.**

Item level + quality + weapon-or-armour fully determine the result. Verified
against **8,843,728 observed disenchants**: the band boundaries land exactly on
vanilla's 5-wide ladder, with no fuzz, and per item level the top-end boundary
is crisp (ilvl 60 greens give 1.54 dust per proc, ilvl 61 give 3.48).

So every source of disenchant knowledge answers the **same** question:

| Source | Really is | Answers |
|---|---|---|
| A disenchant the player performed | an item-level **estimator** | what is the item level? |
| A shipped item-level table | an item-level **lookup** | what is the item level? |
| `minLevel` from `GetItemInfo` | an item-level **guess** | what is the item level? |
| — | no item level | *unanswered* |

One rule, one resolver, four ranked sources — not four parallel lookups. That
is the shape the whole feature is built in.

#### What the v1.28.1 spike got wrong

- **"No item level, and no way to get one."** True of the client and still
  true. But the spike itself listed *"any addon-visible source for it"* as an
  unblocker and then failed to look for one. A shipped `[itemId] = itemLevel`
  table is exactly that.
- **"Learning it from play needs a bag walk on a spell event"** — and is
  therefore HARD RULE 16 territory. **Simply false.** The era's addons hook
  `PickupContainerItem` / `PickupInventoryItem` to remember the item the click
  landed on, gate that behind `SPELLCAST_START` for Disenchant, and read the
  loot at `LOOT_OPENED`. Every step is O(1); the loot read is bounded by slot
  count. Verified against the real 1.12.1 `ContainerFrame.lua`: a plain left
  click is `PickupContainerItem` (there is no `SpellCanTargetItem` branch in
  1.12 — that arrived later).
- **"Required level is not a substitute."** This one **stands**, and is why
  the `reqlevel` fallback is gated on a measurement rather than assumed (§5).

The lesson worth keeping: the spike reasoned from what the client lacks and
never checked what other addons had already solved. Both corrections came from
reading their source.

#### Phases

- **§1 — the rule. v1.29.0, restart. DONE.** `core/disenchant.lua` +
  `core/itemlevel.lua` + the `.toc` edit. Pure functions, constants generated
  by `tools/gen_disenchant.py`, `/aex de <link> [ilvl]` to verify in-game.
  441 checks, six sabotages.
- **§2 — the tooltip line. v1.30.0. DONE.** Value plus a Shift-held breakdown,
  gated on `tipDisenchant`. Silent wherever the rule cannot answer. Added
  `de.Resolve` / `de.YieldOf` / `de.ValueOf` as the single resolution layer,
  and `W.LoadUI` so `ui/` modules are testable at all.
- **§3 — learning from play. v1.32.0. DONE.** Stores **observations only**;
  every band and level above them is derived at read time.

  **A correction to what this entry used to claim.** It said one disenchant
  identifies the band for "46 of 53 material signatures". That conflated a
  *full* signature — every material an item can yield, which takes many breaks
  to establish — with a *single* observation, which yields one material. The
  real figure, measured against the shipped table: of the **30**
  material/quality combinations it can produce, **21 pin a band exactly and 9
  leave two or three candidates**. An essence names its band outright; a dust
  does not (Strange Dust spans bands 15, 20 and 25, whose yields differ by
  more than double). So `de.BandCandidates` returns a candidate COUNT and
  `de.ItemLevel` accepts the answer only at one — evidence accumulates rather
  than being believed on the first result.

  It is still a far better trade than an item-keyed model, where one break is
  one sample out of hundreds. Here one or two breaks give a full expected
  value backed by 8.8M samples.

  **Attribution reads no spell name.** Enchantrix gates on `SPELLCAST_START`
  matching the localised name of Disenchant; we do not, because the name is
  localised and whether Turtle produces a cast at all is not answerable from
  the client source. Instead all four must hold: the click happened while a
  spell awaited an item target (`SpellIsTargeting`), the item clicked **can**
  be disenchanted, a loot window arrived inside 15s, and **every** loot slot is
  an enchanting reagent. The last is the discriminator — enchanting opens no
  loot window, a lockbox yields non-reagents — and the second is what stops a
  lockbox being "learned" from the shard picked out of it.
- **§4 — the filters. v1.33.0. DONE.** `disenchant-profit` and
  `disenchant-percent`, both per item, both confessing through the
  `UNANSWERED_FIX` path §7a built. `ui.PENDING_COMPONENTS` is down to `item`
  alone. The two share one remedy string on purpose: `UnansweredSummary`
  withholds advice when components disagree about the cure, so a query using
  both would otherwise lose its advice line.
- **§5 — the `reqlevel` fallback. DROPPED, v1.40.0.** Never built, and now
  never will be.

  The measurement shipped in v1.39.0 (`/aex de audit`) came back **0 items
  judged, 12,135 uncached** out of 12,567. That is not a verdict on required
  level; it is 1.12's item cache holding only what a client has actually seen.
  A bulk sweep cannot work, and warming 12,567 items to make it work is a
  worse idea than the fallback was.

  It is moot regardless: **v1.40.0 reads the real item level** where a client
  mod exposes it. There is no reason to approximate a number you can read.
  `/aex de audit` and `de.CompareBands` are kept — they still answer "how good
  would that guess have been" for anyone curious, and they cost nothing.

- **§5b — client-provided item data. DONE, v1.40.0.** 1.12 populates an item's
  vendor sell price AND its item level on every item and displays neither.
  Where a mod (ClassicAPI) exposes them, Aegis now reads both:
  `util.ClientSellPrice` and `util.ClientItemLevel`, asked as **capabilities**
  rather than by addon name — the rule the scanner already applies to
  AuctionQueryThrottle.

  Rankings: vendor price is `client` → `merchant` (learned) → nil. Item level
  is `observed` → `client` → `itemlevel` (shipped) → nil. Observation stays on
  top because it reflects the server being played on, not what an item's data
  says.

  **Nothing degrades without it.** The absence path is asserted directly, and
  is the case for most players.

- **§5c — then decide about `core/itemlevel.lua`. OPEN.** With the client
  answering for every item including Turtle's, the borrowed 12,567-entry table
  may have nothing left to do — and deleting it retires the unlicensed-data
  question with it. That is a decision to make **with a number in hand**: how
  often is the shipped table still the answer? Do not delete on the strength
  of the argument alone; §5 is what that mistake looks like.

- **§6 — "worth more disenchanted" on the Sell tab. Not committed.** A wrong
  answer here destroys something unrecoverable, so it needs shipped item level
  **and** a local observation, or it says nothing.

#### The two limits that are not going away

- **Above item level 65 there is no data.** Observations thin to a few dozen
  and stop being monotone; Turtle item levels run to 99, and **16%** of its
  custom items with a known level sit above 65. `de.Band` returns nil there,
  in one place, so nothing can extrapolate by accident.
- **Item level does not say whether an item CAN be disenchanted.** Quality and
  equip slot get most of the way; the rest is a hardcoded exception list that
  no rule predicts. Turtle will have its own and only a failed disenchant
  reveals them.

#### The item-level provenance decision — CLOSED by deletion, v1.41.0

`core/itemlevel.lua` shipped **empty** in v1.29.0, was **populated** in v1.31.0
with 12,567 entries from ShaguScore, and is **gone** as of v1.41.0.

ClassicAPI exposes the client's own item level — the real number, for every
item, including the two thirds of Turtle's custom gear the borrowed table never
had. A partial copy of a number you can read directly has nothing left to do,
so it was deleted, and the question of whether shipping someone else's
unlicensed database was all right went with it. That is a better way for that
question to end than any answer to it would have been.

The consequence, stated plainly: **without ClassicAPI the disenchant line now
answers only for items the player has disenchanted themselves.** That is the
trade the owner chose, and the UI says so — the setting and both Filter Builder
components carry a tooltip naming the requirement rather than going quiet
unexplained.

Two releases shipped with nothing visible before the table landed (§1 by
design, §2 as a consequence), which is worth remembering as a sequencing
lesson: a phase whose payoff depends on a parked decision should not be
followed by another that depends on the same one.

The derived yield constants carry no such problem: Enchantrix's GPL v2 file is
never vendored, and a few dozen probabilities computed from public observation
are facts about the game rather than anyone's expression of them.

#### The fallback that broke HARD RULE 16 — v1.41.1

v1.41.0's readers (`util.ClientSellPrice`, `util.ClientItemLevel`) asked
ClassicAPI first and fell back to `util.ItemInfo`, i.e. `GetItemInfo`.

`GetItemInfo` reads like a local cache lookup, and for a cached item it is one.
For an **uncached** item on 1.12 it sends a query to the server. `db.GetVendor`
is called per bag item, per auction row and per tooltip, so the cheap-looking
fallback multiplied by the length of whatever list was being painted.

The general shape: **HARD RULE 16 can be broken by a fallback, not just by a
handler.** The rule names the expensive calls, and reviewing a handler for them
is not enough when one hides two calls down a chain that starts at a table
read. When a function is documented as O(1) and is called from loops, the
guarantee belongs in the function, not in its callers' heads.

Now enforced rather than remembered: the test client counts `GetItemInfo` calls
and `clientdata` requires **zero** from any of these paths, with and without
ClassicAPI. The `info` argument on `db.GetVendor` / `de.ItemLevel` is a caller
*handing over* a `util.ItemInfo` it already paid for — never a hint to fetch
one.

#### The crash to desktop — CLOSED. It was the client install.

Reinstalling mods, patches and DLLs fixed it. v1.41.1 now runs clean on
Auctions, History and Crafting, so the tree is restored to v1.41.1 and the
1.39.0 rollback is undone.

**Three releases claimed a fix for a fault that was never in the addon.** That
is the thing worth keeping from this, and it is a diagnostic lesson rather than
a code one:

- **Every one of the three had a mechanism that genuinely existed in the code.**
  `db.GetVendor` reaching for `GetItemInfo`; the unbounded query-per-hover.
  Both were real, both were worth fixing, and neither was the crash. *A found
  bug that fits the symptom is not thereby the cause.*
- **The evidence that it was environmental was available early and was not
  weighed.** v1.40.0, the release the crash was pinned to, changed **no UI file
  at all**, and the three crashing tabs did not call the code being blamed.
  Each of those refuted the story being told at the time. Both were noticed and
  neither was treated as disqualifying, because a plausible mechanism was
  already in hand.
- **What eventually produced facts was measurement, not reading.** The rig that
  loads the real `ui/frame.lua` against a mock client and counts calls settled
  in one pass what three rounds of reading got wrong. It could not have found
  this cause — no rig sees a missing DLL — but it did rule out the addon, which
  is exactly the answer that was needed and was not believed.
- **The next unexplained crash starts by establishing whether it is ours at
  all.** A clean-profile / reinstall check is cheap and should come before any
  code change, not after three.

#### What survived the hunt

- The **tooltip `SetHyperlink` fallback** (v1.41.1): auction rows kept their
  tooltips after the AH was closed and reopened. A real bug, really fixed.
- The **measurement rig** (scratch, not in `tests/`). It counts `GetItemInfo`
  per tab and per hover and drives every sub-tab through every sort column.
  Bringing it into the suite needs one change: `tests/support/wow.lua` resolves
  ANY unknown key to a fresh no-op function, so `if b.backdrop then` is true for
  every frame and a genuinely nil field read as a method never surfaces. It
  needs a fixed list of real widget methods with nil for everything else, which
  is what the client does. Until then `ui/frame.lua` is a file no suite loads.
- The **`GetItemInfo` miss gate** (v1.41.2), NOT currently shipped. Measured: a
  40-row sweep cost 32 lookups before and 1 after; re-hovering one row twenty
  times went 20 to 0; 61 cached items stayed 61, which is the constraint that
  matters, since pacing cached lookups would break the Buy tab and the bag
  browser. It is out because it was written to fix a crash it did not fix and
  has never run in a healthy client — not because it is wrong. Re-apply it as
  its own release, on its own evidence, and let it be tested for what it
  actually does: fewer server queries when hovering lists of uncached items.

### 3l — The no-ClassicAPI backup, from aux — **BUILDING**

Phase 1 (sell-slot vendor price) shipped in **v1.42.0**; phase 2 (the
required-level fallback) in **v1.43.0**; phase 3 (the item-fact harvest) in
**v1.44.0**; phase 4 (the multi-section tooltip) in **v1.45.0**. **The aux work
is done.**

Left deliberately unbuilt: **vendor BUY prices**. aux learns what a merchant
charges as well as what it pays and flags limited stock (`limited = stock >= 0`
from GetMerchantItemInfo's 5th return, with an unlimited-stock price always
beating a limited one). We never scan a merchant's inventory, so there is
nothing to show. It is a feature with its own event handling, not a tooltip
line, and belongs in its own release.

**A load-bearing fact was wrong and is now corrected.** `GetItemInfo` does NOT
query the server for an uncached item -- it returns nil and does nothing else.
The call that forces a fetch is a tooltip `SetHyperlink`. aux's own
cache-warming command settles it: `if not GetItemInfo(id) then SetHyperlink(id)
end` is only meaningful if the first is a free probe and the second is the
fetch. v1.41.2 asserted the opposite and shipped a throttle for it; that release
was rolled back, but the claim survived in comments and is now fixed at every
site. It is the difference between the harvest being free and being
unshippable.

**The ladder question is settled, and it needed no second table.** The offset
between aux's required-level bands and our item-level bands was derived by
aligning the two by MATERIAL SIGNATURE rather than assumed: all 20 of aux's
uncommon and rare bands sit exactly 5 below ours, with no boundary disagreeing.
So `de.ItemLevel` returns `minLevel + de.REQ_OFFSET` and the existing `de.Band`
does the rest. The four bands whose material LISTS differ are all places our
generator dropped a low-probability tail material for thin data — our own gap,
unrelated to the offset.

The trap flagged in the research pass was real and is what the derivation
avoided: feeding required level into the item-level bands raw lands every item
a band low, and adjacent bands differ by more than double in yield. The
sabotage `reqlevel-offset-dropped` plants exactly that.

**Settled since the research pass:** `INVTYPE_SHIELD` is **armour**, which is
what Exchange already has. Aux puts it under WEAPON and aux is wrong; dust is
~75% of green armour yields and essence ~75% of green weapons, and shields are
armour. No change needed, and it is off the open-questions list.

Read `shirsig/aux-addon-vanilla` @ `6b56d0f` in full. Full write-up lives in the
artifact "Aux, Taken Apart"; what follows is what the repo needs to remember.

**No LICENSE file exists in that repository**, and no licence appears in its
README or `.toc`. Understood-and-reimplemented only, never copied — the same
conclusion this project reached for Auctionator and for the ShaguScore table.

#### The finding that matters

**Aux never had an item level either.** `util/info.lua:375` destructures
`GetItemInfo` and names position 4 `level`, feeding it straight into the
disenchant band lookup — but on 1.12 position 4 is **minLevel, the required
level**. Aux's whole disenchant model is keyed on required level, which every
client returns with no mod at all. Its ladder stops at **60**, the maximum
*required* level; ours stops at 65, consistent with *item* level. Two ladders,
each internally consistent with its own key.

§5 dropped the required-level fallback on an audit that returned *0 judged /
12,135 uncached*. That measured a cold item cache, not the quality of the
signal. The addon that actually ships on Turtle has run on it for years.

**THE TRAP: required level cannot be fed into our existing bands.** They are
item-level bands built from item-level observations, and required level runs
~5-10 lower for the same piece — every item would land a band or two low and
report the wrong materials, silently. The backup needs its own ladder: either
re-derive bands keyed on required level (correct), or adopt aux's boundaries
with our measured distributions (cheaper, approximate at the seams, must be
labelled). `de.ItemLevel` already returns a `source`; add `"required"` to the
ranking below `"table"` and let the UI say "approx".

#### The passive cache harvest — what §5 should have concluded

`core/cache.lua:165` walks item ids 1..30000 calling `GetItemInfo`, records
**only items already cached** (the `if name` guard — it never forces a fetch),
paced at 100 newly-recorded items per half second, and **persists to
SavedVariables** so coverage accumulates across every session played. Forcing
the cache to fill is a separate, explicit, opt-in command that prints progress
and is never automatic.

That separation is the whole design. A sweep cannot work as a snapshot; it
works as an incremental, persistent curve. It also makes tooltips O(1) after
first sight, which independently removes the query-per-hover cost measured
earlier (40 rows cost 32 `GetItemInfo` calls).

#### Vendor price without a DLL — one source we do not have

Aux has three: the merchant tooltip scan (we have this), `ShaguTweaks.SellValueDB`
as a fallback, and — **the one worth taking** — the **AH sell slot**.
`NEW_AUCTION_UPDATE` plus `GetAuctionSellItemInfo()` position 6 gives the exact
vendor price of anything a player posts, divided by charges or count. We already
handle that event and already have a sell slot. Every posted item would teach us
a vendor price, free.

That also makes the deposit exact rather than approximate. Aux:
`floor(unit_vendor_price * deposit_factor * stack_size) * stack_count *
duration_factor`, where `deposit_factor` is `.05` at your faction's AH and `.25`
neutral, and `duration_factor` is `minutes / 120`. Turtle's x3 durations flow
straight through: 72h = 4320/120 = **36**, against vanilla's 12 at 24h. That is
most of the "inflated deposit", and it is arithmetic, not a mystery. Our ~0.6
fudge exists only because we do not reliably know the vendor price.

#### Corrections to the brief, from source

- The expected-value sum also multiplies by the **quantity midpoint**
  `(min+max)/2`. The brief's version (probability x value) is the Classic/TBC
  form and understates every multi-drop material.
- `history.market_value()` is **today's** minimum buyout; `history.value()` is
  the 11-day age-weighted median. The brief has these swapped. The disenchant
  clamp is therefore `min(median, today)` — a pessimism clamp, not a comparison
  of two averages.
- The 4th argument to `disenchant.value` is a **not-disenchantable exception
  list**, not a value override. Same seven ids our `NEVER` table already has.
- Aux prints the **raw quantity range** `(1-2)`, not Enchantrix's `x1.5`
  midpoint. Same fact, two notations.
- If **any one material** is unpriced, aux returns nil for the whole item. That
  is the "Devout Belt never resolves" report — expected behaviour, not a bug.
  We should show the distribution anyway and name the missing material.

#### One genuine conflict to settle in game

**`INVTYPE_SHIELD`: aux says weapon, we say armour.** Armour is dust-led (~82%)
and weapons essence-led (~80%), so this swaps which material dominates. Our
table came from 8.8M observations and aux's is hand-written, so ours should
win — but disenchant a few shields and confirm. Aux also omits `INVTYPE_THROWN`,
`INVTYPE_RELIC` and `INVTYPE_TABARD` entirely, reporting them not-disenchantable.

Where the data overlaps we are better: we carry measured multi-material
distributions for uncommon *and* rare where aux's rare bands are a single
deterministic shard. Aux has five epic bands; they are as unmeasured as the ones
we dropped, so its epics are a guess presented without qualification. Our
silence is the more honest of the two — keep it.

### 2h — Session Purchase & Crafting Material Tracker

**Decided.** Add a real-time purchasing and material tracking widget to the AH interface to streamline bulk crafting and recipe purchases.

* **Session Purchase Counter:** A lightweight UI tracker anchored to the AH window logging items bought during the current shopping session (e.g., `Iron Ore: 10 purchased`).
* **Aggregate Inventory Awareness:** Real-time calculation of total materials owned across character bags, bank, mailbox, and alt character databases.
* **Goal Progress Ratio:** Displays contextual owned/purchased counts against target requirements (e.g., `Iron Ore — 25/40 available`).
* **Instant Tally Updates:** Refreshes inventory totals and session counts immediately upon buyout/bid confirmation.



---

## Phase 3 — History & Price Intelligence polish

- **Line graph** of profit/loss over time on the History tab. No charting
  primitive exists in 1.12 FrameXML — needs a short design spike (grid of
  `Texture` pixels vs. a `StatusBar`-based sparkline) before committing to
  an approach. **Phase 0.3 is settled (v1.4.0)**, so this is unblocked; read
  its note about plotting a median before designing the axes.
- **Disenchant value** in the tooltip — **building**, as §2 of 3k. The v1.28.1
  "no" was overturned: see 3k for which of its claims did not survive checking.
  v1.29.0 shipped the rule and v1.30.0 the tooltip line; learning item levels
  from play is next.

---

## Explicitly deferred / out of scope for now

- **Auto Buy** — decided out for Phase 2. Revisit only on explicit request.
- **Courier reading Aegis's data, or two-way sync** — decided against in
  Phase 1; the integration is one-directional (Courier → Aegis) to keep the
  cross-repo maintenance surface to a single function signature.
