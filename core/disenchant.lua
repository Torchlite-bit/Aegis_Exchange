-- Aegis: Exchange
-- core/disenchant.lua
--
-- What an item disenchants into, and what that is worth.
--
-- THERE IS NO DISENCHANT TABLE HERE. There is a rule, and an item level.
--
-- Given item level, quality and weapon-or-armour, vanilla's disenchant result
-- is fully determined -- which materials, how often, and how many. That is not
-- read from documentation; it is measured. tools/gen_disenchant.py derives the
-- BANDS table below from 8.8 million observed disenchants, and the band
-- boundaries land exactly on the 5-wide ladder with no fuzz.
--
-- The consequence worth understanding before editing anything here: every
-- source of disenchant knowledge -- a shipped item-level table, a disenchant
-- the player performed, `minLevel` as a last resort -- answers the SAME
-- question, "what is this item's level". They are not four different lookups.
-- This file is the one rule they all feed.
--
-- 1.12 gives us no item level (`util.ItemInfo` documents that at length), so
-- resolving it is the whole problem. `de.ItemLevel` is the shipped-table half;
-- learning it from play is a later phase.
--
-- WHAT THIS FILE DELIBERATELY CANNOT ANSWER, and why -- do not "fix" these by
-- filling in plausible numbers:
--
--   * Item level above 65. The observations thin to a few dozen there and
--     stop being monotone, and Turtle item levels run to 99. `de.Band`
--     returns nil, once, so no caller can extrapolate by accident.
--   * Epics (quality 4). Vanilla players rarely disenchanted epics, so the
--     source data holds 9 items total, with yields (4.1 Large Brilliant
--     Shards per proc) that no real item produces. The generator drops them
--     and BANDS has no [4]. An epic reports unknown.
--   * Weapons in a few bands. Where the source has no usable weapon data the
--     band ships armour only. Armour numbers are NOT borrowed for weapons:
--     armour is dust-led (~82%) and weapons essence-led (~80%), so borrowing
--     would be confidently wrong rather than roughly right.
--   * Whether an item can be disenchanted AT ALL. Quality and equip slot get
--     most of the way; the rest is a hardcoded exception list that no rule
--     predicts. Turtle will have its own entries and only a failed disenchant
--     reveals them.
--
-- Everything here is a pure function of its arguments -- no globals read, no
-- DB, no client API. `de.Value` takes the pricer as a parameter for that
-- reason: it is testable without either, and a caller that needs a stricter
-- price source can pass one.

local A = AegisExchange
A.de = {}
local de = A.de
local util = A.util

-- The ladder is fixed and 5 wide. Nothing above the last entry is answerable;
-- see the header. Kept as ONE table rather than a family of file-scope locals
-- -- the 32-upvalue ceiling is real and a table of constants costs one.
local LADDER = { 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65 }

-- equipLoc -> the BANDS key for that class. Returning the table key directly
-- rather than a prettier "armor"/"weapon" removes a translation step, and a
-- translation step is somewhere a swap can hide.
local INVTYPE = {
    INVTYPE_2HWEAPON      = "w",
    INVTYPE_WEAPON        = "w",
    INVTYPE_WEAPONMAINHAND = "w",
    INVTYPE_WEAPONOFFHAND = "w",
    INVTYPE_RANGED        = "w",
    INVTYPE_RANGEDRIGHT   = "w",
    INVTYPE_THROWN        = "w",
    INVTYPE_HEAD          = "a",
    INVTYPE_NECK          = "a",
    INVTYPE_SHOULDER      = "a",
    INVTYPE_BODY          = "a",
    INVTYPE_CHEST         = "a",
    INVTYPE_ROBE          = "a",
    INVTYPE_WAIST         = "a",
    INVTYPE_LEGS          = "a",
    INVTYPE_FEET          = "a",
    INVTYPE_WRIST         = "a",
    INVTYPE_HAND          = "a",
    INVTYPE_FINGER        = "a",
    INVTYPE_TRINKET       = "a",
    INVTYPE_CLOAK         = "a",
    INVTYPE_HOLDABLE      = "a",
    INVTYPE_SHIELD        = "a",
    INVTYPE_RELIC         = "a",
    INVTYPE_TABARD        = "a",
}

-- Items that pass every test above and still cannot be disenchanted. There is
-- no rule behind this; it is a list. These seven are the vanilla ones aux also
-- carries. A table so Turtle's can be added without touching the function.
local NEVER = {
    [20406] = true,   -- Twilight Cultist Mantle
    [20407] = true,   -- Twilight Cultist Robe
    [20408] = true,   -- Twilight Cultist Cowl
    [11287] = true,   -- Lesser Magic Wand      (enchanter-made)
    [11288] = true,   -- Greater Magic Wand
    [11289] = true,   -- Lesser Mystic Wand
    [11290] = true,   -- Greater Mystic Wand
}

-- BANDS[quality][band] = { a = armour, w = weapon }, each a list of
-- { materialId, chance, meanYield }. `chance` sums to 1 across the list;
-- `meanYield` is the average count when that material is the one that drops.
-- The comment on each class carries the item count and observation count
-- behind it -- that is the evidence, and it is why this table is generated
-- rather than typed. Re-run tools/gen_disenchant.py; do not patch a number.
local BANDS = {
    [2] = {   -- green
        [15] = {
            a = {   -- 118 items, n=418902
                { 10940, 0.8102, 1.517 },   -- Strange Dust
                { 10938, 0.1898, 1.516 },   -- Lesser Magic Essence
            },
            w = {   -- 41 items, n=154152
                { 10938, 0.8091, 1.518 },   -- Lesser Magic Essence
                { 10940, 0.1909, 1.492 },   -- Strange Dust
            },
        },
        [20] = {
            a = {   -- 202 items, n=652964
                { 10940, 0.7642, 2.509 },   -- Strange Dust
                { 10939, 0.1889, 1.506 },   -- Greater Magic Essence
                { 10978, 0.0469, 1.006 },   -- Small Glimmering Shard
            },
            w = {   -- 52 items, n=191048
                { 10939, 0.7593, 1.515 },   -- Greater Magic Essence
                { 10940, 0.1889, 2.523 },   -- Strange Dust
                { 10978, 0.0519, 1.001 },   -- Small Glimmering Shard
            },
        },
        [25] = {
            a = {   -- 202 items, n=449927
                { 10940, 0.7778, 5.022 },   -- Strange Dust
                { 10998, 0.1344, 1.525 },   -- Lesser Astral Essence
                { 10978, 0.0877, 1.005 },   -- Small Glimmering Shard
            },
            -- w: no usable data (0 items, n=0)
        },
        [30] = {
            a = {   -- 258 items, n=574926
                { 11083, 0.7742, 1.525 },   -- Soul Dust
                { 11082, 0.1809, 1.502 },   -- Greater Astral Essence
                { 11084, 0.0449, 1.000 },   -- Large Glimmering Shard
            },
            -- w: no usable data (0 items, n=0)
        },
        [35] = {
            a = {   -- 255 items, n=430610
                { 11083, 0.7891, 3.515 },   -- Soul Dust
                { 11134, 0.1689, 1.497 },   -- Lesser Mystic Essence
                { 11138, 0.0420, 1.001 },   -- Small Glowing Shard
            },
            w = {   -- 25 items, n=64685
                { 11134, 0.7689, 1.509 },   -- Lesser Mystic Essence
                { 11083, 0.1877, 3.512 },   -- Soul Dust
                { 11138, 0.0434, 1.020 },   -- Small Glowing Shard
            },
        },
        [40] = {
            a = {   -- 249 items, n=584008
                { 11137, 0.7775, 1.527 },   -- Vision Dust
                { 11135, 0.1764, 1.497 },   -- Greater Mystic Essence
                { 11139, 0.0461, 1.000 },   -- Large Glowing Shard
            },
            w = {   -- 29 items, n=76126
                { 11135, 0.7480, 1.522 },   -- Greater Mystic Essence
                { 11137, 0.2024, 1.514 },   -- Vision Dust
                { 11139, 0.0496, 1.033 },   -- Large Glowing Shard
            },
        },
        [45] = {
            a = {   -- 335 items, n=592103
                { 11137, 0.7867, 3.524 },   -- Vision Dust
                { 11174, 0.1682, 1.504 },   -- Lesser Nether Essence
                { 11177, 0.0452, 1.000 },   -- Small Radiant Shard
            },
            w = {   -- 27 items, n=55612
                { 11174, 0.8042, 1.498 },   -- Lesser Nether Essence
                { 11137, 0.1532, 3.839 },   -- Vision Dust
                { 11177, 0.0427, 1.000 },   -- Small Radiant Shard
            },
        },
        [50] = {
            a = {   -- 321 items, n=742147
                { 11176, 0.7811, 1.530 },   -- Dream Dust
                { 11175, 0.1759, 1.511 },   -- Greater Nether Essence
                { 11178, 0.0430, 1.018 },   -- Large Radiant Shard
            },
            w = {   -- 28 items, n=57873
                { 11175, 0.7727, 1.507 },   -- Greater Nether Essence
                { 11176, 0.1783, 1.486 },   -- Dream Dust
                { 11178, 0.0490, 1.055 },   -- Large Radiant Shard
            },
        },
        [55] = {
            a = {   -- 152 items, n=247579
                { 11176, 0.8148, 3.521 },   -- Dream Dust
                { 16202, 0.1852, 1.513 },   -- Lesser Eternal Essence
            },
            w = {   -- 13 items, n=30860
                { 16202, 0.8359, 1.469 },   -- Lesser Eternal Essence
                { 11176, 0.1641, 3.475 },   -- Dream Dust
            },
        },
        [60] = {
            a = {   -- 298 items, n=751452
                { 16204, 0.7751, 1.525 },   -- Illusion Dust
                { 16203, 0.1976, 1.512 },   -- Greater Eternal Essence
                { 14344, 0.0273, 1.000 },   -- Large Brilliant Shard
            },
            w = {   -- 25 items, n=65838
                { 16203, 0.7611, 1.526 },   -- Greater Eternal Essence
                { 16204, 0.2084, 1.525 },   -- Illusion Dust
                { 14344, 0.0305, 1.000 },   -- Large Brilliant Shard
            },
        },
        [65] = {
            a = {   -- 64 items, n=65819
                { 16204, 0.8507, 3.540 },   -- Illusion Dust
                { 16203, 0.1493, 2.482 },   -- Greater Eternal Essence
            },
            -- w: no usable data (4 items, n=3740)
        },
    },
    [3] = {   -- rare
        [20] = {
            a = {   -- 7 items, n=5376
                { 10978, 1.0000, 1.000 },   -- Small Glimmering Shard
            },
            w = {   -- 7 items, n=5376
                { 10978, 1.0000, 1.000 },   -- Small Glimmering Shard
            },
        },
        [25] = {
            a = {   -- 46 items, n=129937
                { 10978, 1.0000, 1.009 },   -- Small Glimmering Shard
            },
            w = {   -- 46 items, n=129937
                { 10978, 1.0000, 1.009 },   -- Small Glimmering Shard
            },
        },
        [30] = {
            a = {   -- 44 items, n=120505
                { 11084, 1.0000, 1.001 },   -- Large Glimmering Shard
            },
            w = {   -- 44 items, n=120505
                { 11084, 1.0000, 1.001 },   -- Large Glimmering Shard
            },
        },
        [35] = {
            a = {   -- 45 items, n=57954
                { 11138, 1.0000, 1.001 },   -- Small Glowing Shard
            },
            w = {   -- 45 items, n=57954
                { 11138, 1.0000, 1.001 },   -- Small Glowing Shard
            },
        },
        [40] = {
            a = {   -- 56 items, n=125839
                { 11139, 1.0000, 1.012 },   -- Large Glowing Shard
            },
            w = {   -- 56 items, n=125839
                { 11139, 1.0000, 1.012 },   -- Large Glowing Shard
            },
        },
        [45] = {
            a = {   -- 53 items, n=194288
                { 11177, 1.0000, 1.007 },   -- Small Radiant Shard
            },
            w = {   -- 53 items, n=194288
                { 11177, 1.0000, 1.007 },   -- Small Radiant Shard
            },
        },
        [50] = {
            a = {   -- 56 items, n=163395
                { 11178, 1.0000, 1.006 },   -- Large Radiant Shard
            },
            w = {   -- 56 items, n=163395
                { 11178, 1.0000, 1.006 },   -- Large Radiant Shard
            },
        },
        [55] = {
            a = {   -- 96 items, n=221288
                { 14343, 1.0000, 1.010 },   -- Small Brilliant Shard
            },
            w = {   -- 96 items, n=221288
                { 14343, 1.0000, 1.010 },   -- Small Brilliant Shard
            },
        },
        [60] = {
            a = {   -- 182 items, n=338076
                { 14344, 1.0000, 1.019 },   -- Large Brilliant Shard
            },
            w = {   -- 182 items, n=338076
                { 14344, 1.0000, 1.019 },   -- Large Brilliant Shard
            },
        },
        [65] = {
            a = {   -- 194 items, n=359504
                { 14344, 1.0000, 1.011 },   -- Large Brilliant Shard
            },
            w = {   -- 194 items, n=359504
                { 14344, 1.0000, 1.011 },   -- Large Brilliant Shard
            },
        },
    },
}

-- Which band an item level falls in, or nil when it is out of range.
--
-- The nil above the ladder's top is the single place the "we do not know past
-- 65" rule is expressed. Every caller inherits it by getting nil back, which
-- is why no other function repeats the check.
function de.Band(ilvl)
    if type(ilvl) ~= "number" or ilvl < 1 then return nil end
    local i, n = 1, table.getn(LADDER)
    while i <= n do
        if ilvl <= LADDER[i] then return LADDER[i] end
        i = i + 1
    end
    return nil
end

-- equipLoc -> "a" (armour) or "w" (weapon), or nil for anything not worn.
function de.Class(equipLoc)
    if not equipLoc then return nil end
    return INVTYPE[equipLoc]
end

-- Can this item be disenchanted at all?
--
-- Quality must be uncommon..epic: greys and whites yield nothing, and
-- legendaries cannot be disenchanted in vanilla. `itemId` is optional and
-- only consulted against the exception list.
function de.CanDisenchant(quality, equipLoc, itemId)
    if type(quality) ~= "number" then return false end
    if quality < 2 or quality > 4 then return false end
    if not de.Class(equipLoc) then return false end
    if itemId and NEVER[itemId] then return false end
    return true
end

-- The stored rows for this combination, or nil. Internal: the caller must not
-- hold on to or mutate the table, which is why de.Yield copies and only
-- de.Value (the hot path, called per auction row) reads it directly.
local function RowsFor(ilvl, quality, equipLoc, itemId)
    if not de.CanDisenchant(quality, equipLoc, itemId) then return nil end
    local band = de.Band(ilvl)
    if not band then return nil end
    local byQuality = BANDS[quality]
    if not byQuality then return nil end
    local rec = byQuality[band]
    if not rec then return nil end
    return rec[de.Class(equipLoc)]
end

-- What this item disenchants into: a list of { itemId, chance, mean }, or nil
-- when we cannot say. `chance` sums to 1 across the list; `mean` is the
-- average quantity when that material is the one that drops.
--
-- Returns nil rather than a partial list. Half an answer about what an item
-- breaks into reads exactly like a whole one.
function de.Yield(ilvl, quality, equipLoc, itemId)
    local rows = RowsFor(ilvl, quality, equipLoc, itemId)
    if not rows then return nil end
    local out, i, n = {}, 1, table.getn(rows)
    while i <= n do
        local r = rows[i]
        table.insert(out, { itemId = r[1], chance = r[2], mean = r[3] })
        i = i + 1
    end
    return out
end

-- Expected disenchant value in copper, or nil.
--
-- `priceOf(materialId)` supplies the price and is a PARAMETER, not a direct
-- A.db call: it keeps this function testable without a DB, and lets a caller
-- that must be more careful (advising someone to destroy an item, say) pass a
-- stricter source than one that is only filtering a list.
--
-- One unknown material price makes the WHOLE value nil. Treating it as zero
-- would quietly under-report every item whose shard has never been seen, and
-- under-reporting a disenchant value is the direction that loses money.
function de.Value(ilvl, quality, equipLoc, itemId, priceOf)
    local rows = RowsFor(ilvl, quality, equipLoc, itemId)
    if not rows or not priceOf then return nil end
    local total, i, n = 0, 1, table.getn(rows)
    while i <= n do
        local r = rows[i]
        local price = priceOf(r[1])
        if not price then return nil end
        total = total + r[2] * r[3] * price
        i = i + 1
    end
    return math.floor(total + 0.5)
end

-- This item's level, and where it came from.
--
-- Returns level, "itemlevel" from the shipped table, or nil, nil. Later
-- phases add sources ABOVE this one -- a disenchant the player performed
-- names the band directly and is always preferred, because it is evidence
-- from the server they are actually on rather than from vanilla in 2006.
function de.ItemLevel(itemId)
    if not itemId or not A.ilvlData then return nil end
    local lvl = A.ilvlData[itemId]
    if type(lvl) ~= "number" or lvl < 1 then return nil end
    return lvl, "itemlevel"
end

-- ---------------------------------------------------------------------------
-- Resolving one item -- the layer everything user-facing goes through
-- ---------------------------------------------------------------------------

-- itemId -> item level, where that level came from, quality, equip slot.
--
-- Returns nil unless ALL of it is known. There are three separate ways to not
-- know -- the client has never cached the item, the item is not disenchantable,
-- or no source knows its level -- and callers do not need to tell them apart:
-- every one of them means "say nothing". Distinguishing them here would only
-- invite a caller to print three different flavours of shrug.
--
-- `source` names where the ITEM LEVEL came from, never where a price did. It
-- is the fact that decides how far a caller should trust the number, which is
-- why it is returned rather than left implicit.
function de.Resolve(itemId)
    if not itemId or not util then return nil end
    -- The numeric id, not an "item:900:0:0:0" string: both are valid on 1.12
    -- but the id needs no formatting and therefore cannot be mis-formatted.
    local info = util.ItemInfo(itemId)
    if not info then return nil end
    if not de.CanDisenchant(info.quality, info.equipLoc, itemId) then
        return nil
    end
    local ilvl, source = de.ItemLevel(itemId)
    if not ilvl then return nil end
    return ilvl, source, info.quality, info.equipLoc
end

-- What this item disenchants into, by id. Returns rows, source, or nil.
function de.YieldOf(itemId)
    local ilvl, source, quality, equipLoc = de.Resolve(itemId)
    if not ilvl then return nil end
    local rows = de.Yield(ilvl, quality, equipLoc, itemId)
    if not rows then return nil end
    return rows, source
end

-- What this item is worth disenchanted, by id. Returns copper, source, or nil.
function de.ValueOf(itemId, priceOf)
    local ilvl, source, quality, equipLoc = de.Resolve(itemId)
    if not ilvl then return nil end
    local value = de.Value(ilvl, quality, equipLoc, itemId, priceOf)
    if not value then return nil end
    return value, source
end

-- The default pricer: what one of a material is worth, best source first.
--
-- ONE writer, shared by the tooltip and /aex de, so the two can never quote
-- different numbers for the same item -- which is the drift that produced the
-- Saved-vs-Builder mismatch in 1.19.3 and is worth not repeating.
function de.MarketPrice(matId)
    if not A.db or not A.db.MarketValue then return nil end
    return A.db.MarketValue(matId) or A.db.MinBuyout(matId)
end

-- The breakdown as display lines: { "78%  1.5 x Dream Dust", ... }, or nil.
--
-- `nameOf(materialId)` supplies the names and is a PARAMETER for the same
-- reason de.Value takes a pricer: it keeps this testable without a client, and
-- it keeps the one decision about how a yield READS out of the UI, where two
-- callers would otherwise each grow their own version of it.
function de.BreakdownText(rows, nameOf)
    if not rows then return nil end
    local out, i, n = {}, 1, table.getn(rows)
    while i <= n do
        local r = rows[i]
        local name = (nameOf and nameOf(r.itemId)) or ("item:" .. r.itemId)
        table.insert(out, string.format("%2d%%  %.1f x %s",
            math.floor(r.chance * 100 + 0.5), r.mean, name))
        i = i + 1
    end
    return out
end

-- Parse a `/aex de` argument: an item link OR a bare item id, plus an optional
-- item level to stand in for the lookup.
--
-- Returns itemId, ilvl -- either may be nil.
--
-- The override is read from what follows the LINK, never from the whole
-- string. The first version read the trailing number out of the whole string
-- and then tried to rule out digits belonging to the link by asking whether
-- the link contained them. That cannot work: any item whose id merely happens
-- to contain the same digits loses its override silently, so "/aex de <boots>
-- 48" did nothing at all for a large slice of the item table -- and this
-- command is the only way to exercise the rule while the item-level lookup
-- ships empty, so it failing quietly was the worst place for it to fail.
--
-- Extracted rather than left inline in the slash handler because a parser is
-- exactly the kind of thing that can be wrong in a way nothing errors on.
function de.ParseReportArgs(rest)
    rest = rest or ""
    local first, last = string.find(rest, "|c%x+|Hitem:.-|h.-|h|r")
    if first then
        local id = util and util.ItemIdFromLink(string.sub(rest, first, last))
        local _, _, lvl = string.find(string.sub(rest, last + 1), "(%d+)")
        return id, tonumber(lvl)
    end
    -- No link. Bare ids are accepted so the rule can be exercised without
    -- owning the item -- "/aex de 12345 48" is the whole point of the command
    -- until item levels are resolvable on their own.
    local _, _, id, lvl = string.find(rest, "^%s*(%d+)%s+(%d+)%s*$")
    if id then return tonumber(id), tonumber(lvl) end
    local _, _, only = string.find(rest, "^%s*(%d+)%s*$")
    if only then return tonumber(only), nil end
    return nil, nil
end
