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

    -- 2. Build the dedup key for an auction mail THROUGH THIS HELPER.
    local key = AegisExchange.MailTxnKey(subject, money, daysLeft)

    -- 3. Push the matched transaction.
    local ok, why = AegisExchange.RecordExternalTxn({
        kind   = "sale",        -- or "buy"
        item   = "Silk Cloth",
        amount = netProceeds,   -- copper, AFTER the 5% cut (what actually
                                -- arrived in the mail)
        itemId = 4306,          -- optional
        key    = key,           -- optional; repeats are ignored
    })
end
```

`RecordExternalTxn` returns `true`, or `false` plus a short reason
(`"duplicate"`, `"kind must be 'sale' or 'buy'"`, …) so Courier can surface
failures rather than miscounting silently. `INTEGRATION_VERSION` is currently
**1**; it bumps whenever a signature or field meaning changes.

**Why `MailTxnKey` is exposed rather than left internal.** A user who ran Aegis
alone already has auction mails in the ledger under *Aegis's* keys. If Courier
invented its own key scheme it would re-report those mails and double-count
every one of them on the day Courier is installed. Generating keys through the
shared helper makes the handover seamless. This matters more than it looks — it
is the single most likely way the integration could corrupt someone's history.

**Mail ownership** is an explicit handshake (`ClaimMailScanning` /
`ReleaseMailScanning`) rather than Aegis sniffing for a global, because explicit
survives Courier being renamed. There *is* a global-name fallback for a Courier
that loads without claiming, but it is a safety net, not the contract.

> ⚠️ **Open, for the Courier session to close:** that fallback currently guesses
> at `AegisCourier` / `Aegis_Courier`. Once Courier settles its real addon
> global, trim `COURIER_GLOBALS` in `core/db.lua` to the true name. Harmless
> either way as long as Courier calls `ClaimMailScanning`.

Full design (data-flow direction, standalone requirement) below in **Phase 1**.

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
  named multi-item lists searched sequentially) stays exactly as-is — aux
  doesn't have an equivalent concept, and it's a genuinely different use
  case from a single saved query. It is not being merged into Saved
  Searches.
- The right-hand content area gains a row of switchable views — **Search
  Results** (today's results table, now also accepting typed query syntax),
  **Saved Searches**, and **Filter Builder** — reusing the sidebar's screen
  real estate rather than adding a fourth top-level sub-tab.

### 2a — Parser, compiler, core primitives (same search box)
Nothing about today's casual usage changes: typing an item name still just
searches by name. Additionally supported in the same box:
- Blizzard-query / post-filter split — one Blizzard query per search term
  (drives page count via the existing 9-arg `QueryAuctionItems`), unlimited
  post-filters applied client-side as each page loads (`buy.ReadPage`
  already reads one page at a time — post-filters slot into that loop).
- `exact` modifier, tailored as tightly as the Blizzard query allows
  (level range, class/subclass/slot, quality) — cannot combine with a
  manual filter on those same fields.
- Tooltip-substring search, with the leading-term-vs-tooltip disambiguation
  aux uses (name search before any category term, tooltip search after; the
  `container/bag/tooltip/8` vs `container/bag/8` case is the concrete test).
- The two filters explicitly requested: buyout-only (exclude bid-only
  auctions), and fully-stacked-only (stack size == max for that item).
- Quick wins that only need the existing box, done here while it's already
  being touched: 
   - Right-click an item in your bags while on the Buy tab to instantly initiate a search for that item.
   - Right-click an item in your bags while on the Sell tab to automatically place it directly into the sell slot for auction creation.
   - Dragging an inventory item onto the search box or right-clicking an item link in chat.
   - Tab-autocompletion in the search bar.

### 2b — Filter Builder tab
Form-driven query construction mirroring aux's layout (Name / Level Range /
Item Class / Subclass / Slot / Min Quality on one side for the Blizzard
filter, primitives + combination on the other for post-filters) — but
**more efficient than aux's**, per your ask: aux requires hand-typing
arity-prefixed operators (`and2`, `or3`, ...) to nest conditions correctly,
which is a well-known rough edge. Aegis's builder manages that nesting
automatically — click **+ Condition**, pick AND/OR, and the generated query
string is always correctly nested without the user ever typing polish
notation by hand. Search / Export / Import actions, same as aux.

### 2c — Saved Searches tab
Favorites and Recent, styled after aux's split-column layout. Hover for a
formatted tooltip, left-click to run, right-click for a context menu,
shift-click to copy the query into the search box, shift-right-click to
append to whatever's already there. No Auto Buy toggle (decided above).

### 2d — Full primitive set + boolean combinators
Everything from 2a's primitive set generalized under full `and`/`or`/`not`
prefix-notation combination, plus stat-suffix matching (the
`+3 stamina/+3 agility` wristband-suffix case) and any remaining aux
primitives worth carrying over.

### 3e — Blizzard-style Category Navigation Tree
Decided. Integrate default Blizzard-style category browsing directly into the search interface
- Displays a collapsible category tree on the left side of the search view (e.g., Weapons > Two-Handed Maces or Armor > Leather).
- Allows users to easily browse specific item slots or types visually without having to rely strictly on typing name search queries or remembering syntax.
 - Category filters feed cleanly into the underlying search engine alongside post-filter rules.

### 3f — Session Purchase & Crafting Material Tracker

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
