# ⚔️ Aegis: Exchange v1.54.25

## ✨ New
- **Browse a category, get every page** — Projectile → Bullet lists every ammo type in one grouped list, not just page 1
- **History is a dashboard** — the gold chart gets the whole tab, with High · Low · Sold · Bought · Top Sale · Top Buy underneath, and **Sales · Expenses · Profit** blocks (total, per day, top item)
- **Ledger window** — an **Items** view (sold, avg sell, bought, avg buy, avg profit per item) and a **Transactions** view, with its own period buttons
- **Stack sizes are recorded** for sales and purchases
- **Receipt** button on the Buy tab — everything bought this session: units, auctions, avg each, total
- Grouped results count items too: `8 auctions, 129 items`
- Price lines on items **clicked in chat**
- Money in gold / silver / copper colours
- **Remove all** on the Crafting tab, and Remove now works down the list
- `/aex demo` fills the Ledger and Receipt too

## 🛠️ Fixed
- **Disenchant values rebuilt from the server's own loot table** — epics have a value, weapons answer at every level, the 5% Brilliant Shard is back for ilvl 51–65 greens, shields & off-hands are priced right, thrown weapons no longer claim to disenchant
- **Sell tab showed no listings** for items your client hadn't seen yet
- **Buying again after a buyout** said *no longer available* until you searched again
- **Wizard Oil & other charge items** couldn't be posted (showed a negative total)
- Posting split stacks into your **ammo pouch** and gave up
- **Deposit crept** while you clicked Undercut / Price match
- **Bags stuck behind the window** — click one and it comes to the front
- Sales weren't logged on **non-English clients**
- `/aex demo` could change or delete your **real** crafting recipes
- Below-vendor warning now counts the 5% AH cut
- Sale counts work for auctions posted before you updated

📥 https://github.com/Torchlite-bit/Aegis_Exchange
