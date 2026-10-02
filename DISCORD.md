# ⚔️ Aegis: Exchange v1.54.27

## ✨ New
- **Searches read every page** — *Wizard Oil* finds every grade, Projectile → Bullet lists every ammo type, not just page 1
- **History is a dashboard** — full-tab gold chart, High · Low · Sold · Bought · Top Sale · Top Buy, and **Sales · Expenses · Profit** blocks
- **Ledger window** — **Items** (sold, bought, avg prices, avg profit) and **Transactions** views, with period buttons
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
- **Disenchant line said "?"** when one material had no price — now shows *at least* and still calls *worth more than vendor*
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
