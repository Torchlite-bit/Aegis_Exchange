# Aegis: Exchange — Design Reference

This folder holds the **visual concept** for the addon. It is a reference target, not source code.

> **IMPORTANT — for Claude Code and any developer:**
> These files are a **visual target only**. The real addon UI is built in **Lua against vanilla WoW 1.12 frame templates** (FauxScrollFrame, UIPanelButton, MoneyFrame, dropdowns, checkbuttons, one StatusBar) per `Aegis_Exchange/CLAUDE.md`.
> **Do NOT port the HTML/CSS.** Do not recreate flexbox, gradients, or web layout. Match the *layout, hierarchy, and styling intent* — then implement it with real 1.12 templates.
> None of these files are loaded by the game. They are **not** listed in `Aegis_Exchange.toc` and must never be.

---

## Files

| File | What it shows | Build phase it pairs with |
|------|---------------|---------------------------|
| `prototype.html` | Full interactive mockup (all screens) | — (reference for all) |
| `overview.png` | Whole Aegis panel docked to the AH frame, sub-tab row, scan strip, component legend | — (orientation) |
| `01-scan-strip.png` | Persistent scan status strip (idle / scanning / stale states) + item tooltip mockup | **Phase 1** — scanning engine + tooltip |
| `02-sell.png` | Sell sub-tab: drop-slot, suggested undercut price, deposit, listings counter, duration, low-price warning modal | **Phase 2** — post + undercut price + too-low protection |
| `03-buy.png` | Buy sub-tab: shopping-list sidebar, filter row, recent searches, results list, empty states | **Phase 3** — filtered search + history + shopping lists |
| `04-auctions.png` | Auctions sub-tab: own auctions, undercut (red) vs lowest (green) rows, cancel buttons, scan progress | **Phase 4** — undercut scan + one-click cancel |
| `05-crafting.png` | Crafting sub-tab: recipe list, reagent rows, cost/value/profit summary, "find reagents" button | **Phase 5** — reagent cost/profit + find reagents |

> Adjust filenames above to match what you actually exported from Claude Design.

---

## How to use these when building

When you hand a build phase to Claude Code, attach the matching screen and say:

> "Match the layout and styling in `design/02-sell.png`, but build it with real vanilla 1.12 frame templates per `CLAUDE.md`. Do not port the HTML/CSS — it's a visual target only."

Repeat per sub-tab for each phase.

---

## Source of truth

- **What the UI should look like** → these files.
- **What gets built and how** → the phased Claude Code prompts + `Aegis_Exchange/CLAUDE.md`.

If the prototype and a build prompt ever disagree, the build prompt + CLAUDE.md win. The prototype is the picture; the prompts are the plan.
