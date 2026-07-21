# CLAUDE.md — Aegis: Exchange

A World of Warcraft addon (folder + `.toc` name: **`Aegis_Exchange`**) — a clean
auction house helper for **Turtle WoW 1.18.1**, which runs the **ORIGINAL WoW
1.12 (vanilla) client on Lua 5.0**.

> This is **NOT** WoW Classic and **NOT** retail. Do **not** use any API newer
> than patch **1.12**. When in doubt, assume the API does not exist.

---

## HARD RULES — never violate these

These are not style preferences. Breaking any of them produces a runtime error
or silent breakage on the 1.12 / Lua 5.0 client.

### Language (Lua 5.0)

1. **Lua 5.0 only.** **NO** `string.match`, **NO** `string.gmatch`, **NO**
   `:match()`. Use **`string.find`** (with captures) and **`string.gfind`**.
   - `string.gfind` is the 5.0 name for what later Lua calls `string.gmatch`.
2. **NO `#` length operator.** Use **`table.getn(t)`**. **NO `table.setn`.**
3. **NO `%` modulo operator.** Use **`math.mod(a, b)`**.
   - Lua 5.0 also has no integer division — combine `math.floor` with
     `math.mod`.
4. **Varargs use the `arg` table and `arg.n`** — not `...` expansion helpers
   from later versions. (`select()` does not exist.)
5. String library note: `string.gsub`, `string.find`, `string.gfind`,
   `string.format`, `string.sub`, `string.lower`/`upper` are fine. The banned
   ones are strictly the `match`/`gmatch` family.

### Events

6. **Event handlers read the GLOBALS `event`, `arg1`, `arg2`, …** — **NOT**
   `function(self, event, ...)`. On this client the OnEvent script receives no
   arguments; the client sets `this`, `event`, and `arg1..argN` as globals.
   - Central dispatch lives in `core/init.lua`. Register with
     `AegisExchange.RegisterEvent(evt, fn)`; the dispatcher reads the globals
     and forwards them.

### Hooking

7. **NO `hooksecurefunc` and NO secure hooks.** Hook by **saving the original
   function and replacing it**, then call the saved original from your
   replacement. (Secure-hook infrastructure does not exist in 1.12.)
   See `ui/tooltip.lua` for the canonical pattern.

### Auction House API (1.12)

8. **`GetAuctionItemInfo("list", i)`** returns **ONLY** these values, in order:
   ```
   name, texture, count, quality, canUse, level,
   minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner
   ```
   Nothing else. **`owner` may be `nil`** until the name resolves — re-read the
   page or handle nil gracefully.
9. **`QueryAuctionItems` takes 9 args:**
   ```
   QueryAuctionItems(name, minLevel, maxLevel, invTypeIndex,
                     classIndex, subclassIndex, page, isUsable, qualityIndex)
   ```
   - **`page` is 0-indexed.**
   - **There is NO working `getAll` on 1.12.** Do not attempt a bulk pull.
   - Pass **strings** for `name` / `minLevel` / `maxLevel` — **`""` when
     unused, never nil**. The stock browse UI sends `GetText()` results
     (always strings) and Auctionator does the same; servers may silently
     ignore a query with nils in those slots. The index/flag args
     (`invType`, `class`, `subclass`, `isUsable`, `quality`) stay nil for
     "no filter".
10. **Throttle every query.** Poll **`CanSendAuctionQuery()`** before **every**
    query. Leave **~4 seconds between pages**. Wait for the
    **`AUCTION_ITEM_LIST_UPDATE`** event before reading a page.
11. **Page size is 50.**
12. **Hiding `AuctionFrame` ENDS the AH session.** `AuctionFrame`'s XML
    `<OnHide>` runs **`CloseAuctionHouse()`**, so **any** `AuctionFrame:Hide()`
    / `HideUIPanel(AuctionFrame)` closes the server session and every following
    `QueryAuctionItems` becomes a silent no-op (a scan spins forever on
    "Requesting first page…"). Our standalone window replaces the Blizzard AH,
    so it must hide `AuctionFrame` **without** letting that `<OnHide>` body run:
    save-and-replace its `OnHide`, and while *we* are the one hiding it, skip
    the default body so the session survives. See `ui.HideBlizzardAH` /
    `ui.HookAuctionFrame` in `ui/frame.lua`.

### SavedVariables

13. **SavedVariables are `nil` until `ADDON_LOADED` fires for
    `"Aegis_Exchange"`.** Do all DB setup from the ADDON_LOADED path (queue via
    `AegisExchange.OnLoad(fn)`), never at file scope.
    - `AegisExchangeDB` — account-wide (declared `## SavedVariables`).
    - `AegisExchangeCharDB` — per-character (`## SavedVariablesPerCharacter`).

### Frames & globals

14. Use **`getglobal()` / `setglobal()`** for dynamic frame names (e.g.
    building `"AuctionFrameTab" .. n`).
15. Build frames with **`CreateFrame`** using **vanilla templates only**, e.g.
    `UIPanelButtonTemplate`, `FauxScrollFrameTemplate`, `GameTooltipTemplate`,
    `AuctionTabTemplate`.
    - **AH tabs inherit `AuctionTabTemplate`** (what the stock
      `AuctionFrameTab1..3` inherit; verified in-game and against the Turtle
      1.12 UI source). There is **NO** template named `AuctionFrameTab` —
      using it throws `Couldn't find inherited node`.

---

## Turtle WoW specifics

Turtle exposes a global **`TURTLE_WOW_VERSION`** — use it to detect Turtle
(see `AegisExchange.isTurtle`).

- **Cross-faction AH.** Turtle's auction house is a **single shared economy**.
  Do **not** split the price DB by faction.
- **Auction durations are ×3 vanilla** — max **72h**.
- **Deposit is inflated** in what the client shows. Apply a **~0.6 factor** as
  an approximation and **label it "approx"** in the UI. Never present it as
  exact.
- **120-auction account cap.**
- **5% faction consignment cut** on sales.

---

## Project layout

```
Aegis_Exchange/
  Aegis_Exchange.toc     -- Interface 11200; declares SavedVariables + load order
  core/init.lua          -- namespace (AegisExchange) + event dispatcher + OnLoad queue
  core/util.lua          -- Lua 5.0 safe helpers (money fmt/parse, split, table utils)
  core/db.lua            -- SavedVariables price DB (daily-min + weighted-median market)
  core/scan.lua          -- page-by-page auction scanner state machine
  ui/frame.lua           -- standalone Aegis window (replaces the AH) + sub-tabs
  ui/tooltip.lua         -- GameTooltip price lines (save/replace hooks)
  design/                -- VISUAL REFERENCE ONLY (mockup renders + source);
                         -- never ported to Lua verbatim, NEVER in the .toc
  CLAUDE.md              -- this file
```

Load order is fixed by the `.toc`: `init` → `util` → `db` → `scan` → `frame` →
`tooltip`. `init.lua` must load first (it creates the namespace and dispatcher).

The repository root **is** the addon folder: clone/copy it into
`Interface/AddOns/Aegis_Exchange` so the folder name matches the `.toc`.

---

## Reference addons

Read their patterns for how vanilla AH scanning, throttling, and tooltip hooks
are done in practice — **imitate the approach, do not copy code blindly**:

- **aux-addon-vanilla** — https://github.com/shirsig/aux-addon-vanilla
- **AuctionatorVanilla** — https://github.com/nimeral/AuctionatorVanilla
- **LilSparkysWorkshop-vanilla** — https://github.com/laytya/LilSparkysWorkshop-vanilla

---

## Quick self-check before committing Lua

- [ ] No `string.match` / `string.gmatch` / `:match()` — used `string.find` /
      `string.gfind`.
- [ ] No `#` — used `table.getn`. No `table.setn`.
- [ ] No `%` operator — used `math.mod`.
- [ ] Event handlers read `event` / `arg1…` globals (not `self, event, ...`).
- [ ] No `hooksecurefunc` / secure hooks — saved original + replaced.
- [ ] AH reads match the 12-value `GetAuctionItemInfo` and 9-arg
      `QueryAuctionItems` signatures; queries gated on `CanSendAuctionQuery()`.
- [ ] DB touched only after `ADDON_LOADED` for `"Aegis_Exchange"`.
