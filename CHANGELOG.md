# Changelog

All notable changes to **Aegis: Exchange**.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
The version here matches `## Version` in `Aegis_Exchange.toc` and the number
printed in the window title bar — quote it in bug reports.

> ⚠️ Releases marked **restart** add a new `.lua` file. WoW 1.12 reads the file
> list at startup, so `/reload` won't pick them up — you need to fully restart
> the client. Everything else is `/reload`-safe.

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

[1.1.9]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.8]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.7]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.6]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.5]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.4]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.3]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.2]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
[1.1.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
