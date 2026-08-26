# Changelog

All notable changes to **Aegis: Exchange**.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
The version here matches `## Version` in `Aegis_Exchange.toc` and the number
printed in the window title bar — quote it in bug reports.

> ⚠️ Releases marked **restart** add a new `.lua` file. WoW 1.12 reads the file
> list at startup, so `/reload` won't pick them up — you need to fully restart
> the client. Everything else is `/reload`-safe.

---

## [1.45.1]

### Changed
- **The disenchant diagnosis no longer resolves the item twice.** v1.45.0 asked
  `de.MissingPriceOf` separately from `de.ValueOf`, which repeated the whole
  resolve — taking an unpriced item's tooltip from one item lookup to three, on
  exactly the items most likely to be unpriced, which is most of them before a
  scan. `de.ValueOf` now hands back *why* it failed alongside the failure.

## [1.45.0]

**The tooltip, rebuilt as sections.** Last of the aux work. `/reload`-safe.

### Added
- **Every number now carries what qualifies it.**
  - *Market* shows how many **days** the median rests on. One day and thirty
    produce the same-looking figure and are not the same claim, and the tooltip
    is the only place a player ever sees either.
  - *Min Buyout* shows today's cheapest **as a percentage of market**, which is
    the only thing it means. A bare figure made every reader do that division.

- **A verdict on the disenchant line.** *worth more than vendor*, *worth more
  than the AH*, or *sells for more than it breaks for* — the comparison that
  made you hover in the first place, rather than a number you then have to
  compare yourself. Silent when there is nothing to compare against, and silent
  when the two are within 10% of each other, because a verdict on a 3%
  difference is noise.

- **An unresolvable value now says why.** `de.Value` is all-or-nothing: one
  unpriced material and the whole figure disappears. That is right for the
  number — a partial sum understates, and an understated gold figure is worse
  than none — but it made a useless explanation. The line now appears with a
  grey `?` and **names the material standing in the way**: *no price yet for
  Large Radiant Shard*.

  This is the long-standing "that item has never worked" complaint, and it was
  never a bug in the rule. aux has the same behaviour and the same silence.

- **"Always show the breakdown" setting.** The material list is off by default —
  three extra lines on every disenchantable item — and **Shift still shows it on
  demand whatever the setting says**. The two gates are independent, so turning
  the setting off does not take away the gesture.

### Not built
- **Vendor *buy* prices.** aux learns what a merchant charges as well as what it
  pays, and flags limited stock. Aegis never scans a merchant's inventory, so
  there is nothing to show — that is a feature, not a line, and it can have its
  own release rather than a half-built one here.

## [1.44.0]

**The item-fact harvest.** `/reload`-safe — no new files.

### Added
- **Aegis now keeps its own copy of what the client's item cache knows.** On
  1.12 `GetItemInfo` answers only for items the client has already seen, so the
  disenchant line and both disenchant search filters went blank for every
  auction row whose item this machine had never happened to look at — however
  much Aegis knew about it last week.

  A background sweep copies quality, required level and equip slot into
  SavedVariables as it finds them. Coverage stops resetting with the client's
  cache and starts accumulating: **`de.Resolve` now falls back to the harvested
  facts**, so a row for an unseen item still gets an answer.

  Paced at 500 ids per half second, starting about six seconds after login
  (login being the busiest the client ever is, and this the least urgent thing
  in the addon). It skips what it already has, so each session costs less than
  the last, and it stops for good — frame hidden, script cleared — when it
  reaches the top of the range. The range runs to 120,000 because Turtle's
  custom items sit far above where vanilla's stop.

- **`/aex cache`** reports how many items are known and whether the sweep is
  still running. It is silent by design, and "is it doing anything" had no other
  answer.

### Correction
- **An earlier release claimed `GetItemInfo` queries the server for an uncached
  item. It does not.** It returns nil and does nothing else; the call that
  forces a fetch is a tooltip `SetHyperlink`. aux settles it — its cache-warming
  command reads `if not GetItemInfo(id) then SetHyperlink(id) end`, which is
  only meaningful if the first is a free probe and the second is the fetch.

  That claim shipped in v1.41.2's throttle (since rolled back, so no code
  carries it) and survived in comments. Corrected where it stood, because it is
  the difference between this release's sweep being free and being unshippable.

## [1.43.0]

**Disenchant values now answer without ClassicAPI.** `/reload`-safe.

### Added
- **A fourth item-level source: the required level.** 1.12 hands every addon the
  level needed to *equip* an item and no item level at all, so without a mod
  exposing the real one the disenchant line simply never appeared — for most
  players, on most items. It now falls back to the required level plus 5.

  **Where the 5 comes from.** aux keys its entire disenchant table on required
  level, so its band boundaries and ours describe the same items on two
  different scales. Lining the two up by *material signature* — which materials
  each band yields, independent of any assumed offset — puts every one of aux's
  20 uncommon and rare bands **exactly** 5 below ours, with no boundary
  disagreeing. Four of the 20 differ in their material list, and all four are
  places our own generator dropped a low-probability tail material for having
  too few items behind it. That is a known thinness in our data and says nothing
  about the offset.

- **The tooltip says when a value is approximate.** A disenchant line resolved
  this way reads **Aegis Disenchant (approx)**; one resolved from a real item
  level or from a disenchant you performed keeps the plain label. Required level
  moves in steps of 5 where item level does not, so an item near a boundary can
  land one band out — and adjacent bands differ by more than double in yield.
  The number is worth showing. It is not worth showing as though it were
  measured.

### Ranking
Strongest first, and a caller only ever sees the one that answered:
**observed** (you disenchanted it) → **client** (ClassicAPI's real number) →
**required** (this, approximate). The new source is last, and cannot outrank
either of the others.

### Fixed
- **`/aex de` reported "unknown" for items the tooltip was answering for.** It
  called `de.ItemLevel` without passing the item info the required-level
  fallback reads.

## [1.42.0]

First of the changes from reading aux. `/reload`-safe — no new files.

### Added
- **Vendor prices are now learned from the auction house sell slot.**
  `GetAuctionSellItemInfo`'s sixth return is the item's vendor price for the
  whole stack in the slot — the client states it outright. Aegis has always read
  that value (as the deposit base) and thrown it away; it now records it, divided
  down to a unit price.

  This is the vendor-price source that costs you nothing. Learning at a merchant
  needs you to walk to one with the item in your bags; ClassicAPI needs a DLL.
  This needs you to do the thing you opened the auction house to do — **every
  item you ever post now teaches Aegis its exact vendor price.**

  It feeds everything that already reads a vendor price: the tooltip's Vendor
  line, the Sell tab's vendor comparison, the Vendor list, and the
  `vendor-profit` search filter — whose "no answer" hint now names the new source
  alongside the old ones.

### Known inexactness
- **Charge items resolve high.** For an item with charges, 1.12 reports the
  full-charge price in this slot, and there is no charge count in that API to
  divide by. A partly-used charge item will therefore read as worth more than it
  is. Walking past a merchant with it corrects the number — that path is exact,
  and a later write wins. Recording it anyway is the deliberate call: the
  alternative was dropping a source that answers for everything else over a
  narrow case.

## Restored to 1.41.1 — **restart**

**The crash was the client install, not the addon.** After reinstalling mods,
patches and DLLs, v1.41.1 runs clean on the Auctions, History and Crafting
tabs. The 1.39.0 rollback is undone and the shipping code is v1.41.1 again,
byte-for-byte.

> ⚠️ **Full client restart, not `/reload`.** This removes `core/itemlevel.lua`
> from the `.toc`, and 1.12 reads the file list only at startup.

So ClassicAPI vendor prices and item levels are back, along with the tooltip's
`SetHyperlink` fallback for auction rows after the AH has been closed and
reopened.

### Not restored
- **v1.41.2's `GetItemInfo` miss gate.** It is a real improvement and was
  measured — a sweep down 40 auction rows cost 32 `GetItemInfo` calls before it
  and 1 after, and re-hovering one row twenty times went from 20 to 0 — but it
  was written to fix a crash it did not fix, and never ran in a healthy client.
  v1.41.1 is what has actually been verified, so v1.41.1 is what ships. The gate
  can be re-applied on its own merits, as its own release, and tested properly.

### What the three failed fixes were worth
v1.41.0, v1.41.1 and v1.41.2 all claimed a crash that no addon change could
have fixed. Two things came out of that hunt that stand on their own: the
tooltip fallback in v1.41.1, and the measurement rig that drives the real
`ui/frame.lua` against a mock client — see `ROADMAP.md`, which also records
what would have to change in `tests/support/wow.lua` to bring it into the suite.

## [1.41.2]

**The crash to desktop, found and fixed.**

### Fixed
- **Hovering rows on the Auctions, History and Crafting tabs froze the client
  and then killed it.** On 1.12, `GetItemInfo` answers from the client's item
  cache — and for an item that is **not** in it, the client asks the **server**
  and returns `nil` in the meantime. Nothing remembered that `nil`, so every
  hover asked again.

  Measured against the real window: re-hovering **one** auction row twenty times
  cost twenty `GetItemInfo` calls, and sweeping forty rows cost thirty-two. Where
  the items are cached that is free, which is why the Buy tab was always fine —
  its rows sit on the auction page the client just loaded. Auctions, History and
  Crafting draw from mail, the ledger and recipe reagents, none of which the
  client has necessarily seen this session, and those are exactly the lists you
  sweep the mouse down. Forty rows is forty server queries in about two seconds.

  Misses are now paced by a per-item cooldown *and* a burst budget, so a sweep
  costs a bounded few queries instead of one per row. Only misses pay either
  limit: sixty-one cached items still resolve in sixty-one calls, so the Buy tab
  and the bag browser are untouched. Nothing is blocked permanently — the query
  that does go out warms the cache, and the next lookup past the cooldown picks
  the answer up. Same bargain the scanner strikes with `CanSendAuctionQuery`:
  progress, paced.

  Same measurements after the fix: forty rows **1**, twenty re-hovers of one row
  **0**, sixty-one cached items **61**.

### Note on v1.41.1
- v1.41.1 said it fixed this and did not. The three crashing tabs are precisely
  the three that never call `db.GetVendor`, so the fallback it removed was not on
  the path. What v1.41.1 *did* do is real and worth having: v1.40.0 had tripled
  the per-hover cost (1 → 3) by adding two more lookups to the same tooltip path,
  which is the regression that made a long-standing problem suddenly fatal, and
  removing them put it back to 1. This release removes the remaining one.

## [1.41.1]

### Fixed
- **Auction tooltips degraded to just the item name after leaving and returning
  to the auction house.** Both routes into the tooltip read the auction page the
  client currently holds, and that page is discarded when the auction house
  closes — so a Buy tab still showing your last search had rows whose tooltips
  had nothing behind them until you searched again. There is now a fallback to
  the item link itself, which does not depend on a live page.

### Changed
- **The client-data readers no longer call `GetItemInfo`.** `util.ClientSellPrice`
  and `util.ClientItemLevel` fell back to it when ClassicAPI was absent or had no
  answer. On 1.12 that is a cache read only for an item the client has already
  seen; for an uncached one it sends a query to the server — and `db.GetVendor`
  is called once per bag item, once per auction row and once per tooltip, so the
  fallback multiplied by the length of whatever list was being painted. That is
  HARD RULE 16 broken by a fallback rather than by a handler, which is worth
  closing on its own merits.

  Both readers are ClassicAPI-only now. A caller that already holds a
  `util.ItemInfo` can pass it in; nothing fetches one on their behalf. The suite
  counts `GetItemInfo` calls and requires zero from these paths, with and
  without ClassicAPI.

### Still open
- **The crash to desktop on the Auctions, History and Crafting tabs is NOT
  fixed, and the change above was mis-attributed to it when this release was
  cut.** The three tabs that crash are precisely the three that never call
  `db.GetVendor` on their paint path, so that fallback cannot have been the
  cause. Driving all six tabs against a mock client — empty and populated,
  every sort column, both directions — produces no Lua error, reaches no
  ClassicAPI entry point on tab selection, and creates no unbounded number of
  frames. v1.40.0, the release the crash was first seen on, changed no UI file
  at all. Diagnosis continues.

## [1.41.0] — **restart**

The scaffolding around a missing number comes out. **Removes a `.lua` file, so
this one needs a full client restart, not `/reload`.**

### Removed
- **`core/itemlevel.lua`** — 12,567 item levels borrowed from ShaguScore,
  shipped since v1.31.0 because 1.12 gave addons no way to get one. ClassicAPI
  provides the client's own: the real number, for **every** item, including the
  two thirds of Turtle's custom gear the borrowed table never had. A partial
  copy of a number you can read directly has nothing left to do.

  Deleting it also retires the question of whether shipping someone else's
  unlicensed database was all right — a better way for that question to end
  than any answer to it would have been. Thanks to shagu for the years it
  covered the gap.

- **`/aex de audit`** and the required-level comparison behind it. It existed
  to decide whether required level could stand in for item level; that question
  is not asked any more. `tools/gen_itemlevel.py` goes with the file it
  generated.

### The trade, stated plainly
**Without ClassicAPI the disenchant line now answers only for items you have
disenchanted yourself.** It previously answered for vanilla items from the
borrowed table. That is the cost of the deletion and it is deliberate.

### Added
- **The UI says so.** The *Disenchant value* setting and both Filter Builder
  components (`disenchant-profit`, `disenchant-percent`) carry a hover
  explanation naming the requirement — and noting that disenchanting something
  teaches Aegis about it regardless. A feature that goes quiet without saying
  why reads as broken.
- **Vendor price gets the same treatment**, worded honestly: it is *learned at
  a merchant*, and ClassicAPI makes it instant for every item. It has never
  required the DLL and the tooltip does not claim it does.
- `ui.SetHelpTip`, since checkboxes had no hover explanation of any kind.

### Not covered by tests
The help tooltips are not asserted anywhere — no suite loads `ui/frame.lua`.
The strings and the tables behind them are shared single writers, which is
mitigation rather than coverage, and worth saying rather than implying
otherwise.

---

## [1.40.0]

Aegis stops guessing two numbers the client has had all along. `/reload`.

### Added
1.12 fills in an item's **vendor sell price** and its **item level** on every
item and displays **neither** — the sell-price field is populated and the
engine's tooltip code simply never reads it. Where a client mod
([ClassicAPI](https://github.com/brues-code/ClassicAPI), a DLL) exposes them,
Aegis now reads both.

- **Vendor prices are known, not learned.** Previously Aegis only knew what a
  merchant paid if you had stood at one with that item. Ranking is now
  `client` → `merchant` (what we learned) → unknown, and `db.GetVendor` returns
  the source alongside the number — a price the client states and one we
  watched a merchant offer are different kinds of fact.
- **Item level is read, not borrowed.** The disenchant rule has always been
  exact *given* a level; the level was the only missing input. Ranking is
  `observed` (what you disenchanted) → `client` → the shipped table → unknown.
  Observation stays on top because it reflects the server you actually play on.
- **Turtle's custom items become answerable.** Roughly two thirds of them are
  absent from the shipped item-level table. The client knows all of them.

Detected as **capabilities**, never by addon name or version — the same rule
the scanner applies to AuctionQueryThrottle, where the query gate itself is the
detector. Asked per function, so a build providing one and not the other costs
one feature rather than both.

**Nothing degrades without it.** Every path behaves exactly as v1.39.1 did when
no such mod is present, which is the case for most players, and a test asserts
that directly rather than assuming it.

### Dropped
- **The required-level fallback (§5) will not be built.** Its measurement,
  shipped in v1.39.0, came back **0 items judged, 12,135 uncached** — 1.12's
  item cache only holds what your client has seen, so a bulk sweep cannot
  work. And it is moot now: there is no reason to approximate a number you can
  read. `/aex de audit` stays, since it still answers "how good would that
  guess have been".

### Hardened
- `util.ItemInfo` now handles a **third** `GetItemInfo` shape. It anchors on
  "the last value that is a number" — right for vanilla's 9 and later clients'
  10, and exactly wrong for modern WoW's 18, where six numbers sit *after*
  stack count. A mod that replaced the global rather than namespacing it would
  have had Aegis read the class id where the required level belongs: small,
  plausible, silently wrong integers. Defended rather than trusted.

---

## [1.39.1]

Rows and their last column stop running under the box border. `/reload`.

### Fixed
- **Table rows drew underneath their own box's right border.** A backdrop edge
  is drawn *centred* on the frame boundary, and every table's box is anchored
  to its scroll frame's right edge — so a row spanning the scroll frame's full
  width ended up half under that border, and its rightmost column with it.

  One bug, two faces: the **bag rows visibly poking through the box edge**, and
  the Buy table's **"% Mkt" being shaved** by it. Both are fixed by the same
  `ROWPAD`, which every row builder and both layout functions read — the rows'
  inset and the width the columns may use are one measurement seen from two
  ends.

- **Every heading would have drifted off its column** as a result, by 2px on
  the left of each table and 8px on the count column in the bag list — headings
  anchor to the panel and the box, and it was the *rows* that moved. Caught
  before shipping and fixed at all six anchor points; a heading that disagrees
  with its cells is the defect these tables keep being fixed for.

Also applied to Auctions and History, which have the same construction and
therefore had the same overhang, unreported.

---

## [1.39.0]

The measurement that decides whether Aegis gets a fourth source of item level.
`/reload`.

**This release does not build that source.** It builds the thing that says
whether it should exist, because the brief for it said not to build it until
the number was in hand.

### Added
- **`/aex de audit`** — walks the shipped item-level table and, for every item
  your client has cached, compares the band the item's *real* level gives
  against the band its **required** level would have given.

  That is the open question from the disenchant work. aux feeds `GetItemInfo`'s
  slot 4 — which on 1.12 is required level — into a table that wants item
  level. Aegis has refused to, on the grounds that a disenchant band is one
  material tier wide so a near miss is not a near miss. That was **reasoning,
  not measurement**. This measures it.

  It cannot be measured anywhere but in a client: `minLevel` comes from
  `GetItemInfo`, which only answers for items that client has already cached.
  So the audit reports what it could **not** judge rather than quietly skipping
  it — a run that saw 200 items has measured 200 items, not the game — and
  declines to conclude anything under 200.

### How it scores, and why that way
- The bar is **95% agreement**, deliberately high.
- **One band out counts against it as hard as a wilder miss.** A band is one
  material tier wide: "off by one" is Dream Dust where the answer was Illusion
  Dust, not a rounding error.
- An item with **no level requirement** yields no band at all, so the fallback
  would *decline* rather than answer. That is a safe failure and is tallied
  separately — counting it as wrong would reject the fallback for the wrong
  reason.

If it clears the bar, required level becomes a last-resort source **for the
filters only** — never the tooltip, and never for advising you to destroy
something.

---

## [1.38.0]

Rows light up under the cursor in every table, not one. `/reload`.

### Changed
- **The hover highlight is part of the shared row chrome now**, so Buy results,
  Crafting results, Your Bags, Auctions and History all get it — previously the
  Sell tab's listings were the only data table in the window that had one.

  Worth naming what the inconsistency was actually signalling: the highlight
  read as *"this row is interactive"* when it really meant *"this row happened
  to be built as a Button"*. Every one of these rows is interactive.

- **Four row types are Buttons instead of Frames.** `SetHighlightTexture` is a
  Button method and does not exist on a Frame, which is why those tables had no
  hover. The change also removes the reason `BuildResultRow` needed
  `EnableMouse` to get a tooltip at all, and the reason selecting a Buy result
  goes through `OnMouseDown` — its own comment reads *"A Frame has no
  OnClick"*. Those workarounds are left in place for now: frame type first,
  simplify once it has been seen working.

- **History rows had no mouse enabled at all**, so they received no hover
  events of any kind. A ledger line is not clickable, but it should still light
  up like every other row.

### The bug this deliberately avoided
The obvious implementation is `row:SetScript("OnEnter", …)` to show a texture.
In WoW `SetScript` **replaces** a handler rather than adding to it — and four
of these tables already own their `OnEnter` **to show an item tooltip**. That
patch would have silently deleted the tooltips on all four: nothing errors,
every row draws, the highlight works perfectly. Asking the client for a
highlight instead needs no script at all, which is why it is done that way.
There is a sabotage planting the script version.

### Not covered by tests
`rowchrome_test.lua` asserts the highlight is requested, that it does not join
the three ordered BACKGROUND textures, and that a Frame-shaped row degrades
instead of erroring. It **cannot** tell you whether the highlight looks right
beside the listings table, or whether making a row clickable broke a click that
used to reach a child — the Buy tab's batch tick boxes are the place to check.
Both need the client and a person.

---

## [1.37.0]

The listings table uses its window, and every layout runs on resize. `/reload`.

### Fixed
- **The Buy table's "use the whole window" fix, shipped in v1.35.0, never ran
  when you resized the window.** It lived in `ui.LayoutBuyTable()`, and the
  resize grip re-laid out four things — not that one. So dragging wider grew
  the table and left its columns at their minimum until a Blizzlike/Advanced
  toggle happened to fix them, at which point they jumped. The fix was inert in
  exactly the situation it was written for.

  There were **two lists** of "things to re-lay out" — one in the grip, one in
  `ui.SetBuyMode` — and they disagreed. There is one now, `ui.LayoutAll()`, and
  both callers use it. Two lists of the same thing is how the next entry gets
  forgotten.

### Changed — the Sell tab's listings columns
- **One gutter (14px) and one alignment rule.** Worth understanding before
  editing them: the old set already had *identical* 4px gutters and still read
  badly. What varied was the **justification** either side of each one.
  RIGHT-then-LEFT (`Unit price → Available`, `% mkt → You?`) put two texts 4px
  apart; LEFT-then-RIGHT (`Available → Stack price`) put a short value at the
  far left of a 156px column and the next at the far right of the one after —
  about **178px of void out of 4px of gutter**. Both complaints, one cause.
- **`You?` is centred**, which is what stops it colliding with the
  right-aligned `% mkt` before it. Same medicine as the Buy table's `Lvl`.
- **`Available` absorbs the surplus width**, so `Stack price`, `% mkt` and
  `You?` sit against the right edge where the eye looks for totals. The columns
  were a fixed 490px block in a box that is ~630px at the *smallest* window and
  unbounded above — everything past that was dead table that grew the wider you
  dragged.

### A note on what is and is not guarded
The column geometry is asserted: one gutter between every pair, and
`SELL_COLS_END` checked against where the last column actually ends rather than
a hand-written sum. **The resize wiring is not.** No suite loads `ui/frame.lua`
or simulates a drag, so nothing would catch `ui.LayoutAll()` losing a line. The
mitigation is structural — one list instead of two — not a test, and it is
worth saying so plainly rather than implying coverage that does not exist.

---

## [1.36.0]

The Sell tab's bag column: headings, indent, scrollbar. `/reload`.

### Fixed
- **"Your Bags" and "Qty" rendered grey while the listings headings two inches
  away rendered tan — from the identical palette entry.** The colour was never
  wrong. These were bare FontStrings on the panel, and in WoW every child
  *frame* draws above **all** of its parent's regions whatever draw layer they
  claim — so the headings were drawn underneath their own table's 85%-opaque
  backdrop and came out darkened. The listings headings escaped it only because
  they happened to be built as Buttons.

  Both now go through one `ui.MakeHeaderCell`, so a heading is a child frame
  wherever it appears and the difference cannot come back. Setting the colour
  again would have fixed nothing.

- **The bag list's scrollbar cut through the box's right border.**
  `FauxScrollFrameTemplate` anchors its bar 2px *inside* the scroll frame's
  right edge; a backdrop edge is drawn *centred* on that same line and so hangs
  6px outside it. The bar therefore ran through the border and 2px into the
  box. It is pushed clear now, and the gutter widened so it also clears the
  **listings** box's border on the far side — three numbers that are really one
  measurement, with an assertion tying them together.

### Changed
- **"Your Bags" is indented to line up with the item names beneath it**, rather
  than sitting flush on the box edge. Same rule the numeric columns follow — a
  heading is placed the way its cells are — applied to the left edge.

---

## [1.35.0]

Spacing and alignment across both tables. `/reload`.

### Sell tab
- **The bag column got wider, the listings narrower.** The listings table had
  ~170px of slack at the minimum window size while the bag column had none and
  was clipping item names. The two now split the space nearer to how they use
  it.
- **"Have" is "Qty"**, and it is a proper column: wider, **centred** under a
  centred heading, and held off the box edge. A right-aligned number flush to
  a border reads as though it is falling out of the table.
- **"Your Bags" and "Qty" are the same colour as the listings headings.** They
  were the same *literal* before and could drift apart; both now read one
  palette entry, `C.header`, so they cannot.
- **Your gold sits bottom-left**, as it does on the Buy tab. Posting is the one
  place in the addon where you watch a number go up, and the tab that does it
  was the only one that never showed you the number. **Vendor** and **Scan**
  moved right to make room, and up slightly.
- Gold now refreshes on `PLAYER_MONEY`, so a sale, a repair or a trade updates
  both tabs. Previously the Buy tab's figure only refreshed when you switched
  to it or bought something.

### Buy tab — results table
- **One gutter between every pair of columns**, instead of the 6/8/18 mix these
  had grown into. Uneven gutters are why a table reads as assembled: the eye
  finds the rhythm and then loses it, and reads the break as a mistake in the
  data.
- **Lvl is centred**, not right-aligned. It sat right-aligned immediately
  before a left-aligned Time Left, which pushed the two columns into the gap
  between them and left air on the outside of both. A level is a two-digit
  label, not a magnitude read digit by digit.
- **The table uses the whole window now.** Column widths were measured against
  the difference between the two view modes, which is the same number as the
  row width only at the minimum size — so dragging the window wider grew the
  table but not its columns, leaving a strip of empty table down the right
  that got bigger the more room you gave it.

### Fixed
- `ui.MakeSortHeaders` had no `CENTER` case, so a centred column's heading fell
  through to left-aligned and sat over the left edge of centred cells — which
  looks like a mistake in the data rather than in the layout. Found while
  centring Lvl.
- The geometry suite's table reader could only find a field that **started** a
  line, so the Buy table's packed column definitions read as "the table moved"
  rather than "the table is formatted differently". Eight new assertions
  depended on it.

---

## [1.34.0]

The Sell tab's bag list is a table now, not a list of text. `/reload`.

### Changed
- **"Your Bags" gets the same treatment the listings table got**: one box
  around the heading and the rows, a rule under the heading, and the scrollbar
  hanging outside the box. Both halves of the tab now start and end on the same
  lines, which is asserted so they cannot drift apart again.
- **The count moved into its own right-aligned "Have" column** instead of being
  glued to the end of the name as `Ice Cold Milk x35`. A number you have to
  read out of the middle of a sentence is not a column, and this list sits
  beside one whose numerics all line up.
- A holding of **one shows blank** rather than `1`. A column of ones down the
  side of a bag list is noise; the interesting fact is a stack, and spelling
  out the dull case hides it.
- **Vendor** and **Scan** moved below the box. They used to float over the top
  edge on the row the heading now occupies, and under it they line up with the
  listings' status line.

### Added
- `tests/lint/palette.py` — every `C.<colour>` the UI reads must exist in the
  palette.

  **This one has a story.** `C.textDim` does not exist; the palette has
  `goldDim`. That typo passed the Lua parser, all eight lints, all 16 suites
  and 140 sabotages, because `ui/frame.lua` builds a window on load and so no
  suite loads it — the line would simply have thrown the first time anyone
  opened the Sell tab. Now it is caught before a commit, with its own selftest
  and a sabotage that plants the exact mistake back.

---

## [1.33.0]

`disenchant-profit` stops being pending, and brings a sibling. `/reload`.

### Added
- **`disenchant-profit/<price>`** — gear worth at least that much more broken
  than bought. `wristbands/disenchant-profit/1g`.
- **`disenchant-percent/<n>`** — the same question as a ratio: at most `n`%
  of what it breaks into. `wristbands/disenchant-percent/70`.

Both are **per item**, because each disenchant rolls the table again — a stack
of five is five separate breaks, not five times one number.

`ui.PENDING_COMPONENTS` is down to a single entry (`item`), which is the first
time since the Builder was written that almost everything in it works.

### An unknown value is not zero
A row Aegis cannot value is **counted and confessed**, never silently dropped.
Treating an unknown disenchant value as zero would make
`disenchant-profit/1g` quietly reject every item Aegis has not learned yet —
which reads as "nothing here is profitable", the most misleading answer
available and indistinguishable from a filter that works.

The status line says which remedy applies: *"disenchant one, or scan its
materials"*. Both components deliberately share that wording, because
`UnansweredSummary` withholds advice when two components want different
remedies, and a query using both would otherwise lose its advice line
entirely.

A **bid-only** auction still is not in that count. It has no buyout because
the seller set none; that is a fact about the auction, not our ignorance, and
no amount of scanning or disenchanting changes it.

### Notes
- These are the first components that cost a `GetItemInfo` per row — everything
  else reads page data the client already holds. Affordable because it happens
  only when one of them is in the term, and because the `tooltip` component
  beside them already scans a whole tooltip per row. It is **not** affordable
  unconditionally, so it must not be hoisted into `ReadPage`.
- Five new sabotages, including both operators inverted and the unknown-as-zero
  shortcut. 140 caught in total.

---

## [1.32.0]

Aegis now learns what things disenchant into by watching you do it. `/reload`.

### Added
- **Disenchanting an item teaches Aegis about it.** No configuration, nothing
  to turn on. This is the only source that can ever answer for the two thirds
  of Turtle's custom items the shipped table has never heard of — and it is
  evidence from the server you actually play on, so it **outranks** the
  shipped item levels rather than filling gaps around them.

- **Evidence accumulates; it is not believed on the first result.** An essence
  names an item's band outright, but a dust does not — Strange Dust belongs to
  bands 15, 20 and 25, whose yields differ by more than double. Of the 30
  material/quality combinations the table can produce, 21 pin a band and 9
  leave two or three open. Until the evidence narrows to one, Aegis keeps
  saying nothing rather than picking.

### How it knows what you disenchanted
1.12 never reports it: a spell is cast, a bag item is clicked, and neither step
names the item. Aegis remembers what the click landed on and attributes a loot
window to it only when **all four** hold — a spell was awaiting an item target,
the item can actually be disenchanted, the loot arrived within 15 seconds, and
**every** loot slot is an enchanting reagent.

That last one is what makes it work without reading a spell name (which is
localised, and would have needed an answer about Turtle's cast bar that the
client source does not give). The second is what stops a lockbox being
"learned" from the shard you picked out of it.

Cost is one table write per bag click and a read of one or two loot slots —
nothing walks your bags, so HARD RULE 16 holds by construction.

### Corrected
- A claim in ROADMAP 3k that "one disenchant identifies the band for 46 of 53
  material signatures" was **wrong** — it conflated a full signature (every
  material an item can yield, which takes many breaks) with a single
  observation (one material). The measured figure is 21 of 30 combinations.
  Corrected in place rather than quietly dropped.

### Notes
- **Observations only** are saved. No band, no item level, no guess is ever
  written — everything above the counts is derived at read time, every time. A
  derived value stored beside real evidence becomes indistinguishable from it a
  month later, and there is no way back from that. A test asserts the store
  holds nothing else.
- Observations are per realm, because what an item breaks into is server
  behaviour.
- New suite (34 checks) and eight sabotages, most of them about cases where
  **nothing** should be recorded — a false observation is permanent, so those
  matter more than the happy path.

---

## [1.31.0]

**The disenchant line actually appears now.** `/reload` — no new files, because
`core/itemlevel.lua` has been in the `.toc` since 1.29.0 waiting for exactly
this.

### Added
- **12,567 item levels**, in `core/itemlevel.lua`. That is the one input 1.12
  does not give addons and the whole disenchant calculation turns on, so with
  it in place the tooltip line — shipped inert in 1.30.0 — starts answering for
  vanilla items and roughly a third of Turtle's custom ones.

  Source: **[ShaguScore](https://github.com/shagu/ShaguScore)** by **shagu**,
  with thanks. ShaguScore carries no licence of any kind, so including it was a
  deliberate call by this project's owner rather than something done quietly —
  see the header of `core/itemlevel.lua` and ROADMAP 3k. If shagu would rather
  it were not there, it comes out and the addon keeps working.

- `tools/gen_itemlevel.py`, so the file is regenerable rather than a 141 KB
  blob nobody can check. The input is not vendored.

### Notes
- Item levels **above 65 are kept** even though the disenchant ladder stops
  there. This is an item-level lookup, not a disenchant-band lookup, and
  knowing something is item level 70 is different from knowing nothing about
  it — `/aex de` now tells you which of those it is.
- Anything with no entry still says **nothing at all**. That has not changed
  and is not a gap waiting to be filled with "unknown".
- A sabotage now plants an emptied table, because a regeneration that produced
  a truncated file would otherwise be invisible: the addon loads, every line
  goes quiet, and it looks exactly like the release before this one.

---

## [1.30.1]

A fix to the one command that could show 1.30.0 working at all. `/reload`.

### Fixed
- **`/aex de <link> <item level>` silently ignored the item level** for any
  item whose id happened to contain the same digits — `48` was dropped on item
  4801, on 7448, and on a good slice of the table besides. The override was
  being read from the whole string and then filtered by asking whether the link
  contained those digits, which is not a question that can distinguish them.
  It now reads only what follows the link.

  This mattered more than a normal parser bug: with `core/itemlevel.lua`
  shipping empty, this command is the **only** path that reaches the
  disenchant rule, so the fault made the entire 1.29.0/1.30.0 feature look
  like it did nothing.

### Added
- `/aex de` now accepts a **bare item id** as well as a link —
  `/aex de 12345 48` — so the rule can be tried on items you do not own.
- The parsing is extracted as `de.ParseReportArgs` and tested (18 checks,
  including the exact regression above) instead of living inline in the slash
  handler where nothing could see it.

---

## [1.30.0]

The disenchant value reaches the tooltip. `/reload`.

### Added
- **Expected disenchant value on item tooltips**, with the full material
  breakdown while **Shift** is held:

  ```
  Aegis Disenchant     1g 84s
    78%  1.5 x Dream Dust
    18%  1.5 x Greater Nether Essence
     4%  1.0 x Large Radiant Shard
  ```

  Toggle it on the Aegis tab beside the other three tooltip lines.

- **The value is per ITEM, and deliberately does not multiply by the stack.**
  The price lines beside it do, which is exactly what makes this easy to get
  wrong — but each disenchant rolls the table again, so a stack of twenty is
  twenty separate draws rather than twenty times one number. There is a test
  and a sabotage holding that line.

### It says nothing far more often than it says something
The line appears only where the rule can genuinely answer: a cached,
disenchantable item whose **item level** some source knows. Today that is rare,
because `core/itemlevel.lua` ships empty on purpose — see 1.29.0. Everything
else gets **no line at all**, rather than "unknown" on every grey, trade good
and uncached item in a full bag.

That is not a placeholder for a better message. Silence is the message.

### Under the hood
- `de.Resolve` / `de.YieldOf` / `de.ValueOf` — one place that turns an item id
  into everything the rule needs, so the tooltip and `/aex de` cannot drift
  apart. `de.MarketPrice` and `de.BreakdownText` are shared by both for the
  same reason.
- `de.ValueOf` returns **value, source** — where the *item level* came from,
  never where a price did. That is the fact a later phase weighs when deciding
  whether it may advise on a number or merely show it.
- The test harness can now load `ui/` modules, so tooltip behaviour is testable
  at all. First suite in (17 checks) plus three sabotages; the disenchant suite
  grew to 466.

---

## [1.29.0] — **restart**

The disenchant rule. **Adds two `.lua` files, so this one needs a full client
restart, not `/reload`.**

Nothing is visible in the window yet — this release is the arithmetic that
later ones stand on, plus one slash command to look at it.

### What 1.28.1 got wrong
The previous entry said a disenchant breakdown was not buildable. Two of its
three reasons were mistaken, and this release exists because of what turned up
when they were checked properly:

- *"There is no item level and no way to get one."* True of the client, and
  still true. But a **shipped lookup** is an addon-visible source, and 1.28.1
  named exactly that as an unblocker before dismissing it.
- *"Learning it from play needs a bag walk on a spell event."* Simply wrong.
  The way the era's addons did it costs **one** call — remember the item the
  click landed on, gate it behind the Disenchant cast, read the loot. Every
  step is O(1). That is a later phase, but it is not the obstacle it was
  written up as.

What survives is the part that mattered least to the decision: item level is
missing from `GetItemInfo` and has to come from somewhere.

### The rule
There is no disenchant table. There is a **rule** — item level, quality and
weapon-or-armour fully determine what an item breaks into — and the whole
problem is knowing the item level.

The constants behind it are **generated**, not typed: `tools/gen_disenchant.py`
derives them from **8.8 million observed disenchants**, and the band boundaries
land exactly on vanilla's 5-wide ladder with no fuzz. The armour/weapon split
is read off the data too (~82/17), which is close to but not the same as the
75/20 the era's addons hand-typed.

### What it will not answer, and why that is the point
- **Item level above 65.** The observations thin to a few dozen there and stop
  being monotone, while Turtle's item levels run to 99.
- **Epics.** The source data holds nine epic items, with yields no real item
  produces (4.14 Large Brilliant Shards per disenchant). Dropped entirely.
- **Weapons in a few bands.** Where no usable weapon data survives, the band
  ships armour only rather than lending armour's numbers to weapons — armour
  is dust-led, weapons essence-led, so borrowing would be confidently wrong
  instead of roughly right.

Each of those returns "I do not know" rather than a plausible number.

### `core/itemlevel.lua` ships empty, on purpose
The obvious source of item levels is another addon's database that carries **no
licence at all**. That is a decision about someone else's work, so it is the
owner's to make rather than something to do quietly. The file is in the `.toc`
from today so data can be dropped in later **without a second restart release**,
and learning item levels from your own disenchants — a later phase — fills it
from the server you actually play on, which is better than any 2006 table.

### Also
- `/aex de <item link> [item level]` prints the breakdown for one item. A
  verification hook, not a feature.
- `tests/support/wow.lua` now reads `Aegis_Exchange.toc` and refuses to run if
  its own load order has drifted from it — two copies of one order is how a
  file gets added to the addon but never to the tests.
- New suite (441 checks) and six sabotages. One of those immediately caught a
  real fault: the new suite printed its failures but exited zero, so nothing
  downstream would ever have noticed a regression in it.

---

## [1.28.1]

A feasibility answer, and the small change that records it. `/reload`.

### Not building: the disenchant breakdown
Asked for as a tooltip line predicting what an item will disenchant into. The
answer is **no, and not for want of effort** — 1.12 exposes no disenchant API,
and the formula's key input is missing: vanilla's `GetItemInfo` returns **no
item level**, which this addon already knows because `util.ItemInfo` is built
around that gap. Required level is not a substitute; the disenchant buckets are
narrow enough that guessing wrong gives the wrong *material tier*, not a
slightly wrong answer.

Shipping a static table keyed by item id would sidestep that — it is what the
era's addons did — but it means shipping thousands of unverified entries onto
servers that add their own items and can change drop tables, where a wrong
entry is indistinguishable from a right one. Learning it from your own
disenchants fits this addon far better, but vanilla never says *which* item was
disenchanted, so it needs a bag diff hung off a spell event to find out.

Written up in full in `ROADMAP.md` (3k), including the three things that would
unblock it, so the question does not get re-asked from scratch.

### Changed
- **The greyed-out components in the Builder now say WHY.** "Not wired up yet"
  was true of both remaining ones and useful about neither: `item` is
  *unbuilt*, `disenchant-profit` is *unbuildable* with what the client
  provides. Each carries its own reason in its dropdown tooltip.

### Internal
- The engine's pending list and the UI's are **two tables in two files**, and
  nothing made them agree — a component implemented in one and still listed in
  the other either works while looking broken or looks fine while doing
  nothing. The suite now reads the UI's list out of the source and checks it
  against what the parser actually leaves inert, **in both directions**.
- Three sabotages for that pairing; **112 caught in all.**

## [1.28.0]

Three Sell-tab flow fixes. `/reload`.

### Fixed
- **An item you moved on from stayed stuck to the cursor.** Click a second bag
  item while the first is still in the sell slot and the first one never went
  back to your bag — you had to put it down by hand.

  `ClickAuctionSellItemButton` does not *put*, it **swaps**: it gives the slot
  what the cursor holds and hands back what was already there. So the second
  placement handed the first item straight onto the cursor, where it silently
  stayed. The `ClearCursor()` that was already there could not have helped —
  it ran *before* the pickup and was long finished by the time the swap
  happened. The slot is emptied first now, which turns the click back into the
  plain placement it was always assumed to be.

### Added
- **Leftovers stay ready to post.** Post two stacks of ten out of
  twenty-five and the remaining five are re-slotted **at the same price**, so
  the small stack goes straight out without finding it in the bags and pricing
  it again.

  Gated on the item matching — that gate is the whole safety of it, because
  carrying the price across a *different* item would post that one at a stale
  price. Off while walking a scanned bag list (the queue owns what comes next)
  and after a cancel. New **Keep leftovers ready to post** toggle on the Aegis
  tab, defaulting on.
- **A "Max" button** beside the stack count, filling in every stack of the
  chosen size that can actually be assembled. Not the total divided by the
  size: 1.12 cannot merge partial stacks, so thirty held as three tens gives
  three stacks of ten and none of thirty.

### Internal
- The cursor and the sell slot are **modelled** in the simulated client now,
  not stubbed. `ClickAuctionSellItemButton` swaps, `ClearCursor` returns a
  held item to where it came from, and bags are mutable — which is the only
  reason the bug above was reproducible instead of guessed at. It had been
  guessed at for a release.
- `ui.SetStackCount` is the single writer for the stack count. The count box
  and its slider are re-ranged against each other on every repaint, so writing
  the box directly left the two showing different numbers until something else
  repainted them.
- `W.SetBags` clears the cursor and slot as well: an item still held from a
  previous case got put *back* into the new bags, so five copper bars became
  ten and read as a duplication bug in the addon rather than one test world
  leaking into the next.
- New `sellslot` suite (26 checks). Three sabotages there plus a stale
  anchor-chain entry rewritten — inserting the new checkbox into the settings
  chain moved the anchor the lint watches, which is exactly the mistake that
  lint exists for. **109 sabotages caught in all.**

## [1.27.0]

The Sell tab's listings table, drawn the way the Buy table is. `/reload`.

### Changed
- **The listings table has a box.** One border around the column headings AND
  the rows, a rule under the headings, and separators between the header
  cells — exactly the Buy table's construction. It had no box at all before:
  headings and rows sat on the bare panel, so the tab read as a list of text
  rather than as a table.
- **The status line moved BELOW the box.** It used to float above the
  headings, competing with them for the same eye and leaving the table
  unanchored at its top.
- **26px rows**, the Buy table's height, instead of 19.
- **Numeric columns are right-aligned** — Unit price, Stack price and % mkt.
  Every column was left-aligned, so the money ran ragged down the page while
  the Buy table's lined up. The headings follow automatically: a right-aligned
  column's heading sits over the right edge of its cells, from the same flag.

### Internal
- The Sell tab's vertical bands join its horizontal ones in `SELLL`, and
  `LISTBOX.sellList` reads them rather than carrying its own copy — so the box,
  the scroll frame and the row count cannot disagree about where the table
  starts or stops.
- The geometry suite asserts the four numbers that have to stay in step: the
  box starts above the headings *by the same gap the Buy table uses*, the
  headings fit above the rule, the first row clears it, and there is room
  under the box for the status line — plus that the whole thing still holds
  rows at the smallest window.
- Its table-loader now runs a layout table's real literal instead of parsing
  fields one at a time, which is what lets `SELLL`'s bands be arithmetic on
  `SELL_TOP_H` and `LISTBOX` read `SELLL`.
- Five new sabotages; **106 caught in all.**

## [1.26.0]

The Sell tab's bag list: one row per item, and the Buy table's look.
`/reload`.

### Fixed
- **Your Bags drew one row per bag SLOT.** Thirty Lesser Magic Essence held as
  three stacks of ten showed as three identical lines — and it was not only
  cosmetic: the **Vendor list**, the **Scan-all batch** and the **post-scan
  sell queue** each processed the same item three times over. One row per item
  now, showing the total across every bag.

  Present since the feature was written.

- **The stack-size slider could ask for a stack that cannot exist.** It ranged
  up to your *total* holdings, and 1.12 has no way to merge two partial
  stacks — so with thirty held as three tens, asking for a stack of thirty
  gave zero postable stacks with no explanation. It ranges to the **largest
  single stack** now. The total is still shown; it is the ceiling that had to
  be honest.

### Changed
- **The bag list matches the Buy table.** 26px rows instead of 19, the same
  zebra banding and hairline separators every other table wears, 20px icons,
  and **quality-coloured item names**.
- **Category headers are banded**, so they read as the dividers they are
  rather than as text that happened to land there.
- **The bag column is wider** — 156px truncated most names to "Pattern: Fine
  Leather Bo…". The listings column moved right to match.

### Internal
- `sell.ScanBags` entries now carry three separate numbers, and keeping them
  separate is the whole design: `count` is the **holdings total**, `stackMax`
  the **largest single stack** — the only one that bounds what can be posted
  as one auction — and `slots` every physical stack behind the row. `bag` and
  `slot` point at the largest stack, so every caller that places or hovers an
  item keeps working and gets the most useful stack while doing it.
- **`sell.MarkedInBags` deliberately still emits one row per physical stack.**
  `SellMarkedToVendor` calls `UseContainerItem(bag, slot)` once per row and
  that sells exactly one stack — an aggregated row there would sell a third of
  what was marked and report success.
- `sell.LargestStack` is new and is not `sell.CountInBags`; the suite asserts
  the difference directly.
- The Sell tab's two column positions were four literals across five call
  sites (`168`, and `200` three times). One `SELLL` table now, read by every
  `SetPoint` and by the geometry suite, which requires the listings columns to
  fit beside the bag column **at the smallest window** and the gutter to clear
  the bag list's scrollbar.
- New `bags` suite (36 checks) with a bag model added to the simulated client.
  It covers the aggregate, the three counts, uneven stacks, vendor marks, and
  a **cold item cache** — which must still produce a row, must not claim a
  quality it does not know (quality 1 would paint an epic white), and still
  recovers the name from the item link.
- The geometry suite's table-field reader could not see a field on a table's
  **opening line**, so `SCX`/`ACX`-shaped tables reported their first field
  missing. Fixed; it read as "the table moved" rather than "the table is
  formatted differently".
- Eight new sabotages; **101 caught in all.**

## [1.25.1]

The window opened smaller than it was designed for on a fresh install.
`/reload`.

### Fixed
- **The window opened clipped until you touched the resize grip.** The frame
  was created at a literal **832 × 460** — the size it used back when `MIN_W`
  was 832 — and those literals were left behind when the minimum rose to
  **1000 × 492**. Anyone with a saved size was clamped up on login and never
  saw it; anyone **without** one got a window 168px narrower than its own
  declared minimum, with the Buy table's right-hand columns running off the
  panel. `ui.ColumnsFitAt` puts the true column floor at ~970.

  It hid behind the grip: `SetMinResize` snaps the frame to the minimum the
  instant sizing starts, and releasing saves that size — so **one drag fixed
  it permanently**, and nobody who had ever resized the window could reproduce
  it.

  Reported by two people on different setups. **Neither screen resolution nor
  pfUI had anything to do with it** — the common factor was simply never
  having dragged the window, which a clean settings reset guarantees.

  The window is created at the minimum now, and the size is clamped into range
  on every restore rather than only when there is a saved size to restore —
  so the next drift in a default cannot ship as a clipped window again.

### Internal
- `ui.ClampWindowSize` is split out as pure arithmetic so "the window is never
  below the minimum" is an assertion rather than a comment. The geometry suite
  now also reads the frame's **creation** size out of the source and requires
  it to sit inside the range, and requires the result columns to fit at it —
  paired with a check that the old 832 genuinely fails, so the pair cannot
  pass for the wrong reason.
- Four sabotages: the old default restored whole, the height alone put back
  (half the bug, and far more innocent in a diff), the unsaved-size case
  skipped, and the lower clamp dropped. **93 caught in all.**

## [1.25.0]

The two filter components that need the price database. `/reload`.

### Added
- **`percent`** — at most this percentage of market value.
  `linen/percent/70` is "a third under the going rate or better", measured
  against what Aegis has actually seen the item sell for.

  A ceiling rather than a band, for the same reason `left` is a bound: it
  answers the question people actually have, and `not/percent/70` still gives
  the other side of it. A trailing `%` is taken and dropped, because that is
  what people type.
- **`vendor-profit`** — at least this much per item over what a merchant pays.
  `linen/vendor-profit/50s` finds what you can buy and sell straight to a
  vendor for 50s more each. Both figures are per unit, which is the only
  comparison that survives different stack sizes.

Both now appear in normal colour in the Builder's **Component** dropdown
rather than dimmed, and the Post Filter list draws each one in its own terms —
`70% of market, or less`, `50s per item, or more`.

### Changed
- **The status line now gives advice that works.** Rows a filter cannot judge
  were already counted and named; the note ended `— search again`, which is
  right for a seller name and **wrong for a vendor price**. There is no sell
  price in 1.12's `GetItemInfo`; the only source is standing at a merchant, so
  "search again" was sending people round a loop that cannot succeed.

  Each cause carries its own remedy now — *search again*, *scan to learn its
  price*, *vendor prices are learned at a merchant* — and when two causes want
  two different cures, **no advice is offered at all** rather than advice that
  is half wrong.

### Not counted, on purpose
- **A bid-only auction is not a row we failed to judge.** It has no unit price
  because the seller set no buyout — a fact about the auction, visible on the
  row, that no amount of scanning changes. Confessing those would put the note
  on nearly every search until it stopped meaning anything. The count is for
  data *we* are missing; this is the same treatment `max-unit-buy` has always
  given them.

### Still pending
`item` needs the client's item cache. `disenchant-profit` needs a data source
1.12 does not provide and remains unscheduled — deliberately alone.

### Internal
- Nine new sabotages, **89 caught in all**: `percent` as a floor, its ratio
  inverted, the ×100 dropped, `vendor-profit` subtracting the wrong way round
  and as a ceiling, unknown data hidden instead of confessed, the wrong remedy
  offered for a vendor price, advice given for mixed causes, and a bid-only
  row counted as ignorance.

## [1.24.0]

Every column on every table sorts now. `/reload`.

### Added
- **Auctions sorts.** Item, Qty, Unit, Buyout, Time and **vs market** are all
  clickable. They were bare grey text before — not pressable at all, and the
  grey read as a disabled band rather than as the table's headings.

  *vs market* sorts by how far above the cheapest known listing each auction
  sits, so descending puts the ones you have been undercut hardest on at the
  top — which is the question that column exists to answer.
- **History sorts.** When, Type, Item and Amount. It still opens most-recent
  first; that is the sort's default now rather than a fixed reversal, which is
  what makes it changeable at all.

  *Amount* sorts by **size**, not by sign: the sign is already carried by
  Sold/Bought in the Type column, and a 40g sale and a 40g purchase are the
  same size of transaction.

### Changed
- **The Sell tab's listings headers go through the shared builder**, so they
  are warm tan like every other table's instead of grey, and a numeric
  column's header sits over the right edge of its cells.

### Internal
- **One nil rule, five tables.** `ui.SortByKey` holds the rule this addon has
  already got wrong once: a row whose value is missing **always** sinks, in
  both directions. Fold the guards into the direction branch instead and a
  descending sort floats priceless rows to the top, where a bid-only auction
  presents as the dearest listing on the page. It was one table's private
  comparator; now every table borrows it, and it has its own assertions rather
  than only being tested through the Buy tab.
- **One direction rule.** `ui.NextSort` — same column flips, new column starts
  ascending. There were three hand-written copies before Auctions and History
  wanted a fourth and a fifth.
- **The Sell tab's column x and widths were two disagreeing sets of numbers**
  (panel-relative in the headers, row-relative in the rows, a few pixels apart
  on every numeric column). One pair now, read by both.
- **A sabotage found a hole it was not aiming at.** The entry meant to invert
  Auctions' *vs market* ratio matched an identical line in the Buy tab's
  *% Mkt* sort first — and the suite did not notice *that* either, because
  nothing checked pct **ordering**, only that bid-only rows sank. Both
  functions have their own sabotage now, and pct is asserted to be a ratio
  rather than unit price wearing a different name.
- One assertion was written against an **unstable sort's tie order** and
  replaced. `table.sort` is not stable in Lua, so naming which of two equal
  rows lands second pins an accident.
- Ten new sabotages; **80 caught in all.**

### Not changed, on purpose
- **History's item names stay uncoloured.** The ledger stores a name and an
  item id, never a quality, so colouring them would mean a `GetItemInfo` per
  row inside a repaint that can run while the client is storming
  `MAIL_INBOX_UPDATE` and resolving item data — exactly the shape HARD RULE 16
  forbids, and what froze Courier. Every other table's item column is
  quality-coloured already; the Type column carries the colour that matters
  here and costs nothing.

## [1.23.0]

Every table now looks like the Buy table, and six lists that stopped short of
their own boxes now fill them. `/reload`.

### Fixed
- **Six lists kept the row count they worked out when the window was
  created.** Crafting, its recipe tree, Auctions, History, and the Sell tab's
  bag and listings columns all counted their rows by measuring their scroll
  frame — and every one of those frames is anchored by two corners, so
  `GetHeight()` reports the height it was last *laid out* at. Drag the window
  taller and the box grew with its anchors while the list did not: a
  full-height box with a half-full list, and empty space below the last row.

  This is the same trap that took the Buy results table, the Advanced column
  widths and the Saved Searches lists. Those three were each fixed in place;
  this is the audit that finished the job. Row counts are arithmetic on the
  window's own height now — which is set explicitly, so it is true the moment
  it is read — and **the measuring version has been deleted rather than left
  available**. A trap four separate bugs walked into does not want a
  convenient spelling.

### Changed
- **The Sell, Auctions, Crafting and History tables wear the Buy table's
  chrome**: the faint zebra banding, the hairline rule between rows, and the
  selection tint where rows can be picked. Previously the Buy table had the
  only copy, which is exactly why every other tab read as a different addon.

  The banding is keyed to a row's **position**, never to the entry it is
  showing, so scrolling slides data past fixed stripes instead of making them
  crawl along with it.

  History gets no selection tint and no tick column: a ledger line is a
  record, and there is nothing to select one *for*.

### Internal
- **One function, five tables.** `ui.AddRowChrome` builds all three textures
  in the one order that works — stripe, then hairline, then tint. They share
  the BACKGROUND layer, where creation order *is* draw order, so any other
  order is a silent visual bug: nothing errors, every row still draws, and a
  selected row wears a hairline scar or reads as striped-and-selected. That
  order is now asserted directly, by running the real function against a row
  that records what it was asked to make.
- The suite also checks there is exactly **one** copy of each chrome colour in
  the file, because four tabs each growing their own is the shape that
  produced the Saved-vs-Builder drift in 1.19.3.
- **`tests/lint/definitions.py` had been inert for its whole life.** It asked
  whether a name appeared *anywhere in the file text*, so a rename passed as a
  substring (`ui.TableRowsAt` is inside `ui.TableRowsAtNew`) and a deletion
  passed whenever a comment happened to mention the name — which is precisely
  how it waved through the `ui.RowsFor` removal above.

  It compares definition *sets* now. It also **fails when it compared
  nothing**: without a git repo every file is skipped as "new" and the run
  exited 0 having checked nothing at all, which is indistinguishable from a
  clean pass. It has a `--selftest` mode pinning both misses, run before it
  every time — the same guard `lua50.py` has had all along.

  This repo has met this failure before, in `sharedlayout.py`: a checker
  fooled by its own documentation is worse than none.
- Deliberate removals are expressible: `REMOVED_ON_PURPOSE` names them and
  their reason, and an entry naming something still defined is reported as
  stale, so the list cannot quietly become a blanket exemption.
- Nine new sabotages across the row counts and the chrome; **73 caught in
  all.** Two written for this pass were deleted rather than papered over — a
  sabotage that cannot fail proves as little as a test that cannot.

## [1.22.0]

Five of the nine placeholder filter components are real filters now.
`/reload`.

### Added
- **`min-level` and `max-level`** — bound the listing's own required level.
  `sword/min-level/40/max-level/50` is a band, which is the thing the
  server-side `level/40-50` cannot be: a query filter is part of the query and
  cannot be OR'd or negated, so `min-level/40/or/rarity/epic` needs the
  post-filter version.
- **`rarity`** — **exactly** that quality, not "that or better".

  The server-side `quality/N` is already the minimum — it *is* the form's
  **Min Quality** dropdown — so a post-filter minimum would be a second way to
  spell something that already had one. Exact is what you could not otherwise
  say: `bracers/rarity/rare` is rares and none of the epics above them. Same
  vocabulary as `quality`, so `rarity/rare` and `rarity/3` are the same
  clause.
- **`seller`** — case-insensitive substring of the seller's name, so
  `linen/seller/Bob` finds Bobby and Bobson. Matched as plain text, never as a
  pattern: a seller called `Mr.X` is a name, not a wildcard.
- **`left`** — **at most** this much time remaining. `left/short` is what is
  about to expire; `left/long` is everything except the freshly posted. Takes
  a word or an index (`short`, `medium`, `long`, `very long`, or `1`–`4`), and
  your client's own wording is accepted too.

  A bound rather than an exact match because the question people actually have
  is "what is ending soon" — and because a bound still composes:
  `left/medium/not/left/short` is exactly medium.

- **A filter that cannot ANSWER now says so.** The seller's name arrives a
  moment after the page does, and some servers do not report time left at all.
  Rows those filters cannot judge are dropped — a positive filter cannot
  honestly keep what it cannot verify — but they are **counted and named** in
  the status line: `3 skipped (no seller data yet — search again)`.

  This is the same confession bare `stack` makes, for the same reason: an
  unexplained empty page is indistinguishable from a broken filter, and that
  is exactly how the `stack` fault got reported in the first place.

All five now appear in normal colour in the Builder's **Component** dropdown
rather than dimmed, and the Post Filter list draws each one's value in its own
terms — a quality by name, a time left as "or less", a price as "per item".

### Still pending
`item`, `percent`, `vendor-profit` and `disenchant-profit` remain placeholders
and stay dimmed. `percent` and `vendor-profit` need the price DB and are next;
`item` needs the client's item cache; `disenchant-profit` needs a data source
that does not exist on 1.12 and is not scheduled.

### Internal
- **One table decides what a component's value IS**, and four readers ask it:
  the parser, the query writer, the Builder's Enter key and the Post Filter
  list. Four hand-written copies of "min-level takes a number" is the shape
  that produced the Saved-vs-Builder drift in 1.19.3.

  It also fixed a latent fault: the Builder assumed every non-`tooltip`
  component took **money**, which was true only while the price bounds were
  the only ones wired up. A level typed into that box would have been read as
  a price.
- **A value that does not parse is not a clause.** `silk/min-level/soon`
  leaves the words as name text instead of building a clause that can never
  match — the rule `quality` and `level` already follow.
- New `post_filter` suite (76 checks) driving every predicate through the real
  `ParseTerm → CompileTerm → filter` path. Eleven sabotages, each confirmed to
  fail it: both bounds inverted, `rarity` turned back into a minimum, the
  seller needle treated as a pattern and as case-sensitive, unanswered rows
  dropped silently and kept wrongly, a bad value accepted as a clause, the
  emitter bypassing the value table, and a pending component that filters.
- The suite's own row helper caught a Lua trap worth naming: `Row({ owner =
  nil })` sets **no key at all**, so `pairs()` never sees it and the default
  survived. Four assertions about unresolved owners were passing against a row
  that had one. A sentinel is the only way to say "absent" through a table.

## [1.21.1]

The **Usable items** check box never actually filtered anything. `/reload`.

Reported and diagnosed by **[@MarkuruThunderhoof](https://github.com/MarkuruThunderhoof)**.

### Fixed
- **"Usable items" did nothing** — ticking it changed no results, in either
  the simple view or `usable` in a query. The box, the term and the query all
  carried the flag correctly; the last step handed `QueryAuctionItems` a Lua
  **boolean**, and that slot is not a boolean on 1.12. A CheckButton reports
  `1` or `nil` there and the stock browse UI passes `GetChecked()` straight
  through, so `true` is a shape the client is never given — the query still
  went out, and the filter simply never applied.

  **Present since v1.5.0**, the query language's first release.

  It sends `1` or `nil` now. Not `1` or `0`: **0 is truthy in Lua**, so a
  client reading that slot as a flag rather than a number would take "off" as
  "usable only" and silently narrow every search — plausible-looking results,
  which is worse than the bug being fixed. `nil` is correct under either
  reading, is what CLAUDE.md rule 9 requires of every index/flag arg, and is
  what both the stock UI and Auctionator send.

### Internal
- **The simulated client now asserts that slot.** It already checked that
  `name` / `minLevel` / `maxLevel` are strings and that `page` is 0-indexed —
  and said nothing at all about the flag args, which is why a boolean sat
  there through every release since 1.5.0 with a green suite. The index args
  must now be numbers or nil, and `isUsable` must be `1` or `nil`, with `0`
  refused explicitly.
- Three sabotages: the boolean that shipped, the `0` spelling that looks like
  the obvious fix, and the flag inverted. All confirmed to fail `buy.term`.

## [1.21.0]

Tab moves between input boxes, and `tooltip` no longer needs repeating.
`/reload`.

### Added
- **Tab moves to the next input box, Shift-Tab to the previous.** Wired down
  the Sell tab (stack size → count → bid → buyout, a coin at a time), through
  the Filter Builder's form, across the Buy tab's level pair and bid entry, and
  the Aegis tab's undercut fields.

  Boxes the current mode has **hidden are stepped over** — the money triplets
  and the flat-amount fields come and go with the mode they belong to, and
  tabbing into one that is not on screen puts the cursor somewhere you cannot
  see it. A dead end leaves focus where it is rather than clearing it: losing
  the cursor is a worse answer than not moving it.

  The order is written out per form rather than derived from where the boxes
  sit, so it matches what the eye expects and a layout change cannot silently
  re-order it.

- **THE ONE EXCEPTION, and it is deliberate: the two search boxes keep
  autocomplete.** Tab in the Buy tab's **Name** field and in the Advanced
  **query box** still completes item names and cycles the matches, as it always
  has. That binding is older, already in people's fingers, and worth more on a
  search box than stepping to the level fields — so it wins, and nothing else
  on either box changes. Saying so here rather than leaving it to be
  discovered.

### Changed
- **`tooltip` no longer needs repeating.** Keep listing what you are after and
  each one is another thing the tooltip must say:

  | Before | Now |
  |---|---|
  | `wristbands/tooltip/+3 stam/tooltip/+3 agi` | `wristbands/tooltip/+3 stam/+3 agi` |

  Both spellings parse to **exactly the same term**, so every saved search and
  every favourite written the long way keeps working untouched — stacked
  clauses were always ANDed, which is what the run-on means.

  The run ends at the first word the search claims for itself, so
  `cloak/tooltip/stamina/exact` still applies *exact* and
  `container/bag/tooltip/8` is unchanged.

  **The trade, plainly:** a needle that *is* one of those words can no longer
  be written bare. `tooltip/Stamina/Weapon` filters tooltips for Stamina and
  searches the **Weapon class**. Repeat the keyword to say otherwise —
  `tooltip/Stamina/tooltip/Weapon` — which stays supported permanently, and is
  the form the Builder emits on its own when a needle would be misread.

  Otherwise the Builder and the saved-search list hand back the **short**
  form, so what you typed is what you get back.

### Internal
- **One function answers "is this word spoken for?", and both sides ask it.**
  `buy.IsTermKeyword` is shared by the parser's run-on and by the query
  emitter. Written twice they would drift, and the drift would be silent: a
  query that round-trips into a *different* search. It takes the term as well
  as the token, because a subclass is a keyword only once its class is known.
- The term suite pins both spellings to the same parsed term, the long form on
  its own (that is the assertion that says an upgrade cannot break saved data),
  a run of three, and **every keyword ending the run** — each paired with a
  check that the token really is part of the parser's vocabulary, so a list
  that has drifted fails loudly instead of passing for the wrong reason.
- New `taborder` suite. `ui.NextInputIn` is extracted from `ui/frame.lua` and
  run against stub boxes rather than restated — the mistake that has already
  let two bugs through here. It covers the wrap in both directions (`math.mod`
  is `fmod` on Lua 5.0 and hands back a **negative** remainder, so Shift-Tab
  off the front of a form would otherwise index nothing), runs of hidden
  boxes, and the dead ends. It also reads the traversal chains out of the file
  and fails if a search box is ever added to one, because that would cost it
  autocomplete with nothing else noticing.
- Nine sabotages added, all confirmed to fail the suite they name.

## [1.20.2]

The Aegis tab's check boxes were losing their left edge to the scroll frame
that holds them. `/reload`.

### Fixed
- **Check boxes on the Aegis tab were clipped down their left side.** The
  settings block lives in a ScrollFrame — the only 1.12 widget that clips,
  which is why overflow stays inside the window instead of spilling past the
  bottom edge — and the clip line falls exactly on the block's left edge. The
  block started at x=0, and the top-level check box column is nudged 2px
  *further* left than the labels so the boxes line up under the text above
  them, which put their left edge outside the frame. The labels got away with
  it because a glyph carries its own side bearing; a solid 1px edge texture
  does not, which is why the check boxes were the only thing that showed it.
  The block is inset now, and the scroll frame moved the same distance the
  other way so nothing shifted on screen.

### Internal
- The geometry suite walks the settings panel's **real anchor chain** out of
  `ui/frame.lua` — every vertical link, with the offsets the file carries —
  and requires the leftmost widget to land strictly inside the frame. It also
  checks the chain genuinely steps left of its root, so the check cannot pass
  for the wrong reason, and that nothing has resolved to a widget the walk
  lost track of. Sabotage-tested from both directions: removing the inset, and
  leaving the inset alone but nudging a widget further left than it covers.

## [1.20.1]

Two fixes to what 1.20.0 shipped — a settings panel drawing on top of itself,
and pfUI button labels that the last attempt did not actually rescue.
`/reload`.

### Fixed
- **The Aegis tab drew on top of itself.** 1.20.0's new "Ask before posting an
  auction" checkbox went into the middle of the settings panel's anchor chain,
  and the Scan pacing row below it was left anchored to the checkbox *above*
  the new one. So the new checkbox, the pacing label, its two buttons, the
  price-data line and Clear price data all landed in the same place. Inserting
  a widget into a chain is two edits, and only one of them was made.
- **pfUI button labels, properly this time.** 1.20.0 pushed pfUI's backdrop one
  frame level behind its button, which was not enough: frame level orders
  *siblings*, while "a child frame draws over its parent's regions" is a
  separate rule. The scan strip's buttons — one frame under the window — came
  out fine, and the Aegis settings buttons, three frames deep inside a scroll
  child, stayed blank. The label is now rebuilt **on** the backdrop frame,
  where the draw layer is the whole ordering rule and no level can get in
  front of it.
- **The same fix, in the four places it was missing.** Our buttons on other
  addons' frames (the tradeskill and craft "Add to shopping list" buttons, the
  merchant sell button, and the "Aegis UI" button on the Blizzard auction
  house) were being handed to pfUI's generic button skinner rather than
  treated as Aegis buttons, which gave them a second border and the same
  buried label. They go through the same path as every other Aegis button now.

### Internal
- **New lint: `tests/lint/anchorchain.py`.** Two widgets anchored below the
  same one is a fork in a vertical chain, and it is invisible to everything
  else — the addon loads, every widget exists, nothing errors, the tab just
  overlaps. It reads the chain relation only (`TOPLEFT` to a `BOTTOMLEFT`),
  so sharing a container's corner — which is normal and everywhere — is not
  flagged, and it skips reassigned loop cursors. Run by `tests/run.sh`, and
  sabotage-tested against the exact bug above, through both the raw `SetPoint`
  and the settings panel's `label()` helper.
- `tests/sabotage.py` can now run a **lint** as a suite, not only a Lua unit
  file. A lint makes a claim about the source and can be wrong about it the
  same way an assertion can.

## [1.20.0]

Phase one of the feature batch: the window remembers where you put it, a post
confirmation you can switch off, and selected buttons that actually look
selected. `/reload`.

### Added
- **The window remembers its position.** It saved its size but not its point,
  so it returned to centre every session. A restored point is checked against
  the current screen first: the title bar is the only drag handle, so a window
  saved near the edge of a large monitor and restored on a smaller one would
  otherwise be stranded off-screen with no way back. If it would land
  unreachable it centres instead and forgets the bad point.
- **"Ask before posting an auction"** on the Aegis tab, alongside the existing
  cancel toggle. Off posts on the first click, which is what you want when
  relisting a stack at a time. The confirmation is all that is skipped — the
  price and stack checks still run.

### Fixed
- **Selected buttons showed no selected state, in six places.** The chosen post
  duration, sell mode, undercut mode, scan pacing, history period and Sell-tab
  duration were all marked with `LockHighlight()`, which drives a *template*
  highlight texture that `ui.MakeButton` does not have — so every one of those
  calls was silently doing nothing and the chosen button looked exactly like
  its neighbours. The selected one now takes the warm gold plate that Search
  and Full Scan wear.

  This is the same bug that was found and fixed for the Advanced view tabs in
  1.15.1. It was fixed in one place and left in six others, so it is a shared
  `ui.MarkChosen` now rather than a seventh copy of the loop.
- **pfUI's backdrop could cover a button's label.** `CreateBackdrop` builds a
  child frame, and a child draws above *all* of its parent's regions whatever
  layer they are on — the same rule that puts the Filter Builder's text on a
  child rather than on the well. The backdrop is pushed one frame level behind
  its button now, so the label is always on top.

## [1.19.4]

The Filter Builder's form fits its box, and the saved lists fill theirs and
scroll. `/reload`.

### Fixed
- **The Filter Builder's form overflowed its column at small window sizes.**
  "Stack Size" was cut off by the well's border and the status note escaped
  entirely, drawing across the money readout. The row offsets were ten
  hand-written numbers ending at 276 in a column that is 254px tall at the
  minimum window height — and nothing anywhere checked they fit. The three
  options added in 1.19.0 are what pushed it over. Rows now come from a pitch
  constant, and the suite asserts the last one fits.
- **The Builder's status line moved to the action bar.** "Copied to the search
  box." is a status message, not a form field; it never belonged inside the
  column, and at the minimum height it landed outside it.
- **Saved Searches and Recent stopped short of the bottom of their own well.**
  The visible row count came from measuring the column — `GetHeight()` on a
  frame anchored by two edges, which reports the size it was last laid out at,
  i.e. the window's creation size. The third time this trap has bitten;
  `ui.SavedRowsAt` derives from the window's height, like the results table.
- **Neither saved list could scroll.** Anything past the visible count was
  simply unreachable — with a dozen favourites and a short window the last few
  did not exist as far as the UI was concerned. Both columns take the mouse
  wheel now, independently, with the offset re-clamped on every repaint so
  deleting an entry while scrolled to the bottom pulls the view back instead of
  leaving an empty band.

### Changed
- `ui.RowsFor` carries a warning naming the trap and the three bugs it has
  caused. Its remaining callers — Crafting, Auctions, History, the bag and list
  pickers — have not been audited; if one of those lists is ever reported as
  not filling its box, that is the first thing to look at.

### Not changed, and why
- **The two Filter Builder wells already end on the same line.** The right
  column's clause box is inset from its own well on purpose — it is nested
  inside it — which reads as a mismatch in a screenshot but is correct.

## [1.19.3]

Alignment and spacing across the Advanced view. `/reload`.

### Fixed
- **The tab row did not line up with the content under it.** It was centred on
  the PANEL, but the content is not symmetric in the panel — it runs from 10 on
  the left to 12 on the right — so the row landed 1–2px off the wells below,
  and by a different amount at each window size because the rounding was thrown
  away. Two pixels in at the smallest size, one pixel past at the largest. It
  is centred on the CONTENT now.
- **All three Advanced views now start on the same line.** Saved Searches and
  the Filter Builder began at `ADVL.body_y`; the results table was still placed
  from `BUYL.well_top` — a Blizzlike number measured against the *control*
  strip, and 2px above where the tab strip ends. Search Results began ten
  pixels higher than the other two.
- **The footer rule was covered on Saved Searches and the Filter Builder.** The
  rule sits 38px up and those wells stopped at 36, so they drew over it. Only
  Search Results looked right, and by accident: its table stops at 82 to leave
  room for the count and pager.
- **Saved Searches and the Filter Builder were not the same size.** Each had
  its own copy of the two-column split and the copies disagreed — a 16px gutter
  measured off the frame against a 12px one measured off the window, so both
  columns differed by 2px. That is the shift when clicking between the two
  tabs. One `ui.SplitAdvColumns` places both now.

### Changed
- **The view tabs are sized to their labels and centred**, rather than
  stretched to a third of the panel each. Three equal thirds made a 442px pill
  for a 110px label on a wide window and was still 308px on the narrowest one;
  a tab is now the same size wherever the window is.
- **More air between the tab strip and the content below it** — 20px, up from
  8.

### Testing
- `tests/units/geometry_test.lua` now extracts and RUNS `ui.LayoutViewTabs`
  against stub buttons rather than restating its arithmetic, and reads every
  layout constant out of `ui/frame.lua` instead of carrying its own copy. Both
  changes exist because the first version of this suite would have passed a
  build with the bug still in it.
- `tests/lint/sharedlayout.py` is new: it checks that two views sharing a space
  are placed by ONE function. That property is structural, not arithmetic — a
  unit test on the numbers passes whether there is one copy of the split or
  two — so it is checked structurally.

## [1.19.2]

Clipping and proportion pass over the Advanced view. `/reload`.

### Fixed
- **The Search button and the query box drew on top of each other, on all three
  Advanced views.** Search hung off the *Advanced* button — a default-mode
  widget that Advanced hides but which still carries a position — so it
  inherited a slot 10px below the Advanced strip's own baseline and 102px in
  from the edge. The query box's right margin was a constant that had to agree
  with three numbers it could not see, and did not: 172 against a button whose
  left edge is at 196. Search is now placed per mode, and the box's right edge
  hangs off the button itself.
- **The tab strip and the Filter Builder's columns were sized from a stale
  width.** Both measured a frame anchored by two edges, which reports the width
  it was *last laid out at* — in practice the window's creation size. The tab
  strip filled 69% of a resized panel and the builder's left column came out at
  29% where 41% was asked for. Both now derive from the window's own width,
  which is set explicitly, through the new `ui.PanelWidthAt` — the horizontal
  twin of `ui.PanelHeightAt`, which exists for exactly this reason.
- **"Exact" and "Usable" drew on top of the POST FILTER panel.** Every control
  was stretched to fill the left column, leaving no room for the checkbox
  anchored to the Name box's right edge, so it landed in the gutter. The
  concept has two widths, not one: the Name box and the level pair stop short
  with their checkbox beside them, while the four dropdowns run the full width
  past where that checkbox sits. The reserve is measured from the label, not
  guessed.
- **Long post-filter clauses ran past the well's edge.** They are clipped now —
  but the value is clipped *before* the colour codes are spliced on, because
  cutting a `|cffRRGGBB` in half prints garbage and leaks the colour into every
  line after it.
- **The `↵` in "adds" was an invisible character.** U+21B5 is not in the 1.12
  font, so the hint read as a blank followed by "adds". It says "Enter adds".
- **The saved-search context menu straddled the well's border.** Inset by the
  well's own padding.

### Changed
- **The three view tabs are centred**, as well as filling the content width.
  Anchoring the row from the left meant every rounding shortfall pooled into
  one gap on the right; from the centre it splits evenly.
- **The Filter Builder's columns are 50/50**, up from 41/59. The form is the
  side with six labelled rows plus three options, and the clause lines clip
  rather than wrap.
- **The post-filter hint belongs to the empty state only.** It used to change
  with the clause count and stay on screen underneath them, so a populated list
  carried a long centred sentence competing with the clauses. The stacking rule
  moved to a tooltip on the clause well.

### Not changed, and why
- **The Results view keeps Bid / Buyout / Close and no action row.** The 1.19.0
  spec said it should also carry Search / Build / Import / Clear; having seen
  it, that is wrong — Search is redundant beside the strip's own Search button,
  and Import / Clear are Builder verbs. Recorded rather than left contradicting
  the spec.
- **The results table keeps its scrollbar.** Its arrow buttons sit outside the
  table's right edge, which is inherent to `FauxScrollFrameTemplate`. The
  BROWSE tree's bar was hidden in 1.17.0 because that list is short and the
  mockup has none; a fifty-row results page genuinely needs the affordance, and
  it is identical in the Blizzlike view.

## [1.19.1]

Hotfix: 1.19.0 would not open the auction house window at all. `/reload`.

### Fixed
- **`ui.LayoutBuyTable` read `BUYL` before it was declared.** Lua scopes a
  `local` from its declaration onward, so a function defined 500 lines above it
  does not close over it — the name resolves to a nil GLOBAL instead. That is
  legal Lua and compiles cleanly, so it surfaced only at runtime, as
  `attempt to index global 'BUYL' (a nil value)` on the first frame of
  `BuildBuyTab`, which took the whole window down with it.

  The function has moved below `BUYL`. **`tests/lint/scoping.py` is new and
  catches this class**: it disassembles each file with `luac -l` and reports any
  name that is both declared as a file-scope local and read via `GETGLOBAL`.
  Verified against the exact file that shipped as 1.19.0 — `luac5.1 -p` passes
  it and the lint names `BUYL`.

  This is the fourth time this trap has caught this file (`ColumnsFitAt`,
  `BUY_ROWS_MAX`, `SIDE_ROW_H`, now `BUYL`) and the first time anything but a
  person in-game has found it.

## [1.19.0]

The Advanced view, brought to the approved concept: it reclaims the width the
hidden category tree was still occupying, stops leaking the results table's
furniture onto the other views, and the Filter Builder gains three options the
query language always understood. `/reload`.

### Fixed
- **Advanced was drawing in the right-hand two-thirds of the window.** Its
  search strip, tab row, Saved lists and Builder all anchored to the *results
  column* origin — which sits right of the category tree, and exists only
  because the tree is to its left. Advanced hides the tree, so that left about
  300px of empty panel down the left of everything. All four now start at the
  panel margin.
- **The results table's column separators drew across the Saved and Builder
  views.** Six 1px textures that belonged to no show/hide list, so nothing
  ever put them down — the row of stray ticks above both panels. The "N
  selected" line and the rule under the Blizzlike control strip had the same
  problem.
- **Saved-search rows were plated under pfUI.** They are Buttons, because a
  row has to be clickable, and pfUI skins every Button — the same bug already
  fixed for the category tree. Unskinned they were always correct, which is
  why it took a skinned screenshot to see.
- **The Post Filter's value box rendered as a bare `( )`.** It was the only
  edit box in the window still using a raw `InputBoxTemplate`, whose rounded
  end-caps are all that draws when nothing fills the middle. This had
  previously been read as the box being clipped and "fixed" by anchoring both
  edges.
- **The Builder silently dropped `buyout` and `stack` flags.** `ui.BuilderTerm`
  never read them, so importing `linen/buyout/stack/20`, pressing Build, and
  searching ran a *wider* search than the one you loaded — with nothing to say
  a filter had gone.

### Added
- **Buyout only, Full stacks only, and Stack Size** in the Builder's
  auction-house form. The query language has always understood all three;
  until now the form was the only place you could not reach them. Full stacks
  and an explicit size are mutually exclusive — the term holds one or the
  other — so setting either clears the other rather than letting the form
  express something the query cannot spell.
- **The Advanced results table fills the width it gains** from the hidden
  tree, and the surplus goes to the Item column, which is the one that
  actually runs out of room.

### Changed
- **The three view tabs span the content width** and are named in full —
  Search Results, Saved Searches, Filter Builder. At 112px each they occupied
  under a quarter of a wide panel and read as three unrelated buttons rather
  than as the tab strip they are.
- **Back is purple**, matching the Advanced button it is the counterpart of,
  and **Build → is purple** rather than a plain `Build >`.
- **Search, Build, Import and Clear appear on Saved Searches too**, with Build
  greyed. That view previously showed nothing but Close.
- **Filter Builder labels are left-aligned on a shared margin** and named as
  the concept names them (Level Range, Item Class, Item Subclass, Item Slot,
  Min Quality). **Exact now sits on the Name row and Usable on the Level
  Range row**, which is two rows of height back.
- **Two wells instead of one**, so the auction-house filter and the post-filter
  builder read as the two different things they are, with the clause list in
  its own recessed box.
- **The component dropdown leads with `and` / `or` / `not`**, coloured red as
  combinators rather than filters. Components that are not wired up yet are
  greyed with a tooltip saying so, instead of carrying "(soon)" in the label.

  All nine pending ones stay greyed, which is a deliberate deviation from the
  concept: it shows the finished list, and a component that looks live but
  narrows nothing is worse than one that admits it.
- **Saved Searches matches the concept**: headings and their hints on one line
  inside the well, a gold ★ on favourites, separators under recent rows, a
  highlight band that stays lit while a row's context menu is open, and
  ▲ / ▼ / × glyphs on that menu.

### Not done yet
- **Query-string syntax highlighting.** A 1.12 `EditBox` does not render `|c`
  escapes — it prints them literally — so the coloured query in the concept
  needs an overlay FontString swapped out on focus. Deliberately deferred
  until the rest is confirmed on a real client, since a coloured string that
  can desync from the box is worse than a plain one that cannot.

## [1.18.0]

Buy tab: the category tree stops searching on its own, the results table and
the category list stop losing rows they had room for, and every check box in
the addon is drawn by one helper. `/reload`.

### Fixed
- **Clicking a category no longer fires a search.** Picking "Weapons" searched
  every weapon on the auction house; picking "Staves" underneath it
  immediately searched again. Selecting is now just selecting — the status
  line names what you picked and waits for Search. Results already on screen
  are deliberately LEFT there rather than cleared: a click that blanked a
  search you had just run would be worse than one that leaves it, and the
  status line names the pending selection so the rows cannot be mistaken for
  it.
- **The empty band under the results, and the categories cut off at the
  smallest window, were the same bug.** Both lists sized themselves from a
  frame height that was 86 pixels wrong, so the results table drew fewer rows
  than it had room for while the category list believed it had less room than
  it did. Both now derive their height from the one number that is explicitly
  set — the window's own — through `ui.PanelHeightAt`. At the minimum window
  size all eleven top-level categories fit, which they did not before.
- **Check boxes were not boxes.** A `SetBackdrop` whose `edgeSize` approaches
  the frame size cannot draw a border — the two corner pieces are each
  `edgeSize` square and physically will not fit across a 14px button — so the
  result rows' tick boxes rendered as a garbled cross. Under pfUI they became
  circles instead, because pfUI reskins anything reporting `CheckButton`.
  There is now one helper (`ui.MakeCheckBox`) behind every check box in the
  addon: result rows, "Usable items", the Filter Builder and the Settings tab.
  Its border is four 1px textures, which stay square at any size, and it opts
  out of the pfUI pass the same way the sort headers already do.
- **A row you own now shows a dimmed tick box rather than no tick box.**
  Hiding it punched a hole in the tick column, so an owned row read as a row
  missing a cell instead of a row you are not allowed to buy.

### Changed
- **The three control-strip labels are placed by one rule instead of two.**
  "Name" hung off the panel at a fixed y while "Level Range" and "Min Quality"
  hung off their own controls, so nothing held the three in line — there was no
  single number to adjust. Each label now sits on its own control's top edge,
  and `BUYL.strip_lbl_gap` is the only place that air is set. The gap is wider,
  which is what the labels sitting on top of the boxes needed.
- **The Min Quality dropdown shows each quality in that quality's colour**, from
  FrameXML's own `ITEM_QUALITY_COLORS` — the same table item links and the
  results' Item column use, so a Rare here is exactly the blue a Rare is
  everywhere else. The closed button shows the selection in its colour too.
  "All" stays neutral: no quality filter is not a quality and must not borrow
  one's colour.

### Verified, not assumed
- **Bid-only auctions sort last, in both directions.** A listing with no buyout
  has no unit price, and "last" for a priceless row has to mean last whichever
  way the arrow points — the alternative reads as "these are the most
  expensive". `tests/sort_results.lua` pins it, and pins that the Bid column
  does *not* sink them, since there they have a real value. The test extracts
  `ui.SortResults` from `ui/frame.lua` at run time rather than copying it, so
  it cannot pass against a stale duplicate. It is not in the `.toc` and the
  client never loads it; run it with `lua5.1 tests/sort_results.lua`.

## [1.17.0]

Buy tab polish: alignment, clipping and colour. `/reload`.

### Fixed
- **The BROWSE scrollbar was drawn across the results table's left border.**
  `FauxScrollFrameTemplate` hangs its scrollbar outward from the scroll
  frame's right edge, which sat in the same eight pixels the results box
  starts at. Its down-arrow also floated far below the category list, since
  that frame runs to the panel bottom while the categories usually end
  higher. The scrollbar is hidden — the mockup has none — and the mouse wheel
  still scrolls the tree. Hiding it once was not enough: `FauxScrollFrame_Update`
  re-shows the bar whenever content overflows.
- **"N selected — <price>" no longer crowds the action buttons.** It sat
  inside the band the Bid / Buyout / Close buttons occupy. It now shares the
  action bar's baseline, to the right of the gold.

### Changed
- **The results table fills the height available to it.** It previously
  stopped well short, leaving a dead band above the action bar — the mockup's
  table ends high, but the mockup is one screenshot with five results and a
  real page has fifty. Only whole rows are drawn: a row that would be clipped
  by the bottom edge is dropped rather than half-shown, since rows are not the
  scroll frame's scroll-child and nothing would clip it — it would simply draw
  over the count line.

  **This reverses the "table is the shorter column" decision** recorded in
  ROADMAP 2r. That entry has been updated rather than left contradicting the
  code.
- **Your gold is left-aligned on the panel margin**, sharing the edge the Name
  field, "BROWSE" and the category plates sit on. It used to be anchored by
  its copper coin and grow leftwards, so that a total gaining a digit could
  not shove the layout about; on the left margin there is nothing to its right
  until the Bid row, so alignment is worth more than that. Because Blizzard
  hides denominations above the value, the anchor moves to whichever
  denomination is currently leftmost — otherwise 43 copper would leave a hole
  where the gold and silver would have been.
- **Column headings are warm tan rather than disabled grey**, so the header
  band reads as headings instead of as something switched off.
- **The control strip is raised, and every control in it shares one height and
  one top edge.** The Min Quality dropdown was 20px against the others' 18 and
  hung below the line; the three labels now sit the same distance above their
  own controls.
- **A rule under the control strip**, matching the one above the action bar.
  The mockup has both; we had only the lower one, so the strip ran into the
  BROWSE heading and the table with nothing between them.
- The match count is plain grey rather than amber — it was one of the warmest
  things on the tab and is the least important line in the column.

### Not changed, and why
- **`% Mkt` showing 100% on every row is correct arithmetic, not a broken
  colour.** Market value is a weighted median of daily minimum unit prices, so
  an item first seen in the scan you are looking at has a market value equal to
  that page's own cheapest listing — the comparison is the number against
  itself. The colour helper was verified again: below market green, exactly
  market neutral, above market red. It will show the full range once the price
  DB has history older than the current page.
- **"Miscellaneous" listing first under Armor is the client's own order** —
  it is Armor's subclass 0, and the stock auction house lists it there too.
  Left alone deliberately, since this view is the Blizzlike one.

---

## [1.16.1]

**Hotfix — 1.16.0 would not load.** `/reload`.

### Fixed
- **`too many upvalues (limit=32)` — the addon did not load at all.** Lua 5.0
  allows a function to reference at most 32 file-scope locals, and each one it
  reads costs an "upvalue". 1.16.0 added thirteen layout constants beside a
  builder function that was already large, taking it to 36. The client refuses
  to load a file containing such a function, so nothing in the addon ran.

  The constants are now fields of one table, which costs a single upvalue
  however many fields it carries. The function sits at 24 with room to spare.

  **Why this was not caught before shipping.** Lua 5.1 — which both `luac5.1`
  and the test harness use — allows 60 upvalues. The file compiled cleanly and
  the whole suite passed against a file the 1.12 client would reject on sight.
  `luac -l` reports the count per function, so the suite now asks it for every
  file and fails if anything is above 32, with a second check at 30 so the
  ceiling is noticed while there is still room to react. Recorded in
  CLAUDE.md as a hard rule and added to the pre-commit checklist.

---

## [1.16.0]

Buy tab default view rebuilt to the mockup's structure. `/reload`.

### Changed
- **The control strip spans the full width, at the panel's left edge.** It
  used to begin to the *right* of the category sidebar, so the sidebar sat
  beside it rather than beneath it. In the mockup the Name field, the
  "BROWSE" heading and every category plate share one left edge, and both
  columns hang below the strip. This was the single biggest structural
  difference between what we shipped and the reference, and most of the
  "it doesn't look like the concept" feeling came from it.
- **The two columns are different lengths now, as the mockup has them.** The
  results table is the shorter one and stops well above the action bar, with
  the match count and pager directly beneath it; the category tree is the
  longer one and runs on down to the action bar. Previously the table ran
  almost to the bottom and the tree stopped halfway, leaving its lower half
  empty.
- **Alternating row shading in the results.** Keyed to a row's position in
  the list rather than to the auction, so scrolling slides the data past
  fixed banding instead of making the stripes crawl, and drawn beneath both
  the selection tint and the "(yours)" dimming.
- **The category tree has the mockup's rhythm.** Plated top-level rows are
  taller than bare subcategory rows — one height for both is what made the
  list look evenly spaced where the reference has structure. Three dimming
  steps instead of two, so a third-level entry reads as deeper than a
  subcategory. The browsed category is marked with a lighter plate and a gold
  edge rather than the blue-green highlight bar, which appears nowhere in the
  reference. "BROWSE" is letter-spaced caps.
- **Smaller things**: the Min Quality dropdown has a caret, so it reads as a
  dropdown; the pager uses triangle glyphs instead of `<` and `>`; Search and
  Advanced no longer touch; the gold readout is larger, gold-coloured and set
  tight against its coins; the match count is muted rather than gold, and is
  centred on the pager rather than merely sharing its offset.

### Fixed
- **`% Mkt` at exactly 100% is neutral, not yellow.** Yellow reads as a
  warning, and paying exactly market price is the unremarkable case — green
  and red mean something precisely because the middle does not. Below and
  above market were already correct.

### Internal
- `ui.ColumnsFitAt` and `ui.StripFitsAt` both re-derived. **The result
  columns, not the control strip, now set the minimum window width.** Moving
  the strip to the left edge handed it back ~190px and it fits the old 832
  comfortably; the columns' floor is ~970, so `MIN_W` stays at 1000. It could
  only go lower by narrowing the table, which would move away from the
  mockup.
- The category tree paints with variable row heights. `FauxScrollFrame`
  assumes uniform rows, but its offset is counted in ROWS rather than pixels,
  so a ragged list works as long as the visible count is derived by
  accumulating heights rather than by dividing.

---

## [1.15.1]

Buy tab default view, second pass against the mockup. `/reload`.

### Fixed
- **The results table no longer draws over the bottom of the window.** Rows
  were spilling past the table and covering the match count, the pager, the
  bid boxes and the Bid / Buyout / Close buttons.

  `ui.RowsFor` treated its `minRows` argument as a floor on a *measured* fit,
  so when rows grew from 20px to 26px in 1.15.0 it kept insisting on eleven
  rows in a space that now held eight. Rows anchor to each other and are not
  the scroll frame's scroll-child, so nothing clipped the surplus. `minRows`
  now means only "the answer when the frame has no measurable height yet";
  a real measurement always wins. **Every list in the addon shares that
  function, so every list is fixed.**
- **The scrollbar no longer sits on top of the last column.** The table's box
  now stops exactly where the scroll frame ends, and the scrollbar hangs
  outside it.

### Changed
- **The Seller column is gone**, deliberately and against the mockup.
  `owner` is nil until the client resolves the name, so the column was blank
  on nearly every row — worse than not having it. The field is still read: it
  is what marks your own auctions, dims them and blocks them from a buyout
  batch. The freed width went to the gap between Lvl and Time Left, which
  were close enough to run together.
- **One box around the table, headings included.** The box used to wrap only
  the rows, leaving the column headings floating above it and the rule that
  belongs under them stranded on the box's top edge. Rows have hairline
  separators, the header cells have dividers, and a rule separates the action
  bar from the table.
- **Text fields are flat dark rectangles.** vanilla's `InputBoxTemplate` draws
  a left cap, a right cap and a tiling middle, which reads as a rounded
  trough at text-field width and as two brackets with a gap at the width of a
  level box — the reported `( )` shapes. The template is kept for its cursor
  and selection behaviour; only what it draws is replaced.
- **No box around the category list.** The mockup boxes the results table and
  nothing else, and a trough here fought with the plated rows inside it. A
  selected subcategory is bright text rather than a highlight bar; the bar
  stays on top-level rows, where it marks the whole category.
- **Fold glyphs are back on expanded categories**, reversing ROADMAP 2l. That
  entry argued the stock 1.12 list shows expansion by highlighting the parent,
  which works for one level; this tree nests three (Armor > Leather > Chest)
  and highlighting alone cannot say which of two open levels you are in.
  Collapsed rows carry no glyph — a `+` on everything closed is noise.

---

## [1.15.0]

The Buy tab's default view rebuilt to the design mockup, plus multi-buyout.
`/reload`.

### Added
- **Tick several auctions and buy them all at once.** Each result row has a
  checkbox; Buyout then acts on everything ticked, after a single confirmation
  showing the count, the total, and what you will be left with. The total is
  checked against your gold before anything is bought, and again before each
  individual purchase — mail, repairs and vendors all move money while the
  auction house is open.

  **On buying the right auctions.** 1.12 has no bulk buy: each buyout is a
  separate call against an *index* into the page the client currently holds,
  and a purchase removes that auction and re-sends the page, shifting every
  index after it. Walking a list of captured indices therefore buys the wrong
  things from the second purchase onward. There is also no auction ID, so "the
  same auction" cannot be re-found — and eleven identical Linen Bandages at 8c
  are genuinely indistinguishable anyway.

  So the batch is a multiset of *fingerprints* — item, stack size, buyout
  price — with a remaining count each. Every step re-reads the live page,
  finds an index whose fingerprint is still owed, and buys that one. Nothing
  is ever bought against a remembered index. If something ticked is no longer
  there, the batch stops and reports what completed rather than substituting
  whatever slid into that slot.
- **Four columns the table was missing**: Lvl, Time Left, Seller and Current
  Bid. Time Left needs its own API call (it is not among the twelve values
  `GetAuctionItemInfo` returns) and renders through the client's own
  localized strings, so it reads correctly on a non-English client.

### Changed
- **The results table follows the mockup.** Eight columns in a bordered well
  with a rule under the headers, taller rows, numeric columns right-aligned
  under right-aligned headers, and money figures in gold with the unit letter
  dimmed. The stack count moved onto the item name (`Thick Leather Tunic x2`),
  which is what freed the width for the new columns. A row you own is dimmed
  whole and labelled `(yours)`; an auction with no buyout shows a dash there
  and `bid only` under Unit.
- **The control strip is a fixed-width cluster on the left with the buttons
  hard right** and the slack between them, rather than a Name box stretching
  to fill the width. `Usable` is `Usable items` again.
- **Advanced is purple again**, as its own button kind rather than the tint
  removed in 1.14.0 — that tint sat over another button's plate and read as a
  smudge. Search and Buyout are the mockup's warm brown-gold rather than the
  deep red taken from the older concept PNG; where the two references
  disagree, the newer mockup wins.
- **The minimum window width is 1000, up from 832.** Eight columns and a
  fixed-width strip do not fit in 832, and letting the window get that narrow
  reproduces the overlap fixed in 1.14.1. A saved width below the new minimum
  is raised to it, so an existing character gets a wider window rather than a
  broken one.

### Fixed
- **The category tree no longer renders as a stack of buttons under pfUI.**
  Its rows are Buttons because a row has to be clickable, so pfUI's button
  skinner gave every one an identical plate — erasing the distinction between
  plated top-level categories and bare indented subcategories. They opt out
  the same way the sort headers already did.

---

## [1.14.1]

Cleanup pass on 1.14.0, from screenshots. `/reload`.

### Fixed
- **The Search button no longer prints through the "Usable" checkbox.** The
  filter strip was built as a chain growing rightwards from the Name box,
  while Search and Advanced were pinned at a fixed distance from the right
  edge — with nothing joining the two halves. At any window width where the
  chain reached the buttons, they simply drew on top of each other. The strip
  is now built from both ends and the Name box takes up the slack, so they
  cannot meet.
- **Saved Searches and the Filter Builder no longer leave a tall empty gap.**
  Both stopped wherever their content ran out and left bare window below.
  Each content area sits in a bordered well running the full height of the
  view, so the empty space reads as an empty list rather than as a hole.
- **Saved Searches shows more rows on a taller window.** The count was a
  hardcoded 12 regardless of how much room there was; it is measured at paint
  time now, like every other list in the addon.
- **Results / Saved / Builder show which one you are in.** All three drew
  identically in every view, so they read as three unrelated actions rather
  than as a tab strip. The active one takes the primary plate.

### Changed
- **Button borders are dark rather than warm.** The concept edges both plates
  with near-black; 1.14.0 used a warm brown on the quiet plate and a bright
  red on the primary one, which is what made the unskinned buttons read as
  outlined-in-brown. They are not literally the concept's `#14120f`, because
  the concept's panel is *lighter* than its buttons and ours is darker — an
  exactly-black edge would disappear against our panel instead of defining
  the plate.

---

## [1.14.0]

Every button in the addon is now drawn by Aegis rather than inherited from
Blizzard's `UIPanelButtonTemplate`. `/reload`.

### Changed
- **New button art across all six tabs**, matching the design concept: flat
  dark plates with a thin border, in two weights. The deep red plate with the
  gold label marks the *one* action each area exists to perform — Search,
  Post, Full Scan, Buyout, Scan Selected, and Buy on a listing row. Everything
  beside it takes the quiet dark plate.

  This reverses the decision recorded in 1.12.0, which kept the stock art on
  the grounds that "the default view looks like the stock auction house" was
  the point. That held while only the Buy tab was in question; carrying it
  across the whole addon is what the concept always showed, and a half-
  converted window looks like a bug rather than a choice.
- **The purple tint is gone** from the Advanced and Build buttons. It existed
  to mark them as the one non-stock addition to an otherwise Blizzlike strip.
  With the strip no longer Blizzlike, a third colour on top of the new plates
  just read as a smudge over the button — which is how it was reported.

### Fixed
- **Buttons now have a disabled look.** `UIPanelButtonTemplate` supplied one
  for free and hand-drawn plates do not: without it a button that has been
  disabled still looks live, and silently ignores the click. Disabled plates
  and labels are dimmed, and they no longer light up on hover or press.
- **A press dragged off a button no longer sticks.** The button never receives
  the mouse-up in that case, so the pressed plate would stay dark until the
  next hover.

### Internal
- `ui.MakeButton(parent, kind, name)` replaces the template at 56 call sites
  and owns all four visual states. `ui.SetButtonKind` replaces `ui.TintButton`,
  which vertex-coloured template textures that no longer exist and has been
  removed.
- Under pfUI the plates ride on pfUI's own backdrop, resolved at paint time
  rather than at creation — pfUI's skin runs long after the window is built.
  The generic `SkinButton` pass skips these, since a button that already has
  a backdrop would come out double-bordered.

---

## [1.13.0]

Buy tab fixes and layout, following the 1.12.0 polish pass. `/reload`.

### Fixed
- **A finishing scan painted the results list over Saved Searches and the
  Filter Builder.** Switching away while a scan was in flight left the paint
  guarded at the *switch*, not at the paint — so the reply, arriving a
  moment later, drew rows straight through whichever overlay was open. Both
  the list repaint and the status line now refuse to draw unless Results is
  the visible view, which is the only place that cannot be wrong.
- **Running a search from Saved Searches now brings Results forward.** It
  only did so from the Builder, so a saved query appeared to do nothing.
- **The default view was clipped at the bottom and along the right edge.**
  The category well drew below its scroll frame and cut through the gold
  total; the results column started inside the well's border. Both have room
  now, and the Min Quality and Level Range labels no longer crowd their
  controls.

### Changed
- **Your gold is shown in coins**, not the letters `g` / `s` / `c`. The
  readout is anchored by its copper coin so the figure grows leftwards as it
  gets larger, and denominations above the value are hidden — 43 copper
  shows one coin, not three.
- **`+ OR` is gone from the action row.** It wrote a bare combinator into the
  clause list with nothing decided about what it joined; `and` / `or` /
  `not` are chosen in the Component dropdown, next to the clause they apply
  to. The row is now **Search / Build > / Import / Clear**.
- **Bid, Buyout and the bid entry are hidden outside Results.** They act on a
  selected auction, and there are no auctions on screen in Saved Searches or
  the Builder. Clear takes the freed space, so the Builder's own actions sit
  where the eye already is.
- **The favourite context menu opens below its row**, inside the favourites
  column — clear of both the row it acts on and the Recent list beside it.

## [1.12.0]

Concept-parity polish across the Buy tab. `/reload`.

### Changed
- **The Bid entry is the Sell tab's gold / silver / copper control**, coin
  art and all, instead of one plain box that rendered as two stray brackets.
  A price now reads the same everywhere in the window. The Sell widget is
  reused rather than reimplemented, and it emulates the plain box's
  interface, so every existing caller works against it untouched.
- **The Browse tree looks like Blizzard's filter list.** Top-level categories
  get a plate; subcategories are bare indented text beneath the expanded
  parent; the whole list sits in a bordered well; the category you are
  browsing carries the blue selection bar. **The `+` / `-` fold glyphs are
  gone** — the stock list shows expansion by highlighting the parent and
  showing its children, and so does this now.
- **The Component dropdown no longer offers "All".** There is no such thing
  as all components; the row only offered a way to pick nothing. Class,
  Subclass, Slot and Quality keep it, where "no filter" is a real choice.
- **The selected component's text takes that component's colour**, matching
  its line in the Post Filter list. Both read the colour from one function,
  so the dropdown and the list cannot disagree about what a tooltip clause
  looks like.
- **Clear empties the search bar too**, not just the form and the clause
  list. Leaving the query behind meant the next Search ran something the form
  in front of you no longer described.
- **Import is back**, and the action row is **Search / Build > / + OR /
  Import / Clear**, right-aligned on the window's action bar beside Bid /
  Buyout / Close. It was dropped when the Builder was somewhere you only ever
  left from; now that a shift-click in Saved Searches lands you in it, a
  hand-typed query had no route into the form. A multi-term query loads its
  first term and says so.

### Fixed
- **The component value box was clipped to a pair of brackets** at the right
  edge — it had a fixed width that ran off the frame. Both edges are anchored
  now, so it fills the space it is given at any window width.
- **Saved Searches columns are equal halves that stretch with the window.**
  They sat at fixed offsets, leaving a dead gap on a wide window. Rows fill
  their column.
- **The favourite context menu opened over the query it was acting on.** It
  opens to the row's left now.
- **Level Range boxes** in both the default strip and the Builder were tiny
  stubs sitting badly against their dash; both are sized to the concept.

### Note on button colour
The warm red-brown plates are vanilla's own `UIPanelButtonTemplate` art —
what every stock button looks like without a skin — not a bug or a stray
tint. The concept's flat dark plates were CSS in an HTML mockup and no
vanilla template produces them. Deliberate choice: **keep the stock art**,
since the default view's whole premise is looking like the stock auction
house, with a subtle accent only on **Advanced** and **Build >** so the two
non-stock actions read as different.

## [1.11.0]

Layout pass over the Buy tab, against the approved concept. `/reload`.

### Fixed
- **The Results / Saved / Builder tabs were off the window entirely.** They
  were anchored 232px right of the Search button — fine while Search sat on
  the left, and clean off the frame the moment v1.9.0 moved Search to the
  right edge. They hang off the panel now, under the search bar, so they
  cannot follow another widget off screen again.
- **The pager sat on top of the Advanced button**, which is where the stray
  `< >` over it came from. Both were anchored to the panel's top-right. The
  pager moved to the bottom of the results area, with the match count
  opposite it on the left — where the concept puts them.
- **"Usable items" crowded the Search button.** Shortened to "Usable", the
  Name box and Quality dropdown gave back some width, and Search/Advanced
  moved right.
- **The `< Back` button and the query box** now have real padding between
  them.

### Changed
- **Advanced has no left column at all.** The Builder and Saved views span
  the full content width, which is what the concept shows and what stops the
  form's headings being clipped by a column that had no business being there.
- **The Shopping Lists sidebar is gone**, along with `+ Add` / `Rename` /
  `Del` / `Search entire list` and the `Max` box and `Add to list` button
  that floated under the Advanced search bar. Recent searches live in
  **Saved**; `max-unit-buy` does the Max box's job inside a query, where it
  is visible and saveable.

  Your saved lists are **not deleted** — the storage and its API are
  untouched, so re-homing the feature later is a UI job, not a rewrite.
- **The Builder form lost its Query preview and its Buyout only / Full
  stacks / Stack size controls.** Those filters are still in the query
  language (`/buyout`, `/stack 20`); the built query is visible in the search
  bar after **Build**.
- **The Add button beside the component input is gone** — Enter appends, as
  the concept intends.
- **Bottom row is now Search / Build > / + OR / Clear**, on the window's
  action bar beside Bid / Buyout / Close rather than floating inside the
  builder frame. **Build >** is tinted to match Advanced.

### Added
- **The rest of the component list**: `item`, `min-level`, `max-level`,
  `rarity`, `seller`, `percent`, `vendor-profit`, `left` and
  `disenchant-profit`. These are **placeholders** — they parse, round-trip
  and save, but they do not filter yet, so every one is labelled `(soon)` in
  the dropdown and drawn dim with "not wired up yet — ignored" in the Post
  Filter. A component that silently did nothing would be indistinguishable
  from a broken filter, which is a mistake this addon has already made twice.

## [1.10.0]

Builds out the **Advanced** side: saved searches, and a post-filter system
that can hold more than one clause. `/reload`.

### Added
- **Saved Searches**, a third view beside Results and Builder. *Recent* and
  *Favorites*, side by side. **Right-click a recent** and it goes straight
  into Favorites — no dialog. **Right-click a favorite** for **Move Up /
  Move Down / Delete**. Left-click either to run it; **shift**-left-click
  loads it into the Builder instead so you can edit before searching.

  Favorites are yours to order, so nothing re-sorts them, promoting the same
  query twice is a no-op rather than a reshuffle, and the order persists.
- **A component / post-filter system in the Builder.** Pick a component, type
  a value, press Enter, and the clause joins a list:

  ```
  tooltip: +3 stamina
  tooltip: +3 agi
  max-unit-buy: 5g
  ```

  **Stacked clauses must all hold** — that is one item carrying both stats,
  under 5g, without typing a single operator. `or` between two clauses widens
  instead; `not` before one excludes it. Evaluation is strictly left to right
  with no precedence, so `A or B and C` is `(A or B) and C` and there is no
  table to memorise. Click any line to remove it.
- **`max-unit-buy` / `min-unit-buy`** as query components — a bound on the
  price **per item**, so a stack of 20 compares honestly against a stack of 1.
- **Stat abbreviations match either way round.** `agi` finds "Agility",
  `Stamina` finds "stam", and the same for `str`, `int`, `spi`. The Post
  Filter shows which other spelling it will look for, so you can see the
  expansion landed before spending a scan on it.

### Changed
- **`tooltip` now takes exactly one token**, like `quality` and `level`,
  instead of swallowing everything after it. That is what makes a second
  tooltip clause possible at all — `tooltip/+3 stam/tooltip/+3 agi` used to
  collapse into the single nonsense string `"+3 stam tooltip +3 agi"` and
  match nothing.

  Nothing else changes: tokens split on `/` only, so a multi-word value like
  `tooltip/+3 stamina` is still one token, and `container/bag/tooltip/8`
  behaves exactly as before. It also retires the old "tooltip must be emitted
  last" rule in the query generator, since nothing can be swallowed any more.

## [1.9.0]

Redesigns the Buy tab around a **Blizzlike default view**, with everything
that was there before moved behind one **Advanced** button. `/reload`.

### Added
- **The Buy tab now opens looking like the stock auction house.** Name, Level
  Range, Min Quality, Usable items, Search; the category list down the left;
  your gold and **Bid / Buyout / Close** along the bottom. Click a row to
  select it and act from the bottom bar, exactly as the stock window does.

  Two columns are kept from Aegis: **Unit** (price per item) and **% Mkt**
  (against market value, green under / red over).

  The Name field searches *within* the selected category, so the tree and the
  text box compose instead of fighting. So does everything else on the strip —
  clicking through categories keeps your name, level range, quality and usable
  settings applied rather than resetting them.
- **An "Advanced" button**, in the slot Blizzard used for "Display on
  Character". It swaps in the full query box, the shopping-list sidebar and
  the Filter Builder; **< Back** returns.

  The switch carries your search **both ways**: Advanced inherits whatever the
  simple view had, and Back rebuilds the controls from the query. Filters only
  Advanced can express (a tooltip clause, an exact-match, a stack size) are
  dropped on the way back **and the status line says so** — an invisible
  filter that keeps narrowing your results is the one outcome worth ruling out.
- **Bid and Buyout gate themselves visibly.** Your own auction greys both; an
  auction with no buyout greys Buyout only; nothing selected greys both. The
  bid box prefills with what the selected auction actually needs next.

### Changed
- **"To box" is now "Build"**, and **Import is gone** — the builder is for
  building a query, and reading one back was the least-used direction. Editing
  the query box directly still does it.
- **Per-row Buy/Bid buttons are gone from the Buy tab** in favour of the
  Blizzlike select-then-act model. The Crafting tab keeps its own row buttons
  and is unchanged.
- **The Max price box belongs to Advanced now.** It is no longer read while
  the default view is up, so a value left there cannot keep filtering results
  after its box is off screen. Advanced also has `max-unit-buy` for the same
  job inside a query.

## [1.8.0]

### Added
- **Category tree on the Buy tab** (ROADMAP 2e). The left column now opens as
  a Blizzard-style **category tree**: click **Weapons > Two-Handed Swords** or
  **Armor > Leather > Chest** and it searches — no typing, no syntax. Every
  list in it comes from the client's own localized category names, the same
  source the query language and the Builder's dropdowns read.

  A tree pick **composes** with whatever is already in the search box rather
  than replacing it: pick a category with `quality/rare/stack 20` typed and
  you get rare 20-stacks *of that category*. Extra `;` terms ride along
  untouched. That composition is the feature's contract and is tested.

  The **Advanced** button swaps the tree back to the shopping-list sidebar
  (lists + recent searches); **Categories** brings the tree back. The choice
  sticks per character.

### Fixed
- **Exact match with an empty Name matched nothing at all.** `""` is truthy
  in Lua, so a nameless term's exact filter compared every listing against an
  empty string and rejected the entire page — an Exact checkbox ticked
  without a name could never return a single result, whatever else was set.
  Exact now only engages when there is a name to be exact *about*. (This was
  the likely shape of the reported "Silk Cloth + stack 10 + Exact finds
  nothing": the named form of that search passes, and passes a test now.)
- **A page emptied by filters no longer reads as "No auctions found."** It
  now says `0 match(es) (of N) • filters removed this page's rows — try the
  next page`, because an unexplained empty page is indistinguishable from a
  broken filter — exactly how `/stack` got reported in 1.5.x, and how this
  one got reported too.
- **The dropdown menus in the Filter Builder were see-through.** Their
  texture paths were written with single backslashes, which Lua silently
  swallows (`"\T"` is not an escape), so the client was asked for
  `InterfaceTooltips...` — a texture that does not exist — and drew no
  background and no hover highlight at all. Paths doubled, popup made fully
  opaque, and lifted to its own strata so nothing in the window can paint
  over it. Three tests now pin those strings byte-for-byte.
- **Long recent searches wrecked the sidebar.** A long query wrapped onto a
  second line and painted across the row below it. Sidebar rows now clip
  with an ellipsis and show the **full query in a tooltip** on hover.
- **The Builder view no longer shows the results status line or pager.**
  "7 match(es) • unit low to high" used to print straight through the form's
  heading, and the `<` `>` buttons still paged (and queried the server) for
  a list you couldn't see.

## [1.7.0]

### Added
- **Filter Builder on the Buy tab** (ROADMAP 2b). A **Builder** view sitting
  beside **Results** in the same space: fill in a form — Name, Exact, Level
  range, Class, Subclass, Slot, Quality, Usable, plus Buyout only, Full stacks,
  Stack size and Tooltip contains — and it writes the query for you, shown live
  as you go.

  Class gates Subclass gates Slot, the way the auction house's own dropdowns
  do, and every list is populated from the game's **own localized category
  names** — the same source the typed query language reads, so there is no
  second copy to drift.

  **Search** runs it. **To box** copies the query into the search box, **+ OR**
  appends it as another `;` term, **From box** loads a typed query back into
  the form. Round-tripping is the feature's contract and is tested: whatever
  the form builds must parse back to the same search.

  The form edits **one** term. Loading a multi-term query fills in the first
  and says so explicitly rather than quietly dropping the rest.

### Changed
- `GetItemInfo` is now read through one shared normaliser (`util.ItemInfo`)
  that returns **named** fields. Its return list differs between clients —
  vanilla 1.12 has no `itemLevel`, so every field after the third sits one slot
  earlier than on later clients — and two separate positional reads had already
  shipped with bugs from it: the stack-size lookup that made `/stack` misbehave
  for several releases, and the Sell tab's bag-list headers, which grouped by
  item *type* on one client and *subtype* on the other. No caller indexes
  `GetItemInfo` by position any more.
- The Courier detection fallback no longer guesses at the companion addon's
  global. Confirmed against Aegis: Courier's own source, it is `AegisCourier`;
  `Aegis_Courier` is the folder and `.toc` name and is never a global, so it is
  no longer accepted. Only affects a Courier that loads without calling
  `ClaimMailScanning` — the explicit handshake was and remains the contract.

---

## [1.6.0]

### Added
- **`stack <n>` — search for an exact stack size.** `silk cloth/stack 20`,
  `silk cloth/stack 8`. It compares each listing's own count and needs no item
  data whatsoever, so it works on the first search, for any item, however cold
  the client's item cache is. Three spellings all work: `stack 20`,
  `stack/20`, `stack20` — the spaced one matters because search terms split on
  `/`, so `stack 20` arrives as a single token.

### Changed
- **Bare `stack` no longer dead-ends when an item's maximum can't be read.**
  It still means "full stacks" and still prefers the real maximum, but when
  the client can't supply one it now falls back to the largest stack of that
  item on the page — which needs no item data at all — and says
  `biggest on this page` in the status line so the weaker promise is never
  passed off as the stronger one.

  This is a pragmatic answer to `GetItemInfo` being unreliable here in ways
  three attempts haven't fully pinned down. `stack <n>` is the form to use
  when you want a guarantee.

---

## [1.5.3]

### Fixed
- **`stack` said "stack size unknown" even for items sitting in your own bags.**
  A stack of 20 Silk Cloth is definitely in the client's item cache, so the
  cache was never the problem — the code was reading the wrong value out of
  `GetItemInfo`.

  Its return list is not the same on every client: vanilla 1.12 returns nine
  values, while later clients insert `itemLevel` at position 4 and shift
  everything after it down a slot. Counting slots therefore reads the stack
  count on one client and the equip slot on the other — which is empty for a
  trade good (hence "unknown" for every cloth, ore and herb) and a string like
  `INVTYPE_CHEST` for gear, where it would have thrown outright.

  The stack count is the **last number** in that list under both layouts —
  everything after it is a string — so that is what Aegis looks for now,
  instead of counting positions. The test suite runs these checks under *both*
  return layouts, so a fix that only works on one can't pass.

---

## [1.5.2]

### Fixed
- **`stack` showed every stack size, not just full ones.** v1.5.1 made the
  filter fail *open* when an item's maximum stack size was unknown, which
  turned out to mean "always" for items your client hasn't cached — so it let
  everything through instead of everything being hidden. Both failure modes
  looked equally broken.

  Max stack size has exactly one source on 1.12 — `GetItemInfo`, which only
  answers for items already in the client's local cache, i.e. not the ones
  you're shopping for. **Aegis now remembers every stack size it learns**
  (account-wide, alongside vendor prices — it's a property of the item, not
  the realm), so the filter fills in as you browse and play. Anything still
  unknown is excluded *and counted*, with the status line saying so:
  `No full stacks • 12 skipped (stack size unknown — search again)`.

- **`weapon/dagger` returned thrown weapons with "Dagger" in the name.** The
  game's category names are plural and often qualified — "Daggers",
  "One-Handed Swords" — so the singular never matched, fell through to a name
  search, and dragged in anything called "…Dagger". Categories now match on an
  exact name, then a unique prefix, then a unique substring.

  Deliberately *unique*: `weapon/sword` matches both One-Handed and Two-Handed
  Swords, so it stays a name search rather than silently picking one half and
  returning a confidently wrong page. Naming one exactly still works.

---

## [1.5.1]

### Added
- **Search results are coloured by item quality**, matching each item's
  tooltip — a rare reads blue, an epic purple. Colours come from FrameXML's own
  `ITEM_QUALITY_COLORS`, so they match the rest of the game exactly rather than
  being re-guessed. Applies to the Buy tab and the Crafting tab's reagent
  results, which share a row painter.

### Fixed
- **`armor/leather` and other category searches returned nothing.** Class,
  subclass and slot keywords were never implemented — they fell through to
  being name text, so `armor/leather` searched for an item literally *called*
  "armor leather". They now resolve against the auction house's **own
  localized category names** (`GetAuctionItemClasses` /
  `GetAuctionItemSubClasses` / `GetAuctionInvTypes`), so `armor/leather`,
  `container/bag` and `armor/plate/chest` all work — in any client language.

  Subclasses resolve *within* their class, because names repeat: "Leather"
  exists under both Armor and Trade Goods, and "Mail" exists only under Armor.
  `trade goods/mail` correctly leaves "mail" as name text instead of silently
  searching a category you never asked for.

- **`container/bag/tooltip/8` returned nothing** — same root cause. Now that
  the categories resolve, both halves of that pair work as documented:
  `container/bag/tooltip/8` filters tooltips for "8", `container/bag/8`
  searches names for "8".

- **`mageweave/stack` returned an empty page.** The fully-stacked filter needs
  each item's max stack size from `GetItemInfo`, which only answers for items
  already in the client's cache — and it was failing *closed*, so on a cold
  cache every row was hidden, indistinguishable from "no full stacks exist".
  It now fails open: a few partial stacks may show until the cache warms.

- **Tooltip searches matched the wrong listings, or nothing at all.**
  `GameTooltipTemplate` reuses its text lines, so text from a previous, longer
  tooltip is still sitting in the higher-numbered ones. Reading "until a line
  comes back empty" walked off the end of the current tooltip into that stale
  text. Now bounded by `NumLines()`, and built lazily with the same
  owner-then-clear-then-set sequence the Sell tab's bind-status scanner has
  always used.

- **The "you can't use this" warning never appeared.** `GetAuctionItemInfo`
  returns `canUse` as `1`-or-`nil`, so `nil` *is* the cannot-use answer — but
  the check treated it as "unknown, assume fine", making the warning
  unreachable. It now fires correctly, and shows as a red icon tint (the name
  colour having been taken over by item quality).

- Quality keywords now also accept the client's own localized names via
  `ITEM_QUALITY<n>_DESC`, with the English words kept as a fallback.

---

## [1.5.0]

### Added
- **A search query language on the Buy tab** (ROADMAP 2a). Typing a plain item
  name still does exactly what it always did — a bare word with no keyword is
  just name text, same as ever. The same box now also understands:

  | Query | Effect |
  |---|---|
  | `linen cloth/exact` | only *Linen Cloth*, not *Bolt of Linen Cloth* |
  | `belt/quality3`, `belt/quality/rare` | server-side quality filter |
  | `sword/level20-30`, `sword/level/25` | server-side level range |
  | `belt/usable` | server-side "usable by me" flag |
  | `runecloth/buyout` | exclude bid-only auctions |
  | `mageweave/stack` | fully-stacked listings only |
  | `container/bag/tooltip/8` | name *container bag*, tooltip contains *8* |
  | `linen;wool;silk` | three searches browsed as one list |

  The grammar is aux's (settled in ROADMAP.md) — this is an original
  implementation of that shape, not ported code. Filters split into the parts
  the 1.12 server can do (one `QueryAuctionItems` per term) and the parts it
  can't (applied client-side as each page loads). An unrecognised token can
  never break a query: it falls back to being literal name text.

  Semicolon terms browse as **one** list — page past the end of one and it
  rolls into the next, rather than leaving you to notice and re-run.

- **Right-click a bag item on the Buy tab to search for it.** The Sell tab's
  existing right-click-to-slot is untouched; each only fires on its own tab.
- **Shift-click any item to search for it** — a bag slot, a chat link, a
  tooltip. Works through `HandleModifiedItemClick`, the single 1.12 global
  every shift-click funnels through.
- **Tab-completion in the search box**, from every item name Aegis has learned
  (scans, searches, browsing) plus your recent searches. Press Tab again to
  cycle through the matches.

### Changed
- The Buy tab's result count now reads `N match(es) (of M)` when a query filter
  is narrowing the page, so the bigger Blizzard-side number can't be mistaken
  for "how many I can buy". The pager names the current term (`Term 1/3`) only
  when a query actually has more than one — a single-term search looks exactly
  as it always has.

### Fixed
- Removed a duplicate price-database write on the browse path. `core/buy.lua`
  folded every browsed listing into the price DB, but `core/scan.lua`'s
  `RecordVisiblePage` already does that for *every* result page anyone looks
  at — from the same event, with identical values. Surfaced by a sabotage test
  that fed the DB from filtered rows instead of raw ones and changed nothing
  observable. Behaviour is unchanged (and still verified): a filtered search
  narrows what is **displayed**, never what is **learned**.

---

## [1.4.0]

### Changed
- **Market value now looks back 30 days instead of 11, and actually weights
  those days** (ROADMAP 0.3). The old setting was described as "recent days
  weighted more, decreasing effect past roughly a month" and did neither: the
  window was 11 days, so nothing survived to a month, and at 0.95 decay per day
  the oldest retained value still carried 57% of today's weight — which made
  the "time-weighted" median return the same answer as an unweighted one in
  **93% of cases**. It was a flat 11-day median wearing a decay curve's name.

  The new curve is 30 days at 0.85 per day:

  | age | today | 3d | 7d | 14d | 21d | 30d |
  |---|---|---|---|---|---|---|
  | weight | 100% | 61% | 32% | 10% | 3% | 1% |

  Nothing was traded away to get it. A real price shift (100 → 200 and it
  stays) is tracked in **5 days — exactly as fast as before**. One absurd
  listing still moves a steady series by nothing, because it is still a median.
  And it fixes casual scanning: in an 11-day window someone scanning weekly had
  **one** sample, and a weighted median of one sample is just that sample.
  Thirty days gives them four.

  **Nothing to do on your end.** No migration, no reset. Existing databases hold
  at most 11 days, so they ramp up to the full window over the next three weeks
  rather than changing under you at once. Price history keeps roughly 3 MB of
  SavedVariables at 6000 tracked items, up from about 1 MB.

---

## [1.3.0]

### Added
- **The Sell tab has a header band.** The item sits on the left; on the right,
  four figures as labelled columns — **Total**, **Deposit**, **After cut** and
  **Listings**. They used to be four loose right-aligned sentences
  (`1 x 11c = 11c`, `Deposit ~1c (approx)`, `Listings: 1 / 120`) each carrying
  its own label and competing with the item name for the same eye.
- **After cut** is new: what actually reaches your mailbox once the 5%
  consignment cut is taken. The cut has always been documented and never
  shown, so the headline total was a number you would not receive.

### Changed
- **The Sell tab's controls sit on one shared grid.** Left column and right
  column now line up row for row — stack size, stacks and duration on the left;
  the pricing buttons, bid and buyout on the right, every one of them pinned
  flush to the panel's right edge. Before, the two halves ran on independent
  baselines and nothing aligned across the middle.
- **Post and Skip have their own action bar** across the bottom of the block,
  with the posting status beside them. Post used to float mid-panel after the
  duration pills, reading like part of the duration setting.
- The context line under the item name reads `market 18c · lowest 12c ·
  vendor 2c` — separators instead of runs of spaces.
- **The vendor comparison is a warning now, not a status line.** It appears
  only when your price is *below* what a merchant would pay. "1371% of vendor
  · above vendor" was reassurance holding a permanent line, and the vendor
  figure is on the context line either way.
- Minimum window height is 492 (was 472), so the taller control block does not
  cost the smallest window a row in its lists.

### Fixed
- **A price of `11c` drew as `[ ][0][11]`** in the coin boxes — an empty gold
  box beside a zero silver, which reads as a missing value rather than "no
  silver". Gold blanked its leading zero and silver did not; now every leading
  zero blanks and interior zeros (`2g 0s 5c`) are kept.

---

## [1.2.0]

### Added
- **Window scale** (Aegis tab). Resizing and scaling answer different questions:
  a taller window shows *more rows* — vanilla frames never reflow, so that is
  all it can do — while scale makes the same window physically bigger or
  smaller. On a large monitor you want both. Steps of 5% between 70% and 150%,
  with a Reset, remembered per character.
- **Price match** alongside **Undercut** on the Sell tab. Undercut works from
  the competition's price with your undercut rule applied; Price match uses
  that same reference price untouched, for when you would rather sit level with
  the cheapest seller than start a race to the bottom.

### Changed
- **The Sell tab is two columns.** The left half is *what am I posting* — both
  sliders stacked, duration under them; the right half is *for how much* — the
  two pricing buttons above the bid and buyout rows they write into. They used
  to interleave on shared rows, which meant reading a price and reading a stack
  size were the same eye movement.
- **The flat undercut is entered in gold / silver / copper**, the same widget
  the Sell tab's bid and buyout use, instead of typing `1s 50c` into a text
  box. One way to type a price everywhere in the addon.
- The Sell tab's **History block is gone**. The scan median, minimum buyout and
  vendor price still sit on the line under the item name, and what things have
  actually sold for lives on the History tab.
- The posting status line moved to its own row under the buttons — squeezed
  onto the duration row it had about 160px before it ran into the price column,
  which is not enough for `Item 7 of 23 — Elemental Earth`.
- Minimum window height is 472 (was 460), so the roomier Sell controls do not
  cost the smallest window a row in its lists.

### Fixed
- **A taller window now fills with rows instead of growing around them.**
  Releasing the resize grip refreshed the scan strip but never repainted the
  open tab, so every list kept the row count it was last drawn with and the
  extra height went to empty space (or, in the bag list, to more scrolling).
- A saved window scale is re-applied on login even when the window was never
  resized — the two are stored independently, and restoring bailed out early
  when there was no saved size.

---

## [1.1.9]

### Added
- **Tooltips now price more surfaces** — loot windows, quest rewards, the quest
  log, and profession reagents, on top of bags, inventory, the AH, merchants and
  the mailbox. Hover a reagent in a profession window and see what it's worth
  without leaving it.
- **Aegis tab controls which lines appear**: Market value, Minimum buyout and
  Vendor price each toggle independently under the master tooltip switch, which
  greys them when it's off.
- **"Stack totals only while Shift is held"** — off by default, so nothing
  changes unless you want it. On, a tooltip shows the unit price and only adds
  `(x20 = 24g)` while Shift is down, which keeps things short in a bank full of
  stacks.
- **Stack size and stack count are sliders now**, and they interlock — drag the
  size and the count's ceiling follows, because bigger stacks means fewer of
  them. The size slider stops at the item's own max stack (or what you're
  actually carrying, whichever is smaller), so you can't ask for a stack the
  game won't allow. The line beside them reads `= 27 of 28`, so you can see
  what you're about to list against what you hold.
- **Prices are entered in gold / silver / copper**, one box each with the
  game's own coin icons, like the stock auction house — instead of typing
  `1g 88s`.
- **The window resizes.** Grab the grip on the frame's bottom-right corner and
  drag.
  Every list re-fits itself to the new height as you go, so a taller window
  shows **more rows**, not more empty space — up to ~3x the listings on the
  Sell and Buy tabs. Bounded to sensible limits (the old fixed size is the
  minimum), and the size is remembered per character.
- **Bid per item** is now its own field, separate from **Buy per item**. Leave
  it blank and the start bid follows the buyout, exactly as before.

### Changed
- The editable **stack price** box is gone. With a stack-size slider it was a
  second way to say the same thing, and the two boxes rounding into each other
  made your price drift as you dragged. The stack total is shown on the right
  instead (`3 x 16s 92c = 50s 76c`).

### Fixed
- The stack assembler now waits when a bag slot is **locked** (mid-move on the
  server) instead of splitting into it and burning a retry on a cursor that was
  never going to fill.

## [1.1.8]

### Fixed
- **"couldn't assemble a stack" — actually fixed this time.** Posting anything
  that needed a genuine split still failed after 1.1.5. The auction slot
  reliably takes a *whole bag stack*, which is exactly why posting always
  worked when your bags already held the right sizes and never worked when
  Aegis had to do the splitting. Waiting for the split to reach the cursor
  (1.1.5) was necessary but not enough.
  Aegis now **carves**: it splits the amount off into a spare bag slot, waits
  for the bags to settle, then posts that new stack down the whole-stack path
  that always worked. Posting 19 as 2×9, or 9+19 as 3×9, both work now.
- With **no free bag slot** there's nowhere to carve into, so it says
  *"no free bag slot to split into"* instead of grinding through retries and
  blaming the stack assembler.
- `/aex debug` now traces the posting state machine — which phase gave up, and
  what the sell slot actually held when it did. "Couldn't assemble a stack"
  never told anyone anything; if it happens again, that trace will.

### Changed
- **No more tooltips on the Sell tab's listings rows.** Every row there is the
  same item that's already in the sell slot, so the tooltip just repeated the
  header — and anchored that far right it hung off the side of the window.
  Tooltips stay where they tell you something you can't already see: the
  **Your Bags** list and the sell slot itself.
- The listings table's **Unit price** column is inset 4px instead of sitting
  flush against the row border, where it read as clipped.

## [1.1.7]

### Added
- **Integration surface for the companion addon, [Aegis: Courier](https://github.com/Torchlite-bit).**
  Courier owns the mailbox; this is the seam it pushes through, so it never
  touches Aegis's saved tables directly and our internals stay free to change:
  - `AegisExchange.RecordExternalTxn(txn)` — log a sale/purchase Courier
    matched. Validates the payload and refuses bad ones with a reason rather
    than corrupting the ledger.
  - `AegisExchange.MailTxnKey(subject, money, daysLeft)` — the dedup key Aegis
    has always used for auction mail. Shared deliberately: if you ran Aegis
    alone for a while, those mails are already in your ledger under these keys,
    so Courier generating keys through it means installing Courier **doesn't
    re-count everything you'd already banked**.
  - `AegisExchange.ClaimMailScanning(name)` / `ReleaseMailScanning()` —
    Aegis's own mail scanner stands down while Courier owns the inbox. Two
    scanners on one mailbox means every sale counted twice.
  - `AegisExchange.INTEGRATION_VERSION` — so a future signature change is a
    detectable mismatch instead of a silent miscount.

  No effect at all unless a companion addon is installed.

## [1.1.6]

### Changed
- **Price data is now kept per realm.** `## SavedVariables` is account-wide
  across *every* server, so a character on Octo WoW and one on Capy WoW were
  folding their buyouts into the same daily minimum — two unrelated economies
  blended into one median. Market data now hangs off the realm you're on.
  Everything that's a game constant rather than an economy fact stays shared:
  **vendor prices** (an NPC charges the same everywhere — no re-learning them
  server by server), the item name→ID map, and your shopping lists, crafting
  projects, settings and history.
  - Scans are still pooled across **all your characters on that realm**, which
    was always the intent.
  - The Aegis tab now names the realm next to the item count, and **Clear price
    data** wipes that realm only — never one you can't see from there.
  - **Your existing prices are kept, not wiped.** They carry no realm tag, so
    they're attributed to whichever realm you first log in on after updating.
    Single-realm players lose nothing. If you play several, one realm inherits
    some foreign dailies and that ages itself out within ~11 days as fresh
    scans replace them.

## [1.1.5]

### Fixed
- **"Posted 0 of N. (couldn't assemble a stack)" whenever a stack had to be
  split.** `SplitContainerItem` is a *server round-trip* on 1.12, but the
  assembler called `ClickAuctionSellItemButton` in the same frame — firing
  against a still-empty cursor, so the sell slot never filled, verify failed,
  and the job burned its retries. This is why posting worked if you manually
  split the stacks yourself first (that path uses the instant
  `PickupContainerItem`) and failed every time Aegis had to do the splitting.
  The assembler now waits for the item to actually reach the cursor before
  handing it to the sell slot, exiting the moment it lands.
- **Right-click a bag item to load it into the Sell tab.** It played the default
  click sound and did nothing. Both right-click paths are now hooked — the stock
  bag buttons *and* `UseContainerItem`, which is where replacement bag addons
  (pfUI and friends) land — so the item goes into the sell slot with pricing
  filled in. Only active while the Aegis window is open on the Sell tab, and
  only for postable items, so right-click keeps its normal meaning everywhere
  else.
- **Hover tooltips on search results.** The Buy, Crafting, Auctions and Sell
  listing rows had no tooltip. They do now; the browse rows re-verify the
  auction index first, so a row can never describe someone else's listing after
  the page shifts.
- **Long item names no longer overflow the "Your Bags" list.** Names like
  *Formula: Enchant Shield - Lesser Protection* ran straight out of the list and
  into the listings table. They're now clipped with an ellipsis. (1.12 has no
  truncation mode for text — giving a FontString a width makes it *wrap* — so
  the name is measured and cut instead.)
- A job whose item was already sitting in the sell slot moved to a phase name
  nothing handled, and would have hung there instead of posting.

## [1.1.4]

### Fixed
- Dead placeholder code in the sub-tab loop. It built a centered "coming soon"
  label for any tab not in a hardcoded exclusion list — but that list had grown
  to contain every entry in `SUBTABS`, so the branch had been unreachable since
  the last placeholder tab was filled in 0.15.0.

### Changed
- `ui/frame.lua`'s header still described the file as "Stage A: shell only"
  with "empty labels" for panels and scanning "in later stages". All six tabs
  have been real since 0.15.0; the header now describes the actual layout.
- `AegisExchangeSwapButton` — the "Aegis UI" button on the stock auction house
  — is now commented as the deliberate, single exception to "nothing is
  parented to AuctionFrame", so it doesn't read as leftover overlay code.
- `CLAUDE.md`'s project layout was missing `core/buy.lua`, `ui/skin.lua` and
  `pfui/`, and its load order omitted `buy` and `skin`.

## [1.1.3]

### Fixed
- **"Add to Aegis" no longer clips the profession window's right edge.** It was
  anchored flush with the Exit button's right edge, but the button is wider
  than Exit and its border art overhangs its logical bounds, so it overlapped
  the frame in both the stock UI and pfUI. Now inset 10px; the profit lines
  stack off the button, so they move with it.

## [1.1.2]

### Fixed
- **The Aegis tab's settings no longer run off the bottom of the window.**
  Everything below the tip line now sits in a scrollable region with its own
  bar (mouse wheel works too); the bar hides itself when it isn't needed. The
  settings block had simply outgrown the panel — *Price data / Clear price
  data* was clipped by the window edge with no way to reach it.
- **"Add to Aegis" and the profit lines are aligned on the stock profession
  window.** They were anchored to the frame's own bottom-right corner, which on
  the unskinned window is out under its thick ornate border art — so the whole
  cluster sat outside the panel. pfUI's border is a hairline, which is why this
  only ever looked right when skinned. They now anchor to the window's own
  Exit button, which is inside the content area in both UIs.

### Changed
- The Discord invite moved to `hsgPTNkSX` across all five places in the README.

## [1.1.1]

### Changed
- **Nothing claims to be "Required" any more, and the loader badges are gone.**
  Aegis calls only vanilla 1.12 API, so the SuperWoW / Nampower / UnitXP_SP3 /
  ClassicAPI badges were removed rather than left implying a relationship with
  this addon. **AuctionQueryThrottle** stands alone as *Highly Recommended* — the
  only external thing that changes Aegis's behaviour, and only scan speed — with
  a caption stating that Aegis needs no mods or DLLs.
- Added a **Client** badge (WoW 1.12 vanilla); the version badge was dropped, so
  the version now lives in the `.toc` and the in-game title bar.

## [1.1.0] — first public release

> Aegis: Exchange is officially released. Everything below 1.1.0 was
> pre-release development; the feature set it shipped with is the sum of it.

### Added
- **Cancel all undercuts** on the Auctions tab — one button, labelled with the
  count, that cancels every auction someone is currently beating. It works from
  the highest owner index down, because cancelling shifts the later indices.
- **"Ask before cancelling an auction"** toggle on the Aegis tab. Turn it off and
  Cancel (single or bulk) acts on the first click.
- **Scan results report.** Finishing a scan now prints a breakdown: auctions
  scanned, distinct items, a per-quality tally in item colours, items added vs.
  updated in the price DB, items ignored, and pages/duration.

### Changed
- **Shipping defaults are now undercut / flat / 1 copper** — cheapest by the
  smallest possible margin, rather than giving away 5%.
- Badge colours: Octo WoW purple, Capy WoW brown, Required red, Recommended
  orange. The pfUI badge is gone (it was never required) — the "Using pfUI?"
  section says so instead.
- README leads with an **AuctionQueryThrottle** notice, including that the gain
  is realm-dependent (Octo WoW dramatically faster, Capy WoW roughly 2×), and a
  note that Aegis itself calls **only** vanilla 1.12 API — the loader badges
  describe the recommended realm setup, not Aegis's own dependencies.

### Fixed
- **"Posted 0 of 1 — couldn't assemble a stack."** `SplitContainerItem` only
  splits *part* of a stack; asking it for the whole stack is a no-op on 1.12, so
  the cursor stayed empty and the job died after retrying. Posting a single full
  stack always hit this. The assembler now picks the whole stack up instead.
  (The harness's sim happily split whole stacks, which is why this was never
  caught — it now models the real no-op.)
- **The post-scan queue sometimes slotted the wrong item, or nothing.** It used
  the bag/slot captured when the queue was built, and posting shifts bags. It now
  re-locates each item by itemId via the new `sell.FindItemSlot`.

## [0.21.1]

### Changed
- **Auto pacing is now genuinely minimal.** Our own floor between pages dropped
  from 0.25s to 0.05s — at 0.25s a 60-page scan spent 15s waiting on *us*
  rather than the server. The client's gate is still what actually throttles.
- The scan readout now splits the per-page cost into **gate** vs **server**
  (`fast — gate 0.02s, server 0.61s`), so a slow scan can be blamed correctly.
  Realm-to-realm differences show up here as server time, not gate time.

## [0.21.0]

### Added
- **Adaptive scan pacing.** Aegis now waits on the client's own
  `CanSendAuctionQuery()` gate rather than a fixed wall-clock delay, so a client
  running the [AuctionQueryThrottle](https://github.com/brues-code/AuctionQueryThrottle)
  DLL scans as fast as the server answers, while a stock client still waits its
  ~5s. That DLL is not an addon, so there is nothing to detect — the gate *is*
  the signal.
- **Scan pacing** setting on the Aegis tab (**Auto** / **Safe 4s**) with a live
  readout of what the gate is actually doing (`fast — gate opened in 0.28s`).

## [0.20.2]

### Fixed
- **pfUI: header row alignment.** The title strip now hugs the frame under the
  skin, and the close button anchors to the *strip* (centred on it) rather than
  the frame corner — so the X, version text and **Blizzard UI** button stay
  locked together. Our default offsets were tuned for vanilla's thick border;
  pfUI's is a hairline, so everything drifted.
- **pfUI: merchant button alignment.** The **Aegis: sell N marked** button moved
  into the tab row, right of Merchant / Buyback. It anchors to the *tabs*, which
  move with the window when pfUI restyles it, so it lines up in both UIs.

## [0.20.1]

### Added
- **Every column sorts.** Buy and Crafting gained **Item** (alphabetical) and
  **Ct**; the Sell tab's listing table gained sorting on all five of its columns.
- **Auto-pricing on the Sell tab.** Selecting an item fills the buyout from its
  lowest competing listing with your undercut rule applied. A price you typed
  yourself survives a re-scan of the same item.

### Fixed
- **pfUI: close button** rendered as an oversized empty box — pfUI's generic
  button skinner strips the X. Now routed to its close-button helper.
- **pfUI: sort headers** were skinned into boxes that visibly overlapped. They
  now opt out of skinning and stay bare clickable text.
- `Blizzard_AuctionUI.lua:836: attempt to perform arithmetic on field 'page'`.
  Blizzard seeds `AuctionFrameAuctions.page` in its own `OnShow`, but we replace
  that window — so any owned-auction update we caused hit their handler with a
  nil field. Now seeded when we hook the AH.

## [0.20.0] — restart

### Added
- **pfUI skin.** With pfUI installed, Aegis restyles itself using pfUI's own
  backdrop / button / checkbox / scrollbar helpers. Toggle with **Match pfUI's
  look** on the Aegis tab. Purely cosmetic and fully guarded — if pfUI's API
  changes, the worst case is the default look.
- `pfui/Aegis_Exchange.lua`, an optional drop-in for
  [pfUI-addonskinner](https://github.com/mrrosh/pfUI-addonskinner) users.

## [0.19.1]

### Fixed
- Merchant button no longer lands on pfUI's Merchant / Buyback tabs.

## [0.19.0]

### Added
- **Sell vendor-marked items at a merchant.** Tick items on the Vendor list
  (or *Mark all*); at any merchant an **Aegis: sell N marked** button appears,
  confirms what's about to go, sells the lot, and logs the gold to History.
- The Sell tab's per-item scan now shows the same live
  `Page 3 / 6 • ~12s • 16.6/s` line as the Aegis strip.

## [0.18.0]

### Added
- **Vendor list** — bag items worth more at a merchant than on the AH, comparing
  vendor price against the best AH price *after the 5% cut*, sorted by gain.
- **History panel on the Sell tab** — what your scans say the item is worth
  (median, range, days of data) next to what it has actually sold for.
- **Post-scan sell queue** — after a bag scan the first item is slotted
  automatically; **Post** or **Skip** walks to the next.

## [0.17.0]

### Added
- **History tab.** Sales are logged straight from your mailbox (every
  "Auction successful" mail, deduped so reopening never double-counts);
  purchases are logged when you buy. Shows **Income · Spent · Net** over
  24h / 7d / 30d / all time.

## [0.16.1]

### Fixed
- Hovering the sell slot could throw a Lua error. Tooltip hooks now only wrap
  methods that actually exist, and the slot uses `SetAuctionSellItem`.

## [0.16.0]

### Added
- **Stop** button for scans — a paused scan no longer blocks browsing, so you
  can pause, check a price, then resume or stop.
- **Undercut by a flat amount** as well as a percentage (1 copper now works).
- Hover tooltips on the Sell tab's bag list and sell slot.
- Item icons beside names on the Buy and Auctions tabs.
- Bid-only auctions show the current bid instead of just "bid only".

### Changed
- The header bar now extends cleanly to the close button.

## [0.15.1]

### Removed
- The window portrait / crest (revisiting the branding later).

## [0.15.0]

### Added
- **Auctions tab** — your active auctions with time left, bid state, an
  **undercut flag** (green = still cheapest, red = someone's under you), and a
  per-row Cancel. This filled the last placeholder tab.

## [0.14.0]

### Added
- Aegis crest as a window portrait. *(Removed again in 0.15.1.)*

## [0.13.0]

### Added
- **Aegis tab** (was Scan) with settings: default post duration, undercut rule,
  default sell price, tooltip lines, profit line, and price-data management.

### Changed
- **Add to Aegis** moved to the profession window's bottom-right, below the
  profit text — clear of both the stock UI and pfUI.

## [0.12.1]

### Fixed
- Profit line no longer overlaps the skill progress bar; Crafting's **Search**
  button no longer covers the **Item** column header.

## [0.12.0]

### Added
- **Live profit line on profession windows** — reads saved prices, so it works
  with the auction house closed.

## [0.11.0]

### Added
- **Crafting profit/loss estimate**: reagent cost vs. what the item sells for,
  minus the 5% cut.

### Changed
- **Ordinary searches now feed the price database**, not just full scans — so
  `% mkt` and profit estimates work without scanning everything.

## [0.10.0]

### Added
- **Crafting tab** and the **Add to Aegis** button on profession windows:
  capture a recipe, then shop each reagent like any other item.

## [0.9.x]

### Added
- **Buy tab**: search, sort, buy and bid; shopping lists and recent searches.
- Click a listing to adopt its price; max-price filter; sortable columns.

## [0.8.0]

### Added
- Multi-stack posting — "3 stacks of 20" in one go.

## [0.7.x]

### Added
- Sell tab bag browser, per-item live scan, and a listings table.
- Soulbound and non-postable items filtered out.

## [0.6.0]

### Added
- **Sell tab** — post from the sell slot with Aegis price context.

## [0.5.0]

### Added
- Scan as its own tab; two-way swap with the Blizzard auction house.

## [0.4.0]

### Fixed
- The real scan killer: hiding the Blizzard AH is now deferred past
  `AuctionFrame_Show`'s visibility guard, which was silently ending the session
  and leaving scans stuck on "Requesting first page…".

## [0.1.0] – [0.3.0]

### Added
- Standalone Aegis window replacing the auction house frame.
- Page-by-page auction scanner with throttling, pause / resume, and a targeted
  class → subclass category picker.
- Price database — daily minimum buyouts, market value as a time-weighted
  median over ~11 days.
- Price lines on item tooltips, including vendor price.

---

[1.45.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.45.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.44.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.43.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.42.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.41.2]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.41.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.41.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.40.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.39.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.39.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.38.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.37.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.36.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.35.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.34.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.33.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.32.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.31.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.30.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.30.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.29.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.28.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.28.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.27.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.26.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.25.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.25.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.24.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.23.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.22.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.21.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.21.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.20.2]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.20.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.20.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.19.4]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.19.3]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.19.2]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.19.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.19.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.18.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.17.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.16.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.16.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.15.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.15.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.14.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.14.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.13.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.12.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.11.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.10.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.9.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.8.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.7.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.6.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.5.3]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.5.2]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.5.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.5.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.4.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.3.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.2.0]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.9]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.8]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.7]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.6]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.5]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.4]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.3]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.2]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
