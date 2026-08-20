-- Aegis: Exchange
-- core/itemlevel.lua
--
-- [itemId] = itemLevel, and nothing else.
--
-- 1.12's GetItemInfo returns no item level -- see the long note in
-- `util.ItemInfo` -- and item level is the single input core/disenchant.lua
-- needs. This file is where a shipped lookup would live.
--
-- IT IS DELIBERATELY EMPTY.
--
-- The obvious source is ShaguScore's Database.lua (12,871 item levels,
-- including a useful slice of Turtle's custom items). It ships with NO
-- LICENCE: no LICENSE file, no header, nothing in its README or .toc. Aegis
-- is MIT. Vendoring an unlicensed database into an MIT addon is a decision
-- about someone else's work, not a technical one, so it is not mine to make
-- quietly -- exactly as ROADMAP 3k says.
--
-- Nothing is blocked by that. The file is in the .toc from the day the
-- feature landed, so data can be dropped in later WITHOUT another .toc edit
-- and therefore without asking everyone to restart the client a second time.
-- `de.ItemLevel` already handles the empty case, and learning item levels
-- from the player's own disenchants -- a later phase -- fills this in from
-- the server they are actually on, which is better data than any 2006 table.
--
-- If it is ever populated, the format is exactly:
--     A.ilvlData = { [12345] = 41, [12346] = 44, ... }
-- and the provenance goes in tools/README.md next to the generator's.

local A = AegisExchange

A.ilvlData = {}
