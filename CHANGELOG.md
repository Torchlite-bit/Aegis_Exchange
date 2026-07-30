# Changelog

All notable changes to **Aegis: Exchange**.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
The version here matches `## Version` in `Aegis_Exchange.toc` and the number
printed in the window title bar — quote it in bug reports.

> ⚠️ Releases marked **restart** add a new `.lua` file. WoW 1.12 reads the file
> list at startup, so `/reload` won't pick them up — you need to fully restart
> the client. Everything else is `/reload`-safe.

---

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

[1.1.1]: https://github.com/Torchlite-bit/Aegis_Exchange/releases
