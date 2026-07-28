# Aegis: Exchange

**A clean, fast auction house for Turtle WoW.**

The stock 1.12 auction house is three text boxes and a prayer. Aegis replaces it
with a window that actually knows what things are worth — what you should charge,
what you should pay, whether that recipe is worth crafting, and how much gold you
made this week.

> Built for **Turtle WoW 1.18.1**, which runs the original **WoW 1.12 (vanilla)**
> client on **Lua 5.0**. Not Classic. Not retail. Real vanilla.

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

### 🔍 Aegis tab — scanning + settings
Run a full scan, a category-targeted scan, or scan everything in your bags to
price it. Pause, resume, or **stop** whenever. Plus your defaults: post duration,
undercut rule, auto-fill price, tooltip lines, and profit line — all in one place.

### 💬 Tooltips everywhere
Every item tooltip — bags, inventory, the AH, even the mailbox — gains market
value, minimum buyout, and vendor price, with stack totals.

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
- **Scanning is deliberately polite.** ~4 seconds between pages, because the 1.12
  server will happily ignore you if you hammer it. A full scan takes a while;
  that's the protocol, not the addon.
- **Mail sale-tracking is enUS-only** right now (it matches "Auction successful:").

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
│   └── tooltip.lua price lines on item tooltips
└── design/         mockups (reference only — never loaded)
```

Market value is a **time-weighted median** of each item's daily minimum buyout
over ~11 days, so one weird lowball doesn't wreck your numbers and a genuine
price shift still moves them.

Everything is **Lua 5.0 and 1.12 API only** — no `string.match`, no `#`, no `%`
operator, no secure hooks. If you're contributing, `CLAUDE.md` has the full rules
and the reasons behind them, most of which were learned the hard way.

---

## Contributing

PRs welcome. Two requests: keep it inside the 1.12 rules in `CLAUDE.md`, and bump
the version in both `core/init.lua` and the `.toc` so in-game bug reports say
which build they came from.

## License

MIT — see [LICENSE](LICENSE).

---

*Aegis: Exchange is part of the Aegis addon series. Happy flipping.* ⚔️
