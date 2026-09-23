# Aegis: Exchange (v1.54.15)

**A clean, fast auction house for vanilla WoW (1.12).**

[![Discord](https://img.shields.io/badge/Discord-join%20us-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/hsgPTNkSX)
[![RavenCraft](https://img.shields.io/badge/RavenCraft-1.18.1-1e1e1e?style=flat-square&labelColor=555)](https://ravencraft.io/)
[![CapyCraft](https://img.shields.io/badge/CapyCraft-1.18.1-8B5A2B?style=flat-square&labelColor=555)](https://capycraft.io/)
[![Octo WoW](https://img.shields.io/badge/Octo%20WoW-1.18.1-8A2BE2?style=flat-square&labelColor=555)](https://octowow.st/)

[![ClassicAPI](https://img.shields.io/badge/ClassicAPI-Recommended-3fb950?style=flat-square&labelColor=555)](https://github.com/brues-code/ClassicAPI)
[![AuctionQueryThrottle](https://img.shields.io/badge/AuctionQueryThrottle-Highly%20Recommended-ff8c00?style=flat-square&labelColor=555)](https://github.com/brues-code/AuctionQueryThrottle)

<sub>**Aegis runs on a stock client.** Two optional DLLs make it better, and
neither is required: **AuctionQueryThrottle** makes scans much faster, and
**ClassicAPI** gives exact item levels and vendor prices — without it, disenchant
values are estimated from the level needed to equip an item and are labelled
*(approx)*.
</sub>

The stock 1.12 auction house is three text boxes and a prayer. Aegis replaces it
with a window that knows what things are worth — what to charge, what to pay,
whether that recipe is worth crafting, and where your gold went this week.

> Built for **1.18.1** servers (Octo WoW, Capy WoW, Turtle WoW, RavenCraft),
> which run the original **WoW 1.12 (vanilla)** client on **Lua 5.0**. Not
> Classic. Not retail. Real vanilla.

> ### ⚡ Scans fastest with AuctionQueryThrottle
> Vanilla makes the client sit out ~5 seconds between auction queries.
> **[AuctionQueryThrottle](https://github.com/brues-code/AuctionQueryThrottle)**
> clears that timer the moment the server replies, and Aegis picks the change up
> **automatically** — nothing to configure. What's left is your realm's own
> response time, so the gain varies: **Octo WoW** is dramatically faster, **Capy
> WoW** lands around **2×**. The Aegis tab tells you which you're getting
> (`fast — gate 0.02s, server 0.61s`).
>
> It's a DLL, not an addon, and it needs the VanillaFixes loader.

**[💬 Join the Discord](https://discord.gg/hsgPTNkSX)** for help, bug reports,
and feature ideas.

---

## Contents

- [What it does](#what-it-does) — the six tabs, and the shopping list
- [Using pfUI?](#using-pfui)
- [Install](#install) · [Using it](#using-it)
- [A few honest notes](#a-few-honest-notes)
- [Under the hood](#under-the-hood)
- [Something broken?](#something-broken) · [Contributing](#contributing)

---

## What it does

### 🛒 Buy — shop like you mean it

**Results group by item** — one row per item with how many auctions, how many
items (`8 auctions, 129 items`) and the lowest price you can actually pay,
instead of forty rows of Mana Potion.

- **Left-click** a row to open it and see every auction underneath — seller,
  stack, time left, price. No new search; the listings are already in hand.
- **Right-click** to search that item alone, all of it, not just this page.

Two columns are the reason to be here: **Unit** (price per item, so a stack of
20 compares with a stack of 1) and **% Mkt** — **green under market, red over**.
Names are quality-coloured the way their tooltips are.

It opens looking like the auction house you know: Name, Level Range, Min
Quality, Usable items, **Display on Character** (try gear on as you click it),
categories down the left, Bid / Buyout along the bottom.

- **Advanced** swaps in a full query box and three views: **Results**,
  **Saved** (every search you've run, plus favourites you order yourself) and
  **Builder** (the same language as a form).
- **Receipt** opens everything you've bought **this session** — units,
  auctions, average each and total spent, biggest spend first. It survives
  leaving the auction house, because a crafting run takes several trips;
  **Clear** is the reset.
- **Shortcuts:** right-click a bag item to search for it, shift-click any item
  anywhere to drop its name in the box, **Tab** to autocomplete from everything
  Aegis has seen.

<details>
<summary><b>The search language</b> — optional; a plain name still just searches for that name</summary>

| Type this | Get that |
|---|---|
| `[Linen Cloth]` or `linen cloth/exact` | only *Linen Cloth*, not *Bolt of Linen Cloth* |
| `armor/plate/chest` | plate chest pieces |
| `belt/quality/rare` · `bracers/rarity/rare` | rare **and better** · rares **only** |
| `sword/level20-30` · `sword/min-level/20/max-level/30` | required level 20–30 · the same, combinable with `or` / `not` |
| `runecloth/buyout` | skip bid-only auctions |
| `mageweave/stack 20` · `mageweave/stack` | stacks of exactly 20 · the biggest stacks |
| `wristbands/tooltip/+3 stam/+3 agi` | **both** stats on one item |
| `wristbands/tooltip/+3 stam/or/tooltip/+3 agi` | either stat |
| `boots/not/tooltip/soulbound` | excludes what the clause matches |
| `silk cloth/max-unit-buy/5g` | at or under 5g **per item** |
| `linen/seller/Bob` · `linen/left/short` | by seller · about to expire |
| `linen/percent/70` | at or under **70% of market** |
| `linen/vendor-profit/50s` | a vendor pays 50s **more** than it costs |
| `wristbands/disenchant-profit/1g` | worth 1g more broken than bought |
| `wristbands/disenchant-percent/70` | costs at most 70% of what it breaks into |
| `linen;wool;silk` | all three, browsed as one list |

Terms combine with `/`; `;` runs several searches back to back. **Categories are
the game's own names**, in your language — class, then subclass, then slot. A
word matching *several* categories stays a name search rather than guessing.

**`stack 20` always works; bare `stack`** needs the item's maximum stack, which
1.12 only reports for items your client has cached — Aegis remembers every one
it learns and otherwise uses the biggest on the page, saying so.

**Filters that can't judge a row say so** instead of silently returning nothing:
`3 skipped (no vendor-profit data — vendor prices are learned at a merchant)`.

**These filters run on your client**, and the server only hands over 50
listings a page — so a rare match lands wherever the server put it
(`vendor-profit` on page 3 of 277 is normal). Aegis **keeps paging until a page
has matches**, stops there, and tells you how far it went; it gives up after 25
pages and **▶** starts another run.

</details>

### 💰 Sell — price it right the first time

**Your Bags** lists everything you can post. Click one and Aegis scans for *just
that item*, shows every competing listing, and pre-fills your price —
**Undercut** (percentage or flat, 1 copper works) or **Price match**. Click any
competitor's row to take their price.

The header carries **Total**, **Deposit**, **After cut** (what reaches your
mailbox after the 5% cut) and **Listings** against the 120-auction cap.

- **Post several stacks at once** on interlocking sliders. **Max** fills in
  every stack of that size you can actually assemble — 1.12 can't merge stacks.
- **Leftovers stay ready**: post two stacks of ten out of twenty-five and the
  last five come back into the slot at the same price.
- After a bag scan, **Post / Skip walks your whole inventory**.
- If what you'd **net after the cut** is below what a merchant pays, the action
  bar says so — or, if it's **worth more disenchanted**, says that instead.

### 🏪 Vendor list — some things aren't worth listing

**Vendor** on the Sell tab lists bag items worth **more at a merchant** than on
the AH after the cut, sorted by what you'd gain. Tick the ones you want gone,
and at any merchant **"Aegis: sell 6 marked"** sells the lot and logs the gold.

> Vendor prices are learned by hovering items at a merchant or putting them in
> the sell slot (or exactly, with ClassicAPI). What a merchant *charges* is read
> off its whole shelf when you open it.

### 📜 Auctions — mind the store, and your bids

**Your auctions above, your bids below.**

- **Your auctions:** time left, current bid, and **have I been undercut?** —
  green if you're still cheapest, red if not. Every column sorts. A line above
  reads *"at most 412g after the cut"*; bid-only auctions are counted
  separately, never guessed at.
- **Cancel all** carries the count (`Cancel all 47`) and always asks first.
- **Your bids:** what you're **winning** and what it has committed. An outbid row
  shows the price to beat, dimmed — 1.12 won't tell you what you bid.
- **No bids, no bottom half** — the table above gets the rows back.

### 🔨 Crafting — one shopping list for everything you're making

Open a profession, pick a recipe, **Add to Aegis**. Track as many as you like at
`[-] 5 [+]` each, and the tab merges them into **one shopping list** — two
recipes wanting Dreamfoil is one line for forty. It counts your bags and bank,
and a small `v` means a **vendor sells it cheaper**.

- **Click a reagent** to search for it; **Price all** searches everything you're
  short of so the total fills in (it buys nothing).
- **Expand a recipe** for what *it* needs at your quantity — five of something
  made in twos is three crafts, so six, not ten.
- **Something you can craft yourself** goes dim: its reagents are already listed.
- **Spent 41g 20s of 104g 30s** tracks the run as you buy.

> **mats 12g 40s → sells 18g** · **Profit 4g 71s** *(after the 5% cut)*

That profit line also appears **on the profession window itself**, live, and
works with the AH closed.

### 🛍️ The shopping list, anywhere

**`/aex shop`** opens the crafting list in a small movable window with no AH
needed, and it **pops up at a merchant** — half a reagent list is usually vendor
stuff. A bag button on the merchant frame toggles it and shows how many lines
are left.

- **Only what's left to buy**, alphabetical, with icons and quality colours.
- **Green count = vendor line, gold = auction line.** Hover for the price and
  which recipes want it.
- It closes when you leave — unless you opened it yourself. Turn the pop-up off
  on the Aegis tab.

### 📈 History — where did all the gold go?

**The chart gets the whole tab:** your **account's gold** over 24h, 7d, 30d, 3m
or all time. Tick one character, several, or *All Players*; hover the line for
what you held and when.

Underneath, **High · Low · Sold · Bought · Top Sale · Top Buy**, then three
blocks — **Sales**, **Expenses** and **Profit** — each with a total, a per-day
figure and the item that earned or cost the most (hover it for its tooltip).
*Top Sale* is your biggest single transaction; *Top item* is what actually
earns. They are rarely the same thing.

**Ledger** opens the full record over the window, with its own period buttons:

- **Items** — per item: **Sold · Avg Sell · Bought · Avg Buy · Avg Profit**,
  sortable, with a footer of what you resold and made.
- **Transactions** — every sale and purchase, with Income · Spent · Net.

Sales are logged **from your mailbox**, in any client language; purchases when
you buy. **Stack sizes are recorded both ways** — for sales, by matching the
mail against what you posted and what's still up. A sale that can't be counted
shows **`?`** (or `120 +2?`) rather than a guess, and an average only ever uses
money and units from the same sales.

Money reads in **gold, silver and copper**. About **three months** of gold
history fits in your saved variables.

> 1.12 only reports gold for the character you're on, so the account total is a
> sum of remembered figures — each as fresh as that character's last login.

### 🪟 Resize it, scale it, stack it

Drag the grip bottom-right and **every list re-fits** — taller means more rows,
not more blank space. **Window scale** (70–150%) is on the Aegis tab. Both are
remembered per character.

**Whatever you clicked last is in front** — bags, profession windows, the
merchant, bank and mail trade places with the Aegis window when you click them.

### 🔍 Aegis tab — scanning + settings

Full scan, category scan or bag scan; pause, resume or stop. A targeted scan
names the item it's fetching. Settings: post duration, undercut rule, default
sell price, window scale, tooltip lines, the profession profit line, pfUI
styling, confirm-before-cancel/post, the merchant pop-up, leftover handling,
auto-paging, and **scan pacing** (*Auto*, or *Safe 4s*).

### 💬 Tooltips everywhere

Bags, the auction house, merchants, mail, loot, quest rewards, profession
reagents and **items linked in chat** all gain the same block:

```
Seen 313 times at auction total

Aegis Buyout:                          7s 99c
Aegis Market:                          7s 99c
Sell to Vendor:                         3s 6c
Buy from Vendor:                       12s 0c

Crafting Cost:                         5s 40c

Class: Weapon
Disenchants Into (approx, from required level):
    80%  Lesser Magic Essence  x1.5
    20%  Strange Dust  x1.5

Disenchant (worth more than the AH):   10s 40c

Inventory                            39 total
    Torchlite                 20  (14 bags, 6 bank)
    Troglodyte                14  (2 bags, 8 bank, 4 ah)
```

- **Buyout above Market**: today's cheapest is what you act on; the median is
  context.
- **Crafting Cost** only appears when *every* reagent is priced — a partial
  total reads low, and low loses money.
- **The verdict** (*worth more than vendor / the AH / breaking it*) stays quiet
  when the two are within 10%.
- **Inventory is account-wide and per realm** — bags, bank, auctions and mail
  for every character, names in class colour. Alts appear once you've logged in
  on them.

Pick your lines on the Aegis tab; optionally show stack totals only with
**Shift** held.

<details>
<summary><b>How the disenchant line knows</b></summary>

**The table is the server's own.** Materials, chances and quantities come from
the 1.12.1 loot tables — every quality from green to epic, weapons and armour
separately, up to item level 95 (70 for rares). Shields and off-hand items break on the
*weapon* table, as they do in game.

**The one thing 1.12 hides is the item level**, so Aegis finds it, best first:

1. **You disenchanted one** — evidence from your own server outranks everything.
   A single dust leaves two or three possibilities, so it waits for a second
   break.
2. **[ClassicAPI](https://github.com/brues-code/ClassicAPI)** hands over the real
   number, Turtle's custom gear included.
3. **The level required to equip it, plus five** — always labelled
   *(approx, from required level)*, since it can land one band out.

The value is **per item**: a stack of twenty is twenty separate rolls. If a
material has no price yet the line names it — *no price yet for Large Glowing
Shard* — instead of going quiet.

</details>

---

## Using pfUI?

Aegis notices pfUI and **restyles itself to match** — borders, buttons,
checkboxes and scrollbars. Nothing to install; turn it off with **"Match pfUI's
look"** on the Aegis tab (needs a `/reload`). It's purely cosmetic and fully
guarded: if pfUI changes, the worst case is Aegis's default look.

<details>
<summary>Using <b>pfUI-addonskinner</b>?</summary>

You don't need it, but if you prefer it:

1. Copy `pfui/Aegis_Exchange.lua` to
   `Interface/AddOns/pfUI-addonskinner/skins/Aegis_Exchange.lua`
2. Add `skins\Aegis_Exchange.lua` to `pfUI-addonskinner.toc` under `# skins`
3. Restart the client

That file just calls Aegis's own skinning, so both paths stay identical.
</details>

---

## Install

1. Download this repo (**Code → Download ZIP**, or clone it).
2. Put the folder in `World of Warcraft/Interface/AddOns/`.
3. **Name it exactly `Aegis_Exchange`** — GitHub's ZIP unpacks as
   `Aegis_Exchange-main`, and the addon won't load under that name.
4. Restart the client and visit an auctioneer.

---

## Using it

| Do this | Get that |
|---|---|
| Talk to an auctioneer | The Aegis window opens |
| `/aex` or the **Blizzard UI** button | Hand the session back to the stock AH |
| `/aex shop` | The crafting shopping list, anywhere |
| `/aex flips` | What the last scan found **below vendor price** |
| `/aex demo` | Fill the chart, Ledger and Crafting tab with invented data to see them working. Nothing is saved; `/reload` clears it |
| `/aex diag <shift-click an item>` | Everything Aegis knows about that item, and how |
| `/aex cache` | How many items Aegis has learned from the client |
| `/aex debug` | Scanner trace, for when something looks wrong |

**Prices come from scanning.** A fresh install knows nothing — run a scan, or
just search (every search feeds the database) and the numbers fill in.

---

## A few honest notes

- **Deposits are labelled *approx*.** With an item in the sell slot the client's
  own figure is used; a bag preview applies a ratio measured from the slot and
  checked against real posts, so it improves as you play.
- **Turtle rules are built in:** durations ×3 (6h / 24h / 72h), a 120-auction
  cap, a 5% cut, and a **cross-faction** AH — one economy, one set of prices.
- **Scan speed is your client's, not ours.** Vanilla holds the query gate ~5s
  between pages; [AuctionQueryThrottle](https://github.com/brues-code/AuctionQueryThrottle)
  lifts it and Aegis speeds up by itself.
- **Sale counts start from when you updated.** Older sales keep their `?`, and
  if several stacks of one item are up at *different* sizes, the one that sold
  can't be told apart — so it isn't guessed.
- **Aegis needs nothing but the client.** Its only external call is ClassicAPI's
  `C_Item`, always guarded.

---

## Under the hood

```
Aegis_Exchange/
├── core/
│   ├── init.lua        namespace + event dispatcher
│   ├── util.lua        Lua 5.0-safe helpers (money, strings, tables)
│   ├── db.lua          price database, settings, ledger, vendor prices
│   ├── disenchant.lua  the disenchant rule, and what it learns from play
│   ├── scan.lua        page-by-page scanner state machine
│   ├── sell.lua        posting engine + owned auctions
│   └── buy.lua         search/buy engine + shopping lists + crafting
├── ui/
│   ├── frame.lua       the window and every tab
│   ├── skin.lua        optional pfUI restyling
│   └── tooltip.lua     price lines on item tooltips
├── art/                textures (the chart's gradient)
├── pfui/               drop-in skin for pfUI-addonskinner (not loaded by Aegis)
├── tests/              lint + unit suites + the sabotage layer (never shipped)
├── tools/              build-time generators (never shipped)
└── design/             mockups (reference only — never loaded)
```

**Market value** is a time-weighted median of each item's daily minimum buyout
over 30 days — today counts fully, a week ago about a third. One absurd listing
moves a median by nothing; a real price shift shows within about five days.

Everything is **Lua 5.0 and 1.12 API only**. `./tests/run.sh` checks the
language rules, the 32-upvalue ceiling and the unit suites; `--sabotage` plants
real bugs in a throwaway copy and requires the suites to catch every one.
[`CLAUDE.md`](CLAUDE.md) has the rules and the reasons, most learned the hard way.

---

## Something broken?

1. Check the **version** in the window's title bar (`v1.54.15`) — quote it.
2. **`/aex diag <shift-click an item>`** prints everything Aegis knows about that
   item and every step it took. If a tooltip line is missing, it says why.
3. `/aex debug` turns on a scanner trace if a scan misbehaves.
4. Tell us on **[Discord](https://discord.gg/hsgPTNkSX)** or open an
   [issue](https://github.com/Torchlite-bit/Aegis_Exchange/issues). Screenshots
   help enormously, especially for layout.

Recent changes are in [CHANGELOG.md](CHANGELOG.md).

---

## Contributing

PRs welcome — say hi on **[Discord](https://discord.gg/hsgPTNkSX)** first if
you're planning something big.

1. Stay inside the 1.12 / Lua 5.0 rules in [`CLAUDE.md`](CLAUDE.md) — breaking
   them fails at *runtime*, not at load.
2. Bump the version in all **five** places: `core/init.lua` (`A.version`), the
   `.toc`, this file's **H1**, its "Check the version" line, and a
   [`CHANGELOG.md`](CHANGELOG.md) entry with its link. `python3
   tests/lint/version.py` checks they agree.
3. **Patch** for a fix, wording, colour or layout; **minor** for something the
   addon couldn't do before; major only for a change that breaks an existing
   setup with no migration.

## Credits

The disenchant table is derived from the **[CMaNGOS Classic-DB](https://github.com/cmangos/classic-db)**
1.12.1 loot tables. No Classic-DB file is included — only probabilities computed
from it. Earlier versions derived it from the community-harvested observations
in **Enchantrix** (Norganna & contributors), which agree with it everywhere they
overlap.

Item levels were shipped from **[ShaguScore](https://github.com/shagu/ShaguScore)**
by **shagu** in v1.31.0–v1.40.0, before ClassicAPI could provide the client's
own — with thanks for the years it covered the gap.

## License

MIT — see [LICENSE](LICENSE).

---

<div align="center">

**[💬 Discord](https://discord.gg/hsgPTNkSX)** · **[📜 Changelog](CHANGELOG.md)** · **[🐛 Issues](https://github.com/Torchlite-bit/Aegis_Exchange/issues)**

*Aegis: Exchange is part of the Aegis addon series. Happy flipping.* ⚔️

</div>
