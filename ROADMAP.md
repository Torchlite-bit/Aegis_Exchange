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

### 0.1 Realm-keyed price data
**Decided.** Price history currently lives under `AegisExchangeDB` — confirm
the exact keying in `core/db.lua` and, if it's scoped narrower than the
realm, widen it so every character on the same server pools into one price
history. Turtle's cross-faction AH (already a CLAUDE.md hard rule) means
there's no faction split to preserve — this is purely closing a
character/account split that shouldn't exist. `AegisExchangeCharDB` stays
per-character for things that should genuinely stay local (window position,
UI state); only price/market data moves.

### 0.2 Aegis: Courier integration surface
**Decided** (contract; implementation is this phase's task). Expose the
seam Courier will build against, so that repo has something stable from day
one instead of chasing a moving target:

- `AegisExchange.RecordExternalTxn(...)` (naming TBD at implementation time)
  — the one function Courier calls to push a matched mail transaction into
  Aegis's ledger. Courier never touches `AegisExchangeDB`'s internal shape
  directly; this function is the whole contract, so Aegis's internals can
  keep changing freely as long as the signature holds.
- `AegisExchange.INTEGRATION_VERSION` (or similar) — a small version number
  Courier checks so a future signature change is a detectable mismatch, not
  a silent miscount.
- Aegis's existing built-in mail scanner (`ui/frame.lua` `ScanMailSales` /
  `AuctionSoldItem`, shipped 0.17.0) detects Courier at `ADDON_LOADED` and
  **stands down** — skips installing its own mail hook — so a user running
  both addons never gets double-hooked mailbox handlers or double-counted
  sales. Courier becomes sole owner of mail scanning the moment it's
  installed; Aegis's own scanner is only active when Courier isn't present.

Full design (data-flow direction, standalone requirement) below in **Phase 1**.

### 0.3 Historical-value weighting audit
**Decided to do; outcome open.** `core/db.lua` `db.MarketValue` already does
daily-minimum + weighted-median over ~11 days. Before building the line
graph in Phase 3 (which will visualize this value), audit the actual
weighting curve against the target behavior — recent days weighted more,
decreasing effect past roughly a month — and close any gap between what's
implemented and what's intended. This is mostly verification, not new code.

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
  being touched: tab-complete, and starting a search by dragging an
  inventory item onto the box or right-clicking an item/item link.

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

---

## Phase 3 — History & Price Intelligence polish

- **Line graph** of profit/loss over time on the History tab. No charting
  primitive exists in 1.12 FrameXML — needs a short design spike (grid of
  `Texture` pixels vs. a `StatusBar`-based sparkline) before committing to
  an approach. Depends on Phase 0.3's weighting audit being settled first,
  since the graph visualizes that value.
- **Disenchant value** in the tooltip — needs a feasibility check first
  (is a disenchant-value source even available via 1.12 API); not committed
  until that's answered.

---

## Explicitly deferred / out of scope for now

- **Auto Buy** — decided out for Phase 2. Revisit only on explicit request.
- **Courier reading Aegis's data, or two-way sync** — decided against in
  Phase 1; the integration is one-directional (Courier → Aegis) to keep the
  cross-repo maintenance surface to a single function signature.
