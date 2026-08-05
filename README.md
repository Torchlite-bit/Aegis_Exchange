# Aegis: Exchange (v1.1.9)

**A clean, fast auction house for vanilla WoW (1.12).**

[![Discord](https://img.shields.io/badge/Discord-join%20us-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/hsgPTNkSX)
[![Octo WoW](https://img.shields.io/badge/Octo%20WoW-1.18.1-8A2BE2?style=flat-square&labelColor=555)](https://octowow.st/)
[![Capy WoW](https://img.shields.io/badge/Capy%20WoW-1.18.1-8B5A2B?style=flat-square&labelColor=555)](https://capycraft.io/)
[![Client](https://img.shields.io/badge/client-WoW%201.12%20(vanilla)-c79c6e?style=flat-square)](https://turtle-wow.org)

[![AuctionQueryThrottle](https://img.shields.io/badge/AuctionQueryThrottle-Highly%20Recommended-ff8c00?style=flat-square&labelColor=555)](https://github.com/brues-code/AuctionQueryThrottle)

<sub>**Aegis needs no mods or .dll** — it calls only vanilla 1.12 API.
**AuctionQueryThrottle** however is the one that changes anything here (scan speed).
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
under market, red is over.** Keep **shopping lists** of the things you always
need (all your tailoring mats, say) and search the whole list in one click.

### 💰 Sell — price it right the first time
Drop an item in and Aegis scans the AH for *just that item*, shows you every
competing listing, and pre-fills your price. **Undercut** by a percentage or a
flat amount (yes, 1 copper works). Post **multiple stacks at once** — "3 stacks
of 20" — with an approximate deposit and your listing count against the 120-auction
cap. Click any competitor's row to steal their price.

A **History** panel shows what your scans say the item is worth (median, the
range you've seen, how many days of data) next to what it has **actually sold
for** from your mailbox. And after a **bag scan**, Aegis loads the first item
into the sell slot and walks you down the list — **Post** or **Skip** moves to
the next one, so you can clear a full bag without clicking back and forth.

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
> doesn't expose them otherwise), so this list fills in as you play.

### 📜 Auctions — mind the store
Every auction you have out, with time left, current bid, and the thing you
actually care about: **have I been undercut?** Green means you're still the
cheapest. Red means someone slid under you. Cancel anything with one click.

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
time.

### 🪟 Resize it
Drag the grip in the bottom-right corner. The lists re-fit as you drag, so a
taller window shows **more rows** rather than more blank space. Your size is
remembered per character.

### 🔍 Aegis tab — scanning + settings
Run a full scan, a category-targeted scan, or scan everything in your bags to
price it. Pause, resume, or **stop** whenever. Plus your defaults: post duration,
undercut rule (% or flat), auto-fill price, tooltip lines, profit line, and the
pfUI skin — all in one place.

### 💬 Tooltips everywhere
Bags, inventory, the auction house, merchants, the mailbox, **loot windows,
quest rewards and profession reagents** — all gain market value, minimum buyout
and vendor price, with stack totals. Pick which of those three lines you want on
the Aegis tab, and optionally show stack totals only while **Shift** is held.

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
│   ├── db.lua      price database, settings, ledger
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
over ~11 days, so one weird lowball doesn't wreck your numbers and a genuine
price shift still moves them.

Everything is **Lua 5.0 and 1.12 API only** — no `string.match`, no `#`, no `%`
operator, no secure hooks. If you're contributing, `CLAUDE.md` has the full rules
and the reasons behind them, most of which were learned the hard way.

---

## Something broken?

1. Check the **version** in the window's title bar (`v1.1.9`) — quote it.
2. `/aex debug` turns on a scanner trace if a scan is misbehaving.
3. Tell us on **[Discord](https://discord.gg/hsgPTNkSX)** or open an
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
2. Bump the version in **both** `core/init.lua` and the `.toc`, so in-game bug
   reports say which build they came from.
3. Add a line to [`CHANGELOG.md`](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).

---

<div align="center">

**[💬 Discord](https://discord.gg/hsgPTNkSX)** · **[📜 Changelog](CHANGELOG.md)** · **[🐛 Issues](https://github.com/Torchlite-bit/Aegis_Exchange/issues)**

*Aegis: Exchange is part of the Aegis addon series. Happy flipping.* ⚔️

</div>
