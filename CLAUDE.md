# CLAUDE.md — Aegis: Exchange

A World of Warcraft addon (folder + `.toc` name: **`Aegis_Exchange`**) — a clean
auction house helper for **Turtle WoW 1.18.1**, which runs the **ORIGINAL WoW
1.12 (vanilla) client on Lua 5.0**.

> This is **NOT** WoW Classic and **NOT** retail. Do **not** use any API newer
> than patch **1.12**. When in doubt, assume the API does not exist.

**Planned work lives in [`ROADMAP.md`](ROADMAP.md)**, phased and dependency
ordered, including the integration contract for the planned **Aegis: Courier**
companion addon (separate repo). Check it before starting any large feature
so the phase ordering and settled design decisions aren't re-litigated or
built out of order.

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
    query — that gate is the authority, never a wall-clock timer alone. Wait
    for the **`AUCTION_ITEM_LIST_UPDATE`** event before reading a page.
    - The client keeps the gate shut ~5s after each query, which is where the
      old "leave ~4 seconds between pages" rule of thumb came from. We now
      apply only a small floor (`scan.FAST_DELAY`) and let the gate do the
      throttling, because the **AuctionQueryThrottle** DLL
      (<https://github.com/brues-code/AuctionQueryThrottle>) clears that timer
      as soon as the reply lands. It is a DLL, **not an addon** — there is
      nothing to `IsAddOnLoaded()`, so the gate itself is the detector: it
      opens fast with the DLL and stays shut ~5s without it.
    - `scan.PageDelay()` returns the floor for the current pacing setting;
      "safe" restores the fixed 4s for clients that report the gate unreliably.
      **Never** send a query without checking the gate, whatever the floor.
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
    - **A SECOND close path lives in `AuctionFrame_Show()`** (the client's
      AUCTION_HOUSE_SHOW handler, verbatim from the Turtle UI source):
      ```
      ShowUIPanel(AuctionFrame);
      if ( not AuctionFrame:IsVisible() ) then
          CloseAuctionHouse();
      end
      ```
      So hiding the Blizzard AH **synchronously from its own `OnShow`** also
      kills the session. The takeover hide must be **deferred one OnUpdate
      tick** (see `AegisExchangeHider` in `ui/frame.lua`). Hiding from our own
      AUCTION_HOUSE_SHOW handler is safe — it runs after this guard.

### The 32-upvalue ceiling

12a. **A function may read at most 32 file-scope locals. Lua 5.0 refuses to
    LOAD a file that breaks this** — `too many upvalues (limit=32)` — so the
    whole addon dies, not just that feature.

    Every file-scope `local` a function references costs one upvalue. A big
    builder function plus a handful of new layout constants is all it takes:
    `ui.BuildBuyTab` hit 36 and v1.16.0 shipped an addon that would not load.

    **Nothing local catches this.** `luac5.1 -p` compiles the file happily
    and any Lua 5.1 test harness runs it happily, because 5.1's limit is 60.
    The only signal is `luac -l`, which prints an upvalue count per function:

    ```
    luac5.1 -l -p ui/frame.lua | grep upvalues
    ```

    **The fix is a table.** Thirteen constants as thirteen locals cost
    thirteen upvalues; the same thirteen as fields of one table cost one. See
    `BUYL` in `ui/frame.lua`. Group new layout constants into it rather than
    adding another file-scope local next to a function that is already large.

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
    - **`FauxScrollFrame_OnVerticalScroll(itemHeight, updateFn)` — 2 args on
      1.12.** The frame and scroll offset are the implicit globals `this` /
      `arg1`. The offset-first form belongs to later clients; using it here
      passes a number as the update function and FrameXML crashes with
      "attempt to call local 'updateFunction' (a number value)".

### Event handler cost — SUITE-WIDE (applies to every Aegis addon)

16. **A handler for an event that can STORM must be O(1), state-gated, or
    coalesced behind a once-per-frame flush. Never an unbounded rescan, and
    never a per-item client query, inline in the handler.**

    This is a freeze rule, not a tidiness rule. On 1.12 the client populates
    its item cache lazily, so the **first** time a session sees mail with
    unseen attachments, the client fires `MAIL_INBOX_UPDATE` (and, because
    the stock `MAIL_SHOW` handler calls `OpenBackpack()`, `BAG_UPDATE`)
    repeatedly as each item resolves — dozens of fires in a few frames.
    Later opens do not, which is why the symptom is *"only the first time,
    and it goes away if you open the mailbox once with the addon
    disabled"*. Any handler doing real work per fire gets multiplied by that
    storm.

    Measured across the suite on one 1.12 client (SuperWoW + nampower +
    UnitXP_SP3, ~10+ mails): **Courier hard-froze, RallyPower stalled ~18s
    despite having no mailbox feature at all** (it registers a bag/inventory
    event, which is enough), Blizzard's own UI and TurtleMail were fine, and
    **Exchange was clean**. Exchange is the reference case, and the reason is
    entirely structural — see below.

    **The three shapes that are safe.** All three are in this repo already;
    copy whichever fits:

    - **O(1) / bounded, no item queries.** `ui.ScanMailSales`
      (`ui/frame.lua`) does ONE pass over the mail headers per fire, reading
      only `GetInboxHeaderInfo` — header text and money, never
      `GetInboxItem`, never a tooltip. It touches no item data at all, so it
      cannot participate in the cache storm no matter how often it fires,
      and it repaints nothing unless the History tab is the visible one. N
      fires × M mails costs N×M cheap header reads and nothing else.
    - **State-gated.** `core/buy.lua`'s `AUCTION_ITEM_LIST_UPDATE` handler
      runs `ReadPage` only while `phase == "wait_results"`, and `ReadPage`
      sets `phase = "idle"` before it returns. Repeat fires in the same
      frame are no-ops. This is what makes the one expensive auction path
      (up to 50 `GetItemInfo` calls per page) self-limiting: exactly one
      execution per query WE sent, paced by `CanSendAuctionQuery()`.
    - **Dirty flag + once-per-frame flush.** Set a boolean in the handler,
      do the work in an existing `OnUpdate`. Use this whenever the work is a
      full rescan that cannot be made cheap.

    **What must never appear inline in a stormable handler:**
    `GetItemInfo` per item, any `GameTooltip:Set*` per item, a full bag or
    inventory walk, or a list repaint. If a handler needs any of those, it
    needs a dirty flag.

    **Corollary — keep private scanning tooltips private.** `ui/tooltip.lua`
    hooks by assigning to the **`GameTooltip` object** (`GameTooltip[name] =
    ...`), which shadows the shared widget metatable for that one frame.
    Our own scanning tooltips (`AegisExchangeQueryTooltip` in `core/buy.lua`,
    and `core/sell.lua`'s) are separate frames, so their `Set*` calls resolve
    through the metatable to the untouched original and do **not** re-enter
    our price-line code. Hooking the metatable instead would make every
    per-row tooltip read in a filter or bag scan run the full tooltip
    extension — turning a bounded scan into an unbounded one. Never
    "simplify" the hook that way.

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
  core/db.lua            -- SavedVariables price DB (daily-min + weighted-median
                         -- market), settings, ledger, vendor prices
  core/disenchant.lua    -- the disenchant RULE (item level + quality + slot ->
                         -- materials). Constants generated, not typed. Its
                         -- last section is the ONE impure part: it watches the
                         -- player disenchant things and records what it sees
  core/scan.lua          -- page-by-page auction scanner state machine
  core/sell.lua          -- posting engine (StartAuction wrap + deposit/cap/cut),
                         -- owned auctions, vendor list
  core/buy.lua           -- search/buy engine + shopping lists; also defines the
                         -- A.craft namespace (recipe capture + profit maths)
  ui/frame.lua           -- standalone Aegis window (replaces the AH) + all six
                         -- sub-tabs; ~5k lines, the bulk of the addon
  ui/skin.lua            -- OPTIONAL pfUI restyling; every call pcall-guarded so
                         -- a pfUI API change can only cost us the default look
  ui/tooltip.lua         -- GameTooltip price lines (save/replace hooks)
  pfui/Aegis_Exchange.lua-- drop-in for pfUI-addonskinner users. NOT in the .toc
                         -- and NOT loaded by us; it just calls A.skin.Apply()
  design/                -- VISUAL REFERENCE ONLY (mockup renders + source);
                         -- never ported to Lua verbatim, NEVER in the .toc
  tools/                 -- build-time generators. NOTHING here ships and
                         -- nothing is in the .toc; adding a file is never a
                         -- restart release and never a version bump
  CLAUDE.md              -- this file
  ROADMAP.md             -- phased, dependency-ordered plan; check before
                         -- starting a large feature
```

Load order is fixed by the `.toc`: `init` → `util` → `db` → `disenchant` →
`scan` → `sell` → `buy` → `frame` → `skin` → `tooltip`.
**`tests/support/wow.lua` keeps a second copy of that order and checks itself
against the `.toc` at load** — two copies of one order is how a file gets added
to the addon but never to the tests. `init.lua` must load first (it creates
the namespace and dispatcher); `util` second (every other module takes a
file-scope `local util = A.util`); `sell` and `buy` before `frame` because the
tabs drive `A.sell` / `A.buy` / `A.craft`. `skin` and `tooltip` are only
reached at runtime, so their position is not load-critical.

**Adding a `.lua` file means editing the `.toc` — and that needs a FULL client
restart, not `/reload`.** 1.12 reads the file list at startup. Mark such a
release **restart** in `CHANGELOG.md`.

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

---

## README / CHANGELOG upkeep

- **The badge block at the top of `README.md` is maintained by the project
  owner.** It is grouped deliberately:
  1. Discord (`5865F2`), then the 1.18.1 servers — Raven (`1e1e1e`), Octo WoW
     purple (`8A2BE2`), Capy WoW brown (`8B5A2B`).
  2. The two OPTIONAL DLLs, on their own row: **ClassicAPI** green (`3fb950`,
     "Recommended") and **AuctionQueryThrottle** orange (`ff8c00`, "Highly
     Recommended"), followed by a `<sub>` caption saying Aegis runs on a stock
     client and naming what each one buys.

  **The Client badge was removed** (`c79c6e`, "WoW 1.12 vanilla). It restated
  what the server badges and the intro already say, and the row it sat in is now
  the optional-DLL row, where a client badge does not belong.

  **ClassicAPI earned its badge in code and nothing else has.** SuperWoW,
  Nampower and UnitXP_SP3 badges used to sit here; a grep of `core/` and `ui/`
  finds no calls to any of them, so they were removed rather than imply a
  relationship. `C_Item` IS called (`util.ClientSellPrice`,
  `util.ClientItemLevel`), which is why ClassicAPI came back. Same test for
  anything else: a code change that actually depends on it, or no badge.

  **Nothing is Required.** Both DLLs are optional and the addon states what it
  loses without them — do not reinstate a "Required" badge.

  There is **no version badge** — but the **H1 carries the version**
  (`# Aegis: Exchange (v1.1.2)`), so it is a bump site. See the checklist below.

  There is deliberately **no pfUI badge** — pfUI is optional, and the "Using
  pfUI?" section says so instead. Do not re-add it.

  Keep the shields.io style (`flat-square`, `labelColor=555`) when adding to it,
  and do not reorder, re-row or restyle it unasked.
- **One Discord invite, used everywhere: `https://discord.gg/hsgPTNkSX`.** It
  appears in five places — the badge, the intro line, "Something broken?",
  Contributing and the footer. Change all five together or none, and never
  swap it for one pasted in chat without confirming it is current.
  - This invite has now changed twice, and **both times only the badge got
    updated**, leaving the other four pointing at a dead invite. When you see
    the badge disagree with the body links, the badge is the new one — but
    confirm before propagating, because "the badge is stale instead" is
    equally possible and a wrong guess breaks every link in the file.
- Every version bump gets a `CHANGELOG.md` entry. Mark a release **restart**
  when it adds a new `.lua` file to the `.toc`.
- **A version bump touches FIVE places** — miss one and the in-game version
  stops matching the release:
  1. `core/init.lua` — `A.version`
  2. `Aegis_Exchange.toc` — `## Version:`
  3. `README.md` — the **H1**: `# Aegis: Exchange (vX.Y.Z)`
  4. `README.md` — the "Check the version" line in "Something broken?"
     (there is still no version *badge*; do not add one back)
  5. `CHANGELOG.md` — a new entry plus the link ref at the bottom

  The window title bar and the load message both read `A.version`, so they
  follow automatically.

### WHICH number to bump

`MAJOR.MINOR.PATCH`. **Aegis has had a public release, so MAJOR is 1.**

- **MAJOR (`1`.x.y) — stability.** It went to 1 at the public release and stays
  there. It moves again only for a change that breaks a player's existing setup
  without a migration — a SavedVariables format they cannot upgrade into, a
  removed feature people depend on. Not for "a lot has changed": size is not
  breakage.

- **MINOR (1.`x`.0) — a new capability.** The addon can do something it could
  not do before. A new tooltip line, a new filter, a new tab, a new data source.
  The test: *could a player notice a new thing, not merely a better thing?*
  Resets PATCH to 0.

- **PATCH (1.x.`y`) — a fix or a small correction.** Bug fixes, security fixes,
  typos, wording, colour, layout, and a rewritten formula that computes the same
  quantity more correctly. **No new capability.**

**Where this went wrong before.** A layout change is a PATCH. So is a colour,
a rename, and a corrected calculation. Ten releases in the 1.x line were
numbered MINOR for work that only fixed or polished, which is how the number ran
to 1.49.1 while `main` sat at 1.21.1.

**When a release does both** — adds a capability *and* fixes things — it is a
MINOR. The larger claim wins.

**Every shipped change bumps.** Not once per merge — once per piece of work.
Fix a bug on a feature branch and the PATCH goes up; add a capability and the
MINOR goes up and PATCH resets. The merge lands at whatever the branch has
reached, so a branch that adds a feature and then fixes three things in it
merges as `1.50.3`, not `1.50.0`.

The number is a running account of what happened, which is what makes
"quote the version in the title bar" worth asking for: a player on 1.49.2 and a
player on 1.49.5 are not running the same code, and a scheme that only bumps at
merge time cannot tell them apart.

**Not a release at all**, and therefore not a bump: anything under `tests/`,
`tools/` or `design/`, and edits to `CLAUDE.md` / `ROADMAP.md`. None of it ships.


---

## Quick self-check before committing Lua

**Most of this list is now automated — run `./tests/run.sh`.** It checks the
language rules, syntax, the upvalue ceiling and the top-level definitions, then
runs the unit suites. `./tests/run.sh --sabotage` additionally plants real bugs
in a throwaway copy and requires the suites to catch them. See
[`tests/README.md`](tests/README.md), including what it deliberately does
**not** cover: anything visual — layout, colour, clipping, either skin — is not
testable there and still needs a real client and a person looking at it.

Adding a test file changes nothing about the addon: nothing in `tests/` is in
the `.toc`, so it is never a **restart** release and never a version bump.

- [ ] No `string.match` / `string.gmatch` / `:match()` — used `string.find` /
      `string.gfind`.
- [ ] No `#` — used `table.getn`. No `table.setn`.
- [ ] No `%` operator — used `math.mod`.
- [ ] Event handlers read `event` / `arg1…` globals (not `self, event, ...`).
- [ ] No handler for a stormable event (`MAIL_INBOX_UPDATE`, `BAG_UPDATE`,
      `AUCTION_ITEM_LIST_UPDATE`, …) does an unbounded rescan, a
      `GetItemInfo`/`GameTooltip:Set*` per item, or a list repaint inline —
      it is O(1), state-gated, or behind a dirty flag flushed once per frame.
- [ ] No `hooksecurefunc` / secure hooks — saved original + replaced.
- [ ] No function exceeds **32 upvalues** (`python3 tests/lint/upvalues.py`, or
      by hand `luac5.1 -l -p f.lua | grep upvalues`). `luac -p` and a 5.1
      harness will NOT catch this; the client refuses to load the file.
- [ ] No `C.<colour>` was invented (`python3 tests/lint/palette.py`). The UI
      file is never loaded by a suite, so a colour that is not in the palette
      passes every check and throws when a player opens that tab.
- [ ] No top-level definition was lost to a scripted edit
      (`python3 tests/lint/definitions.py`). Run this after ANY multi-line or
      scripted edit — the file still compiles when a function goes missing, so
      nothing else notices.
- [ ] No file-scope local is read ABOVE its declaration
      (`python3 tests/lint/scoping.py`). Lua scopes a `local` from its
      declaration onward, so a function defined earlier reads a nil **global**
      of the same name — legal Lua, compiles cleanly, fails only at runtime.
      This has now caught `ColumnsFitAt`, `BUY_ROWS_MAX`, `SIDE_ROW_H` and
      `BUYL`; the last one shipped and the window would not open.
- [ ] AH reads match the 12-value `GetAuctionItemInfo` and 9-arg
      `QueryAuctionItems` signatures; queries gated on `CanSendAuctionQuery()`.
- [ ] DB touched only after `ADDON_LOADED` for `"Aegis_Exchange"`.
