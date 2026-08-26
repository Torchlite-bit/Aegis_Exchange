# Aegis: Exchange (v1.50.1)

**A clean, fast auction house for vanilla WoW (1.12).**

[![Discord](https://img.shields.io/badge/Discord-join%20us-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/hsgPTNkSX)
[![Raven WoW](https://img.shields.io/badge/Raven%20WoW-1.18.1-1e1e1e?style=flat-square&labelColor=555)](https://ravencraft.io/)
[![Octo WoW](https://img.shields.io/badge/Octo%20WoW-1.18.1-8A2BE2?style=flat-square&labelColor=555)](https://octowow.st/)
[![Capy WoW](https://img.shields.io/badge/Capy%20WoW-1.18.1-8B5A2B?style=flat-square&labelColor=555)](https://capycraft.io/)

[![ClassicAPI](https://img.shields.io/badge/ClassicAPI-Recommended-3fb950?style=flat-square&labelColor=555)](https://github.com/brues-code/ClassicAPI)
[![AuctionQueryThrottle](https://img.shields.io/badge/AuctionQueryThrottle-Highly%20Recommended-ff8c00?style=flat-square&labelColor=555)](https://github.com/brues-code/AuctionQueryThrottle)

<sub>**Aegis runs on a stock client.** Two optional DLLs make it better, and
neither is required: **AuctionQueryThrottle** makes scans much faster, and
**ClassicAPI** gives exact item levels and vendor prices — without it, disenchant
values are estimated from the level needed to equip an item and are labelled
*(approx)*.
</sub>

The stock 1.12 auction house is three text boxes and a prayer. Aegis replaces it
with a window that actually knows what things are worth — what you should charge,
what you should pay, whether that recipe is worth crafting, and how much gold you
made this week.

> Built for **1.18.1** servers (Octo WoW, Capy WoW, Turtle WoW), which run the
> original **WoW 1.12 (vanilla)** client on **Lua 5.0**. Not Classic. Not retail.
> Real vanilla.

> ### ⚡ Scans fastest with AuctionQueryThrottle
> Vanilla makes the client sit out ~5 seconds between auction queries.
> **[AuctionQueryThrottle](https://github.com/brues-code/AuctionQueryThrottle)**
> clears that timer the moment the server replies, and Aegis picks the change up
> **automatically** — nothing to configure.
>
> How much you gain depends on the realm, because what's left is the server's own
> response time: **Octo WoW** is dramatically faster, while **Capy WoW** lands at
> roughly **2×**. The Aegis tab tells you which you're getting
> (`fast — gate 0.02s, server 0.61s`).
>
> It's a DLL, not an addon, and it needs the VanillaFixes loader.

**[💬 Join the Discord](https://discord.gg/hsgPTNkSX)** for help, bug reports,
and feature ideas.

---

## Contents

- [What it does](#what-it-does) — the six tabs
- [Using pfUI?](#using-pfui)
- [Install](#install)
- [Using it](#using-it)
- [A few honest notes](#a-few-honest-notes)
- [Under the hood](#under-the-hood)
- [Contributing](#contributing)

---

## What it does

### 🛒 Buy — shop like you mean it
Search the AH, sort by unit price, stack price, or % of market value, and buy or
bid straight from the results. Colour-coded so bargains jump out: **green is
under market, red is over.**

**Typing a name still just searches for that name** — nothing you already do
changes. But the same box now takes a query language when you want one:

| Type this | Get that |
|---|---|
| `linen cloth` | exactly what it always did |
| `linen cloth/exact` | only *Linen Cloth*, not *Bolt of Linen Cloth* |
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

**Categories are the game's own names** — whatever the auction house's own
dropdowns say, in your own language. Class first, then subclass, then slot:
`armor/leather` works, `leather/armor` treats "leather" as a name. You don't
have to match them exactly — `weapon/dagger` finds the "Daggers" category —
but a word matching *several* categories (`weapon/sword` hits both One-Handed
and Two-Handed Swords) is left as a name search rather than guessing.

**`stack 20` is the reliable form** — it just compares each listing's own
count, so it needs no item data and works on the first search for any item.
`stack 8`, `stack 1`, whatever you want. All three spellings work:
`stack 20`, `stack/20`, `stack20`.

Bare **`stack`** means "full stacks", which needs the item's *maximum* size —
and vanilla only reports that for items your client has already cached. Aegis
remembers every maximum it learns, and when it still doesn't know one it falls
back to the biggest stack of that item on the page, saying so in the status
line. If you want a guarantee rather than a best guess, give the number.

**`tooltip` doesn't need repeating.** Keep listing what you're after and each
one is another thing the tooltip must say: `wristbands/tooltip/+3 stam/+3 agi`
wants both. The run ends the moment a word means something else to the search —
`cloak/tooltip/stamina/exact` still applies *exact* — so if what you're looking
*for* is one of those words, say `tooltip` again:
`tooltip/Stamina/tooltip/Weapon` searches tooltips for **Weapon**, while
`tooltip/Stamina/Weapon` searches the Weapon *category*.

**`rarity` means exactly that quality, and `left` means "at most this long".**
The **Min Quality** dropdown already gives you "rare *and better*", so
`rarity/rare` is the other thing — rares and nothing else. `left/short` is
what's about to expire, `left/long` is everything except the freshly posted;
and because it's a bound it still composes, so `left/medium/not/left/short` is
exactly medium.

**`percent` is the deal filter and `vendor-profit` is the flipper's.**
`percent/70` is "a third under the going rate or better", measured against
what Aegis has actually seen the item sell for. `vendor-profit/50s` finds what
you can buy and sell straight to a merchant for 50s more per item.

**`disenchant-profit` and `disenchant-percent` are the enchanter's.**
`disenchant-profit/1g` finds gear worth at least a gold more in mats than it
costs; `disenchant-percent/70` is the same question as a ratio. Both are per
item, because each disenchant rolls the table again — a stack of five is five
separate breaks, not five times one number.

Some of these can't always answer, and they say so rather than quietly
returning nothing. The seller's name arrives a moment after the page does,
some servers don't report time left, market value needs a scan, a vendor
price is only learned by standing at a merchant, and a disenchant value needs
both the item's level and its materials' prices. Rows a filter can't judge are
**counted and named in the status line, with the fix that actually works** —
`3 skipped (no vendor-profit data — vendor prices are learned at a merchant)`.

A **bid-only** auction isn't in that count. It has no buyout because the
seller didn't set one; that's on the row for you to see, not something a
rescan would fix.

Terms combine with `/`, and `;` runs several searches back to back — page past
the end of one and it rolls straight into the next.

Result names are **coloured by item quality**, the way their tooltips are, so
a rare reads blue and an epic purple at a glance. An item you can't use gets a
red-tinted icon.

**None of that is required.** The Buy tab opens looking and working like the
auction house you already know: **Name**, **Level Range**, **Min Quality**,
**Usable items**, **Search**, the category list down the left, and your gold
with **Bid** / **Buyout** / **Close** along the bottom. Click a row to select
it, then bid or buy from the bottom bar — same as the stock window. The
category list expands the way Blizzard's does (**Armor › Leather › Chest**),
and the Name field searches *within* whatever you've picked.

Two extra columns are the reason to be here at all: **Unit** (price per item,
so a stack of 20 is comparable to a stack of 1) and **% Mkt** (how this price
compares to market value — green under, red over).

The one addition to that layout is **Advanced**, top right. It swaps in the
full query box and three views — **Results**, **Saved**, and **Builder**.
**< Back** returns to the simple view.

**Saved** is two columns. *Recent* is every search you've run; **right-click**
one and it jumps straight into *Favorites*. Right-click a favorite for **Move
Up / Move Down / Delete** — the order is yours and nothing re-sorts it.
Left-click either column to run it; **shift**-left-click loads it into the
Builder instead so you can adjust it first.

**Builder** is the form: name, level range, class, subclass, slot, quality on
the left, and the **Post Filter** on the right. Pick a component, type a
value, press **Enter**, and the clause is added to the list:

```
tooltip: +3 stamina
tooltip: +3 agi
max-unit-buy: 5g
```

**Stacked clauses all have to hold** — that's one item carrying both stats,
under 5g, and you didn't type a single operator to say so. Put **`or`**
between two clauses to widen instead, or **`not`** before one to exclude it.
Click any line to remove it. **Search** runs it, **Build** pushes it into the
search box, **+ OR** appends it as another `;` term, **Import** pulls whatever
is in the search box back into the form, and **Clear** empties both.

**Stat names work either way round.** Type `agi` or `Agility`, `stam` or
`Stamina`, `str`, `int`, `spi` — Aegis looks for both spellings, and the
Post Filter shows you which other form it will match so you can see it landed
before spending a scan on it.

Switching carries your search with you in both directions, so you can start
simple, hit Advanced to add something the plain view can't express, and come
back. Anything that *only* exists in Advanced (a tooltip filter, say) is left
behind on the way back — and the status line says so rather than quietly
narrowing your results.

**Shortcuts while the Buy tab is open:** **right-click** any bag item to search
for it, or **shift-click** any item *anywhere* — bags, a chat link, a tooltip —
to drop its name in the box and go. **Tab** completes what you've typed from
every item Aegis has ever seen, pressing it again to cycle through the matches.

**Everywhere else, Tab moves to the next box** and **Shift-Tab** back — down
the Sell tab's stack size, count and price fields, through the Builder's form,
across the gold / silver / copper triplets a coin at a time. Boxes the current
mode has hidden are stepped over. The two search boxes are the one exception:
they keep autocomplete, which is worth more on a search box than stepping to
the level fields.

### 💰 Sell — price it right the first time
**Your Bags** lists what you can post — one line per item showing everything
you hold, categorised, quality-coloured, click to load it. Drop an item in and
Aegis scans the AH for *just that item*, shows you every competing listing, and
pre-fills your price.

One caveat vanilla forces on everyone: **stacks can't be merged**. Thirty
essence held as three stacks of ten is thirty items, but the biggest stack you
can post is ten — so the size slider stops there and the header still tells you
the total. **Max** fills in every stack of the chosen size you can actually
assemble.

**Leftovers stay ready.** Post two stacks of ten out of twenty-five and the
remaining five come straight back into the slot at the same price, so the
small stack goes out without hunting for it in your bags again. Turn it off on
the Aegis tab if you'd rather pick the next item yourself. Two columns: on the left *what
you're posting* — stack size and stack count on interlocking sliders, duration
underneath; on the right *for how much* — **Undercut** (by a percentage or a
flat amount; yes, 1 copper works) or **Price match** to sit level with the
cheapest seller, above bid and buyout in gold / silver / copper.

A header band across the top carries the four figures that matter as labelled
columns — **Total**, **Deposit**, **After cut** (what actually lands in your
mailbox once the 5% consignment cut is taken) and **Listings** against the
120-auction cap. Post **multiple stacks at once** — "3 stacks of 20". Click any
competitor's row to steal their price. If your price ever drops below what a
merchant would pay, the action bar says so — and if the item is **worth more
disenchanted** than sold, it says that instead, because that is the larger
mistake. That warning is deliberately hard to trigger: it needs an *exact* item
level (one you learned by disenchanting, or one ClassicAPI supplied — never the
approximation) and a 25% margin, because it is recommending something you cannot
undo. And after a **bag scan**, Aegis loads the
first item into the sell slot and walks you down the list — **Post** or **Skip**
moves to the next one, so you can clear a full bag without clicking back and
forth.

### 🏪 Vendor list — some things just aren't worth listing
Not everything belongs on the auction house. Hit **Vendor** on the Sell tab and
Aegis shows the bag items worth **more at a merchant** than on the AH — comparing
the vendor price against the best AH price *after the 5% cut* — sorted by what
you'd actually gain:

| Item | Qty | Vendor (ea) | AH net (ea) | You gain |
|---|---|---|---|---|
| Tough Jerky | x5 | 25c | 9c | +80c |

**Tick the ones you want gone** (or *Mark all*). Then at any merchant, an Aegis
button appears on the vendor window — **"Aegis: sell 6 marked"** — which confirms
what's about to go, sells the lot, and logs the gold to your History.

> Vendor prices are learned by **hovering items at a merchant** (1.12's API
> doesn't expose them otherwise), so this list fills in as you play. What a
> merchant *charges* is easier: opening any vendor reads its whole shelf in one
> pass, so that side fills in just by walking past.

### 📜 Auctions — mind the store
Every auction you have out, with time left, current bid, and the thing you
actually care about: **have I been undercut?** Green means you're still the
cheapest. Red means someone slid under you. Cancel anything with one click.

Every column sorts — click **vs market** and the auctions you've been undercut
hardest on come to the top.

The client hands out your auctions **50 at a time**, so a full book (Turtle caps
you at 120) needs paging — use **`<` / `>`** at the top right. The header counts
what you *own*, not what the page shows. It pages rather than gathering them all
into one list on purpose: cancelling works on an index into the page the client
is holding, so showing exactly that page is what keeps every Cancel pointed at
the auction you clicked. The trade is that **undercut counts are per page**, and
the status line says so.

### 🔨 Crafting — is this even worth making?
Open a profession, pick a recipe, hit **Add to Aegis**. The Crafting tab then
lists every reagent — click one to shop for it like any other item. And it does
the maths you were doing in your head:

> **mats 12g 40s → sells 18g** · **Profit 4g 71s** *(after the 5% cut)*

That same profit line shows up **right on the profession window**, live, as you
click through recipes. It reads saved prices, so it works with the AH closed.

### 📈 History — where did all the gold go?
Sales get logged **straight from your mailbox** — open your mail and Aegis
records every "Auction successful" for you. Purchases get logged when you buy.
Then it tells you **Income · Spent · Net** over the last 24h, 7d, 30d, or all
time. Sort by when, type, item or amount — newest first unless you say
otherwise.

### 🪟 Resize it — or scale it
Drag the grip in the bottom-right corner. **Every** list re-fits — Buy, Sell,
Auctions, Crafting and History — so a taller window shows **more rows** rather
than more blank space. Vanilla frames
never reflow, so that's all size can do — for *bigger*, there's a **window
scale** on the Aegis tab (70%–150%). Both are remembered per character.

### 🔍 Aegis tab — scanning + settings
Run a full scan, a category-targeted scan, or scan everything in your bags to
price it. Pause, resume, or **stop** whenever. Plus your defaults: post duration,
undercut rule (% or flat, entered in coins), auto-fill price, window scale,
tooltip lines, profit line, and the pfUI skin — all in one place.

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

Class: Weapon
Disenchants Into (approx, from required level):
    81%  Lesser Magic Essence  x1.5
    19%  Strange Dust  x1.5

Disenchant (worth more than the AH):   10s 40c
```

Every number carries what qualifies it. The **sighting count** leads, because it
is context for every figure below it. **Buyout** sits above **Market** — today's
cheapest is what you act on, the median is the context for it. **Sell to
Vendor** and **Buy from Vendor** sit together because they are opposite sides of
the same NPC — money in and money out — and a vendor whose stock was finite
reads *Buy from Vendor (limited)*, because a price you can't go back to is not
a supply. Pick which lines
you want on the Aegis tab, and optionally show stack totals only while **Shift**
is held.

**Crafting Cost** appears when a recipe you have opened makes the item, priced
per unit rather than per craft. It stays quiet unless *every* reagent is priced:
a partial total reads low, and low is the direction that loses money.

**The verdict** — *worth more than vendor*, *worth more than the AH*, or *sells
for more than it breaks for* — is the comparison that made you hover, in green or
red. It stays silent when the two are within 10% of each other.

#### How the disenchant line knows

Item level is the one input the calculation needs, and the 1.12 client gives
addons no way to read it. Aegis has three sources, best first:

1. **You disenchanted one.** Evidence from the server you actually play on, so
   it outranks everything else. It won't guess from a single result: an essence
   pins an item down, a dust leaves two or three possibilities, so it keeps quiet
   until a second break settles it.
2. **[ClassicAPI](https://github.com/brues-code/ClassicAPI)** — a DLL, not an
   addon. 1.12 stores an item level on every item and shows it nowhere;
   ClassicAPI hands over the real number for everything, Turtle's custom gear
   included.
3. **The level required to equip it**, plus five. Approximate, and **always
   labelled** *(approx, from required level)* — required level moves in steps of
   five where item level does not, so an item near a boundary can land one band
   out. This is what answers without any DLL at all.

When the rule can answer but the market cannot, the line says which material is
missing — *no price yet for Large Glowing Shard* — instead of going quiet.

The value shown is for **one** item: a stack of twenty is twenty separate rolls,
not twenty times that number. The numbers behind it come from **8.8 million
observed disenchants**, not typed by hand; epics and anything above item level 65
are deliberately left unanswered because the data there isn't good enough to
trust. See `tools/README.md` for the workings.

ClassicAPI does the same for **vendor prices**. Without it they are still learned
two ways that cost you nothing: hovering an item at a merchant, and **putting one
in the auction house sell slot** — every item you post teaches Aegis its exact
vendor price.

---

## Using pfUI?

> There's no pfUI badge above on purpose — pfUI is **not required**. Aegis simply
> notices it and matches its look.

Aegis notices and **restyles itself to match** — pfUI's borders, buttons,
checkboxes and scrollbars instead of vanilla tooltip frames. Nothing to install;
it just happens. Turn it off any time with **"Match pfUI's look"** on the Aegis
tab (takes a `/reload`).

The skinning is purely cosmetic and fully guarded — if pfUI changes its API,
the worst case is Aegis keeps its default look. It never affects behaviour.

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
2. Drop the folder into:
   ```
   World of Warcraft/Interface/AddOns/Aegis_Exchange
   ```
3. **The folder must be named exactly `Aegis_Exchange`** — GitHub's ZIP unpacks
   as `Aegis_Exchange-main`, so rename it or the addon won't load.
4. Restart the client. Visit an auctioneer.

That's it. Aegis takes over the auction window automatically.

---

## Using it

| Do this | Get that |
|---|---|
| Talk to an auctioneer | The Aegis window opens automatically |
| `/aex` | Hand the session back to the stock Blizzard AH |
| **Blizzard UI** button | Same thing, with a mouse |
| **Aegis UI** button (on the stock AH) | Come back |
| `/aex debug` | Verbose scanner trace, for when something looks wrong |

**Prices come from scanning.** A fresh install knows nothing — run a scan (or
just search for things; ordinary searches feed the database too) and the market
numbers, % colours, and profit estimates fill in as you go.

---

## A few honest notes

- **Deposits are approximate.** Turtle inflates the number the client reports, so
  Aegis scales it and always labels it *approx*. Never treat it as exact.
- **Turtle specifics are baked in:** durations are ×3 (6h / 24h / 72h), there's a
  120-auction account cap, a 5% cut on sales, and the auction house is
  **cross-faction** — one shared economy, so prices aren't split by side.
- **Scanning is paced by your client, not by us.** Aegis waits on the client's
  own `CanSendAuctionQuery()` gate, which vanilla keeps shut ~5s after every
  query. A full scan takes a while; that's the protocol, not the addon.
  - Running the [AuctionQueryThrottle](https://github.com/brues-code/AuctionQueryThrottle)
    DLL? It clears that timer as soon as the server replies, so **Aegis speeds
    up automatically** — nothing to configure. It's a DLL rather than an addon,
    so there's nothing to detect: the gate *is* the signal. The Aegis tab shows
    which you're getting (`fast — gate opened in 0.28s`), and **Safe 4s** pacing
    is there if you ever want the old fixed floor back.
- **Mail sale-tracking is enUS-only** right now (it matches "Auction successful:").
- **What Aegis itself needs: nothing but the client.** It calls only vanilla 1.12
  API — no SuperWoW, Nampower, UnitXP_SP3 or ClassicAPI calls anywhere in the
  source, so it runs fine without any of them.
  [AuctionQueryThrottle](https://github.com/brues-code/AuctionQueryThrottle) is
  the only external thing that changes anything here, and only how fast scans go.

---

## Under the hood

```
Aegis_Exchange/
├── core/
│   ├── init.lua    namespace + event dispatcher
│   ├── util.lua    Lua 5.0-safe helpers (money, strings, tables)
│   ├── db.lua      price database, settings, ledger, vendor prices
│   ├── disenchant.lua  the disenchant rule, and what it learns from play
│   ├── scan.lua    page-by-page scanner state machine
│   ├── sell.lua    posting engine + owned auctions
│   └── buy.lua     search/buy engine + shopping lists + crafting
├── ui/
│   ├── frame.lua   the window and every tab
│   ├── skin.lua    optional pfUI restyling
│   └── tooltip.lua price lines on item tooltips
├── pfui/           drop-in skin for pfUI-addonskinner (not loaded by Aegis)
└── design/         mockups (reference only — never loaded)
```

Market value is a **time-weighted median** of each item's daily minimum buyout
over the last **30 days**, weighted so today counts fully, a week ago about a
third, and a month ago barely at all. One weird lowball can't wreck your
numbers — it's a median, so a single absurd listing moves it by nothing — while
a genuine price shift is tracked within about five days.

Everything is **Lua 5.0 and 1.12 API only** — no `string.match`, no `#`, no `%`
operator, no secure hooks. If you're contributing, `CLAUDE.md` has the full rules
and the reasons behind them, most of which were learned the hard way.

---

## Something broken?

1. Check the **version** in the window's title bar (`v1.50.1`) — quote it.
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
