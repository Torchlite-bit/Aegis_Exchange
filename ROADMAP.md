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
clause list rather than as prefix polish notation. What remains here is the
rest of aux's primitive set (`percent`, `vendor-profit`, `seller`, `left`,
stat-suffix matching) — the combinator work itself is done.

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

> ⚠️ **Import is absent from the bottom row on purpose.** The concept PNG
> still shows it because that image predates the "you can remove the import
> button" instruction. `ui.BuilderImport` went with the button. One line to
> put back if the concept is the intent.

### 2l — Concept-parity polish — ✅ **DONE** (v1.12.0)

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
- **Disenchant value** in the tooltip — needs a feasibility check first
  (is a disenchant-value source even available via 1.12 API); not committed
  until that's answered.

---

## Explicitly deferred / out of scope for now

- **Auto Buy** — decided out for Phase 2. Revisit only on explicit request.
- **Courier reading Aegis's data, or two-way sync** — decided against in
  Phase 1; the integration is one-directional (Courier → Aegis) to keep the
  cross-repo maintenance surface to a single function signature.
