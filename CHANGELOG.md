# Changelog

All notable changes to **Aegis: Exchange**.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
The version here matches `## Version` in `Aegis_Exchange.toc` and the number
printed in the window title bar — quote it in bug reports.

> ⚠️ Releases marked **restart** add a new `.lua` file. WoW 1.12 reads the file
> list at startup, so `/reload` won't pick them up — you need to fully restart
> the client. Everything else is `/reload`-safe.

---

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
