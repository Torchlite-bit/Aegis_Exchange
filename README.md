# Aegis: Exchange (v1.53.16)

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

- [What it does](#what-it-does) — the six tabs
- [Using pfUI?](#using-pfui)
- [Install](#install) · [Using it](#using-it)
- [A few honest notes](#a-few-honest-notes)
- [Under the hood](#under-the-hood)
- [Something broken?](#something-broken) · [Contributing](#contributing)

---

## What it does

### 🛒 Buy — shop like you mean it

**Results group by item.** Search something broad and you get **one row per
item** — its name, how many auctions there are, and the lowest price you can
actually pay — instead of forty rows of Mana Potion.

- **Left-click** a row to open it and see the individual auctions underneath,
  each with its seller, stack, time left and price. That's a repaint, not
  another search — the listings are already in hand.
- **Right-click** to search that item alone. A real query, so you get *all* of
  it, not a filter over the page you have. Works on a child row too.
- A group of one never opens. There's nothing under it but the row you're
  looking at.

Two columns are the reason to be here: **Unit** (price per item, so a stack of
20 is comparable to a stack of 1) and **% Mkt** (how this price compares to
market value). Colour-coded so bargains jump out — **green is under market, red
is over** — and names are quality-coloured the way their tooltips are.

**It opens looking like the auction house you already know:** Name, Level
Range, Min Quality, Usable items, the category list down the left, your gold
with Bid / Buyout / Close along the bottom. Click a row, then bid or buy.

**Advanced**, top right, swaps in a full query box and three views — **Results**,
**Saved** and **Builder**. *Saved* keeps every search you've run plus a
favourites column you order yourself. *Builder* is the same thing as a form:
pick a component, type a value, press Enter, and the clause joins the list.
Stacked clauses all have to hold; put **`or`** between two to widen, **`not`**
before one to exclude. Switching carries your search both ways.

**Shortcuts while Buy is open:** **right-click** any bag item to search for it,
**shift-click** any item anywhere — bags, chat link, tooltip — to drop its name
in the box, and **Tab** to autocomplete from everything Aegis has ever seen.
Everywhere else Tab moves to the next field and Shift-Tab back.

<details>
<summary><b>The search language</b> — optional, and typing a plain name still just searches for that name</summary>

| Type this | Get that |
|---|---|
| `linen cloth` | exactly what it always did |
| `[Linen Cloth]` or `linen cloth/exact` | only *Linen Cloth*, not *Bolt of Linen Cloth* |
| `armor/leather` | the whole Leather Armor category |
| `armor/plate/chest` | plate chest pieces |
| `belt/quality3` or `belt/quality/rare` | rare-quality belts |
| `sword/level20-30` | swords for levels 20–30 |
| `runecloth/buyout` | skip bid-only auctions |
| `mageweave/stack 20` | stacks of exactly 20 |
| `mageweave/stack` | the biggest stacks |
| `container/bag/tooltip/8` | bags whose tooltip mentions **8** |
| `wristbands/tooltip/+3 stam/+3 agi` | BOTH stats on one item |
| `wristbands/tooltip/+3 stam/or/tooltip/+3 agi` | either stat |
| `boots/not/tooltip/soulbound` | excludes what the clause matches |
| `silk cloth/max-unit-buy/5g` | at or under 5g **per item** |
| `sword/min-level/40/max-level/50` | required level 40–50 |
| `bracers/rarity/rare` | rares **only** — not the epics above them |
| `linen/seller/Bob` | posted by anyone whose name contains *Bob* |
| `linen/left/short` | about to expire |
| `linen/percent/70` | at or under **70% of market** |
| `linen/vendor-profit/50s` | vendor pays 50s **more** than it costs |
| `wristbands/disenchant-profit/1g` | worth **1g more** broken than bought |
| `wristbands/disenchant-percent/70` | costs at most **70%** of what it breaks into |
| `linen;wool;silk` | all three, browsed as one list |

Terms combine with `/`. `;` runs several searches back to back — page past the
end of one and it rolls into the next.

**Categories are the game's own names**, in your own language. Class first, then
subclass, then slot: `armor/leather` works, `leather/armor` treats "leather" as
a name. Close is good enough — `weapon/dagger` finds "Daggers" — but a word
matching *several* categories (`weapon/sword` hits both One-Handed and Two-Handed)
stays a name search rather than guessing.

**`stack 20` is the reliable form** — it compares each listing's own count, so
it needs no item data and works on the first search. Bare **`stack`** means
"full stacks", which needs the item's *maximum* size, and vanilla only reports
that for items your client has cached; Aegis remembers every maximum it learns
and otherwise falls back to the biggest stack on the page, saying so. Want a
guarantee, give the number.

**`tooltip` doesn't need repeating.** Each following term is another thing the
tooltip must say. The run ends when a word means something else to the search —
`cloak/tooltip/stamina/exact` still applies *exact* — so say `tooltip` again if
what you're after is one of those words.

**`rarity` means exactly that quality** (Min Quality already gives you "rare and
better"), and **`left` is a bound**, so `left/medium/not/left/short` is exactly
medium.

**`percent` is the deal filter, `vendor-profit` the flipper's, and
`disenchant-profit` / `disenchant-percent` the enchanter's.** Disenchant figures
are **per item**, because each break rolls the table again.

Some of these can't always answer, and they say so instead of quietly returning
nothing — rows a filter couldn't judge are **counted and named in the status
line, with the fix that works**: `3 skipped (no vendor-profit data — vendor
prices are learned at a merchant)`.

</details>

### 💰 Sell — price it right the first time

**Your Bags** lists everything you can post, categorised and quality-coloured.
Click one, and Aegis scans the AH for *just that item*, shows every competing
listing, and pre-fills your price — **Undercut** by a percentage or a flat
amount (yes, 1 copper works) or **Price match** to sit level with the cheapest.
Click any competitor's row to steal their price.

A header band carries the four figures that matter: **Total**, **Deposit**,
**After cut** (what actually lands in your mailbox after the 5% consignment cut)
and **Listings** against the 120-auction cap.

- **Post multiple stacks at once** — "3 stacks of 20" — on interlocking sliders.
- **Stacks can't be merged** on 1.12, so thirty essence held as three stacks of
  ten caps the slider at ten. **Max** fills in every stack of that size you can
  actually assemble.
- **Leftovers stay ready.** Post two stacks of ten out of twenty-five and the
  last five come back into the slot at the same price.
- **After a bag scan, Post / Skip walks your whole inventory** without clicking
  back and forth.
- If your price drops below what a merchant would pay, the action bar says so —
  and if the item is **worth more disenchanted**, it says that instead, because
  that's the larger mistake.

### 🏪 Vendor list — some things just aren't worth listing

Hit **Vendor** on the Sell tab for the bag items worth **more at a merchant**
than on the AH — vendor price against the best AH price *after the cut* — sorted
by what you'd gain:

| Item | Qty | Vendor (ea) | AH net (ea) | You gain |
|---|---|---|---|---|
| Tough Jerky | x5 | 25c | 9c | +80c |

**Tick the ones you want gone** (or *Mark all*). At any merchant an Aegis button
appears — **"Aegis: sell 6 marked"** — which confirms, sells the lot, and logs
the gold to your History.

> Vendor prices are learned by **hovering items at a merchant** (1.12 exposes
> them no other way), so this fills in as you play. What a merchant *charges* is
> easier: opening any vendor reads its whole shelf in one pass.

### 📜 Auctions — mind the store, and your bids

**Your auctions above, your bids below.** A bid is an outgoing commitment
exactly the way a posted auction is an incoming one, and both are decided by the
same clock.

**Your auctions:** time left, current bid, and the thing you actually care
about — **have I been undercut?** Green means you're still cheapest, red means
someone slid under you; cancel with one click. Every column sorts, so clicking
**vs market** brings the worst news to the top. A line above it reads **"at most
412g after the cut"** — what the page would pay if everything sold at buyout.
Bid-only auctions can't be guessed at, so they're **counted and named
separately**, never averaged in.

**Your bids:** what you've bid on, what you're **winning**, and what that has
committed — same sorting, tooltips and row chrome as the half above. *Committed*
counts only what you're winning, and that figure is exact: 1.12 takes the gold
when you bid and mails it back the moment someone beats you, so an outbid row is
money you already have. An outbid row shows the **price to beat**, dimmed —
never a number presented as yours, because 1.12 won't tell you what you bid.

Both halves page at **50** (`<` / `>`, top right) because that's how the client
hands them over, and cancelling works on an index into the page it's holding.
The trade is that undercut counts are per page, and the status line says so.
**No bids, no half** — the bottom collapses and gives every row back to the
table above.

### 🔨 Crafting — one shopping list for everything you're making

Open a profession, pick a recipe, hit **Add to Aegis**. Track as many as you
like, set how many of each with `[-] 5 [+]`, and the tab turns the lot into
**one shopping list**:

> **Dreamfoil** &nbsp; `18/40` &nbsp;&nbsp; **Gromsblood** &nbsp; `12/42`
> &nbsp;&nbsp; **Crystal Vial** &nbsp; `22/28` ᵛ

Two recipes wanting Dreamfoil is **one line for forty**, not two lines you shop
for twice. It counts what's in your bags and bank, and a small `v` means a
**vendor sells it cheaper**.

- **Click a reagent** to search for it — a real auction query.
- **Price all** walks the whole list, searching everything you're short of so
  the total fills in. It buys nothing. Press again to stop.
- **Expand a recipe** to see what *it* needs at the quantity you asked. Wanting
  five of something made in twos is three crafts, so it says six — not ten.
- **Something you can craft yourself** goes dim instead of red: its own reagents
  are already further down the list.
- **Spent 41g 20s of 104g 30s** tracks the run as you buy.

**The list follows you to the vendor.** `/aex shop` opens it anywhere, and it
pops up by itself at a **merchant** — which is where half a reagent list
actually gets bought. A **bag button on the merchant window** toggles it, with a
badge for how many lines are left. Only what's **still to buy**, alphabetical,
with item icons and quality colours; a green count means buy it from the
merchant, gold means the auction house. It closes when you leave — unless you
opened it yourself.

And it still does the maths you were doing in your head:

> **mats 12g 40s → sells 18g** · **Profit 4g 71s** *(after the 5% cut)*

That profit line shows up **on the profession window itself**, live, as you
click through recipes. It reads saved prices, so it works with the AH closed.

### 📈 History — where did all the gold go?

**The ledger on the left, your gold over time on the right.**

Sales are logged **straight from your mailbox** — open your mail and Aegis
records every "Auction successful". Purchases are logged when you buy. Then it
tells you **Income · Spent · Net** over 24h, 7d, 30d, 3m or all time, sortable
by when, type, item or amount.

The chart plots **gold held, for your whole account**. Tick one character, tick
several to see what they hold together, or *All Players*. **Hover the line** for
what you were carrying at that point and when. **HIGH / LOW** of the line and
**IN / OUT / NET** for the period sit underneath, from the same totals the table
uses — so the two halves can't disagree.

Roughly **three months of history** fits in the same saved variables: samples
start hourly and compact to one a day once they age past four days.

> 1.12 has one money call and it answers for the character you're on, so an
> account total is necessarily a sum of remembered figures — each as fresh as
> the last time that character played, and the chart says so. Your own figure is
> always live.

### 🪟 Resize it — or scale it

Drag the grip in the bottom-right and **every** list re-fits, so a taller window
shows more rows rather than more blank space. Vanilla frames never reflow, so
for *bigger* there's a **window scale** (70%–150%) on the Aegis tab. Both are
remembered per character.

### 🔍 Aegis tab — scanning + settings

Run a full scan, a category-targeted scan, or scan your bags to price them.
Pause, resume or stop whenever. Plus your defaults: post duration, undercut rule,
auto-fill price, window scale, tooltip lines, profit line, whether the shopping
list pops up at a merchant, and the pfUI skin.

### 💬 Tooltips everywhere

Bags, inventory, the auction house, merchants, the mailbox, **loot windows,
quest rewards and profession reagents** — all gain the same block:

```
Seen 313 times at auction total

Aegis Buyout:                          7s 99c
Aegis Market:                          7s 99c
Sell to Vendor:                         3s 6c
Buy from Vendor:                       12s 0c

Crafting Cost:                         5s 40c

You have: 14  (bags 6 · bank 8)
Alts: Torchlite 20 · Troglodyte 5

Disenchants Into (approx, from required level):
    81%  Lesser Magic Essence  x1.5
    19%  Strange Dust  x1.5

Disenchant (worth more than the AH):   10s 40c
```

Every number carries what qualifies it. The **sighting count** leads, because
it's context for everything below. **Buyout** sits above **Market** — today's
cheapest is what you act on, the median is the context. **Sell to Vendor** and
**Buy from Vendor** sit together because they're opposite sides of the same NPC,
and a vendor whose stock was finite reads *Buy from Vendor (limited)*.

**How many you have** counts bags, bank, auctions and mail — **across your whole
account**, not just the character you're on. Alts are recorded the first time
you log in on them.

**Crafting Cost** appears when a recipe you've opened makes the item, priced per
unit. It stays quiet unless *every* reagent is priced: a partial total reads
low, and low is the direction that loses money.

**The verdict** — *worth more than vendor*, *worth more than the AH*, or *sells
for more than it breaks for* — is the comparison that made you hover. It stays
silent when the two are within 10%.

Pick which lines you want on the Aegis tab, and optionally show stack totals
only while **Shift** is held.

<details>
<summary><b>How the disenchant line knows</b></summary>

Item level is the one input the calculation needs, and the 1.12 client gives
addons no way to read it. Aegis has three sources, best first:

1. **You disenchanted one.** Evidence from the server you actually play on, so
   it outranks everything else. It won't guess from a single result: an essence
   pins an item down, a dust leaves two or three possibilities, so it keeps
   quiet until a second break settles it.
2. **[ClassicAPI](https://github.com/brues-code/ClassicAPI)** — a DLL, not an
   addon. 1.12 stores an item level on every item and shows it nowhere;
   ClassicAPI hands over the real number, Turtle's custom gear included.
3. **The level required to equip it**, plus five. Approximate, and **always
   labelled** *(approx, from required level)* — required level moves in steps of
   five where item level does not, so an item near a boundary can land one band
   out. This is what answers with no DLL at all.

When the rule can answer but the market can't, the line says which material is
missing — *no price yet for Large Glowing Shard* — instead of going quiet.

The value shown is for **one** item: a stack of twenty is twenty separate rolls.
The numbers behind it come from **8.8 million observed disenchants**, not typed
by hand; epics and anything above item level 65 are deliberately left unanswered
because the data there isn't good enough to trust. See `tools/README.md`.

ClassicAPI does the same for **vendor prices**. Without it they're still learned
two ways that cost you nothing: hovering an item at a merchant, and **putting one
in the sell slot** — every item you post teaches Aegis its exact vendor price.

</details>

---

## Using pfUI?

Aegis notices pfUI and **restyles itself to match** — borders, buttons,
checkboxes and scrollbars. Nothing to install. Turn it off with **"Match pfUI's
look"** on the Aegis tab (takes a `/reload`).

The skinning is purely cosmetic and fully guarded: if pfUI changes its API, the
worst case is that Aegis keeps its default look. It never affects behaviour.

<details>
<summary>Using <b>pfUI-addonskinner</b>?</summary>

Aegis skins itself, so you don't need this. But if you prefer managing every
skin through [pfUI-addonskinner](https://github.com/mrrosh/pfUI-addonskinner):

1. Copy `pfui/Aegis_Exchange.lua` from this repo to
   `Interface/AddOns/pfUI-addonskinner/skins/Aegis_Exchange.lua`
2. Add `skins\Aegis_Exchange.lua` to `pfUI-addonskinner.toc` under `# skins`
3. Restart the client

That file just calls Aegis's own skinning routine, so both paths stay identical.
</details>

---

## Install

1. Download this repo (**Code → Download ZIP**, or clone it).
2. Drop the folder into `World of Warcraft/Interface/AddOns/Aegis_Exchange`.
3. **The folder must be named exactly `Aegis_Exchange`** — GitHub's ZIP unpacks
   as `Aegis_Exchange-main`, so rename it or the addon won't load.
4. Restart the client, then visit an auctioneer.

---

## Using it

| Do this | Get that |
|---|---|
| Talk to an auctioneer | The Aegis window opens automatically |
| `/aex` | Hand the session back to the stock Blizzard AH |
| **Blizzard UI** / **Aegis UI** buttons | The same swap, with a mouse |
| `/aex shop` | The crafting shopping list, anywhere — no AH needed |
| `/aex demo` | Fill the gold chart and Crafting tab with invented data, to see what they look like with a real history. Nothing is saved; `/reload` clears it |
| `/aex diag <shift-click an item>` | Everything Aegis knows about that item, and how it knows it |
| `/aex cache` | How many items Aegis has learned from the client |
| `/aex debug` | Verbose scanner trace, for when something looks wrong |

**Prices come from scanning.** A fresh install knows nothing — run a scan, or
just search for things (ordinary searches feed the database too) and the market
numbers, % colours and profit estimates fill in as you go.

---

## A few honest notes

- **Deposits are approximate, and labelled *approx*.** Where an item is in the
  sell slot the client's own figure is used as-is. For a bag preview, which
  can't reach that figure, Aegis applies a ratio it measured from the slot — and
  separately compares what the client quoted against the gold that actually left
  your bags on a real post, so the number improves as you use it. Never treat it
  as exact.
- **Turtle specifics are baked in:** durations are ×3 (6h / 24h / 72h), a
  120-auction account cap, a 5% cut on sales, and the auction house is
  **cross-faction** — one shared economy, so prices aren't split by side.
- **Scanning is paced by your client, not by us.** Aegis waits on the client's
  own `CanSendAuctionQuery()` gate, which vanilla keeps shut ~5s after every
  query. A full scan takes a while; that's the protocol, not the addon.
  [AuctionQueryThrottle](https://github.com/brues-code/AuctionQueryThrottle)
  clears that timer and Aegis speeds up on its own — and **Safe 4s** pacing is
  there if you ever want the old fixed floor back.
- **Mail sale-tracking is enUS-only** right now (it matches "Auction
  successful:").
- **Aegis needs nothing but the client.** The only external thing it calls is
  ClassicAPI's `C_Item`, for exact item levels and vendor prices, and every call
  is guarded — without it those are estimated and labelled. No SuperWoW,
  Nampower or UnitXP_SP3 calls anywhere in the source.

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

Market value is a **time-weighted median** of each item's daily minimum buyout
over the last **30 days**, weighted so today counts fully, a week ago about a
third, and a month ago barely at all. One weird lowball can't wreck your numbers
— it's a median, so a single absurd listing moves it by nothing — while a
genuine price shift is tracked within about five days.

Everything is **Lua 5.0 and 1.12 API only** — no `string.match`, no `#`, no `%`
operator, no secure hooks. `./tests/run.sh` checks the language rules, the
32-upvalue ceiling and the unit suites; `--sabotage` additionally plants real
bugs in a throwaway copy and requires the suites to catch them.
[`CLAUDE.md`](CLAUDE.md) has the full rules and the reasons behind them, most of
which were learned the hard way.

---

## Something broken?

1. Check the **version** in the window's title bar (`v1.53.16`) — quote it.
2. **`/aex diag <shift-click an item>`** prints everything Aegis knows about
   that item and every step it took: which modules loaded, what the client
   returned, the item level and where it came from, and the disenchant value.
   If a tooltip line is missing, this says why in one line. It found three
   separate bugs that screenshots could not.
3. **`/aex cache`** reports how many items Aegis has learned from the client.
4. `/aex debug` turns on a scanner trace if a scan is misbehaving.
5. Tell us on **[Discord](https://discord.gg/hsgPTNkSX)** or open an
   [issue](https://github.com/Torchlite-bit/Aegis_Exchange/issues). Screenshots
   help enormously, especially for anything layout-related.

Recent changes are in [CHANGELOG.md](CHANGELOG.md).

---

## Contributing

PRs welcome — come say hi on **[Discord](https://discord.gg/hsgPTNkSX)** first
if you're planning something big.

Three requests:

1. Keep inside the 1.12 / Lua 5.0 rules in [`CLAUDE.md`](CLAUDE.md) — they're
   there because breaking them fails at *runtime*, not at load.
2. Bump the version. It is written in **five** places and they must agree, or
   the number in the title bar stops matching the release: `core/init.lua`
   (`A.version`), the `.toc` (`## Version:`), this file's **H1**, this file's
   "Check the version" line under *Something broken?*, and a
   [`CHANGELOG.md`](CHANGELOG.md) entry with its link reference at the bottom.
   `python3 tests/lint/version.py` checks all five agree.
3. Which number: **patch** for a fix, wording, colour or layout; **minor** for
   a capability the addon did not have before (and reset patch); major only for
   a change that breaks an existing setup with no migration.

## Credits

Item levels were shipped from **[ShaguScore](https://github.com/shagu/ShaguScore)**
by **shagu** in v1.31.0–v1.40.0, when 1.12 gave addons no way to get one.
ClassicAPI now provides the client's own, so that table has been removed —
with thanks for the years it covered the gap.

The disenchant probabilities are derived from the community-harvested
observations in **Enchantrix** (Norganna & contributors); no Enchantrix code
or data file is included here, only statistics computed from it.

## License

MIT — see [LICENSE](LICENSE).

---

<div align="center">

**[💬 Discord](https://discord.gg/hsgPTNkSX)** · **[📜 Changelog](CHANGELOG.md)** · **[🐛 Issues](https://github.com/Torchlite-bit/Aegis_Exchange/issues)**

*Aegis: Exchange is part of the Aegis addon series. Happy flipping.* ⚔️

</div>
